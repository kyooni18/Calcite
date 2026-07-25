import Foundation

/// Incrementally decodes UTF-8 without losing scalar sequences split across read boundaries.
///
/// Invalid byte sequences are replaced using Swift's standard UTF-8 repair behavior. At most
/// three bytes are retained between calls because a valid UTF-8 scalar is no longer than four
/// bytes.
public struct IncrementalUTF8Decoder: Sendable {
  private var pending: [UInt8] = []

  public init() {}

  public var hasPendingBytes: Bool { !pending.isEmpty }

  public mutating func decode(_ data: Data) -> String {
    decodeBytes(data)
  }

  public mutating func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    decodeBytes(bytes)
  }

  private mutating func decodeBytes<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    var combined = pending
    combined.append(contentsOf: bytes)
    pending.removeAll(keepingCapacity: true)

    let completeCount = Self.completePrefixLength(in: combined)
    guard completeCount < combined.count else {
      return String(decoding: combined, as: UTF8.self)
    }

    pending.append(contentsOf: combined[completeCount...])
    return String(decoding: combined[..<completeCount], as: UTF8.self)
  }

  /// Flushes any incomplete trailing sequence using standard replacement semantics.
  public mutating func finish() -> String {
    defer { pending.removeAll(keepingCapacity: true) }
    return String(decoding: pending, as: UTF8.self)
  }

  public mutating func reset() {
    pending.removeAll(keepingCapacity: true)
  }

  private static func completePrefixLength(in bytes: [UInt8]) -> Int {
    var index = 0
    while index < bytes.count {
      let first = bytes[index]
      let length = sequenceLength(for: first)

      // Invalid leading bytes are complete input on their own and are repaired by String(decoding:).
      guard length > 1 else {
        index += 1
        continue
      }

      let remaining = bytes.count - index
      guard remaining >= length else { return index }
      guard sequenceIsValid(bytes, at: index, length: length) else {
        index += 1
        continue
      }
      index += length
    }
    return index
  }

  private static func sequenceLength(for byte: UInt8) -> Int {
    switch byte {
    case 0x00...0x7F: return 1
    case 0xC2...0xDF: return 2
    case 0xE0...0xEF: return 3
    case 0xF0...0xF4: return 4
    default: return 1
    }
  }

  private static func sequenceIsValid(_ bytes: [UInt8], at index: Int, length: Int) -> Bool {
    func isContinuation(_ byte: UInt8) -> Bool { (0x80...0xBF).contains(byte) }

    switch length {
    case 2:
      return isContinuation(bytes[index + 1])
    case 3:
      let first = bytes[index]
      let second = bytes[index + 1]
      let third = bytes[index + 2]
      guard isContinuation(third) else { return false }
      switch first {
      case 0xE0: return (0xA0...0xBF).contains(second)
      case 0xED: return (0x80...0x9F).contains(second)
      default: return isContinuation(second)
      }
    case 4:
      let first = bytes[index]
      let second = bytes[index + 1]
      guard isContinuation(bytes[index + 2]), isContinuation(bytes[index + 3]) else {
        return false
      }
      switch first {
      case 0xF0: return (0x90...0xBF).contains(second)
      case 0xF4: return (0x80...0x8F).contains(second)
      default: return isContinuation(second)
      }
    default:
      return true
    }
  }
}
