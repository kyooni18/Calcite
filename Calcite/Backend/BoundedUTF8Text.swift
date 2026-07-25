import Foundation

nonisolated enum BoundedUTF8Text {
  static func suffix(of value: String, maximumBytes: Int) -> String {
    guard maximumBytes > 0 else { return "" }
    guard value.utf8.count > maximumBytes else { return value }

    var bytes = value.utf8.suffix(maximumBytes)
    while let first = bytes.first, (0x80...0xBF).contains(first) {
      bytes = bytes.dropFirst()
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
