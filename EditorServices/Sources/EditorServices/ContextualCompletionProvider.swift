import EditorCore
import EditorWorkspace
import Foundation

struct ContextualCompletionResult: Sendable {
  var completions: [Completion]
  var projectSymbols: [ProjectCompletionSymbol]
}

/// Produces lightweight, project-aware completions when an LSP is unavailable or incomplete.
///
/// The provider intentionally remains internal. Public callers continue to use the backend's
/// completion API while the backend combines these candidates with language-server results.
struct ContextualCompletionProvider: Sendable {
  private var projectIndex = ProjectCompletionIndex()

  mutating func completions(
    snapshot: TextSnapshot,
    uri: URL,
    languageID: String,
    position: TextPosition,
    triggerCharacter: String?,
    allowEmptyPrefix: Bool = false,
    workspaceFiles: [SourceCodeFile],
    externalFiles: [ExternalIndexedSourceFile] = [],
    externalGeneration: Int = 0,
    limit: Int
  ) throws -> ContextualCompletionResult {
    let context = try CompletionQueryContext(snapshot: snapshot, position: position)
    let languageStrategy = CompletionLanguageStrategyRegistry.strategy(for: languageID)
    let initializerContext = languageStrategy.initializerContext(
      in: snapshot.text,
      caretUTF16Offset: context.caretUTF16Offset
    )
    let triggeredMemberRequest =
      triggerCharacter == "." || triggerCharacter == ":" || triggerCharacter == ">"

    let lexicalContext = CompletionStructuralAnalysis.lexicalContext(
      in: snapshot.text,
      languageID: languageID,
      caret: context.caretUTF16Offset
    )
    let memberAccess = CompletionScopedSymbolAnalysis.memberAccess(
      in: snapshot.text,
      languageID: languageID,
      caretUTF16Offset: context.caretUTF16Offset,
      prefix: context.prefix,
      lexicalContext: lexicalContext
    )
    let isMemberRequest = triggeredMemberRequest || memberAccess != nil
    guard
      !context.prefix.isEmpty || allowEmptyPrefix || isMemberRequest || context.isImportPath
        || initializerContext != nil
    else {
      return ContextualCompletionResult(completions: [], projectSymbols: [])
    }

    var accumulator = CompletionCandidateAccumulator(
      prefix: context.prefix,
      languageID: languageID,
      limit: limit
    )
    if !isMemberRequest {
      accumulator.consumeFunctionParameters(lexicalContext.parameterSpellings)
    }

    projectIndex.update(
      workspaceFiles: workspaceFiles,
      externalFiles: externalFiles,
      externalGeneration: externalGeneration
    )
    let currentDirectory = uri.deletingLastPathComponent().standardizedFileURL
    let importedText = CompletionImportContext.importText(in: snapshot.text, languageID: languageID)
    let workspaceSymbols = projectIndex.symbols(languageID: languageID, excluding: uri)
    let currentSymbols = ProjectDeclarationScanner.scan(
      text: snapshot.text,
      languageID: languageID,
      fileName: uri.lastPathComponent,
      url: uri
    )
    let allSymbols = currentSymbols + workspaceSymbols
    let visibleNames = lexicalContext.localNames.union(lexicalContext.parameterNames)
    let visibleBindings = languageStrategy.visibleBindings(
      in: snapshot.text,
      caretUTF16Offset: context.caretUTF16Offset,
      lexicalTypes: lexicalContext.variableTypes
    ).filter { visibleNames.contains($0.name.lowercased()) }
    if let initializerContext {
      switch initializerContext.position {
      case .memberName:
        accumulator.consumeInitializerMembers(
          allSymbols,
          context: initializerContext,
          visibleBindings: visibleBindings,
          strategy: languageStrategy
        )
      case .memberValue(let memberName):
        accumulator.consumeInitializerValues(
          visibleBindings,
          memberName: memberName,
          memberType: allSymbols.first { symbol in
            symbol.ownerType?.caseInsensitiveCompare(initializerContext.typeName) == .orderedSame
              && symbol.name.caseInsensitiveCompare(memberName) == .orderedSame
          }?.typeName,
          strategy: languageStrategy
        )
      }
    }
    let memberSymbols =
      memberAccess.map { access in
        allSymbols.filter(access.accepts)
      } ?? []
    let hasResolvedMemberCandidates =
      !memberSymbols.isEmpty || memberAccess?.tupleMembers.isEmpty == false

    if !hasResolvedMemberCandidates {
      accumulator.consume(
        text: snapshot.text,
        origin: .currentDocument,
        caretUTF16Offset: context.caretUTF16Offset
      )
    }

    if let memberAccess {
      if hasResolvedMemberCandidates {
        accumulator.consumeMemberSymbols(
          memberSymbols,
          context: memberAccess,
          currentURI: uri
        )
        accumulator.consumeFallbackMemberSymbols(
          allSymbols.filter { !memberAccess.accepts($0) },
          context: memberAccess
        )
        accumulator.consumeScopedCandidates(memberAccess.tupleMembers, scoreBonus: 1_450)
      } else {
        // A language server may still be warming up or an external type may have been inferred
        // through a qualified constructor. Keep library/project members available instead of
        // falling back to unrelated global identifiers only.
        accumulator.consumeFallbackMemberSymbols(allSymbols, context: memberAccess)
      }
    } else {
      accumulator.consumeProjectSymbols(
        currentSymbols,
        currentDirectory: currentDirectory,
        currentFileStem: uri.deletingPathExtension().lastPathComponent,
        importedText: importedText,
        currentDocument: true
      )
      accumulator.consumeProjectSymbols(
        workspaceSymbols,
        currentDirectory: currentDirectory,
        currentFileStem: uri.deletingPathExtension().lastPathComponent,
        importedText: importedText
      )
    }
    if context.isImportPath {
      accumulator.consumeProjectFiles(
        workspaceFiles,
        externalFiles: externalFiles,
        currentURI: uri,
        linePrefix: context.linePrefix
      )
    } else if !hasResolvedMemberCandidates,
      initializerContext?.position != .memberName
    {
      accumulator.consumeLanguageItems()
    }
    return ContextualCompletionResult(
      completions: accumulator.results(),
      projectSymbols: currentSymbols + workspaceSymbols
    )
  }
}

