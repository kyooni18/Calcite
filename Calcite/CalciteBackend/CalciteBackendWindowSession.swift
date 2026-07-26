import Combine
import Foundation

nonisolated enum CalciteFastPanelTarget: String, CaseIterable, Identifiable, Sendable {
  case fileTree
  case bottomView

  var id: String { rawValue }

  var title: String {
    switch self {
    case .fileTree: "File Tree"
    case .bottomView: "Bottom View"
    }
  }

  var systemImage: String {
    switch self {
    case .fileTree: "sidebar.left"
    case .bottomView: "rectangle.bottomhalf.inset.filled"
    }
  }
}

/// Window-scoped presentation and editor-instance state owned by a project backend.
///
/// Views read and mutate workspace state through this session and its `CalciteBackend`; state that
/// must remain independent between windows is kept here.
@MainActor
final class CalciteBackendWindowSession: ObservableObject, Identifiable {
  nonisolated enum DocumentCloseDecision: Equatable, Sendable {
    case save
    case discard
    case cancel
  }

  /// An editor-targeted command. Unlike a document-scoped command event, this remains unambiguous
  /// when the same document is displayed by more than one editor instance.
  nonisolated struct EditorCommandEvent: Equatable, Sendable {
    let id = UUID()
    let editorSessionID: UUID
    let documentID: UUID
    let command: EditorTabCommand
  }

  private enum SectionTabNavigationItem: Equatable {
    case document(editorTabID: UUID, documentID: UUID)
    case sectionTab(UUID)
  }

  #if os(macOS)
    private struct TerminalEditorSessionEntry {
      let command: String?
      let session: EditorTerminalSession
    }

    private var terminalEditorSessions: [String: TerminalEditorSessionEntry] = [:]
  #endif

  /// A single presentation of a document. Document contents remain owned by `EditorTab`; this
  /// object owns only editor-instance state such as selection, scrolling, and zoom.
  @MainActor
  final class EditorSession: ObservableObject, Identifiable {
    let id: UUID
    let documentID: UUID

    @Published private(set) var selectedRange: NSRange
    @Published private(set) var horizontalScrollOffset: Double
    @Published private(set) var verticalScrollOffset: Double
    @Published private(set) var zoomScale: Double

    private weak var windowSession: CalciteBackendWindowSession?

    var document: EditorTab? {
      windowSession?.backend?.document(id: documentID)
    }

    var isActive: Bool {
      windowSession?.activeEditorSessionID == id
    }

    fileprivate init(
      id: UUID = UUID(),
      documentID: UUID,
      selectedRange: NSRange,
      horizontalScrollOffset: Double = 0,
      verticalScrollOffset: Double = 0,
      zoomScale: Double = 1,
      windowSession: CalciteBackendWindowSession
    ) {
      self.id = id
      self.documentID = documentID
      self.selectedRange = selectedRange
      self.horizontalScrollOffset = max(0, horizontalScrollOffset)
      self.verticalScrollOffset = max(0, verticalScrollOffset)
      self.zoomScale = Self.clampedZoom(zoomScale)
      self.windowSession = windowSession
    }

    func updateSelection(_ range: NSRange) {
      guard let document else { return }
      let clamped = Self.clamped(range, utf16Length: document.text.utf16.count)
      guard selectedRange != clamped else { return }
      selectedRange = clamped
      if isActive {
        document.updateSelection(clamped)
      }
    }

    func updateScroll(horizontal: Double? = nil, vertical: Double? = nil) {
      if let horizontal, horizontal.isFinite {
        horizontalScrollOffset = max(0, horizontal)
      }
      if let vertical, vertical.isFinite {
        verticalScrollOffset = max(0, vertical)
      }
    }

    func updateZoom(_ scale: Double) {
      guard scale.isFinite else { return }
      zoomScale = Self.clampedZoom(scale)
    }

    func zoomIn() {
      updateZoom(zoomScale + 0.1)
    }

    func zoomOut() {
      updateZoom(zoomScale - 0.1)
    }

    func resetZoom() {
      updateZoom(1)
    }

    fileprivate func captureSelectionFromDocument() {
      guard let document else { return }
      selectedRange = Self.clamped(
        document.selectedRange,
        utf16Length: document.text.utf16.count
      )
    }

    fileprivate func applySelectionToDocument() {
      guard let document else { return }
      let clamped = Self.clamped(selectedRange, utf16Length: document.text.utf16.count)
      if selectedRange != clamped {
        selectedRange = clamped
      }
      if document.selectedRange != clamped {
        document.updateSelection(clamped)
      }
    }

