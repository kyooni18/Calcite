import SwiftUI

extension MainView {
  var commandPaletteActions: [EditorCommandPalette.Action] {
    paletteActions.map { action in
      EditorCommandPalette.Action(
        id: action.id,
        title: action.title,
        systemImage: action.systemImage
      ) {
        closeCommandPalette()
        commandExecutor.perform(action.command)
      }
    }
  }

  private var paletteActions: [EditorPaletteAction] {
    [
      .init(id: "save", title: "Save", systemImage: "square.and.arrow.down", command: .save),
      .init(id: "format", title: "Format", systemImage: "text.alignleft", command: .format),
      .init(
        id: "input-mode",
        title: controller.profile.vim.enabled ? "Use GUI Editing" : "Use Vim Editing",
        systemImage: "keyboard",
        command: .toggleInputMode
      ),
      .init(
        id: "definition", title: "Go to Definition", systemImage: "arrow.turn.down.right",
        command: .goToDefinition),
      .init(
        id: "references", title: "Find References", systemImage: "list.bullet.rectangle",
        command: .findReferences),
      .init(
        id: "quick-help", title: "Show Quick Help", systemImage: "questionmark.circle",
        command: .showQuickHelp),
      .init(id: "build", title: "Build Project", systemImage: "hammer", command: .build),
      .init(id: "run", title: "Run Project", systemImage: "play", command: .run),
      .init(id: "test", title: "Test Project", systemImage: "checkmark.seal", command: .test),
      .init(id: "debug", title: "Start Debugging", systemImage: "ladybug", command: .startDebug),
      .init(
        id: "terminal", title: "Show Terminal", systemImage: "terminal", command: .showTerminal),
      .init(
        id: "problems", title: "Show Problems", systemImage: "exclamationmark.triangle",
        command: .showProblems),
      .init(
        id: "open-item", title: "Open File or Folder", systemImage: "folder",
        command: .openFileOrFolder),
      .init(
        id: "settings", title: "Open Settings", systemImage: "gearshape", command: .openSettings),
      .init(
        id: "theme-builder", title: "Open Theme Builder", systemImage: "paintpalette",
        command: .openThemeBuilder),
    ]
  }
}

private struct EditorPaletteAction {
  let id: String
  let title: String
  let systemImage: String
  let command: EditorCommand
}
