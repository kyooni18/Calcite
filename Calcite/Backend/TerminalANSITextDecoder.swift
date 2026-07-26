import Foundation

enum TerminalANSIColor: Equatable, Sendable {
  case indexed(Int)
  case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

struct TerminalTextStyle: Equatable, Sendable {
  var foreground: TerminalANSIColor?
  var background: TerminalANSIColor?
  var isBold = false
  var isDim = false
  var isItalic = false
  var isUnderlined = false
  var isInverse = false

  static let plain = Self()

  var hasBackgroundFill: Bool { background != nil || isInverse }
}

struct TerminalStyleSpan: Equatable, Sendable {
  var utf16Location: Int
  var utf16Length: Int
  var style: TerminalTextStyle
}

struct TerminalRenderedSnapshot: Equatable, Sendable {
  var text: String
  var styleSpans: [TerminalStyleSpan]
  var cursorUTF16Location: Int

  init(
    text: String,
    styleSpans: [TerminalStyleSpan],
    cursorUTF16Location: Int = 0
  ) {
    self.text = text
    self.styleSpans = styleSpans
    self.cursorUTF16Location = cursorUTF16Location
  }
}

/// A pointer event expressed in terminal cell coordinates (which are one-based
/// in the VT mouse protocols).
enum TerminalMouseInput: Sendable {
  case buttonDown(Int, column: Int, row: Int)
  case buttonUp(Int, column: Int, row: Int)
  case drag(Int, column: Int, row: Int)
  case scroll(up: Bool, column: Int, row: Int)
}

/// Cursor-aware VT screen model used by the embedded PTY view.
///
/// It supports the control and SGR sequences commonly emitted by shells, line editors,
/// compilers, and command-line tools. Unknown sequences are ignored instead of being
/// printed into the terminal buffer.
struct TerminalANSITextDecoder: Sendable {
  private enum State: Sendable {
    case text
    case escape
    case escapeIntermediate
    case controlSequence
    case operatingSystemCommand
    case operatingSystemCommandEscape
  }

  private var state: State = .text
  private var controlSequence = ""
  private var screen = TerminalScreenBuffer()

  /// Opt-in for exact terminal-cell backgrounds after EL. Keeping this off
  /// makes popup menus from Vim/Neovim compact in Calcite's native text view.
  var preservesEraseCellBackgrounds = false {
    didSet { screen.preservesEraseCellBackgrounds = preservesEraseCellBackgrounds }
  }

  var renderedSnapshot: TerminalRenderedSnapshot { screen.renderedSnapshot }

  mutating func mouseSequence(for input: TerminalMouseInput) -> String? {
    screen.mouseSequence(for: input)
  }

  mutating func reset(columns: Int = 100, rows: Int = 32) {
    state = .text
    controlSequence = ""
    screen = TerminalScreenBuffer(columns: columns, rows: rows)
    screen.preservesEraseCellBackgrounds = preservesEraseCellBackgrounds
  }

  mutating func resize(columns: Int, rows: Int) {
    screen.resize(columns: columns, rows: rows)
  }

  /// Consumes terminal output and returns the complete visible scrollback text.
  @discardableResult
  mutating func decode(_ value: String) -> String {
    for scalar in value.unicodeScalars {
      switch state {
      case .text:
        consumeText(scalar)

      case .escape:
        consumeEscape(scalar)

      case .escapeIntermediate:
        consumeEscapeIntermediate(scalar)

      case .controlSequence:
        if (0x40...0x7E).contains(scalar.value) {
          screen.applyControlSequence(controlSequence, final: Character(String(scalar)))
          controlSequence = ""
          state = .text
        } else if scalar.value == 0x1B {
          controlSequence = ""
          state = .escape
        } else {
          controlSequence.unicodeScalars.append(scalar)
        }

      case .operatingSystemCommand:
        if scalar.value == 0x07 {
          state = .text
        } else if scalar.value == 0x1B {
          state = .operatingSystemCommandEscape
        }

      case .operatingSystemCommandEscape:
        state = scalar.value == 0x5C ? .text : .operatingSystemCommand
      }
    }
    return screen.renderedSnapshot.text
  }

