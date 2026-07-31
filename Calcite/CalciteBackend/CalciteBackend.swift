import Combine
import EditorServices
@_spi(Calcite) import EditorVim
import Foundation
import SwiftUI

/// Project-scoped source of truth for Calcite workspace services and documents.
///
/// A single backend is shared by all windows that display the same project, while each window
/// owns an independent `CalciteBackendWindowSession` for presentation and editor-instance state.
@MainActor
final class CalciteBackend: ObservableObject, Identifiable {
  let id = UUID()
  let workspaceURL: URL

  // Project-scoped services owned and exposed by the backend.
  let controller: EditorWorkspaceController
  let terminal: EditorTerminalSession
  let fileVisibility: FileVisibilitySettings
  let recentItems: EditorRecentItemsStore
  let logStore: CalciteLogStore

  @Published private(set) var lifecycleState: WorkspaceLifecycleState = .idle
  @Published private(set) var windowSessions: [CalciteBackendWindowSession] = []
  @Published private(set) var activeWindowSessionID: UUID?

  private static var projectBackends: [String: CalciteBackend] = [:]

  private var startupTask: Task<WorkspaceLifecycleState, Never>?
  private var shutdownTask: Task<Bool, Never>?
  private var pendingWindowPresentationSnapshots: [WorkspaceWindowPresentationSnapshot] = []
  private var pendingActivePresentationWindowID: UUID?
  private var observations = Set<AnyCancellable>()

  /// Returns the active backend for a project, creating one only when needed.
  static func shared(
    for workspaceURL: URL,
    recentItems: EditorRecentItemsStore? = nil,
    fileVisibility: FileVisibilitySettings? = nil
  ) -> CalciteBackend {
    let standardizedURL = workspaceURL.standardizedFileURL
    let key = registryKey(for: standardizedURL)
    if let existing = projectBackends[key], existing.lifecycleState != .stopped {
      return existing
    }

    let backend = CalciteBackend(
      workspaceURL: standardizedURL,
      recentItems: recentItems ?? EditorRecentItemsStore(),
      fileVisibility: fileVisibility ?? FileVisibilitySettings()
    )
    projectBackends[key] = backend
    return backend
  }

  /// Creates an independent backend even if another backend currently owns the project.
  /// This is primarily useful for isolated tests; normal app code should use `shared(for:)`.
  init(
    workspaceURL: URL,
    recentItems: EditorRecentItemsStore = EditorRecentItemsStore(),
    fileVisibility: FileVisibilitySettings = FileVisibilitySettings()
  ) {
    let standardizedURL = workspaceURL.standardizedFileURL
    self.workspaceURL = standardizedURL
    self.controller = EditorWorkspaceController(workspaceURL: standardizedURL)
    self.terminal = EditorTerminalSessionRegistry.shared.session(for: standardizedURL)
    self.fileVisibility = fileVisibility
    self.recentItems = recentItems
    self.logStore = CalciteLogStore.shared

    configureControllerCallbacks()
    observeExistingServices()
  }

  isolated deinit {
    startupTask?.cancel()
    shutdownTask?.cancel()
  }

  // MARK: - Project services

  var documents: [EditorTab] { controller.tabs }
  var activeDocument: EditorTab? { controller.activeTab }
  var activeDocumentID: UUID? { controller.selectedTabID }
  var workspacePhase: EditorWorkspacePhase { controller.phase }
  var serviceReport: EditorServiceAvailabilityReport { controller.serviceReport }
  var serviceSettingsModel: EditorServicesSettingsModel { controller.serviceSettingsModel }
  var buildController: EditorBuildController { controller.buildController }
  var commandAvailability: EditorCommandAvailability { controller.commandAvailability }
  var hasUnsavedDocuments: Bool { controller.hasUnsavedDocuments }
  var activeWindowSession: CalciteBackendWindowSession? {
    guard let activeWindowSessionID else { return nil }
    return windowSessions.first { $0.id == activeWindowSessionID }
  }

  func document(id: UUID) -> EditorTab? {
    documents.first { $0.id == id }
  }

  func document(at url: URL) -> EditorTab? {
    let key = url.standardizedFileURL
    return documents.first { $0.url.standardizedFileURL == key }
  }

  // MARK: - Lifecycle

  /// Starts the project services once. Every caller may independently request an initial
  /// document and terminal startup, even when another window is already starting them.
  @discardableResult
  func start(
    initialFileURL: URL? = nil,
    shouldStartTerminal: Bool = false
  ) async -> WorkspaceLifecycleState {
    let result = await ensureStarted()
    guard result == .running else { return result }

    if let initialFileURL {
      _ = await openDocument(at: initialFileURL)
    }
    if shouldStartTerminal {
      terminal.startIfNeeded()
    }
    return lifecycleState
  }