    private static func clamped(_ range: NSRange, utf16Length: Int) -> NSRange {
      let location = min(max(0, range.location), utf16Length)
      let length = min(max(0, range.length), utf16Length - location)
      return NSRange(location: location, length: length)
    }

    private static func clampedZoom(_ value: Double) -> Double {
      min(max(value, 0.5), 2)
    }
  }

  let id = UUID()

  /// Weak by design: the project backend owns its active window sessions. Shared backends are
  /// retained by `CalciteBackend`'s project registry until successful project shutdown.
  private(set) weak var backend: CalciteBackend?

  // Window-level services coordinated by this backend session.
  let palette: CommandPaletteState
  let themeBuilderSession: ThemeBuilderSession
  let commandExecutor: EditorCommandExecutor
  let nowPlaying: NowPlayingController
  let sectionalLayout: MainSectionalLayoutController
  let layoutProfile: CalciteLayoutProfileService

  @Published private(set) var editorSessions: [EditorSession] = []
  @Published private(set) var activeEditorSessionID: UUID?
  @Published private(set) var editorCommandEvent: EditorCommandEvent?
  @Published private(set) var pendingDocumentOpenURLs: [URL] = []
  private var sectionalEditorAssignments: [UUID: UUID] = [:]

  @Published var selectedFileURL: URL?
  @Published private(set) var pendingDocumentClose: EditorTab?
  @Published private(set) var isClosed = false

  @Published var showsBuildProjectControl = true
  @Published var showsNowPlaying = true
  @Published var usesLiveMarkdownEditor = true
  @Published var showsSidebar: Bool {
    didSet {
      guard let backend else { return }
      EditorWorkspaceLayoutStore.saveSidebarVisibility(
        showsSidebar,
        for: backend.workspaceURL,
        defaults: defaults
      )
    }
  }

  @Published var showsMarkdownSyntax: Bool {
    didSet { defaults.set(showsMarkdownSyntax, forKey: PreferenceKey.markdownShowsSyntax) }
  }

  @Published var markdownWrapsLines: Bool {
    didSet { defaults.set(markdownWrapsLines, forKey: PreferenceKey.markdownWrapsLines) }
  }

  @Published var appearanceModeRaw: String {
    didSet { defaults.set(appearanceModeRaw, forKey: PreferenceKey.editorAppearanceMode) }
  }

  private let defaults: UserDefaults
  private let onOpenItem: () -> Void
  private let onRequestCloseWindow: () -> Void
  private var observations = Set<AnyCancellable>()
  private var isSynchronizingSelection = false

  var controller: EditorWorkspaceController? { backend?.controller }
  var terminal: EditorTerminalSession? { backend?.terminal }
  var fileVisibility: FileVisibilitySettings? { backend?.fileVisibility }
  var activeEditorSession: EditorSession? {
    guard let activeEditorSessionID else { return nil }
    return editorSessions.first { $0.id == activeEditorSessionID }
  }
  var selectedDocument: EditorTab? { activeEditorSession?.document ?? backend?.activeDocument }
  var activeDocument: EditorTab? { activeEditorSession?.document }

  var effectiveAppearanceMode: EditorInterfaceAppearance {
    controller?.profile.forcedInterfaceAppearance
      ?? EditorInterfaceAppearance(rawValue: appearanceModeRaw)
      ?? .system
  }

  var commandAvailability: EditorCommandAvailability {
    guard let controller else {
      return EditorCommandAvailability(
        hasDocument: false,
        hasUnsavedDocuments: false,
        canSave: false,
        canSaveAll: false,
        canBuild: false,
        canRun: false,
        canTest: false,
        canCheck: false,
        isBuilding: false,
        canStartDebug: false,
        debugIsActive: false,
        debugIsRunning: false,
        debugIsPaused: false
      )
    }

    let base = controller.commandAvailability
    let hasActiveDocument = activeEditorSession?.document != nil
    return EditorCommandAvailability(
      hasDocument: hasActiveDocument,
      hasUnsavedDocuments: base.hasUnsavedDocuments,
      canSave: hasActiveDocument
        || (sectionalLayout.activeSelectedKind == .themeBuilder && themeBuilderSession.isDirty),
      canSaveAll: base.hasUnsavedDocuments,
      canBuild: base.canBuild,
      canRun: base.canRun,
      canTest: base.canTest,
      canCheck: base.canCheck,
      isBuilding: base.isBuilding,
      canStartDebug: hasActiveDocument && base.canStartDebug,
      debugIsActive: base.debugIsActive,
      debugIsRunning: base.debugIsRunning,
      debugIsPaused: base.debugIsPaused
    )
  }

