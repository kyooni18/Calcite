import EditorCore
import EditorWorkspace
import Foundation

struct ProjectCompletionSymbol: Sendable {
  var name: String
  var insertion: String
  var format: InsertTextFormat
  var kind: CompletionKind
  var fileName: String
  var url: URL
  var occurrences: Int
  var ownerType: String?
  var isStatic: Bool
  var isDeclaration: Bool
  var fileRole: CompletionSourceFileRole
  var isExternal: Bool = false
  var packageName: String? = nil
  var typeName: String? = nil
  /// Raw parameter declaration used to distinguish overloads whose insertion snippets
  /// have the same placeholder names.
  var signature: String? = nil
}

struct ProjectCompletionIndex: Sendable {
  private struct Entry: Sendable {
    var contentHash: UInt64
    var languageID: String
    var isExternal: Bool
    var packageName: String?
    var symbols: [ProjectCompletionSymbol]
  }

  private var entries: [URL: Entry] = [:]
  private var externalURLs: Set<URL> = []
  private var externalGeneration: Int?

  mutating func update(
    workspaceFiles: [SourceCodeFile],
    externalFiles: [ExternalIndexedSourceFile] = [],
    externalGeneration nextExternalGeneration: Int = 0
  ) {
    let workspaceURLs = Set(workspaceFiles.map { $0.url.standardizedFileURL })
    let externalChanged = externalGeneration != nextExternalGeneration
    if externalChanged {
      externalURLs = Set(externalFiles.map { $0.file.url.standardizedFileURL })
      externalGeneration = nextExternalGeneration
    }
    let liveURLs = workspaceURLs.union(externalURLs)
    entries = entries.filter { liveURLs.contains($0.key) }

    for file in workspaceFiles {
      update(file, isExternal: false, packageName: nil)
    }
    if externalChanged {
      for external in externalFiles {
        update(external.file, isExternal: true, packageName: external.packageName)
      }
    }
  }

  private mutating func update(
    _ file: SourceCodeFile,
    isExternal: Bool,
    packageName: String?
  ) {
    let key = file.url.standardizedFileURL
    let hash = file.diskFingerprint?.contentHash ?? Self.contentHash(file.content)
    if let existing = entries[key],
      existing.contentHash == hash,
      existing.languageID == file.languageID,
      existing.isExternal == isExternal,
      existing.packageName == packageName
    {
      return
    }
    entries[key] = Entry(
      contentHash: hash,
      languageID: file.languageID,
      isExternal: isExternal,
      packageName: packageName,
      symbols: ProjectDeclarationScanner.scan(
        file,
        isExternal: isExternal,
        packageName: packageName
      )
    )
  }

