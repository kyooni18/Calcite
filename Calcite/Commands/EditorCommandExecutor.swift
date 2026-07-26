import AppKit
import Combine
import EditorServices
import Foundation
import SwiftUI

@MainActor
protocol EditorCommandExecutorDelegate: AnyObject {
  var commandSelectedDocumentID: UUID? { get }
  var commandSelectedSectionKind: MainSectionKind? { get }

  func commandSelectDocument(_ id: UUID)
  func commandPresentSection(_ kind: MainSectionKind)
  func commandToggleSidebar()
  func commandToggleFastPanel()
  func commandToggleBottomPanel()
  func commandToggleLayoutCustomization()
  func commandNavigateTab(forward: Bool)
  func commandSelectTab(number: Int)
  func commandNavigateSection(forward: Bool)
  func commandNavigateSection(direction: MainSectionDirection)
}

/// Executes commands against the project backend while delegating window presentation to the
/// active `CalciteBackendWindowSession`.
@MainActor
final class EditorCommandExecutor: ObservableObject {
  weak var delegate: EditorCommandExecutorDelegate?

  let controller: EditorWorkspaceController
  let terminal: EditorTerminalSession
  let palette: CommandPaletteState
  let fileVisibility: FileVisibilitySettings
  let themeBuilderSession: ThemeBuilderSession

  private let onOpenItem: () -> Void
  private var settingsWindow: NSWindow?

  init(
    controller: EditorWorkspaceController,
    terminal: EditorTerminalSession,
    palette: CommandPaletteState,
    fileVisibility: FileVisibilitySettings,
    themeBuilderSession: ThemeBuilderSession,
    onOpenItem: @escaping () -> Void
  ) {
    self.controller = controller
    self.terminal = terminal
    self.palette = palette
    self.fileVisibility = fileVisibility
    self.themeBuilderSession = themeBuilderSession
    self.onOpenItem = onOpenItem
  }

