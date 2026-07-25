import SwiftUI

struct EditorSideOpenRequest: Equatable {
  let id = UUID()
  let url: URL
  var orientation: EditorSplitOrientation = .right
}

enum EditorSplitOrientation: String, Codable {
  case right
  case below
}

private enum EditorPane: String, Hashable {
  case primary
  case secondary
}

struct EditorWorkspaceDetail: View {
  @ObservedObject var controller: EditorWorkspaceController
  @ObservedObject var terminal: EditorTerminalSession
  @Binding var bottomPanel: EditorBottomPanel?
  @Binding var bottomPanelHeight: Double
  @Binding var sideOpenRequest: EditorSideOpenRequest?

  let usesLiveMarkdownEditor: Bool
  let showsMarkdownSyntax: Bool
  let wrapsMarkdownLines: Bool
  let requestClose: (EditorTab) -> Void
  var showsTabsBar = true
  var tabCommandEvent: EditorTabCommandEvent?
  var layoutCommandEvent: EditorLayoutCommandEvent?

  @State private var splitOrientation: EditorSplitOrientation?
  @State private var primaryTabID: EditorTab.ID?
  @State private var secondaryTabID: EditorTab.ID?
  @State private var activePane: EditorPane = .primary

  var body: some View {
    EditorWorkspaceScaffold(showsTabsBar: showsTabsBar) {
      EditorTabsBar(
        tabs: controller.tabs,
        selectedID: selectionBinding(for: activePane),
        close: requestClose,
        save: { tab in
          Task { await tab.save() }
        },
        openToSide: { tab in openToSide(tab) },
        splitRight: { ensureSplit(.right) },
        splitBelow: { ensureSplit(.below) },
        closeSplit: splitOrientation == nil ? nil : { closeSplit() }
      )
    } content: {
      EditorWorkspacePanelContainer(
        isPanelVisible: bottomPanel != nil,
        preferredPanelHeight: $bottomPanelHeight
      ) {
        EditorDocumentSplitLayout(orientation: splitOrientation) {
          editorPane(.primary)
        } secondary: {
          editorPane(.secondary)
        }
      } panel: {
        EditorBottomPanelView(
          controller: controller,
          terminal: terminal,
          selection: $bottomPanel
        )
      }
    }
    .background(controller.profile.workbench.windowBackground.color)
    .onAppear {
      initializeWorkspaceState()
      consumeSideOpenRequestIfNeeded()
    }
    .clipShape(Rectangle())
    .onChange(of: tabIDs) { _, _ in
      reconcileTabs()
    }
    .onChange(of: sideOpenRequest?.id) { _, _ in
      consumeSideOpenRequestIfNeeded()
    }
    .onChange(of: controller.selectedTabID) { _, newValue in
      synchronizeSelectionFromController(newValue)
    }
    .onChange(of: layoutCommandEvent?.id) { _, _ in
      handle(layoutCommandEvent)
    }
  }

  private func handle(_ event: EditorLayoutCommandEvent?) {
    guard let event else { return }
    switch event.command {
    case .splitRight:
      ensureSplit(.right)
    case .splitBelow:
      ensureSplit(.below)
    case .closeSplit:
      closeSplit()
    }
  }

  private var tabIDs: [EditorTab.ID] {
    controller.tabs.map(\.id)
  }

  private func editorPane(_ pane: EditorPane) -> some View {
    EditorWorkspacePane(
      background: controller.profile.workbench.windowBackground.color
    ) {
      paneHeader(pane)
    } content: {
      paneContent(pane)
    }
  }

  @ViewBuilder
  private func paneHeader(_ pane: EditorPane) -> some View {
    if splitOrientation != nil {
      EditorSplitPaneHeader(
        tabs: controller.tabs,
        selectedID: selectionBinding(for: pane),
        isActive: activePane == pane,
        close: closeAction(for: pane),
        activate: {
          activate(pane)
        }
      )

      Divider()
    }
  }

  private func selectionBinding(for pane: EditorPane) -> Binding<EditorTab.ID?> {
    Binding(
      get: {
        selectedTabID(for: pane)
      },
      set: { newValue in
        guard let newValue else { return }
        setSelectedTab(newValue, in: pane)
      }
    )
  }

