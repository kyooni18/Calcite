import EditorCore
import Foundation

/// Internal, context-sensitive completion ranking. The public completion API intentionally stays
/// unchanged; callers simply receive candidates in a more useful order with normalized sortText.
struct CompletionUsageHistory: Sendable {
  private struct Entry: Sendable {
    var count: Int
    var lastSequence: UInt64
  }

  private var entries: [String: Entry] = [:]
  private var sequence: UInt64 = 0
  private let capacity = 512

  mutating func record(_ completion: Completion, languageID: String) {
    sequence &+= 1
    let key = Self.key(for: completion, languageID: languageID)
    var entry = entries[key] ?? Entry(count: 0, lastSequence: sequence)
    entry.count = min(entry.count + 1, 64)
    entry.lastSequence = sequence
    entries[key] = entry

    guard entries.count > capacity else { return }
    let overflow = entries.count - capacity
    for key in entries.sorted(by: { $0.value.lastSequence < $1.value.lastSequence })
      .prefix(overflow).map(\.key)
    {
      entries.removeValue(forKey: key)
    }
  }

  func bonus(for completion: Completion, languageID: String) -> Int {
    guard let entry = entries[Self.key(for: completion, languageID: languageID)] else { return 0 }
    let age = sequence >= entry.lastSequence ? sequence - entry.lastSequence : 0
    let recency = max(0, 260 - min(260, Int(age) * 18))
    let frequency = min(220, entry.count * 42)
    return recency + frequency
  }

  private static func key(for completion: Completion, languageID: String) -> String {
    let identity = completion.primaryEdit?.replacement ?? completion.insertText ?? completion.label
    return "\(languageID.lowercased())|\(completion.kind?.rawValue ?? 0)|\(identity.lowercased())"
  }
}

enum CompletionRankingEngine {
  static func rank(
    _ completions: [Completion],
    snapshot: TextSnapshot,
    position: TextPosition,
    invocation: EditorCompletionInvocation,
    languageID: String,
    usageHistory: CompletionUsageHistory,
    limit: Int,
    currentURI: URL? = nil,
    projectSymbols: [ProjectCompletionSymbol] = []
  ) throws -> [Completion] {
    guard limit > 0, !completions.isEmpty else { return [] }
    let context = try CompletionRankingContext(
      snapshot: snapshot,
      position: position,
      invocation: invocation,
      languageID: languageID,
      currentURI: currentURI,
      projectSymbols: projectSymbols
    )
    let serverRanks = serverPriorityRanks(for: completions)

    let ranked = completions.enumerated().map { originalIndex, completion in
      RankedCompletion(
        completion: completion,
        originalIndex: originalIndex,
        score: score(
          completion,
          serverRank: serverRanks[originalIndex],
          context: context,
          invocation: invocation,
          languageID: languageID,
          usageHistory: usageHistory
        )
      )
    }
    .sorted { lhs, rhs in
      if lhs.score.total != rhs.score.total { return lhs.score.total > rhs.score.total }
      if lhs.score.semantic != rhs.score.semantic {
        return lhs.score.semantic > rhs.score.semantic
      }
      if lhs.score.name != rhs.score.name { return lhs.score.name > rhs.score.name }
      if lhs.score.quality != rhs.score.quality { return lhs.score.quality > rhs.score.quality }
      if lhs.score.usage != rhs.score.usage { return lhs.score.usage > rhs.score.usage }
      if lhs.originalIndex != rhs.originalIndex { return lhs.originalIndex < rhs.originalIndex }
      return lhs.completion.label.localizedStandardCompare(rhs.completion.label)
        == .orderedAscending
    }

    return ranked.prefix(limit).enumerated().map { index, ranked in
      var completion = ranked.completion
      // LSP clients frequently perform a second sort using sortText. Encode the final contextual
      // order so the ranking remains stable without changing the public completion API.
      completion.sortText = String(format: "%06d", index)
      return completion
    }
  }