  init(
    backend: CalciteBackend,
    defaults: UserDefaults,
    onOpenItem: @escaping () -> Void,
    onRequestCloseWindow: @escaping () -> Void
  ) {
    self.backend = backend
    self.defaults = defaults
    self.onOpenItem = onOpenItem
    self.onRequestCloseWindow = onRequestCloseWindow

    let palette = CommandPaletteState()
    let themeBuilderSession = ThemeBuilderSession(controller: backend.controller)
    let initialSidebarVisibility = EditorWorkspaceLayoutStore.loadSidebarVisibility(
      for: backend.workspaceURL,
      defaults: defaults
    )
    let initialFastPanelTargets = Self.loadFastPanelTargets(
      for: backend.workspaceURL,
      defaults: defaults
    )
    let sectionalLayout = MainSectionalLayoutController(
      workspaceURL: backend.workspaceURL,
      defaults: defaults,
      includesPanelByDefault: false,
      includesSidebarByDefault: initialSidebarVisibility
    )

    self.palette = palette
    self.themeBuilderSession = themeBuilderSession
    self.nowPlaying = NowPlayingController()
    self.sectionalLayout = sectionalLayout
    self.layoutProfile = CalciteLayoutProfileService()
    self.showsSidebar = initialSidebarVisibility
    self.commandExecutor = EditorCommandExecutor(
      controller: backend.controller,
      terminal: backend.terminal,
      palette: palette,
      fileVisibility: backend.fileVisibility,
      themeBuilderSession: themeBuilderSession,
      onOpenItem: onOpenItem
    )
    self.showsMarkdownSyntax =
      defaults.object(
        forKey: PreferenceKey.markdownShowsSyntax
      ).map { _ in defaults.bool(forKey: PreferenceKey.markdownShowsSyntax) } ?? true
    self.markdownWrapsLines =
      defaults.object(
        forKey: PreferenceKey.markdownWrapsLines
      ).map { _ in defaults.bool(forKey: PreferenceKey.markdownWrapsLines) } ?? true
    self.appearanceModeRaw =
      defaults.string(forKey: PreferenceKey.editorAppearanceMode)
      ?? EditorInterfaceAppearance.system.rawValue

    self.commandExecutor.delegate = self
    migrateLegacyFastPanelTargets(initialFastPanelTargets)
    observeExistingWindowServices()
  }

  isolated deinit {
    nowPlaying.stop()
  }

  // MARK: - Lifecycle

  /// Starts the shared project services and then drains all document requests queued for this
  /// window. The initial document is queued first to ensure it is never opened twice.
  @discardableResult
  func start(
    initialFileURL: URL? = nil,
    shouldStartTerminal: Bool? = nil
  ) async -> WorkspaceLifecycleState {
    guard !isClosed, let backend else { return .stopped }
    markActive()
    if let initialFileURL {
      enqueueDocumentOpen(initialFileURL)
    }

    let state = await backend.start(
      shouldStartTerminal: shouldStartTerminal ?? false
    )
    guard state == .running else { return state }
    await drainPendingDocumentOpens()
    reconcileDocuments()
    return state
  }

  @discardableResult
  func close(saveChangesIfLastWindow: Bool = true) async -> Bool {
    guard !isClosed else { return true }
    guard let backend else {
      backendDidClose()
      return true
    }
    return await backend.closeWindowSession(
      self,
      saveChangesIfLastWindow: saveChangesIfLastWindow
    )
  }

  func markActive() {
    guard !isClosed, let backend else { return }
    backend.setActiveWindowSession(self)
  }

  func backendDidClose() {
    guard !isClosed else { return }
    isClosed = true
    nowPlaying.stop()
    observations.removeAll()
    editorSessions.removeAll()
    #if os(macOS)
      terminalEditorSessions.removeAll()
    #endif
    activeEditorSessionID = nil
    pendingDocumentOpenURLs.removeAll()
    pendingDocumentClose = nil
  }

  // MARK: - Documents and editor instances

  func enqueueDocumentOpen(_ url: URL) {
    let standardizedURL = url.standardizedFileURL
    guard
      !pendingDocumentOpenURLs.contains(where: {
        $0.standardizedFileURL == standardizedURL
      })
    else { return }
    pendingDocumentOpenURLs.append(standardizedURL)
  }