  private func closeAction(for pane: EditorPane) -> (() -> Void)? {
    guard pane == .secondary else { return nil }
    return {
      closeSplit()
    }
  }

  @ViewBuilder
  private func paneContent(_ pane: EditorPane) -> some View {
    if let tab = tab(for: pane) {
      editorView(for: tab, in: pane)
    } else {
      EditorEmptyState(phase: controller.phase)
    }
  }

  private func editorView(for tab: EditorTab, in pane: EditorPane) -> some View {
    EditorView(
      tab: tab,
      liveMarkdownStyling: usesLiveMarkdownEditor,
      showsMarkdownSyntax: showsMarkdownSyntax,
      wrapsMarkdownLines: wrapsMarkdownLines,
      profile: controller.profile,
      onVimHostRequest: { request in
        activate(pane)
        controller.handleVimHostRequest(request)
      },
      onGoToDefinition: {
        activate(pane)
        controller.goToDefinition()
      },
      onFindReferences: {
        activate(pane)
        controller.findReferences()
      },
      onShowQuickHelp: {
        activate(pane)
        controller.showQuickHelp()
      },
      onToggleInputMode: {
        activate(pane)
        controller.toggleEditorInputMode()
      },
      commandEvent: tabCommandEvent
    )
    .id("\(pane.rawValue)-\(tab.id.uuidString)")
  }

  private func initializeWorkspaceState() {
    if primaryTabID == nil {
      primaryTabID = controller.selectedTabID ?? controller.tabs.first?.id
    }

    restoreSplitIfPossible()
    reconcileTabs()
    consumeSideOpenRequestIfNeeded()
  }

  private func reconcileTabs() {
    let availableIDs = Set(controller.tabs.map(\.id))

    if let primaryTabID, !availableIDs.contains(primaryTabID) {
      self.primaryTabID = controller.selectedTabID ?? controller.tabs.first?.id
    }

    if let secondaryTabID, !availableIDs.contains(secondaryTabID) {
      self.secondaryTabID =
        controller.tabs.first(where: { $0.id != primaryTabID })?.id
        ?? self.primaryTabID
    }

    if controller.tabs.isEmpty {
      closeSplit()
      primaryTabID = nil
      return
    }

    if primaryTabID == nil {
      primaryTabID = controller.selectedTabID ?? controller.tabs.first?.id
    }

    restoreSplitIfPossible()
  }

  private func consumeSideOpenRequestIfNeeded() {
    guard let request = sideOpenRequest else { return }
    openSideRequest(request)
  }

  private func openSideRequest(_ request: EditorSideOpenRequest) {
    let standardizedURL = request.url.standardizedFileURL

    Task { @MainActor in
      if !controller.tabs.contains(where: {
        $0.url.standardizedFileURL == standardizedURL
      }) {
        await controller.openDocument(at: standardizedURL)
      }

      guard
        let tab = controller.tabs.first(where: {
          $0.url.standardizedFileURL == standardizedURL
        })
      else {
        sideOpenRequest = nil
        return
      }

      openToSide(tab, orientation: request.orientation)
      sideOpenRequest = nil
    }
  }

  private func tab(for pane: EditorPane) -> EditorTab? {
    guard let id = selectedTabID(for: pane) else { return nil }
    return controller.tabs.first(where: { $0.id == id })
  }

  private func selectedTabID(for pane: EditorPane) -> EditorTab.ID? {
    if splitOrientation == nil || pane == .primary {
      return primaryTabID ?? controller.selectedTabID
    }

    return secondaryTabID
  }

  private func setSelectedTab(_ id: EditorTab.ID, in pane: EditorPane) {
    guard controller.tabs.contains(where: { $0.id == id }) else { return }

    switch pane {
    case .primary:
      primaryTabID = id
    case .secondary:
      secondaryTabID = id
    }

    activePane = pane
    controller.selectedTabID = id
    persistSplit()
  }