  private static func score(
    _ completion: Completion,
    serverRank: Int?,
    context: CompletionRankingContext,
    invocation: EditorCompletionInvocation,
    languageID: String,
    usageHistory: CompletionUsageHistory
  ) -> CompletionRankingScore {
    let kind = completion.kind ?? .text
    let nameMatch = CompletionNameMatcher.bestMatch(for: completion, prefix: context.prefix)
    var nameScore = nameMatch?.score ?? 0

    if nameMatch == nil, !context.prefix.isEmpty {
      nameScore -= invocation == .explicit ? 1_700 : 5_500
    } else if nameMatch?.tier == .subsequence {
      if invocation == .automatic { nameScore -= context.prefix.count < 2 ? 620 : 180 }
    }

    let normalizedLabel = completion.label.lowercased()
    var semantic = roleScore(kind: kind, label: completion.label, role: context.role)
    semantic += categoryAdjustment(kind: kind, label: completion.label, role: context.role)
    semantic += structuralScore(
      completion,
      kind: kind,
      normalizedLabel: normalizedLabel,
      context: context
    )
    semantic += context.languageStrategy.rankingAdjustment(
      CompletionLanguageRankingInput(
        kind: kind,
        label: completion.label,
        detail: completion.detail,
        documentation: completion.documentation,
        isMemberAccess: context.role.isMemberAccess,
        isStaticReceiver: context.isStaticReceiver,
        expectedType: context.expectedType,
        initializerContext: context.initializerContext
      )
    )

    if context.callableNames.contains(normalizedLabel) {
      semantic += kind.isCallable ? 230 : 45
    }
    if context.allMemberNames.contains(normalizedLabel) {
      semantic += context.role.isMemberAccess ? 210 : 50
    }
    if let receiver = context.receiver?.lowercased(),
      context.membersByReceiver[receiver]?.contains(normalizedLabel) == true
    {
      semantic += 620
    }

    semantic += contextWordScore(completion.label, contextWords: context.contextWords)

    if let expectedType = context.expectedType,
      let expectedTypeToken = canonicalTypeToken(expectedType)
    {
      let metadata = [completion.detail, completion.documentation]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
      if metadataMentionsType(expectedTypeToken, in: metadata) { semantic += 360 }
      if let resultType = inferredResultType(for: completion),
        context.languageStrategy.typesAreCompatible(resultType, expectedType)
      {
        // Type compatibility is stronger evidence than spelling. This is what makes
        // `let count: usize = value.` prefer `len()` over unrelated mutating methods,
        // and it applies equally to Swift, Go, TypeScript and other strategies.
        semantic += kind.isCallable ? 980 : 820
      }
      let normalizedType = expectedTypeToken.lowercased()
      if normalizedLabel == normalizedType
        || normalizedLabel.hasPrefix(normalizedType + ".")
        || normalizedLabel.hasPrefix(normalizedType + "::")
        || normalizedLabel.hasPrefix(normalizedType + "(")
      {
        semantic += 170
      }
    }

    if completion.insertTextFormat == .snippet {
      switch context.role {
      case .statement, .declaration: semantic += 150
      case .memberAccess, .typePosition, .importPath, .argument: semantic -= 220
      case .attribute: semantic += 120
      default: semantic += 20
      }
    }

    var quality = sourceQuality(completion)
    if let serverRank {
      quality += max(0, 80 - min(serverRank, 80))
    }
    if completion.documentation?.isEmpty == false { quality += 18 }
    if completion.detail?.isEmpty == false { quality += 12 }

    let metadata = [completion.detail, completion.documentation]
      .compactMap { $0?.lowercased() }
      .joined(separator: " ")
    if metadata.contains("deprecated") || metadata.contains("obsolete") {
      quality -= 900
    }
    if metadata.contains("unavailable") || metadata.contains("not available") {
      quality -= 620
    }

    if completion.label.hasPrefix("_") && !context.prefix.hasPrefix("_") { quality -= 100 }
    if completion.label.count == 1 && context.prefix.count > 1 { quality -= 80 }

    let usage = min(520, usageHistory.bonus(for: completion, languageID: languageID))
    let interaction: Int
    if let match = nameMatch {
      // Similar to clangd's quality/relevance/name separation: compact name matches amplify
      // semantic relevance while weak subsequences cannot rescue an inappropriate symbol kind.
      let boundedSemantic = min(1_600, max(-1_200, semantic))
      let tierWeight: Int
      switch match.tier {
      case .exact, .caseInsensitiveExact: tierWeight = 14
      case .prefix, .caseInsensitivePrefix: tierWeight = 11
      case .wordBoundary: tierWeight = 8
      case .contiguousSubstring: tierWeight = 5
      case .subsequence: tierWeight = 2
      case .neutral: tierWeight = 0
      }
      interaction = boundedSemantic * tierWeight / 20
    } else {
      interaction = 0
    }

    return CompletionRankingScore(
      total: nameScore + semantic + quality + usage + interaction,
      name: nameScore,
      semantic: semantic,
      quality: quality,
      usage: usage
    )
  }

  private static func inferredResultType(for completion: Completion) -> String? {
    let values = [completion.detail, completion.documentation].compactMap { $0 }
    let expression = try? NSRegularExpression(
      pattern: #"(?:->|:)\s*([^•\n]+?)(?=\s*(?:•|$))"#
    )
    for value in values {
      let source = value as NSString
      let matches =
        expression?.matches(
          in: value, range: NSRange(location: 0, length: source.length)
        ) ?? []
      guard let match = matches.last, match.numberOfRanges > 1,
        match.range(at: 1).location != NSNotFound
      else { continue }
      let candidate = source.substring(with: match.range(at: 1))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !candidate.isEmpty { return candidate }
    }
    return nil
  }