  @discardableResult
  func openDocument(
    at url: URL,
    inNewEditor: Bool = false
  ) async -> EditorSession? {
    guard !isClosed, let backend else { return nil }
    guard backend.lifecycleState == .running else {
      enqueueDocumentOpen(url)
      return nil
    }

    guard let document = await backend.openDocument(at: url) else { return nil }
    let editor: EditorSession
    if inNewEditor {
      editor = createEditorSession(for: document, activate: false)
    } else if let existing = editorSessions.first(where: { $0.documentID == document.id }) {
      editor = existing
    } else {
      editor = createEditorSession(for: document, activate: false)
    }
    activateEditorSession(editor.id)
    return editor
  }

  @discardableResult
  func createEditorSession(
    for document: EditorTab,
    activate: Bool = true
  ) -> EditorSession {
    let editor = EditorSession(
      documentID: document.id,
      selectedRange: document.selectedRange,
      windowSession: self
    )
    editorSessions.append(editor)
    if activate {
      activateEditorSession(editor.id)
    }
    return editor
  }

  @discardableResult
  func createAdditionalEditor(for documentID: UUID) -> EditorSession? {
    guard let document = backend?.document(id: documentID) else { return nil }
    return createEditorSession(for: document)
  }

  /// Returns a stable editor instance for a sectional editor leaf. Additional leaves reuse an
  /// unassigned editor for the active document or create a second editor instance when needed.
  @discardableResult
  func assignEditorSession(toSection sectionID: UUID) -> UUID? {
    if let assignedID = sectionalEditorAssignments[sectionID],
      editorSessions.contains(where: { $0.id == assignedID })
    {
      return assignedID
    }

    let assignedIDs = Set(sectionalEditorAssignments.values)
    let activeDocumentID = activeEditorSession?.documentID

    var candidate: EditorSession?
    if let activeEditorSession, !assignedIDs.contains(activeEditorSession.id) {
      candidate = activeEditorSession
    }
    if candidate == nil {
      candidate = editorSessions.first { editor in
        !assignedIDs.contains(editor.id) && editor.documentID == activeDocumentID
      }
    }
    if candidate == nil, let document = activeEditorSession?.document {
      candidate = createEditorSession(for: document, activate: false)
    }
    if candidate == nil {
      candidate = editorSessions.first { !assignedIDs.contains($0.id) }
    }
    if candidate == nil, let document = backend?.activeDocument {
      candidate = createEditorSession(for: document, activate: false)
    }

    guard let candidate else {
      sectionalEditorAssignments.removeValue(forKey: sectionID)
      return nil
    }

    sectionalEditorAssignments[sectionID] = candidate.id
    return candidate.id
  }

  func editorSessionAssigned(toSection sectionID: UUID) -> EditorSession? {
    guard let editorID = sectionalEditorAssignments[sectionID] else { return nil }
    return editorSessions.first { $0.id == editorID }
  }

  func documentIDAssigned(toSection sectionID: UUID) -> UUID? {
    editorSessionAssigned(toSection: sectionID)?.documentID
  }

  /// Selects a document only for the requested sectional editor tab. Other section assignments
  /// remain unchanged, even though the project-level document collection is shared.
  @discardableResult
  func selectDocument(_ documentID: UUID, inSection sectionID: UUID) -> UUID? {
    guard let backend, let document = backend.document(id: documentID) else { return nil }

    if let assigned = editorSessionAssigned(toSection: sectionID),
      assigned.documentID == documentID
    {
      activateEditorSession(assigned.id)
      return assigned.id
    }

    let otherAssignedEditorIDs = Set(
      sectionalEditorAssignments.compactMap { key, editorID in
        key == sectionID ? nil : editorID
      }
    )
    let editor =
      editorSessions.first { session in
        session.documentID == documentID && !otherAssignedEditorIDs.contains(session.id)
      }
      ?? createEditorSession(for: document, activate: false)

    sectionalEditorAssignments[sectionID] = editor.id
    activateEditorSession(editor.id)
    return editor.id
  }

  func updateEditorSessionAssignment(forSection sectionID: UUID, editorSessionID: UUID?) {
    guard let editorSessionID else {
      sectionalEditorAssignments.removeValue(forKey: sectionID)
      return
    }
    guard editorSessions.contains(where: { $0.id == editorSessionID }) else { return }
    sectionalEditorAssignments[sectionID] = editorSessionID
  }

  func reconcileSectionalEditorAssignments(validSectionIDs: Set<UUID>) {
    sectionalEditorAssignments = sectionalEditorAssignments.filter { sectionID, editorID in
      validSectionIDs.contains(sectionID)
        && editorSessions.contains(where: { $0.id == editorID })
    }
  }

