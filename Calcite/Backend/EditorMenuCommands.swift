import SwiftUI

// MARK: - Commands

nonisolated enum EditorCommand: Equatable, Sendable {
  case directionalSection(MainSectionDirection)
  case selectTab(Int)
  case save
  case saveAll

  case build
  case run
  case test
  case check
  case clean
  case stopBuild

  case startDebug
  case stopDebug
  case continueDebug
  case pauseDebug
  case stepOver
  case stepInto
  case stepOut
  case toggleBreakpoint

  case openSettings
  case openThemeBuilder
  case openFileOrFolder

  case showTerminal
  case showProblems
  case toggleSidebar
  case toggleFastPanel
  case toggleBottomPanel
  case toggleLayoutCustomization
  case toggleHiddenFiles
  case toggleIgnoredFiles
  case toggleBuildArtifacts
  case toggleDSStore

  case showCommandPalette
  case showQuickOpen
  case nextTab
  case previousTab
  case nextSection
  case previousSection
  case toggleInputMode

  case find
  case replace
  case format
  case requestCompletion
  case zoomIn
  case zoomOut
  case resetZoom

  case goToDefinition
  case findReferences
  case showQuickHelp

  case restartTerminal
  case clearTerminal
  case openExternalTerminal
  case runTerminalCommand(String)
}

nonisolated enum AppCommand: Equatable, Sendable {
  case newProject
  case openProject
  case openItem
  case openRecent(URL)
  case closeProject
}

// MARK: - Focused handlers

@MainActor
struct EditorCommandHandler {
  private let action: (EditorCommand) -> Void

  init(perform: @escaping (EditorCommand) -> Void) {
    action = perform
  }

  func perform(_ command: EditorCommand) {
    action(command)
  }
}

@MainActor
struct AppCommandHandler {
  private let action: (AppCommand) -> Void

  init(perform: @escaping (AppCommand) -> Void) {
    action = perform
  }

  func perform(_ command: AppCommand) {
    action(command)
  }
}

nonisolated struct EditorCommandAvailability: Equatable, Sendable {
  var hasDocument: Bool
  var hasUnsavedDocuments: Bool
  var canSave: Bool
  var canSaveAll: Bool
  var canBuild: Bool
  var canRun: Bool
  var canTest: Bool
  var canCheck: Bool
  var isBuilding: Bool
  var canStartDebug: Bool
  var debugIsActive: Bool
  var debugIsRunning: Bool
  var debugIsPaused: Bool
}

private struct EditorCommandHandlerKey: FocusedValueKey {
  typealias Value = EditorCommandHandler
}

private struct AppCommandHandlerKey: FocusedValueKey {
  typealias Value = AppCommandHandler
}

private struct EditorCommandAvailabilityKey: FocusedValueKey {
  typealias Value = EditorCommandAvailability
}

extension FocusedValues {
  var editorCommandHandler: EditorCommandHandler? {
    get { self[EditorCommandHandlerKey.self] }
    set { self[EditorCommandHandlerKey.self] = newValue }
  }

  var appCommandHandler: AppCommandHandler? {
    get { self[AppCommandHandlerKey.self] }
    set { self[AppCommandHandlerKey.self] = newValue }
  }

  var editorCommandAvailability: EditorCommandAvailability? {
    get { self[EditorCommandAvailabilityKey.self] }
    set { self[EditorCommandAvailabilityKey.self] = newValue }
  }
}

// MARK: - Menu commands

struct EditorEditCommands: Commands {
  @FocusedValue(\.editorCommandHandler) private var handler
  @FocusedValue(\.editorCommandAvailability) private var availability

  var body: some Commands {
    CommandGroup(after: .pasteboard) {
      Divider()
      Button("Find…") { handler?.perform(.find) }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(handler == nil || availability?.hasDocument != true)
      Button("Find and Replace…") { handler?.perform(.replace) }
        .keyboardShortcut("f", modifiers: [.command, .option])
        .disabled(handler == nil || availability?.hasDocument != true)
      Button("Format Document") { handler?.perform(.format) }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(handler == nil || availability?.hasDocument != true)
      Button("Show Completions") { handler?.perform(.requestCompletion) }
        .keyboardShortcut(" ", modifiers: .control)
        .disabled(handler == nil || availability?.hasDocument != true)
    }
  }
}

struct EditorProjectCommands: Commands {
  @FocusedValue(\.editorCommandHandler) private var handler
  @FocusedValue(\.editorCommandAvailability) private var availability