  /// Shuts down the project controller. The shared registry releases this backend only after a
  /// successful shutdown, ensuring that a failed save cannot detach live windows from services.
  @discardableResult
  func shutdown(saveChanges: Bool = true) async -> Bool {
    if lifecycleState == .stopped { return true }
    if let shutdownTask { return await shutdownTask.value }

    lifecycleState = .stopping
    startupTask?.cancel()
    let controller = controller
    let task = Task { @MainActor in
      let succeeded = await controller.shutdown(saveChanges: saveChanges)
      return succeeded
    }
    shutdownTask = task
    let succeeded = await task.value
    shutdownTask = nil

    if succeeded {
      lifecycleState = .stopped
      unregisterSharedInstance()
    } else if case .failed(let message) = controller.phase {
      lifecycleState = .failed(message)
    } else {
      lifecycleState = .failed("The workspace could not be closed.")
    }
    return succeeded
  }

  private func ensureStarted() async -> WorkspaceLifecycleState {
    switch lifecycleState {
    case .running:
      return .running
    case .stopping, .stopped:
      return lifecycleState
    case .starting:
      if let startupTask { return await startupTask.value }
    case .idle, .failed:
      break
    }

    lifecycleState = .starting
    let controller = controller
    let task = Task { @MainActor in
      await controller.start()
      if Task.isCancelled { return WorkspaceLifecycleState.stopped }
      switch controller.phase {
      case .ready:
        return .running
      case .failed(let message):
        return .failed(message)
      case .idle:
        return .stopped
      case .starting:
        return .failed("The workspace did not finish starting.")
      }
    }
    startupTask = task
    let result = await task.value
    if startupTask != nil { startupTask = nil }
    if lifecycleState != .stopping && lifecycleState != .stopped {
      lifecycleState = result
      if result == .running {
        recentItems.add(workspaceURL)
      }
    }
    return lifecycleState
  }

  // MARK: - Window sessions

  func captureRuntimePresentationSnapshot() -> WorkspacePresentationSnapshot {
    WorkspacePresentationSnapshot(
      activeWindowSessionID: activeWindowSessionID,
      windows: windowSessions.map { $0.captureRuntimePresentationSnapshot() }
    )
  }

  func restoreRuntimePresentationSnapshot(_ snapshot: WorkspacePresentationSnapshot) {
    guard !snapshot.windows.isEmpty else { return }

    var unusedSnapshots = snapshot.windows
    var unusedSessions = windowSessions
    var restoredWindowIDs: [UUID: UUID] = [:]

    for session in windowSessions {
      guard let index = unusedSnapshots.firstIndex(where: { $0.windowSessionID == session.id })
      else { continue }
      let value = unusedSnapshots.remove(at: index)
      unusedSessions.removeAll { $0 === session }
      restoredWindowIDs[value.windowSessionID] = session.id
      session.restoreRuntimePresentationSnapshot(value)
    }

    for session in unusedSessions where !unusedSnapshots.isEmpty {
      let value = unusedSnapshots.removeFirst()
      restoredWindowIDs[value.windowSessionID] = session.id
      session.restoreRuntimePresentationSnapshot(value)
    }

    pendingWindowPresentationSnapshots = unusedSnapshots
    pendingActivePresentationWindowID = snapshot.activeWindowSessionID
    if let storedActiveID = snapshot.activeWindowSessionID,
      let restoredActiveID = restoredWindowIDs[storedActiveID],
      let session = windowSessions.first(where: { $0.id == restoredActiveID })
    {
      pendingActivePresentationWindowID = nil
      setActiveWindowSession(session)
    }
  }

  @discardableResult
  func makeWindowSession(
    defaults: UserDefaults = .standard,
    onOpenItem: @escaping () -> Void = {},
    onRequestCloseWindow: @escaping () -> Void = {}
  ) -> CalciteBackendWindowSession {
    let session = CalciteBackendWindowSession(
      backend: self,
      defaults: defaults,
      onOpenItem: onOpenItem,
      onRequestCloseWindow: onRequestCloseWindow
    )
    windowSessions.append(session)
    if activeWindowSessionID == nil {
      setActiveWindowSession(session)
    }
    session.reconcileDocuments()
    if !pendingWindowPresentationSnapshots.isEmpty {
      let value = pendingWindowPresentationSnapshots.removeFirst()
      session.restoreRuntimePresentationSnapshot(value)
      if pendingActivePresentationWindowID == value.windowSessionID {
        pendingActivePresentationWindowID = nil
        setActiveWindowSession(session)
      }
    }
    return session
  }