  func activateEditorSession(_ id: UUID) {
    guard !isSynchronizingSelection,
      let editor = editorSessions.first(where: { $0.id == id }),
      editor.document != nil,
      let backend
    else { return }

    activeEditorSession?.captureSelectionFromDocument()
    isSynchronizingSelection = true
    activeEditorSessionID = editor.id
    if backend.controller.selectedTabID != editor.documentID {
      backend.controller.selectedTabID = editor.documentID
    }
    editor.applySelectionToDocument()
    backend.setActiveWindowSession(self)
    isSynchronizingSelection = false
  }

  /// Closes only one editor instance. The underlying document remains open until explicitly
  /// closed through `requestCloseDocument` / `resolvePendingDocumentClose`.
  func closeEditorSession(_ id: UUID) {
    guard let index = editorSessions.firstIndex(where: { $0.id == id }) else { return }
    let wasActive = activeEditorSessionID == id
    editorSessions[index].captureSelectionFromDocument()
    editorSessions.remove(at: index)

    guard wasActive else { return }
    let replacement =
      editorSessions.indices.contains(index)
      ? editorSessions[index]
      : editorSessions.last
    activeEditorSessionID = nil
    if let replacement {
      activateEditorSession(replacement.id)
    }
  }

  func reconcileDocuments() {
    guard !isClosed, let backend else { return }
    let availableIDs = Set(backend.documents.map(\.id))
    if editorSessions.contains(where: { !availableIDs.contains($0.documentID) }) {
      editorSessions.removeAll { !availableIDs.contains($0.documentID) }
    }

    for document in backend.documents
    where !editorSessions.contains(where: {
      $0.documentID == document.id
    }) {
      _ = createEditorSession(for: document, activate: false)
    }

    if let activeEditorSessionID,
      editorSessions.contains(where: { $0.id == activeEditorSessionID })
    {
      return
    }

    let selectedDocumentID = backend.activeDocumentID
    let replacement =
      selectedDocumentID.flatMap { id in
        editorSessions.first { $0.documentID == id }
      } ?? editorSessions.first

    activeEditorSessionID = nil
    if let replacement {
      if backend.activeWindowSession === self {
        activateEditorSession(replacement.id)
      } else {
        activeEditorSessionID = replacement.id
        replacement.captureSelectionFromDocument()
      }
    }
  }

  func synchronizeControllerSelection() {
    guard !isSynchronizingSelection, !isClosed, let backend, let activeEditorSession else {
      return
    }
    activeEditorSession.applySelectionToDocument()
    if backend.controller.selectedTabID != activeEditorSession.documentID {
      backend.controller.selectedTabID = activeEditorSession.documentID
    }
  }

  func synchronizeSelectedDocumentFromController(_ documentID: UUID?) {
    guard !isSynchronizingSelection, !isClosed, let documentID else { return }
    guard let editor = editorSessions.first(where: { $0.documentID == documentID }) else {
      reconcileDocuments()
      return
    }

    isSynchronizingSelection = true
    activeEditorSession?.captureSelectionFromDocument()
    activeEditorSessionID = editor.id
    editor.captureSelectionFromDocument()
    isSynchronizingSelection = false
  }

  private func drainPendingDocumentOpens() async {
    while !pendingDocumentOpenURLs.isEmpty {
      let url = pendingDocumentOpenURLs.removeFirst()
      _ = await openDocument(at: url)
    }
  }

  // MARK: - Document and utility close workflows

  func requestCloseDocument(_ document: EditorTab) {
    guard backend?.document(id: document.id) != nil else { return }
    if document.isDirty {
      pendingDocumentClose = document
    } else {
      backend?.closeDocument(document)
    }
  }

  @discardableResult
  func resolvePendingDocumentClose(_ decision: DocumentCloseDecision) async -> Bool {
    guard let document = pendingDocumentClose else { return true }
    switch decision {
    case .cancel:
      pendingDocumentClose = nil
      return false
    case .save:
      guard await document.save() else { return false }
      pendingDocumentClose = nil
      backend?.closeDocument(document)
      return true
    case .discard:
      pendingDocumentClose = nil
      backend?.closeDocument(document)
      return true
    }
  }

  // MARK: - Commands

