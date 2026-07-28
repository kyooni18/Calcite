import Foundation

extension VimEngine {
  func visualBlockDimensions() -> (width: Int, height: Int)? {
    guard let selection = selectionSetUnlocked(), selection.shape == .block else { return nil }
    let fallbackColumns =
      min(
        selection.anchor.virtualColumn,
        selection.active.virtualColumn
      )..<max(selection.anchor.virtualColumn, selection.active.virtualColumn) + 1
    let columns = visualBlockColumnBounds() ?? fallbackColumns
    return (max(1, columns.count), max(1, selection.projectedRanges.count))
  }

  func executeBlockSemantic(_ command: VimBlockSemanticCommand) {
    switch command {
    case .select(let width, let height):
      selectVisualBlock(width: width, height: height)
    case .beginInsert(let append):
      beginVisualBlockInsert(append: append)
    case .replace(let character):
      replaceVisualBlock(with: character)
    }
  }

  func selectVisualBlock(width: Int, height: Int) {
    let anchor = state.cursor
    visualAnchor = anchor
    visualSelectionShape = .block
    state.mode = .visualCharacter

    var targetLine = lineStart(at: anchor)
    for _ in 1..<max(1, height) {
      let next = nextLineStart(targetLine)
      guard next != targetLine else { break }
      targetLine = next
    }
    let anchorColumn = displayColumn(from: lineStart(at: anchor), to: anchor)
    state.cursor = offset(
      from: targetLine,
      atDisplayColumn: anchorColumn + max(0, width - 1),
      contentEnd: lineContentEnd(at: targetLine)
    )
    updateVisualSelection()
  }

  func applyVisualBlockOperator(_ op: VimOperator, register: VimRegister) {
    let ranges = projectedVisualRanges()
    guard !ranges.isEmpty, let dimensions = visualBlockDimensions() else { return }
    rememberVisualSelection()

    let payload = ranges.map(substring).joined(separator: "\n")
    let registerValue = VimRegisterValue(
      text: payload,
      shape: .blockwise(width: dimensions.width)
    )

    switch op {
    case .yank:
      writeOperationRegister(register, value: registerValue, operation: .yank)
      state.cursor = ranges[0].lowerBound
      finishVisualBlock()

    case .change:
      beginEditCapture()
      let before = state
      writeOperationRegister(register, value: registerValue, operation: .smallDelete)
      let adjustedOffsets = blockOffsetsAfterDeleting(ranges)
      for range in ranges.reversed() where !range.isEmpty {
        replace(range: range, with: "")
      }
      state.cursor = adjustedOffsets.first ?? ranges[0].lowerBound
      state.mode = .insert
      state.selection = nil
      visualAnchor = nil
      visualSelectionShape = .character
      activeChange = VimChangeSession(
        before: before,
        commands: [
          .block(.select(width: dimensions.width, height: dimensions.height)),
          .action(.operatorSelection(.change), count: 1, register: register),
        ],
        changedText: before.text != state.text,
        insertRepeatCount: 1
      )
      blockInsertSession = VimBlockInsertSession(
        originalText: state.text,
        primaryOffset: state.cursor,
        targetOffsets: Array(adjustedOffsets.dropFirst()),
        append: false,
        height: dimensions.height
      )

    case .delete:
      performVisualBlockMutation(op: op, register: register, dimensions: dimensions) {
        writeOperationRegister(register, value: registerValue, operation: .smallDelete)
        for range in ranges.reversed() where !range.isEmpty { replace(range: range, with: "") }
        state.cursor = blockOffsetsAfterDeleting(ranges).first ?? ranges[0].lowerBound
      }
      finishVisualBlock()

    case .uppercase, .lowercase, .swapCase, .rot13:
      performVisualBlockMutation(op: op, register: register, dimensions: dimensions) {
        for range in ranges.reversed() where !range.isEmpty {
          let old = substring(range)
          replace(range: range, with: transformedBlockText(old, operation: op))
        }
        state.cursor = ranges[0].lowerBound
      }
      finishVisualBlock()

    case .indent, .outdent:
      let lineStarts = ranges.map { lineStart(at: $0.lowerBound) }
      performVisualBlockMutation(op: op, register: register, dimensions: dimensions) {
        for lineStart in lineStarts.reversed() {
          if op == .indent {
            replace(
              range: lineStart..<lineStart,
              with: String(repeating: " ", count: bufferStateStorage.tabWidth))
          } else {
            var end = lineStart
            var remaining = bufferStateStorage.tabWidth
            while remaining > 0, end < lineContentEnd(at: lineStart),
              isHorizontalWhitespace(at: end)
            {
              let next = nextCharacterBoundary(from: end)
              guard next > end else { break }
              end = next
              remaining -= 1
            }
            if end > lineStart { replace(range: lineStart..<end, with: "") }
          }
        }
        state.cursor = lineStarts.first ?? state.cursor
      }
      finishVisualBlock()

    case .format:
      publishMessage(
        VimMessage(
          text: "Formatting a Visual Block is not supported",
          code: "E481",
          severity: .warning,
          lifetime: .timed(milliseconds: 2600)
        )
      )
    }
  }

