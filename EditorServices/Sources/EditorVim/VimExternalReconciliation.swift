import Foundation

@_spi(Calcite)
public enum VimExternalReconciliationResult: Hashable, Sendable {
  case unchanged
  case preserved
  case cancelledConflict(VimMessage)
}

extension VimEngine {
  @_spi(Calcite)
  public func reconcileExternalText(
    _ text: String,
    cursor requestedCursor: Int? = nil
  ) -> VimExternalReconciliationResult {
    lock.withLock {
      let before = state
      guard before.text != text else {
        if let requestedCursor {
          state.cursor = normalizedVimUTF16Offset(requestedCursor, in: text)
          normalizeCursorForMode()
        }
        return .unchanged
      }

      guard let delta = VimEditDelta.between(before.text, and: text) else {
        synchronize(text: text, cursor: requestedCursor)
        let message = VimMessage(
          text: "External update replaced the active Vim state",
          code: "VIM_EXTERNAL_REPLACED",
          severity: .warning,
          lifetime: .timed(milliseconds: 2800)
        )
        publishMessage(message)
        return .cancelledConflict(message)
      }

      let changedRange = delta.forwardRange
      let visualRanges = selectionSetUnlocked()?.projectedRanges ?? []
      let overlapsVisual = visualRanges.contains { Self.externalRange(changedRange, overlaps: $0) }
      let hasUnsafeTransientState =
        activeChange != nil || blockInsertSession != nil || before.mode == .insert
        || before.mode == .replace
      let conflicts = hasUnsafeTransientState || overlapsVisual

      let adjustedCursor = Self.adjustedExternalPosition(
        requestedCursor ?? before.cursor,
        replacing: changedRange,
        replacementUTF16Count: delta.insertedUTF16Count
      )

      activeChange = nil
      if editCaptureDepth > 0 { _ = endEditCapture() }
      replaceRestorations.removeAll(keepingCapacity: true)
      blockInsertSession = nil
      temporaryInsertReturnMode = nil

      let updatesSharedBufferState = bufferStateStorage.authoritativeText != text
      state.text = text
      lineIndex.synchronize(with: before.text)
      lineIndex.apply(
        replacementRange: changedRange,
        removedText: delta.removedText,
        insertedText: delta.insertedText,
        resultingText: text
      )
      if updatesSharedBufferState {
        adjustBufferPositions(
          afterReplacing: changedRange,
          replacementUTF16Count: delta.insertedUTF16Count
        )
        bufferStateStorage.authoritativeText = text
      }
      adjustWindowPositions(
        afterReplacing: changedRange,
        replacementUTF16Count: delta.insertedUTF16Count
      )
      state.cursor = normalizedVimUTF16Offset(adjustedCursor, in: text)
      preferredColumn = nil
      preferredVisualColumn = nil

      if conflicts {
        state.mode = .normal
        state.selection = nil
        visualAnchor = nil
        visualSelectionShape = .character
        normalizeCursorForMode()
        let message = VimMessage(
          text: "External edit cancelled an overlapping Vim interaction",
          code: "VIM_EXTERNAL_CONFLICT",
          severity: .warning,
          lifetime: .timed(milliseconds: 2800)
        )
        publishMessage(message)
        commitActiveBufferText(before: before.text, after: text)
        return .cancelledConflict(message)
      }

      normalizeCursorForMode()
      commitActiveBufferText(before: before.text, after: text)
      return .preserved
    }
  }

  private static func externalRange(_ lhs: Range<Int>, overlaps rhs: Range<Int>) -> Bool {
    if lhs.isEmpty { return rhs.contains(lhs.lowerBound) }
    if rhs.isEmpty { return lhs.contains(rhs.lowerBound) }
    return lhs.overlaps(rhs)
  }

  private static func adjustedExternalPosition(
    _ position: Int,
    replacing range: Range<Int>,
    replacementUTF16Count: Int
  ) -> Int {
    let delta = replacementUTF16Count - range.count
    if position < range.lowerBound { return position }
    if range.isEmpty, position == range.lowerBound { return position + replacementUTF16Count }
    if position <= range.upperBound { return range.lowerBound + replacementUTF16Count }
    return position + delta
  }
}
