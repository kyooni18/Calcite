import Foundation

enum VimRegexMagic {
  case veryMagic
  case magic
  case nomagic
  case veryNomagic
}

struct VimCompiledRegex {
  var expression: NSRegularExpression
  var sourcePattern: String
}

enum VimRegexCompiler {
  static func compile(
    _ pattern: String,
    ignoreCase: Bool,
    smartCase: Bool,
    forceCaseInsensitive: Bool? = nil
  ) throws -> VimCompiledRegex {
    var caseOverride: Bool?
    let translated = translate(pattern, caseOverride: &caseOverride)
    let containsUppercase = pattern.unicodeScalars.contains {
      CharacterSet.uppercaseLetters.contains($0)
    }
    let caseInsensitive =
      forceCaseInsensitive
      ?? caseOverride
      ?? (ignoreCase && !(smartCase && containsUppercase))
    let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
    return VimCompiledRegex(
      expression: try NSRegularExpression(pattern: translated, options: options),
      sourcePattern: pattern
    )
  }

  static func replacementTemplate(_ replacement: String) -> String {
    var result = ""
    var index = replacement.startIndex
    while index < replacement.endIndex {
      let character = replacement[index]
      if character == "\\" {
        let nextIndex = replacement.index(after: index)
        guard nextIndex < replacement.endIndex else {
          result += "\\\\"
          break
        }
        let next = replacement[nextIndex]
        if let digit = next.wholeNumberValue, digit <= 9 {
          result += "$\(digit)"
        } else {
          switch next {
          case "&": result += "&"
          case "r", "n": result += "\n"
          case "\\": result += "\\\\"
          default: result += escapeReplacementLiteral(String(next))
          }
        }
        index = replacement.index(after: nextIndex)
      } else {
        if character == "&" {
          result += "$0"
        } else {
          result += escapeReplacementLiteral(String(character))
        }
        index = replacement.index(after: index)
      }
    }
    return result
  }

  static func veryNomagicLiteral(_ literal: String) -> String {
    "\\V" + literal.replacingOccurrences(of: "\\", with: "\\\\")
  }

  private static func translate(
    _ pattern: String,
    caseOverride: inout Bool?
  ) -> String {
    var magic: VimRegexMagic = .magic
    var result = ""
    var inCharacterClass = false
    var index = pattern.startIndex

    while index < pattern.endIndex {
      let character = pattern[index]
      if character == "\\" {
        let nextIndex = pattern.index(after: index)
        guard nextIndex < pattern.endIndex else {
          result += "\\\\"
          break
        }
        let next = pattern[nextIndex]
        switch next {
        case "c": caseOverride = true
        case "C": caseOverride = false
        case "v": magic = .veryMagic
        case "m": magic = .magic
        case "M": magic = .nomagic
        case "V": magic = .veryNomagic
        case "<", ">": result += "\\b"
        case "=": result += "?"
        case "(", ")", "|", "+", "?", "{", "}":
          if magic == .veryNomagic {
            result += NSRegularExpression.escapedPattern(for: String(next))
          } else {
            result.append(next)
          }
        case "n": result += "\\n"
        default:
          if magic == .veryNomagic {
            result += NSRegularExpression.escapedPattern(for: String(next))
          } else {
            result.append("\\")
            result.append(next)
          }
        }
        index = pattern.index(after: nextIndex)
        continue
      }

      if character == "[" && magic != .veryNomagic {
        inCharacterClass = true
        result.append(character)
      } else if character == "]" && inCharacterClass {
        inCharacterClass = false
        result.append(character)
      } else if inCharacterClass {
        result.append(character)
      } else {
        result += translateUnescaped(character, magic: magic)
      }
      index = pattern.index(after: index)
    }
    return result
  }

  private static func translateUnescaped(_ character: Character, magic: VimRegexMagic) -> String {
    let value = String(character)
    switch magic {
    case .veryMagic:
      return value
    case .magic:
      // Preserve the Stage 3 acceptance of ICU/NSRegularExpression syntax
      // while also translating Vim escaped operators. This intentionally
      // accepts a superset of Vim's default-magic grammar.
      return value
    case .nomagic:
      if ".[]*+?()|{}".contains(character) {
        return NSRegularExpression.escapedPattern(for: value)
      }
      return value
    case .veryNomagic:
      return NSRegularExpression.escapedPattern(for: value)
    }
  }

  private static func escapeReplacementLiteral(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "$", with: "\\$")
  }
}
