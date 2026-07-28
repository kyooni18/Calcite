import Foundation

/// Identifies why the host moved the native editor selection. Vim uses the
/// source only for interaction policy; text reconciliation remains a separate
/// operation.
@_spi(Calcite)
public enum VimHostCursorMoveSource: String, Hashable, Sendable, Codable {
  case pointer
  case keyboard
  case accessibility
  case parentRequest
}

extension VimEngine {
  /// Moves the window-local Vim cursor to a native host position without
  /// replacing text or creating undo history.
  ///
  /// Insert and Replace modes remain active so a user can click and continue
  /// typing. A plain host cursor move leaves Visual mode, matching Vim's mouse
  /// behavior, and clears preferred columns so subsequent vertical motion starts
  /// from the newly selected position.
  @_spi(Calcite)
  @discardableResult
  public func acceptHostCursorMove(
    toUTF16Offset offset: Int,
    source: VimHostCursorMoveSource
  ) -> VimState {
    lock.withLock {
      _ = source
      let wasVisual = state.mode == .visualCharacter || state.mode == .visualLine
      if wasVisual { rememberVisualSelection() }
      state.cursor = normalizedVimUTF16Offset(offset, in: state.text)

      switch state.mode {
      case .visualCharacter, .visualLine:
        state.mode = .normal
        state.selection = nil
        visualAnchor = nil
        visualSelectionShape = .character
        blockInsertSession = nil
      case .commandLine, .search:
        state.mode = .normal
        state.selection = nil
      case .normal, .insert, .replace:
        state.selection = nil
      }

      preferredColumn = nil
      preferredVisualColumn = nil
      normalizeCursorForMode()
      return state
    }
  }
}
