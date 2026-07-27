import Foundation

/// Deterministic terminal-style display width used when AppKit visual geometry is
/// unavailable. It keeps vertical Vim motions stable across tabs, combining text,
/// CJK characters, and emoji while the host remains free to render proportionally.
enum VimDisplayColumns {
  static func width(of character: Character, at column: Int, tabWidth: Int) -> Int {
    if character == "\t" {
      let width = max(1, tabWidth)
      return width - (column % width)
    }

    var result = 0
    for scalar in character.unicodeScalars {
      result = max(result, scalarWidth(scalar))
    }
    return result
  }

  private static func scalarWidth(_ scalar: Unicode.Scalar) -> Int {
    switch scalar.properties.generalCategory {
    case .control, .format, .nonspacingMark, .enclosingMark:
      return 0
    default:
      break
    }

    let value = scalar.value
    if scalar.properties.isEmojiPresentation || isEastAsianWide(value) { return 2 }
    return 1
  }

  private static func isEastAsianWide(_ value: UInt32) -> Bool {
    switch value {
    case 0x1100...0x115F,
      0x231A...0x231B,
      0x2329...0x232A,
      0x23E9...0x23EC,
      0x23F0...0x23F0,
      0x23F3...0x23F3,
      0x25FD...0x25FE,
      0x2614...0x2615,
      0x2648...0x2653,
      0x267F...0x267F,
      0x2693...0x2693,
      0x26A1...0x26A1,
      0x26AA...0x26AB,
      0x26BD...0x26BE,
      0x26C4...0x26C5,
      0x26CE...0x26CE,
      0x26D4...0x26D4,
      0x26EA...0x26EA,
      0x26F2...0x26F3,
      0x26F5...0x26F5,
      0x26FA...0x26FA,
      0x26FD...0x26FD,
      0x2705...0x2705,
      0x270A...0x270B,
      0x2728...0x2728,
      0x274C...0x274C,
      0x274E...0x274E,
      0x2753...0x2755,
      0x2757...0x2757,
      0x2795...0x2797,
      0x27B0...0x27B0,
      0x27BF...0x27BF,
      0x2B1B...0x2B1C,
      0x2B50...0x2B50,
      0x2B55...0x2B55,
      0x2E80...0xA4CF,
      0xAC00...0xD7A3,
      0xF900...0xFAFF,
      0xFE10...0xFE19,
      0xFE30...0xFE6F,
      0xFF01...0xFF60,
      0xFFE0...0xFFE6,
      0x1F200...0x1FAFF,
      0x20000...0x3FFFD:
      return true
    default:
      return false
    }
  }
}

extension VimEngine {
  func displayColumn(from lineStart: Int, to offset: Int) -> Int {
    let lower = clamp(lineStart)
    let upper = clamp(offset)
    if let visual = storedVisualGeometryProvider?.visualColumn(
      atUTF16Offset: upper,
      logicalLineStart: lower,
      text: state.text
    ) {
      return max(0, visual)
    }
    guard upper > lower else { return 0 }

    var column = 0
    var current = lower
    while current < upper {
      guard let character = character(at: current) else { break }
      column += VimDisplayColumns.width(
        of: character,
        at: column,
        tabWidth: storedTabWidth
      )
      let next = nextCharacterBoundary(from: current)
      guard next > current else { break }
      current = next
    }
    return column
  }

  func offset(
    from lineStart: Int,
    atDisplayColumn desiredColumn: Int,
    contentEnd: Int
  ) -> Int {
    let start = clamp(lineStart)
    let end = clamp(contentEnd)
    if let visual = storedVisualGeometryProvider?.utf16Offset(
      inLogicalLineStartingAt: start,
      atVisualColumn: max(0, desiredColumn),
      contentEnd: end,
      text: state.text,
      roundForward: false
    ) {
      return normalizedVimUTF16Offset(visual, in: state.text)
    }
    guard start < end else { return start }

    var column = 0
    var current = start
    while current < end {
      if column >= desiredColumn { return current }
      guard let character = character(at: current) else { break }
      let width = VimDisplayColumns.width(
        of: character,
        at: column,
        tabWidth: storedTabWidth
      )
      if column + width > desiredColumn { return current }
      let next = nextCharacterBoundary(from: current)
      guard next > current, next <= end else { break }
      current = next
      column += width
    }
    return normalLineEnd(at: start)
  }
}
