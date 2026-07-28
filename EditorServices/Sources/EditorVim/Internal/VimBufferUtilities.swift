import Foundation

extension VimEngine {
  func joinLine() {
    let end = lineContentEnd(at: state.cursor)
    guard end < state.text.utf16.count else { return }
    let nextStart = lineEndIncludingNewline(at: state.cursor)
    guard nextStart > end else { return }
    var next = nextStart
    while next < state.text.utf16.count, isHorizontalWhitespace(at: next) {
      next = nextCharacterBoundary(from: next)
    }
    replace(range: end..<next, with: " ")
    state.cursor = end
  }

  func rememberVisualSelection() {
    guard state.mode == .visualCharacter || state.mode == .visualLine else { return }
    let anchor = visualAnchor ?? state.selection?.lowerBound ?? state.cursor
    lastVisual = VimVisualSnapshot(
      anchor: anchor,
      caret: state.cursor,
      mode: state.mode,
      shape: visualSelectionShape
    )
  }

  func enterVisualBlock() {
    if state.mode == .visualCharacter, visualSelectionShape == .block {
      rememberVisualSelection()
      state.mode = .normal
      state.selection = nil
      visualAnchor = nil
      visualSelectionShape = .character
      return
    }
    visualAnchor = state.cursor
    visualSelectionShape = .block
    state.mode = .visualCharacter
    updateVisualSelection()
  }

  func updateVisualSelection() {
    guard state.mode == .visualCharacter || state.mode == .visualLine else { return }
    let anchor = visualAnchor ?? state.cursor
    visualAnchor = anchor
    if visualSelectionShape == .block {
      let ranges = projectedVisualRanges()
      guard let first = ranges.first else {
        state.selection = VimSelection(state.cursor, state.cursor)
        return
      }
      let lower = ranges.map(\.lowerBound).min() ?? first.lowerBound
      let upper = ranges.map(\.upperBound).max() ?? first.upperBound
      state.selection = VimSelection(lower, upper)
    } else if state.mode == .visualCharacter {
      visualSelectionShape = .character
      let lower = min(anchor, state.cursor)
      let upper = nextCharacterBoundary(from: max(anchor, state.cursor))
      state.selection = VimSelection(lower, max(lower, upper))
    } else {
      visualSelectionShape = .line
      let anchorStart = lineStart(at: anchor)
      let caretStart = lineStart(at: state.cursor)
      let lower = min(anchorStart, caretStart)
      let upperLine = max(anchorStart, caretStart)
      state.selection = VimSelection(lower, lineEndIncludingNewline(at: upperLine))
    }
  }

  func swapVisualEndpoints() {
    guard state.mode == .visualCharacter || state.mode == .visualLine else { return }
    let previousCaret = state.cursor
    state.cursor = clamp(visualAnchor ?? state.cursor)
    visualAnchor = previousCaret
    updateVisualSelection()
  }

  func prepareVisualExRange() -> String? {
    guard let range = visualRange() else { return nil }
    marks["<"] = range.lowerBound
    marks[">"] = max(range.lowerBound, range.upperBound - 1)
    return ":'<,'>"
  }

  func visualRange() -> Range<Int>? {
    guard state.mode == .visualCharacter || state.mode == .visualLine else { return nil }
    if visualSelectionShape == .block {
      let ranges = projectedVisualRanges()
      guard let lower = ranges.map(\.lowerBound).min(),
        let upper = ranges.map(\.upperBound).max()
      else { return nil }
      return lower..<max(lower, upper)
    }
    let anchor = clamp(visualAnchor ?? state.selection?.lowerBound ?? state.cursor)
    if state.mode == .visualLine {
      let lower = lineStart(at: min(anchor, state.cursor))
      let upper = lineEndIncludingNewline(at: max(anchor, state.cursor))
      return lower..<max(lower, upper)
    }
    let lower = min(anchor, state.cursor)
    let upper = nextCharacterBoundary(from: max(anchor, state.cursor))
    return lower..<max(lower, upper)
  }