  func perform(_ command: EditorCommand) {
    switch command {
    case .save:
      if delegate?.commandSelectedSectionKind == .themeBuilder {
        themeBuilderSession.save()
      } else {
        selectActiveDocument()
        controller.saveActiveDocument()
      }

    case .saveAll:
      Task { _ = await controller.saveAllDocuments() }

    case .build:
      runBuildTask(.build)
    case .run:
      runBuildTask(.run)
    case .test:
      runBuildTask(.test)
    case .check:
      runBuildTask(.check)
    case .clean:
      runBuildTask(.clean)
    case .stopBuild:
      controller.cancelBuildTask()

    case .startDebug:
      selectActiveDocument()
      delegate?.commandPresentSection(.debug)
      controller.startDebugging()
    case .stopDebug:
      controller.stopDebugging()
    case .continueDebug:
      controller.continueDebugging()
    case .pauseDebug:
      controller.pauseDebugging()
    case .stepOver:
      controller.stepOver()
    case .stepInto:
      controller.stepInto()
    case .stepOut:
      controller.stepOut()
    case .toggleBreakpoint:
      guard hasSelectedDocument else { return }
      selectActiveDocument()
      controller.toggleBreakpointAtCurrentLine()

    case .openSettings:
      showSettingsWindow()
    case .openThemeBuilder:
      themeBuilderSession.beginEditing()
      delegate?.commandPresentSection(.themeBuilder)
    case .openFileOrFolder:
      onOpenItem()

    case .showTerminal:
      selectActiveDocument()
      delegate?.commandPresentSection(.terminal)
      terminal.startIfNeeded()
    case .showProblems:
      selectActiveDocument()
      delegate?.commandPresentSection(.problems)
    case .toggleSidebar:
      delegate?.commandToggleSidebar()
    case .toggleFastPanel:
      delegate?.commandToggleFastPanel()
    case .toggleBottomPanel:
      delegate?.commandToggleBottomPanel()
    case .toggleLayoutCustomization:
      delegate?.commandToggleLayoutCustomization()
    case .toggleHiddenFiles:
      fileVisibility.showsHiddenFiles.toggle()
    case .toggleIgnoredFiles:
      fileVisibility.showsIgnoredFiles.toggle()
    case .toggleBuildArtifacts:
      fileVisibility.showsBuildArtifacts.toggle()
    case .toggleDSStore:
      fileVisibility.showsDSStore.toggle()

    case .showCommandPalette:
      palette.present(mode: .commands)
    case .showQuickOpen:
      palette.present(mode: .files)
    case .nextTab:
      delegate?.commandNavigateTab(forward: true)
    case .previousTab:
      delegate?.commandNavigateTab(forward: false)
    case .selectTab(let number):
      delegate?.commandSelectTab(number: number)
    case .nextSection:
      delegate?.commandNavigateSection(forward: true)
    case .previousSection:
      delegate?.commandNavigateSection(forward: false)
    case .directionalSection(let direction):
      delegate?.commandNavigateSection(direction: direction)
    case .toggleInputMode:
      guard hasSelectedDocument else { return }
      selectActiveDocument()
      controller.toggleEditorInputMode()

    case .find, .replace, .zoomIn, .zoomOut, .resetZoom:
      // These editor-instance commands are published by `CalciteBackendWindowSession` before the
      // shared controller command is executed.
      selectActiveDocument()

    case .format:
      guard hasSelectedDocument else { return }
      selectActiveDocument()
      controller.activeTab?.format(
        tabWidth: controller.profile.behavior.tabWidth,
        insertSpaces: controller.profile.behavior.insertSpaces
      )
    case .requestCompletion:
      guard hasSelectedDocument else { return }
      selectActiveDocument()
      controller.activeTab?.requestCompletionsExplicitly()

    case .goToDefinition:
      guard hasSelectedDocument else { return }
      selectActiveDocument()
      controller.goToDefinition()
    case .findReferences:
      guard hasSelectedDocument else { return }
      selectActiveDocument()
      controller.findReferences()
    case .showQuickHelp:
      guard hasSelectedDocument else { return }
      selectActiveDocument()
      controller.showQuickHelp()

    case .restartTerminal:
      selectActiveDocument()
      delegate?.commandPresentSection(.terminal)
      terminal.restart()
    case .clearTerminal:
      terminal.clear()
    case .openExternalTerminal:
      terminal.openExternalTerminal()
    case .runTerminalCommand(let command):
      guard !command.isEmpty else { return }
      selectActiveDocument()
      delegate?.commandPresentSection(.terminal)
      terminal.startIfNeeded()
      terminal.send(command + "\r")
    }
  }

  func openDocument(_ url: URL) {
    Task {
      _ = await openAndSelectDocument(url)
    }
  }

  private func showSettingsWindow() {
    if let settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let rootView = ServiceSettingsView(
      controller: controller,
      openFile: openDocument
    )
    let hostingController = NSHostingController(rootView: rootView)
    let window = NSWindow(contentViewController: hostingController)
    window.title = "Calcite Settings"
    window.setContentSize(NSSize(width: 1_080, height: 760))
    window.minSize = NSSize(width: 820, height: 560)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.isReleasedWhenClosed = false
    window.center()
    settingsWindow = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @discardableResult
  func openAndSelectDocument(_ url: URL) async -> EditorTab? {
    let standardizedURL = url.standardizedFileURL
    await controller.openDocument(at: standardizedURL)
    guard
      let tab = controller.tabs.first(where: {
        $0.url.standardizedFileURL == standardizedURL
      })
    else { return nil }
    delegate?.commandSelectDocument(tab.id)
    return tab
  }

  private func runBuildTask(_ kind: EditorBuildTaskKind) {
    selectActiveDocument()
    delegate?.commandPresentSection(.buildOutput)
    controller.runBuildTask(kind)
  }

  private var hasSelectedDocument: Bool {
    guard let selectedID = delegate?.commandSelectedDocumentID else { return false }
    return controller.tabs.contains(where: { $0.id == selectedID })
  }

  private func selectActiveDocument() {
    guard let selectedID = delegate?.commandSelectedDocumentID else { return }
    delegate?.commandSelectDocument(selectedID)
    if controller.selectedTabID != selectedID {
      controller.selectedTabID = selectedID
    }
  }
}