private struct CompletionQueryContext {
  let prefix: String
  let caretUTF16Offset: Int
  let linePrefix: String
  let isImportPath: Bool

  init(snapshot: TextSnapshot, position: TextPosition) throws {
    caretUTF16Offset = try snapshot.utf16Offset(of: position)
    let range = try CompletionUtilities.inferredIdentifierRange(in: snapshot, endingAt: position)
    let nsRange = try snapshot.nsRange(for: range)
    let source = snapshot.text as NSString
    prefix = source.substring(with: nsRange)
    var lineStart = nsRange.location
    while lineStart > 0 {
      let previous = source.character(at: lineStart - 1)
      if previous == 10 || previous == 13 { break }
      lineStart -= 1
    }
    linePrefix = source.substring(
      with: NSRange(location: lineStart, length: max(0, nsRange.location - lineStart))
    )
    let lower = linePrefix.trimmingCharacters(in: .whitespaces).lowercased()
    isImportPath =
      lower.range(
        of: #"^(?:#\s*include|#\s*import|import|from|use|require|package|mod)\b"#,
        options: .regularExpression
      ) != nil
  }
}

private enum CompletionCandidateOrigin {
  case currentDocument
  case workspace(String)
  case external(package: String, file: String)
  case keyword

  var detail: String {
    switch self {
    case .currentDocument: return "Current document"
    case .workspace(let fileName): return "Project • \(fileName)"
    case .external(let package, let file): return "Library • \(package) • \(file)"
    case .keyword: return "Language keyword"
    }
  }

  var baseScore: Int {
    switch self {
    case .currentDocument: return 500
    case .workspace: return 260
    case .external: return 185
    case .keyword: return 80
    }
  }
}

private struct CompletionCandidate {
  var name: String
  var insertion: String
  var format: InsertTextFormat
  var kind: CompletionKind
  var score: Int
  var occurrences: Int
  var detail: String
}

private struct CompletionCandidateAccumulator {
  let prefix: String
  let languageID: String
  let limit: Int
  private var candidates: [String: CompletionCandidate] = [:]

  init(prefix: String, languageID: String, limit: Int) {
    self.prefix = prefix
    self.languageID = languageID.lowercased()
    self.limit = max(1, limit)
  }

  mutating func consume(
    text: String,
    origin: CompletionCandidateOrigin,
    caretUTF16Offset: Int?
  ) {
    for token in IdentifierScanner.scan(text, languageID: languageID) {
      guard token.value != prefix,
        let matchScore = CompletionNameMatcher.score(token.value, prefix: prefix)
      else { continue }
      let kind = DeclarationClassifier.kind(
        for: token,
        in: text,
        languageID: languageID
      )
      var score = origin.baseScore + matchScore + kindBonus(kind)
      if let caretUTF16Offset {
        score += proximityBonus(token.range.location, caret: caretUTF16Offset)
      }
      merge(
        name: token.value,
        insertion: token.value,
        format: .plainText,
        kind: kind,
        score: score,
        detail: origin.detail
      )
    }
  }

  mutating func consumeFunctionParameters(_ parameters: [String]) {
    for parameter in parameters {
      guard parameter != prefix,
        let matchScore = CompletionNameMatcher.score(parameter, prefix: prefix)
      else { continue }
      merge(
        name: parameter,
        insertion: parameter,
        format: .plainText,
        kind: .variable,
        score: 1_100 + matchScore,
        detail: "Function parameter"
      )
    }
  }

  mutating func consumeScopedCandidates(
    _ values: [CompletionScopedCandidate],
    scoreBonus: Int
  ) {
    for value in values {
      guard value.name != prefix,
        let matchScore = CompletionNameMatcher.score(value.name, prefix: prefix)
      else { continue }
      merge(
        name: value.name,
        insertion: value.insertion,
        format: .plainText,
        kind: value.kind,
        score: scoreBonus + matchScore + kindBonus(value.kind),
        detail: value.detail
      )
    }
  }