  func projectedVisualRanges() -> [Range<Int>] {
    guard let anchor = visualAnchor,
      state.mode == .visualCharacter || state.mode == .visualLine
    else { return [] }
    if visualSelectionShape != .block {
      return visualRange().map { [$0] } ?? []
    }

    let anchorStart = lineStart(at: anchor)
    let caretStart = lineStart(at: state.cursor)
    let top = min(anchorStart, caretStart)
    let bottom = max(anchorStart, caretStart)
    guard let columns = visualBlockColumnBounds() else { return [] }
    let left = columns.lowerBound
    let right = columns.upperBound

    var ranges: [Range<Int>] = []
    var line = top
    while true {
      let end = lineContentEnd(at: line)
      let lower = blockBoundaryOffset(from: line, desiredColumn: left, contentEnd: end)
      let upper = offsetAtOrAfterDisplayColumn(
        from: line,
        desiredColumn: right,
        contentEnd: end
      )
      ranges.append(lower..<max(lower, upper))
      if line == bottom { break }
      let next = nextLineStart(line)
      if next == line { break }
      line = next
    }
    return ranges
  }

  func visualBlockColumnBounds() -> Range<Int>? {
    guard let anchor = visualAnchor, visualSelectionShape == .block else { return nil }
    let anchorStart = lineStart(at: anchor)
    let caretStart = lineStart(at: state.cursor)
    let anchorColumn = displayColumn(from: anchorStart, to: anchor)
    let caretColumn = displayColumn(from: caretStart, to: state.cursor)
    let anchorWidth = displayWidthOfCharacter(at: anchor, column: anchorColumn)
    let caretWidth = displayWidthOfCharacter(at: state.cursor, column: caretColumn)
    let left = min(anchorColumn, caretColumn)
    let right = max(anchorColumn + anchorWidth, caretColumn + caretWidth)
    return left..<max(left + 1, right)
  }

  func displayWidthOfCharacter(at offset: Int, column: Int) -> Int {
    let start = lineStart(at: offset)
    if let visual = storedVisualGeometryProvider?.visualWidth(
      atUTF16Offset: offset,
      logicalLineStart: start,
      text: state.text
    ) {
      return max(1, visual)
    }
    guard offset < lineContentEnd(at: offset), let character = character(at: offset) else {
      return 1
    }
    return max(
      1,
      VimDisplayColumns.width(of: character, at: column, tabWidth: bufferStateStorage.tabWidth)
    )
  }