  private mutating func consumeText(_ scalar: UnicodeScalar) {
    switch scalar.value {
    case 0x00, 0x07:
      return
    case 0x08:
      screen.backspace()
    case 0x09:
      screen.tab()
    case 0x0A, 0x0B, 0x0C:
      screen.lineFeed()
    case 0x0D:
      screen.carriageReturn()
    case 0x1B:
      state = .escape
    case 0x20...0x10FFFF:
      if Self.isZeroWidthTerminalScalar(scalar) {
        // A variation selector or combining scalar belongs to the glyph in the
        // preceding cell. Dropping it changes Nerd Font glyph selection and
        // makes the AppKit run no longer match the terminal grid.
        screen.appendToPreviousCell(scalar)
      } else {
        screen.write(Character(String(scalar)))
      }
    default:
      return
    }
  }

  private mutating func consumeEscape(_ scalar: UnicodeScalar) {
    switch scalar.value {
    case 0x20...0x2F:
      // VT escape sequences may contain one or more intermediate bytes before
      // their final byte. Vim and Neovim commonly emit ESC ( B to designate
      // the ASCII character set; treating "(" as the complete sequence leaks
      // its trailing "B" into the editor display.
      state = .escapeIntermediate
    case 0x5B:  // CSI
      controlSequence = ""
      state = .controlSequence
    case 0x5D:  // OSC
      state = .operatingSystemCommand
    case 0x37:  // DECSC
      screen.saveCursor()
      state = .text
    case 0x38:  // DECRC
      screen.restoreCursor()
      state = .text
    case 0x44:  // IND
      screen.lineFeed()
      state = .text
    case 0x45:  // NEL
      screen.carriageReturn()
      screen.lineFeed()
      state = .text
    case 0x4D:  // RI
      screen.moveCursor(rowDelta: -1, columnDelta: 0)
      state = .text
    case 0x63:  // RIS
      screen.hardReset()
      state = .text
    default:
      state = .text
    }
  }

  private static func isZeroWidthTerminalScalar(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 0x0300...0x036F,
      0x1AB0...0x1AFF,
      0x1DC0...0x1DFF,
      0x200D,
      0x20D0...0x20FF,
      0xFE00...0xFE0F,
      0xFE20...0xFE2F,
      0xE0100...0xE01EF:
      true
    default:
      false
    }
  }

  private mutating func consumeEscapeIntermediate(_ scalar: UnicodeScalar) {
    switch scalar.value {
    case 0x20...0x2F:
      // Continue consuming intermediate bytes until the sequence's final byte.
      return
    case 0x1B:
      state = .escape
    default:
      // The final byte selects a terminal capability (for example "B" in
      // ESC ( B). Calcite does not need to model character-set designation,
      // but it must consume the complete sequence.
      state = .text
    }
  }
}

private struct TerminalCell: Equatable, Sendable {
  var character: Character?
  var columnWidth: Int
  var style: TerminalTextStyle

  static func blank(style: TerminalTextStyle) -> Self {
    Self(character: " ", columnWidth: 1, style: style)
  }

  static func continuation(style: TerminalTextStyle) -> Self {
    Self(character: nil, columnWidth: 0, style: style)
  }
}

private struct TerminalSavedScreen: Sendable {
  var lines: [[TerminalCell]]
  var cursorRow: Int
  var cursorColumn: Int
  var savedCursor: (row: Int, column: Int)?
  var scrollTop: Int
  var scrollBottom: Int
  var hasActiveScrollRegion: Bool
}

private struct TerminalScreenBuffer: Sendable {
  private static let maximumScrollbackLines = 12_000

  private var lines: [[TerminalCell]] = [[]]
  private var cursorRow = 0
  private var cursorColumn = 0
  private var savedCursor: (row: Int, column: Int)?
  private var primaryScreen: TerminalSavedScreen?
  private var currentStyle = TerminalTextStyle.plain
  private var mouseReportingModes: Set<Int> = []
  var preservesEraseCellBackgrounds = false
  /// DECSTBM margins. Full-screen terminal applications such as Neovim use
  /// these to scroll their editing grid without moving the status line.
  private var scrollTop = 0
  private var scrollBottom: Int
  private var hasActiveScrollRegion = false
  private(set) var columns: Int
  private(set) var rows: Int