  var body: some Commands {
    CommandMenu("Build") {
      Button("Build") { handler?.perform(.build) }
        .keyboardShortcut("b", modifiers: .command)
        .disabled(
          handler == nil || availability?.canBuild != true || availability?.isBuilding == true)
      Button("Run") { handler?.perform(.run) }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(
          handler == nil || availability?.canRun != true || availability?.isBuilding == true)
      Button("Test") { handler?.perform(.test) }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .disabled(
          handler == nil || availability?.canTest != true || availability?.isBuilding == true)
      Button("Check") { handler?.perform(.check) }
        .disabled(
          handler == nil || availability?.canCheck != true || availability?.isBuilding == true)
      Button("Clean") { handler?.perform(.clean) }
        .disabled(handler == nil || availability?.isBuilding == true)
      Divider()
      Button("Stop") { handler?.perform(.stopBuild) }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(handler == nil || availability?.isBuilding != true)
    }

    CommandMenu("Debug") {
      Button("Start Debugging") { handler?.perform(.startDebug) }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(handler == nil || availability?.canStartDebug != true)
      Button("Continue") { handler?.perform(.continueDebug) }
        .disabled(handler == nil || availability?.debugIsPaused != true)
      Button("Pause") { handler?.perform(.pauseDebug) }
        .disabled(handler == nil || availability?.debugIsRunning != true)
      Divider()
      Button("Step Over") { handler?.perform(.stepOver) }
        .keyboardShortcut("o", modifiers: [.command, .control])
        .disabled(handler == nil || availability?.debugIsPaused != true)
      Button("Step Into") { handler?.perform(.stepInto) }
        .keyboardShortcut("i", modifiers: [.command, .control])
        .disabled(handler == nil || availability?.debugIsPaused != true)
      Button("Step Out") { handler?.perform(.stepOut) }
        .keyboardShortcut("u", modifiers: [.command, .control])
        .disabled(handler == nil || availability?.debugIsPaused != true)
      Button("Toggle Breakpoint") { handler?.perform(.toggleBreakpoint) }
        .keyboardShortcut("b", modifiers: [.command, .control])
        .disabled(handler == nil || availability?.hasDocument != true)
      Divider()
      Button("Stop Debugging") { handler?.perform(.stopDebug) }
        .disabled(handler == nil || availability?.debugIsActive != true)
    }

    CommandMenu("Project") {
      Button("Command Palette…") { handler?.perform(.showCommandPalette) }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(handler == nil)
      Button("Quick Open…") { handler?.perform(.showQuickOpen) }
        .keyboardShortcut("p", modifiers: .command)
        .disabled(handler == nil)
      Button("Show Problems") { handler?.perform(.showProblems) }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(handler == nil)
      Divider()
      Button("Toggle Fast Panel") { handler?.perform(.toggleFastPanel) }
        .keyboardShortcut("j", modifiers: [.command, .shift])
        .disabled(handler == nil)
      Button("Toggle File Tree") { handler?.perform(.toggleSidebar) }
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .disabled(handler == nil)
      Button("Toggle Bottom View") { handler?.perform(.toggleBottomPanel) }
        .disabled(handler == nil)
      Button("Customize Layout") { handler?.perform(.toggleLayoutCustomization) }
        .disabled(handler == nil)
      Divider()
      Button("Next Tab") { handler?.perform(.nextTab) }
        .keyboardShortcut(.tab, modifiers: .control)
        .disabled(handler == nil)
      Button("Previous Tab") { handler?.perform(.previousTab) }
        .keyboardShortcut(.tab, modifiers: [.control, .shift])
        .disabled(handler == nil)
      Button("Next Section") { handler?.perform(.nextSection) }
        .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
        .disabled(handler == nil)
      Button("Previous Section") { handler?.perform(.previousSection) }
        .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
        .disabled(handler == nil)
      Divider()
      Button("Toggle GUI/Vim Mode") { handler?.perform(.toggleInputMode) }
        .keyboardShortcut("v", modifiers: [.command, .control])
        .disabled(handler == nil || availability?.hasDocument != true)
    }
  }
}

struct EditorTerminalCommands: Commands {
  @FocusedValue(\.editorCommandHandler) private var handler

  var body: some Commands {
    CommandMenu("Terminal") {
      Button("Show Terminal") { handler?.perform(.showTerminal) }
        .keyboardShortcut("`", modifiers: [.command, .control])
        .disabled(handler == nil)
      Button("Restart Terminal") { handler?.perform(.restartTerminal) }
        .disabled(handler == nil)
      Button("Clear Terminal") { handler?.perform(.clearTerminal) }
        .keyboardShortcut("k", modifiers: [.command, .control])
        .disabled(handler == nil)
      Button("Open External Terminal") { handler?.perform(.openExternalTerminal) }
        .disabled(handler == nil)
    }
  }
}