  private static func canonicalTypeToken(_ type: String) -> String? {
    let outer = type.split(separator: "<", maxSplits: 1).first.map(String.init) ?? type
    let tokens = outer.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
    return tokens.last.map(String.init)
  }

  private static func metadataMentionsType(_ expectedType: String, in metadata: String) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: expectedType)
    return metadata.range(
      of: #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#,
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }

  private static func contextWordScore(
    _ label: String,
    contextWords: [String: Int]
  ) -> Int {
    guard !contextWords.isEmpty else { return 0 }
    let words = Set(CompletionIdentifierTokenizer.words(in: label))
    return min(240, words.reduce(0) { $0 + (contextWords[$1] ?? 0) })
  }

  private static func sourceQuality(_ completion: Completion) -> Int {
    guard let service = completion.serviceIdentifier else { return 25 }
    if service == "editor-context" {
      if completion.detail == "Current document" { return 300 }
      if completion.detail?.hasPrefix("Project •") == true { return 130 }
      if completion.detail == "Language keyword" { return -60 }
      return 75
    }
    return 180
  }

  private static func serverPriorityRanks(for completions: [Completion]) -> [Int: Int] {
    let ordered = completions.indices.filter { completions[$0].sortText != nil }.sorted {
      lhs, rhs in
      let lhsKey = completions[lhs].sortText ?? ""
      let rhsKey = completions[rhs].sortText ?? ""
      if lhsKey != rhsKey { return lhsKey < rhsKey }
      return lhs < rhs
    }
    return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
  }

  private static func structuralScore(
    _ completion: Completion,
    kind: CompletionKind,
    normalizedLabel: String,
    context: CompletionRankingContext
  ) -> Int {
    var value = 0
    let variableLike: Set<CompletionKind> = [.variable, .field, .property, .constant, .value]

    if !context.role.isMemberAccess {
      if context.parameterNames.contains(normalizedLabel) {
        value += variableLike.contains(kind) ? 920 : 250
      } else if context.localNames.contains(normalizedLabel) {
        value += variableLike.contains(kind) ? 760 : 180
      }
    } else if context.receiver?.lowercased() == normalizedLabel {
      value -= 420
    }
    if context.currentFunction?.lowercased() == normalizedLabel, kind.isCallable { value += 170 }

    let symbols = context.symbolsByName[normalizedLabel, default: []]
    let candidateStaticFromDetail = [completion.detail, completion.documentation]
      .compactMap { $0?.lowercased() }
      .contains { text in
        text.range(
          of: #"\b(?:class|static)\s+(?:func|fn|method|var|let|property)\b"#,
          options: .regularExpression) != nil
          || text.contains("static method") || text.contains("static property")
      }

    if let receiverType = context.receiverType?.lowercased(), context.role.isMemberAccess {
      let matching = symbols.filter { $0.ownerType?.lowercased() == receiverType }
      if !matching.isEmpty {
        value += 940
        if context.isQualifiedDefinition {
          value += matching.contains(where: { $0.isDeclaration }) ? 520 : 180
          value += matching.contains(where: { !$0.isStatic }) ? 180 : 20
        } else if context.isStaticReceiver {
          value += matching.contains(where: \.isStatic) ? 300 : -260
        } else {
          value += matching.contains(where: { !$0.isStatic }) ? 240 : -100
        }
      } else if symbols.contains(where: { $0.ownerType != nil }) {
        value -= 440
      } else if context.isStaticReceiver {
        value += candidateStaticFromDetail ? 190 : -100
      } else if candidateStaticFromDetail {
        value -= 80
      }
    } else if let currentType = context.currentType?.lowercased() {
      let owned = symbols.filter { $0.ownerType?.lowercased() == currentType }
      if !owned.isEmpty {
        value += kind == .constructor ? 500 : 590
        if context.isStaticContext {
          value += owned.contains(where: \.isStatic) ? 210 : -80
        } else if owned.contains(where: { !$0.isStatic }) {
          value += 130
        }
      } else {
        let inherited = symbols.filter { symbol in
          guard let owner = symbol.ownerType?.lowercased() else { return false }
          return context.baseTypes.contains { $0.lowercased() == owner }
        }
        if !inherited.isEmpty {
          value += context.expectsOverride && kind.isCallable ? 720 : 210
        } else if symbols.contains(where: { $0.ownerType != nil }) {
          value -= context.role.isStatement ? 40 : 130
        }
      }
    }

    switch context.fileRole {
    case .header, .interface:
      if symbols.contains(where: { $0.isDeclaration }) { value += 130 }
      if let currentType = context.currentType,
        symbols.contains(where: {
          $0.ownerType?.caseInsensitiveCompare(currentType) == .orderedSame
        })
      {
        value += 170
      }
      if completion.insertTextFormat == .snippet, context.currentType != nil { value -= 100 }
      if context.currentType != nil, kind == .function { value -= 90 }
    case .implementation:
      if symbols.contains(where: {
        $0.url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(
          context.currentFileStem) == .orderedSame
      }) {
        value += 260
      }
      if symbols.contains(where: { $0.fileRole == .header || $0.fileRole == .interface }) {
        value += 70
      }
    case .test:
      if normalizedLabel.hasPrefix("test") || normalizedLabel.contains("mock")
        || normalizedLabel.contains("stub")
      {
        value += 140
      }
    case .generated:
      value -= 40
    case .other:
      break
    }

    if !completion.additionalEdits.isEmpty {
      switch context.role {
      case .importPath: value += 130
      case .memberAccess: value -= 80
      default: value -= 35
      }
    }
    if kind == .file || kind == .folder {
      value += context.role.isImportPath ? 520 : -560
    }
    if kind == .constructor, let expectedType = context.expectedType?.lowercased(),
      symbols.contains(where: { $0.ownerType?.lowercased() == expectedType })
    {
      value += 430
    }
    return value
  }

  /// Keeps broad type and language-keyword candidates available without allowing them to crowd
  /// out concrete symbols in ordinary editing contexts. Contexts that explicitly require a type or
  /// begin a statement retain a much smaller adjustment.
  private static func categoryAdjustment(
    kind: CompletionKind,
    label: String,
    role: CompletionRankingRole
  ) -> Int {
    switch kind {
    case .class, .interface, .enum, .struct, .typeParameter:
      switch role {
      case .typePosition: return -40
      case .declaration(let expected) where expected.contains(kind): return -30
      case .importPath: return -90
      default: return -140
      }

    case .keyword:
      let normalized = label.lowercased()
      switch role {
      case .statement:
        return -90
      case .typePosition
      where ["any", "some", "self", "void", "never", "dyn"].contains(normalized):
        return -50
      case .expression
      where ["true", "false", "nil", "null", "none", "self", "this", "super"].contains(
        normalized):
        return -45
      case .importPath:
        return -80
      default:
        return -150
      }

    default:
      return 0
    }
  }

  private static func roleScore(
    kind: CompletionKind,
    label: String,
    role: CompletionRankingRole
  ) -> Int {
    switch role {
    case .memberAccess:
      switch kind {
      case .method: return 900
      case .property, .field: return 760
      case .function: return 590
      case .variable: return 390
      case .constant, .enumMember: return 240
      case .operator: return 130
      case .constructor: return 80
      case .keyword, .snippet: return -800
      case .module, .file, .folder: return -620
      case .class, .interface, .enum, .struct, .typeParameter: return -380
      default: return -80
      }

    case .typePosition:
      switch kind {
      case .class, .interface, .enum, .struct, .typeParameter: return 850
      case .constructor: return 480
      case .module: return 250
      case .keyword
      where ["any", "some", "self", "void", "never", "dyn"].contains(label.lowercased()):
        return 380
      case .variable, .field, .property, .constant, .enumMember: return -520
      case .method, .function: return -360
      case .snippet: return -500
      default: return -100
      }

    case .importPath:
      switch kind {
      case .module, .file, .folder: return 950
      case .class, .interface, .enum, .struct: return 160
      case .keyword: return -250
      default: return -700
      }

    case .declaration(let expected):
      if expected.contains(kind) { return 900 }
      switch kind {
      case .variable, .field, .property: return 420
      case .text: return 260
      case .constant: return 180
      case .keyword, .snippet: return -480
      default: return -220
      }

    case .callable:
      switch kind {
      case .method, .function: return 760
      case .constructor: return 640
      case .variable, .field, .property: return 210
      case .class, .struct, .enum: return 160
      case .constant: return 50
      case .keyword, .snippet: return -260
      default: return -40
      }

    case .argument:
      let normalized = label.lowercased()
      let looksLikeLabel =
        normalized.hasSuffix(":") || normalized.contains(" parameter")
        || normalized.contains("argument")
      if looksLikeLabel { return 880 }
      switch kind {
      case .variable, .field, .property, .constant, .value, .enumMember: return 620
      case .method, .function, .constructor: return 430
      case .keyword
      where ["true", "false", "nil", "null", "none", "self", "this", "super"].contains(
        normalized):
        return 320
      case .class, .interface, .enum, .struct, .typeParameter: return -180
      case .snippet: return -300
      default: return 0
      }

    case .pattern:
      switch kind {
      case .enumMember: return 900
      case .constant, .value: return 700
      case .variable, .field, .property: return 560
      case .class, .interface, .enum, .struct: return 360
      case .keyword
      where ["let", "var", "is", "as", "true", "false", "nil", "null", "none"].contains(
        label.lowercased()):
        return 440
      case .method, .function, .constructor, .snippet: return -420
      default: return 0
      }

    case .condition:
      switch kind {
      case .variable, .field, .property: return 700
      case .method, .function: return 620
      case .constant, .enumMember, .value: return 540
      case .keyword
      where ["true", "false", "nil", "null", "none", "self", "this", "super"].contains(
        label.lowercased()):
        return 470
      case .constructor: return 180
      case .class, .interface, .enum, .struct, .typeParameter: return -650
      case .snippet: return -520
      default: return 0
      }

    case .attribute:
      switch kind {
      case .keyword, .snippet: return 780
      case .class, .interface, .struct, .enum, .module: return 520
      case .function, .method: return 180
      case .variable, .field, .property, .constant, .value: return -520
      default: return 0
      }

    case .expression:
      switch kind {
      case .variable, .field, .property: return 650
      case .method, .function: return 560
      case .constant, .enumMember, .value: return 480
      case .constructor: return 300
      case .class, .struct, .enum: return 170
      case .keyword
      where ["true", "false", "nil", "null", "none", "self", "this", "super"].contains(
        label.lowercased()):
        return 310
      case .keyword: return -130
      case .snippet: return -170
      default: return 0
      }

    case .statement:
      switch kind {
      case .snippet: return 620
      case .keyword: return 500
      case .method, .function: return 330
      case .variable, .field, .property: return 230
      case .class, .struct, .enum, .constructor: return 150
      case .constant: return 80
      default: return 0
      }

    case .unknown:
      switch kind {
      case .variable, .field, .property: return 330
      case .method, .function: return 310
      case .constant, .enumMember: return 210
      case .constructor, .class, .interface, .enum, .struct: return 170
      case .keyword, .snippet: return 80
      default: return 0
      }
    }
  }
}