  mutating func consumeMemberSymbols(
    _ symbols: [ProjectCompletionSymbol],
    context: CompletionMemberAccessContext,
    currentURI: URL
  ) {
    let owners = Set(context.ownerTypes.map { $0.lowercased() })
    for symbol in symbols {
      guard let owner = symbol.ownerType?.lowercased(), owners.contains(owner) else { continue }
      if context.staticAccess == true,
        !symbol.isStatic,
        symbol.kind != .enumMember,
        symbol.kind != .constructor
      {
        continue
      }
      if context.staticAccess == false,
        symbol.isStatic || symbol.kind == .enumMember || symbol.kind == .constructor
      {
        continue
      }
      guard symbol.name != prefix,
        let matchScore = CompletionNameMatcher.score(symbol.name, prefix: prefix)
      else { continue }

      var score =
        1_650 + matchScore + kindBonus(symbol.kind) + memberKindBonus(symbol.kind)
        + min(80, symbol.occurrences * 5)
      if symbol.url.standardizedFileURL == currentURI.standardizedFileURL { score += 240 }
      if symbol.ownerType?.caseInsensitiveCompare(context.ownerTypes.first ?? "") == .orderedSame {
        score += 80
      }
      merge(
        name: symbol.name,
        insertion: symbol.insertion,
        format: symbol.format,
        kind: symbol.kind,
        score: score,
        detail: memberDetail(
          symbol,
          externalPrefix: symbol.isExternal
            ? "Library member • \(symbol.packageName ?? symbol.fileName)"
            : "Member",
          fallbackOwner: context.receiver
        ),
        identity: symbol.signature
      )
    }
  }

  mutating func consumeFallbackMemberSymbols(
    _ symbols: [ProjectCompletionSymbol],
    context: CompletionMemberAccessContext
  ) {
    for symbol in symbols where symbol.ownerType != nil {
      if context.staticAccess == true,
        !symbol.isStatic,
        symbol.kind != .enumMember,
        symbol.kind != .constructor
      {
        continue
      }
      if context.staticAccess == false,
        symbol.isStatic || symbol.kind == .enumMember || symbol.kind == .constructor
      {
        continue
      }
      guard symbol.name != prefix,
        let matchScore = CompletionNameMatcher.score(symbol.name, prefix: prefix)
      else { continue }
      merge(
        name: symbol.name,
        insertion: symbol.insertion,
        format: symbol.format,
        kind: symbol.kind,
        score: 320 + matchScore + kindBonus(symbol.kind) + memberKindBonus(symbol.kind)
          + min(40, symbol.occurrences * 3),
        detail: memberDetail(
          symbol,
          externalPrefix: symbol.isExternal
            ? "Library member • \(symbol.packageName ?? symbol.fileName)"
            : "Project member",
          fallbackOwner: symbol.fileName
        ),
        identity: symbol.signature
      )
    }
  }

  mutating func consumeInitializerMembers(
    _ symbols: [ProjectCompletionSymbol],
    context: CompletionInitializerContext,
    visibleBindings: [CompletionVisibleBinding],
    strategy: any CompletionLanguageStrategy
  ) {
    let owner = context.typeName.lowercased()
    var bindingsByName: [String: CompletionVisibleBinding] = [:]
    for binding in visibleBindings {
      // Later declarations shadow earlier ones. Avoid Dictionary(uniqueKeysWithValues:)
      // because shadowed bindings are valid source code and must not crash completion.
      bindingsByName[
        CompletionLanguageIdentity.normalizedIdentifier(binding.name, languageID: languageID)
      ] = binding
    }
    for symbol in symbols {
      guard let symbolOwner = symbol.ownerType?.lowercased(), symbolOwner == owner,
        symbol.kind == .field || symbol.kind == .property,
        !context.usedMembers.contains(symbol.name.lowercased()),
        let matchScore = CompletionNameMatcher.score(symbol.name, prefix: prefix)
      else { continue }

      let exactBinding = bindingsByName[
        CompletionLanguageIdentity.normalizedIdentifier(symbol.name, languageID: languageID)
      ]
      // Exported Go fields commonly use `Name` while the local binding is `name`. Keep
      // candidate identities case-sensitive, but allow a type-compatible case-insensitive
      // shorthand when constructing an object. Exact spelling always wins.
      let binding =
        exactBinding
        ?? visibleBindings.first { candidate in
          candidate.name.caseInsensitiveCompare(symbol.name) == .orderedSame
            && (symbol.typeName == nil || candidate.typeName == nil
              || strategy.typesAreCompatible(symbol.typeName, candidate.typeName))
        }
      let compatibleBinding = binding.flatMap { candidate -> CompletionVisibleBinding? in
        guard
          symbol.typeName == nil || candidate.typeName == nil
            || strategy.typesAreCompatible(symbol.typeName, candidate.typeName)
        else { return nil }
        return candidate
      }
      let expression =
        compatibleBinding?.name
        ?? strategy.defaultExpression(for: symbol.typeName)
      let insertion = strategy.initializerInsertion(
        memberName: symbol.name,
        defaultExpression: expression
      )
      var score = 2_300 + matchScore + kindBonus(symbol.kind)
      if compatibleBinding != nil { score += 420 }
      if symbol.typeName != nil { score += 80 }
      if symbol.isExternal { score += 35 }
      merge(
        name: symbol.name,
        insertion: insertion,
        format: insertion.contains("${") ? .snippet : .plainText,
        kind: symbol.kind,
        score: score,
        detail: symbol.isExternal
          ? "Library initializer member • \(symbol.packageName ?? symbol.fileName) • \(symbol.typeName ?? "inferred")"
          : "Initializer member • \(context.typeName) • \(symbol.typeName ?? "inferred")"
      )
    }
  }

