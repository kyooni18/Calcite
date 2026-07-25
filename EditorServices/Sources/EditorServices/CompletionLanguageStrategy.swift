import EditorCore
import Foundation

/// A language-neutral description of an initializer or object-construction position.
///
/// The completion pipeline uses this model for Rust struct literals, Swift initializers,
/// Python keyword arguments, TypeScript object literals, and C-family designated initializers.
struct CompletionInitializerContext: Sendable {
  enum Position: Sendable, Equatable {
    case memberName
    case memberValue(memberName: String)
  }

  var typeName: String
  var usedMembers: Set<String>
  var position: Position
}

struct CompletionVisibleBinding: Sendable, Equatable {
  var name: String
  var typeName: String?
}

/// The subset of editor context that may legitimately differ by language.
/// Generic ranking remains in CompletionRankingEngine; strategies only contribute language rules.
struct CompletionLanguageRankingInput: Sendable {
  var kind: CompletionKind
  var label: String
  var detail: String?
  var documentation: String?
  var isMemberAccess: Bool
  var isStaticReceiver: Bool
  var expectedType: String?
  var initializerContext: CompletionInitializerContext?
}

protocol CompletionLanguageStrategy: Sendable {
  var languageIDs: Set<String> { get }

  func initializerContext(in text: String, caretUTF16Offset: Int) -> CompletionInitializerContext?

  func visibleBindings(
    in text: String,
    caretUTF16Offset: Int,
    lexicalTypes: [String: String]
  ) -> [CompletionVisibleBinding]

  func canonicalType(_ raw: String?) -> String?
  func typesAreCompatible(_ lhs: String?, _ rhs: String?) -> Bool
  func defaultExpression(for rawType: String?) -> String
  func initializerInsertion(memberName: String, defaultExpression: String?) -> String
  func rankingAdjustment(_ input: CompletionLanguageRankingInput) -> Int
}

extension CompletionLanguageStrategy {
  func typesAreCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs = canonicalType(lhs), let rhs = canonicalType(rhs) else { return false }
    return lhs.caseInsensitiveCompare(rhs) == .orderedSame
  }

  func rankingAdjustment(_ input: CompletionLanguageRankingInput) -> Int {
    CompletionLanguageRankingDefaults.adjustment(input)
  }
}

enum CompletionLanguageRankingDefaults {
  static func adjustment(_ input: CompletionLanguageRankingInput) -> Int {
    var score = 0
    if input.isMemberAccess {
      switch input.kind {
      case .method: score += 320
      case .property, .field: score += 90
      case .function: score += 40
      case .keyword, .snippet, .module, .file, .folder: score -= 180
      default: break
      }
    }

    if let initializer = input.initializerContext {
      switch initializer.position {
      case .memberName:
        switch input.kind {
        case .field, .property: score += 780
        case .variable: score += 120
        case .method, .function, .constructor: score -= 420
        case .keyword, .snippet, .module, .file, .folder: score -= 620
        default: score -= 80
        }
      case .memberValue:
        switch input.kind {
        case .variable, .field, .property, .constant, .value, .enumMember: score += 360
        case .function, .method, .constructor: score += 150
        case .keyword: score += 40
        case .class, .interface, .enum, .struct, .typeParameter: score -= 160
        default: break
        }
      }
    }
    return score
  }
}

enum CompletionLanguageStrategyRegistry {
  private static let strategies: [any CompletionLanguageStrategy] = [
    RustCompletionLanguageStrategy(),
    SwiftCompletionLanguageStrategy(),
    PythonCompletionLanguageStrategy(),
    JavaScriptCompletionLanguageStrategy(),
    GoCompletionLanguageStrategy(),
    LuaCompletionLanguageStrategy(),
    CFamilyCompletionLanguageStrategy(),
    GenericCompletionLanguageStrategy(),
  ]

  static func strategy(for languageID: String) -> any CompletionLanguageStrategy {
    let normalized = CompletionStructuralAnalysis.normalizedLanguage(languageID)
    return strategies.first { $0.languageIDs.contains(normalized) }
      ?? GenericCompletionLanguageStrategy()
  }
}

enum CompletionSyntaxUtilities {
  static func clampedCaret(_ caretUTF16Offset: Int, in source: NSString) -> Int {
    min(max(0, caretUTF16Offset), source.length)
  }

  static func unmatchedOpening(
    open: unichar,
    close: unichar,
    before caret: Int,
    in source: NSString
  ) -> Int? {
    var depth = 0
    var index = caret
    while index > 0 {
      index -= 1
      let character = source.character(at: index)
      if character == close {
        depth += 1
      } else if character == open {
        if depth == 0 { return index }
        depth -= 1
      }
    }
    return nil
  }

  static func firstTopLevelIndex(of target: Character, in value: String) -> String.Index? {
    var round = 0
    var square = 0
    var angle = 0
    var brace = 0
    var quote: Character?
    var escaped = false
    for index in value.indices {
      let character = value[index]
      if let activeQuote = quote {
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
      if character == target, round == 0, square == 0, angle == 0, brace == 0 { return index }
    }
    return nil
  }

  static func topLevelComponents(
    in value: String,
    separatedBy separator: Character
  ) -> [String] {
    var values: [String] = []
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
        values.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    values.append(current)
    return values
  }

  static func identifierWords(in value: String) -> [String] {
    value.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "$" }
      .map(String.init)
  }

  static func regexCaptures(
    pattern: String,
    in text: String,
    groups: [Int]
  ) -> [[String?]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let source = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
      match in
      groups.map { group in
        guard group < match.numberOfRanges, match.range(at: group).location != NSNotFound else {
          return nil
        }
        return source.substring(with: match.range(at: group))
      }
    }
  }

  static func canonicalNominalType(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    value = value.replacingOccurrences(
      of: #"^(?:&\s*(?:'[^\s]+\s*)?(?:mut\s+)?|\*const\s+|\*mut\s+|inout\s+|some\s+|any\s+)"#,
      with: "",
      options: .regularExpression
    )
    if let optional = value.firstIndex(of: "?") { value = String(value[..<optional]) }
    if let generic = value.firstIndex(of: "<") { value = String(value[..<generic]) }
    if let bracket = value.firstIndex(of: "[") { value = String(value[..<bracket]) }
    let identifiers = identifierWords(in: value)
    return identifiers.last
  }

  static func sortedBindings(_ values: [String: CompletionVisibleBinding])
    -> [CompletionVisibleBinding]
  {
    values.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