private struct CompletionRankingScore: Sendable {
  var total: Int
  var name: Int
  var semantic: Int
  var quality: Int
  var usage: Int
}

private struct RankedCompletion {
  var completion: Completion
  var originalIndex: Int
  var score: CompletionRankingScore
}

private enum CompletionRankingRole: Sendable {
  case memberAccess
  case typePosition
  case importPath
  case declaration(Set<CompletionKind>)
  case callable
  case argument
  case pattern
  case condition
  case attribute
  case expression
  case statement
  case unknown

  var isMemberAccess: Bool {
    if case .memberAccess = self { return true }
    return false
  }

  var isStatement: Bool {
    if case .statement = self { return true }
    return false
  }

  var isImportPath: Bool {
    if case .importPath = self { return true }
    return false
  }
}

private struct CompletionRankingContext: Sendable {
  var prefix: String
  var role: CompletionRankingRole
  var receiver: String?
  var receiverType: String?
  var isStaticReceiver: Bool
  var expectedType: String?
  var currentType: String?
  var baseTypes: Set<String>
  var currentFunction: String?
  var isStaticContext: Bool
  var expectsOverride: Bool
  var isQualifiedDefinition: Bool
  var localNames: Set<String>
  var parameterNames: Set<String>
  var fileRole: CompletionSourceFileRole
  var currentFileStem: String
  var symbolsByName: [String: [ProjectCompletionSymbol]]
  var membersByReceiver: [String: Set<String>]
  var allMemberNames: Set<String>
  var callableNames: Set<String>
  var contextWords: [String: Int]
  var languageStrategy: any CompletionLanguageStrategy
  var initializerContext: CompletionInitializerContext?

