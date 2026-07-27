import Foundation

extension VimEngine {
  func withExecutionBatch<T>(_ body: () throws -> T) rethrows -> T {
    let isOutermost = executionBatchDepth == 0
    if isOutermost { currentExecutionEdits.removeAll(keepingCapacity: true) }
    executionBatchDepth += 1
    defer {
      executionBatchDepth -= 1
      if isOutermost {
        completedExecutionEdits = currentExecutionEdits
        currentExecutionEdits.removeAll(keepingCapacity: true)
      }
    }
    return try body()
  }

  func recordExecutionEdit(_ edit: VimEditDelta) {
    guard executionBatchDepth > 0 else { return }
    currentExecutionEdits.append(edit)
  }

  func recordHistoryApplication(_ transaction: VimChangeTransaction, forward: Bool) {
    if forward {
      for edit in transaction.edits { recordExecutionEdit(edit) }
    } else {
      for edit in transaction.edits.reversed() {
        recordExecutionEdit(
          VimEditDelta(
            location: edit.location,
            removedText: edit.insertedText,
            insertedText: edit.removedText
          ))
      }
    }
  }

  /// Calcite-only incremental edit handoff. The method is SPI so it is excluded
  /// from the ordinary EditorVim source-compatibility surface.
  @_spi(Calcite)
  public func consumeCompletedEdits() -> [(range: Range<Int>, replacement: String)] {
    lock.withLock {
      let result = completedExecutionEdits.map { ($0.forwardRange, $0.insertedText) }
      completedExecutionEdits.removeAll(keepingCapacity: true)
      return result
    }
  }
}

extension VimEngine {
  func updateViewportContext(visibleUTF16Range: Range<Int>) {
    lineIndex.synchronize(with: state.text)
    let length = state.text.utf16.count
    let lower = min(max(0, visibleUTF16Range.lowerBound), length)
    let upper = min(max(lower, visibleUTF16Range.upperBound), length)
    viewportTopLine = lineIndex.oneBasedLine(containing: lower, textLength: length)
    let bottomProbe = upper > lower ? previousCharacterBoundary(from: upper) : lower
    viewportBottomLine = lineIndex.oneBasedLine(containing: bottomProbe, textLength: length)
    viewportPageLineCount = max(1, viewportBottomLine - viewportTopLine + 1)
    viewportHalfPageLineCount = max(1, viewportPageLineCount / 2)
  }

  @_spi(Calcite)
  public func updateViewport(visibleUTF16Range: Range<Int>) {
    lock.withLock { updateViewportContext(visibleUTF16Range: visibleUTF16Range) }
  }
}
