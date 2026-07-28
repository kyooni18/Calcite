import Foundation

struct VimKeywordOptions: Sendable {
  private var includesLetters = true
  private var includesDigits = true
  private var includedRanges: [ClosedRange<UInt32>] = [95...95]
  private var excludedRanges: [ClosedRange<UInt32>] = []

  mutating func reset() {
    includesLetters = true
    includesDigits = true
    includedRanges = [95...95]
    excludedRanges = []
  }

  mutating func assign(_ specification: String) {
    includesLetters = false
    includesDigits = false
    includedRanges = []
    excludedRanges = []
    add(specification)
  }

  mutating func add(_ specification: String) {
    for atom in Self.atoms(in: specification) {
      if atom == "@" {
        includesLetters = true
      } else if atom == "48-57" {
        includesDigits = true
      } else if let range = Self.range(from: atom) {
        includedRanges.append(range)
        excludedRanges.removeAll { $0 == range }
      }
    }
  }

  mutating func remove(_ specification: String) {
    for atom in Self.atoms(in: specification) {
      if atom == "@" {
        includesLetters = false
      } else if atom == "48-57" {
        includesDigits = false
      } else if let range = Self.range(from: atom) {
        excludedRanges.append(range)
        includedRanges.removeAll { $0 == range }
      }
    }
  }

  func contains(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value
    if excludedRanges.contains(where: { $0.contains(value) }) { return false }
    if includedRanges.contains(where: { $0.contains(value) }) { return true }
    if includesLetters, CharacterSet.letters.contains(scalar) { return true }
    if includesDigits, CharacterSet.decimalDigits.contains(scalar) { return true }
    return false
  }

  private static func atoms(in specification: String) -> [String] {
    specification.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
  }

  private static func range(from atom: String) -> ClosedRange<UInt32>? {
    if atom.unicodeScalars.count == 1, let scalar = atom.unicodeScalars.first {
      return scalar.value...scalar.value
    }

    let components = atom.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard components.count == 2,
      let lower = scalarValue(String(components[0])),
      let upper = scalarValue(String(components[1]))
    else { return nil }
    return min(lower, upper)...max(lower, upper)
  }

  private static func scalarValue(_ value: String) -> UInt32? {
    if let number = UInt32(value) { return number }
    guard value.unicodeScalars.count == 1 else { return nil }
    return value.unicodeScalars.first?.value
  }
}