  mutating func consumeInitializerValues(
    _ bindings: [CompletionVisibleBinding],
    memberName: String,
    memberType: String?,
    strategy: any CompletionLanguageStrategy
  ) {
    for binding in bindings {
      guard binding.name != prefix,
        let matchScore = CompletionNameMatcher.score(binding.name, prefix: prefix)
      else { continue }
      let nameMatches = binding.name.caseInsensitiveCompare(memberName) == .orderedSame
      let typeMatches = strategy.typesAreCompatible(binding.typeName, memberType)
      var score = 1_300 + matchScore
      if nameMatches { score += 780 }
      if typeMatches { score += 920 }
      if nameMatches && typeMatches { score += 340 }
      merge(
        name: binding.name,
        insertion: binding.name,
        format: .plainText,
        kind: .variable,
        score: score,
        detail: typeMatches
          ? "Compatible value • \(binding.typeName ?? memberType ?? "inferred")"
          : "Visible value"
      )
    }

    let expression = strategy.defaultExpression(for: memberType)
    guard !expression.isEmpty,
      let matchScore = CompletionNameMatcher.score(expression, prefix: prefix)
        ?? (prefix.isEmpty ? 0 : nil)
    else { return }
    merge(
      name: expression,
      insertion: expression,
      format: expression.contains("${") ? .snippet : .plainText,
      kind: .value,
      score: 1_050 + matchScore,
      detail: "Default value • \(memberType ?? "inferred type")"
    )
  }

  mutating func consumeProjectSymbols(
    _ symbols: [ProjectCompletionSymbol],
    currentDirectory: URL,
    currentFileStem: String,
    importedText: String,
    currentDocument: Bool = false
  ) {
    for symbol in symbols {
      guard symbol.name != prefix,
        let matchScore = CompletionNameMatcher.score(symbol.name, prefix: prefix)
      else { continue }
      let origin: CompletionCandidateOrigin
      if currentDocument {
        origin = .currentDocument
      } else if symbol.isExternal {
        origin = .external(package: symbol.packageName ?? "External", file: symbol.fileName)
      } else {
        origin = .workspace(symbol.fileName)
      }
      var score =
        origin.baseScore + matchScore + kindBonus(symbol.kind)
        + min(60, symbol.occurrences * 4)
      if symbol.url.deletingLastPathComponent().standardizedFileURL == currentDirectory {
        score += 90
      }
      let stem = symbol.url.deletingPathExtension().lastPathComponent.lowercased()
      if !stem.isEmpty && importedText.lowercased().contains(stem) { score += 120 }
      if stem.caseInsensitiveCompare(currentFileStem) == .orderedSame { score += 150 }
      if symbol.isExternal, let package = symbol.packageName?.lowercased(),
        importedText.lowercased().contains(package)
      {
        score += 280
      }
      if symbol.fileRole == .header || symbol.fileRole == .interface { score += 45 }
      if symbol.ownerType != nil { score += 35 }
      let detail: String
      if currentDocument, let owner = symbol.ownerType {
        detail = projectDetail(prefix: "Current document", symbol: symbol, owner: owner)
      } else if currentDocument {
        detail = projectDetail(
          prefix: CompletionCandidateOrigin.currentDocument.detail,
          symbol: symbol,
          owner: nil
        )
      } else if symbol.isExternal, let owner = symbol.ownerType {
        detail = projectDetail(
          prefix: "Library • \(symbol.packageName ?? "External")",
          symbol: symbol,
          owner: owner
        )
      } else if symbol.isExternal {
        detail = projectDetail(
          prefix: "Library • \(symbol.packageName ?? "External") • \(symbol.fileName)",
          symbol: symbol,
          owner: nil
        )
      } else if let owner = symbol.ownerType {
        detail = projectDetail(prefix: "Project • \(symbol.fileName)", symbol: symbol, owner: owner)
      } else {
        detail = projectDetail(prefix: "Project • \(symbol.fileName)", symbol: symbol, owner: nil)
      }
      merge(
        name: symbol.name,
        insertion: symbol.insertion,
        format: symbol.format,
        kind: symbol.kind,
        score: score,
        detail: detail,
        identity: symbol.signature
      )
    }
  }

  mutating func consumeProjectFiles(
    _ files: [SourceCodeFile],
    externalFiles: [ExternalIndexedSourceFile],
    currentURI: URL,
    linePrefix: String
  ) {
    let currentDirectory = currentURI.deletingLastPathComponent().standardizedFileURL
    let currentStem = currentURI.deletingPathExtension().lastPathComponent.lowercased()
    let quoted = linePrefix.contains("\"") || linePrefix.contains("'")
    let indexedFiles =
      files.map { (file: $0, packageName: Optional<String>.none) }
      + externalFiles.map { (file: $0.file, packageName: Optional($0.packageName)) }
    for indexed in indexedFiles
    where indexed.file.url.standardizedFileURL != currentURI.standardizedFileURL {
      let file = indexed.file
      let role = CompletionSourceFileRole.classify(url: file.url, languageID: file.languageID)
      guard role == .header || role == .interface else { continue }
      let insertion: String
      if file.url.deletingLastPathComponent().standardizedFileURL == currentDirectory {
        insertion = file.name
      } else if let packageName = indexed.packageName {
        let virtualPrefix = "Libraries/\(packageName)/"
        insertion =
          file.relativePath.hasPrefix(virtualPrefix)
          ? String(file.relativePath.dropFirst(virtualPrefix.count))
          : file.name
      } else {
        insertion = file.relativePath
      }
      guard
        let matchScore = CompletionNameMatcher.score(insertion, prefix: prefix)
          ?? CompletionNameMatcher.score(file.name, prefix: prefix)
      else { continue }
      var score = 900 + matchScore
      if file.url.deletingLastPathComponent().standardizedFileURL == currentDirectory {
        score += 240
      }
      if file.stem.lowercased() == currentStem { score += 360 }
      if role == .header { score += 120 }
      if quoted { score += 40 }
      merge(
        name: insertion,
        insertion: insertion,
        format: .plainText,
        kind: .file,
        score: score,
        detail: indexed.packageName.map { "Library header • \($0) • \(file.name)" }
          ?? "Header • \(file.relativePath)"
      )
    }
  }