  func beginVisualBlockInsert(append: Bool) {
    let ranges = projectedVisualRanges()
    guard !ranges.isEmpty, let dimensions = visualBlockDimensions() else { return }
    rememberVisualSelection()
    let offsets = ranges.map { append ? $0.upperBound : $0.lowerBound }
    let before = state
    beginEditCapture()
    state.cursor = offsets[0]
    state.mode = .insert
    state.selection = nil
    visualAnchor = nil
    visualSelectionShape = .character
    activeChange = VimChangeSession(
      before: before,
      commands: [
        .block(.select(width: dimensions.width, height: dimensions.height)),
        .block(.beginInsert(append: append)),
      ],
      changedText: false,
      insertRepeatCount: 1
    )
    blockInsertSession = VimBlockInsertSession(
      originalText: state.text,
      primaryOffset: offsets[0],
      targetOffsets: Array(offsets.dropFirst()),
      append: append,
      height: dimensions.height
    )
  }

  func replicateVisualBlockInsertionIfNeeded() {
    guard let session = blockInsertSession,
      let delta = VimEditDelta.between(session.originalText, and: state.text),
      delta.location == session.primaryOffset,
      delta.removedText.isEmpty,
      !delta.insertedText.isEmpty
    else { return }

    let shift = delta.insertedUTF16Count
    for originalOffset in session.targetOffsets.reversed() {
      let target = originalOffset > session.primaryOffset ? originalOffset + shift : originalOffset
      replace(range: target..<target, with: delta.insertedText)
    }
    activeChange?.changedText = true
  }

  func replaceVisualBlock(with character: Character) {
    let ranges = projectedVisualRanges()
    guard !ranges.isEmpty, let dimensions = visualBlockDimensions() else { return }
    performVisualBlockMutation(op: .swapCase, register: .unnamed, dimensions: dimensions) {
      for range in ranges.reversed() where !range.isEmpty {
        let count = characterDistance(from: range.lowerBound, to: range.upperBound)
        replace(range: range, with: String(repeating: String(character), count: count))
      }
      state.cursor = ranges[0].lowerBound
    }
    if !isReplayingChange {
      lastChange = .replaceCharacter(character)
      lastRepeat = VimRepeatRecord(
        commands: [
          .block(.select(width: dimensions.width, height: dimensions.height)),
          .block(.replace(character)),
        ],
        finishesInInsertMode: false
      )
    }
    finishVisualBlock()
  }

  func pasteOverVisualBlock(
    _ value: VimRegisterValue,
    count: Int,
    sourceRegister: VimRegister
  ) {
    let ranges = projectedVisualRanges()
    guard !ranges.isEmpty, let dimensions = visualBlockDimensions() else { return }
    let rows = blockRows(from: value)
    let replaced = VimRegisterValue(
      text: ranges.map(substring).joined(separator: "\n"),
      shape: .blockwise(width: dimensions.width)
    )
    let before = state
    beginEditCapture()
    writeOperationRegister(.unnamed, value: replaced, operation: .smallDelete)
    for (index, range) in ranges.enumerated().reversed() {
      let row = rows[index % max(1, rows.count)]
      replace(range: range, with: String(repeating: row, count: max(1, count)))
    }
    state.cursor = ranges[0].lowerBound
    finishVisualBlock()
    let edits = endEditCapture()
    if before.text != state.text {
      pushUndo(before, edits: edits)
      lastRepeat = VimRepeatRecord(
        commands: [
          .block(.select(width: dimensions.width, height: dimensions.height)),
          .paste(value, after: false, count: count),
        ],
        finishesInInsertMode: false
      )
      lastChange = .pasteBefore
    }
    _ = sourceRegister
  }

