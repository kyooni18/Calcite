import Combine
@_spi(Calcite) import EditorVim
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

  private struct VimWindowLocation: Equatable {
    let sectionID: UUID
    let editorTabID: UUID
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
    @Published private(set) var documentID: UUID

    @Published private(set) var selectedRange: NSRange
    @Published private(set) var horizontalScrollOffset: Double
    @Published private(set) var verticalScrollOffset: Double
    @Published private(set) var zoomScale: Double

    private struct DocumentPresentationState {
      var selectedRange: NSRange
      var horizontalScrollOffset: Double
      var verticalScrollOffset: Double
      var zoomScale: Double
    }

    private var documentPresentationStates: [UUID: DocumentPresentationState] = [:]
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
      persistCurrentPresentation()
    }

    fileprivate func switchDocument(to document: EditorTab) {
      guard documentID != document.id else { return }
      persistCurrentPresentation()
      documentID = document.id

      if let stored = documentPresentationStates[document.id] {
        selectedRange = Self.clamped(
          stored.selectedRange,
          utf16Length: document.text.utf16.count
        )
        horizontalScrollOffset = max(0, stored.horizontalScrollOffset)
        verticalScrollOffset = max(0, stored.verticalScrollOffset)
        zoomScale = Self.clampedZoom(stored.zoomScale)
      } else {
        selectedRange = Self.clamped(
          document.selectedRange,
          utf16Length: document.text.utf16.count
        )
        horizontalScrollOffset = 0
        verticalScrollOffset = 0
        zoomScale = 1
      }
      persistCurrentPresentation()
    }

    func selection(for document: EditorTab) -> NSRange {
      if documentID == document.id {
        return Self.clamped(selectedRange, utf16Length: document.text.utf16.count)
      }
      if let stored = documentPresentationStates[document.id] {
        return Self.clamped(stored.selectedRange, utf16Length: document.text.utf16.count)
      }
      return Self.clamped(document.selectedRange, utf16Length: document.text.utf16.count)
    }

    func updateSelection(_ range: NSRange) {
      guard let document else { return }
      updateSelection(range, for: document)
    }

    func updateSelection(_ range: NSRange, for document: EditorTab) {
      let clamped = Self.clamped(range, utf16Length: document.text.utf16.count)
      if documentID == document.id {
        if selectedRange != clamped {
          selectedRange = clamped
        }
        persistCurrentPresentation()
        if isActive, document.selectedRange != clamped {
          document.updateSelection(clamped)
        }
        return
      }

      var state =
        documentPresentationStates[document.id]
        ?? DocumentPresentationState(
          selectedRange: clamped,
          horizontalScrollOffset: 0,
          verticalScrollOffset: 0,
          zoomScale: 1
        )
      state.selectedRange = clamped
      documentPresentationStates[document.id] = state
    }

    func updateScroll(horizontal: Double? = nil, vertical: Double? = nil) {
      var changed = false
      if let horizontal, horizontal.isFinite {
        let value = max(0, horizontal)
        if abs(horizontalScrollOffset - value) > 0.5 {
          horizontalScrollOffset = value
          changed = true
        }
      }
      if let vertical, vertical.isFinite {
        let value = max(0, vertical)
        if abs(verticalScrollOffset - value) > 0.5 {
          verticalScrollOffset = value
          changed = true
        }
      }
      if changed { persistCurrentPresentation() }
    }

    func updateZoom(_ scale: Double) {
      guard scale.isFinite else { return }
      let value = Self.clampedZoom(scale)
      guard abs(zoomScale - value) > 0.0001 else { return }
      zoomScale = value
      persistCurrentPresentation()
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
      persistCurrentPresentation()
    }

    /// Updates this editor instance's window-local selection without writing it
    /// through to the shared document. This is used during a document handoff,
    /// before the target editor becomes authoritative for the document again.
    fileprivate func restoreSelection(_ range: NSRange) {
      guard let document else { return }
      selectedRange = Self.clamped(range, utf16Length: document.text.utf16.count)
      persistCurrentPresentation()
    }

    fileprivate func retainPresentationStates(for documentIDs: Set<UUID>) {
      documentPresentationStates = documentPresentationStates.filter { state in
        documentIDs.contains(state.key)
      }
      if documentIDs.contains(documentID) {
        persistCurrentPresentation()
      }
    }

    fileprivate func runtimePresentationSnapshot(
      vimRuntime: VimViewRuntimeSnapshot?
    ) -> WorkspaceEditorPresentationSnapshot {
      persistCurrentPresentation()
      return WorkspaceEditorPresentationSnapshot(
        editorSessionID: id,
        documentID: documentID,
        selectedRange: WorkspaceTextRangeSnapshot(selectedRange),
        horizontalScrollOffset: horizontalScrollOffset,
        verticalScrollOffset: verticalScrollOffset,
        zoomScale: zoomScale,
        vimRuntime: vimRuntime,
        documentPresentations: documentPresentationStates.map { documentID, state in
          WorkspaceDocumentPresentationSnapshot(
            documentID: documentID,
            selectedRange: WorkspaceTextRangeSnapshot(state.selectedRange),
            horizontalScrollOffset: state.horizontalScrollOffset,
            verticalScrollOffset: state.verticalScrollOffset,
            zoomScale: state.zoomScale
          )
        }.sorted { lhs, rhs in
          lhs.documentID.uuidString < rhs.documentID.uuidString
        }
      )
    }

    fileprivate func restoreDocumentPresentations(
      _ values: [WorkspaceDocumentPresentationSnapshot]
    ) {
      guard let backend = windowSession?.backend else { return }
      for value in values {
        guard let document = backend.document(id: value.documentID) else { continue }
        documentPresentationStates[value.documentID] = DocumentPresentationState(
          selectedRange: Self.clamped(
            value.selectedRange.nsRange,
            utf16Length: document.text.utf16.count
          ),
          horizontalScrollOffset: max(0, value.horizontalScrollOffset),
          verticalScrollOffset: max(0, value.verticalScrollOffset),
          zoomScale: Self.clampedZoom(value.zoomScale)
        )
      }
      if let current = documentPresentationStates[documentID] {
        selectedRange = current.selectedRange
        horizontalScrollOffset = current.horizontalScrollOffset
        verticalScrollOffset = current.verticalScrollOffset
        zoomScale = current.zoomScale
      }
      persistCurrentPresentation()
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
      persistCurrentPresentation()
    }

    private func persistCurrentPresentation() {
      documentPresentationStates[documentID] = DocumentPresentationState(
        selectedRange: selectedRange,
        horizontalScrollOffset: horizontalScrollOffset,
        verticalScrollOffset: verticalScrollOffset,
        zoomScale: zoomScale
      )
    }

    fileprivate static func clamped(_ range: NSRange, utf16Length: Int) -> NSRange {
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
  let vimSessionCoordinator: VimSessionCoordinator
  private let vimStateStore: CalciteVimStateStore

  @Published private(set) var editorSessions: [EditorSession] = []
  @Published private(set) var activeEditorSessionID: UUID?
  private var previousActiveEditorSessionID: UUID?
  @Published private(set) var editorCommandEvent: EditorCommandEvent?
  @Published private(set) var pendingDocumentOpenURLs: [URL] = []
  private var sectionalEditorAssignments: [UUID: UUID] = [:]
  private struct PendingVimRuntimeSnapshot {
    var documentID: UUID
    var snapshot: VimViewRuntimeSnapshot
  }
  private var pendingVimRuntimeSnapshots: [UUID: PendingVimRuntimeSnapshot] = [:]

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
  private var lastPersistedVimHistory = VimHistorySnapshot()

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
        canRunCurrentFile: false,
        canTest: false,
        canCheck: false,
        isBuilding: false,
        canStartDebug: false,
        canDebugCurrentFile: false,
        debugIsActive: false,
        debugIsRunning: false,
        debugIsPaused: false,
        liveDebugIsEnabled: false
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
      canRunCurrentFile: hasActiveDocument && base.canRunCurrentFile,
      canTest: base.canTest,
      canCheck: base.canCheck,
      isBuilding: base.isBuilding,
      canStartDebug: hasActiveDocument && base.canStartDebug,
      canDebugCurrentFile: hasActiveDocument && base.canDebugCurrentFile,
      debugIsActive: base.debugIsActive,
      debugIsRunning: base.debugIsRunning,
      debugIsPaused: base.debugIsPaused,
      liveDebugIsEnabled: base.liveDebugIsEnabled
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

    let vimStateStore = CalciteVimStateStore(workspaceURL: backend.workspaceURL)
    let persistedVimHistory = vimStateStore.loadHistory()
    let vimSessionCoordinator = VimSessionCoordinator()
    vimSessionCoordinator.mergeHistory(persistedVimHistory)
    self.vimStateStore = vimStateStore
    self.vimSessionCoordinator = vimSessionCoordinator
    self.lastPersistedVimHistory = persistedVimHistory

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
    // The sectional layout file is authoritative once it exists. The legacy workspace setting is
    // used only to seed a brand-new layout, never to overwrite a restored tree on first appear.
    self.showsSidebar = sectionalLayout.containsVisible(.sidebar)
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

  func persistVimHistory(_ history: VimHistorySnapshot) {
    vimSessionCoordinator.mergeHistory(history)
    let merged = vimSessionCoordinator.historySnapshot
    guard merged != lastPersistedVimHistory else { return }
    lastPersistedVimHistory = merged
    vimStateStore.saveHistory(merged)
  }

  func vimController(
    for editor: EditorSession,
    displaying document: EditorTab,
    profile: EditorCustomProfile,
    attachment: VimControllerAttachment
  ) -> VimKeymapController {
    let windowID = VimWindowID(editor.id)
    let bufferID = VimBufferID(document.id)
    let controller = vimSessionCoordinator.controller(
      for: windowID,
      displaying: bufferID,
      text: document.text,
      cursor: editor.selection(for: document).location,
      name: document.url.path,
      leader: profile.vim.normalizedLeader,
      localLeader: profile.vim.normalizedLeader,
      tabWidth: profile.behavior.tabWidth,
      attachment: attachment
    )

    if let pending = pendingVimRuntimeSnapshots[editor.id],
      pending.documentID == document.id,
      vimSessionCoordinator.restoreRuntimeSnapshot(
        pending.snapshot,
        for: windowID,
        displaying: bufferID
      )
    {
      // Do not publish EditorSession changes while SwiftUI is evaluating the
      // editor body. The surface projects the restored engine state after it
      // attaches to this controller.
      pendingVimRuntimeSnapshots.removeValue(forKey: editor.id)
    }
    return controller
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
    for editor in editorSessions {
      vimSessionCoordinator.removeWindow(VimWindowID(editor.id))
    }
    editorSessions.removeAll()
    sectionalEditorAssignments.removeAll()
    pendingVimRuntimeSnapshots.removeAll()
    #if os(macOS)
      terminalEditorSessions.removeAll()
    #endif
    activeEditorSessionID = nil
    pendingDocumentOpenURLs.removeAll()
    pendingDocumentClose = nil
  }

  // MARK: - Documents and editor instances

  func captureRuntimePresentationSnapshot() -> WorkspaceWindowPresentationSnapshot {
    for editor in editorSessions {
      captureAuthoritativeSelection(for: editor)
    }
    return WorkspaceWindowPresentationSnapshot(
      windowSessionID: id,
      activeEditorSessionID: activeEditorSessionID,
      activeSectionID: sectionalLayout.activeSectionID,
      editors: editorSessions.map { editor in
        let vimRuntime =
          vimSessionCoordinator.runtimeSnapshot(
            for: VimWindowID(editor.id),
            displaying: VimBufferID(editor.documentID)
          )
          ?? pendingVimRuntimeSnapshots[editor.id].flatMap { pending in
            pending.documentID == editor.documentID ? pending.snapshot : nil
          }
        return editor.runtimePresentationSnapshot(vimRuntime: vimRuntime)
      },
      sectionAssignments: sectionalEditorAssignments.map { sectionID, editorSessionID in
        WorkspaceSectionEditorAssignmentSnapshot(
          sectionID: sectionID,
          editorSessionID: editorSessionID
        )
      }.sorted { lhs, rhs in
        lhs.sectionID.uuidString < rhs.sectionID.uuidString
      }
    )
  }

  func restoreRuntimePresentationSnapshot(_ snapshot: WorkspaceWindowPresentationSnapshot) {
    guard !isClosed, let backend else { return }

    for editor in editorSessions {
      vimSessionCoordinator.removeWindow(VimWindowID(editor.id))
    }
    editorSessions.removeAll(keepingCapacity: true)
    sectionalEditorAssignments.removeAll(keepingCapacity: true)
    pendingVimRuntimeSnapshots.removeAll(keepingCapacity: true)
    activeEditorSessionID = nil
    previousActiveEditorSessionID = nil

    var restoredEditorIDs: Set<UUID> = []
    for value in snapshot.editors {
      guard restoredEditorIDs.insert(value.editorSessionID).inserted,
        let document = backend.document(id: value.documentID)
      else { continue }
      let editor = EditorSession(
        id: value.editorSessionID,
        documentID: document.id,
        selectedRange: value.selectedRange.nsRange,
        horizontalScrollOffset: value.horizontalScrollOffset,
        verticalScrollOffset: value.verticalScrollOffset,
        zoomScale: value.zoomScale,
        windowSession: self
      )
      editor.restoreDocumentPresentations(value.documentPresentations)
      editorSessions.append(editor)
      if let vimRuntime = value.vimRuntime {
        pendingVimRuntimeSnapshots[editor.id] = PendingVimRuntimeSnapshot(
          documentID: document.id,
          snapshot: vimRuntime
        )
      }
    }

    let availableEditorIDs = Set(editorSessions.map(\.id))
    for value in snapshot.sectionAssignments
    where availableEditorIDs.contains(value.editorSessionID) {
      sectionalEditorAssignments[value.sectionID] = value.editorSessionID
    }

    if let activeSectionID = snapshot.activeSectionID {
      sectionalLayout.activateSection(activeSectionID)
    }

    let restoredActiveID =
      snapshot.activeEditorSessionID.flatMap { candidate in
        availableEditorIDs.contains(candidate) ? candidate : nil
      } ?? editorSessions.first?.id

    if let restoredActiveID {
      if backend.activeWindowSession === self {
        activateEditorSession(restoredActiveID)
      } else {
        activeEditorSessionID = restoredActiveID
        editorSessions.first(where: { $0.id == restoredActiveID })?.applySelectionToDocument()
      }
    }
  }

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
    if inNewEditor || activeEditorSession == nil {
      editor = createEditorSession(for: document, activate: false)
    } else {
      editor = activeEditorSession!
      switchDocument(in: editor, to: document)
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

  @discardableResult
  func switchEditorSession(_ editorSessionID: UUID, to documentID: UUID) -> Bool {
    guard let backend, let document = backend.document(id: documentID),
      let editor = editorSessions.first(where: { $0.id == editorSessionID })
    else { return false }
    switchDocument(in: editor, to: document)
    if activeEditorSessionID == editorSessionID { activateEditorSession(editorSessionID) }
    return true
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

    if let assigned = editorSessionAssigned(toSection: sectionID) {
      switchDocument(in: assigned, to: document)
      activateEditorSession(assigned.id)
      return assigned.id
    }

    let editor = createEditorSession(for: document, activate: false)
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

    // A same-editor tab switch has already persisted the outgoing document.
    // Reading from `activeEditorSession.document` here would read the *new*
    // document and overwrite the state restored by `switchDocument(in:to:)`.
    if let outgoing = activeEditorSession, outgoing.id != editor.id {
      captureAuthoritativeSelection(for: outgoing)
    }

    isSynchronizingSelection = true
    if let activeEditorSessionID, activeEditorSessionID != editor.id {
      previousActiveEditorSessionID = activeEditorSessionID
    }
    activeEditorSessionID = editor.id
    restoreSelectionFromVimIfAvailable(for: editor)
    if backend.controller.selectedTabID != editor.documentID {
      backend.controller.selectedTabID = editor.documentID
    }
    editor.applySelectionToDocument()
    backend.setActiveWindowSession(self)
    isSynchronizingSelection = false
  }

  /// Performs a document handoff without allowing shared `EditorTab.selectedRange`
  /// to overwrite the window-local Vim state. Both the outgoing and incoming
  /// selections are refreshed directly from their cached `(window, buffer)`
  /// controllers when Calcite Vim is active.
  private func switchDocument(in editor: EditorSession, to document: EditorTab) {
    guard editor.documentID != document.id else {
      restoreSelectionFromVimIfAvailable(for: editor)
      return
    }

    captureAuthoritativeSelection(for: editor)
    editor.switchDocument(to: document)
    _ = vimSessionCoordinator.switchBuffer(
      in: VimWindowID(editor.id),
      to: VimBufferID(document.id)
    )
    restoreSelectionFromVimIfAvailable(for: editor)
  }

  private func captureAuthoritativeSelection(for editor: EditorSession) {
    if let controller = existingVimController(for: editor) {
      // VimEngine is authoritative. EditorSession and EditorTab carry only a
      // projection used by non-Vim UI and must never overwrite a cached engine.
      restoreSelection(controller, to: editor)
    } else {
      editor.captureSelectionFromDocument()
    }
  }

  @discardableResult
  private func restoreSelectionFromVimIfAvailable(for editor: EditorSession) -> Bool {
    guard let controller = existingVimController(for: editor) else { return false }
    restoreSelection(controller, to: editor)
    return true
  }

  private func existingVimController(for editor: EditorSession) -> VimKeymapController? {
    guard selectedEditorInterface.usesCalciteVim else { return nil }
    return vimSessionCoordinator.existingController(
      for: VimWindowID(editor.id),
      displaying: VimBufferID(editor.documentID)
    )
  }

  private func restoreSelection(
    _ controller: VimKeymapController,
    to editor: EditorSession
  ) {
    let presentation = CalciteVimSelectionPresenter.presentation(
      for: controller.engine.state,
      selectionSet: controller.engine.selectionSet
    )
    editor.restoreSelection(presentation.primaryRange)
  }

  private var selectedEditorInterface: EditorInterface {
    EditorInterface(
      rawValue: defaults.string(forKey: EditorInterfacePreferences.interfaceKey)
        ?? EditorInterface.builtIn.rawValue
    ) ?? .builtIn
  }

  /// Closes only one editor instance. The underlying document remains open until explicitly
  /// closed through `requestCloseDocument` / `resolvePendingDocumentClose`.
  func closeEditorSession(_ id: UUID) {
    guard let index = editorSessions.firstIndex(where: { $0.id == id }) else { return }
    let wasActive = activeEditorSessionID == id
    captureAuthoritativeSelection(for: editorSessions[index])
    vimSessionCoordinator.removeWindow(VimWindowID(id))
    pendingVimRuntimeSnapshots.removeValue(forKey: id)
    editorSessions.remove(at: index)
    sectionalEditorAssignments = sectionalEditorAssignments.filter { $0.value != id }
    if previousActiveEditorSessionID == id { previousActiveEditorSessionID = nil }

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
    let vanishedEditorDocumentIDs = editorSessions.lazy
      .map(\.documentID)
      .filter { !availableIDs.contains($0) }
    let vanishedRegisteredBufferIDs = vimSessionCoordinator.listedBuffers.lazy
      .map { $0.id.rawValue }
      .filter { !availableIDs.contains($0) }
    var vanishedDocumentIDs = Set(vanishedEditorDocumentIDs)
    vanishedDocumentIDs.formUnion(vanishedRegisteredBufferIDs)
    if !vanishedDocumentIDs.isEmpty {
      for documentID in vanishedDocumentIDs {
        removeDocumentFromVimLifecycle(
          documentID,
          fallback: backend.activeDocument ?? backend.documents.first
        )
        vimSessionCoordinator.wipeBuffer(VimBufferID(documentID))
      }
    }
    for editor in editorSessions {
      editor.retainPresentationStates(for: availableIDs)
    }

    if editorSessions.isEmpty, let document = backend.activeDocument ?? backend.documents.first {
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
        restoreSelectionFromVimIfAvailable(for: replacement)
      }
    }
  }

  /// Reveals a document-local range in this window without using the shared
  /// `EditorTab.selectedRange` as the presentation authority. An existing view
  /// of the document is preferred; otherwise the active editor is reused.
  @discardableResult
  func revealSelection(
    _ range: NSRange,
    in documentID: UUID,
    preferredEditorSessionID: UUID? = nil
  ) -> EditorSession? {
    guard !isClosed, let backend, let document = backend.document(id: documentID) else {
      return nil
    }

    let preferred = preferredEditorSessionID.flatMap { id in
      editorSessions.first { $0.id == id }
    }
    let editor =
      preferred
      ?? activeEditorSession.flatMap { $0.documentID == documentID ? $0 : nil }
      ?? editorSessions.first { $0.documentID == documentID }
      ?? activeEditorSession
      ?? createEditorSession(for: document, activate: false)

    if editor.documentID != documentID {
      switchDocument(in: editor, to: document)
    }

    let clamped = EditorSession.clamped(range, utf16Length: document.text.utf16.count)
    editor.updateSelection(clamped, for: document)
    if let controller = existingVimController(for: editor) {
      _ = controller.acceptHostCursorMove(
        toUTF16Offset: clamped.location,
        source: .parentRequest
      )
      restoreSelection(controller, to: editor)
    }
    activateEditorSession(editor.id)
    return editor
  }

  func synchronizeControllerSelection() {
    guard !isSynchronizingSelection, !isClosed, let backend, let activeEditorSession else {
      return
    }
    restoreSelectionFromVimIfAvailable(for: activeEditorSession)
    activeEditorSession.applySelectionToDocument()
    if backend.controller.selectedTabID != activeEditorSession.documentID {
      backend.controller.selectedTabID = activeEditorSession.documentID
    }
  }

  func synchronizeSelectedDocumentFromController(_ documentID: UUID?) {
    guard !isSynchronizingSelection, !isClosed, let documentID,
      let document = backend?.document(id: documentID)
    else { return }
    if let editor = activeEditorSession {
      isSynchronizingSelection = true
      switchDocument(in: editor, to: document)
      editor.applySelectionToDocument()
      isSynchronizingSelection = false
    } else {
      _ = createEditorSession(for: document)
    }
  }

  private func drainPendingDocumentOpens() async {
    while !pendingDocumentOpenURLs.isEmpty {
      let url = pendingDocumentOpenURLs.removeFirst()
      _ = await openDocument(at: url)
    }
  }

  // MARK: - Vim host routing

  func handleVimHostInvocation(_ invocation: VimHostInvocation) -> VimHostResponse {
    let originID = invocation.context.windowID?.rawValue ?? invocation.context.editorSessionID
    let origin = originID.flatMap { id in editorSessions.first { $0.id == id } }

    if Self.vimRequestRequiresOrigin(invocation.request) {
      guard let origin, let document = origin.document else { return .rejected(.staleContext) }
      if let bufferID = invocation.context.bufferID, bufferID.rawValue != document.id {
        return .rejected(.staleContext)
      }
      if let url = invocation.context.documentURL,
        url.standardizedFileURL != document.url.standardizedFileURL
      {
        return .rejected(.staleContext)
      }
      if let revision = invocation.context.revision, revision.value != document.textRevision {
        return .rejected(.staleContext)
      }
    }

    if let response = handleVimTopologyRequest(invocation.request, origin: origin) {
      return response
    }

    if let origin { activateEditorSession(origin.id) }
    guard let backend else { return .rejected(.staleContext) }
    return backend.controller.handleVimHostInvocation(invocation)
  }

  private static func vimRequestRequiresOrigin(_ request: VimHostRequest) -> Bool {
    switch request {
    case .openFile, .newTab, .shell:
      return false
    case .custom(let command):
      return !command.hasPrefix("vim-buffer-add:")
    default:
      return true
    }
  }

  private func handleVimTopologyRequest(
    _ request: VimHostRequest,
    origin: EditorSession?
  ) -> VimHostResponse? {
    switch request {
    case .quit, .closeWindow:
      guard let origin else { return .rejected(.staleContext) }
      return closeVimWindow(origin)
    case .writeAndQuit:
      guard let origin, let document = origin.document else { return .rejected(.staleContext) }
      Task { @MainActor [weak self, weak origin] in
        guard await document.save(), let self, let origin else { return }
        _ = self.closeVimWindow(origin)
      }
      return .accepted
    case .split(let horizontal):
      guard let origin else { return .rejected(.staleContext) }
      return splitVimWindow(origin, horizontal: horizontal)
    case .switchBuffer(let number):
      guard let origin else { return .rejected(.staleContext) }
      return switchVimBuffer(number: number, in: origin)
    case .scroll(let lines):
      guard let origin else { return .rejected(.staleContext) }
      scrollVimWindow(origin, lines: lines)
      return .accepted
    case .nextTab:
      guard let origin else { return .rejected(.staleContext) }
      // Do this in the window that received the Vim event. Routing through the
      // shared workspace controller can target another active window/section.
      activateEditorSession(origin.id)
      navigateTab(forward: true, originatingEditorSessionID: origin.id)
      return .accepted
    case .previousTab:
      guard let origin else { return .rejected(.staleContext) }
      activateEditorSession(origin.id)
      navigateTab(forward: false, originatingEditorSessionID: origin.id)
      return .accepted
    case .focusWindow(let direction, let count):
      return handleVimCustomTopologyCommand(
        "vim-window-\(direction.rawValue):\(max(1, count))", origin: origin)
    case .cycleWindow(let direction, let count):
      let name = direction == .next ? "next" : "previous"
      return handleVimCustomTopologyCommand("vim-window-\(name):\(max(1, count))", origin: origin)
    case .focusPreviousWindow:
      return handleVimCustomTopologyCommand("vim-window-previous-active", origin: origin)
    case .closeOtherWindows:
      return handleVimCustomTopologyCommand("vim-window-only", origin: origin)
    case .newWindow(let horizontal):
      return handleVimCustomTopologyCommand(
        horizontal ? "vim-window-new-horizontal" : "vim-window-new-vertical",
        origin: origin
      )
    case .custom(let command) where command.hasPrefix("vim-"):
      return handleVimCustomTopologyCommand(command, origin: origin)
    default:
      return nil
    }
  }

  private func registerOpenVimBuffers() {
    guard let backend else { return }
    for document in backend.documents {
      _ = vimSessionCoordinator.registerBuffer(
        id: VimBufferID(document.id),
        name: document.url.path,
        text: document.text
      )
      vimSessionCoordinator.updateBufferMetadata(
        id: VimBufferID(document.id),
        isLoaded: true,
        isModified: document.isDirty,
        isListed: true
      )
    }
  }

  private func switchVimBuffer(number: Int, in origin: EditorSession) -> VimHostResponse {
    registerOpenVimBuffers()
    guard let info = vimSessionCoordinator.bufferInfo(number: number),
      backend?.document(id: info.id.rawValue) != nil,
      switchEditorSession(origin.id, to: info.id.rawValue)
    else {
      return .rejected(.failed(code: "VIM_NO_BUFFER", message: "Buffer \(number) does not exist."))
    }
    return .completed(message: "Buffer \(number): \(info.name)")
  }

  private func switchVimBuffer(
    _ bufferID: VimBufferID,
    in origin: EditorSession
  ) -> VimHostResponse {
    guard let info = vimSessionCoordinator.bufferInfo(id: bufferID),
      backend?.document(id: bufferID.rawValue) != nil,
      switchEditorSession(origin.id, to: bufferID.rawValue)
    else {
      return .rejected(.failed(code: "VIM_NO_BUFFER", message: "Buffer is no longer available."))
    }
    return .completed(message: "Buffer \(info.number): \(info.name)")
  }

  private func resolveVimBuffer(_ argument: String, current: EditorSession?) -> VimBufferInfo? {
    registerOpenVimBuffers()
    let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty || value == "%", let current {
      return vimSessionCoordinator.bufferInfo(id: VimBufferID(current.documentID))
    }
    if value == "#", let current,
      let alternate = vimSessionCoordinator.alternateBuffer(for: VimWindowID(current.id))
    {
      return vimSessionCoordinator.bufferInfo(id: alternate)
    }
    if let number = Int(value) { return vimSessionCoordinator.bufferInfo(number: number) }
    let candidates = vimSessionCoordinator.listedBuffers.filter {
      $0.name == value || URL(fileURLWithPath: $0.name).lastPathComponent == value
        || $0.name.localizedCaseInsensitiveContains(value)
    }
    return candidates.count == 1 ? candidates[0] : nil
  }

  private func handleVimCustomTopologyCommand(
    _ command: String,
    origin: EditorSession?
  ) -> VimHostResponse {
    registerOpenVimBuffers()
    switch command {
    case "vim-buffer-current":
      guard let origin,
        let info = vimSessionCoordinator.bufferInfo(id: VimBufferID(origin.documentID))
      else { return .rejected(.staleContext) }
      return .completed(message: "Buffer \(info.number): \(info.name)")
    case "vim-buffer-list":
      let currentID = origin.map { VimBufferID($0.documentID) }
      let lines = vimSessionCoordinator.listedBuffers.map { info in
        let current = info.id == currentID ? "%" : " "
        let modified = info.isModified ? "+" : " "
        return "\(info.number)\(current)\(modified) \(info.name)"
      }
      return .completed(message: lines.isEmpty ? "No buffers" : lines.joined(separator: "\n"))
    case "vim-buffer-next", "vim-buffer-previous":
      guard let origin else { return .rejected(.staleContext) }
      let forward = command == "vim-buffer-next"
      guard
        let target = vimSessionCoordinator.nextBuffer(
          after: VimBufferID(origin.documentID),
          forward: forward
        )
      else {
        return .rejected(.failed(code: "VIM_NO_BUFFER", message: "No listed buffers."))
      }
      return switchVimBuffer(target, in: origin)
    case "vim-buffer-first", "vim-buffer-last":
      guard let origin else { return .rejected(.staleContext) }
      let values = vimSessionCoordinator.listedBuffers
      guard let target = command == "vim-buffer-first" ? values.first : values.last else {
        return .rejected(.failed(code: "VIM_NO_BUFFER", message: "No listed buffers."))
      }
      return switchVimBuffer(target.id, in: origin)
    case "vim-buffer-alternate":
      guard let origin,
        let target = vimSessionCoordinator.alternateBuffer(for: VimWindowID(origin.id))
      else {
        return .rejected(.failed(code: "VIM_NO_ALTERNATE", message: "No alternate buffer."))
      }
      return switchVimBuffer(target, in: origin)
    case "vim-window-previous-active":
      guard let previousActiveEditorSessionID,
        let previous = editorSessions.first(where: { $0.id == previousActiveEditorSessionID })
      else {
        return .rejected(
          .failed(code: "VIM_NO_PREVIOUS_WINDOW", message: "No previous Vim window."))
      }
      return activateVimWindow(previous) ? .accepted : .rejected(.staleContext)
    case "vim-window-force-close":
      guard let origin else { return .rejected(.staleContext) }
      return closeVimWindow(origin, force: true)
    case "vim-window-only":
      guard let origin else { return .rejected(.staleContext) }
      closeOtherVimWindows(keeping: origin.id)
      return .accepted
    case "vim-window-new-horizontal":
      guard let origin else { return .rejected(.staleContext) }
      return splitVimWindow(origin, horizontal: true)
    case "vim-window-new-vertical":
      guard let origin else { return .rejected(.staleContext) }
      return splitVimWindow(origin, horizontal: false)
    case "vim-window-split-horizontal":
      guard let origin else { return .rejected(.staleContext) }
      return splitVimWindow(origin, horizontal: true)
    case "vim-window-split-vertical":
      guard let origin else { return .rejected(.staleContext) }
      return splitVimWindow(origin, horizontal: false)
    case "vim-tab-close":
      guard let origin, let document = origin.document, let backend else {
        return .rejected(.staleContext)
      }
      if document.isDirty {
        return .rejected(
          .failed(code: "VIM_NO_WRITE", message: "No write since last change."))
      }
      _ = activateVimWindow(origin)
      backend.closeDocument(document)
      return .accepted
    default:
      break
    }

    for (prefix, horizontal) in [
      ("vim-window-split-horizontal:", true),
      ("vim-window-split-vertical:", false),
    ] where command.hasPrefix(prefix) {
      guard let origin, let backend else { return .rejected(.staleContext) }
      let path = String(command.dropFirst(prefix.count))
      guard !path.isEmpty else { return splitVimWindow(origin, horizontal: horizontal) }
      let url = URL(
        fileURLWithPath: NSString(string: path).expandingTildeInPath,
        relativeTo: backend.workspaceURL
      ).standardizedFileURL
      let originalDocumentID = origin.documentID
      Task { @MainActor [weak self, weak origin] in
        guard let self, let origin, self.editorSessions.contains(where: { $0.id == origin.id }),
          let document = await backend.openDocument(at: url)
        else { return }
        _ = self.switchEditorSession(origin.id, to: originalDocumentID)
        _ = self.splitVimWindow(
          origin,
          horizontal: horizontal,
          displaying: document
        )
      }
      return .accepted
    }
    if command.hasPrefix("vim-window-") {
      return navigateVimWindow(command, origin: origin)
    }
    if command.hasPrefix("vim-wincmd:") {
      let key = String(command.dropFirst("vim-wincmd:".count))
      return handleVimCustomTopologyCommand(
        "vim-window-\(Self.vimWindowCommandName(key))", origin: origin)
    }
    if command.hasPrefix("vim-buffer-switch:") {
      guard let origin else { return .rejected(.staleContext) }
      let argument = String(command.dropFirst("vim-buffer-switch:".count))
      guard let target = resolveVimBuffer(argument, current: origin) else {
        return .rejected(
          .failed(code: "VIM_NO_BUFFER", message: "Buffer \(argument) is ambiguous or missing."))
      }
      return switchVimBuffer(target.id, in: origin)
    }
    if command.hasPrefix("vim-buffer-add:") {
      let path = String(command.dropFirst("vim-buffer-add:".count))
      guard let backend else { return .rejected(.staleContext) }
      let url = URL(
        fileURLWithPath: NSString(string: path).expandingTildeInPath,
        relativeTo: backend.workspaceURL
      ).standardizedFileURL
      let previousID = activeEditorSessionID
      Task { @MainActor [weak self] in
        guard let self, let document = await backend.openDocument(at: url) else { return }
        _ = self.vimSessionCoordinator.registerBuffer(
          id: VimBufferID(document.id),
          name: document.url.path,
          text: document.text
        )
        if let previousID { self.activateEditorSession(previousID) }
      }
      return .accepted
    }
    for (prefix, wipe) in [
      ("vim-buffer-delete:", false),
      ("vim-buffer-unload:", false),
      ("vim-buffer-wipeout:", true),
    ] where command.hasPrefix(prefix) {
      guard let origin else { return .rejected(.staleContext) }
      var argument = String(command.dropFirst(prefix.count))
      let force = argument.hasPrefix("!")
      if force { argument.removeFirst() }
      guard let target = resolveVimBuffer(argument, current: origin) else {
        return .rejected(.failed(code: "VIM_NO_BUFFER", message: "Buffer does not exist."))
      }
      return deleteVimBuffer(target, force: force, wipe: wipe)
    }
    return .rejected(.failed(code: "VIM_UNKNOWN_HOST_COMMAND", message: command))
  }

  private static func vimWindowCommandName(_ key: String) -> String {
    switch key.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "h": return "left:1"
    case "j": return "down:1"
    case "k": return "up:1"
    case "l": return "right:1"
    case "w": return "next:1"
    case "W": return "previous:1"
    case "p": return "previous-active"
    case "s", "S": return "split-horizontal"
    case "v": return "split-vertical"
    case "n": return "new-horizontal"
    case "o": return "only"
    case "q", "c": return "close"
    default: return "unknown"
    }
  }

  private func navigateVimWindow(
    _ command: String,
    origin: EditorSession?
  ) -> VimHostResponse {
    guard let origin, activateVimWindow(origin) else { return .rejected(.staleContext) }
    let body = String(command.dropFirst("vim-window-".count))
    let pieces = body.split(separator: ":", maxSplits: 1).map(String.init)
    let count = pieces.count > 1 ? max(1, Int(pieces[1]) ?? 1) : 1
    switch pieces[0] {
    case "left":
      for _ in 0..<count { navigateVimSection(direction: .left) }
    case "right":
      for _ in 0..<count { navigateVimSection(direction: .right) }
    case "up":
      for _ in 0..<count { navigateVimSection(direction: .up) }
    case "down":
      for _ in 0..<count { navigateVimSection(direction: .down) }
    case "next":
      for _ in 0..<count { navigateVimSection(forward: true) }
    case "previous":
      for _ in 0..<count { navigateVimSection(forward: false) }
    case "close":
      return closeVimWindow(origin)
    default:
      return .rejected(.failed(code: "VIM_BAD_WINCOMMAND", message: command))
    }
    return .accepted
  }

  private func closeVimWindow(
    _ origin: EditorSession,
    force: Bool = false
  ) -> VimHostResponse {
    guard let location = vimWindowLocation(for: origin) else {
      return .rejected(.staleContext)
    }
    if sectionalLayout.root.visibleVimEditorSectionIDs.count <= 1 {
      if origin.document?.isDirty == true, !force {
        return .rejected(
          .failed(code: "VIM_NO_WRITE", message: "No write since last change. Use :q! to force."))
      }
      requestWindowClose()
      return .accepted
    }
    removeVimWindowPresentation(origin, at: location)
    activateBestAvailableVimWindow()
    return .accepted
  }

  private func closeOtherVimWindows(keeping editorID: UUID) {
    guard let kept = editorSessions.first(where: { $0.id == editorID }),
      let keptLocation = vimWindowLocation(for: kept)
    else { return }
    let closing = editorSessions.filter { editor in
      editor.id != editorID && vimWindowLocation(for: editor) != nil
    }
    for editor in closing {
      guard let location = vimWindowLocation(for: editor),
        location != keptLocation
      else { continue }
      removeVimWindowPresentation(editor, at: location)
    }
    _ = activateVimWindow(kept)
  }

  private func vimWindowLocation(for editor: EditorSession) -> VimWindowLocation? {
    guard
      let editorTabID = sectionalEditorAssignments.first(where: { $0.value == editor.id })?.key,
      let sectionID = sectionalLayout.root.sectionID(containingTab: editorTabID),
      let section = sectionalLayout.root.sectionNode(id: sectionID),
      section.isSectionVisible,
      section.tabs.contains(where: {
        $0.id == editorTabID && $0.isVisible && $0.kind.isEditorHost
      })
    else { return nil }
    return VimWindowLocation(sectionID: sectionID, editorTabID: editorTabID)
  }

  @discardableResult
  private func activateVimWindow(_ editor: EditorSession) -> Bool {
    guard let location = vimWindowLocation(for: editor) else { return false }
    _ = sectionalLayout.activateVimEditorSection(location.sectionID)
    activateEditorSession(editor.id)
    return true
  }

  private func activateVimSection(_ sectionID: UUID) {
    guard let editorTabID = sectionalLayout.activateVimEditorSection(sectionID),
      let editorID = assignEditorSession(toSection: editorTabID)
    else { return }
    activateEditorSession(editorID)
  }

  private func navigateVimSection(forward: Bool) {
    guard let sectionID = sectionalLayout.navigateVimEditorSection(forward: forward) else { return }
    activateVimSection(sectionID)
  }

  private func navigateVimSection(direction: MainSectionDirection) {
    guard let sectionID = sectionalLayout.navigateVimEditorSection(direction: direction) else {
      return
    }
    activateVimSection(sectionID)
  }

  private func splitVimWindow(
    _ origin: EditorSession,
    horizontal: Bool,
    displaying requestedDocument: EditorTab? = nil
  ) -> VimHostResponse {
    guard let document = requestedDocument ?? origin.document,
      let location = vimWindowLocation(for: origin)
    else {
      return .rejected(.staleContext)
    }
    _ = activateVimWindow(origin)
    let axis: MainSectionSplitAxis = horizontal ? .vertical : .horizontal
    guard
      let created = sectionalLayout.splitVimEditorSection(
        id: location.sectionID,
        axis: axis
      )
    else {
      return .rejected(
        .failed(code: "VIM_SPLIT_FAILED", message: "Calcite could not split this section."))
    }

    let editor = createEditorSession(for: document, activate: false)
    editor.updateSelection(origin.selectedRange)
    editor.updateScroll(
      horizontal: origin.horizontalScrollOffset,
      vertical: origin.verticalScrollOffset
    )
    editor.updateZoom(origin.zoomScale)
    sectionalEditorAssignments[created.editorTabID] = editor.id
    _ = sectionalLayout.activateVimEditorSection(created.sectionID)
    activateEditorSession(editor.id)
    return .accepted
  }

  private func removeVimWindowPresentation(
    _ editor: EditorSession,
    at location: VimWindowLocation
  ) {
    guard let section = sectionalLayout.root.sectionNode(id: location.sectionID) else { return }
    sectionalEditorAssignments.removeValue(forKey: location.editorTabID)
    if section.tabs.count > 1 {
      sectionalLayout.removeTab(sectionID: location.sectionID, tabID: location.editorTabID)
    } else {
      sectionalLayout.removeSection(id: location.sectionID)
    }
    closeEditorSession(editor.id)
  }

  private func activateBestAvailableVimWindow() {
    let preferredSectionID = sectionalLayout.activeSectionID.flatMap { candidate in
      sectionalLayout.root.visibleVimEditorSectionIDs.contains(candidate) ? candidate : nil
    }
    guard
      let sectionID = preferredSectionID ?? sectionalLayout.root.visibleVimEditorSectionIDs.first
    else { return }
    activateVimSection(sectionID)
  }

  private func deleteVimBuffer(
    _ info: VimBufferInfo,
    force: Bool,
    wipe: Bool
  ) -> VimHostResponse {
    guard let backend, let document = backend.document(id: info.id.rawValue) else {
      return .rejected(.failed(code: "VIM_NO_BUFFER", message: "Buffer does not exist."))
    }
    if document.isDirty, !force {
      return .rejected(
        .failed(code: "VIM_NO_WRITE", message: "No write since last change for \(document.title)."))
    }

    registerOpenVimBuffers()
    let fallback = vimSessionCoordinator.listedBuffers.first {
      $0.id != info.id && backend.document(id: $0.id.rawValue) != nil
    }.flatMap { backend.document(id: $0.id.rawValue) }
    removeDocumentFromVimLifecycle(document.id, fallback: fallback)

    vimSessionCoordinator.updateBufferMetadata(
      id: info.id,
      isLoaded: false,
      isModified: document.isDirty,
      isListed: false
    )
    if wipe {
      vimSessionCoordinator.wipeBuffer(info.id)
    } else {
      vimSessionCoordinator.unloadBuffer(info.id)
    }
    backend.closeDocument(document)
    return .accepted
  }

  private func scrollVimWindow(_ origin: EditorSession, lines: Int) {
    guard lines != 0,
      let controller = vimSessionCoordinator.existingController(
        for: VimWindowID(origin.id),
        displaying: VimBufferID(origin.documentID)
      )
    else { return }
    controller.engine.requestViewportScroll(lines: lines)
  }

  // MARK: - Document and utility close workflows

  /// Removes every view of a document from the Vim session before its Calcite
  /// document disappears. A window currently displaying the document is moved
  /// to the fallback document when possible; retained views are detached from
  /// every other window as well.
  private func removeDocumentFromVimLifecycle(
    _ documentID: UUID,
    fallback: EditorTab?
  ) {
    pendingVimRuntimeSnapshots = pendingVimRuntimeSnapshots.filter { _, pending in
      pending.documentID != documentID
    }
    let bufferID = VimBufferID(documentID)
    let fallback = fallback.flatMap { $0.id == documentID ? nil : $0 }
    let managesVimBuffer = vimSessionCoordinator.bufferInfo(id: bufferID) != nil

    if managesVimBuffer, let fallback {
      _ = vimSessionCoordinator.registerBuffer(
        id: VimBufferID(fallback.id),
        name: fallback.url.path,
        text: fallback.text
      )
    }

    for editor in Array(editorSessions) {
      let windowID = VimWindowID(editor.id)
      if editor.documentID == documentID {
        if let fallback {
          switchDocument(in: editor, to: fallback)
          if activeEditorSessionID == editor.id {
            activateEditorSession(editor.id)
          }
          vimSessionCoordinator.detachBuffer(bufferID, from: windowID)
        } else {
          closeEditorSession(editor.id)
        }
      } else {
        vimSessionCoordinator.detachBuffer(bufferID, from: windowID)
      }
    }
  }

  private func closeDocumentThroughVimLifecycle(_ document: EditorTab) {
    guard let backend, backend.document(id: document.id) != nil else { return }
    let bufferID = VimBufferID(document.id)
    let hadVimBuffer = vimSessionCoordinator.bufferInfo(id: bufferID) != nil
    let fallback =
      backend.activeDocument.flatMap { $0.id == document.id ? nil : $0 }
      ?? backend.documents.first(where: { $0.id != document.id })
    removeDocumentFromVimLifecycle(document.id, fallback: fallback)
    if hadVimBuffer { vimSessionCoordinator.wipeBuffer(bufferID) }
    backend.closeDocument(document)
  }

  func requestCloseDocument(_ document: EditorTab) {
    guard backend?.document(id: document.id) != nil else { return }
    if document.isDirty {
      pendingDocumentClose = document
    } else {
      closeDocumentThroughVimLifecycle(document)
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
      closeDocumentThroughVimLifecycle(document)
      return true
    case .discard:
      pendingDocumentClose = nil
      closeDocumentThroughVimLifecycle(document)
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

  func navigateTab(
    forward: Bool,
    originatingEditorSessionID: UUID? = nil
  ) {
    guard
      let backend,
      let context = tabNavigationContext(
        originatingEditorSessionID: originatingEditorSessionID
      )
    else { return }
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
  func selectTab(
    number: Int,
    originatingEditorSessionID: UUID? = nil
  ) {
    guard
      let context = tabNavigationContext(
        originatingEditorSessionID: originatingEditorSessionID
      ),
      context.items.indices.contains(number - 1)
    else { return }
    selectTabNavigationItem(context.items[number - 1], in: context.sectionID)
  }

  private func tabNavigationContext(
    originatingEditorSessionID: UUID? = nil
  ) -> (
    sectionID: UUID,
    section: MainSectionLayoutNode,
    primaryEditorTabID: UUID?,
    items: [SectionTabNavigationItem]
  )? {
    guard let backend else { return nil }
    let originEditorTabID = originatingEditorSessionID.flatMap { editorSessionID in
      sectionalEditorAssignments.first { $0.value == editorSessionID }?.key
    }
    let originSectionID = originEditorTabID.flatMap { editorTabID in
      sectionalLayout.root.sectionID(containingTab: editorTabID)
    }
    let sectionID =
      originSectionID
      ?? sectionalLayout.activeSectionID
      ?? sectionalLayout.root.visibleSectionIDs.first
    guard let sectionID, let section = sectionalLayout.root.sectionNode(id: sectionID) else {
      return nil
    }
    let primaryEditorTabID =
      originEditorTabID.flatMap { editorTabID in
        section.visibleTabs.first {
          $0.id == editorTabID && ($0.kind == .editor || $0.kind == .workspace)
        }?.id
      }
      ?? section.visibleTabs.first {
        $0.kind == .editor || $0.kind == .workspace
      }?.id
    let items = section.visibleTabs.flatMap { tab -> [SectionTabNavigationItem] in
      if tab.id == primaryEditorTabID,
        tab.kind == .editor || tab.kind == .workspace,
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
    guard let origin = activeEditorSession else { return }
    _ = splitVimWindow(origin, horizontal: horizontal)
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
    if let editor = activeEditorSession {
      switchDocument(in: editor, to: document)
      activateEditorSession(editor.id)
    } else {
      _ = createEditorSession(for: document)
    }
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

  func commandNavigateTab(
    forward: Bool,
    originatingEditorSessionID: UUID
  ) {
    navigateTab(
      forward: forward,
      originatingEditorSessionID: originatingEditorSessionID
    )
  }

  func commandSelectTab(number: Int) {
    selectTab(number: number)
  }

  func commandSelectTab(
    number: Int,
    originatingEditorSessionID: UUID
  ) {
    selectTab(
      number: number,
      originatingEditorSessionID: originatingEditorSessionID
    )
  }

  func commandNavigateSection(forward: Bool) {
    navigateSection(forward: forward)
  }

  func commandNavigateSection(direction: MainSectionDirection) {
    guard let sectionID = sectionalLayout.navigateSection(direction: direction) else { return }
    activateSection(sectionID)
  }
}
