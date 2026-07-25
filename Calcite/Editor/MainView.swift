import AppKit
import EditorServices
import SwiftUI

@MainActor
struct MainView: View {
  @Environment(\.colorScheme) var colorScheme

  @StateObject var controller: EditorWorkspaceController
  @StateObject var terminal: EditorTerminalSession
  @StateObject var workspaceTabs: WorkspaceTabController
  @StateObject var palette: CommandPaletteState
  @StateObject var fileVisibility: FileVisibilitySettings
  @StateObject var themeBuilderSession: ThemeBuilderSession
  @StateObject var commandExecutor: EditorCommandExecutor
  @StateObject var lifecycle: WorkspaceLifecycleCoordinator
  @StateObject var nowPlaying: NowPlayingController

  let initialFileURL: URL?
  let documentOpenRequestID: UUID?
  let onOpenItem: () -> Void
  let onControllerReady: (EditorWorkspaceController?) -> Void

  @State var selectedFileURL: URL?
  @State var sideOpenRequest: EditorSideOpenRequest?
  @State var pendingClose: EditorTab?
  @State var pendingUtilityClose: WorkspaceTabID?
  @State var pendingDocumentOpenURL: URL?
  @State var showsBuildProjectControl = true
  @State var showsNowPlaying = true
  @State var usesLiveMarkdownEditor = true
  @State var sidebarWidth: Double
  @State var bottomPanelHeight: Double
  @FocusState var topSearchIsFocused: Bool

  @AppStorage("markdownShowsSyntax") var showsMarkdownSyntax = true
  @AppStorage("markdownWrapsLines") var markdownWrapsLines = true
  @AppStorage("editorAppearanceMode") var appearanceModeRaw =
    EditorInterfaceAppearance.system.rawValue

  init(
    workspaceURL: URL,
    initialFileURL: URL? = nil,
    documentOpenRequestID: UUID? = nil,
    onOpenItem: @escaping () -> Void = {},
    onControllerReady: @escaping (EditorWorkspaceController?) -> Void = { _ in }
  ) {
    let controller = EditorWorkspaceController(workspaceURL: workspaceURL)
    let terminal = EditorTerminalSessionRegistry.shared.session(for: workspaceURL)
    let workspaceTabs = WorkspaceTabController(workspaceURL: workspaceURL)
    let palette = CommandPaletteState()
    let fileVisibility = FileVisibilitySettings()
    let themeBuilderSession = ThemeBuilderSession(controller: controller)
    let initialBottomPanel = EditorWorkspaceLayoutStore.loadBottomPanel(for: workspaceURL)
    let initialSidebarVisibility = EditorWorkspaceLayoutStore.loadSidebarVisibility(
      for: workspaceURL)
    let initialSidebarWidth = EditorWorkspaceLayoutStore.loadSidebarWidth(for: workspaceURL)
    let initialBottomPanelHeight = EditorWorkspaceLayoutStore.loadBottomPanelHeight(
      for: workspaceURL)
    let commandExecutor = EditorCommandExecutor(
      controller: controller,
      terminal: terminal,
      workspaceTabs: workspaceTabs,
      palette: palette,
      fileVisibility: fileVisibility,
      themeBuilderSession: themeBuilderSession,
      initialBottomPanel: initialBottomPanel,
      initialSidebarVisibility: initialSidebarVisibility,
      onOpenItem: onOpenItem
    )

    self.initialFileURL = initialFileURL
    self.documentOpenRequestID = documentOpenRequestID
    self.onOpenItem = onOpenItem
    self.onControllerReady = onControllerReady
    _controller = StateObject(wrappedValue: controller)
    _terminal = StateObject(wrappedValue: terminal)
    _workspaceTabs = StateObject(wrappedValue: workspaceTabs)
    _palette = StateObject(wrappedValue: palette)
    _fileVisibility = StateObject(wrappedValue: fileVisibility)
    _themeBuilderSession = StateObject(wrappedValue: themeBuilderSession)
    _commandExecutor = StateObject(wrappedValue: commandExecutor)
    _lifecycle = StateObject(
      wrappedValue: WorkspaceLifecycleCoordinator(controller: controller, terminal: terminal)
    )
    _nowPlaying = StateObject(wrappedValue: NowPlayingController())
    _sidebarWidth = State(initialValue: initialSidebarWidth)
    _bottomPanelHeight = State(initialValue: initialBottomPanelHeight)
  }

  var body: some View {
    dialogView
  }
}