  mutating func consumeLanguageItems() {
    for item in LanguageCompletionCatalog.items(for: languageID) {
      guard item.label != prefix,
        let matchScore = CompletionNameMatcher.score(item.label, prefix: prefix)
      else { continue }
      merge(
        name: item.label,
        insertion: item.insertion,
        format: item.format,
        kind: item.kind,
        score: CompletionCandidateOrigin.keyword.baseScore + item.scoreBonus + matchScore
          + languageItemCategoryAdjustment(item.kind),
        detail: item.detail
      )
    }
  }

  func results() -> [Completion] {
    candidates.values
      .sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        if $0.occurrences != $1.occurrences { return $0.occurrences > $1.occurrences }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      .prefix(limit)
      .enumerated()
      .map { index, candidate in
        Completion(
          label: candidate.name,
          kind: candidate.kind,
          detail: candidate.detail,
          sortText: String(format: "%05d", index),
          filterText: candidate.name,
          insertText: candidate.insertion,
          insertTextFormat: candidate.format,
          serviceIdentifier: "editor-context"
        )
      }
  }

  private mutating func merge(
    name: String,
    insertion: String,
    format: InsertTextFormat,
    kind: CompletionKind,
    score: Int,
    detail: String,
    identity: String? = nil
  ) {
    let key = CompletionLanguageIdentity.candidateKey(
      name: name,
      insertion: insertion,
      kind: kind,
      languageID: languageID,
      declarationSignature: identity
    )
    if var existing = candidates[key] {
      existing.occurrences += 1
      let incomingIsMoreSpecific = kindSpecificity(kind) > kindSpecificity(existing.kind)
      let incomingIsStronger = score > existing.score
      if incomingIsMoreSpecific || incomingIsStronger {
        // Preserve the spelling supplied by the stronger semantic candidate. This matters for
        // case-sensitive languages such as Go, where a visible `name` binding may merge with an
        // exported `Name` field while retaining the field insertion.
        existing.name = name
        existing.kind = kind
        existing.detail = detail
        existing.insertion = insertion
        existing.format = format
      }
      existing.score = max(existing.score, score) + min(existing.occurrences, 20)
      if format == .snippet, existing.format == .plainText {
        existing.insertion = insertion
        existing.format = format
      }
      if detail == CompletionCandidateOrigin.currentDocument.detail,
        existing.detail.hasPrefix("Project •")
      {
        existing.detail = detail
      }
      candidates[key] = existing
    } else {
      candidates[key] = CompletionCandidate(
        name: name,
        insertion: insertion,
        format: format,
        kind: kind,
        score: score,
        occurrences: 1,
        detail: detail
      )
    }
  }

  private func kindSpecificity(_ kind: CompletionKind) -> Int {
    switch kind {
    case .method, .constructor, .property, .field, .enumMember: return 4
    case .function, .variable, .constant: return 3
    case .class, .interface, .enum, .struct, .typeParameter: return 2
    case .keyword, .snippet: return 1
    default: return 0
    }
  }

  private func proximityBonus(_ location: Int, caret: Int) -> Int {
    let distance = abs(location - caret)
    switch distance {
    case 0..<80: return 180
    case 80..<400: return 120
    case 400..<2_000: return 70
    case 2_000..<10_000: return 30
    default: return 0
    }
  }

  private func kindBonus(_ kind: CompletionKind) -> Int {
    switch kind {
    case .method: return 180
    case .function, .constructor: return 110
    case .variable, .field, .property, .constant: return 35
    case .class, .interface, .enum, .struct, .typeParameter: return 5
    default: return 0
    }
  }

  private func memberKindBonus(_ kind: CompletionKind) -> Int {
    switch kind {
    case .method: return 420
    case .function, .constructor: return 220
    case .property, .field: return 40
    case .keyword, .snippet, .module, .file, .folder: return -240
    default: return 0
    }
  }

  private func memberDetail(
    _ symbol: ProjectCompletionSymbol,
    externalPrefix: String,
    fallbackOwner: String
  ) -> String {
    var parts = [externalPrefix, symbol.ownerType ?? fallbackOwner]
    if let declaration = symbol.signature, !declaration.isEmpty {
      parts.append("\(symbol.name)(\(declaration))")
    } else if let signature = CompletionLanguageIdentity.displaySignature(
      name: symbol.name,
      insertion: symbol.insertion
    ) {
      parts.append(signature)
    }
    if let typeName = symbol.typeName, !typeName.isEmpty {
      parts.append(
        CompletionLanguageIdentity.isCallable(symbol.kind) ? "-> \(typeName)" : ": \(typeName)")
    }
    return parts.joined(separator: " • ")
  }

  private func projectDetail(
    prefix: String,
    symbol: ProjectCompletionSymbol,
    owner: String?
  ) -> String {
    var parts = [prefix]
    if let owner, !owner.isEmpty { parts.append(owner) }
    if let declaration = symbol.signature, !declaration.isEmpty {
      parts.append("\(symbol.name)(\(declaration))")
    } else if let signature = CompletionLanguageIdentity.displaySignature(
      name: symbol.name,
      insertion: symbol.insertion
    ) {
      parts.append(signature)
    }
    if let typeName = symbol.typeName, !typeName.isEmpty {
      parts.append(
        CompletionLanguageIdentity.isCallable(symbol.kind) ? "-> \(typeName)" : ": \(typeName)")
    }
    return parts.joined(separator: " • ")
  }