  init(columns: Int = 100, rows: Int = 32) {
    self.columns = max(2, columns)
    self.rows = max(2, rows)
    self.scrollBottom = max(2, rows) - 1
  }

  var renderedSnapshot: TerminalRenderedSnapshot {
    var text = ""
    var spans: [TerminalStyleSpan] = []
    var utf16Offset = 0
    var cursorUTF16Location: Int?

    // Interactive shells may temporarily clear rows below the cursor while
    // repainting after SIGWINCH. Those rows belong to the terminal screen, but
    // serializing them as document newlines makes a horizontal resize appear to
    // add permanent lines. Keep the cursor row and all visible content while
    // omitting only trailing, blank screen rows from the rendered text.
    let lastContentRow =
      lines.lastIndex { line in
        line.contains { cell in
          guard let character = cell.character else { return false }
          return character != " " || cell.style != .plain
        }
      } ?? 0
    let lastRenderedRow = min(lines.count - 1, max(cursorRow, lastContentRow))

    for (lineIndex, line) in lines.prefix(lastRenderedRow + 1).enumerated() {
      var activeStyle: TerminalTextStyle?
      var activeLocation = utf16Offset
      var activeLength = 0

      func finishSpan() {
        guard let activeStyle, activeStyle != .plain, activeLength > 0 else { return }
        spans.append(
          TerminalStyleSpan(
            utf16Location: activeLocation,
            utf16Length: activeLength,
            style: activeStyle
          ))
      }

      for (columnIndex, cell) in line.enumerated() {
        if lineIndex == cursorRow, columnIndex == cursorColumn {
          cursorUTF16Location = utf16Offset
        }
        guard let character = cell.character else { continue }
        let value = String(character)
        let length = (value as NSString).length
        if activeStyle != cell.style {
          finishSpan()
          activeStyle = cell.style
          activeLocation = utf16Offset
          activeLength = 0
        }
        text += value
        utf16Offset += length
        activeLength += length
      }
      finishSpan()
      if lineIndex == cursorRow, cursorUTF16Location == nil {
        cursorUTF16Location = utf16Offset
      }

      if lineIndex < lastRenderedRow {
        text.append("\n")
        utf16Offset += 1
      }
    }
    return TerminalRenderedSnapshot(
      text: text,
      styleSpans: spans,
      cursorUTF16Location: min(cursorUTF16Location ?? utf16Offset, utf16Offset)
    )
  }

  mutating func resize(columns: Int, rows: Int) {
    self.columns = max(2, columns)
    self.rows = max(2, rows)
    scrollTop = min(scrollTop, self.rows - 1)
    scrollBottom = max(scrollTop, min(scrollBottom, self.rows - 1))
    cursorColumn = min(cursorColumn, self.columns - 1)
    normalizeCursor()
  }

  mutating func write(_ character: Character) {
    let width = Self.columnWidth(of: character)
    if cursorColumn + width > columns {
      cursorColumn = 0
      cursorRow += 1
    }
    ensureRow(cursorRow)
    ensureCurrentLineLength(cursorColumn)
    clearGlyph(at: cursorColumn)
    if width == 2 { clearGlyph(at: cursorColumn + 1) }
    ensureCurrentLineLength(cursorColumn + width)
    lines[cursorRow][cursorColumn] = TerminalCell(
      character: character,
      columnWidth: width,
      style: currentStyle
    )
    if width == 2 {
      lines[cursorRow][cursorColumn + 1] = .continuation(style: currentStyle)
    }
    cursorColumn += width
    trimScrollbackIfNeeded()
  }

  mutating func appendToPreviousCell(_ scalar: UnicodeScalar) {
    guard cursorRow < lines.count, cursorColumn > 0 else { return }
    var column = min(cursorColumn - 1, lines[cursorRow].count - 1)
    while column > 0, lines[cursorRow][column].columnWidth == 0 { column -= 1 }
    guard let character = lines[cursorRow][column].character else { return }
    lines[cursorRow][column].character = Character(String(character) + String(scalar))
  }

  mutating func carriageReturn() {
    cursorColumn = 0
  }

