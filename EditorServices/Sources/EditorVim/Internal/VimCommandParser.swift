import Foundation

/// Persistent parser state for one Vim command.
///
/// The same state machine is used by direct notation execution and by
/// `VimKeymapController`, avoiding repeated reparsing of every pending prefix.
struct VimCommandParser: Sendable {
  var count = 0
  var pendingOperator: (value: VimOperator, count: Int, register: VimRegister)?
  var pendingOperatorG = false
  var pendingTextObjectInner: Bool?
  var pendingG = false
  var pendingFind: (forward: Bool, till: Bool, count: Int)?
  var pendingReplace = false
  var pendingMark = false
  var pendingJump: Bool?
  var pendingMacro = false
  var pendingMacroStart = false
  var pendingRegister = false
  var selectedRegister: VimRegister = .unnamed
  var temporaryNormalTokenCount = 0

  var isIncomplete: Bool {
    count > 0
      || pendingG
      || pendingOperator != nil
      || pendingOperatorG
      || pendingTextObjectInner != nil
      || pendingFind != nil
      || pendingReplace
      || pendingMark
      || pendingJump != nil
      || pendingMacro
      || pendingMacroStart
      || pendingRegister
  }

  var isAtCommandBoundary: Bool { !isIncomplete }

  mutating func reset() {
    self = VimCommandParser()
  }

  mutating func resetRegister() {
    selectedRegister = .unnamed
  }

  static func tokens(in notation: String) -> [String] {
    var values: [String] = []
    var index = notation.startIndex
    while index < notation.endIndex {
      if notation[index] == "<", let end = notation[index...].firstIndex(of: ">") {
        values.append(String(notation[index...end]))
        index = notation.index(after: end)
      } else {
        values.append(String(notation[index]))
        index = notation.index(after: index)
      }
    }
    return values
  }

  static func register(for character: Character) throws -> VimRegister {
    if character == "\"" { return .unnamed }
    if character == "_" { return .blackHole }
    if character == "-" { return .smallDelete }
    if character == "+" || character == "*" { return .clipboard }
    if character == "." || character == ":" || character == "/" {
      return .named(character)
    }
    if let digit = character.wholeNumberValue { return .numbered(digit) }
    if character.isLetter { return .named(character) }
    throw VimError.invalidRegister
  }

  static func operatorToken(for value: VimOperator) -> String {
    switch value {
    case .delete: return "d"
    case .change: return "c"
    case .yank: return "y"
    case .indent: return ">"
    case .outdent: return "<"
    default: return ""
    }
  }

  static func motion(for token: String) -> VimMotion? {
    switch token {
    case "h": return .left
    case "j": return .down
    case "k": return .up
    case "l": return .right
    case "w": return .wordForward
    case "b": return .wordBackward
    case "e": return .wordEnd
    case "0": return .lineStart
    case "^": return .firstNonBlank
    case "$": return .lineEnd
    case "G": return .documentEnd
    case "%": return .matchingPair
    default: return nil
    }
  }

  static func textObject(for token: String) -> VimTextObject? {
    switch token {
    case "w": return .word
    case "W": return .WORD
    case "p": return .paragraph
    case "s": return .sentence
    case "\"", "'", "`": return token.first.map(VimTextObject.quotes)
    case "(", ")", "b": return .parentheses
    case "[", "]": return .brackets
    case "{", "}", "B": return .braces
    case "<", ">": return .angles
    case "t": return .tag
    default: return nil
    }
  }
}