  func setActiveWindowSession(_ session: CalciteBackendWindowSession) {
    guard session.backend === self, windowSessions.contains(where: { $0 === session }) else {
      return
    }
    guard activeWindowSessionID != session.id else { return }
    activeWindowSessionID = session.id
    session.synchronizeControllerSelection()
  }

  @discardableResult
  func closeWindowSession(
    _ session: CalciteBackendWindowSession,
    saveChangesIfLastWindow: Bool = true
  ) async -> Bool {
    guard session.backend === self, windowSessions.contains(where: { $0 === session }) else {
      return true
    }

    if windowSessions.count == 1 {
      guard await shutdown(saveChanges: saveChangesIfLastWindow) else { return false }
    }

    removeWindowSession(session)
    return true
  }

  private func removeWindowSession(_ session: CalciteBackendWindowSession) {
    windowSessions.removeAll { $0 === session }
    session.backendDidClose()
    if activeWindowSessionID == session.id {
      activeWindowSessionID = windowSessions.last?.id
      activeWindowSession?.synchronizeControllerSelection()
    }
  }

  // MARK: - Documents

  @discardableResult
  func openDocument(at url: URL) async -> EditorTab? {
    let standardizedURL = url.standardizedFileURL
    await controller.openDocument(at: standardizedURL)
    return document(at: standardizedURL)
  }

  func selectDocument(id: UUID?) {
    if let id, document(id: id) == nil { return }
    controller.selectedTabID = id
  }

  func closeDocument(_ document: EditorTab, saving: Bool = false) {
    guard self.document(id: document.id) != nil else { return }
    controller.closeTab(document, saving: saving)
  }

  func saveActiveDocument() {
    controller.saveActiveDocument()
  }

  @discardableResult
  func saveAllDocuments() async -> Bool {
    await controller.saveAllDocuments()
  }

  // MARK: - File system and project context

  @discardableResult
  func createFile(in directory: URL, name: String) async -> Bool {
    await controller.createFile(in: directory, name: name)
  }

  @discardableResult
  func createDirectory(in directory: URL, name: String) async -> Bool {
    await controller.createDirectory(in: directory, name: name)
  }

  @discardableResult
  func renameItem(at url: URL, to name: String) async -> Bool {
    await controller.renameItem(at: url, to: name)
  }

  @discardableResult
  func duplicateFile(at url: URL) async -> Bool {
    await controller.duplicateFile(at: url)
  }

  @discardableResult
  func deleteItem(at url: URL) async -> Bool {
    await controller.deleteItem(at: url)
  }

  func hasUnsavedChanges(under url: URL) -> Bool {
    controller.hasUnsavedChanges(under: url)
  }

  func refreshProjectContext() {
    controller.refreshProjectContext()
  }

  func selectBuildProjectFolder(_ url: URL) {
    controller.selectBuildProjectFolder(url)
  }

  func useWorkspaceAsBuildProject() {
    controller.useWorkspaceAsBuildProject()
  }

  func selectPythonInterpreter(_ url: URL?) {
    controller.selectPythonInterpreter(url)
  }

  // MARK: - Language services

  func applyServicesConfiguration(_ configuration: EditorServicesConfiguration) {
    controller.applyServicesConfiguration(configuration)
  }

  func toggleEditorInputMode() {
    controller.toggleEditorInputMode()
  }

  func requestCompletion() {
    controller.activeTab?.requestCompletionsExplicitly()
  }

  func formatActiveDocument() {
    controller.activeTab?.format(
      tabWidth: controller.profile.behavior.tabWidth,
      insertSpaces: controller.profile.behavior.insertSpaces
    )
  }

  func goToDefinition() {
    controller.goToDefinition()
  }

  func findReferences() {
    controller.findReferences()
  }

  func showQuickHelp() {
    controller.showQuickHelp()
  }

  func openSymbolLocation(_ location: SourceLocation) {
    controller.openSymbolLocation(location)
  }

  // MARK: - Build and run

  func resolvedBuildTask(_ kind: EditorBuildTaskKind) -> EditorBuildTaskTarget? {
    controller.resolvedBuildTask(kind)
  }

  func runBuildTask(_ kind: EditorBuildTaskKind) {
    controller.runBuildTask(kind)
  }

  func runSelectedBuildTask() {
    controller.runSelectedBuildTask()
  }

  func cancelBuildTask() {
    controller.cancelBuildTask()
  }

  func openBuildDiagnostic(_ diagnostic: EditorBuildDiagnostic) {
    controller.openBuildDiagnostic(diagnostic)
  }

  // MARK: - Debugger

  func startDebugging() {
    controller.startDebugging()
  }

  func stopDebugging() {
    controller.stopDebugging()
  }