  func perform(_ command: EditorCommand) {
    guard !isClosed else { return }
    markActive()

    switch command {
    case .find:
      publishEditorCommand(.find)
    case .replace:
      publishEditorCommand(.replace)
    case .zoomIn:
      activeEditorSession?.zoomIn()
      publishEditorCommand(.zoomIn)
    case .zoomOut:
      activeEditorSession?.zoomOut()
      publishEditorCommand(.zoomOut)
    case .resetZoom:
      activeEditorSession?.resetZoom()
      publishEditorCommand(.resetZoom)
    default:
      synchronizeControllerSelection()
    }

    commandExecutor.perform(command)
  }

  func sendLayoutCommand(_ command: EditorLayoutCommand) {
    guard !isClosed else { return }
    markActive()
    synchronizeControllerSelection()
    switch command {
    case .splitRight:
      sectionalLayout.splitActiveSection(axis: .horizontal)
    case .splitBelow:
      sectionalLayout.splitActiveSection(axis: .vertical)
    case .closeSplit:
      sectionalLayout.closeActiveSection()
    }
  }

  private func publishEditorCommand(_ command: EditorTabCommand) {
    guard let editor = activeEditorSession else { return }
    synchronizeControllerSelection()
    editorCommandEvent = EditorCommandEvent(
      editorSessionID: editor.id,
      documentID: editor.documentID,
      command: command
    )
  }

  func activateSection(_ sectionID: UUID) {
    sectionalLayout.activateSection(sectionID)
    guard let section = sectionalLayout.root.sectionNode(id: sectionID),
      let selectedTab = section.selectedVisibleTab
    else { return }
    if selectedTab.kind == .editor || selectedTab.kind == .workspace,
      let editorSessionID = assignEditorSession(toSection: selectedTab.id)
    {
      activateEditorSession(editorSessionID)
    }
  }

  func navigateSection(forward: Bool) {
    guard let sectionID = sectionalLayout.navigateSection(forward: forward) else { return }
    activateSection(sectionID)
  }

  #if os(macOS)
    /// Starts terminal editor processes for every open document so changing a
    /// Vim/Neovim tab or section does not wait for the editor to launch.
    func preloadTerminalEditors(interface: EditorInterface) {
      guard interface.usesTerminalEditor, let backend else { return }
      let openPaths = Set(backend.documents.map { $0.url.standardizedFileURL.path })
      let staleKeys = terminalEditorSessions.keys.filter { key in
        !openPaths.contains(where: { key.hasSuffix("|\($0)") })
      }
      for key in staleKeys {
        terminalEditorSessions.removeValue(forKey: key)?.session.stop()
      }
      for document in backend.documents {
        _ = terminalEditorSession(interface: interface, fileURL: document.url)
      }
    }

    func terminalEditorSession(
      interface: EditorInterface,
      fileURL: URL
    ) -> EditorTerminalSession {
      let command = EditorInterfacePreferences.launchCommand(
        interface: interface,
        fileURL: fileURL,
        workspaceURL: backend?.workspaceURL ?? fileURL.deletingLastPathComponent()
      )
      let key = "\(interface.rawValue)|\(fileURL.standardizedFileURL.path)"
      if let existing = terminalEditorSessions[key], existing.command == command {
        if existing.command != nil { existing.session.startIfNeeded() }
        return existing.session
      }

      terminalEditorSessions[key]?.session.stop()
      let session = EditorTerminalSession(
        workspaceURL: backend?.workspaceURL ?? fileURL.deletingLastPathComponent(),
        initialCommand: command,
        monitorsPythonEnvironment: false
      )
      terminalEditorSessions[key] = TerminalEditorSessionEntry(command: command, session: session)
      if command != nil { session.startIfNeeded() }
      return session
    }
  #endif

  func navigateTab(forward: Bool) {
    guard let backend, let context = tabNavigationContext() else { return }
    let (sectionID, section, primaryEditorTabID, items) = context

    let currentItem: SectionTabNavigationItem?
    if let selectedTab = section.selectedVisibleTab,
      selectedTab.id == primaryEditorTabID,
      let documentID = documentIDAssigned(toSection: selectedTab.id) ?? backend.activeDocumentID
    {
      currentItem = .document(editorTabID: selectedTab.id, documentID: documentID)
    } else {
      currentItem = section.selectedVisibleTab.map { .sectionTab($0.id) }
    }

    let currentIndex =
      currentItem.flatMap { items.firstIndex(of: $0) }
      ?? (forward ? -1 : 0)
    let nextIndex =
      forward
      ? (currentIndex + 1) % items.count
      : (currentIndex - 1 + items.count) % items.count
    selectTabNavigationItem(items[nextIndex], in: sectionID)
  }