  private func languageItemCategoryAdjustment(_ kind: CompletionKind) -> Int {
    kind == .keyword ? -40 : 0
  }
}

private enum CompletionImportContext {
  static func importText(in text: String, languageID: String) -> String {
    let prefixes: [String]
    switch languageID.lowercased() {
    case "swift": prefixes = ["import "]
    case "rust": prefixes = ["use ", "mod "]
    case "go": prefixes = ["import "]
    case "python": prefixes = ["import ", "from "]
    case "javascript", "javascriptreact", "typescript", "typescriptreact":
      prefixes = ["import ", "require("]
    case "java", "kotlin": prefixes = ["import ", "package "]
    default: prefixes = ["import ", "#include ", "#import ", "include ", "use "]
    }
    return text.split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { line in
        prefixes.contains { line.trimmingCharacters(in: .whitespaces).hasPrefix($0) }
      }
      .joined(separator: "\n")
  }
}

private struct ScannedIdentifier {
  let value: String
  let range: NSRange
}

private enum IdentifierScanner {
  private static let expression = try? NSRegularExpression(
    pattern: #"[\p{L}_][\p{L}\p{N}_]*"#
  )

  static func scan(_ text: String, languageID: String) -> [ScannedIdentifier] {
    guard let expression else { return [] }
    let searchable = CompletionCodeMask.maskedCode(text, languageID: languageID)
    let source = text as NSString
    return expression.matches(
      in: searchable,
      range: NSRange(location: 0, length: (searchable as NSString).length)
    ).map {
      ScannedIdentifier(value: source.substring(with: $0.range), range: $0.range)
    }
  }
}

private enum CompletionCodeMask {
  private enum State {
    case code
    case lineComment
    case blockComment
    case string(UInt16)
  }

  static func maskedCode(_ text: String, languageID: String) -> String {
    let source = text as NSString
    var output = [UInt16](repeating: 32, count: source.length)
    var state = State.code
    var index = 0
    let language = languageID.lowercased()
    let hashComments = ["python", "ruby", "shellscript", "shell", "bash", "zsh", "yaml", "toml"]
      .contains(language)
    let dashComments = ["sql", "lua", "haskell"].contains(language)
    let slashComments = ![
      "python", "ruby", "shellscript", "shell", "bash", "zsh", "sql", "yaml", "toml", "markdown",
    ]
    .contains(language)
    let backtickStrings = ["javascript", "javascriptreact", "typescript", "typescriptreact"]
      .contains(language)

    while index < source.length {
      let current = source.character(at: index)
      let next = index + 1 < source.length ? source.character(at: index + 1) : 0

      switch state {
      case .code:
        if isNewline(current) {
          output[index] = current
        } else if hashComments && current == 35 {
          state = .lineComment
        } else if dashComments && current == 45 && next == 45 {
          state = .lineComment
          index += 1
        } else if slashComments && current == 47 && next == 47 {
          state = .lineComment
          index += 1
        } else if slashComments && current == 47 && next == 42 {
          state = .blockComment
          index += 1
        } else if current == 34 || (current == 39 && hasClosingQuote(in: source, from: index))
          || (backtickStrings && current == 96)
        {
          state = .string(current)
        } else {
          output[index] = current
        }

      case .lineComment:
        if isNewline(current) {
          output[index] = current
          state = .code
        }

      case .blockComment:
        if isNewline(current) { output[index] = current }
        if current == 42 && next == 47 {
          index += 1
          state = .code
        }

      case .string(let quote):
        if isNewline(current) { output[index] = current }
        if current == 92 {
          if index + 1 < source.length {
            if isNewline(next) { output[index + 1] = next }
            index += 1
          }
        } else if current == quote {
          state = .code
        }
      }
      index += 1
    }

    return String(decoding: output, as: UTF16.self)
  }

  private static func hasClosingQuote(in source: NSString, from opening: Int) -> Bool {
    var index = opening + 1
    while index < source.length {
      let value = source.character(at: index)
      if isNewline(value) { return false }
      if value == 92 {
        index += 2
        continue
      }
      if value == 39 { return true }
      index += 1
    }
    return false
  }

  private static func isNewline(_ value: UInt16) -> Bool {
    value == 10 || value == 13
  }
}

private enum DeclarationClassifier {
  private static let declarationWords: [String: CompletionKind] = [
    "actor": .class, "class": .class, "enum": .enum, "interface": .interface,
    "protocol": .interface, "struct": .struct, "trait": .interface, "type": .typeParameter,
    "typealias": .typeParameter, "fn": .function, "func": .function, "function": .function,
    "def": .function, "fun": .function, "let": .variable, "var": .variable,
    "const": .constant, "static": .property, "field": .field,
  ]

  static func kind(
    for token: ScannedIdentifier,
    in text: String,
    languageID: String
  ) -> CompletionKind {
    let source = text as NSString
    let lookBehindStart = max(0, token.range.location - 48)
    let before = source.substring(
      with: NSRange(location: lookBehindStart, length: token.range.location - lookBehindStart)
    )
    if let word = IdentifierScanner.scan(before, languageID: languageID).last?.value.lowercased(),
      let kind = declarationWords[word]
    {
      return kind
    }
    let afterStart = NSMaxRange(token.range)
    let suffix: String
    if afterStart < source.length {
      let length = min(12, source.length - afterStart)
      suffix = source.substring(with: NSRange(location: afterStart, length: length))
    } else {
      suffix = ""
    }
    let isCall = suffix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("(")
    let trimmedBefore = before.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedBefore.hasSuffix(".") || trimmedBefore.hasSuffix("::")
      || trimmedBefore.hasSuffix("->")
    {
      return isCall ? .method : .property
    }
    if token.value.first?.isUppercase == true,
      typeNamesAreConventionallyUppercase(languageID)
    {
      return .class
    }
    if isCall { return .function }
    return .text
  }