  func pasteBlockwise(_ value: VimRegisterValue, after: Bool, count: Int) {
    let rows = blockRows(from: value)
    guard !rows.isEmpty else { return }

    let startLine = lineStart(at: state.cursor)
    let cursorColumn = displayColumn(from: startLine, to: state.cursor)
    let baseColumn =
      cursorColumn + (after ? displayWidthOfCharacter(at: state.cursor, column: cursorColumn) : 0)

    var lineStarts = [startLine]
    while lineStarts.count < rows.count {
      let current = lineStarts[lineStarts.count - 1]
      let next = nextLineStart(current)
      if next != current, lineHasTerminator(at: current) {
        lineStarts.append(next)
        continue
      }

      replace(range: state.text.utf16.count..<state.text.utf16.count, with: "\n")
      lineStarts.append(state.text.utf16.count)
    }

    var insertions: [(location: Int, text: String, padding: Int)] = []
    for (line, row) in zip(lineStarts, rows) {
      let end = lineContentEnd(at: line)
      let endColumn = displayColumn(from: line, to: end)
      let location = blockBoundaryOffset(
        from: line,
        desiredColumn: baseColumn,
        contentEnd: end
      )
      let padding = max(0, baseColumn - endColumn)
      insertions.append(
        (
          location: location,
          text: String(repeating: " ", count: padding)
            + String(repeating: row, count: max(1, count)),
          padding: padding
        ))
    }

    for insertion in insertions.reversed() {
      replace(range: insertion.location..<insertion.location, with: insertion.text)
    }
    if let first = insertions.first {
      state.cursor = first.location + first.padding
    }
    state.mode = .normal
  }

  private func performVisualBlockMutation(
    op: VimOperator,
    register: VimRegister,
    dimensions: (width: Int, height: Int),
    body: () -> Void
  ) {
    let before = state
    beginEditCapture()
    body()
    let edits = endEditCapture()
    guard before.text != state.text else { return }
    pushUndo(before, edits: edits)
    if !isReplayingChange {
      lastChange = .operatorSelection(op)
      lastRepeat = VimRepeatRecord(
        commands: [
          .block(.select(width: dimensions.width, height: dimensions.height)),
          .action(.operatorSelection(op), count: 1, register: register),
        ],
        finishesInInsertMode: false
      )
    }
  }

  func blockOffsetsAfterDeleting(_ ranges: [Range<Int>]) -> [Int] {
    var removed = 0
    return ranges.map { range in
      defer { removed += range.count }
      return range.lowerBound - removed
    }
  }

  func transformedBlockText(_ value: String, operation: VimOperator) -> String {
    switch operation {
    case .uppercase:
      return value.uppercased()
    case .lowercase:
      return value.lowercased()
    case .swapCase:
      return value.map { character in
        let source = String(character)
        if source == source.uppercased(), source != source.lowercased() {
          return source.lowercased()
        }
        if source == source.lowercased(), source != source.uppercased() {
          return source.uppercased()
        }
        return source
      }.joined()
    case .rot13:
      return String(
        value.unicodeScalars.map { scalar in
          let code = scalar.value
          if (65...90).contains(code), let mapped = UnicodeScalar(65 + (code - 65 + 13) % 26) {
            return Character(mapped)
          }
          if (97...122).contains(code), let mapped = UnicodeScalar(97 + (code - 97 + 13) % 26) {
            return Character(mapped)
          }
          return Character(String(scalar))
        })
    default:
      return value
    }
  }

  private func blockRows(from value: VimRegisterValue) -> [String] {
    let rows = value.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return rows.last == "" ? Array(rows.dropLast()) : rows
  }

  private func finishVisualBlock() {
    state.mode = .normal
    state.selection = nil
    visualAnchor = nil
    visualSelectionShape = .character
    blockInsertSession = nil
    preferredColumn = nil
    preferredVisualColumn = nil
  }
}