  private func synchronizeSelectionFromController(_ id: EditorTab.ID?) {
    guard let id else { return }
    guard controller.tabs.contains(where: { $0.id == id }) else { return }

    if splitOrientation == nil {
      primaryTabID = id
      activePane = .primary
      return
    }

    if id == secondaryTabID {
      activePane = .secondary
    } else if id == primaryTabID {
      activePane = .primary
    } else {
      setSelectedTab(id, in: activePane)
    }
  }

  private func activate(_ pane: EditorPane) {
    activePane = pane

    guard let id = selectedTabID(for: pane) else { return }
    if controller.selectedTabID != id {
      controller.selectedTabID = id
    }
  }

  private func openToSide(
    _ tab: EditorTab,
    orientation: EditorSplitOrientation = .right
  ) {
    if splitOrientation == nil {
      ensureSplit(orientation)
    } else if splitOrientation != orientation {
      splitOrientation = orientation
    }

    secondaryTabID = tab.id
    activate(.secondary)
    persistSplit()
  }

  private func ensureSplit(_ orientation: EditorSplitOrientation) {
    if primaryTabID == nil {
      primaryTabID = controller.selectedTabID ?? controller.tabs.first?.id
    }

    splitOrientation = orientation

    if secondaryTabID == nil {
      secondaryTabID =
        controller.tabs.first(where: { $0.id != primaryTabID })?.id
        ?? primaryTabID
    }

    activePane = .secondary

    if let secondaryTabID {
      controller.selectedTabID = secondaryTabID
    }

    persistSplit()
  }

  private func closeSplit() {
    if activePane == .secondary, let primaryTabID {
      controller.selectedTabID = primaryTabID
    }

    splitOrientation = nil
    secondaryTabID = nil
    activePane = .primary
    EditorSplitLayoutStore.clear(workspaceURL: controller.workspaceURL)
  }

  private func persistSplit() {
    guard let splitOrientation else {
      EditorSplitLayoutStore.clear(workspaceURL: controller.workspaceURL)
      return
    }

    EditorSplitLayoutStore.save(
      orientation: splitOrientation,
      secondaryURL: tab(for: .secondary)?.url,
      workspaceURL: controller.workspaceURL
    )
  }

  private func restoreSplitIfPossible() {
    guard splitOrientation == nil else { return }
    guard let saved = EditorSplitLayoutStore.load(workspaceURL: controller.workspaceURL) else {
      return
    }

    splitOrientation = saved.orientation

    if let secondaryPath = saved.secondaryPath {
      secondaryTabID =
        controller.tabs.first(where: {
          $0.url.standardizedFileURL.path == secondaryPath
        })?.id
    }

    if secondaryTabID == nil {
      secondaryTabID =
        controller.tabs.first(where: { $0.id != primaryTabID })?.id
        ?? primaryTabID
    }
  }
}

private struct EditorWorkspaceScaffold<Tabs: View, Content: View>: View {
  let showsTabsBar: Bool
  private let tabs: Tabs
  private let content: Content

  init(
    showsTabsBar: Bool,
    @ViewBuilder tabs: () -> Tabs,
    @ViewBuilder content: () -> Content
  ) {
    self.showsTabsBar = showsTabsBar
    self.tabs = tabs()
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsTabsBar {
        tabs
        Divider()
      }
      content
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
  }
}

private struct EditorWorkspacePanelContainer<EditorContent: View, Panel: View>: View {
  let isPanelVisible: Bool
  @Binding var preferredPanelHeight: Double
  private let editorContent: EditorContent
  private let panel: Panel

  init(
    isPanelVisible: Bool,
    preferredPanelHeight: Binding<Double>,
    @ViewBuilder editorContent: () -> EditorContent,
    @ViewBuilder panel: () -> Panel
  ) {
    self.isPanelVisible = isPanelVisible
    _preferredPanelHeight = preferredPanelHeight
    self.editorContent = editorContent()
    self.panel = panel()
  }