  /// Selects a visible tab by its one-based position, matching Command-Number
  /// and Vim leader-number conventions.
  func selectTab(number: Int) {
    guard let context = tabNavigationContext(), context.items.indices.contains(number - 1) else {
      return
    }
    selectTabNavigationItem(context.items[number - 1], in: context.sectionID)
  }

  private func tabNavigationContext() -> (
    sectionID: UUID,
    section: MainSectionLayoutNode,
    primaryEditorTabID: UUID?,
    items: [SectionTabNavigationItem]
  )? {
    guard let backend else { return nil }
    let sectionID = sectionalLayout.activeSectionID ?? sectionalLayout.root.visibleSectionIDs.first
    guard let sectionID, let section = sectionalLayout.root.sectionNode(id: sectionID) else { return nil }
    let primaryEditorTabID = section.visibleTabs.first {
      $0.kind == .editor || $0.kind == .workspace
    }?.id
    let items = section.visibleTabs.flatMap { tab -> [SectionTabNavigationItem] in
      if tab.id == primaryEditorTabID,
        (tab.kind == .editor || tab.kind == .workspace),
        !backend.documents.isEmpty
      {
        return backend.documents.map { .document(editorTabID: tab.id, documentID: $0.id) }
      }
      return [.sectionTab(tab.id)]
    }
    return items.isEmpty ? nil : (sectionID, section, primaryEditorTabID, items)
  }

  private func selectTabNavigationItem(_ item: SectionTabNavigationItem, in sectionID: UUID) {
    sectionalLayout.activateSection(sectionID)
    switch item {
    case .document(let editorTabID, let documentID):
      sectionalLayout.selectTab(sectionID: sectionID, tabID: editorTabID)
      _ = selectDocument(documentID, inSection: editorTabID)
    case .sectionTab(let tabID):
      sectionalLayout.selectTab(sectionID: sectionID, tabID: tabID)
      activateSection(sectionID)
    }
  }

  func receiveVimSplit(horizontal: Bool) {
    sendLayoutCommand(horizontal ? .splitBelow : .splitRight)
  }

  func requestWindowClose() {
    onRequestCloseWindow()
  }

  func requestOpenItem() {
    onOpenItem()
  }

  // MARK: - Palette, panels, and utility services

  func showUnifiedPalette() {
    palette.present(mode: .all)
  }

  func sendPaletteKeyboardCommand(_ command: CalciteCommandPaletteSurface.KeyboardCommand) {
    palette.send(command)
  }

  func closeCommandPalette() {
    palette.dismiss()
  }

  func setFastPanelTarget(_ target: CalciteFastPanelTarget, enabled: Bool) {
    let sectionIDs = fastPanelSectionIDs(for: target, createIfNeeded: enabled)
    for sectionID in sectionIDs {
      sectionalLayout.setFastPanel(enabled, for: sectionID)
    }
  }

  func toggleFastPanel() {
    sectionalLayout.toggleFastPanels()
  }

  func toggleBottomPanel() {
    sectionalLayout.toggleBottomPanel()
  }

  func toggleLayoutCustomization() {
    sectionalLayout.isCustomizing.toggle()
  }

  func startNowPlaying() {
    nowPlaying.start()
  }

  func stopNowPlaying() {
    nowPlaying.stop()
  }

  func refreshNowPlaying() {
    nowPlaying.refresh()
  }

  func toggleNowPlayingPlayback() {
    nowPlaying.togglePlayback()
  }

  func playPreviousTrack() {
    nowPlaying.previousTrack()
  }

  func playNextTrack() {
    nowPlaying.nextTrack()
  }

  // MARK: - Observation and persistence

  private func observeExistingWindowServices() {
    forwardChanges(from: palette)
    forwardChanges(from: themeBuilderSession)
    forwardChanges(from: commandExecutor)
    forwardChanges(from: nowPlaying)
    forwardChanges(from: sectionalLayout)

    if let controller = backend?.controller {
      controller.$profile
        .sink { [weak self] _ in self?.themeBuilderSession.noteProfileChanged() }
        .store(in: &observations)
      controller.$activeThemeSlot
        .sink { [weak self] _ in self?.themeBuilderSession.noteProfileChanged() }
        .store(in: &observations)
      controller.$usesWorkspaceThemeOverrides
        .sink { [weak self] _ in self?.themeBuilderSession.noteProfileChanged() }
        .store(in: &observations)
    }
  }

