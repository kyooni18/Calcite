import Foundation

struct VimParsedExCommand: Sendable {
  var range: String?
  var name: String
  var bang: Bool
  var arguments: String
}

enum VimExParser {
  static func parse(_ raw: String) -> VimParsedExCommand {
    var source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if source.first == ":" { source.removeFirst() }
    source = source.trimmingCharacters(in: .whitespaces)

    let range = consumeRangePrefix(from: &source)

    var name = ""
    if source.first == "&" || source.first == "~" {
      name.append(source.removeFirst())
    } else {
      while let first = source.first, first.isLetter {
        name.append(first)
        source.removeFirst()
      }
    }

    var bang = false
    if source.first == "!" {
      bang = true
      source.removeFirst()
    }

    return VimParsedExCommand(
      range: range,
      name: name.lowercased(),
      bang: bang,
      arguments: source.trimmingCharacters(in: .whitespaces)
    )
  }

  static func splitCommands(_ raw: String) -> [String] {
    var result: [String] = []
    var current = ""
    var escaped = false
    for character in raw {
      if escaped {
        current.append("\\")
        current.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "|" {
        let value = current.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty { result.append(value) }
        current = ""
      } else {
        current.append(character)
      }
    }
    if escaped { current.append("\\") }
    let value = current.trimmingCharacters(in: .whitespaces)
    if !value.isEmpty { result.append(value) }
    return result
  }

  static func matches(_ abbreviation: String, command: String, minimum: Int = 1) -> Bool {
    abbreviation.count >= minimum
      && abbreviation.count <= command.count
      && command.hasPrefix(abbreviation)
  }

  private static func consumeRangePrefix(from source: inout String) -> String? {
    guard !source.isEmpty else { return nil }

    var cursor = source.startIndex
    let start = cursor

    if source[cursor] == "%" {
      cursor = source.index(after: cursor)
    } else {
      guard consumeAddress(in: source, cursor: &cursor) else { return nil }

      if cursor < source.endIndex, source[cursor] == "," || source[cursor] == ";" {
        cursor = source.index(after: cursor)
        _ = consumeAddress(in: source, cursor: &cursor)
      }
    }

    let range = String(source[start..<cursor])
    source.removeSubrange(start..<cursor)
    return range.isEmpty ? nil : range
  }

  private static func consumeAddress(in source: String, cursor: inout String.Index) -> Bool {
    guard cursor < source.endIndex else { return false }
    let original = cursor

    switch source[cursor] {
    case ".", "$":
      cursor = source.index(after: cursor)
    case "'", "`":
      cursor = source.index(after: cursor)
      guard cursor < source.endIndex else {
        cursor = original
        return false
      }
      cursor = source.index(after: cursor)
    case "/", "?":
      let delimiter = source[cursor]
      cursor = source.index(after: cursor)
      var escaped = false
      while cursor < source.endIndex {
        let value = source[cursor]
        cursor = source.index(after: cursor)
        if escaped {
          escaped = false
        } else if value == "\\" {
          escaped = true
        } else if value == delimiter {
          break
        }
      }
    default:
      if source[cursor].isNumber {
        while cursor < source.endIndex, source[cursor].isNumber {
          cursor = source.index(after: cursor)
        }
      } else if source[cursor] != "+" && source[cursor] != "-" {
        return false
      }
    }

    while cursor < source.endIndex, source[cursor] == "+" || source[cursor] == "-" {
      cursor = source.index(after: cursor)
      while cursor < source.endIndex, source[cursor].isNumber {
        cursor = source.index(after: cursor)
      }
    }

    return cursor > original
  }
}