  private static func typeNamesAreConventionallyUppercase(_ languageID: String) -> Bool {
    switch languageID.lowercased() {
    case "swift", "rust", "java", "kotlin", "csharp", "typescript", "typescriptreact",
      "javascript", "javascriptreact", "cpp", "c++", "objective-c", "objective-cpp", "zig":
      return true
    default:
      return false
    }
  }
}

private struct LanguageCompletionItem {
  var label: String
  var insertion: String
  var kind: CompletionKind
  var format: InsertTextFormat
  var scoreBonus: Int
  var detail: String

  static func keyword(_ value: String) -> Self {
    .init(
      label: value,
      insertion: value,
      kind: .keyword,
      format: .plainText,
      scoreBonus: 0,
      detail: "Language keyword"
    )
  }

  static func snippet(_ label: String, _ insertion: String, detail: String) -> Self {
    .init(
      label: label,
      insertion: insertion,
      kind: .snippet,
      format: .snippet,
      scoreBonus: 120,
      detail: detail
    )
  }
}

private enum LanguageCompletionCatalog {
  static func items(for languageID: String) -> [LanguageCompletionItem] {
    let normalized = aliases[languageID] ?? languageID
    let words = keywords[normalized, default: []].map(LanguageCompletionItem.keyword)
    return snippets[normalized, default: []] + words
  }

  private static let aliases: [String: String] = [
    "javascriptreact": "javascript",
    "typescriptreact": "typescript",
    "shellscript": "shell",
    "bash": "shell",
    "zsh": "shell",
    "c++": "cpp",
    "objective-c": "c",
    "objective-cpp": "cpp",
  ]

  private static let snippets: [String: [LanguageCompletionItem]] = [
    "swift": [
      .snippet(
        "func", "func ${1:name}(${2:parameters}) ${3:-> ${4:ReturnType} }{\n\t$0\n}",
        detail: "Function declaration"),
      .snippet("if", "if ${1:condition} {\n\t$0\n}", detail: "If statement"),
      .snippet("guard", "guard ${1:condition} else {\n\t$0\n}", detail: "Guard statement"),
      .snippet("for", "for ${1:item} in ${2:sequence} {\n\t$0\n}", detail: "For-in loop"),
      .snippet("struct", "struct ${1:Name} {\n\t$0\n}", detail: "Structure declaration"),
    ],
    "rust": [
      .snippet(
        "fn", "fn ${1:name}(${2:parameters})${3: -> ${4:ReturnType}} {\n\t$0\n}",
        detail: "Function declaration"),
      .snippet("if", "if ${1:condition} {\n\t$0\n}", detail: "If expression"),
      .snippet("match", "match ${1:value} {\n\t${2:pattern} => $0,\n}", detail: "Match expression"),
      .snippet("impl", "impl ${1:Type} {\n\t$0\n}", detail: "Implementation block"),
      .snippet(
        "struct", "struct ${1:Name} {\n\t${2:field}: ${3:Type},\n}", detail: "Structure declaration"
      ),
    ],
    "go": [
      .snippet(
        "func", "func ${1:name}(${2:parameters}) ${3:ReturnType} {\n\t$0\n}",
        detail: "Function declaration"),
      .snippet("if", "if ${1:condition} {\n\t$0\n}", detail: "If statement"),
      .snippet("for", "for ${1:condition} {\n\t$0\n}", detail: "For loop"),
      .snippet(
        "switch", "switch ${1:value} {\ncase ${2:pattern}:\n\t$0\n}", detail: "Switch statement"),
    ],
    "java": [
      .snippet("class", "class ${1:Name} {\n\t$0\n}", detail: "Class declaration"),
      .snippet(
        "method", "${1:public} ${2:void} ${3:name}(${4:parameters}) {\n\t$0\n}",
        detail: "Method declaration"),
      .snippet("if", "if (${1:condition}) {\n\t$0\n}", detail: "If statement"),
      .snippet("for", "for (${1:item} : ${2:items}) {\n\t$0\n}", detail: "Enhanced for loop"),
    ],
    "kotlin": [
      .snippet(
        "fun", "fun ${1:name}(${2:parameters})${3:: ${4:ReturnType}} {\n\t$0\n}",
        detail: "Function declaration"),
      .snippet("if", "if (${1:condition}) {\n\t$0\n}", detail: "If expression"),
      .snippet("when", "when (${1:value}) {\n\t${2:condition} -> $0\n}", detail: "When expression"),
      .snippet("class", "class ${1:Name} {\n\t$0\n}", detail: "Class declaration"),
    ],
    "javascript": [
      .snippet(
        "function", "function ${1:name}(${2:parameters}) {\n\t$0\n}", detail: "Function declaration"
      ),
      .snippet("const", "const ${1:name} = ${0:value};", detail: "Constant declaration"),
      .snippet("if", "if (${1:condition}) {\n\t$0\n}", detail: "If statement"),
      .snippet("for", "for (const ${1:item} of ${2:items}) {\n\t$0\n}", detail: "For-of loop"),
    ],
    "typescript": [
      .snippet(
        "function", "function ${1:name}(${2:parameters}): ${3:ReturnType} {\n\t$0\n}",
        detail: "Typed function declaration"),
      .snippet(
        "interface", "interface ${1:Name} {\n\t${2:property}: ${3:Type};\n}",
        detail: "Interface declaration"),
      .snippet("type", "type ${1:Name} = ${0:Type};", detail: "Type alias"),
      .snippet("if", "if (${1:condition}) {\n\t$0\n}", detail: "If statement"),
    ],
    "python": [
      .snippet("def", "def ${1:name}(${2:parameters}):\n\t$0", detail: "Function declaration"),
      .snippet("class", "class ${1:Name}:\n\t$0", detail: "Class declaration"),
      .snippet("if", "if ${1:condition}:\n\t$0", detail: "If statement"),
      .snippet("for", "for ${1:item} in ${2:items}:\n\t$0", detail: "For loop"),
      .snippet(
        "try", "try:\n\t$1\nexcept ${2:Exception} as ${3:error}:\n\t$0", detail: "Try/except block"),
    ],
    "zig": [
      .snippet(
        "fn", "fn ${1:name}(${2:parameters}) ${3:ReturnType} {\n\t$0\n}",
        detail: "Function declaration"),
      .snippet("const", "const ${1:name}: ${2:Type} = ${0:value};", detail: "Constant declaration"),
      .snippet("if", "if (${1:condition}) {\n\t$0\n}", detail: "If expression"),
      .snippet("struct", "const ${1:Name} = struct {\n\t$0\n};", detail: "Structure declaration"),
    ],
  ]