  private static func contentHash(_ content: String) -> UInt64 {
    content.utf8.reduce(1_469_598_103_934_665_603) { hash, byte in
      (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
  }

  func symbols(languageID: String, excluding url: URL? = nil) -> [ProjectCompletionSymbol] {
    let key = CompletionStructuralAnalysis.normalizedLanguage(languageID)
    let excluded = url?.standardizedFileURL
    return entries.values
      .filter { entry in
        let entryLanguage = CompletionStructuralAnalysis.normalizedLanguage(entry.languageID)
        return entryLanguage == key
          || (entry.isExternal && Self.externalLanguage(entryLanguage, isCompatibleWith: key))
      }
      .flatMap(\.symbols)
      .filter { symbol in
        guard let excluded else { return true }
        return symbol.url.standardizedFileURL != excluded
      }
  }
  private static func externalLanguage(_ source: String, isCompatibleWith target: String) -> Bool {
    let groups: [Set<String>] = [
      ["c", "cpp", "swift"],
      ["javascript", "typescript"],
      ["java", "kotlin"],
      ["shell", "fish"],
    ]
    return groups.contains { $0.contains(source) && $0.contains(target) }
  }

}

enum ProjectDeclarationScanner {
  private struct Pattern {
    var expression: NSRegularExpression?
    var kind: CompletionKind
    var nameGroup: Int
    var parameterGroup: Int?
    var explicitOwnerGroup: Int?
    var requiresTypeScope: Bool
    var typeGroup: Int? = nil
  }

  static func scan(
    _ file: SourceCodeFile,
    isExternal: Bool = false,
    packageName: String? = nil
  ) -> [ProjectCompletionSymbol] {
    scan(
      text: file.content,
      languageID: file.languageID,
      fileName: file.name,
      url: file.url,
      isExternal: isExternal,
      packageName: packageName
    )
  }

  static func scan(
    text: String,
    languageID: String,
    fileName: String,
    url: URL,
    isExternal: Bool = false,
    packageName: String? = nil
  ) -> [ProjectCompletionSymbol] {
    let language = CompletionStructuralAnalysis.normalizedLanguage(languageID)
    let code = CompletionProjectCodeMask.maskedCode(text, languageID: language)
    let source = text as NSString
    let typeScopes = CompletionStructuralAnalysis.typeScopes(in: text, languageID: language)
    let fileRole = CompletionSourceFileRole.classify(url: url, languageID: language)
    var grouped: [String: ProjectCompletionSymbol] = [:]

    for pattern in patterns(for: language) {
      guard let expression = pattern.expression else { continue }
      let range = NSRange(location: 0, length: (code as NSString).length)
      for match in expression.matches(in: code, range: range) {
        guard match.numberOfRanges > pattern.nameGroup,
          match.range(at: pattern.nameGroup).location != NSNotFound
        else { continue }
        let name = source.substring(with: match.range(at: pattern.nameGroup))
        guard isUsefulIdentifier(name) else { continue }
        if shouldSkipValueDeclaration(
          kind: pattern.kind,
          language: language,
          matchRange: match.range,
          code: code
        ) {
          continue
        }

        let explicitOwner: String?
        if let group = pattern.explicitOwnerGroup, match.numberOfRanges > group,
          match.range(at: group).location != NSNotFound
        {
          explicitOwner = source.substring(with: match.range(at: group))
        } else {
          explicitOwner = nil
        }
        let enclosing = CompletionStructuralAnalysis.enclosingType(
          at: match.range.location,
          in: typeScopes
        )
        let owner = explicitOwner ?? enclosing?.name
        if pattern.requiresTypeScope, owner == nil { continue }
        if explicitOwner == nil {
          if let enclosing,
            [.function, .variable, .constant].contains(pattern.kind),
            !isDirectTypeMember(
              at: match.range.location,
              in: enclosing,
              code: code,
              language: language
            )
          {
            continue
          }
          if enclosing == nil,
            [.variable, .constant].contains(pattern.kind),
            braceDepth(at: match.range.location, in: code) > 0
          {
            continue
          }
        }

        let parameters: String?
        if let group = pattern.parameterGroup, match.numberOfRanges > group,
          match.range(at: group).location != NSNotFound
        {
          let capturedRange = match.range(at: group)
          let opening = max(0, capturedRange.location - 1)
          if source.character(at: opening) == 40,
            let closing = matchingParenthesis(in: source, openingAt: opening)
          {
            parameters = source.substring(
              with: NSRange(location: opening + 1, length: closing - opening - 1)
            )
          } else {
            parameters = source.substring(with: capturedRange)
          }
        } else {
          parameters = nil
        }

        let declaredType: String?
        if let group = pattern.typeGroup, match.numberOfRanges > group,
          match.range(at: group).location != NSNotFound
        {
          declaredType = source.substring(with: match.range(at: group))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } else {
          declaredType = nil
        }

        let kind = resolvedKind(
          pattern.kind,
          name: name,
          owner: owner,
          language: language
        )
        let insertion = parameters.map {
          callSnippet(name: name, parameters: $0, language: language)
        }
        let declarationText = source.substring(with: match.range)
        let isStatic = staticDeclaration(
          declarationText,
          parameters: parameters,
          language: language,
          owner: owner
        )
        let isDeclaration = declarationOnly(
          declarationText,
          fileRole: fileRole,
          kind: kind
        )
        let symbolInsertion = insertion ?? name
        let key = CompletionLanguageIdentity.projectSymbolKey(
          owner: owner,
          name: name,
          kind: kind,
          isStatic: isStatic,
          insertion: symbolInsertion,
          languageID: language,
          declarationSignature: parameters
        )
        if var existing = grouped[key] {
          existing.occurrences += 1
          existing.isDeclaration = existing.isDeclaration && isDeclaration
          existing.typeName = existing.typeName ?? declaredType
          existing.signature = existing.signature ?? parameters
          grouped[key] = existing
        } else {
          grouped[key] = ProjectCompletionSymbol(
            name: name,
            insertion: symbolInsertion,
            format: insertion == nil ? .plainText : .snippet,
            kind: kind,
            fileName: fileName,
            url: url,
            occurrences: 1,
            ownerType: owner,
            isStatic: isStatic,
            isDeclaration: isDeclaration,
            fileRole: fileRole,
            isExternal: isExternal,
            packageName: packageName,
            typeName: declaredType,
            signature: parameters
          )
        }
      }
    }

    for symbol in enumMemberSymbols(
      code: code,
      source: source,
      language: language,
      typeScopes: typeScopes,
      fileName: fileName,
      url: url,
      fileRole: fileRole,
      isExternal: isExternal,
      packageName: packageName
    ) {
      let key = CompletionLanguageIdentity.projectSymbolKey(
        owner: symbol.ownerType,
        name: symbol.name,
        kind: symbol.kind,
        isStatic: symbol.isStatic,
        insertion: symbol.insertion,
        languageID: language
      )
      if var existing = grouped[key] {
        existing.occurrences += symbol.occurrences
        grouped[key] = existing
      } else {
        grouped[key] = symbol
      }
    }

    for symbol in supplementalSymbols(
      text: text,
      language: language,
      fileName: fileName,
      url: url,
      fileRole: fileRole,
      isExternal: isExternal,
      packageName: packageName
    ) {
      let key = CompletionLanguageIdentity.projectSymbolKey(
        owner: symbol.ownerType,
        name: symbol.name,
        kind: symbol.kind,
        isStatic: symbol.isStatic,
        insertion: symbol.insertion,
        languageID: language
      )
      if var existing = grouped[key] {
        existing.occurrences += symbol.occurrences
        existing.typeName = existing.typeName ?? symbol.typeName
        existing.signature = existing.signature ?? symbol.signature
        grouped[key] = existing
      } else {
        grouped[key] = symbol
      }
    }

    return Array(grouped.values).sorted {
      if $0.ownerType != $1.ownerType { return ($0.ownerType ?? "") < ($1.ownerType ?? "") }
      if $0.name != $1.name {
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      if $0.kind != $1.kind {
        return CompletionLanguageIdentity.isCallable($0.kind)
          && !CompletionLanguageIdentity.isCallable($1.kind)
      }
      if $0.insertion != $1.insertion {
        return $0.insertion.localizedStandardCompare($1.insertion) == .orderedAscending
      }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private static func supplementalSymbols(
    text: String,
    language: String,
    fileName: String,
    url: URL,
    fileRole: CompletionSourceFileRole,
    isExternal: Bool,
    packageName: String?
  ) -> [ProjectCompletionSymbol] {
    switch language {
    case "go":
      return goStructFieldSymbols(
        text: text,
        fileName: fileName,
        url: url,
        fileRole: fileRole,
        isExternal: isExternal,
        packageName: packageName
      )
    case "lua":
      return luaAnnotatedSymbols(
        text: text,
        fileName: fileName,
        url: url,
        fileRole: fileRole,
        isExternal: isExternal,
        packageName: packageName
      )
    default:
      return []
    }
  }

  private static func goStructFieldSymbols(
    text: String,
    fileName: String,
    url: URL,
    fileRole: CompletionSourceFileRole,
    isExternal: Bool,
    packageName: String?
  ) -> [ProjectCompletionSymbol] {
    let source = text as NSString
    let typePattern = #"\btype\s+([\p{L}_][\p{L}\p{N}_]*)\s+struct\s*\{"#
    guard let typeRegex = try? NSRegularExpression(pattern: typePattern),
      let fieldRegex = try? NSRegularExpression(
        pattern: #"(?m)(?:^|[;\n])\s*([\p{L}_][\p{L}\p{N}_]*)\s+([^;\n}`]+)(?:`[^`]*`)?"#
      )
    else { return [] }

    var symbols: [ProjectCompletionSymbol] = []
    for match in typeRegex.matches(
      in: text,
      range: NSRange(location: 0, length: source.length)
    ) {
      guard match.range(at: 1).location != NSNotFound else { continue }
      let owner = source.substring(with: match.range(at: 1))
      let opening = NSMaxRange(match.range) - 1
      guard let closing = matchingCurlyBrace(in: source, openingAt: opening) else { continue }
      let bodyRange = NSRange(location: opening + 1, length: max(0, closing - opening - 1))
      let body = source.substring(with: bodyRange)
      let bodySource = body as NSString
      for field in fieldRegex.matches(
        in: body,
        range: NSRange(location: 0, length: bodySource.length)
      ) {
        guard field.range(at: 1).location != NSNotFound,
          field.range(at: 2).location != NSNotFound
        else { continue }
        let name = bodySource.substring(with: field.range(at: 1))
        let type = bodySource.substring(with: field.range(at: 2))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsefulIdentifier(name) else { continue }
        symbols.append(
          ProjectCompletionSymbol(
            name: name,
            insertion: name,
            format: .plainText,
            kind: .field,
            fileName: fileName,
            url: url,
            occurrences: 1,
            ownerType: owner,
            isStatic: false,
            isDeclaration: true,
            fileRole: fileRole,
            isExternal: isExternal,
            packageName: packageName,
            typeName: type
          )
        )
      }
    }
    return symbols
  }

  private static func luaAnnotatedSymbols(
    text: String,
    fileName: String,
    url: URL,
    fileRole: CompletionSourceFileRole,
    isExternal: Bool,
    packageName: String?
  ) -> [ProjectCompletionSymbol] {
    let source = text as NSString
    var symbols: [ProjectCompletionSymbol] = []

    let classPattern = #"(?m)^\s*---@class\s+([\p{L}_][\p{L}\p{N}_.]*)"#
    if let classRegex = try? NSRegularExpression(pattern: classPattern) {
      let matches = classRegex.matches(
        in: text,
        range: NSRange(location: 0, length: source.length)
      )
      for (index, match) in matches.enumerated() {
        guard match.range(at: 1).location != NSNotFound else { continue }
        let rawOwner = source.substring(with: match.range(at: 1))
        let owner = rawOwner.split(separator: ".").last.map(String.init) ?? rawOwner
        symbols.append(
          ProjectCompletionSymbol(
            name: owner,
            insertion: owner,
            format: .plainText,
            kind: .class,
            fileName: fileName,
            url: url,
            occurrences: 1,
            ownerType: nil,
            isStatic: true,
            isDeclaration: true,
            fileRole: fileRole,
            isExternal: isExternal,
            packageName: packageName,
            typeName: owner
          )
        )

        let start = NSMaxRange(match.range)
        let end = index + 1 < matches.count ? matches[index + 1].range.location : source.length
        let blockRange = NSRange(location: start, length: max(0, end - start))
        let fieldPattern = #"(?m)^\s*---@field\s+([\p{L}_][\p{L}\p{N}_]*)\??\s+([^\n]+)"#
        guard let fieldRegex = try? NSRegularExpression(pattern: fieldPattern) else { continue }
        for field in fieldRegex.matches(in: text, range: blockRange) {
          guard field.range(at: 1).location != NSNotFound,
            field.range(at: 2).location != NSNotFound
          else { continue }
          let name = source.substring(with: field.range(at: 1))
          let type = source.substring(with: field.range(at: 2))
            .trimmingCharacters(in: .whitespacesAndNewlines)
          symbols.append(
            ProjectCompletionSymbol(
              name: name,
              insertion: name,
              format: .plainText,
              kind: .property,
              fileName: fileName,
              url: url,
              occurrences: 1,
              ownerType: owner,
              isStatic: false,
              isDeclaration: true,
              fileRole: fileRole,
              isExternal: isExternal,
              packageName: packageName,
              typeName: type
            )
          )
        }
      }
    }

    let methodPattern =
      #"(?m)\bfunction\s+([\p{L}_][\p{L}\p{N}_.]*)([.:])([\p{L}_][\p{L}\p{N}_]*)\s*\(([^)]*)\)"#
    if let methodRegex = try? NSRegularExpression(pattern: methodPattern) {
      for match in methodRegex.matches(
        in: text,
        range: NSRange(location: 0, length: source.length)
      ) {
        guard match.numberOfRanges > 4 else { continue }
        let rawOwner = source.substring(with: match.range(at: 1))
        let owner = rawOwner.split(separator: ".").last.map(String.init) ?? rawOwner
        let separator = source.substring(with: match.range(at: 2))
        let name = source.substring(with: match.range(at: 3))
        let parameters = source.substring(with: match.range(at: 4))
        let insertion = luaCallSnippet(name: name, parameters: parameters)
        symbols.append(
          ProjectCompletionSymbol(
            name: name,
            insertion: insertion,
            format: insertion == name ? .plainText : .snippet,
            kind: .method,
            fileName: fileName,
            url: url,
            occurrences: 1,
            ownerType: owner,
            isStatic: separator == ".",
            isDeclaration: false,
            fileRole: fileRole,
            isExternal: isExternal,
            packageName: packageName,
            typeName: nil
          )
        )
      }
    }
    return symbols
  }

  private static func luaCallSnippet(name: String, parameters: String) -> String {
    let values = parameters.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty && $0 != "self" }
    guard !values.isEmpty else { return "\(name)()" }
    let placeholders = values.enumerated().map { index, value in
      let label = CompletionSyntaxUtilities.identifierWords(in: value).last ?? "arg"
      return "${\(index + 1):\(label)}"
    }
    return "\(name)(\(placeholders.joined(separator: ", ")))"
  }

  private static func patterns(for language: String) -> [Pattern] {
    functionPatterns(for: language) + typePatterns(for: language) + valuePatterns(for: language)
  }

  private static func functionPatterns(for language: String) -> [Pattern] {
    switch language {
    case "swift":
      return [
        functionPattern(
          #"\b(?:(?:class|static)\s+)?func\s+([\p{L}_][\p{L}\p{N}_]*)\s*\(([^)]*)\)\s*(?:async\s*)?(?:(?:re)?throws\s*)?(?:->\s*([^\n{]+))?"#,
          typeGroup: 3
        )
      ]
    case "rust":
      return [
        functionPattern(
          #"\b(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+([\p{L}_][\p{L}\p{N}_]*)\s*\(([^)]*)\)\s*(?:->\s*([^\n{]+))?"#,
          typeGroup: 3
        )
      ]
    case "go":
      return [
        Pattern(
          expression: regex(
            #"\bfunc\s+\(\s*(?:[\p{L}_][\p{L}\p{N}_]*\s+)?\*?([\p{L}_][\p{L}\p{N}_.]*)\s*\)\s*([\p{L}_][\p{L}\p{N}_]*)\s*\(([^)]*)\)"#
          ),
          kind: .function,
          nameGroup: 2,
          parameterGroup: 3,
          explicitOwnerGroup: 1,
          requiresTypeScope: false
        ),
        functionPattern(#"\bfunc\s+([\p{L}_][\p{L}\p{N}_]*)\s*\(([^)]*)\)"#),
      ]
    case "python":
      return [
        functionPattern(
          #"\b(?:async\s+)?def\s+([\p{L}_][\p{L}\p{N}_]*)\s*\(([^)]*)\)\s*(?:->\s*([^:\n]+))?\s*:"#,
          typeGroup: 3
        )
      ]
    case "javascript", "typescript":
      return [
        functionPattern(
          #"\b(?:async\s+)?function\s+([\p{L}_$][\p{L}\p{N}_$]*)\s*\(([^)]*)\)\s*(?::\s*([^\n{]+))?"#,
          typeGroup: 3
        ),
        functionPattern(
          #"\b(?:const|let|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)\s*=\s*(?:async\s*)?\(([^)]*)\)\s*(?::\s*([^=\n]+))?\s*=>"#,
          typeGroup: 3
        ),
        Pattern(
          expression: regex(
            #"(?m)^\s*(?:(?:public|private|protected|static|async|readonly|abstract|override)\s+)*([\p{L}_$][\p{L}\p{N}_$]*)\s*\(([^)]*)\)\s*(?::\s*([^\n{=;]+))?(?:\{|=>|;)"#
          ),
          kind: .function,
          nameGroup: 1,
          parameterGroup: 2,
          explicitOwnerGroup: nil,
          requiresTypeScope: true,
          typeGroup: 3
        ),
      ]
    case "kotlin":
      return [functionPattern(#"\bfun\s+([\p{L}_][\p{L}\p{N}_]*)\s*\(([^)]*)\)"#)]
    case "java", "csharp", "cpp", "c", "zig":
      return [
        Pattern(
          expression: regex(
            #"(?m)(?:^|(?<=[;{}]))\s*(?:(?:public|private|protected):\s*)*(?:(?:virtual|static|inline|constexpr|consteval|friend|extern|explicit|override|final|async|public|private|protected|internal|sealed|abstract|unsafe|partial)\s+)*(?:[\p{L}_][\p{L}\p{N}_:<>,*&?\[\]]*(?:\s+[\p{L}_][\p{L}\p{N}_:<>,*&?\[\]]*)*)\s+([~\p{L}_][\p{L}\p{N}_]*)\s*\(([^;{}()]*)\)\s*(?:const\s*)?(?:noexcept\s*)?(?:;|\{|=>)"#
          ),
          kind: .function,
          nameGroup: 1,
          parameterGroup: 2,
          explicitOwnerGroup: nil,
          requiresTypeScope: true
        ),
        Pattern(
          expression: regex(
            #"(?m)(?:^|(?<=[;{}]))\s*(?:(?:public|private|protected):\s*)*(?:(?:explicit|inline|constexpr|public|private|protected)\s+)*([~\p{L}_][\p{L}\p{N}_]*)\s*\(([^;{}()]*)\)\s*(?:const\s*)?(?:noexcept\s*)?(?:;|\{|=>)"#
          ),
          kind: .function,
          nameGroup: 1,
          parameterGroup: 2,
          explicitOwnerGroup: nil,
          requiresTypeScope: true
        ),
        Pattern(
          expression: regex(
            #"(?m)^\s*(?:(?:template\s*<[^\n>]*>|public:|private:|protected:)\s*)*(?:(?:virtual|static|inline|constexpr|consteval|friend|extern|explicit|override|final|async|public|private|protected|internal|sealed|abstract)\s+)*(?:[\p{L}_][\p{L}\p{N}_:<>,*&?\[\]\s]+\s+)?([\p{L}_][\p{L}\p{N}_]*)::([~\p{L}_][\p{L}\p{N}_]*)\s*\(([^;{}()]*)\)\s*(?:const\s*)?(?:noexcept\s*)?(?:;|\{|=>)"#
          ),
          kind: .function,
          nameGroup: 2,
          parameterGroup: 3,
          explicitOwnerGroup: 1,
          requiresTypeScope: false
        ),
        Pattern(
          expression: regex(
            #"(?m)^\s*(?:(?:public|private|protected|internal|virtual|static|inline|constexpr|consteval|friend|extern|override|final|sealed|abstract|async|unsafe|partial)\s+)*(?:[\p{L}_][\p{L}\p{N}_:<>,*&?\[\]]*(?:\s+[\p{L}_][\p{L}\p{N}_:<>,*&?\[\]]*)*)\s+([~\p{L}_][\p{L}\p{N}_]*)\s*\(([^;{}()]*)\)\s*(?:const\s*)?(?:noexcept\s*)?(?:;|\{|=>)"#
          ),
          kind: .function,
          nameGroup: 1,
          parameterGroup: 2,
          explicitOwnerGroup: nil,
          requiresTypeScope: false
        ),
        Pattern(
          expression: regex(
            #"(?m)^\s*(?:(?:public|private|protected|explicit|inline|constexpr)\s+)*([~\p{L}_][\p{L}\p{N}_]*)\s*\(([^;{}()]*)\)\s*(?:const\s*)?(?:noexcept\s*)?(?:;|\{|=>)"#
          ),
          kind: .function,
          nameGroup: 1,
          parameterGroup: 2,
          explicitOwnerGroup: nil,
          requiresTypeScope: true
        ),
      ]
    default:
      return [functionPattern(#"\b([\p{L}_][\p{L}\p{N}_]*)\s*\(([^;{}()]*)\)\s*\{"#)]
    }
  }

  private static func typePatterns(for language: String) -> [Pattern] {
    func type(_ pattern: String, _ kind: CompletionKind) -> Pattern {
      Pattern(
        expression: regex(pattern),
        kind: kind,
        nameGroup: 1,
        parameterGroup: nil,
        explicitOwnerGroup: nil,
        requiresTypeScope: false
      )
    }
    switch language {
    case "swift":
      return [
        type(#"\b(?:actor|class)\s+([\p{L}_][\p{L}\p{N}_]*)"#, .class),
        type(#"\bprotocol\s+([\p{L}_][\p{L}\p{N}_]*)"#, .interface),
        type(#"\bstruct\s+([\p{L}_][\p{L}\p{N}_]*)"#, .struct),
        type(#"\benum\s+([\p{L}_][\p{L}\p{N}_]*)"#, .enum),
        type(#"\btypealias\s+([\p{L}_][\p{L}\p{N}_]*)"#, .typeParameter),
      ]
    case "rust":
      return [
        type(#"\bstruct\s+([\p{L}_][\p{L}\p{N}_]*)"#, .struct),
        type(#"\benum\s+([\p{L}_][\p{L}\p{N}_]*)"#, .enum),
        type(#"\btrait\s+([\p{L}_][\p{L}\p{N}_]*)"#, .interface),
        type(#"\btype\s+([\p{L}_][\p{L}\p{N}_]*)"#, .typeParameter),
        type(#"\bmod\s+([\p{L}_][\p{L}\p{N}_]*)"#, .module),
      ]
    case "go":
      return [
        type(#"\btype\s+([\p{L}_][\p{L}\p{N}_]*)\s+struct"#, .struct),
        type(#"\btype\s+([\p{L}_][\p{L}\p{N}_]*)\s+interface"#, .interface),
      ]
    case "python":
      return [type(#"\bclass\s+([\p{L}_][\p{L}\p{N}_]*)"#, .class)]
    case "javascript", "typescript":
      return [
        type(#"\bclass\s+([\p{L}_$][\p{L}\p{N}_$]*)"#, .class),
        type(#"\binterface\s+([\p{L}_$][\p{L}\p{N}_$]*)"#, .interface),
        type(#"\benum\s+([\p{L}_$][\p{L}\p{N}_$]*)"#, .enum),
        type(#"\btype\s+([\p{L}_$][\p{L}\p{N}_$]*)"#, .typeParameter),
        type(#"\bnamespace\s+([\p{L}_$][\p{L}\p{N}_$]*)"#, .module),
      ]
    case "kotlin":
      return [
        type(#"\b(?:class|data\s+class|object)\s+([\p{L}_][\p{L}\p{N}_]*)"#, .class),
        type(#"\binterface\s+([\p{L}_][\p{L}\p{N}_]*)"#, .interface),
        type(#"\benum\s+class\s+([\p{L}_][\p{L}\p{N}_]*)"#, .enum),
        type(#"\btypealias\s+([\p{L}_][\p{L}\p{N}_]*)"#, .typeParameter),
      ]
    default:
      return [
        type(#"\bclass\s+([\p{L}_][\p{L}\p{N}_]*)"#, .class),
        type(#"\b(?:interface|trait)\s+([\p{L}_][\p{L}\p{N}_]*)"#, .interface),
        type(#"\bstruct\s+([\p{L}_][\p{L}\p{N}_]*)"#, .struct),
        type(#"\benum(?:\s+class)?\s+([\p{L}_][\p{L}\p{N}_]*)"#, .enum),
        type(#"\b(?:namespace|module)\s+([\p{L}_][\p{L}\p{N}_]*)"#, .module),
      ]
    }
  }

  private static func shouldSkipValueDeclaration(
    kind: CompletionKind,
    language: String,
    matchRange: NSRange,
    code: String
  ) -> Bool {
    guard kind == .variable || kind == .constant,
      language == "javascript" || language == "typescript"
    else { return false }
    let source = code as NSString
    let safeLocation = min(max(0, matchRange.location), source.length)
    let lineRange = source.lineRange(
      for: NSRange(
        location: safeLocation, length: min(matchRange.length, source.length - safeLocation))
    )
    let line = source.substring(with: lineRange)
    return line.range(
      of: #"=\s*(?:(?:async\s+)?function\b|(?:async\s*)?\([^\n]*\)\s*(?::[^=\n]+)?=>)"#,
      options: .regularExpression
    ) != nil
  }

  private static func valuePatterns(for language: String) -> [Pattern] {
    func value(_ pattern: String, _ kind: CompletionKind = .variable) -> Pattern {
      Pattern(
        expression: regex(pattern),
        kind: kind,
        nameGroup: 1,
        parameterGroup: nil,
        explicitOwnerGroup: nil,
        requiresTypeScope: false
      )
    }
    switch language {
    case "swift":
      return [
        Pattern(
          expression: regex(
            #"\b(?:(?:class|static)\s+)?(?:let|var)\s+([\p{L}_][\p{L}\p{N}_]*)\s*:\s*([^=\n{]+)"#),
          kind: .variable,
          nameGroup: 1,
          parameterGroup: nil,
          explicitOwnerGroup: nil,
          requiresTypeScope: false,
          typeGroup: 2
        ),
        value(#"\b(?:(?:class|static)\s+)?(?:let|var)\s+([\p{L}_][\p{L}\p{N}_]*)"#),
      ]
    case "rust":
      return [
        Pattern(
          expression: regex(
            #"(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?([\p{L}_][\p{L}\p{N}_]*)\s*:\s*([^,\n]+),"#),
          kind: .variable,
          nameGroup: 1,
          parameterGroup: nil,
          explicitOwnerGroup: nil,
          requiresTypeScope: true,
          typeGroup: 2
        ),
        value(#"\b(?:const|static)\s+(?:mut\s+)?([\p{L}_][\p{L}\p{N}_]*)"#, .constant),
        value(#"\blet\s+(?:mut\s+)?([\p{L}_][\p{L}\p{N}_]*)"#),
      ]
    case "go":
      return [
        Pattern(
          expression: regex(
            #"(?m)^\s*([\p{L}_][\p{L}\p{N}_]*)\s+([\p{L}_][\p{L}\p{N}_.*\[\]]*)\s*(?:`[^`]*`)?$"#),
          kind: .variable,
          nameGroup: 1,
          parameterGroup: nil,
          explicitOwnerGroup: nil,
          requiresTypeScope: true,
          typeGroup: 2
        ),
        value(#"\b(?:const|var)\s+([\p{L}_][\p{L}\p{N}_]*)"#),
      ]
    case "python":
      return [
        Pattern(
          expression: regex(#"(?m)^\s*([\p{L}_][\p{L}\p{N}_]*)\s*:\s*([^=\n]+)(?:=|$)"#),
          kind: .variable,
          nameGroup: 1,
          parameterGroup: nil,
          explicitOwnerGroup: nil,
          requiresTypeScope: true,
          typeGroup: 2
        ),
        value(#"(?m)^\s*([\p{L}_][\p{L}\p{N}_]*)\s*(?::[^=\n]+)?="#),
      ]
    case "javascript", "typescript":
      return [
        Pattern(
          expression: regex(
            #"(?m)^\s*(?:(?:public|private|protected|readonly|static|declare|abstract)\s+)*([\p{L}_$][\p{L}\p{N}_$]*)\??\s*:\s*([^;=\n]+)(?:;|=|$)"#
          ),
          kind: .variable,
          nameGroup: 1,
          parameterGroup: nil,
          explicitOwnerGroup: nil,
          requiresTypeScope: true,
          typeGroup: 2
        ),
        value(#"\b(?:const|let|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)"#),
      ]
    case "kotlin": return [value(#"\b(?:val|var)\s+([\p{L}_][\p{L}\p{N}_]*)"#)]
    default:
      return [
        Pattern(
          expression: regex(
            #"(?m)^\s*(?:(?:public|private|protected):\s*)*(?:(?:public|private|protected|internal|static|readonly|const|constexpr|final|volatile|mutable)\s+)*([\p{L}_][\p{L}\p{N}_:<>,*&?\[\]]*)\s+([\p{L}_][\p{L}\p{N}_]*)\s*(?:=|;|,)"#
          ),
          kind: .variable,
          nameGroup: 2,
          parameterGroup: nil,
          explicitOwnerGroup: nil,
          requiresTypeScope: true,
          typeGroup: 1
        ),
        value(
          #"(?m)(?:^|(?<=[;{}]))\s*(?:(?:public|private|protected):\s*)*(?:(?:public|private|protected|internal|static|readonly|const|constexpr|final|volatile|mutable)\s+)*[\p{L}_][\p{L}\p{N}_:<>,*&?\[\]]*\s+([\p{L}_][\p{L}\p{N}_]*)\s*(?:=|;|,)"#
        ),
      ]
    }
  }

  private static func functionPattern(_ pattern: String, typeGroup: Int? = nil) -> Pattern {
    Pattern(
      expression: regex(pattern),
      kind: .function,
      nameGroup: 1,
      parameterGroup: 2,
      explicitOwnerGroup: nil,
      requiresTypeScope: false,
      typeGroup: typeGroup
    )
  }

  private static func resolvedKind(
    _ declaredKind: CompletionKind,
    name: String,
    owner: String?,
    language: String
  ) -> CompletionKind {
    guard let owner else { return declaredKind }
    switch declaredKind {
    case .function:
      let normalized = name.trimmingCharacters(in: CharacterSet(charactersIn: "~"))
      if normalized.caseInsensitiveCompare(owner) == .orderedSame
        || ["init", "__init__", "new"].contains(name.lowercased())
      {
        return .constructor
      }
      return .method
    case .variable:
      if ["swift", "kotlin", "javascript", "typescript", "python", "csharp"].contains(language) {
        return .property
      }
      return .field
    case .constant:
      return .constant
    default:
      return declaredKind
    }
  }

  private static func isDirectTypeMember(
    at location: Int,
    in scope: CompletionTypeScope,
    code: String,
    language: String
  ) -> Bool {
    if language == "python" {
      return isDirectPythonTypeMember(at: location, in: scope, code: code)
    }
    let source = code as NSString
    let searchStart = scope.range.location
    let searchLength = min(scope.range.length, max(0, source.length - searchStart))
    guard searchLength > 0 else { return false }
    let openRange = source.range(
      of: "{",
      range: NSRange(location: searchStart, length: searchLength)
    )
    guard openRange.location != NSNotFound, location > openRange.location else { return false }
    var depth = 1
    var index = openRange.location + 1
    while index < min(location, source.length) {
      let character = source.character(at: index)
      if character == 123 { depth += 1 } else if character == 125 { depth -= 1 }
      index += 1
    }
    return depth == 1
  }

  private static func isDirectPythonTypeMember(
    at location: Int,
    in scope: CompletionTypeScope,
    code: String
  ) -> Bool {
    let source = code as NSString
    guard location >= scope.range.location, location < NSMaxRange(scope.range) else { return false }
    let classLine = source.lineRange(for: NSRange(location: scope.range.location, length: 0))
    let classText = source.substring(with: classLine)
    let classIndent = classText.prefix { $0 == " " || $0 == "\t" }.count

    var minimumBodyIndent: Int?
    var cursor = NSMaxRange(classLine)
    let scopeEnd = min(NSMaxRange(scope.range), source.length)
    while cursor < scopeEnd {
      let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
      let line = source.substring(with: lineRange)
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        if indent > classIndent {
          minimumBodyIndent = minimumBodyIndent.map { min($0, indent) } ?? indent
        }
      }
      cursor = NSMaxRange(lineRange)
    }

    guard let expectedIndent = minimumBodyIndent else { return false }
    let memberLine = source.lineRange(for: NSRange(location: location, length: 0))
    let memberText = source.substring(with: memberLine)
    let memberIndent = memberText.prefix { $0 == " " || $0 == "\t" }.count
    return memberIndent == expectedIndent
  }

  private static func braceDepth(at location: Int, in code: String) -> Int {
    let source = code as NSString
    var depth = 0
    var index = 0
    while index < min(location, source.length) {
      let character = source.character(at: index)
      if character == 123 { depth += 1 } else if character == 125 { depth = max(0, depth - 1) }
      index += 1
    }
    return depth
  }

  private static func enumMemberSymbols(
    code: String,
    source: NSString,
    language: String,
    typeScopes: [CompletionTypeScope],
    fileName: String,
    url: URL,
    fileRole: CompletionSourceFileRole,
    isExternal: Bool,
    packageName: String?
  ) -> [ProjectCompletionSymbol] {
    var result: [ProjectCompletionSymbol] = []
    for scope in typeScopes {
      let scopeStart = scope.range.location
      let scopeLength = min(scope.range.length, max(0, source.length - scopeStart))
      guard scopeLength > 0 else { continue }
      let openRange = source.range(
        of: "{",
        range: NSRange(location: scopeStart, length: scopeLength)
      )
      guard openRange.location != NSNotFound else { continue }
      let header = source.substring(
        with: NSRange(location: scopeStart, length: openRange.location - scopeStart)
      )
      guard header.range(of: #"\benum\b"#, options: .regularExpression) != nil else { continue }
      let closing = NSMaxRange(scope.range) - 1
      guard closing > openRange.location, closing <= (code as NSString).length else { continue }
      let directBody = directTypeBody(
        code: code as NSString,
        opening: openRange.location,
        closing: closing
      )
      let names = enumMemberNames(in: directBody, language: language)
      for name in names where isUsefulIdentifier(name) {
        result.append(
          ProjectCompletionSymbol(
            name: name,
            insertion: name,
            format: .plainText,
            kind: .enumMember,
            fileName: fileName,
            url: url,
            occurrences: 1,
            ownerType: scope.name,
            isStatic: true,
            isDeclaration: true,
            fileRole: fileRole,
            isExternal: isExternal,
            packageName: packageName
          )
        )
      }
    }
    return result
  }

  private static func directTypeBody(
    code: NSString,
    opening: Int,
    closing: Int
  ) -> String {
    var output = [UInt16](repeating: 32, count: max(0, closing - opening - 1))
    var depth = 1
    var index = opening + 1
    while index < closing, index < code.length {
      let character = code.character(at: index)
      if character == 123 {
        depth += 1
      } else if character == 125 {
        depth -= 1
      } else if depth == 1 {
        output[index - opening - 1] = character
      }
      if character == 10 || character == 13, index - opening - 1 < output.count {
        output[index - opening - 1] = character
      }
      index += 1
    }
    return String(decoding: output, as: UTF16.self)
  }

  private static func enumMemberNames(in body: String, language: String) -> [String] {
    let source = body as NSString
    var names: [String] = []
    if language == "swift" {
      guard let regex = try? NSRegularExpression(pattern: #"(?m)\bcase\s+([^\n\r]+)"#) else {
        return []
      }
      for match in regex.matches(in: body, range: NSRange(location: 0, length: source.length)) {
        guard match.numberOfRanges > 1 else { continue }
        let clause = source.substring(with: match.range(at: 1))
        for component in topLevelComponents(in: clause, separatedBy: ",") {
          if let name = firstIdentifier(in: component) { names.append(name) }
        }
      }
    } else if language == "rust" {
      for component in topLevelComponents(in: body, separatedBy: ",") {
        if let name = firstIdentifier(in: component), name.first?.isUppercase == true {
          names.append(name)
        }
      }
    } else {
      let declarationRegion =
        body.split(separator: ";", maxSplits: 1).first.map(String.init) ?? body
      for component in topLevelComponents(in: declarationRegion, separatedBy: ",") {
        if let name = firstIdentifier(in: component) { names.append(name) }
      }
    }
    var seen = Set<String>()
    return names.filter { seen.insert($0.lowercased()).inserted }
  }

  private static func topLevelComponents(
    in value: String,
    separatedBy separator: Character
  ) -> [String] {
    var result: [String] = []
    var current = ""
    var round = 0
    var square = 0
    var angle = 0
    var brace = 0
    var quote: Character?
    var escaped = false
    for character in value {
      if let activeQuote = quote {
        current.append(character)
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == activeQuote {
          quote = nil
        }
        continue
      }
      if character == "\"" || character == "'" || character == "`" {
        quote = character
        current.append(character)
        continue
      }
      switch character {
      case "(": round += 1
      case ")": round = max(0, round - 1)
      case "[": square += 1
      case "]": square = max(0, square - 1)
      case "<": angle += 1
      case ">": angle = max(0, angle - 1)
      case "{": brace += 1
      case "}": brace = max(0, brace - 1)
      default: break
      }
      if character == separator, round == 0, square == 0, angle == 0, brace == 0 {
        result.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    result.append(current)
    return result
  }

  private static func firstIdentifier(in value: String) -> String? {
    value.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "$" }
      .map(String.init)
      .first { !["case", "indirect", "public", "private", "protected"].contains($0.lowercased()) }
  }

  private static func staticDeclaration(
    _ text: String,
    parameters: String?,
    language: String,
    owner: String?
  ) -> Bool {
    guard owner != nil else { return false }
    let lower = text.lowercased()
    if lower.range(of: #"\b(?:class|static|classmethod)\b"#, options: .regularExpression) != nil {
      return true
    }
    if language == "rust", let parameters {
      let lowerParameters = parameters.lowercased()
      return lowerParameters.range(
        of: #"(?:^|[,\s&])(?:mut\s+)?self(?:\s|,|$)"#, options: .regularExpression) == nil
    }
    return false
  }

  private static func declarationOnly(
    _ text: String,
    fileRole: CompletionSourceFileRole,
    kind: CompletionKind
  ) -> Bool {
    if fileRole == .header || fileRole == .interface { return true }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix(";") { return true }
    if kind == .class || kind == .struct || kind == .enum || kind == .interface
      || kind == .typeParameter || kind == .module
    {
      return true
    }
    return false
  }

  private static func callSnippet(name: String, parameters: String, language: String) -> String {
    let names = parameterNames(parameters, language: language)
    guard !names.isEmpty else { return "\(name)($0)" }
    let placeholders = names.enumerated().map { index, value in
      "${\(index + 1):\(value)}"
    }
    return "\(name)(\(placeholders.joined(separator: ", ")))$0"
  }

  private static func parameterNames(_ parameters: String, language: String) -> [String] {
    topLevelComponents(in: parameters, separatedBy: ",").compactMap { raw in
      let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !part.isEmpty, part != "self", part != "&self", part != "&mut self" else { return nil }
      let left = topLevelComponents(in: part, separatedBy: "=").first ?? part
      let colonParts = topLevelComponents(in: left, separatedBy: ":")
      let identifiers: [String]
      if ["swift", "rust", "kotlin", "typescript", "python"].contains(language) {
        identifiers = identifierWords(in: colonParts.first ?? left)
      } else {
        identifiers = identifierWords(in: left)
      }
      let candidate = language == "go" ? identifiers.first : identifiers.last
      guard let candidate, isUsefulIdentifier(candidate) else { return nil }
      return candidate
    }
  }

  private static func identifierWords(in value: String) -> [String] {
    value.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "$" }
      .map(String.init)
  }

  private static func matchingCurlyBrace(in source: NSString, openingAt open: Int) -> Int? {
    guard open >= 0, open < source.length, source.character(at: open) == 123 else { return nil }
    var depth = 0
    var quote: unichar?
    var escaped = false
    var index = open
    while index < source.length {
      let character = source.character(at: index)
      if let activeQuote = quote {
        if escaped {
          escaped = false
        } else if character == 92 {
          escaped = true
        } else if character == activeQuote {
          quote = nil
        }
      } else if character == 34 || character == 39 || character == 96 {
        quote = character
      } else if character == 123 {
        depth += 1
      } else if character == 125 {
        depth -= 1
        if depth == 0 { return index }
      }
      index += 1
    }
    return nil
  }

  private static func matchingParenthesis(in source: NSString, openingAt open: Int) -> Int? {
    guard open >= 0, open < source.length, source.character(at: open) == 40 else { return nil }
    var depth = 0
    var index = open
    while index < source.length {
      let character = source.character(at: index)
      if character == 40 {
        depth += 1
      } else if character == 41 {
        depth -= 1
        if depth == 0 { return index }
      }
      index += 1
    }
    return nil
  }

  private static func regex(_ pattern: String) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }

  private static func isUsefulIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && !["if", "for", "while", "switch", "catch", "return", "sizeof", "typeof"].contains(
        value.lowercased())
  }
}

private enum CompletionProjectCodeMask {
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
    let hash = ["python", "ruby", "shell", "yaml", "toml"].contains(languageID)
    let dash = ["sql", "lua", "haskell"].contains(languageID)
    let slash = !hash && !dash && languageID != "markdown"

    while index < source.length {
      let current = source.character(at: index)
      let next = index + 1 < source.length ? source.character(at: index + 1) : 0
      switch state {
      case .code:
        if current == 10 || current == 13 {
          output[index] = current
        } else if hash && current == 35 {
          state = .lineComment
        } else if dash && current == 45 && next == 45 {
          state = .lineComment
          index += 1
        } else if slash && current == 47 && next == 47 {
          state = .lineComment
          index += 1
        } else if slash && current == 47 && next == 42 {
          state = .blockComment
          index += 1
        } else if current == 34 || current == 39 || current == 96 {
          state = .string(current)
        } else {
          output[index] = current
        }
      case .lineComment:
        if current == 10 || current == 13 {
          output[index] = current
          state = .code
        }
      case .blockComment:
        if current == 10 || current == 13 { output[index] = current }
        if current == 42 && next == 47 {
          state = .code
          index += 1
        }
      case .string(let quote):
        if current == 10 || current == 13 { output[index] = current }
        if current == 92 { index += 1 } else if current == quote { state = .code }
      }
      index += 1
    }
    return String(decoding: output, as: UTF16.self)
  }
}
