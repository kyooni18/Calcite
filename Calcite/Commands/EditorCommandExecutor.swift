import Combine
import EditorServices
import Foundation

@MainActor
final class EditorCommandExecutor: ObservableObject {
  @Published var bottomPanel: EditorBottomPanel?
  @Published var showsSidebar: Bool
  @Published private(set) var tabCommandEvent: EditorTabCommandEvent?
  @Published private(set) var layoutCommandEvent: EditorLayoutCommandEvent?

  let controller: EditorWorkspaceController
  let terminal: EditorTerminalSession
  let workspaceTabs: WorkspaceTabController
  let palette: CommandPaletteState
  let fileVisibility: FileVisibilitySettings
  let themeBuilderSession: ThemeBuilderSession

  private let onOpenItem: () -> Void

  init(
    controller: EditorWorkspaceController,
    terminal: EditorTerminalSession,
    workspaceTabs: WorkspaceTabController,
    palette: CommandPaletteState,
    fileVisibility: FileVisibilitySettings,
    themeBuilderSession: ThemeBuilderSession,
    initialBottomPanel: EditorBottomPanel?,
    initialSidebarVisibility: Bool,
    onOpenItem: @escaping () -> Void
  ) {
    self.controller = controller
    self.terminal = terminal
    self.workspaceTabs = workspaceTabs
    self.palette = palette
    self.fileVisibility = fileVisibility
    self.themeBuilderSession = themeBuilderSession
    bottomPanel = initialBottomPanel
    showsSidebar = initialSidebarVisibility
    self.onOpenItem = onOpenItem
  }

  func perform(_ command: EditorCommand) {
    switch command {
    case .save:
      switch workspaceTabs.selection {
      case .document:
        controller.saveActiveDocument()
      case .themeBuilder:
        themeBuilderSession.save()
      case .settings, nil:
        break
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
      showPanel(.debug)
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
      controller.toggleBreakpointAtCurrentLine()

    case .openSettings:
      workspaceTabs.openSettings()
    case .openThemeBuilder:
      workspaceTabs.openThemeBuilder()
      themeBuilderSession.beginEditing()
    case .openFileOrFolder:
      onOpenItem()

    case .showTerminal:
      selectActiveDocument()
      showPanel(.terminal)
      terminal.startIfNeeded()
    case .showProblems:
      selectActiveDocument()
      showPanel(.problems)
    case .toggleSidebar:
      showsSidebar.toggle()
    case .toggleBottomPanel:
      if bottomPanel == nil {
        perform(.showTerminal)
      } else {
        bottomPanel = nil
      }
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
    case .toggleInputMode:
      guard hasSelectedDocument else { return }
      controller.toggleEditorInputMode()

    case .find:
      sendTabCommand(.find)
    case .replace:
      sendTabCommand(.replace)
    case .format:
      guard hasSelectedDocument else { return }
      controller.activeTab?.format(
        tabWidth: controller.profile.behavior.tabWidth,
        insertSpaces: controller.profile.behavior.insertSpaces
      )
    case .requestCompletion:
      guard hasSelectedDocument else { return }
      controller.activeTab?.requestCompletionsExplicitly()
    case .zoomIn:
      sendTabCommand(.zoomIn)
    case .zoomOut:
      sendTabCommand(.zoomOut)
    case .resetZoom:
      sendTabCommand(.resetZoom)

    case .goToDefinition:
      guard hasSelectedDocument else { return }
      controller.goToDefinition()
    case .findReferences:
      guard hasSelectedDocument else { return }
      controller.findReferences()
    case .showQuickHelp:
      guard hasSelectedDocument else { return }
      controller.showQuickHelp()

    case .restartTerminal:
      selectActiveDocument()
      showPanel(.terminal)
      terminal.restart()
    case .clearTerminal:
      terminal.clear()
    case .openExternalTerminal:
      terminal.openExternalTerminal()
    case .runTerminalCommand(let command):
      guard !command.isEmpty else { return }
      selectActiveDocument()
      showPanel(.terminal)
      terminal.startIfNeeded()
      terminal.send(command + "\r")
    }
  }

  func sendLayoutCommand(_ command: EditorLayoutCommand) {
    guard hasSelectedDocument else { return }
    layoutCommandEvent = EditorLayoutCommandEvent(command: command)
  }

  func openDocument(_ url: URL) {
    Task {
      _ = await openAndSelectDocument(url)
    }
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
    workspaceTabs.selectDocument(tab.id)
    return tab
  }

  func showPanel(_ panel: EditorBottomPanel, toggle: Bool = false) {
    if toggle, bottomPanel == panel {
      bottomPanel = nil
    } else {
      bottomPanel = panel
    }
  }

  private func runBuildTask(_ kind: EditorBuildTaskKind) {
    selectActiveDocument()
    showPanel(.build)
    controller.runBuildTask(kind)
  }

  private func sendTabCommand(_ command: EditorTabCommand) {
    guard case .document(let tabID) = workspaceTabs.selection,
      controller.tabs.contains(where: { $0.id == tabID })
    else { return }
    if controller.selectedTabID != tabID {
      controller.selectedTabID = tabID
    }
    tabCommandEvent = EditorTabCommandEvent(targetTabID: tabID, command: command)
  }

  private var hasSelectedDocument: Bool {
    guard case .document(let tabID) = workspaceTabs.selection else { return false }
    return controller.activeTab?.id == tabID
  }

  private func selectActiveDocument() {
    guard let tabID = controller.selectedTabID else { return }
    workspaceTabs.selectDocument(tabID)
  }
}