  @ViewBuilder
  var body: some View {
    if isPanelVisible {
      EditorBottomPanelLayout(preferredPanelHeight: $preferredPanelHeight) {
        editorContent
      } panel: {
        panel
      }
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    } else {
      editorContent
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
  }
}

private struct EditorWorkspacePane<Header: View, Content: View>: View {
  let background: Color
  private let header: Header
  private let content: Content

  init(
    background: Color,
    @ViewBuilder header: () -> Header,
    @ViewBuilder content: () -> Content
  ) {
    self.background = background
    self.header = header()
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      content
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    .background(background)
  }
}

private struct EditorSplitPaneHeader: View {
  let tabs: [EditorTab]
  @Binding var selectedID: EditorTab.ID?
  let isActive: Bool
  let close: (() -> Void)?
  let activate: () -> Void

  var body: some View {
    HStack(spacing: 7) {
      activityIndicator
      tabMenu
      Spacer(minLength: 0)
      closeButton
    }
    .padding(.horizontal, 8)
    .frame(height: 24)
    .background(isActive ? Color.accentColor.opacity(0.045) : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture(perform: activate)
  }

  private var activityIndicator: some View {
    Circle()
      .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
      .frame(width: 5, height: 5)
  }

  private var tabMenu: some View {
    Menu {
      ForEach(tabs) { tab in
        Button {
          selectedID = tab.id
          activate()
        } label: {
          Label(
            tab.title,
            systemImage: selectedID == tab.id ? "checkmark" : "doc.text"
          )
        }
      }
    } label: {
      HStack(spacing: 5) {
        Text(selectedTabTitle)
          .lineLimit(1)

        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .semibold))
      }
      .font(.caption)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  @ViewBuilder
  private var closeButton: some View {
    if let close {
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
      }
      .buttonStyle(.plain)
      .help("Close split")
    }
  }

  private var selectedTabTitle: String {
    tabs.first(where: { $0.id == selectedID })?.title ?? "No File"
  }
}

struct EditorEmptyState: View {
  let phase: EditorWorkspacePhase

  @ViewBuilder
  var body: some View {
    switch phase {
    case .starting:
      EditorStartingStateView()
    case .failed(let message):
      EditorFailedStateView(message: message)
    case .idle, .ready:
      EditorNoFileStateView()
    }
  }
}

private struct EditorStartingStateView: View {
  var body: some View {
    VStack(spacing: 9) {
      ProgressView()
        .controlSize(.small)
      Text("Preparing editor")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
  }
}

private struct EditorFailedStateView: View {
  let message: String

  var body: some View {
    ContentUnavailableView(
      "Editor Failed",
      systemImage: "exclamationmark.triangle",
      description: Text(message)
    )
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
  }
}

private struct EditorNoFileStateView: View {
  var body: some View {
    ContentUnavailableView {
      Label("No File Open", systemImage: "doc.text")
    } description: {
      Text("Select a file.")
    }
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
  }
}

private enum EditorSplitLayoutStore {
  private struct Record: Codable {
    let orientation: EditorSplitOrientation
    let secondaryPath: String?
  }

  static func save(
    orientation: EditorSplitOrientation,
    secondaryURL: URL?,
    workspaceURL: URL
  ) {
    let record = Record(
      orientation: orientation,
      secondaryPath: secondaryURL?.standardizedFileURL.path
    )

    guard let data = try? JSONEncoder().encode(record) else { return }
    UserDefaults.standard.set(data, forKey: key(for: workspaceURL))
  }

  static func load(
    workspaceURL: URL
  ) -> (orientation: EditorSplitOrientation, secondaryPath: String?)? {
    guard let data = UserDefaults.standard.data(forKey: key(for: workspaceURL)) else {
      return nil
    }

    guard let record = try? JSONDecoder().decode(Record.self, from: data) else {
      return nil
    }

    return (record.orientation, record.secondaryPath)
  }

  static func clear(workspaceURL: URL) {
    UserDefaults.standard.removeObject(forKey: key(for: workspaceURL))
  }

  private static func key(for workspaceURL: URL) -> String {
    let path = workspaceURL.standardizedFileURL.path
    let encodedPath = Data(path.utf8).base64EncodedString()
    return "Calcite.editorSplit.\(encodedPath)"
  }
}