  mutating func lineFeed() {
    if hasActiveScrollRegion, cursorRow == scrollBottom {
      scrollRegionUp()
    } else {
      cursorRow += 1
      ensureRow(cursorRow)
    }
    trimScrollbackIfNeeded()
  }

  mutating func backspace() {
    cursorColumn = max(0, cursorColumn - 1)
  }

  mutating func tab() {
    let nextStop = min(columns, ((cursorColumn / 8) + 1) * 8)
    while cursorColumn < nextStop { write(" ") }
  }

  mutating func saveCursor() {
    savedCursor = (cursorRow, cursorColumn)
  }

  mutating func restoreCursor() {
    guard let savedCursor else { return }
    cursorRow = max(0, min(savedCursor.row, max(0, lines.count - 1)))
    cursorColumn = max(0, min(savedCursor.column, columns - 1))
  }

  mutating func moveCursor(rowDelta: Int, columnDelta: Int) {
    cursorRow = max(0, cursorRow + rowDelta)
    ensureRow(cursorRow)
    cursorColumn = max(0, min(columns - 1, cursorColumn + columnDelta))
  }

  mutating func hardReset() {
    primaryScreen = nil
    currentStyle = .plain
    clearDisplay()
  }

  mutating func applyControlSequence(_ raw: String, final: Character) {
    if applyPrivateMode(raw, final: final) { return }

    let parameters = Self.parameters(raw)
    let first = parameters.first ?? 0
    let amount = max(1, first)

    switch final {
    case "A": moveCursor(rowDelta: -amount, columnDelta: 0)
    case "B", "e": moveCursor(rowDelta: amount, columnDelta: 0)
    case "C", "a": moveCursor(rowDelta: 0, columnDelta: amount)
    case "D": moveCursor(rowDelta: 0, columnDelta: -amount)
    case "E":
      moveCursor(rowDelta: amount, columnDelta: 0)
      carriageReturn()
    case "F":
      moveCursor(rowDelta: -amount, columnDelta: 0)
      carriageReturn()
    case "G", "`":
      cursorColumn = max(0, min(columns - 1, amount - 1))
    case "H", "f":
      let row = max(1, parameters.indices.contains(0) ? parameters[0] : 1)
      let column = max(1, parameters.indices.contains(1) ? parameters[1] : 1)
      cursorRow = row - 1
      cursorColumn = min(columns - 1, column - 1)
      ensureRow(cursorRow)
    case "d":
      cursorRow = max(0, amount - 1)
      ensureRow(cursorRow)
    case "J": eraseDisplay(mode: first)
    case "K": eraseLine(mode: first)
    case "P": deleteCharacters(amount)
    case "@": insertBlanks(amount)
    case "X": eraseCharacters(amount)
    case "L": insertLines(amount)
    case "M": deleteLines(amount)
    case "S": scrollUp(amount)
    case "T": scrollDown(amount)
    case "s": saveCursor()
    case "u": restoreCursor()
    case "m": applyGraphicRendition(parameters)
    case "r": setScrollRegion(parameters)
    case "h", "l", "n", "t", "q": break
    default: break
    }
  }

  private mutating func applyPrivateMode(_ raw: String, final: Character) -> Bool {
    guard raw.hasPrefix("?"), final == "h" || final == "l" else { return false }
    let modes = raw.dropFirst().split(separator: ";").compactMap { Int($0) }
    let enabled = final == "h"
    for mode in modes {
      switch mode {
      case 1047, 1049:
        enabled ? enterAlternateScreen() : leaveAlternateScreen()
      case 1048:
        enabled ? saveCursor() : restoreCursor()
      case 1000, 1002, 1003, 1006:
        if enabled {
          mouseReportingModes.insert(mode)
        } else {
          mouseReportingModes.remove(mode)
        }
      default:
        break
      }
    }
    return true
  }