  init(
    snapshot: TextSnapshot,
    position: TextPosition,
    invocation: EditorCompletionInvocation,
    languageID: String,
    currentURI: URL?,
    projectSymbols: [ProjectCompletionSymbol]
  ) throws {
    let caret = try snapshot.utf16Offset(of: position)
    let identifierRange = try CompletionUtilities.inferredIdentifierRange(
      in: snapshot,
      endingAt: position
    )
    let prefixRange = try snapshot.nsRange(for: identifierRange)
    let source = snapshot.text as NSString
    prefix = source.substring(with: prefixRange)
    languageStrategy = CompletionLanguageStrategyRegistry.strategy(for: languageID)
    initializerContext = languageStrategy.initializerContext(
      in: snapshot.text,
      caretUTF16Offset: caret
    )

    let lexical = CompletionStructuralAnalysis.lexicalContext(
      in: snapshot.text,
      languageID: languageID,
      caret: caret
    )
    currentType = lexical.currentType
    baseTypes = lexical.baseTypes
    currentFunction = lexical.currentFunction
    isStaticContext = lexical.isStaticContext
    localNames = lexical.localNames
    parameterNames = lexical.parameterNames
    fileRole =
      currentURI.map {
        CompletionSourceFileRole.classify(url: $0, languageID: languageID)
      } ?? .other
    currentFileStem = currentURI?.deletingPathExtension().lastPathComponent ?? ""
    symbolsByName = Dictionary(grouping: projectSymbols) { $0.name.lowercased() }

    let prefixStart = prefixRange.location
    let lineStart = Self.lineStart(in: source, before: prefixStart)
    let linePrefix = source.substring(
      with: NSRange(location: lineStart, length: max(0, prefixStart - lineStart))
    )
    let nearbyStart = max(0, prefixStart - 320)
    let nearby = source.substring(
      with: NSRange(location: nearbyStart, length: max(0, prefixStart - nearbyStart))
    )
    expectsOverride =
      linePrefix.lowercased().range(
        of: #"\b(?:override|implements?)\b"#,
        options: .regularExpression
      ) != nil

    receiver = Self.receiver(in: nearby)
    isQualifiedDefinition = Self.qualifiedDefinitionContext(
      in: linePrefix,
      receiver: receiver,
      languageID: languageID,
      currentFileStem: currentFileStem,
      currentFunction: currentFunction
    )
    if let receiver {
      let receiverKey = receiver.lowercased()
      if ["self", "this", "super"].contains(receiverKey) {
        receiverType = lexical.currentType
        isStaticReceiver =
          !isQualifiedDefinition
          && receiverKey == "self" && receiver.first?.isUppercase == true
      } else if let inferred = lexical.variableTypes[receiverKey] {
        receiverType = Self.baseTypeName(inferred)
        isStaticReceiver = false
      } else {
        receiverType = Self.baseTypeName(receiver)
        isStaticReceiver =
          !isQualifiedDefinition
          && (receiver.first?.isUppercase == true
            || projectSymbols.contains { symbol in
              symbol.ownerType?.caseInsensitiveCompare(receiver) == .orderedSame
                || (symbol.kind == .class || symbol.kind == .struct || symbol.kind == .enum
                  || symbol.kind == .interface)
                  && symbol.name.caseInsensitiveCompare(receiver) == .orderedSame
            })
      }
    } else {
      receiverType = nil
      isStaticReceiver = false
    }
    let isReturnExpression =
      linePrefix.range(
        of: #"\b(?:return|yield)\s*$"#,
        options: .regularExpression
      ) != nil
    expectedType =
      Self.expectedType(in: linePrefix)
      ?? (isReturnExpression ? lexical.currentFunctionReturnType : nil)
    role = Self.role(
      typedLine: linePrefix + prefix,
      beforePrefix: linePrefix,
      nearby: nearby,
      invocation: invocation,
      receiver: receiver,
      languageID: languageID
    )

    let evidence = Self.symbolEvidence(in: snapshot.text, languageID: languageID, caret: caret)
    membersByReceiver = evidence.membersByReceiver
    allMemberNames = evidence.allMembers
    callableNames = evidence.callables
    contextWords = Self.contextWords(
      in: snapshot.text,
      languageID: languageID,
      caret: caret,
      excluding: prefix
    )
  }

