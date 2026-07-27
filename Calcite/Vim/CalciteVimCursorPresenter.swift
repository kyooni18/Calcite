import AppKit
import EditorVim

@MainActor
enum CalciteVimCursorPresenter {
  static func apply(
    mode: VimMode,
    profile: EditorCustomProfile,
    to textView: NSTextView,
    isEnabled: Bool = true
  ) {
    guard let codeTextView = textView as? CodeEditorTextView else { return }
    guard isEnabled else {
      codeTextView.vimCursorStyle = nil
      return
    }

    switch mode {
    case .insert:
      codeTextView.vimCursorStyle = profile.vim.insertCursorStyle.overrideStyle
    case .replace:
      codeTextView.vimCursorStyle = profile.vim.replaceCursorStyle.overrideStyle
    case .normal, .visualCharacter, .visualLine, .commandLine, .search:
      codeTextView.vimCursorStyle = profile.vim.normalCursorStyle.overrideStyle
    }
  }
}