  mutating func mouseSequence(for input: TerminalMouseInput) -> String? {
    guard !mouseReportingModes.isEmpty else { return nil }

    let code: Int
    let column: Int
    let row: Int
    let isRelease: Bool
    switch input {
    case .buttonDown(let button, let inputColumn, let inputRow):
      code = button
      column = inputColumn
      row = inputRow
      isRelease = false
    case .buttonUp(let button, let inputColumn, let inputRow):
      code = button
      column = inputColumn
      row = inputRow
      isRelease = true
    case .drag(let button, let inputColumn, let inputRow):
      code = 32 + button
      column = inputColumn
      row = inputRow
      isRelease = false
    case .scroll(let up, let inputColumn, let inputRow):
      code = up ? 64 : 65
      column = inputColumn
      row = inputRow
      isRelease = false
    }

    let safeColumn = max(1, column)
    let safeRow = max(1, row)
    if mouseReportingModes.contains(1006) {
      return "\u{1B}[<\(code);\(safeColumn);\(safeRow)\(isRelease ? "m" : "M")"
    }

    // X10 encoding can address 223 cells. Editors that need larger terminals
    // enable SGR (1006), so clamping here preserves the older protocol safely.
    let legacyCode = isRelease ? 3 : code
    let x = min(223, safeColumn)
    let y = min(223, safeRow)
    guard let codeScalar = UnicodeScalar(32 + legacyCode),
      let xScalar = UnicodeScalar(32 + x),
      let yScalar = UnicodeScalar(32 + y)
    else { return nil }
    return "\u{1B}[M\(Character(codeScalar))\(Character(xScalar))\(Character(yScalar))"
  }

  private mutating func enterAlternateScreen() {
    guard primaryScreen == nil else { return }
    primaryScreen = TerminalSavedScreen(
      lines: lines,
      cursorRow: cursorRow,
      cursorColumn: cursorColumn,
      savedCursor: savedCursor,
      scrollTop: scrollTop,
      scrollBottom: scrollBottom,
      hasActiveScrollRegion: hasActiveScrollRegion
    )
    lines = Array(repeating: [], count: rows)
    cursorRow = 0
    cursorColumn = 0
    savedCursor = nil
    scrollTop = 0
    scrollBottom = rows - 1
    hasActiveScrollRegion = true
  }

  private mutating func leaveAlternateScreen() {
    guard let primaryScreen else { return }
    lines = primaryScreen.lines
    cursorRow = primaryScreen.cursorRow
    cursorColumn = primaryScreen.cursorColumn
    savedCursor = primaryScreen.savedCursor
    scrollTop = primaryScreen.scrollTop
    scrollBottom = primaryScreen.scrollBottom
    hasActiveScrollRegion = primaryScreen.hasActiveScrollRegion
    self.primaryScreen = nil
    normalizeCursor()
  }

  private mutating func applyGraphicRendition(_ values: [Int]) {
    let values = values.isEmpty ? [0] : values
    var index = 0
    while index < values.count {
      let value = values[index]
      switch value {
      case 0:
        currentStyle = .plain
      case 1:
        currentStyle.isBold = true
      case 2:
        currentStyle.isDim = true
      case 3:
        currentStyle.isItalic = true
      case 4:
        currentStyle.isUnderlined = true
      case 7:
        currentStyle.isInverse = true
      case 22:
        currentStyle.isBold = false
        currentStyle.isDim = false
      case 23:
        currentStyle.isItalic = false
      case 24:
        currentStyle.isUnderlined = false
      case 27:
        currentStyle.isInverse = false
      case 30...37:
        currentStyle.foreground = .indexed(value - 30)
      case 38:
        index = applyExtendedColor(values, at: index, foreground: true)
      case 39:
        currentStyle.foreground = nil
      case 40...47:
        currentStyle.background = .indexed(value - 40)
      case 48:
        index = applyExtendedColor(values, at: index, foreground: false)
      case 49:
        currentStyle.background = nil
      case 90...97:
        currentStyle.foreground = .indexed(value - 90 + 8)
      case 100...107:
        currentStyle.background = .indexed(value - 100 + 8)
      default:
        break
      }
      index += 1
    }
  }