  private static let keywords: [String: [String]] = [
    "swift": [
      "actor", "any", "associatedtype", "async", "await", "break", "case", "catch", "class",
      "continue", "defer", "deinit", "do", "else", "enum", "extension", "false", "for", "func",
      "guard", "if", "import", "init", "inout", "let", "macro", "nil", "protocol", "repeat",
      "return", "self", "some", "static", "struct", "subscript", "switch", "throw", "throws",
      "true", "try", "typealias", "var", "where", "while",
    ],
    "rust": [
      "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
      "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
      "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "trait",
      "true", "type", "unsafe", "use", "where", "while",
    ],
    "go": [
      "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
      "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
      "return", "select", "struct", "switch", "type", "var",
    ],
    "java": [
      "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class",
      "const", "continue", "default", "do", "double", "else", "enum", "extends", "final",
      "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface",
      "long", "native", "new", "package", "private", "protected", "public", "record", "return",
      "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws",
      "transient", "try", "void", "volatile", "while",
    ],
    "kotlin": [
      "as", "break", "class", "continue", "data", "do", "else", "enum", "false", "for", "fun",
      "if", "in", "interface", "is", "null", "object", "override", "package", "return", "sealed",
      "super", "suspend", "this", "throw", "true", "try", "typealias", "val", "var", "when",
      "while",
    ],
    "javascript": [
      "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
      "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "function",
      "if", "import", "in", "instanceof", "let", "new", "null", "return", "static", "super",
      "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "yield",
    ],
    "typescript": [
      "abstract", "any", "as", "async", "await", "boolean", "break", "case", "catch", "class",
      "const", "continue", "declare", "default", "else", "enum", "export", "extends", "false",
      "for", "function", "if", "implements", "import", "in", "infer", "interface", "keyof", "let",
      "namespace", "never", "new", "null", "number", "object", "override", "private", "protected",
      "public", "readonly", "return", "satisfies", "static", "string", "super", "switch", "this",
      "throw", "true", "try", "type", "typeof", "undefined", "unknown", "var", "void", "while",
    ],
    "python": [
      "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class",
      "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global",
      "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise",
      "return", "try", "while", "with", "yield",
    ],
    "zig": [
      "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await", "break",
      "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error",
      "export", "extern", "false", "fn", "for", "if", "inline", "noalias", "nosuspend", "null",
      "opaque", "or", "orelse", "packed", "pub", "resume", "return", "struct", "suspend", "switch",
      "test", "threadlocal", "true", "try", "undefined", "union", "unreachable", "usingnamespace",
      "var", "volatile", "while",
    ],
    "c": [
      "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
      "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register",
      "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
      "union", "unsigned", "void", "volatile", "while",
    ],
    "cpp": [
      "alignas", "alignof", "auto", "bool", "break", "case", "catch", "class", "concept", "const",
      "constexpr", "continue", "co_await", "co_return", "co_yield", "decltype", "default", "delete",
      "do", "double", "else", "enum", "explicit", "export", "extern", "false", "float", "for",
      "friend", "if", "import", "inline", "int", "long", "module", "mutable", "namespace", "new",
      "noexcept", "nullptr", "operator", "private", "protected", "public", "requires", "return",
      "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw",
      "true",
      "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile",
      "while",
    ],
    "shell": [
      "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select",
      "then", "time", "until", "while",
    ],
    "sql": [
      "ALTER", "AND", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE", "CREATE", "DELETE", "DESC",
      "DISTINCT", "DROP", "ELSE", "END", "FROM", "GROUP", "HAVING", "IN", "INNER", "INSERT",
      "INTO", "IS", "JOIN", "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "OUTER",
      "RIGHT", "SELECT", "SET", "TABLE", "THEN", "UNION", "UPDATE", "VALUES", "WHEN", "WHERE",
    ],
  ]
}