  private static func role(
    typedLine: String,
    beforePrefix: String,
    nearby: String,
    invocation: EditorCompletionInvocation,
    receiver: String?,
    languageID: String
  ) -> CompletionRankingRole {
    let trimmed = typedLine.trimmingCharacters(in: .whitespaces)
    let lower = trimmed.lowercased()
    let beforeTrimmed = beforePrefix.trimmingCharacters(in: .whitespaces)

    if receiver != nil
      || (invocation.triggerCharacter == "." && beforeTrimmed.hasSuffix("."))
    {
      return .memberAccess
    }

    if lower.range(
      of: #"^(?:#\s*include|#\s*import|import|from|use|include|require|package|mod)\b"#,
      options: .regularExpression
    ) != nil {
      return .importPath
    }

    let normalizedLanguage = CompletionStructuralAnalysis.normalizedLanguage(languageID)
    let attributeContext =
      beforeTrimmed.hasSuffix("@")
      || (normalizedLanguage == "rust" && lower.hasPrefix("#[") && !lower.contains("]"))
      || (normalizedLanguage == "csharp" && lower.hasPrefix("[") && !lower.contains("]"))
      || (normalizedLanguage == "cpp" && lower.hasPrefix("[[") && !lower.contains("]]"))
    if attributeContext { return .attribute }

    let typePatterns = [
      #"(?:->|\bas\s+|\bis\s+|\bnew\s+|\bextends\s+|\bimplements\s+)\s*[\p{L}_][\p{L}\p{N}_.<>?&\[\]]*$"#,
      #"\b(?:let|var|val|const|typealias)\s+[\p{L}_][\p{L}\p{N}_]*\s*:\s*[\p{L}_][\p{L}\p{N}_.<>?&\[\]]*$"#,
      #"\b(?:actor|class|enum|interface|protocol|record|struct|trait|type)\s+[\p{L}_][\p{L}\p{N}_]*\s*:\s*[\p{L}_][\p{L}\p{N}_.<>?&\[\]]*$"#,
      #"\bwhere\s+[\p{L}_][\p{L}\p{N}_]*\s*:\s*[\p{L}_][\p{L}\p{N}_.<>?&\[\]]*$"#,
      #"<[^{>]*[\p{L}_][\p{L}\p{N}_]*\s*:\s*[\p{L}_][\p{L}\p{N}_.<>?&\[\]]*$"#,
      #"\b(?:func|fn|def|fun|function)\b[^()]*\([^)]*[\p{L}_][\p{L}\p{N}_]*\s*:\s*[\p{L}_][\p{L}\p{N}_.<>?&\[\]]*$"#,
    ]
    if typePatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil })
      || lower.hasSuffix("->")
    {
      return .typePosition
    }

    if lower.range(of: #"\b(?:let|var|val|const)\s+[\p{L}_\p{N}]*$"#, options: .regularExpression)
      != nil
    {
      return .declaration([.variable, .field, .property, .constant])
    }
    if lower.range(
      of: #"\b(?:func|fn|def|fun|function)\s+[\p{L}_\p{N}]*$"#, options: .regularExpression) != nil
    {
      return .declaration([.method, .function])
    }
    if lower.range(
      of:
        #"\b(?:actor|class|enum|interface|protocol|record|struct|trait|typealias|type)\s+[\p{L}_\p{N}]*$"#,
      options: .regularExpression
    ) != nil {
      return .declaration([.class, .interface, .enum, .struct, .typeParameter])
    }

    if lower.range(
      of: #"\b(?:func|fn|def|fun|function)\b[^{}=]*\([^)]*(?:^|[,\s])?[\p{L}_][\p{L}\p{N}_]*$"#,
      options: .regularExpression
    ) != nil {
      return .declaration([.variable, .property])
    }

    if lower.range(
      of: #"\b(?:case|if\s+case|guard\s+case)\s+[\p{L}_\p{N}.]*$"#,
      options: .regularExpression
    ) != nil {
      return .pattern
    }

    if lower.range(of: #"(?:\bawait\s+|\btry[!?]?\s+)[\p{L}_\p{N}]*$"#, options: .regularExpression)
      != nil
    {
      return .callable
    }

    if Self.argumentPosition(in: nearby) { return .argument }

    if lower.range(
      of: #"^(?:else\s+)?(?:if|guard|while)\b.*[\p{L}_\p{N}]*$"#,
      options: .regularExpression
    ) != nil {
      return .condition
    }

    if lower.range(
      of: #"(?:=|\breturn|\byield|\bthrow|=>)\s*[\p{L}_\p{N}]*$"#,
      options: .regularExpression
    ) != nil {
      return .expression
    }

    if beforeTrimmed.isEmpty || beforeTrimmed.hasSuffix("{") || beforeTrimmed.hasSuffix(";") {
      return .statement
    }

    return .unknown
  }

  private static func argumentPosition(in text: String) -> Bool {
    var depth = 0
    let characters = Array(text)
    for index in characters.indices.reversed() {
      switch characters[index] {
      case ")", "]": depth += 1
      case "(", "[":
        if depth == 0 {
          guard characters[index] == "(" else { return false }
          let before = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
          guard let last = before.last,
            last.isLetter || last.isNumber || last == "_" || last == ")" || last == "]"
          else { return false }
          let tail = String(characters[characters.index(after: index)...])
          return !tail.contains(";") && !tail.contains("{")
        }
        depth -= 1
      case "{", "}": if depth == 0 { return false }
      default: break
      }
    }
    return false
  }

  private static func receiver(in nearby: String) -> String? {
    let pattern = #"([\p{L}_][\p{L}\p{N}_]*)(?:[?!])?\s*(?:\.|::|->)\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: nearby,
        range: NSRange(location: 0, length: (nearby as NSString).length)
      ),
      match.range(at: 1).location != NSNotFound
    else { return nil }
    return (nearby as NSString).substring(with: match.range(at: 1))
  }

  private static func qualifiedDefinitionContext(
    in linePrefix: String,
    receiver: String?,
    languageID: String,
    currentFileStem: String,
    currentFunction: String?
  ) -> Bool {
    guard let receiver,
      ["cpp", "c++", "objective-cpp", "csharp"].contains(languageID.lowercased())
    else { return false }
    let escaped = NSRegularExpression.escapedPattern(for: receiver)
    let pattern =
      #"^\s*(?:(?:template\s*<[^>]*>|[\p{L}_][\p{L}\p{N}_:<>,*&?\[\]]*)\s+)+"#
      + escaped + #"::[~\p{L}_\p{N}]*$"#
    if linePrefix.range(of: pattern, options: .regularExpression) != nil { return true }
    let constructorPattern = #"^\s*"# + escaped + #"::[~\p{L}_\p{N}]*$"#
    return currentFunction == nil
      && currentFileStem.caseInsensitiveCompare(receiver) == .orderedSame
      && linePrefix.range(of: constructorPattern, options: .regularExpression) != nil
  }

  private static func baseTypeName(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "&*?[] "))
    let withoutGeneric =
      trimmed.split(separator: "<", maxSplits: 1).first.map(String.init) ?? trimmed
    return withoutGeneric.split(separator: ".").last.map(String.init) ?? withoutGeneric
  }

  private static func expectedType(in linePrefix: String) -> String? {
    let pattern = #":\s*([\p{L}_][\p{L}\p{N}_.<>?&\[\]]*)\s*=\s*[^;\n]*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: linePrefix,
        range: NSRange(location: 0, length: (linePrefix as NSString).length)
      ),
      match.range(at: 1).location != NSNotFound
    else { return nil }
    return (linePrefix as NSString).substring(with: match.range(at: 1))
  }

  private static func symbolEvidence(
    in text: String,
    languageID: String,
    caret: Int
  ) -> (membersByReceiver: [String: Set<String>], allMembers: Set<String>, callables: Set<String>) {
    let masked = RankingCodeMask.maskedCode(text, languageID: languageID)
    let source = masked as NSString
    var membersByReceiver: [String: Set<String>] = [:]
    var allMembers = Set<String>()
    var callables = Set<String>()

    if let memberRegex = try? NSRegularExpression(
      pattern: #"([\p{L}_][\p{L}\p{N}_]*)(?:[?!])?\s*(?:\.|::|->)\s*([\p{L}_][\p{L}\p{N}_]*)"#
    ) {
      for match in memberRegex.matches(
        in: masked,
        range: NSRange(location: 0, length: source.length)
      ) where match.numberOfRanges >= 3 {
        let receiver = source.substring(with: match.range(at: 1)).lowercased()
        let member = source.substring(with: match.range(at: 2)).lowercased()
        membersByReceiver[receiver, default: []].insert(member)
        allMembers.insert(member)
      }
    }

    if let callRegex = try? NSRegularExpression(
      pattern: #"\b([\p{L}_][\p{L}\p{N}_]*)\s*\("#
    ) {
      for match in callRegex.matches(
        in: masked,
        range: NSRange(location: 0, length: source.length)
      ) where match.numberOfRanges >= 2 {
        callables.insert(source.substring(with: match.range(at: 1)).lowercased())
      }
    }

    return (membersByReceiver, allMembers, callables)
  }

  private static func contextWords(
    in text: String,
    languageID: String,
    caret: Int,
    excluding prefix: String
  ) -> [String: Int] {
    let masked = RankingCodeMask.maskedCode(text, languageID: languageID) as NSString
    let end = min(max(0, caret), masked.length)
    let start = max(0, end - 1_200)
    let nearby = masked.substring(with: NSRange(location: start, length: end - start))
    guard let regex = try? NSRegularExpression(pattern: #"[\p{L}_][\p{L}\p{N}_]*"#) else {
      return [:]
    }
    let source = nearby as NSString
    let stopWords: Set<String> = [
      "as", "break", "case", "catch", "class", "const", "continue", "default", "defer",
      "do", "else", "enum", "false", "for", "func", "function", "guard", "if", "import",
      "in", "interface", "is", "let", "nil", "none", "null", "package", "protocol",
      "return", "self", "static", "struct", "super", "switch", "this", "throw", "throws",
      "true", "try", "type", "var", "while", "yield",
    ]
    let excluded = Set(CompletionIdentifierTokenizer.words(in: prefix))
    let matches = regex.matches(in: nearby, range: NSRange(location: 0, length: source.length))
      .suffix(48)
    var words: [String: Int] = [:]
    for (distance, match) in matches.reversed().enumerated() {
      let identifier = source.substring(with: match.range)
      let recency = max(18, 90 - distance * 3)
      for word in CompletionIdentifierTokenizer.words(in: identifier) {
        guard word.count > 1, !excluded.contains(word), !stopWords.contains(word) else {
          continue
        }
        let existing = words[word] ?? 0
        words[word] = min(110, max(existing, recency) + (existing > 0 ? 8 : 0))
      }
    }
    return words
  }

  private static func lineStart(in source: NSString, before offset: Int) -> Int {
    var index = min(offset, source.length)
    while index > 0 {
      let previous = source.character(at: index - 1)
      if previous == 10 || previous == 13 { break }
      index -= 1
    }
    return index
  }

}

extension CompletionKind {
  fileprivate var isCallable: Bool {
    switch self {
    case .method, .function, .constructor: return true
    default: return false
    }
  }
}

private enum RankingCodeMask {
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
    let slashComments = !hashComments && !dashComments && language != "markdown"

    while index < source.length {
      let current = source.character(at: index)
      let next = index + 1 < source.length ? source.character(at: index + 1) : 0
      switch state {
      case .code:
        if current == 10 || current == 13 {
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