  private mutating func applyExtendedColor(
    _ values: [Int],
    at index: Int,
    foreground: Bool
  ) -> Int {
    guard values.indices.contains(index + 1) else { return index }
    let mode = values[index + 1]
    let color: TerminalANSIColor?
    let consumed: Int
    if mode == 5, values.indices.contains(index + 2) {
      color = .indexed(max(0, min(255, values[index + 2])))
      consumed = 2
    } else if mode == 2, values.indices.contains(index + 4) {
      color = .rgb(
        red: UInt8(clamping: values[index + 2]),
        green: UInt8(clamping: values[index + 3]),
        blue: UInt8(clamping: values[index + 4])
      )
      consumed = 4
    } else {
      return index
    }

    if foreground {
      currentStyle.foreground = color
    } else {
      currentStyle.background = color
    }
    return index + consumed
  }

  private mutating func eraseDisplay(mode: Int) {
    switch mode {
    case 1:
      for row in 0..<cursorRow where row < lines.count { lines[row] = [] }
      ensureRow(cursorRow)
      eraseCurrentLinePrefix()
    case 2, 3:
      clearDisplay()
    default:
      ensureRow(cursorRow)
      eraseCurrentLineSuffix()
      if cursorRow + 1 < lines.count {
        lines.removeSubrange((cursorRow + 1)..<lines.count)
      }
    }
  }

  private mutating func clearDisplay() {
    lines = [[]]
    cursorRow = 0
    cursorColumn = 0
    savedCursor = nil
    scrollTop = 0
    scrollBottom = rows - 1
    hasActiveScrollRegion = false
  }

  private mutating func eraseLine(mode: Int) {
    ensureRow(cursorRow)
    switch mode {
    case 1: eraseCurrentLinePrefix()
    case 2:
      if !preservesEraseCellBackgrounds || !currentStyle.hasBackgroundFill {
        lines[cursorRow] = []
      } else {
        lines[cursorRow] = Array(repeating: .blank(style: currentStyle), count: columns)
      }
    default: eraseCurrentLineSuffix()
    }
  }

  private mutating func eraseCurrentLinePrefix() {
    ensureCurrentLineLength(cursorColumn + 1)
    for index in 0...cursorColumn {
      lines[cursorRow][index] = .blank(style: currentStyle)
    }
  }

  private mutating func eraseCurrentLineSuffix() {
    guard preservesEraseCellBackgrounds, currentStyle.hasBackgroundFill else {
      guard cursorColumn < lines[cursorRow].count else { return }
      lines[cursorRow].removeSubrange(cursorColumn..<lines[cursorRow].count)
      return
    }

    ensureCurrentLineLength(columns)
    for index in cursorColumn..<columns {
      lines[cursorRow][index] = .blank(style: currentStyle)
    }
  }

  private mutating func deleteCharacters(_ count: Int) {
    ensureRow(cursorRow)
    guard cursorColumn < lines[cursorRow].count else { return }
    let end = min(lines[cursorRow].count, cursorColumn + count)
    lines[cursorRow].removeSubrange(cursorColumn..<end)
  }

  private mutating func insertBlanks(_ count: Int) {
    ensureRow(cursorRow)
    ensureCurrentLineLength(cursorColumn)
    lines[cursorRow].insert(
      contentsOf: repeatElement(.blank(style: currentStyle), count: count),
      at: cursorColumn
    )
    if lines[cursorRow].count > columns {
      lines[cursorRow].removeLast(lines[cursorRow].count - columns)
    }
  }

  private mutating func eraseCharacters(_ count: Int) {
    ensureRow(cursorRow)
    ensureCurrentLineLength(cursorColumn + count)
    let end = min(lines[cursorRow].count, cursorColumn + count)
    guard cursorColumn < end else { return }
    for index in cursorColumn..<end {
      lines[cursorRow][index] = .blank(style: currentStyle)
    }
  }

  private mutating func insertLines(_ count: Int) {
    guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
    ensureRow(scrollBottom)
    let amount = min(count, scrollBottom - cursorRow + 1)
    lines.insert(contentsOf: repeatElement([], count: amount), at: cursorRow)
    lines.removeSubrange((scrollBottom + 1)...(scrollBottom + amount))
  }

  private mutating func deleteLines(_ count: Int) {
    guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
    ensureRow(scrollBottom)
    let amount = min(count, scrollBottom - cursorRow + 1)
    lines.removeSubrange(cursorRow..<(cursorRow + amount))
    lines.insert(contentsOf: repeatElement([], count: amount), at: scrollBottom - amount + 1)
  }

