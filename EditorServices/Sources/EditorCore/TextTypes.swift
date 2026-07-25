import Foundation

public struct TextPosition: Hashable, Codable, Sendable, Comparable {
  public var line: Int
  public var utf16Column: Int

  public init(line: Int, utf16Column: Int) {
    self.line = line
    self.utf16Column = utf16Column
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.line, lhs.utf16Column) < (rhs.line, rhs.utf16Column)
  }

  public static let zero = TextPosition(line: 0, utf16Column: 0)
}

public struct EditorTextRange: Hashable, Codable, Sendable {
  public var start: TextPosition
  public var end: TextPosition

  public init(start: TextPosition, end: TextPosition) {
    self.start = start
    self.end = end
  }

  public var isEmpty: Bool { start == end }

  public func intersects(_ other: EditorTextRange) -> Bool {
    start < other.end && other.start < end
  }
}

public struct TextEdit: Hashable, Codable, Sendable {
  public var range: EditorTextRange
  public var replacement: String

  public init(range: EditorTextRange, replacement: String) {
    self.range = range
    self.replacement = replacement
  }
}

public enum TextBufferError: Error, Equatable, Sendable {
  case invalidPosition(TextPosition)
  case invalidUTF16Offset(Int)
  case reversedRange
  case overlappingEdits
  case versionOverflow
}

public struct TextSnapshot: Hashable, Sendable {
  public let text: String
  public let version: Int

  private let utf16Units: [UInt16]
  private let lineStarts: [Int]
  private let lineEnds: [Int]

  public init(text: String, version: Int = 0) {
    self.text = text
    self.version = version
    self.utf16Units = Array(text.utf16)

    var starts = [0]
    var ends: [Int] = []
    var index = 0
    while index < utf16Units.count {
      switch utf16Units[index] {
      case 0x000D:
        ends.append(index)
        if index + 1 < utf16Units.count, utf16Units[index + 1] == 0x000A {
          index += 2
        } else {
          index += 1
        }
        starts.append(index)
      case 0x000A:
        ends.append(index)
        index += 1
        starts.append(index)
      default:
        index += 1
      }
    }
    ends.append(utf16Units.count)
    self.lineStarts = starts
    self.lineEnds = ends
  }

  public var utf16Count: Int { utf16Units.count }
  public var lineCount: Int { lineStarts.count }

  public func lineUTF16Length(_ line: Int) throws -> Int {
    guard line >= 0, line < lineStarts.count else {
      throw TextBufferError.invalidPosition(.init(line: line, utf16Column: 0))
    }
    return lineEnds[line] - lineStarts[line]
  }

  public func utf16Offset(of position: TextPosition) throws -> Int {
    guard position.line >= 0,
      position.line < lineStarts.count,
      position.utf16Column >= 0
    else {
      throw TextBufferError.invalidPosition(position)
    }
    let lineLength = lineEnds[position.line] - lineStarts[position.line]
    guard position.utf16Column <= lineLength else {
      throw TextBufferError.invalidPosition(position)
    }
    return lineStarts[position.line] + position.utf16Column
  }

  public func position(atUTF16Offset offset: Int) throws -> TextPosition {
    guard offset >= 0, offset <= utf16Units.count else {
      throw TextBufferError.invalidUTF16Offset(offset)
    }

    var low = 0
    var high = lineStarts.count
    while low < high {
      let mid = (low + high) / 2
      if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
    }
    let line = max(0, low - 1)
    guard offset <= lineEnds[line] else {
      throw TextBufferError.invalidUTF16Offset(offset)
    }
    return TextPosition(line: line, utf16Column: offset - lineStarts[line])
  }

  public func nsRange(for range: EditorTextRange) throws -> NSRange {
    guard range.start <= range.end else { throw TextBufferError.reversedRange }
    let lower = try utf16Offset(of: range.start)
    let upper = try utf16Offset(of: range.end)
    return NSRange(location: lower, length: upper - lower)
  }

  public func utf8Offset(of position: TextPosition) throws -> Int {
    let offset = try utf16Offset(of: position)
    let index = String.Index(utf16Offset: offset, in: text)
    guard let utf8Index = index.samePosition(in: text.utf8) else {
      throw TextBufferError.invalidPosition(position)
    }
    return text.utf8.distance(from: text.utf8.startIndex, to: utf8Index)
  }

  public func utf8Column(of position: TextPosition) throws -> Int {
    let targetOffset = try utf16Offset(of: position)
    let lineStartOffset = lineStarts[position.line]
    let start = String.Index(utf16Offset: lineStartOffset, in: text)
    let target = String.Index(utf16Offset: targetOffset, in: text)
    guard let startUTF8 = start.samePosition(in: text.utf8),
      let targetUTF8 = target.samePosition(in: text.utf8)
    else {
      throw TextBufferError.invalidPosition(position)
    }
    return text.utf8.distance(from: startUTF8, to: targetUTF8)
  }

  public func substring(in range: EditorTextRange) throws -> String {
    (text as NSString).substring(with: try nsRange(for: range))
  }
}

public struct AppliedTextEdit: Hashable, Sendable {
  public let edit: TextEdit
  public let oldSnapshot: TextSnapshot
  public let newSnapshot: TextSnapshot
  public let oldUTF16Range: NSRange

  public init(
    edit: TextEdit, oldSnapshot: TextSnapshot, newSnapshot: TextSnapshot, oldUTF16Range: NSRange
  ) {
    self.edit = edit
    self.oldSnapshot = oldSnapshot
    self.newSnapshot = newSnapshot
    self.oldUTF16Range = oldUTF16Range
  }
}

/// Compatibility spelling retained for integrations that used the original text-range name.
public typealias TextRange = EditorTextRange