  func continueDebugging() {
    controller.continueDebugging()
  }

  func pauseDebugging() {
    controller.pauseDebugging()
  }

  func stepOver() {
    controller.stepOver()
  }

  func stepInto() {
    controller.stepInto()
  }

  func stepOut() {
    controller.stepOut()
  }

  func toggleBreakpointAtCurrentLine() {
    controller.toggleBreakpointAtCurrentLine()
  }

  func selectDebugFrame(_ frame: StackFrame) {
    controller.selectDebugFrame(frame)
  }

  func clearDebugConsole() {
    controller.clearDebugConsole()
  }

  // MARK: - External file conflicts

  func resolveExternalFileConflict(using resolution: SourceWorkspaceConflictResolution) {
    controller.resolveExternalFileConflict(using: resolution)
  }

  func dismissExternalFileConflict() {
    controller.dismissExternalFileConflict()
  }

  // MARK: - Themes and profiles

  func profile(for slot: EditorThemeSlot) -> EditorCustomProfile {
    controller.profile(for: slot)
  }

  func setProfile(_ profile: EditorCustomProfile, for slot: EditorThemeSlot) {
    controller.setProfile(profile, for: slot)
  }

  func setUsesWorkspaceThemeOverrides(_ enabled: Bool) {
    controller.setUsesWorkspaceThemeOverrides(enabled)
  }

  func activateThemeSlot(_ slot: EditorThemeSlot) {
    controller.activateThemeSlot(slot)
  }

  func activateTheme(for colorScheme: ColorScheme) {
    controller.activateTheme(for: colorScheme)
  }

  // MARK: - Terminal

  func startTerminal() {
    terminal.startIfNeeded()
  }

  func reattachTerminalView() {
    terminal.reattachView()
  }

  func detachTerminalView() {
    terminal.detachView()
  }

  func restartTerminal() {
    terminal.restart()
  }

  func stopTerminal() {
    terminal.stop()
  }

  func clearTerminal() {
    terminal.clear()
  }

  func sendToTerminal(_ value: String) {
    terminal.send(value)
  }

  func resizeTerminal(columns: Int, rows: Int) {
    terminal.resize(columns: columns, rows: rows)
  }

  func refreshTerminalEnvironment(restartIfChanged: Bool = false) {
    terminal.refreshEnvironment(restartIfChanged: restartIfChanged)
  }

  func openExternalTerminal() {
    terminal.openExternalTerminal()
  }

  // MARK: - Existing Vim host integration

  func handleVimHostInvocation(_ invocation: VimHostInvocation) -> VimHostResponse {
    controller.handleVimHostInvocation(invocation)
  }

  func handleVimHostRequest(_ request: VimHostRequest) {
    controller.handleVimHostRequest(request)
  }

  // MARK: - Observation and routing

  private func configureControllerCallbacks() {
    controller.capturePresentationSnapshot = { [weak self] in
      self?.captureRuntimePresentationSnapshot() ?? .empty
    }
    controller.restorePresentationSnapshot = { [weak self] snapshot in
      self?.restoreRuntimePresentationSnapshot(snapshot)
    }
    controller.onVimSplit = { [weak self] horizontal in
      self?.activeWindowSession?.receiveVimSplit(horizontal: horizontal)
    }
    controller.onVimCloseWindow = { [weak self] in
      self?.activeWindowSession?.requestWindowClose()
    }
    controller.onVimNewTab = { [weak self] in
      self?.activeWindowSession?.requestOpenItem()
    }
    controller.onVimCommand = { [weak self] command in
      self?.activeWindowSession?.perform(command)
    }
  }

  private func observeExistingServices() {
    forwardChanges(from: controller)
    forwardChanges(from: terminal)
    forwardChanges(from: fileVisibility)
    forwardChanges(from: recentItems)
    forwardChanges(from: logStore)

    controller.$tabs
      .sink { [weak self] _ in
        guard let self else { return }
        for session in self.windowSessions {
          session.reconcileDocuments()
        }
      }
      .store(in: &observations)

    controller.$selectedTabID
      .sink { [weak self] selectedID in
        self?.activeWindowSession?.synchronizeSelectedDocumentFromController(selectedID)
      }
      .store(in: &observations)
  }

  private func forwardChanges<Object: ObservableObject>(from object: Object)
  where Object.ObjectWillChangePublisher == ObservableObjectPublisher {
    object.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &observations)
  }

  private func unregisterSharedInstance() {
    let key = Self.registryKey(for: workspaceURL)
    if Self.projectBackends[key] === self {
      Self.projectBackends.removeValue(forKey: key)
    }
  }

  private static func registryKey(for workspaceURL: URL) -> String {
    workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
  }
}