  private mutating func scrollUp(_ count: Int) {
    for _ in 0..<count { scrollRegionUp() }
  }

  private mutating func scrollDown(_ count: Int) {
    for _ in 0..<count { scrollRegionDown() }
  }

  private mutating func setScrollRegion(_ parameters: [Int]) {
    let top = parameters.indices.contains(0) ? parameters[0] : 1
    let bottom = parameters.indices.contains(1) ? parameters[1] : rows
    guard top > 0, bottom > top, bottom <= rows else {
      scrollTop = 0
      scrollBottom = rows - 1
      hasActiveScrollRegion = true
      cursorRow = 0
      cursorColumn = 0
      return
    }
    scrollTop = top - 1
    scrollBottom = bottom - 1
    hasActiveScrollRegion = true
    ensureRow(scrollBottom)
    cursorRow = 0
    cursorColumn = 0
  }

  private mutating func scrollRegionUp() {
    ensureRow(scrollBottom)
    lines.remove(at: scrollTop)
    lines.insert([], at: scrollBottom)
  }

  private mutating func scrollRegionDown() {
    ensureRow(scrollBottom)
    lines.remove(at: scrollBottom)
    lines.insert([], at: scrollTop)
  }

  private mutating func ensureRow(_ row: Int) {
    if row >= lines.count {
      lines.append(contentsOf: repeatElement([], count: row - lines.count + 1))
    }
  }

  private mutating func ensureCurrentLineLength(_ length: Int) {
    ensureRow(cursorRow)
    guard length > lines[cursorRow].count else { return }
    lines[cursorRow].append(
      contentsOf: repeatElement(
        .blank(style: currentStyle),
        count: length - lines[cursorRow].count
      ))
  }

  private mutating func clearGlyph(at column: Int) {
    ensureCurrentLineLength(column + 1)
    let cell = lines[cursorRow][column]
    if cell.columnWidth == 0 {
      var lead = column - 1
      while lead >= 0, lines[cursorRow][lead].columnWidth == 0 { lead -= 1 }
      if lead >= 0 { clearGlyph(at: lead) }
      return
    }
    if cell.columnWidth > 1 {
      let end = min(lines[cursorRow].count, column + cell.columnWidth)
      for index in column..<end {
        lines[cursorRow][index] = .blank(style: currentStyle)
      }
    } else {
      lines[cursorRow][column] = .blank(style: currentStyle)
    }
  }

  private mutating func normalizeCursor() {
    if lines.isEmpty { lines = [[]] }
    cursorRow = max(0, min(cursorRow, lines.count - 1))
    cursorColumn = max(0, min(cursorColumn, columns - 1))
  }

  private mutating func trimScrollbackIfNeeded() {
    guard primaryScreen == nil, lines.count > Self.maximumScrollbackLines else { return }
    let removeCount = lines.count - Self.maximumScrollbackLines
    lines.removeFirst(removeCount)
    cursorRow = max(0, cursorRow - removeCount)
    if let savedCursor {
      self.savedCursor = (max(0, savedCursor.row - removeCount), savedCursor.column)
    }
  }

  private static func parameters(_ raw: String) -> [Int] {
    let normalized = raw.drop(while: { $0 == "?" || $0 == ">" || $0 == "!" })
    if normalized.isEmpty { return [0] }
    return normalized.split(separator: ";", omittingEmptySubsequences: false).map {
      Int($0) ?? 0
    }
  }

  private static func columnWidth(of character: Character) -> Int {
    guard let scalar = character.unicodeScalars.first else { return 1 }
    let value = scalar.value
    switch value {
    case 0x1100...0x115F,
      0x2329...0x232A,
      0x2E80...0xA4CF,
      0xAC00...0xD7A3,
      0xF900...0xFAFF,
      0xFE10...0xFE19,
      0xFE30...0xFE6F,
      0xFF01...0xFF60,
      0xFFE0...0xFFE6,
      0x1F300...0x1FAFF,
      0x20000...0x3FFFD:
      return 2
    default:
      return 1
    }
  }
}