  func blockBoundaryOffset(
    from lineStart: Int,
    desiredColumn: Int,
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
      let width = max(
        1,
        VimDisplayColumns.width(of: character, at: column, tabWidth: bufferStateStorage.tabWidth)
      )
      if column + width > desiredColumn { return current }
      let next = nextCharacterBoundary(from: current)
      guard next > current else { break }
      current = next
      column += width
    }
    return end
  }

  func offsetAtOrAfterDisplayColumn(
    from lineStart: Int,
    desiredColumn: Int,
    contentEnd: Int
  ) -> Int {
    let start = clamp(lineStart)
    let end = clamp(contentEnd)
    if let visual = storedVisualGeometryProvider?.utf16Offset(
      inLogicalLineStartingAt: start,
      atVisualColumn: max(0, desiredColumn),
      contentEnd: end,
      text: state.text,
      roundForward: true
    ) {
      return normalizedVimUTF16Offset(visual, in: state.text, bias: .forward)
    }
    guard start < end else { return start }
    var column = 0
    var current = start
    while current < end {
      guard let character = character(at: current) else { break }
      let width = max(
        1,
        VimDisplayColumns.width(of: character, at: column, tabWidth: bufferStateStorage.tabWidth)
      )
      let next = nextCharacterBoundary(from: current)
      if column + width >= desiredColumn { return max(current, next) }
      guard next > current else { break }
      current = next
      column += width
    }
    return end
  }

  func verticalMove(_ delta: Int) {
    let currentStart = lineStart(at: state.cursor)
    let desired = preferredColumn ?? displayColumn(from: currentStart, to: state.cursor)
    preferredColumn = desired
    let targetStart = delta < 0 ? previousLineStart(currentStart) : nextLineStart(currentStart)
    guard targetStart != currentStart else { return }
    state.cursor = offset(
      from: targetStart,
      atDisplayColumn: desired,
      contentEnd: lineContentEnd(at: targetStart)
    )
  }

  func previousLineStart(_ start: Int) -> Int {
    guard start > 0 else { return 0 }
    let previous = previousCharacterBoundary(from: start)
    return lineStart(at: previous)
  }

  func nextLineStart(_ start: Int) -> Int {
    let next = lineEndIncludingNewline(at: start)
    return next > start && next <= state.text.utf16.count ? next : start
  }

  func lineStart(at offset: Int) -> Int {
    lineIndex.synchronize(with: state.text)
    return lineIndex.lineStart(containing: clamp(offset), textLength: state.text.utf16.count)
  }

  func lineContentEnd(at offset: Int) -> Int {
    lineIndex.synchronize(with: state.text)
    return lineIndex.contentEnd(containing: clamp(offset), textLength: state.text.utf16.count)
  }

  func normalLineEnd(at offset: Int) -> Int {
    let start = lineStart(at: offset)
    let end = lineContentEnd(at: offset)
    return end > start ? previousCharacterBoundary(from: end) : start
  }

  func lineEndIncludingNewline(at offset: Int) -> Int {
    lineIndex.synchronize(with: state.text)
    return lineIndex.endIncludingTerminator(
      containing: clamp(offset),
      textLength: state.text.utf16.count
    )
  }

  func lineHasTerminator(at offset: Int) -> Bool {
    lineEndIncludingNewline(at: offset) > lineContentEnd(at: offset)
  }

  func firstNonBlank(at offset: Int) -> Int {
    var current = lineStart(at: offset)
    let end = lineContentEnd(at: offset)
    while current < end, isHorizontalWhitespace(at: current) {
      current = nextCharacterBoundary(from: current)
    }
    return current
  }

  func lineOffset(_ number: Int) -> Int {
    lineIndex.synchronize(with: state.text)
    return lineIndex.offset(ofOneBasedLine: max(1, number))
  }

  func nextWord(from offset: Int, whole: Bool) -> Int {
    let count = state.text.utf16.count
    guard count > 0 else { return 0 }
    var current = normalizedVimUTF16Offset(offset, in: state.text, bias: .forward)
    if current >= count { return current }
    guard let initial = wordClass(at: current, whole: whole) else { return current }

    if initial != .whitespace {
      while current < count, wordClass(at: current, whole: whole) == initial {
        let next = nextCharacterBoundary(from: current)
        guard next > current else { break }
        current = next
      }
    }
    while current < count, wordClass(at: current, whole: whole) == .whitespace {
      let next = nextCharacterBoundary(from: current)
      guard next > current else { break }
      current = next
    }
    return current
  }

  func previousWord(from offset: Int, whole: Bool) -> Int {
    guard offset > 0 else { return 0 }
    var current = previousCharacterBoundary(from: offset)
    while current > 0, wordClass(at: current, whole: whole) == .whitespace {
      current = previousCharacterBoundary(from: current)
    }
    guard let classification = wordClass(at: current, whole: whole) else { return current }
    while current > 0 {
      let previous = previousCharacterBoundary(from: current)
      guard wordClass(at: previous, whole: whole) == classification else { break }
      current = previous
    }
    return current
  }

  func wordEnd(from offset: Int, whole: Bool) -> Int {
    let length = state.text.utf16.count
    guard length > 0 else { return 0 }
    var current = min(
      normalizedVimUTF16Offset(offset, in: state.text, bias: .forward),
      length - 1
    )

    if let currentClass = wordClass(at: current, whole: whole), currentClass != .whitespace {
      let next = nextCharacterBoundary(from: current)
      if next < length, wordClass(at: next, whole: whole) == currentClass {
        current = next
      } else if next < length {
        current = next
      } else {
        return current
      }
    }

    while current < length, wordClass(at: current, whole: whole) == .whitespace {
      let next = nextCharacterBoundary(from: current)
      guard next < length, next > current else { return current }
      current = next
    }
    guard let classification = wordClass(at: current, whole: whole) else { return current }
    while true {
      let next = nextCharacterBoundary(from: current)
      guard next < length, wordClass(at: next, whole: whole) == classification else {
        return current
      }
      current = next
    }
  }

  func wordClass(at offset: Int, whole: Bool) -> VimWordClass? {
    guard let character = character(at: offset) else { return nil }
    if character.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
      return .whitespace
    }
    if whole { return .keyword }
    return character.unicodeScalars.contains(where: keywordOptions.contains)
      ? .keyword
      : .punctuation
  }

  func isHorizontalWhitespace(at offset: Int) -> Bool {
    guard let character = character(at: offset) else { return false }
    return character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
  }

  func isWhitespaceOrNewline(at offset: Int) -> Bool {
    guard let character = character(at: offset) else { return false }
    return character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
  }

  func isBlankLine(at offset: Int) -> Bool {
    var current = lineStart(at: offset)
    let end = lineContentEnd(at: offset)
    while current < end {
      guard isHorizontalWhitespace(at: current) else { return false }
      current = nextCharacterBoundary(from: current)
    }
    return true
  }

  func find(_ character: Character, forward: Bool, till: Bool, count: Int) {
    let lineStart = lineStart(at: state.cursor)
    let lineEnd = lineContentEnd(at: state.cursor)
    var current = state.cursor
    for _ in 0..<count {
      if forward {
        var candidate = nextCharacterBoundary(from: current)
        var found: Int?
        while candidate < lineEnd {
          if self.character(at: candidate) == character {
            found = candidate
            break
          }
          let next = nextCharacterBoundary(from: candidate)
          guard next > candidate else { break }
          candidate = next
        }
        guard let found else { return }
        current = found
      } else {
        var candidate = current
        var found: Int?
        while candidate > lineStart {
          candidate = previousCharacterBoundary(from: candidate)
          if self.character(at: candidate) == character {
            found = candidate
            break
          }
        }
        guard let found else { return }
        current = found
      }
    }
    if till {
      current =
        forward
        ? previousCharacterBoundary(from: current)
        : nextCharacterBoundary(from: current)
    }
    state.cursor = clamp(current)
    normalizeCursorForMode()
  }

  func matchingPair() {
    let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    guard let current = character(at: state.cursor) else { return }
    if let close = pairs[current] {
      var depth = 0
      var index = state.cursor
      while index < state.text.utf16.count {
        let value = character(at: index)
        if value == current { depth += 1 }
        if value == close {
          depth -= 1
          if depth == 0 {
            state.cursor = index
            return
          }
        }
        let next = nextCharacterBoundary(from: index)
        guard next > index else { break }
        index = next
      }
    } else if let open = pairs.first(where: { $0.value == current })?.key {
      var depth = 0
      var index = state.cursor
      while true {
        let value = character(at: index)
        if value == current { depth += 1 }
        if value == open {
          depth -= 1
          if depth == 0 {
            state.cursor = index
            return
          }
        }
        guard index > 0 else { break }
        index = previousCharacterBoundary(from: index)
      }
    }
  }

  func replace(range: Range<Int>, with replacement: String) {
    let normalizedRange = normalized(range)
    let removed = substring(normalizedRange)
    guard removed != replacement else {
      state.cursor = normalizedRange.lowerBound + replacement.utf16.count
      return
    }
    let oldText = state.text
    lineIndex.synchronize(with: oldText)
    let lower = stringIndex(normalizedRange.lowerBound)
    let upper = stringIndex(normalizedRange.upperBound)
    state.text.replaceSubrange(lower..<upper, with: replacement)
    let edit = VimEditDelta(
      location: normalizedRange.lowerBound,
      removedText: removed,
      insertedText: replacement
    )
    recordEdit(edit)
    lineIndex.apply(
      replacementRange: normalizedRange,
      removedText: removed,
      insertedText: replacement,
      resultingText: state.text
    )
    adjustPositions(
      afterReplacing: normalizedRange,
      replacementUTF16Count: replacement.utf16.count
    )
    state.cursor = normalizedRange.lowerBound + replacement.utf16.count
  }

  func adjustedPosition(
    _ position: Int,
    afterReplacing range: Range<Int>,
    replacementUTF16Count: Int,
    insertionAdvancesBoundary: Bool
  ) -> Int {
    let delta = replacementUTF16Count - range.count
    if position < range.lowerBound { return position }
    if range.isEmpty, position == range.lowerBound {
      return insertionAdvancesBoundary ? position + replacementUTF16Count : position
    }
    if position <= range.upperBound { return range.lowerBound + replacementUTF16Count }
    return position + delta
  }

  func adjustBufferPositions(
    afterReplacing range: Range<Int>,
    replacementUTF16Count: Int,
    insertionAdvancesBoundary: Bool = true
  ) {
    marks = marks.mapValues {
      normalizedVimUTF16Offset(
        adjustedPosition(
          $0,
          afterReplacing: range,
          replacementUTF16Count: replacementUTF16Count,
          insertionAdvancesBoundary: insertionAdvancesBoundary
        ),
        in: state.text
      )
    }
    changePositions = changePositions.map {
      normalizedVimUTF16Offset(
        adjustedPosition(
          $0,
          afterReplacing: range,
          replacementUTF16Count: replacementUTF16Count,
          insertionAdvancesBoundary: insertionAdvancesBoundary
        ),
        in: state.text
      )
    }
  }

  func adjustWindowPositions(
    afterReplacing range: Range<Int>,
    replacementUTF16Count: Int,
    insertionAdvancesBoundary: Bool = true,
    adjustCursor: Bool = false
  ) {
    func adjusted(_ position: Int) -> Int {
      normalizedVimUTF16Offset(
        adjustedPosition(
          position,
          afterReplacing: range,
          replacementUTF16Count: replacementUTF16Count,
          insertionAdvancesBoundary: insertionAdvancesBoundary
        ),
        in: state.text
      )
    }
    if adjustCursor { state.cursor = adjusted(state.cursor) }
    jumpBackStack = jumpBackStack.map(adjusted)
    jumpForwardStack = jumpForwardStack.map(adjusted)
    if let anchor = visualAnchor { visualAnchor = adjusted(anchor) }
    if let selection = state.selection {
      state.selection = VimSelection(adjusted(selection.lowerBound), adjusted(selection.upperBound))
    }
  }

  func adjustStoredPositions(
    afterReplacing range: Range<Int>,
    replacementUTF16Count: Int
  ) {
    adjustBufferPositions(
      afterReplacing: range,
      replacementUTF16Count: replacementUTF16Count
    )
    adjustWindowPositions(
      afterReplacing: range,
      replacementUTF16Count: replacementUTF16Count
    )
  }

  func adjustPositions(afterReplacing range: Range<Int>, replacementUTF16Count: Int) {
    adjustBufferPositions(
      afterReplacing: range,
      replacementUTF16Count: replacementUTF16Count,
      insertionAdvancesBoundary: false
    )
    adjustWindowPositions(
      afterReplacing: range,
      replacementUTF16Count: replacementUTF16Count,
      insertionAdvancesBoundary: false,
      adjustCursor: true
    )
  }

  func normalized(_ range: Range<Int>) -> Range<Int> {
    let lower = normalizedVimUTF16Offset(range.lowerBound, in: state.text, bias: .backward)
    let upper = normalizedVimUTF16Offset(range.upperBound, in: state.text, bias: .forward)
    return min(lower, upper)..<max(lower, upper)
  }

  func containsNewline(_ range: Range<Int>) -> Bool {
    substring(range).contains("\n") || substring(range).contains("\r")
  }

  func substring(_ range: Range<Int>) -> String {
    let r = normalized(range)
    let lower = stringIndex(r.lowerBound)
    let upper = stringIndex(r.upperBound)
    return String(state.text[lower..<upper])
  }

  func character(at offset: Int) -> Character? {
    let startOffset = normalizedVimUTF16Offset(offset, in: state.text, bias: .backward)
    guard startOffset < state.text.utf16.count else { return nil }
    let endOffset = nextCharacterBoundary(from: startOffset)
    let start = stringIndex(startOffset)
    let end = stringIndex(endOffset)
    return state.text[start..<end].first
  }

  func isEscaped(at offset: Int) -> Bool {
    var count = 0
    var current = offset
    while current > 0 {
      let previous = previousCharacterBoundary(from: current)
      guard character(at: previous) == "\\" else { break }
      count += 1
      current = previous
    }
    return count % 2 == 1
  }

  func previousCharacterBoundary(from offset: Int) -> Int {
    var candidate = normalizedVimUTF16Offset(offset, in: state.text, bias: .backward)
    guard candidate > 0 else { return 0 }
    candidate -= 1
    return normalizedVimUTF16Offset(candidate, in: state.text, bias: .backward)
  }

  func nextCharacterBoundary(from offset: Int) -> Int {
    let count = state.text.utf16.count
    var candidate = normalizedVimUTF16Offset(offset, in: state.text, bias: .forward)
    guard candidate < count else { return count }
    candidate += 1
    return normalizedVimUTF16Offset(candidate, in: state.text, bias: .forward)
  }

  func advanceCharacters(from offset: Int, count: Int) -> Int {
    var result = normalizedVimUTF16Offset(offset, in: state.text)
    if count >= 0 {
      for _ in 0..<count {
        let next = nextCharacterBoundary(from: result)
        guard next > result else { break }
        result = next
      }
    } else {
      for _ in 0..<(-count) {
        let previous = previousCharacterBoundary(from: result)
        guard previous < result else { break }
        result = previous
      }
    }
    return result
  }

  func characterDistance(from lower: Int, to upper: Int) -> Int {
    guard upper > lower else { return 0 }
    var count = 0
    var current = lower
    while current < upper {
      let next = nextCharacterBoundary(from: current)
      guard next > current else { break }
      current = next
      count += 1
    }
    return count
  }

  func characterOffset(from start: Int, count: Int, limit: Int) -> Int {
    var current = start
    for _ in 0..<count {
      guard current < limit else { break }
      let next = nextCharacterBoundary(from: current)
      guard next > current, next <= limit else { break }
      current = next
    }
    return current
  }

  func insertionDeleteWordCount() -> Int {
    let start = lineStart(at: state.cursor)
    guard state.cursor > start else { return 0 }
    var target = state.cursor
    while target > start {
      let previous = previousCharacterBoundary(from: target)
      guard isHorizontalWhitespace(at: previous) else { break }
      target = previous
    }
    if target > start,
      let classification = wordClass(
        at: previousCharacterBoundary(from: target),
        whole: false
      )
    {
      while target > start {
        let previous = previousCharacterBoundary(from: target)
        guard wordClass(at: previous, whole: false) == classification else { break }
        target = previous
      }
    }
    return characterDistance(from: target, to: state.cursor)
  }

  func insertionOffsetAfterNormalCursor() -> Int {
    let end = lineContentEnd(at: state.cursor)
    if state.cursor < end { return nextCharacterBoundary(from: state.cursor) }
    return end
  }

  func normalizeCursorForMode() {
    state.cursor = clamp(state.cursor)
    guard state.mode == .normal || state.mode == .visualCharacter || state.mode == .visualLine
    else {
      return
    }
    let start = lineStart(at: state.cursor)
    let end = lineContentEnd(at: state.cursor)
    if end > start, state.cursor >= end {
      state.cursor = previousCharacterBoundary(from: end)
    }
  }

  func isJumpMotion(_ motion: VimMotion) -> Bool {
    switch motion {
    case .documentStart, .documentEnd, .line, .pageUp, .pageDown:
      return true
    default:
      return false
    }
  }

  func recordJumpOrigin() {
    let position = clamp(state.cursor)
    if jumpBackStack.last != position { jumpBackStack.append(position) }
    if jumpBackStack.count > 100 { jumpBackStack.removeFirst(jumpBackStack.count - 100) }
    jumpForwardStack.removeAll(keepingCapacity: true)
  }

  func jumpBackward(count: Int) {
    for _ in 0..<count {
      guard let target = jumpBackStack.popLast() else { break }
      if jumpForwardStack.last != state.cursor { jumpForwardStack.append(state.cursor) }
      state.cursor = clamp(target)
    }
    preferredColumn = nil
    preferredVisualColumn = nil
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func jumpForward(count: Int) {
    for _ in 0..<count {
      guard let target = jumpForwardStack.popLast() else { break }
      if jumpBackStack.last != state.cursor { jumpBackStack.append(state.cursor) }
      state.cursor = clamp(target)
    }
    preferredColumn = nil
    preferredVisualColumn = nil
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func recordChangePosition(_ position: Int) {
    let normalized = clamp(position)
    if changePositionIndex < changePositions.count {
      changePositions.removeSubrange(changePositionIndex..<changePositions.count)
    }
    if changePositions.last != normalized { changePositions.append(normalized) }
    if changePositions.count > 100 {
      changePositions.removeFirst(changePositions.count - 100)
    }
    changePositionIndex = changePositions.count
  }

  func moveThroughChangeList(older: Bool, count: Int) {
    guard !changePositions.isEmpty else { return }
    for _ in 0..<count {
      if older {
        changePositionIndex = max(0, changePositionIndex - 1)
      } else {
        changePositionIndex = min(changePositions.count, changePositionIndex + 1)
      }
    }
    guard changePositionIndex < changePositions.count else { return }
    state.cursor = clamp(changePositions[changePositionIndex])
    preferredColumn = nil
    preferredVisualColumn = nil
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func normalizedMacroName(_ name: Character) -> Character {
    Character(String(name).lowercased())
  }

  func clamp(_ offset: Int) -> Int {
    normalizedVimUTF16Offset(offset, in: state.text)
  }

  func stringIndex(_ utf16Offset: Int) -> String.Index {
    let safe = normalizedVimUTF16Offset(utf16Offset, in: state.text)
    let index = state.text.utf16.index(state.text.utf16.startIndex, offsetBy: safe)
    return String.Index(index, within: state.text) ?? state.text.endIndex
  }
}

extension VimEngine {
  func moveToViewport(_ position: VimViewportPosition, count: Int) {
    lineIndex.synchronize(with: state.text)
    let top = min(max(1, viewportTopLine), lineIndex.lineCount)
    let bottom = min(max(top, viewportBottomLine), lineIndex.lineCount)
    let targetLine: Int
    switch position {
    case .top:
      targetLine = min(bottom, top + max(1, count) - 1)
    case .middle:
      targetLine = top + (bottom - top) / 2
    case .bottom:
      targetLine = max(top, bottom - max(1, count) + 1)
    }
    state.cursor = firstNonBlank(at: lineOffset(targetLine))
    preferredColumn = nil
    preferredVisualColumn = nil
    normalizeCursorForMode()
    updateVisualSelection()
  }
}