  private func forwardChanges<Object: ObservableObject>(from object: Object)
  where Object.ObjectWillChangePublisher == ObservableObjectPublisher {
    object.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &observations)
  }

  private func fastPanelSectionIDs(
    for target: CalciteFastPanelTarget,
    createIfNeeded: Bool
  ) -> [UUID] {
    switch target {
    case .fileTree:
      return sectionalLayout.root.sectionIDs(kind: .sidebar)
    case .bottomView:
      var sectionIDs = sectionalLayout.root.sectionNodes.compactMap { section in
        section.tabs.contains(where: { $0.kind.isBottomPanelKind }) ? section.id : nil
      }
      if sectionIDs.isEmpty, createIfNeeded {
        sectionalLayout.presentTab(.terminal)
        sectionIDs = sectionalLayout.root.sectionNodes.compactMap { section in
          section.tabs.contains(where: { $0.kind.isBottomPanelKind }) ? section.id : nil
        }
      }
      return sectionIDs
    }
  }

  private func migrateLegacyFastPanelTargets(_ targets: Set<CalciteFastPanelTarget>) {
    guard sectionalLayout.fastPanelSectionIDs.isEmpty else { return }
    for target in targets {
      setFastPanelTarget(target, enabled: true)
    }
  }

  private func setSidebarVisible(_ isVisible: Bool) {
    guard showsSidebar != isVisible || sectionalLayout.containsVisible(.sidebar) != isVisible else {
      return
    }
    showsSidebar = isVisible
    sectionalLayout.setSidebarVisible(isVisible)
  }

  private static func fastPanelTargetsKey(for workspaceURL: URL) -> String {
    let path = workspaceURL.standardizedFileURL.path
    let encodedPath = Data(path.utf8).base64EncodedString()
    return "Calcite.fastPanelTargets.\(encodedPath)"
  }

  private static func legacyFastPanelTargetKey(for workspaceURL: URL) -> String {
    let path = workspaceURL.standardizedFileURL.path
    let encodedPath = Data(path.utf8).base64EncodedString()
    return "Calcite.fastPanelTarget.\(encodedPath)"
  }

  private static func loadFastPanelTargets(
    for workspaceURL: URL,
    defaults: UserDefaults
  ) -> Set<CalciteFastPanelTarget> {
    let storedTargets = defaults.stringArray(forKey: fastPanelTargetsKey(for: workspaceURL)) ?? []
    let decodedTargets = Set(storedTargets.compactMap(CalciteFastPanelTarget.init(rawValue:)))
    if !decodedTargets.isEmpty { return decodedTargets }

    if let legacyTarget = defaults.string(forKey: legacyFastPanelTargetKey(for: workspaceURL))
      .flatMap(CalciteFastPanelTarget.init(rawValue:))
    {
      return [legacyTarget]
    }
    return [.fileTree, .bottomView]
  }

  private enum PreferenceKey {
    static let markdownShowsSyntax = "markdownShowsSyntax"
    static let markdownWrapsLines = "markdownWrapsLines"
    static let editorAppearanceMode = "editorAppearanceMode"
  }
}

extension CalciteBackendWindowSession: EditorCommandExecutorDelegate {
  var commandSelectedDocumentID: UUID? {
    activeEditorSession?.documentID ?? backend?.activeDocumentID
  }

  var commandSelectedSectionKind: MainSectionKind? {
    sectionalLayout.activeSelectedKind
  }

  func commandSelectDocument(_ id: UUID) {
    guard let backend, let document = backend.document(id: id) else { return }
    let editor =
      editorSessions.first { $0.documentID == id }
      ?? createEditorSession(for: document, activate: false)
    activateEditorSession(editor.id)
  }

  func commandPresentSection(_ kind: MainSectionKind) {
    sectionalLayout.presentTab(kind)
    if kind == .terminal, backend?.lifecycleState == .running {
      backend?.terminal.startIfNeeded()
    }
  }

  func commandToggleSidebar() {
    setSidebarVisible(!showsSidebar)
  }

  func commandToggleFastPanel() {
    toggleFastPanel()
  }

  func commandToggleBottomPanel() {
    toggleBottomPanel()
  }

  func commandToggleLayoutCustomization() {
    toggleLayoutCustomization()
  }

  func commandNavigateTab(forward: Bool) {
    navigateTab(forward: forward)
  }

  func commandSelectTab(number: Int) {
    selectTab(number: number)
  }

  func commandNavigateSection(forward: Bool) {
    navigateSection(forward: forward)
  }

  func commandNavigateSection(direction: MainSectionDirection) {
    guard let sectionID = sectionalLayout.navigateSection(direction: direction) else { return }
    activateSection(sectionID)
  }
}
