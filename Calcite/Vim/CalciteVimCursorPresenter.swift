import AppKit
import EditorVim

@MainActor
enum CalciteVimCursorPresenter {
  static func resolvedStyle(
    for mode: VimMode,
    profile: EditorCustomProfile
  ) -> EditorCursorStyle {
    switch mode {
    case .insert:
      return profile.vim.insertCursorStyle.resolvedStyle(default: .line)
    case .replace:
      return profile.vim.replaceCursorStyle.resolvedStyle(default: .underline)
    case .normal, .visualCharacter, .visualLine, .commandLine, .search:
      return profile.vim.normalCursorStyle.resolvedStyle(default: .block)
    }
  }

  static func apply(
    mode: VimMode,
    profile: EditorCustomProfile,
    to textView: NSTextView,
    isEnabled: Bool = true
  ) {
    guard let codeTextView = textView as? CodeEditorTextView else { return }
    guard isEnabled else {
      codeTextView.vimCursorStyle = nil
      codeTextView.vimCursorLocation = nil
      codeTextView.refreshInsertionPointRendering()
      return
    }

    // Always assign a concrete Vim shape. Leaving this nil hands cursor drawing
    // back to NSTextView, which is exactly how Normal and Replace modes regressed
    // to the ordinary GUI caret after profile recreation or view rebinding.
    codeTextView.vimCursorStyle = resolvedStyle(for: mode, profile: profile)
    codeTextView.refreshInsertionPointRendering()
  }
}
