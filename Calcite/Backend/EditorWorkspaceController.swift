import AppKit
import Combine
import EditorServices
@_spi(Calcite) import EditorVim
import Foundation
import SwiftUI

enum EditorWorkspacePhase: Equatable {
  case idle
  case starting
  case ready
  case failed(String)
}

enum EditorWorkspaceRuntimeError: LocalizedError {
  case noDebugThread
  case unsavedDocument(String)

  var errorDescription: String? {
    switch self {
    case .noDebugThread:
      return "The debug adapter reported no active thread."
    case .unsavedDocument(let name):
      return "The operation was cancelled because \(name) could not be saved."
    }
  }
}

struct EditorExternalFileConflict: Identifiable, Equatable {
  let id = UUID()
  let url: URL
  let message: String
}

enum EditorDebugPhase: Equatable {
  case idle
  case starting
  case running
  case stopped
  case failed(String)
}

enum EditorLiveDebugPhase: Equatable {
  case disabled
  case watching
  case changesPending(Int)
  case building
  case restarting
  case failed(String)
}

struct EditorDebugScopeSnapshot: Identifiable {
  let scope: Scope
  let variables: [Variable]

  var id: Int { scope.variablesReference }
}

struct EditorSymbolInformation: Identifiable {
  let id = UUID()
  let title: String
  let markdown: String
}

struct EditorSymbolLocationCollection: Identifiable {
  let id = UUID()
  let title: String
  let locations: [SourceLocation]
}

struct EditorProjectDiagnosticGroup: Identifiable {
  let url: URL
  let diagnostics: [Diagnostic]

  var id: URL { url }
}

struct EditorDebugConfiguration: Codable, Equatable, Sendable {
  var programPath: String
  var arguments: String
  var workingDirectory: String
  var stopOnEntry: Bool
  var buildBeforeLaunch: Bool
  var environment: [String: String]
  var terminalMode: EditorTerminalMode
  var adapterID: String?

  var argumentList: [String] { ShellArgumentParser.parse(arguments) }

  init(
    programPath: String,
    arguments: String,
    workingDirectory: String,
    stopOnEntry: Bool,
    buildBeforeLaunch: Bool = true,
    environment: [String: String] = [:],
    terminalMode: EditorTerminalMode = .integrated,
    adapterID: String? = nil
  ) {
    self.programPath = programPath
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.stopOnEntry = stopOnEntry
    self.buildBeforeLaunch = buildBeforeLaunch
    self.environment = environment
    self.terminalMode = terminalMode
    self.adapterID = adapterID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    programPath = try container.decode(String.self, forKey: .programPath)
    arguments = try container.decode(String.self, forKey: .arguments)
    workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
    stopOnEntry = try container.decode(Bool.self, forKey: .stopOnEntry)
    buildBeforeLaunch = try container.decodeIfPresent(Bool.self, forKey: .buildBeforeLaunch) ?? true
    environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    terminalMode =
      try container.decodeIfPresent(EditorTerminalMode.self, forKey: .terminalMode) ?? .integrated
    adapterID = try container.decodeIfPresent(String.self, forKey: .adapterID)
  }
}

@MainActor
final class EditorWorkspaceController: ObservableObject {
  typealias WorkspaceOpening =
    @MainActor (EditorServicesConfiguration) async throws -> EditorIDEWorkspace

  let workspaceURL: URL
  let serviceSettingsModel: EditorServicesSettingsModel
  let buildController: EditorBuildController
  let testController: EditorTestController
  let breakpointController: EditorBreakpointCoordinator
  let runConfigurationController: EditorRunConfigurationController
  let debugSessionController: EditorDebugSessionController

  @Published private(set) var tabs: [EditorTab] = []
  @Published var selectedTabID: EditorTab.ID? {
    didSet { scheduleSessionPersistence() }
  }
  @Published private(set) var phase: EditorWorkspacePhase = .idle
  @Published private(set) var runtimeState: WorkspaceRuntimeState = .idle
  @Published private(set) var serviceReport = EditorServiceAvailabilityReport()
  @Published private(set) var diagnosticsRevision = 0
  @Published private(set) var projectDiagnostics: [URL: [Diagnostic]] = [:]
  @Published private(set) var isPreparingBuildTask = false
  @Published private(set) var recentlyChangedSourceFiles: [URL] = []
  var debugPhase: EditorDebugPhase {
    get { debugSessionController.phase }
    set { debugSessionController.phase = newValue }
  }
  var liveDebugPhase: EditorLiveDebugPhase {
    liveDebugController?.phase ?? .disabled
  }
  @Published var isLiveDebugEnabled = false {
    didSet {
      UserDefaults.standard.set(
        isLiveDebugEnabled,
        forKey: Self.liveDebugPreferenceKey(workspaceURL: workspaceURL)
      )
      configureLiveDebugMonitoring()
    }
  }
  @Published private(set) var debugThreads: [DAPThread] = []
  @Published private(set) var debugFrames: [StackFrame] = []
  @Published private(set) var debugScopes: [EditorDebugScopeSnapshot] = []
  @Published private(set) var debugBreakpointVerification: [URL: [Breakpoint]] = [:]
  @Published private(set) var selectedDebugFrameID: Int?
  @Published private(set) var debugConsole: [String] = []
  @Published var fileOperationError: String?
  @Published var recoveryWarning: String?
  @Published var externalFileConflict: EditorExternalFileConflict?
  @Published var symbolInformation: EditorSymbolInformation?
  @Published var symbolLocations: EditorSymbolLocationCollection?
  @Published var debugConfiguration: EditorDebugConfiguration {
    didSet { EditorDebugPreferencesStore.save(debugConfiguration, workspaceURL: workspaceURL) }
  }
  var onVimSplit: ((Bool) -> Void)?
  var onVimCloseWindow: (() -> Void)?
  var onVimNewTab: (() -> Void)?
  var onVimCommand: ((EditorCommand) -> Void)?
  var capturePresentationSnapshot: (() -> WorkspacePresentationSnapshot)?
  var restorePresentationSnapshot: ((WorkspacePresentationSnapshot) -> Void)?

  @Published private(set) var activeThemeSlot: EditorThemeSlot
  @Published private(set) var usesWorkspaceThemeOverrides: Bool
  @Published var profile: EditorCustomProfile {
    didSet {
      themeProfiles[activeThemeSlot] = profile
      persistThemeProfile(profile, slot: activeThemeSlot)
      snippetLibrary = EditorSnippetLibrary(workspaceURL: workspaceURL, profile: profile.snippets)
      for tab in tabs { tab.updateSnippetLibrary(snippetLibrary) }
    }
  }

  private var servicesConfiguration: EditorServicesConfiguration
  private let servicesBaseEnvironment: [String: String]
  private var themeProfiles: [EditorThemeSlot: EditorCustomProfile]
  private let logStore = CalciteLogStore.shared
  private var snippetLibrary: EditorSnippetLibrary
  private let sessionStore: EditorWorkspaceSessionStore
  private let symbolResolver: EditorProjectSymbolResolver
  private let workspaceOpener: WorkspaceOpening
var ideWorkspace: EditorIDEWorkspace?
  private var projectDiagnosticsByService: [URL: [String: [Diagnostic]]] = [:]
  private let taskSupervisor = WorkspaceTaskSupervisor()
  private let stabilityRecorder = StabilityEventRecorder.shared
  private var serviceRecoveryPolicy = WorkspaceServiceRecoveryPolicy()
  private var startTask: Task<EditorIDEWorkspace, Error>?
  private var startGeneration = 0
  private var backendObservationGeneration: UInt64 = 0
  private var activeThreadID: Int?
  private var activeDebugSourceFingerprint: String? {
    get { debugSessionController.sourceFingerprint }
    set { debugSessionController.sourceFingerprint = newValue }
  }
  private var activeDebugLaunchTarget: EditorDebugLaunchTarget? {
    get { debugSessionController.launchTarget }
    set { debugSessionController.launchTarget = newValue }
  }
  private var activeDebugLanguage: EditorLanguage? {
    get { debugSessionController.language }
    set { debugSessionController.language = newValue }
  }
  private var debugSessionGeneration: UInt64 {
    get { debugSessionController.operationGeneration }
    set { debugSessionController.operationGeneration = newValue }
  }
  private var activeBackendDebugGeneration: UInt64? {
    get { debugSessionController.backendGeneration }
    set { debugSessionController.backendGeneration = newValue }
  }
  private var debugExecutionOperationID: UUID {
    get { debugSessionController.operationID }
    set { debugSessionController.operationID = newValue }
  }
  private var debugExecutionSessionID: UUID? {
    get { debugSessionController.sessionID }
    set { debugSessionController.sessionID = newValue }
  }
  private lazy var dapReverseRequestHost = EditorDAPReverseRequestHost(workspaceURL: workspaceURL)
  private var isReplacingDebugSession: Bool {
    get { debugSessionController.isReplacing }
    set { debugSessionController.isReplacing = newValue }
  }
  private var debugLaunchTarget: EditorDebugLaunchTarget = .project
  private(set) var liveDebugController: EditorLiveDebugController!
  private var openingDocumentURLs: Set<URL> = []
  private var externalConflictIDs: [URL: SourceFileID] = [:]
  private var pendingExternalFileConflicts: [EditorExternalFileConflict] = []
  private var projectContextRefreshGeneration: UInt64 = 0
  private struct ServicesReconfigurationRequest {
    var configuration: EditorServicesConfiguration
    var requiresSuccessfulSave: Bool
    var generation: UInt64
  }

  private var pendingReconfigurationRequest: ServicesReconfigurationRequest?
  private var reconfigurationGeneration: UInt64 = 0
  private var hasRestoredSession = false

  private var isShuttingDown: Bool {
    if case .shuttingDown = runtimeState { return true }
    return false
  }

  private var hasShutDown: Bool {
    if case .terminated = runtimeState { return true }
    return false
  }

  var hasUnsavedDocuments: Bool { tabs.contains(where: \.isDirty) }

  var activeTab: EditorTab? {
    guard let selectedTabID else { return nil }
    return tabs.first { $0.id == selectedTabID }
  }

  init(
    workspaceURL: URL,
    workspaceOpener: WorkspaceOpening? = nil
  ) {
    self.workspaceURL = workspaceURL.standardizedFileURL
    self.workspaceOpener = workspaceOpener ?? Self.openIDEWorkspace
    var configuration = EditorServicesConfiguration(
      workspaceURL: workspaceURL,
      languageSelection: .automatic,
      requirementPolicy: .bestEffort,
      completionStrategy: .mergeKeywordsAndFallbackOnError,
      completionLimit: 100,
      sourceWorkspaceMonitoringInterval: .seconds(1)
    )
    configuration.scanSourceWorkspaceOnConstruction = true
    configuration = EditorServicePreferencesStore.apply(
      EditorServicePreferencesStore.load(workspaceURL: workspaceURL),
      to: configuration
    )
    let servicesBaseEnvironment = configuration.environment
    let initialBuildProjectURL =
      EditorBuildProjectSelectionStore.load(workspaceURL: workspaceURL) ?? workspaceURL
    let initialPythonInterpreter = EditorPythonInterpreterSelectionStore.load(
      workspaceURL: initialBuildProjectURL
    )
    configuration.environment =
      EditorPythonEnvironmentResolver.activatedEnvironment(
        workspaceURL: initialBuildProjectURL,
        base: servicesBaseEnvironment,
        explicitInterpreterURL: initialPythonInterpreter
      ).environment
    let globalLightProfile = EditorProfileStore.load(slot: .light)
    let globalDarkProfile = EditorProfileStore.load(slot: .dark)
    let workspaceTheme = EditorWorkspaceThemeProfileStore.load(workspaceURL: workspaceURL)
    let lightProfile =
      workspaceTheme.isEnabled
      ? (workspaceTheme.light ?? globalLightProfile) : globalLightProfile
    let darkProfile =
      workspaceTheme.isEnabled
      ? (workspaceTheme.dark ?? globalDarkProfile) : globalDarkProfile
    let interfaceAppearance =
      EditorInterfaceAppearance(
        rawValue: UserDefaults.standard.string(forKey: "editorAppearanceMode") ?? ""
      ) ?? .system
    let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let initialThemeSlot: EditorThemeSlot
    switch interfaceAppearance {
    case .light: initialThemeSlot = .light
    case .dark: initialThemeSlot = .dark
    case .system: initialThemeSlot = systemIsDark ? .dark : .light
    }
    let loadedProfile = initialThemeSlot == .light ? lightProfile : darkProfile
    self.servicesConfiguration = configuration
    self.servicesBaseEnvironment = servicesBaseEnvironment
    self.activeThemeSlot = initialThemeSlot
    self.usesWorkspaceThemeOverrides = workspaceTheme.isEnabled
    self.themeProfiles = [.light: lightProfile, .dark: darkProfile]
    self.serviceSettingsModel = EditorServicesSettingsModel(configuration: configuration)
    self.sessionStore = EditorWorkspaceSessionStore(workspaceURL: workspaceURL)
    self.symbolResolver = EditorProjectSymbolResolver(workspaceURL: workspaceURL)
    self.profile = loadedProfile
    self.snippetLibrary = EditorSnippetLibrary(
      workspaceURL: workspaceURL,
      profile: loadedProfile.snippets
    )
    let buildController = EditorBuildController(workspaceURL: workspaceURL)
    self.buildController = buildController
    self.testController = EditorTestController(buildController: buildController)
    self.breakpointController = EditorBreakpointCoordinator(workspaceURL: workspaceURL)
    self.runConfigurationController = EditorRunConfigurationController(workspaceURL: workspaceURL)
    self.debugSessionController = EditorDebugSessionController()
    self.debugConfiguration =
      EditorDebugPreferencesStore.load(workspaceURL: workspaceURL)
      ?? EditorDebugConfiguration(
        programPath: "",
        arguments: "",
        workingDirectory: workspaceURL.path,
        stopOnEntry: false
      )
    self.isLiveDebugEnabled = UserDefaults.standard.bool(
      forKey: Self.liveDebugPreferenceKey(workspaceURL: workspaceURL)
    )
    self.buildController.onDiagnostics = { [weak self] diagnostics in
      self?.applyBuildDiagnostics(diagnostics)
    }
    let workspacePath = self.workspaceURL.path
    self.taskSupervisor.onEvent = { event in
      let lease: WorkspaceTaskLease
      let name: String
      switch event {
      case .started(let value):
        lease = value
        name = "task-started"
      case .cancelled(let value):
        lease = value
        name = "task-cancelled"
      case .finished(let value):
        lease = value
        name = "task-finished"
      }
      StabilityEventRecorder.shared.record(
        .task,
        name,
        metadata: [
          "key": lease.key.description,
          "generation": String(lease.generation),
          "workspace": workspacePath,
        ]
      )
    }
    self.liveDebugController = EditorLiveDebugController(
      rootResolver: { [weak self] target in
        self?.liveDebugRoots(for: target) ?? []
      },
      filter: { [weak self] url, target in
        self?.shouldTriggerLiveDebug(for: url, target: target) ?? false
      },
      applyChanges: { [weak self] batch, generation in
        guard let self else { return }
        await self.restartDebuggingForLiveChanges(batch: batch, generation: generation)
      }
    )
    self.buildController.onBuildProjectChange = { [weak self] in
      self?.configureLiveDebugMonitoring()
    }
  }

  private static func openIDEWorkspace(
    configuration: EditorServicesConfiguration
  ) async throws -> EditorIDEWorkspace {
    try await EditorIDEWorkspace.open(
      configuration: configuration,
      documentConfiguration: .init(
        analysisDebounce: .milliseconds(70),
        semanticAnalysisDebounce: .milliseconds(500),
        includeSemanticHighlights: true
      )
    )
  }

  var activeRuntimeTaskCount: Int { taskSupervisor.activeCount }

  func exportStabilityReport(to url: URL) throws {
    try stabilityRecorder.export(to: url)
  }

  private func transitionRuntime(
    to next: WorkspaceRuntimeState,
    detail: String? = nil
  ) {
    let previous = runtimeState
    guard previous.permitsTransition(to: next) else {
      stabilityRecorder.record(
        .warning,
        "invalid-runtime-transition",
        detail: "\(previous) -> \(next)",
        metadata: ["workspace": workspaceURL.path]
      )
      return
    }
    runtimeState = next
    switch next {
    case .idle, .terminated:
      phase = .idle
    case .starting, .preparingReconfiguration, .committingReconfiguration:
      phase = .starting
    case .running:
      phase = .ready
    case .shuttingDown:
      break
    case .failed(let message):
      phase = .failed(message)
    }
    stabilityRecorder.record(
      .lifecycle,
      "runtime-transition",
      detail: detail,
      metadata: [
        "from": String(describing: previous),
        "to": String(describing: next),
        "workspace": workspaceURL.path,
      ]
    )
  }

  isolated deinit {
    liveDebugController?.stop()
    startTask?.cancel()
    startTask = nil
    startGeneration &+= 1
  }

  func start() async {
    guard !isShuttingDown, !hasShutDown else { return }
    if runtimeState == .running { return }
    let operationID: UUID?

    if startTask == nil {
      transitionRuntime(to: .starting(UUID()), detail: "start requested")
      operationID = logStore.beginOperation(
        "Preparing editor services",
        category: "Workspace",
        detail: workspaceURL.path
      )
      startGeneration &+= 1
      let configuration = servicesConfiguration
      let workspaceOpener = self.workspaceOpener
      startTask = Task {
        try await workspaceOpener(configuration)
      }
    } else {
      operationID = nil
    }

    guard let task = startTask else { return }
    let generation = startGeneration
    do {
      let workspace = try await task.value
      guard generation == startGeneration, !isShuttingDown else {
        try? await workspace.shutdown()
        if let operationID {
          logStore.finishOperation(
            operationID, level: .notice, message: "Editor startup superseded")
        }
        return
      }
      if ideWorkspace == nil {
        ideWorkspace = workspace
        serviceReport = workspace.serviceResult.report
        observeBackend(workspace.backend)
      }
      transitionRuntime(to: .running, detail: "editor services ready")
      let externalReport = await workspace.backend.externalSourceIndexReport()
      let workspaceFileCount = await workspace.backend.sourceWorkspace.files().count
      if let operationID {
        logStore.finishOperation(
          operationID,
          message: "Editor services ready",
          metadata: [
            "workspace_files": String(workspaceFileCount),
            "external_packages": String(externalReport.packageCount),
            "external_files": String(externalReport.indexedFileCount),
          ]
        )
      }
      if !hasRestoredSession {
        hasRestoredSession = true
        await restoreWorkspaceSession()
        scheduleSessionPersistence()
      }
      configureLiveDebugMonitoring()
    } catch is CancellationError {
      guard generation == startGeneration else {
        if let operationID {
          logStore.finishOperation(
            operationID, level: .notice, message: "Editor startup superseded")
        }
        return
      }
      if ideWorkspace == nil {
        transitionRuntime(to: .idle, detail: "startup cancelled")
      }
      if let operationID {
        logStore.finishOperation(operationID, level: .notice, message: "Editor startup cancelled")
      }
    } catch {
      guard generation == startGeneration else {
        if let operationID {
          logStore.finishOperation(
            operationID, level: .notice, message: "Editor startup superseded")
        }
        return
      }
      transitionRuntime(to: .failed(error.localizedDescription), detail: "startup failed")
      if let operationID {
        logStore.finishOperation(operationID, level: .error, message: error.localizedDescription)
      }
    }
    if generation == startGeneration { startTask = nil }
  }

  func applyServicesConfiguration(_ configuration: EditorServicesConfiguration) {
    enqueueServicesReconfiguration(configuration, requiresSuccessfulSave: true)
  }

  private func enqueueServicesReconfiguration(
    _ configuration: EditorServicesConfiguration,
    requiresSuccessfulSave: Bool
  ) {
    guard !isShuttingDown, !hasShutDown else { return }
    var configuration = configuration
    configuration.environment = resolvedPythonProcessEnvironment()
    reconfigurationGeneration &+= 1
    let generation = reconfigurationGeneration
    if let pending = pendingReconfigurationRequest {
      pendingReconfigurationRequest = ServicesReconfigurationRequest(
        configuration: configuration,
        requiresSuccessfulSave: pending.requiresSuccessfulSave && requiresSuccessfulSave,
        generation: generation
      )
    } else {
      pendingReconfigurationRequest = ServicesReconfigurationRequest(
        configuration: configuration,
        requiresSuccessfulSave: requiresSuccessfulSave,
        generation: generation
      )
    }
    taskSupervisor.replace(.reconfiguration) { [weak self] lease in
      guard let self else { return }
      while !Task.isCancelled, self.taskSupervisor.isCurrent(lease),
        let request = self.pendingReconfigurationRequest
      {
        self.pendingReconfigurationRequest = nil
        await self.reconfigure(using: request)
      }
    }
  }

  func openDocument(at url: URL) async {
    guard !isShuttingDown, !hasShutDown else { return }
    let key = url.standardizedFileURL
    guard isRegularFile(key) else { return }
    if let existing = tabs.first(where: { $0.url.standardizedFileURL == key }) {
      selectedTabID = existing.id
      return
    }
    guard openingDocumentURLs.insert(key).inserted else { return }
    defer { openingDocumentURLs.remove(key) }

    if phase != .ready { await start() }
    guard let ideWorkspace else { return }

    do {
      let tab = try await makeEditorTab(at: key, using: ideWorkspace)
      withAnimation(.snappy(duration: 0.22, extraBounce: 0.08)) {
        tabs.append(tab)
        selectedTabID = tab.id
      }
      scheduleSessionPersistence()
      fileOperationError = nil
    } catch {
      fileOperationError = "Could not open \(key.lastPathComponent): \(error.localizedDescription)"
      appendDebugMessage(fileOperationError ?? error.localizedDescription)
    }
  }

  private func makeEditorTab(
    at url: URL,
    using workspace: EditorIDEWorkspace,
    id: UUID = UUID(),
    selectedRange: NSRange? = nil,
    attachCallbacks: Bool = true
  ) async throws -> EditorTab {
    let key = url.standardizedFileURL
    let languageID = EditorLanguageCatalog.standard.languageID(for: key)
    let pipeline = try await workspace.openDocument(at: key, languageID: languageID)
    let tab = try await EditorTab.open(
      pipeline: pipeline,
      snippetLibrary: snippetLibrary,
      id: id
    )
    if let selectedRange {
      let length = (tab.text as NSString).length
      let location = min(max(0, selectedRange.location), length)
      let selectionLength = min(max(0, selectedRange.length), length - location)
      tab.updateSelection(NSRange(location: location, length: selectionLength))
    }
    if attachCallbacks { configureEditorTabCallbacks(tab) }
    tab.setBuildDiagnostics(
      buildController.diagnostics.filter { $0.url.standardizedFileURL == key }
    )
    return tab
  }

  private func configureEditorTabCallbacks(_ tab: EditorTab) {
    tab.onDiagnosticsChange = { [weak self] in
      self?.diagnosticsRevision &+= 1
    }
    tab.onContentStateChange = { [weak self, weak tab] in
      guard let self else { return }
      self.scheduleSessionPersistence()
      guard self.isLiveDebugEnabled, let tab else { return }
      self.liveDebugController.enqueueFullRestart(
        for: [tab.url.standardizedFileURL]
      )
    }
  }

  func closeTab(_ tab: EditorTab, saving: Bool = false) {
    let key = WorkspaceTaskKey.tabOperation(tab.id)
    guard !isShuttingDown, !hasShutDown, !taskSupervisor.contains(key) else { return }
    taskSupervisor.replace(key) { [weak self, weak tab] lease in
      guard let self, let tab, self.taskSupervisor.isCurrent(lease) else { return }
      if saving, !(await tab.save()) { return }
      guard !Task.isCancelled, self.taskSupervisor.isCurrent(lease) else { return }
      await tab.close()
      try? await self.ideWorkspace?.closeDocument(at: tab.url)
      guard !Task.isCancelled, self.taskSupervisor.isCurrent(lease) else { return }
      let removeTab = {
        self.tabs.removeAll { $0.id == tab.id }
        if self.selectedTabID == tab.id {
          self.selectedTabID = self.tabs.last?.id
        }
      }
      if self.isShuttingDown {
        removeTab()
      } else {
        withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
          removeTab()
        }
        self.scheduleSessionPersistence()
      }
    }
  }

  func saveActiveDocument() {
    guard let activeTab else { return }
    taskSupervisor.replace(.auxiliary("save-active-\(activeTab.id.uuidString)")) {
      [weak activeTab] _ in
      _ = await activeTab?.save()
    }
  }

  @discardableResult
  func saveAllDocuments() async -> Bool {
    var succeeded = true
    for tab in tabs {
      if !(await tab.save()) { succeeded = false }
    }
    return succeeded
  }

  private func prepareWorkspaceForExecution(
    _ reason: EditorExecutionPreparationReason
  ) async throws -> EditorPreparedSourceSnapshot {
    NotificationCenter.default.post(name: .calciteCommitEditorStateForExecution, object: nil)
    await Task.yield()

    var openDocuments: [URL: (revision: UInt64, text: String)] = [:]
    for tab in tabs {
      guard await tab.save() else {
        throw EditorExecutionIntegrityError.documentSaveFailed(tab.title)
      }
      let key = tab.url.standardizedFileURL
      openDocuments[key] = (revision: tab.textRevision, text: tab.text)
    }

    let root = buildController.buildProjectURL.standardizedFileURL
    let snapshot = try EditorWorkspaceSourceScanner.snapshot(
      workspaceURL: root,
      reason: reason,
      openDocuments: openDocuments
    )
    stabilityRecorder.record(
      .lifecycle,
      "execution-source-prepared",
      metadata: [
        "reason": reason.rawValue,
        "fingerprint": snapshot.fingerprint,
        "documents": String(snapshot.documentCount),
        "workspace": root.path,
      ]
    )
    return snapshot
  }

  private func prepareSingleFileForExecution(
    _ fileURL: URL,
    reason: EditorExecutionPreparationReason
  ) async throws -> EditorPreparedSourceSnapshot {
    NotificationCenter.default.post(name: .calciteCommitEditorStateForExecution, object: nil)
    await Task.yield()

    let key = fileURL.standardizedFileURL
    let tab = tabs.first { $0.url.standardizedFileURL == key }
    if let tab, !(await tab.save()) {
      throw EditorExecutionIntegrityError.documentSaveFailed(tab.title)
    }
    let snapshot = try EditorWorkspaceSourceScanner.snapshot(
      fileURL: key,
      reason: reason,
      openDocument: tab.map { (revision: $0.textRevision, text: $0.text) }
    )
    stabilityRecorder.record(
      .lifecycle,
      "single-file-source-prepared",
      metadata: [
        "reason": reason.rawValue,
        "fingerprint": snapshot.fingerprint,
        "file": key.path,
      ]
    )
    return snapshot
  }

  @discardableResult
  private func acceptSuccessfulExecution(
    sourceSnapshot: EditorPreparedSourceSnapshot
  ) -> Bool {
    for document in sourceSnapshot.documents where document.revision != nil {
      guard
        let tab = tabs.first(where: {
          $0.url.standardizedFileURL == document.url.standardizedFileURL
        })
      else { continue }
      let currentHash = EditorSourceFingerprint.hash(Data(tab.text.utf8))
      if tab.textRevision != document.revision || currentHash != document.contentHash {
        buildController.invalidateLastArtifact(
          "\(document.url.lastPathComponent) changed while the task was running."
        )
        return false
      }
    }
    clearSupersededServiceDiagnosticsAfterSuccessfulBuild()
    return true
  }

  private func runConfiguredTasks(
    _ identifiers: [String],
    stage: String,
    sourceSnapshot: EditorPreparedSourceSnapshot?
  ) async -> Bool {
    guard !identifiers.isEmpty else { return true }
    let resolved = runConfigurationController.taskCommands(
      identifiers,
      plan: buildController.plan
    )
    if !resolved.missing.isEmpty {
      let message = "\(stage) task(s) not found: " + resolved.missing.joined(separator: ", ")
      appendDebugMessage(message, channel: .system, severity: .error)
      buildController.reportPreparationFailure(message)
      return false
    }
    for command in resolved.commands {
      guard !Task.isCancelled else { return false }
      appendDebugMessage(
        "Running \(stage.lowercased()) task: \(command.title)",
        channel: .system
      )
      guard await buildController.run(command, sourceSnapshot: sourceSnapshot) else {
        appendDebugMessage(
          "\(stage) task failed: \(command.title)",
          channel: .system,
          severity: .error
        )
        return false
      }
    }
    return true
  }

  private func runPreLaunchTasks(
    target: EditorExecutionTargetKind,
    sourceSnapshot: EditorPreparedSourceSnapshot?
  ) async -> Bool {
    guard let configuration = runConfigurationController.configuration(for: target) else {
      return true
    }
    return await runConfiguredTasks(
      configuration.preLaunchTaskIDs,
      stage: "Pre-launch",
      sourceSnapshot: sourceSnapshot
    )
  }

  private func runPostDebugTasks(
    target: EditorExecutionTargetKind
  ) async {
    guard let configuration = runConfigurationController.configuration(for: target) else {
      return
    }
    _ = await runConfiguredTasks(
      configuration.postDebugTaskIDs,
      stage: "Post-debug",
      sourceSnapshot: nil
    )
  }

  func runCurrentFile() {
    guard let fileURL = activeTab?.url,
      EditorBuildDiscovery.singleFileResolution(
        fileURL: fileURL,
        workspaceURL: workspaceURL
      ).runnablePlan != nil,
      !taskSupervisor.contains(.buildLaunch),
      !buildController.phase.isRunning
    else { return }

    runConfigurationController.select(target: .currentFile)
    let runConfiguration = runConfigurationController.configuration(for: .currentFile)
    isPreparingBuildTask = true
    taskSupervisor.replace(.buildLaunch) { [weak self] lease in
      guard let self else { return }
      defer { self.isPreparingBuildTask = false }
      do {
        let snapshot = try await self.prepareSingleFileForExecution(
          fileURL, reason: .singleFileRun
        )
        guard !Task.isCancelled, self.taskSupervisor.isCurrent(lease) else { return }
        guard await self.runPreLaunchTasks(target: .currentFile, sourceSnapshot: snapshot) else {
          return
        }
        self.isPreparingBuildTask = false
        let runtimeWorkingDirectory = runConfiguration.flatMap { configuration -> URL? in
          let path = NSString(string: configuration.workingDirectory).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
          return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        }
        if await self.buildController.runSingleFile(
          fileURL,
          kind: .run,
          sourceSnapshot: snapshot,
          runtimeArguments: runConfiguration?.arguments ?? [],
          runtimeEnvironment: runConfiguration?.environment ?? [:],
          runtimeWorkingDirectory: runtimeWorkingDirectory
        ), self.taskSupervisor.isCurrent(lease) {
          _ = self.acceptSuccessfulExecution(sourceSnapshot: snapshot)
        }
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.buildController.reportPreparationFailure(error.localizedDescription)
      }
    }
  }

  func createFile(in directory: URL, name: String) async -> Bool {
    await performFileOperation("Create file") { backend in
      let url = try self.childURL(named: name, in: directory)
      let relative = try self.relativePath(for: url)
      _ = try await backend.createSourceFile(
        at: relative,
        languageID: EditorLanguageCatalog.standard.languageID(for: url)
      )
    }
  }

  func createDirectory(in directory: URL, name: String) async -> Bool {
    await performFileOperation("Create folder") { backend in
      let url = try self.childURL(named: name, in: directory)
      try await backend.createSourceDirectory(at: self.relativePath(for: url))
    }
  }

  func renameItem(at url: URL, to name: String) async -> Bool {
    await performFileOperation("Rename") { backend in
      let source = url.standardizedFileURL
      let destination = try self.childURL(
        named: name,
        in: source.deletingLastPathComponent()
      )
      let reopenURLs = try await self.prepareTabsForMove(
        from: source,
        to: destination
      )
      do {
        try await self.moveItemUsingBackend(
          backend,
          from: source,
          to: destination
        )
      } catch {
        await self.reopenDocuments(reopenURLs.map(\.source))
        throw error
      }
      EditorBreakpointStore.move(from: source, to: destination)
      await self.reopenDocuments(reopenURLs.map(\.destination))
    }
  }

  func duplicateFile(at url: URL) async -> Bool {
    await performFileOperation("Duplicate") { _ in
      let source = url.standardizedFileURL
      let destination = try self.availableDuplicateURL(for: source)
      try await Task.detached(priority: .userInitiated) {
        try FileManager.default.copyItem(at: source, to: destination)
      }.value
    }
  }

  func deleteItem(at url: URL) async -> Bool {
    await performFileOperation("Delete") { backend in
      let target = url.standardizedFileURL
      try await self.removeItemUsingBackend(backend, at: target)
      EditorBreakpointStore.remove(under: target)
      await self.removeOpenTabs(under: target)
      self.scheduleSessionPersistence()
    }
  }

  func hasUnsavedChanges(under url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    return tabs.contains { tab in
      let tabPath = tab.url.standardizedFileURL.path
      return tab.isDirty && (tabPath == path || tabPath.hasPrefix(path + "/"))
    }
  }

  func resolvedBuildTask(_ kind: EditorBuildTaskKind) -> EditorBuildTaskTarget? {
    EditorBuildTaskResolver.resolve(
      projectPlan: buildController.plan,
      activeFileURL: activeTab?.url,
      kind: kind
    )
  }

  func runBuildTask(_ kind: EditorBuildTaskKind) {
    guard !taskSupervisor.contains(.buildLaunch), !buildController.phase.isRunning else { return }
    isPreparingBuildTask = true
    taskSupervisor.replace(.buildLaunch) { [weak self] lease in
      guard let self else { return }
      defer { self.isPreparingBuildTask = false }
      do {
        let reason: EditorExecutionPreparationReason =
          switch kind {
          case .run: .run
          case .test: .test
          case .build, .check, .clean, .custom: .build
          }
        let snapshot = try await self.prepareWorkspaceForExecution(reason)
        guard !Task.isCancelled, self.taskSupervisor.isCurrent(lease),
          let target = self.resolvedBuildTask(kind)
        else { return }
        self.isPreparingBuildTask = false
        switch target {
        case .project(let command):
          let succeeded: Bool
          if kind == .test {
            succeeded = await self.testController.runAll(sourceSnapshot: snapshot)
          } else if kind == .run {
            guard await self.runPreLaunchTasks(target: .project, sourceSnapshot: snapshot) else {
              return
            }
            let configured = self.runConfigurationController.configuredCommand(
              command, target: .project, plan: self.buildController.plan
            )
            succeeded = await self.buildController.run(configured, sourceSnapshot: snapshot)
          } else {
            succeeded = await self.buildController.run(command, sourceSnapshot: snapshot)
          }
          if succeeded, self.taskSupervisor.isCurrent(lease) {
            _ = self.acceptSuccessfulExecution(sourceSnapshot: snapshot)
          }
        case .standalone(let fileURL, _):
          let configuration =
            kind == .run
            ? self.runConfigurationController.configuration(for: .currentFile) : nil
          let runtimeWorkingDirectory = configuration.flatMap { value -> URL? in
            let path = NSString(string: value.workingDirectory).expandingTildeInPath
              .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
          }
          if kind == .run,
            !(await self.runPreLaunchTasks(target: .currentFile, sourceSnapshot: snapshot))
          {
            return
          }
          if await self.buildController.runSingleFile(
            fileURL,
            kind: kind,
            sourceSnapshot: snapshot,
            runtimeArguments: configuration?.arguments ?? [],
            runtimeEnvironment: configuration?.environment ?? [:],
            runtimeWorkingDirectory: runtimeWorkingDirectory
          ), self.taskSupervisor.isCurrent(lease) {
            _ = self.acceptSuccessfulExecution(sourceSnapshot: snapshot)
          }
        }
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.buildController.reportPreparationFailure(error.localizedDescription)
      }
    }
  }

  func runSelectedBuildTask() {
    guard !taskSupervisor.contains(.buildLaunch), !buildController.phase.isRunning else { return }
    isPreparingBuildTask = true
    taskSupervisor.replace(.buildLaunch) { [weak self] lease in
      guard let self else { return }
      defer { self.isPreparingBuildTask = false }
      do {
        let snapshot = try await self.prepareWorkspaceForExecution(.run)
        guard !Task.isCancelled, self.taskSupervisor.isCurrent(lease) else { return }
        self.isPreparingBuildTask = false
        if let selected = self.buildController.selectedCommand {
          if selected.kind == .run,
            !(await self.runPreLaunchTasks(target: .project, sourceSnapshot: snapshot))
          {
            return
          }
          let command =
            selected.kind == .run
            ? self.runConfigurationController.configuredCommand(
              selected,
              target: .project,
              plan: self.buildController.plan
            )
            : selected
          if await self.buildController.run(command, sourceSnapshot: snapshot),
            self.taskSupervisor.isCurrent(lease)
          {
            _ = self.acceptSuccessfulExecution(sourceSnapshot: snapshot)
          }
        } else if let target = self.resolvedBuildTask(.run) {
          switch target {
          case .project(let command):
            guard await self.runPreLaunchTasks(target: .project, sourceSnapshot: snapshot) else {
              return
            }
            let configured = self.runConfigurationController.configuredCommand(
              command,
              target: .project,
              plan: self.buildController.plan
            )
            if await self.buildController.run(configured, sourceSnapshot: snapshot),
              self.taskSupervisor.isCurrent(lease)
            {
              _ = self.acceptSuccessfulExecution(sourceSnapshot: snapshot)
            }
          case .standalone(let fileURL, _):
            let configuration = self.runConfigurationController.configuration(for: .currentFile)
            let runtimeWorkingDirectory = configuration.flatMap { value -> URL? in
              let path = NSString(string: value.workingDirectory).expandingTildeInPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
              return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
            }
            guard
              await self.runPreLaunchTasks(
                target: .currentFile,
                sourceSnapshot: snapshot
              )
            else { return }
            if await self.buildController.runSingleFile(
              fileURL,
              kind: .run,
              sourceSnapshot: snapshot,
              runtimeArguments: configuration?.arguments ?? [],
              runtimeEnvironment: configuration?.environment ?? [:],
              runtimeWorkingDirectory: runtimeWorkingDirectory
            ), self.taskSupervisor.isCurrent(lease) {
              _ = self.acceptSuccessfulExecution(sourceSnapshot: snapshot)
            }
          }
        }
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.buildController.reportPreparationFailure(error.localizedDescription)
      }
    }
  }

  func runTestsInCurrentFile() {
    guard let fileURL = activeTab?.url,
      !taskSupervisor.contains(.buildLaunch),
      !buildController.phase.isRunning
    else { return }
    isPreparingBuildTask = true
    taskSupervisor.replace(.buildLaunch) { [weak self] lease in
      guard let self else { return }
      defer { self.isPreparingBuildTask = false }
      do {
        let snapshot = try await self.prepareWorkspaceForExecution(.test)
        guard !Task.isCancelled, self.taskSupervisor.isCurrent(lease) else { return }
        self.isPreparingBuildTask = false
        if await self.testController.runCurrentFile(fileURL, sourceSnapshot: snapshot),
          self.taskSupervisor.isCurrent(lease)
        {
          _ = self.acceptSuccessfulExecution(sourceSnapshot: snapshot)
        }
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.buildController.reportPreparationFailure(error.localizedDescription)
      }
    }
  }

  func runTestAtCurrentSymbol() {
    guard let tab = activeTab,
      !taskSupervisor.contains(.buildLaunch),
      !buildController.phase.isRunning
    else { return }
    isPreparingBuildTask = true
    taskSupervisor.replace(.buildLaunch) { [weak self, weak tab] lease in
      guard let self, let tab else { return }
      defer { self.isPreparingBuildTask = false }
      do {
        guard let symbol = try await tab.documentSymbolAtSelection() else {
          self.buildController.reportPreparationFailure(
            "No test symbol could be resolved at the current cursor position."
          )
          return
        }
        let snapshot = try await self.prepareWorkspaceForExecution(.test)
        guard !Task.isCancelled, self.taskSupervisor.isCurrent(lease) else { return }
        self.isPreparingBuildTask = false
        if await self.testController.runCurrentSymbol(
          symbol.name,
          fileURL: tab.url,
          sourceSnapshot: snapshot
        ), self.taskSupervisor.isCurrent(lease) {
          _ = self.acceptSuccessfulExecution(sourceSnapshot: snapshot)
        }
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.buildController.reportPreparationFailure(error.localizedDescription)
      }
    }
  }

  func rerunFailedTests() {
    guard !taskSupervisor.contains(.buildLaunch), !buildController.phase.isRunning else { return }
    isPreparingBuildTask = true
    taskSupervisor.replace(.buildLaunch) { [weak self] lease in
      guard let self else { return }
      defer { self.isPreparingBuildTask = false }
      do {
        let snapshot = try await self.prepareWorkspaceForExecution(.test)
        guard !Task.isCancelled, self.taskSupervisor.isCurrent(lease) else { return }
        self.isPreparingBuildTask = false
        if await self.testController.rerunFailed(sourceSnapshot: snapshot),
          self.taskSupervisor.isCurrent(lease)
        {
          _ = self.acceptSuccessfulExecution(sourceSnapshot: snapshot)
        }
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.buildController.reportPreparationFailure(error.localizedDescription)
      }
    }
  }

  func debugTestsInCurrentFile() {
    guard let fileURL = activeTab?.url else { return }
    guard !isLiveDebugEnabled else {
      appendDebugMessage(
        "Stop Live Debug before starting a test debug session.",
        channel: .debugger,
        severity: .warning
      )
      return
    }
    switch debugPhase {
    case .idle, .failed:
      runDebugOperation { await self.beginDebuggingTests(in: fileURL) }
    case .starting, .running, .stopped:
      appendDebugMessage(
        "Stop the current debug session before debugging tests.",
        channel: .debugger,
        severity: .warning
      )
    }
  }

  func debugTestAtCurrentSymbol() {
    guard let tab = activeTab else { return }
    guard !isLiveDebugEnabled else {
      appendDebugMessage(
        "Stop Live Debug before starting a test debug session.",
        channel: .debugger,
        severity: .warning
      )
      return
    }
    switch debugPhase {
    case .idle, .failed:
      runDebugOperation { [weak tab] in
        guard let tab else { return }
        do {
          guard let symbol = try await tab.documentSymbolAtSelection() else {
            self.appendDebugMessage(
              "No test symbol could be resolved at the current cursor position.",
              channel: .test,
              severity: .warning
            )
            return
          }
          await self.beginDebuggingTests(in: tab.url, symbol: symbol.name)
        } catch {
          self.appendDebugMessage(
            "Test symbol resolution failed: \(error.localizedDescription)",
            channel: .test,
            severity: .error
          )
        }
      }
    case .starting, .running, .stopped:
      appendDebugMessage(
        "Stop the current debug session before debugging tests.",
        channel: .debugger,
        severity: .warning
      )
    }
  }

  private func beginDebuggingTests(in fileURL: URL, symbol: String? = nil) async {
    guard let workspace = ideWorkspace else { return }
    do {
      let snapshot = try await prepareWorkspaceForExecution(.test)
      let plan = try EditorTestDebugPlanner.plan(
        projectKind: buildController.plan.projectKind,
        projectPlan: buildController.plan,
        fileURL: fileURL,
        workspaceURL: buildController.buildProjectURL,
        symbol: symbol
      )
      guard await runPreLaunchTasks(target: .project, sourceSnapshot: snapshot) else {
        throw EditorExecutionIntegrityError.configuration("A pre-launch task failed.")
      }
      var nativeArtifact: URL?
      if let command = plan.buildCommand {
        appendDebugMessage(plan.title, channel: .test)
        guard await buildController.run(command, sourceSnapshot: snapshot) else {
          throw EditorExecutionIntegrityError.configuration(
            "The test build failed. Open the Build panel for details."
          )
        }
        guard acceptSuccessfulExecution(sourceSnapshot: snapshot) else {
          throw EditorExecutionIntegrityError.configuration(
            "The source changed while the test executable was being built."
          )
        }
        nativeArtifact = await EditorTestDebugPlanner.nativeTestArtifact(
          projectKind: buildController.plan.projectKind,
          workspaceURL: buildController.buildProjectURL,
          buildOutput: buildController.output,
          buildCommand: command
        )
      }

      try? await workspace.backend.disconnectDebugger()
      debugExecutionOperationID = UUID()
      debugExecutionSessionID = UUID()
      debugPhase = .starting
      debugBreakpointVerification.removeAll(keepingCapacity: true)
      let configuration = effectiveDebugConfiguration(for: .project)
      let adapterID =
        configuration.adapterID?
        .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? workspace.serviceResult.debugAdapter(for: plan.language)?.defaultAdapterID
        ?? plan.language.rawValue
      let prepared = try await workspace.serviceResult.prepareDebugger(
        for: plan.language,
        initializeArguments: InitializeArguments(
          adapterID: adapterID,
          clientID: "Calcite",
          clientName: "Calcite",
          supportsRunInTerminalRequest: true
        ),
        reverseRequestHandler: dapReverseRequestHost
      )
      do {
        let launchArguments = try EditorTestDebugPlanner.launchArguments(
          plan: plan,
          adapterID: adapterID,
          configuration: configuration,
          nativeArtifact: nativeArtifact
        )
        try await prepared.launch(arguments: launchArguments)
        try await synchronizeBreakpoints(using: prepared)
        try await prepared.finishConfiguration()
        try await workspace.backend.adoptPreparedDebugger(prepared)
      } catch {
        await prepared.discard()
        throw error
      }
      activeBackendDebugGeneration = await workspace.backend.currentDebugSessionGeneration()
      activeDebugSourceFingerprint = snapshot.fingerprint
      activeDebugLanguage = plan.language
      activeDebugLaunchTarget = .project
      debugSessionGeneration &+= 1
      await registerActiveDebugProcess(backend: workspace.backend, live: false)
      debugPhase = .running
      appendDebugMessage(
        "Started test debugger with \(adapterID) for "
          + (symbol.map { "\(fileURL.lastPathComponent)::\($0)" }
            ?? fileURL.lastPathComponent) + ".",
        channel: .test
      )
    } catch {
      try? await workspace.backend.disconnectDebugger()
      await dapReverseRequestHost.terminateActiveTerminalProcess()
      activeThreadID = nil
      activeBackendDebugGeneration = nil
      activeDebugSourceFingerprint = nil
      debugExecutionSessionID = nil
      activeDebugLanguage = nil
      activeDebugLaunchTarget = nil
      debugPhase = .failed(error.localizedDescription)
      appendDebugMessage(
        "Test debug failed: \(error.localizedDescription)",
        channel: .test,
        severity: .error
      )
    }
  }

  func runTestsForChangedFiles() {
    guard !recentlyChangedSourceFiles.isEmpty,
      !taskSupervisor.contains(.buildLaunch),
      !buildController.phase.isRunning
    else { return }
    let files = recentlyChangedSourceFiles
    isPreparingBuildTask = true
    taskSupervisor.replace(.buildLaunch) { [weak self] lease in
      guard let self else { return }
      defer { self.isPreparingBuildTask = false }
      do {
        let snapshot = try await self.prepareWorkspaceForExecution(.test)
        guard !Task.isCancelled, self.taskSupervisor.isCurrent(lease) else { return }
        self.isPreparingBuildTask = false
        if await self.testController.runChangedFiles(files, sourceSnapshot: snapshot),
          self.taskSupervisor.isCurrent(lease)
        {
          _ = self.acceptSuccessfulExecution(sourceSnapshot: snapshot)
          self.recentlyChangedSourceFiles.removeAll(keepingCapacity: true)
        }
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.buildController.reportPreparationFailure(error.localizedDescription)
      }
    }
  }

  func cancelBuildTask() {
    taskSupervisor.cancel(.buildLaunch)
    isPreparingBuildTask = false
    buildController.cancel()
  }

  func openExecutionSource(_ location: EditorExecutionSourceLocation) {
    runAuxiliaryTask("open-execution-source") { [weak self] lease in
      guard let self else { return }
      await self.openDocument(at: location.url)
      guard self.taskSupervisor.isCurrent(lease),
        let tab = self.tabs.first(where: {
          $0.url.standardizedFileURL == location.url.standardizedFileURL
        })
      else { return }
      let snapshot = TextSnapshot(text: tab.text)
      let position = TextPosition(
        line: max(0, location.line - 1),
        utf16Column: max(0, location.column - 1)
      )
      if let offset = try? snapshot.utf16Offset(of: position) {
        tab.updateSelection(NSRange(location: offset, length: 0))
      }
    }
  }

  func openBuildDiagnostic(_ diagnostic: EditorBuildDiagnostic) {
    runAuxiliaryTask("open-build-diagnostic") { [weak self] lease in
      guard let self else { return }
      await self.openDocument(at: diagnostic.url)
      guard self.taskSupervisor.isCurrent(lease),
        let tab = self.tabs.first(where: {
          $0.url.standardizedFileURL == diagnostic.url.standardizedFileURL
        })
      else { return }
      let snapshot = TextSnapshot(text: tab.text)
      let position = TextPosition(
        line: max(0, diagnostic.line - 1),
        utf16Column: max(0, diagnostic.column - 1)
      )
      if let offset = try? snapshot.utf16Offset(of: position) {
        tab.updateSelection(NSRange(location: offset, length: 0))
      }
    }
  }

  func profile(for slot: EditorThemeSlot) -> EditorCustomProfile {
    themeProfiles[slot] ?? (slot == .light ? .light : .standard)
  }

  func setProfile(_ value: EditorCustomProfile, for slot: EditorThemeSlot) {
    themeProfiles[slot] = value
    persistThemeProfile(value, slot: slot)
    if activeThemeSlot == slot {
      profile = value
    }
  }

  func setUsesWorkspaceThemeOverrides(_ enabled: Bool) {
    guard usesWorkspaceThemeOverrides != enabled else { return }
    themeProfiles[activeThemeSlot] = profile
    if enabled {
      usesWorkspaceThemeOverrides = true
      EditorWorkspaceThemeProfileStore.setEnabled(
        true,
        workspaceURL: workspaceURL,
        light: themeProfiles[.light],
        dark: themeProfiles[.dark]
      )
    } else {
      EditorWorkspaceThemeProfileStore.setEnabled(false, workspaceURL: workspaceURL)
      usesWorkspaceThemeOverrides = false
      themeProfiles = [
        .light: EditorProfileStore.load(slot: .light),
        .dark: EditorProfileStore.load(slot: .dark),
      ]
      profile =
        themeProfiles[activeThemeSlot]
        ?? (activeThemeSlot == .light ? .light : .standard)
    }
  }

  func activateThemeSlot(_ slot: EditorThemeSlot) {
    guard activeThemeSlot != slot else { return }
    themeProfiles[activeThemeSlot] = profile
    persistThemeProfile(profile, slot: activeThemeSlot)
    activeThemeSlot = slot
    profile = themeProfiles[slot] ?? (slot == .light ? .light : .standard)
  }

  private func persistThemeProfile(_ value: EditorCustomProfile, slot: EditorThemeSlot) {
    if usesWorkspaceThemeOverrides {
      EditorWorkspaceThemeProfileStore.save(value, slot: slot, workspaceURL: workspaceURL)
    } else {
      EditorProfileStore.save(value, slot: slot)
    }
  }

  func activateTheme(for colorScheme: ColorScheme) {
    if profile.themeMetadata.importedAppearance != .automatic { return }
    let mode =
      EditorInterfaceAppearance(
        rawValue: UserDefaults.standard.string(forKey: "editorAppearanceMode") ?? ""
      ) ?? .system
    let slot: EditorThemeSlot
    switch mode {
    case .light: slot = .light
    case .dark: slot = .dark
    case .system: slot = colorScheme == .dark ? .dark : .light
    }
    activateThemeSlot(slot)
  }

  func toggleEditorInputMode() {
    EditorInterfacePreferences.selectNext()
  }

  func refreshProjectContext() {
    scheduleProjectContextRefresh(delay: .zero)
  }

  private func scheduleProjectContextRefresh(delay: Duration = .milliseconds(350)) {
    guard !isShuttingDown, !hasShutDown else { return }
    projectContextRefreshGeneration &+= 1
    let generation = projectContextRefreshGeneration
    taskSupervisor.replace(.projectRefresh) { [weak self] lease in
      if delay > .zero {
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
      }
      guard let self, !Task.isCancelled, self.taskSupervisor.isCurrent(lease),
        !self.isShuttingDown, !self.hasShutDown,
        self.projectContextRefreshGeneration == generation
      else { return }
      self.buildController.rediscover()
      self.synchronizePythonProcessEnvironment()
      guard !Task.isCancelled, self.taskSupervisor.isCurrent(lease),
        self.projectContextRefreshGeneration == generation
      else { return }
      if let backend = self.ideWorkspace?.backend {
        _ = await backend.refreshExternalSourceIndex()
      }
      guard !Task.isCancelled, self.taskSupervisor.isCurrent(lease),
        self.projectContextRefreshGeneration == generation
      else { return }
      await self.symbolResolver.invalidate()
    }
  }

  func selectBuildProjectFolder(_ url: URL) {
    buildController.selectBuildProjectFolder(url)
    synchronizePythonProcessEnvironment(forceTerminalRestart: true)
  }

  func useWorkspaceAsBuildProject() {
    buildController.useWorkspaceAsBuildProject()
    synchronizePythonProcessEnvironment(forceTerminalRestart: true)
  }

  func selectPythonInterpreter(_ url: URL?) {
    buildController.selectPythonInterpreter(url)
    synchronizePythonProcessEnvironment(forceTerminalRestart: true)
  }

  private func resolvedPythonProcessEnvironment() -> [String: String] {
    EditorPythonEnvironmentResolver.activatedEnvironment(
      workspaceURL: buildController.buildProjectURL,
      base: servicesBaseEnvironment,
      explicitInterpreterURL: buildController.selectedPythonInterpreterURL
    ).environment
  }

  private func synchronizePythonProcessEnvironment(forceTerminalRestart: Bool = false) {
    let environment = resolvedPythonProcessEnvironment()
    let environmentChanged = servicesConfiguration.environment != environment
    #if os(macOS)
      EditorTerminalSessionRegistry.shared.session(for: workspaceURL)
        .refreshEnvironment(restartIfChanged: forceTerminalRestart || environmentChanged)
    #endif
    guard environmentChanged else { return }
    var configuration = servicesConfiguration
    configuration.environment = environment
    applyServicesConfiguration(configuration)
  }

  private var vimHostCapabilities: VimHostCapabilities { .all }

  func handleVimHostInvocation(_ invocation: VimHostInvocation) -> VimHostResponse {
    guard vimHostCapabilities.supports(invocation.request) else {
      return .rejected(
        .unsupportedCapability(
          VimHostCapabilities.capability(for: invocation.request)
        )
      )
    }

    if Self.requiresOriginatingDocument(invocation.request) {
      let originTab =
        invocation.context.bufferID.flatMap { bufferID in
          tabs.first { $0.id == bufferID.rawValue }
        }
        ?? invocation.context.documentURL.flatMap { url in
          tabs.first { $0.url.standardizedFileURL == url.standardizedFileURL }
        }
      guard let originTab else { return .rejected(.staleContext) }
      if let revision = invocation.context.revision, revision.value != originTab.textRevision {
        return .rejected(.staleContext)
      }
    }

    let previousError = fileOperationError
    handleVimHostRequest(invocation.request)
    if let message = fileOperationError, message != previousError {
      return .rejected(.failed(code: "HOST_ACTION_FAILED", message: message))
    }
    return .accepted
  }

  private static func requiresOriginatingDocument(_ request: VimHostRequest) -> Bool {
    switch request {
    case .write, .writeAndQuit, .quit, .closeTab, .split, .focusWindow, .cycleWindow,
      .focusPreviousWindow, .closeOtherWindows, .newWindow, .scroll,
      .definition, .declaration, .references, .hover, .rename, .codeAction,
      .format, .completion:
      return true
    case .openFile, .switchBuffer, .closeWindow, .nextTab, .previousTab,
      .newTab, .shell, .custom:
      return false
    }
  }

  func handleVimHostRequest(_ request: VimHostRequest) {
    switch request {
    case .write:
      onVimCommand?(.save)
    case .writeAndQuit:
      guard let tab = activeTab else { return }
      closeTab(tab, saving: true)
    case .quit, .closeTab:
      guard let tab = activeTab else { return }
      guard !tab.isDirty else {
        fileOperationError = "\(tab.title) has unsaved changes. Use :wq or :q! to close it."
        return
      }
      closeTab(tab)
    case .format:
      onVimCommand?(.format)
    case .completion:
      onVimCommand?(.requestCompletion)
    case .custom(let command) where command.lowercased() == "find":
      onVimCommand?(.find)
    case .custom(let command) where command.lowercased() == "replace":
      onVimCommand?(.replace)
    case .custom(let command) where command.lowercased().hasPrefix("tab-"):
      if let number = Int(command.dropFirst(4)) {
        onVimCommand?(.selectTab(number))
      }
    case .custom(let command) where command.lowercased() == "section-left":
      onVimCommand?(.directionalSection(.left))
    case .custom(let command) where command.lowercased() == "section-right":
      onVimCommand?(.directionalSection(.right))
    case .custom(let command) where command.lowercased() == "section-up":
      onVimCommand?(.directionalSection(.up))
    case .custom(let command) where command.lowercased() == "section-down":
      onVimCommand?(.directionalSection(.down))
    case .nextTab:
      // In the sectional workspace, a Vim tab is the currently visible
      // section's tab. Let the window session choose the next visible item so
      // `gt`, `:tabnext`, and leader mappings also include section-owned tabs.
      onVimCommand?(.nextTab)
    case .previousTab:
      onVimCommand?(.previousTab)
    case .switchBuffer(let number):
      let index = max(0, number - 1)
      guard tabs.indices.contains(index) else {
        fileOperationError = "Buffer \(number) does not exist."
        return
      }
      selectedTabID = tabs[index].id
    case .split(let horizontal):
      guard activeTab != nil else {
        fileOperationError = "There is no active buffer to split."
        return
      }
      onVimSplit?(horizontal)
    case .closeWindow:
      onVimCloseWindow?()
    case .newTab:
      onVimNewTab?()
    case .scroll(let lines):
      scrollActiveTab(lines: lines)
    case .shell(let command):
      onVimCommand?(.runTerminalCommand(command))
    case .openFile(let path):
      let url = URL(
        fileURLWithPath: NSString(string: path).expandingTildeInPath, relativeTo: workspaceURL)
      runAuxiliaryTask("vim-open-file") { [weak self] _ in
        await self?.openDocument(at: url.standardizedFileURL)
      }
    case .definition, .declaration:
      onVimCommand?(.goToDefinition)
    case .references:
      onVimCommand?(.findReferences)
    case .hover:
      onVimCommand?(.showQuickHelp)
    case .rename:
      renameSymbolFromVim()
    case .codeAction:
      runCodeActionFromVim()
    case .focusWindow(let direction, let count):
      handleVimCustomCommand("vim-window-\(direction.rawValue):\(max(1, count))")
    case .cycleWindow(let direction, let count):
      handleVimCustomCommand("vim-window-\(direction.rawValue):\(max(1, count))")
    case .focusPreviousWindow:
      handleVimCustomCommand("vim-window-previous-active")
    case .closeOtherWindows:
      handleVimCustomCommand("vim-window-only")
    case .newWindow(let horizontal):
      handleVimCustomCommand(horizontal ? "vim-window-new-horizontal" : "vim-window-new-vertical")
    case .custom(let command):
      handleVimCustomCommand(command)
    }
  }

  private func scrollActiveTab(lines: Int) {
    guard let tab = activeTab else { return }
    let snapshot = TextSnapshot(text: tab.text)
    let position =
      (try? snapshot.position(atUTF16Offset: tab.selectedRange.location))
      ?? TextPosition(line: 0, utf16Column: 0)
    tab.select(line: max(1, position.line + lines + 1), column: position.utf16Column + 1)
  }

  private func renameSymbolFromVim() {
    guard let tab = activeTab else { return }
    runAuxiliaryTask("rename-symbol") { [weak self, weak tab] lease in
      guard let self, let tab else { return }
      do {
        guard try await tab.prepareRenameAtSelection() != nil,
          self.taskSupervisor.isCurrent(lease)
        else {
          if self.taskSupervisor.isCurrent(lease) {
            self.fileOperationError = "The active language service cannot rename this symbol."
          }
          return
        }
        let alert = NSAlert()
        alert.messageText = "Rename Symbol"
        alert.informativeText = "Enter the new symbol name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: tab.symbolAtSelection ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, self.taskSupervisor.isCurrent(lease),
          let edit = try await tab.renameAtSelection(to: name),
          self.taskSupervisor.isCurrent(lease)
        else { return }
        try await self.applyLanguageWorkspaceEdit(edit, description: "Rename")
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.fileOperationError = "Rename failed: \(error.localizedDescription)"
      }
    }
  }

  private func runCodeActionFromVim() {
    guard let tab = activeTab else { return }
    presentCodeActions(for: tab)
  }

  /// Shows language-server fixes for a diagnostic at its exact source range.
  /// This is shared by the Problems list and the inline diagnostic popup.
  func showQuickFixes(for diagnostic: Diagnostic, in tab: EditorTab) {
    let snapshot = TextSnapshot(text: tab.text)
    guard let range = try? snapshot.nsRange(for: diagnostic.range) else {
      fileOperationError = "Could not locate this diagnostic in the current document."
      return
    }
    tab.updateSelection(range)
    presentCodeActions(for: tab)
  }

  private func presentCodeActions(for tab: EditorTab) {
    runAuxiliaryTask("code-action-\(tab.id.uuidString)") { [weak self, weak tab] lease in
      guard let self, let tab else { return }
      do {
        let actions = try await tab.codeActionsAtSelection().filter { !$0.isDisabled }
        guard self.taskSupervisor.isCurrent(lease), !actions.isEmpty else {
          if self.taskSupervisor.isCurrent(lease) {
            self.fileOperationError = "No code actions are available at the cursor."
          }
          return
        }
        let alert = NSAlert()
        alert.messageText = "Code Action"
        alert.informativeText = "Choose an action to apply."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        let ordered = actions.sorted {
          if $0.isPreferred != $1.isPreferred { return $0.isPreferred && !$1.isPreferred }
          return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        popup.addItems(withTitles: ordered.map(\.title))
        alert.accessoryView = popup
        guard alert.runModal() == .alertFirstButtonReturn,
          ordered.indices.contains(popup.indexOfSelectedItem),
          self.taskSupervisor.isCurrent(lease)
        else { return }
        let action = ordered[popup.indexOfSelectedItem]
        if let edit = action.edit {
          try await self.applyLanguageWorkspaceEdit(edit, description: action.title)
        }
        guard self.taskSupervisor.isCurrent(lease) else { return }
        if let command = action.command, let backend = self.ideWorkspace?.backend {
          _ = try await backend.executeLanguageCommand(command)
        }
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.fileOperationError = "Code action failed: \(error.localizedDescription)"
      }
    }
  }

  private func applyLanguageWorkspaceEdit(
    _ edit: EditorWorkspaceEdit,
    description: String
  ) async throws {
    guard let backend = ideWorkspace?.backend else {
      throw EditorWorkspaceRuntimeError.unsavedDocument(description)
    }
    let result = try await backend.applyWorkspaceEdit(edit, openMissingFiles: true)
    for url in result.appliedDocuments {
      if tabs.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) == false {
        await openDocument(at: url)
      }
    }
    for tab in tabs
    where result.appliedDocuments.contains(where: {
      $0.standardizedFileURL == tab.url.standardizedFileURL
    }) {
      tab.refreshAnalysis()
    }
    if !result.pendingFileOperations.isEmpty {
      fileOperationError =
        "\(description) changed text, but file create/rename/delete operations still require confirmation."
    }
    scheduleSessionPersistence()
  }

  func goToDefinition() {
    navigateToDefinition()
  }

  func findReferences() {
    navigateToReferences()
  }

  func showQuickHelp() {
    runAuxiliaryTask("quick-help") { [weak self] lease in
      guard let self, let tab = self.activeTab else { return }
      do {
        guard let hover = try await tab.hoverAtSelection(), !hover.markdown.isEmpty,
          self.taskSupervisor.isCurrent(lease)
        else {
          if self.taskSupervisor.isCurrent(lease) {
            self.symbolInformation = EditorSymbolInformation(
              title: tab.symbolAtSelection ?? "Quick Help",
              markdown: "No symbol information was returned by the active language service."
            )
          }
          return
        }
        self.symbolInformation = EditorSymbolInformation(
          title: tab.symbolAtSelection ?? "Quick Help",
          markdown: hover.markdown
        )
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.symbolInformation = EditorSymbolInformation(
          title: tab.symbolAtSelection ?? "Quick Help",
          markdown: "Quick Help failed: \(error.localizedDescription)"
        )
      }
    }
  }

  func openSymbolLocation(_ location: SourceLocation) {
    symbolLocations = nil
    runAuxiliaryTask("open-symbol-location") { [weak self] _ in
      await self?.openSourceLocation(location)
    }
  }

  func workspaceSymbols(matching query: String) async throws -> [EditorWorkspaceSymbol] {
    guard let backend = ideWorkspace?.backend else { return [] }
    return try await backend.workspaceSymbols(matching: query)
  }

  func openWorkspaceSymbol(_ symbol: EditorWorkspaceSymbol) {
    guard let location = symbol.location else {
      fileOperationError = "The language server returned no source location for \(symbol.name)."
      return
    }
    runAuxiliaryTask("open-workspace-symbol") { [weak self] _ in
      await self?.openSourceLocation(location)
    }
  }

  func toggleBreakpointAtCurrentLine() {
    guard let tab = activeTab else { return }
    tab.toggleBreakpointAtCurrentLine()
    breakpointController.reload()
    guard debugPhase == .running || debugPhase == .stopped else { return }
    runAuxiliaryTask("breakpoint-sync-\(tab.id.uuidString)") { [weak self, weak tab] lease in
      guard let self, let tab, let backend = self.ideWorkspace?.backend else { return }
      do {
        try await self.synchronizeBreakpoints(for: tab, using: backend)
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.appendDebugMessage("Breakpoint update failed: \(error.localizedDescription)")
      }
    }
  }

  func updateBreakpoint(_ record: EditorStoredBreakpoint) {
    breakpointController.update(record)
    guard debugPhase == .running || debugPhase == .stopped else { return }
    runAuxiliaryTask("breakpoint-record-sync-\(record.id.uuidString)") { [weak self] lease in
      guard let self, let backend = self.ideWorkspace?.backend else { return }
      do {
        try await self.synchronizeBreakpoints(using: backend)
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.appendDebugMessage("Breakpoint update failed: \(error.localizedDescription)")
      }
    }
  }

  func removeBreakpoint(_ record: EditorStoredBreakpoint) {
    breakpointController.remove(id: record.id)
    if let tab = tabs.first(where: {
      $0.url.standardizedFileURL == record.documentURL?.standardizedFileURL
    }) {
      let lines = Set(EditorBreakpointStore.loadRecords(for: tab.url).map(\.requestedLine))
      tab.updateBreakpoints(lines)
    }
    guard debugPhase == .running || debugPhase == .stopped else { return }
    runAuxiliaryTask("breakpoint-record-remove-\(record.id.uuidString)") { [weak self] lease in
      guard let self, let backend = self.ideWorkspace?.backend else { return }
      do {
        try await self.synchronizeBreakpoints(using: backend)
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.appendDebugMessage("Breakpoint removal failed: \(error.localizedDescription)")
      }
    }
  }

  func startDebugging() {
    debugLaunchTarget = .project
    runConfigurationController.select(target: .project)
    runDebugOperation { await self.beginDebugging() }
  }

  func startDebuggingCurrentFile() {
    guard let fileURL = activeTab?.url else { return }
    debugLaunchTarget = .currentFile(fileURL.standardizedFileURL)
    runConfigurationController.select(target: .currentFile)
    runDebugOperation { await self.beginDebugging() }
  }

  func continueDebugging() {
    clearDebugInspection()
    runDebugOperation {
      await self.performThreadCommand { backend, thread in
        _ = try await backend.continueExecution(threadID: thread)
      }
    }
  }

  func pauseDebugging() {
    runDebugOperation {
      await self.performThreadCommand { backend, thread in
        try await backend.pause(threadID: thread)
      }
    }
  }

  func stepOver() {
    clearDebugInspection()
    runDebugOperation {
      await self.performThreadCommand { backend, thread in
        try await backend.stepOver(threadID: thread)
      }
    }
  }

  func stepInto() {
    clearDebugInspection()
    runDebugOperation {
      await self.performThreadCommand { backend, thread in
        try await backend.stepIn(threadID: thread)
      }
    }
  }

  func stepOut() {
    clearDebugInspection()
    runDebugOperation {
      await self.performThreadCommand { backend, thread in
        try await backend.stepOut(threadID: thread)
      }
    }
  }

  func selectDebugFrame(_ frame: StackFrame) {
    selectedDebugFrameID = frame.id
    taskSupervisor.replace(.debugInspection) { [weak self] lease in
      guard let self, let backend = self.ideWorkspace?.backend,
        self.taskSupervisor.isCurrent(lease)
      else { return }
      await self.loadDebugScopes(frameID: frame.id, backend: backend)
      guard !Task.isCancelled, self.taskSupervisor.isCurrent(lease),
        self.selectedDebugFrameID == frame.id
      else { return }
      await self.openDebugFrame(frame)
    }
  }

  func resolveExternalFileConflict(using resolution: SourceWorkspaceConflictResolution) {
    guard let conflict = externalFileConflict else { return }
    let url = conflict.url.standardizedFileURL
    guard let id = externalConflictIDs[url], let backend = ideWorkspace?.backend else {
      externalFileConflict = nil
      return
    }
    runAuxiliaryTask("external-conflict-\(url.path)") { [weak self] lease in
      guard let self else { return }
      do {
        _ = try await backend.resolveSourceFileConflict(id, using: resolution)
        guard self.taskSupervisor.isCurrent(lease) else { return }
        if let tab = self.tabs.first(where: { $0.url.standardizedFileURL == url }) {
          switch resolution {
          case .useDisk:
            try await tab.applyDiskReload()
          case .useMemory:
            tab.markExternalConflictResolved()
          }
        }
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.externalConflictIDs.removeValue(forKey: url)
        if self.externalFileConflict?.url.standardizedFileURL == url {
          self.externalFileConflict = nil
          self.presentNextExternalFileConflict()
        }
        self.appendDebugMessage("Resolved external file conflict: \(url.lastPathComponent)")
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.fileOperationError =
          "Could not resolve the external file conflict: \(error.localizedDescription)"
      }
    }
  }

  func dismissExternalFileConflict() {
    externalFileConflict = nil
    presentNextExternalFileConflict()
  }

  func clearDebugConsole() { debugConsole.removeAll() }

  func stopDebugging() {
    stopLiveDebugging()
    let stoppedTarget: EditorExecutionTargetKind =
      switch activeDebugLaunchTarget ?? debugLaunchTarget {
      case .project: .project
      case .currentFile: .currentFile
      }
    runDebugOperation {
      guard let backend = self.ideWorkspace?.backend else { return }
      try? await backend.terminateDebugger()
      try? await backend.disconnectDebugger()
      await self.dapReverseRequestHost.terminateActiveTerminalProcess()
      if let lease = self.debugSessionController.takeProcessLease() {
        await EditorProcessRegistry.shared.unregister(lease)
      } else {
        await EditorProcessRegistry.shared.unregister(
          owner: .debug(workspacePath: self.workspaceURL.path)
        )
        await EditorProcessRegistry.shared.unregister(
          owner: .liveDebug(workspacePath: self.workspaceURL.path)
        )
      }
      self.activeThreadID = nil
      self.activeDebugSourceFingerprint = nil
      self.activeBackendDebugGeneration = nil
      self.debugExecutionSessionID = nil
      self.activeDebugLanguage = nil
      self.activeDebugLaunchTarget = nil
      self.debugSessionGeneration &+= 1
      self.clearDebugInspection()
      self.debugBreakpointVerification.removeAll(keepingCapacity: true)
      self.debugPhase = .idle
      await self.runPostDebugTasks(target: stoppedTarget)
    }
  }

  @discardableResult
  func shutdown(saveChanges: Bool = true) async -> Bool {
    if hasShutDown { return true }
    guard !isShuttingDown else { return false }
    transitionRuntime(to: .shuttingDown, detail: "workspace shutdown requested")
    liveDebugController.stop()
    pendingReconfigurationRequest = nil

    await taskSupervisor.cancelAndWait(.reconfiguration)
    await taskSupervisor.cancelAndWait(.sessionPersistence)
    let tabTaskKeys = taskSupervisor.snapshots().compactMap { snapshot -> WorkspaceTaskKey? in
      if case .tabOperation = snapshot.key { return snapshot.key }
      return nil
    }
    for key in tabTaskKeys { await taskSupervisor.cancelAndWait(key) }

    if saveChanges {
      await persistWorkspaceSession(includeRecoveries: true)
      guard await saveAllDocuments() else {
        transitionRuntime(
          to: .failed("One or more documents could not be saved."),
          detail: "shutdown save failed"
        )
        scheduleSessionPersistence()
        return false
      }
      await persistWorkspaceSession(includeRecoveries: false)
    } else {
      await persistWorkspaceSession(includeRecoveries: false)
    }

    if buildController.phase.isRunning { buildController.cancel() }
    await taskSupervisor.cancelAndWait(.buildLaunch)
    await taskSupervisor.cancelAndWait(.debugOperation)
    await taskSupervisor.cancelAndWait(.debugInspection)
    await taskSupervisor.cancelAndWait(.projectRefresh)
    projectContextRefreshGeneration &+= 1

    let pendingStart = startTask
    pendingStart?.cancel()
    startTask = nil
    startGeneration &+= 1

    for tab in tabs { await tab.close() }
    tabs.removeAll(keepingCapacity: false)
    selectedTabID = nil

    let observationTasks = cancelBackendObservationTasks()
    try? await ideWorkspace?.shutdown()
    ideWorkspace = nil
    for task in observationTasks { await task.value }
    if let pendingStart { _ = try? await pendingStart.value }

    await taskSupervisor.cancelAllAndWait(rejectingNewTasks: true)
    await dapReverseRequestHost.terminateActiveTerminalProcess()
    await EditorProcessRegistry.shared.terminate(workspaceURL: workspaceURL)
    transitionRuntime(to: .terminated, detail: "workspace shutdown complete")
    return true
  }

  private func runDebugOperation(
    _ operation: @escaping @MainActor () async -> Void
  ) {
    guard !taskSupervisor.contains(.debugOperation), !isShuttingDown, !hasShutDown else {
      return
    }
    taskSupervisor.replace(.debugOperation) { [weak self] lease in
      guard let self, self.taskSupervisor.isCurrent(lease) else { return }
      await operation()
    }
  }

  private func runAuxiliaryTask(
    _ name: String,
    operation: @escaping @MainActor (WorkspaceTaskLease) async -> Void
  ) {
    guard !isShuttingDown, !hasShutDown else { return }
    taskSupervisor.replace(.auxiliary(name)) { [weak self] lease in
      guard let self, self.taskSupervisor.isCurrent(lease) else { return }
      await operation(lease)
    }
  }

  private enum WorkspaceReconfigurationError: LocalizedError {
    case missingDocument(URL)
    case documentChangedDuringPreparation(URL)

    var errorDescription: String? {
      switch self {
      case .missingDocument(let url):
        return "\(url.lastPathComponent) is no longer available on disk."
      case .documentChangedDuringPreparation(let url):
        return "\(url.lastPathComponent) changed on disk while Editor Services were preparing."
      }
    }
  }

  private func captureRuntimeSnapshot() -> WorkspaceRuntimeSnapshot {
    let presentation = capturePresentationSnapshot?() ?? .empty
    return WorkspaceRuntimeSnapshot(
      documents: tabs.map { tab in
        WorkspaceDocumentRuntimeSnapshot(
          id: tab.id,
          url: tab.url,
          selectedRange: WorkspaceTextRangeSnapshot(tab.selectedRange),
          text: tab.text,
          isDirty: tab.isDirty,
          diskModificationTime: tab.diskModificationTime
        )
      },
      selectedDocumentID: selectedTabID,
      presentation: presentation
    )
  }

  private func reconfigure(using request: ServicesReconfigurationRequest) async {
    guard !isShuttingDown, !hasShutDown else { return }
    let operationID = UUID()
    transitionRuntime(
      to: .preparingReconfiguration(operationID),
      detail: "service configuration preparation started"
    )

    if let pendingStart = startTask {
      pendingStart.cancel()
      startTask = nil
      startGeneration &+= 1
      _ = try? await pendingStart.value
    }

    if request.requiresSuccessfulSave, !(await saveAllDocuments()) {
      let message =
        "Editor Services were not reconfigured because a document could not be saved."
      fileOperationError = message
      if ideWorkspace != nil {
        transitionRuntime(to: .running, detail: "reconfiguration save failed; old runtime retained")
      } else {
        transitionRuntime(to: .failed(message), detail: "reconfiguration save failed")
      }
      return
    }
    guard !Task.isCancelled, !isShuttingDown, !hasShutDown else { return }

    let snapshot = captureRuntimeSnapshot()
    let workspaceOpener = self.workspaceOpener
    var candidateWorkspace: EditorIDEWorkspace?
    var candidateTabs: [EditorTab] = []

    do {
      let candidate = try await workspaceOpener(request.configuration)
      candidateWorkspace = candidate
      candidateTabs = try await prepareRuntimeTabs(
        from: snapshot,
        using: candidate
      )

      guard !Task.isCancelled, !isShuttingDown, !hasShutDown else {
        await disposePreparedRuntime(candidateTabs, workspace: candidate)
        return
      }
      guard request.generation == reconfigurationGeneration else {
        await disposePreparedRuntime(candidateTabs, workspace: candidate)
        transitionRuntime(
          to: ideWorkspace == nil ? .idle : .running,
          detail: "prepared service configuration was superseded"
        )
        return
      }

      transitionRuntime(
        to: .committingReconfiguration(operationID),
        detail: "candidate services and documents are ready"
      )
      await commitPreparedRuntime(
        candidateWorkspace: candidate,
        candidateTabs: candidateTabs,
        snapshot: snapshot,
        configuration: request.configuration
      )
      candidateWorkspace = nil
      candidateTabs.removeAll(keepingCapacity: false)
    } catch is CancellationError {
      if let candidateWorkspace {
        await disposePreparedRuntime(candidateTabs, workspace: candidateWorkspace)
      }
      if !isShuttingDown, !hasShutDown {
        transitionRuntime(
          to: ideWorkspace == nil ? .idle : .running,
          detail: "reconfiguration preparation cancelled"
        )
      }
    } catch {
      if let candidateWorkspace {
        await disposePreparedRuntime(candidateTabs, workspace: candidateWorkspace)
      }
      let message =
        "Editor Services could not be reconfigured. The existing workspace was kept: "
        + error.localizedDescription
      fileOperationError = message
      appendDebugMessage(message)
      stabilityRecorder.record(
        .error,
        "reconfiguration-rolled-back",
        detail: error.localizedDescription,
        metadata: ["workspace": workspaceURL.path]
      )
      if ideWorkspace != nil {
        transitionRuntime(to: .running, detail: "candidate runtime failed; old runtime retained")
      } else {
        transitionRuntime(to: .failed(message), detail: "candidate runtime failed")
      }
    }
  }

  private func prepareRuntimeTabs(
    from snapshot: WorkspaceRuntimeSnapshot,
    using workspace: EditorIDEWorkspace
  ) async throws -> [EditorTab] {
    var prepared: [EditorTab] = []
    prepared.reserveCapacity(snapshot.documents.count)

    do {
      for state in snapshot.documents {
        try Task.checkCancellation()
        guard isRegularFile(state.url) else {
          throw WorkspaceReconfigurationError.missingDocument(state.url)
        }
        let tab = try await makeEditorTab(
          at: state.url,
          using: workspace,
          id: state.id,
          selectedRange: state.selectedRange.nsRange,
          attachCallbacks: false
        )
        prepared.append(tab)

        guard
          modificationTimesMatch(
            state.diskModificationTime,
            tab.diskModificationTime
          )
        else {
          throw WorkspaceReconfigurationError.documentChangedDuringPreparation(state.url)
        }
        if tab.text != state.text {
          guard state.isDirty else {
            throw WorkspaceReconfigurationError.documentChangedDuringPreparation(state.url)
          }
          try await tab.restoreRecoveredText(state.text)
          tab.updateSelection(state.selectedRange.nsRange)
        }
      }
      return prepared
    } catch {
      for tab in prepared {
        await tab.close()
        try? await workspace.closeDocument(at: tab.url)
      }
      throw error
    }
  }

  private func modificationTimesMatch(
    _ lhs: TimeInterval?,
    _ rhs: TimeInterval?
  ) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
      return true
    case (.some(let lhs), .some(let rhs)):
      return abs(lhs - rhs) < 0.001
    default:
      return false
    }
  }

  private func commitPreparedRuntime(
    candidateWorkspace: EditorIDEWorkspace,
    candidateTabs: [EditorTab],
    snapshot: WorkspaceRuntimeSnapshot,
    configuration: EditorServicesConfiguration
  ) async {
    await taskSupervisor.cancelAndWait(.projectRefresh)
    projectContextRefreshGeneration &+= 1
    let observationTasks = cancelBackendObservationTasks()

    let previousWorkspace = ideWorkspace
    let previousTabs = tabs
    for tab in candidateTabs { configureEditorTabCallbacks(tab) }

    ideWorkspace = candidateWorkspace
    serviceReport = candidateWorkspace.serviceResult.report
    servicesConfiguration = configuration
    tabs = candidateTabs
    if let selectedID = snapshot.selectedDocumentID,
      candidateTabs.contains(where: { $0.id == selectedID })
    {
      selectedTabID = selectedID
    } else {
      selectedTabID = candidateTabs.first?.id
    }
    observeBackend(candidateWorkspace.backend)
    EditorServicePreferencesStore.save(configuration: configuration)
    transitionRuntime(to: .running, detail: "candidate runtime committed")
    fileOperationError = nil
    if !hasRestoredSession, tabs.isEmpty {
      hasRestoredSession = true
      await restoreWorkspaceSession()
    }
    scheduleSessionPersistence()

    for tab in previousTabs { await tab.close() }
    try? await previousWorkspace?.shutdown()
    for task in observationTasks { await task.value }
  }

  private func disposePreparedRuntime(
    _ preparedTabs: [EditorTab],
    workspace: EditorIDEWorkspace
  ) async {
    for tab in preparedTabs {
      await tab.close()
      try? await workspace.closeDocument(at: tab.url)
    }
    try? await workspace.shutdown()
  }

  func startLiveDebugging() {
    debugLaunchTarget = .project
    beginLiveDebuggingForSelectedTarget()
  }

  func startLiveDebuggingCurrentFile() {
    guard let fileURL = activeTab?.url else { return }
    debugLaunchTarget = .currentFile(fileURL.standardizedFileURL)
    beginLiveDebuggingForSelectedTarget()
  }

  private func beginLiveDebuggingForSelectedTarget() {
    if !isLiveDebugEnabled {
      isLiveDebugEnabled = true
    } else {
      configureLiveDebugMonitoring()
    }
    switch debugPhase {
    case .idle, .failed:
      runDebugOperation { await self.beginDebugging() }
    case .starting:
      liveDebugController.report(.watching)
    case .running, .stopped:
      if activeDebugLaunchTarget != debugLaunchTarget {
        let changedPaths: Set<URL> =
          switch debugLaunchTarget {
          case .project: [buildController.buildProjectURL.standardizedFileURL]
          case .currentFile(let fileURL): [fileURL.standardizedFileURL]
          }
        liveDebugController.enqueueFullRestart(for: changedPaths)
      } else {
        liveDebugController.report(.watching)
      }
    }
  }

  func stopLiveDebugging() {
    isLiveDebugEnabled = false
    liveDebugController.stop()
    liveDebugController.report(.disabled)
  }

  private static func liveDebugPreferenceKey(workspaceURL: URL) -> String {
    "calcite.liveDebug." + EditorSourceFingerprint.hash(workspaceURL.standardizedFileURL.path)
  }

  private func configureLiveDebugMonitoring() {
    guard let liveDebugController else { return }
    guard !isShuttingDown, !hasShutDown else {
      liveDebugController.stop()
      return
    }
    liveDebugController.configure(
      enabled: isLiveDebugEnabled,
      target: debugLaunchTarget
    )
  }

  private func liveDebugRoots(for target: EditorDebugLaunchTarget) -> [URL] {
    let targetKind: EditorExecutionTargetKind =
      switch target {
      case .project: .project
      case .currentFile: .currentFile
      }
    let configuration = runConfigurationController.configuration(for: targetKind)
    let baseRoot: URL =
      switch target {
      case .project:
        buildController.buildProjectURL.standardizedFileURL
      case .currentFile(let fileURL):
        if let language = languageForDebugFile(fileURL),
          usesProjectDebugContext(for: fileURL, language: language)
        {
          buildController.buildProjectURL.standardizedFileURL
        } else {
          fileURL.standardizedFileURL.deletingLastPathComponent()
        }
      }
    guard let configuration, !configuration.liveDebugWatchRoots.isEmpty else {
      return [baseRoot]
    }
    return configuration.liveDebugWatchRoots.map { value in
      let expanded = NSString(string: value).expandingTildeInPath
      if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
      }
      return baseRoot.appendingPathComponent(expanded, isDirectory: true).standardizedFileURL
    }.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  private func shouldTriggerLiveDebug(
    for url: URL,
    target: EditorDebugLaunchTarget
  ) -> Bool {
    let standardized = url.standardizedFileURL
    let targetKind: EditorExecutionTargetKind =
      switch target {
      case .project: .project
      case .currentFile: .currentFile
      }
    if let configuration = runConfigurationController.configuration(for: targetKind),
      configuration.liveDebugExclusions.contains(where: {
        EditorPathPattern.matches(
          path: standardized.path,
          pattern: $0,
          relativeTo: buildController.buildProjectURL
        )
      })
    {
      return false
    }
    if case .currentFile(let targetURL) = target {
      let usesProjectContext =
        languageForDebugFile(targetURL).map {
          usesProjectDebugContext(for: targetURL, language: $0)
        } ?? false
      if !usesProjectContext, standardized != targetURL.standardizedFileURL {
        return false
      }
    }
    let impact = EditorFileChangeImpactResolver.resolve(
      changedURL: standardized,
      workspaceURL: buildController.buildProjectURL,
      launchTarget: target
    )
    switch impact {
    case .ignore:
      return false
    case .rebuildTargets(let targets), .rebuildDependents(let targets):
      let active = activeLiveDebugTargetNames(for: target)
      return active.isEmpty || !targets.isDisjoint(with: active)
    case .resourceReload, .projectGraphReload, .debuggerRestartOnly:
      return true
    }
  }

  private func activeLiveDebugTargetNames(
    for target: EditorDebugLaunchTarget
  ) -> Set<String> {
    var values = Set<String>()
    let commands = [
      buildController.plan.command(for: .run),
      buildController.plan.command(for: .build),
    ].compactMap { $0 }
    for command in commands {
      for flag in ["--product", "--target", "--bin", "--package", "-p"] {
        if let index = command.arguments.lastIndex(of: flag),
          command.arguments.indices.contains(index + 1)
        {
          values.insert(command.arguments[index + 1])
        }
      }
    }
    if let configured = runConfigurationController.configuration(for: .project)?
      .projectTargetName?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !configured.isEmpty
    {
      values.insert(configured)
    }
    if let product = buildController.lastSuccessfulArtifact?.productName,
      !product.isEmpty
    {
      values.insert(product)
    }
    let fileURL: URL? =
      switch target {
      case .project: activeTab?.url
      case .currentFile(let fileURL): fileURL
      }
    if let fileURL {
      let root = buildController.buildProjectURL.standardizedFileURL
      let path = fileURL.standardizedFileURL.path
      if path.hasPrefix(root.path + "/") {
        let relative = String(path.dropFirst(root.path.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        if parts.count >= 2, ["Sources", "Tests"].contains(parts[0]) {
          values.insert(parts[1])
        }
      }
    }
    let configuredProgram = effectiveDebugConfiguration(for: target).programPath
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !configuredProgram.isEmpty {
      values.insert(URL(fileURLWithPath: configuredProgram).lastPathComponent)
    }
    return values
  }

  private func targetedLiveDebugBuildCommand(
    for batch: ProjectFileChangeBatch
  ) -> EditorBuildCommand? {
    guard case .project = debugLaunchTarget,
      var command = buildController.plan.command(for: .build)
    else { return nil }
    let paths = batch.changedPaths.union(batch.removedPaths).union(batch.renamedPaths)
    let impacts = paths.map {
      EditorFileChangeImpactResolver.resolve(
        changedURL: $0,
        workspaceURL: buildController.buildProjectURL,
        launchTarget: debugLaunchTarget
      )
    }
    if impacts.contains(where: {
      if case .projectGraphReload = $0 { return true }
      return false
    }) {
      buildController.rediscover()
      return buildController.plan.command(for: .build)
    }
    let configuredTarget = runConfigurationController.configuration(for: .project)?
      .projectTargetName?
      .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let artifactTarget = buildController.lastSuccessfulArtifact?.productName
    let active = activeLiveDebugTargetNames(for: debugLaunchTarget)
    guard let target = configuredTarget ?? artifactTarget ?? active.sorted().first else {
      return command
    }
    switch buildController.plan.projectKind {
    case .swiftPackage:
      if !command.arguments.contains("--target") && !command.arguments.contains("--product") {
        command.arguments += ["--product", target]
        command.title += " (\(target))"
      }
    case .rustCargo:
      if !command.arguments.contains("--bin"),
        !command.arguments.contains("--package"),
        !command.arguments.contains("-p")
      {
        command.arguments += ["--bin", target]
        command.title += " (\(target))"
      }
    case .goModule, .nodePackage, .python, .xcode, .gradle, .maven, .zig, .cmake,
      .make, .generic:
      break
    }
    return command
  }

  private func restartDebuggingForLiveChanges(
    batch: ProjectFileChangeBatch,
    generation: UInt64
  ) async {
    guard let workspace = ideWorkspace,
      liveDebugController.generation == generation,
      isLiveDebugEnabled
    else { return }
    do {
      liveDebugController.report(.building)
      let snapshot = try await prepareSourceSnapshotForDebugTarget(reason: .liveDebug)
      guard liveDebugController.generation == generation, !Task.isCancelled else { return }
      if snapshot.fingerprint == activeDebugSourceFingerprint {
        appendDebugMessage(
          "Live Debug ignored a change batch with an unchanged source fingerprint."
        )
        return
      }

      appendDebugMessage(
        "Live Debug processing \(batch.changedPaths.count + batch.removedPaths.count + batch.renamedPaths.count) changed file(s)…",
        channel: .liveDebug
      )
      let configurationTarget: EditorExecutionTargetKind =
        switch debugLaunchTarget {
        case .project: .project
        case .currentFile: .currentFile
        }
      guard
        await runPreLaunchTasks(
          target: configurationTarget,
          sourceSnapshot: snapshot
        )
      else {
        liveDebugController.report(
          .failed("A pre-launch task failed; the previous session was kept."))
        return
      }
      guard
        await buildDebugLaunchTarget(
          sourceSnapshot: snapshot,
          projectBuildCommandOverride: targetedLiveDebugBuildCommand(for: batch)
        )
      else {
        liveDebugController.report(.failed("Build failed; the previous debug session was kept."))
        appendDebugMessage("Live Debug build failed; the previous session was kept running.")
        return
      }

      guard liveDebugController.generation == generation, !Task.isCancelled else { return }
      liveDebugController.report(.restarting)
      try await replaceDebugSession(using: workspace, sourceSnapshot: snapshot)
      guard liveDebugController.generation == generation else { return }
      activeDebugSourceFingerprint = snapshot.fingerprint
      liveDebugController.report(.watching)
    } catch is CancellationError {
      return
    } catch {
      liveDebugController.report(.failed(error.localizedDescription))
      appendDebugMessage("Live Debug restart failed: \(error.localizedDescription)")
    }
  }

  private struct ResolvedDebugLaunch {
    let language: EditorLanguage
    let programPath: String
    let workingDirectory: URL
  }

  func usesProjectDebugContext(
    for fileURL: URL,
    language: EditorLanguage
  ) -> Bool {
    let rootPath = buildController.buildProjectURL.standardizedFileURL.path
    let filePath = fileURL.standardizedFileURL.path
    guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else { return false }
    switch buildController.plan.projectKind {
    case .xcode:
      return [.swift, .c, .cpp, .objectiveC, .objectiveCPP].contains(language)
    case .swiftPackage:
      return language == .swift
    case .rustCargo:
      return language == .rust
    case .goModule:
      return language == .go
    case .python:
      return language == .python
    case .gradle, .maven:
      return language == .java || language == .kotlin
    case .nodePackage:
      return language == .javascript || language == .typescript
    case .zig:
      return language == .zig
    case .cmake, .make:
      return [.c, .cpp, .objectiveC, .objectiveCPP].contains(language)
    case .generic:
      return false
    }
  }

  private func languageForDebugFile(_ fileURL: URL) -> EditorLanguage? {
    let standardized = fileURL.standardizedFileURL
    let languageID =
      tabs.first(where: {
        $0.url.standardizedFileURL == standardized
      })?.languageID ?? EditorLanguageCatalog.standard.languageID(for: standardized)
    return editorLanguage(for: languageID)
  }

  private func prepareSourceSnapshotForDebugTarget(
    reason: EditorExecutionPreparationReason
  ) async throws -> EditorPreparedSourceSnapshot {
    switch debugLaunchTarget {
    case .project:
      return try await prepareWorkspaceForExecution(reason)
    case .currentFile(let fileURL):
      if let language = languageForDebugFile(fileURL),
        usesProjectDebugContext(for: fileURL, language: language)
      {
        return try await prepareWorkspaceForExecution(reason)
      }
      return try await prepareSingleFileForExecution(fileURL, reason: reason)
    }
  }

  private func buildDebugLaunchTarget(
    sourceSnapshot: EditorPreparedSourceSnapshot,
    projectBuildCommandOverride: EditorBuildCommand? = nil
  ) async -> Bool {
    guard effectiveDebugConfiguration(for: debugLaunchTarget).buildBeforeLaunch else {
      return true
    }
    switch debugLaunchTarget {
    case .project:
      guard
        let baseCommand = projectBuildCommandOverride
          ?? buildController.plan.command(for: .build)
      else { return true }
      var command = runConfigurationController.configuredCommand(
        baseCommand,
        target: .project,
        plan: buildController.plan
      )
      command = prepareDebugArtifactCommand(command, sourceSnapshot: sourceSnapshot)
      appendDebugMessage(
        "Building project before debug launch: \(command.title)…",
        channel: isLiveDebugEnabled ? .liveDebug : .debugger
      )
      guard await buildController.run(command, sourceSnapshot: sourceSnapshot) else {
        return false
      }
    case .currentFile(let fileURL):
      guard let language = languageForDebugFile(fileURL) else {
        appendDebugMessage("The current file language could not be resolved for debugging.")
        return false
      }
      if usesProjectDebugContext(for: fileURL, language: language) {
        guard let baseCommand = buildController.plan.command(for: .build) else { return true }
        var command = runConfigurationController.configuredCommand(
          baseCommand,
          target: .project,
          plan: buildController.plan
        )
        command = prepareDebugArtifactCommand(command, sourceSnapshot: sourceSnapshot)
        appendDebugMessage("Building project context for \(fileURL.lastPathComponent)…")
        guard await buildController.run(command, sourceSnapshot: sourceSnapshot) else {
          return false
        }
        break
      }
      do {
        let target = try EditorStandaloneDebugTarget.resolve(
          fileURL: fileURL, language: language
        )
        if let buildCommand = target.buildCommand {
          appendDebugMessage("Building \(fileURL.lastPathComponent) for standalone debugging…")
          guard await buildController.run(buildCommand, sourceSnapshot: sourceSnapshot) else {
            return false
          }
        }
      } catch {
        appendDebugMessage(error.localizedDescription)
        return false
      }
    }
    return acceptSuccessfulExecution(sourceSnapshot: sourceSnapshot)
  }

  private func prepareDebugArtifactCommand(
    _ command: EditorBuildCommand,
    sourceSnapshot: EditorPreparedSourceSnapshot
  ) -> EditorBuildCommand {
    guard buildController.plan.projectKind == .goModule,
      URL(fileURLWithPath: command.executable).lastPathComponent == "go",
      command.arguments.first == "build"
    else { return command }

    var command = command
    let configuration = runConfigurationController.configuration(for: .project)
    let configuredTarget = configuration?.projectTargetName?
      .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let package = configuredTarget ?? "."
    let directory = Self.debugArtifactDirectory(
      workspaceURL: buildController.buildProjectURL,
      sourceFingerprint: sourceSnapshot.fingerprint
    )
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let output = directory.appendingPathComponent(
      URL(fileURLWithPath: package).lastPathComponent.nilIfEmpty ?? "program"
    )

    command.arguments = Self.goDebugBuildArguments(
      from: command.arguments,
      package: package,
      output: output
    )
    command.artifactPath = output.path
    command.title += " (debug artifact)"
    return command
  }

  nonisolated private static func goDebugBuildArguments(
    from arguments: [String],
    package: String,
    output: URL
  ) -> [String] {
    let flagsWithValues: Set<String> = [
      "-asmflags", "-buildmode", "-buildvcs", "-compiler", "-gcflags", "-installsuffix",
      "-ldflags", "-mod", "-modfile", "-overlay", "-pgo", "-pkgdir", "-tags",
      "-toolexec",
    ]
    var preserved: [String] = []
    var index = arguments.first == "build" ? 1 : 0
    while index < arguments.count {
      let value = arguments[index]
      if flagsWithValues.contains(value), arguments.indices.contains(index + 1) {
        preserved += [value, arguments[index + 1]]
        index += 2
        continue
      }
      if value.hasPrefix("-") && value != "-o" {
        preserved.append(value)
        index += 1
        continue
      }
      if value == "-o" {
        index += min(2, arguments.count - index)
        continue
      }
      index += 1
    }
    return ["build", "-o", output.path] + preserved + [package]
  }

  nonisolated private static func debugArtifactDirectory(
    workspaceURL: URL,
    sourceFingerprint: String
  ) -> URL {
    let caches =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let workspaceHash = EditorSourceFingerprint.hash(workspaceURL.standardizedFileURL.path)
    return
      caches
      .appendingPathComponent("Calcite/DebugArtifacts", isDirectory: true)
      .appendingPathComponent(workspaceHash, isDirectory: true)
      .appendingPathComponent(sourceFingerprint, isDirectory: true)
  }

  private func resolveDebugLaunch(
    in workspace: EditorIDEWorkspace,
    sourceSnapshot: EditorPreparedSourceSnapshot
  ) async throws -> ResolvedDebugLaunch {
    switch debugLaunchTarget {
    case .project:
      guard let language = await resolvedDebugLanguage(in: workspace) else {
        throw EditorExecutionIntegrityError.configuration(
          "No debug adapter is available for the active project language."
        )
      }
      let resolver = EditorDebugProgramResolver(workspaceURL: buildController.buildProjectURL)
      let launchConfiguration = effectiveDebugConfiguration(for: debugLaunchTarget)
      let matchingArtifact = buildController.lastSuccessfulArtifact.flatMap { artifact -> String? in
        guard artifact.sourceFingerprint == sourceSnapshot.fingerprint,
          let url = artifact.executableURL,
          FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url.path
      }
      let configuredProgram = resolver.resolveConfiguredPath(launchConfiguration.programPath)
      let program: String?
      if Self.requiresFingerprintBoundArtifact(buildController.plan.projectKind),
        launchConfiguration.buildBeforeLaunch
      {
        program = matchingArtifact
      } else {
        program =
          matchingArtifact ?? configuredProgram
          ?? Self.interpretedProjectEntry(
            activeTab: activeTab,
            language: language,
            workspaceURL: buildController.buildProjectURL
          )
      }
      guard let program else {
        throw EditorExecutionIntegrityError.configuration(
          "No executable matching the current source snapshot was found. Build the selected product or set an explicit program in Run Configurations."
        )
      }
      return ResolvedDebugLaunch(
        language: language,
        programPath: program,
        workingDirectory: buildController.buildProjectURL
      )

    case .currentFile(let fileURL):
      let standardized = fileURL.standardizedFileURL
      guard let language = languageForDebugFile(standardized) else {
        throw EditorExecutionIntegrityError.configuration(
          "The language of \(standardized.lastPathComponent) cannot be debugged."
        )
      }
      guard workspace.serviceResult.debugAdapter(for: language) != nil else {
        throw EditorDebugAdapterSelectionError.unavailable(language)
      }
      if usesProjectDebugContext(for: standardized, language: language) {
        let resolver = EditorDebugProgramResolver(workspaceURL: buildController.buildProjectURL)
        let launchConfiguration = effectiveDebugConfiguration(for: debugLaunchTarget)
        let matchingArtifact = buildController.lastSuccessfulArtifact.flatMap {
          artifact -> String? in
          guard artifact.sourceFingerprint == sourceSnapshot.fingerprint,
            let url = artifact.executableURL,
            FileManager.default.fileExists(atPath: url.path)
          else { return nil }
          return url.path
        }
        let configuredProgram = resolver.resolveConfiguredPath(launchConfiguration.programPath)
        let program: String?
        if Self.requiresFingerprintBoundArtifact(buildController.plan.projectKind),
          launchConfiguration.buildBeforeLaunch
        {
          program = matchingArtifact
        } else {
          program =
            matchingArtifact ?? configuredProgram
            ?? Self.interpretedProjectEntry(
              activeTab: activeTab,
              language: language,
              workspaceURL: buildController.buildProjectURL
            )
        }
        guard let program else {
          throw EditorExecutionIntegrityError.configuration(
            "No project executable matching the current source was found for \(standardized.lastPathComponent)."
          )
        }
        return ResolvedDebugLaunch(
          language: language,
          programPath: program,
          workingDirectory: buildController.buildProjectURL
        )
      }
      let target = try EditorStandaloneDebugTarget.resolve(
        fileURL: standardized, language: language
      )
      if target.buildCommand != nil,
        !FileManager.default.isExecutableFile(atPath: target.programPath)
      {
        throw EditorExecutionIntegrityError.configuration(
          "The standalone debug artifact was not created: \(target.programPath)"
        )
      }
      return ResolvedDebugLaunch(
        language: language,
        programPath: target.programPath,
        workingDirectory: target.workingDirectory
      )
    }
  }

  nonisolated private static func requiresFingerprintBoundArtifact(
    _ kind: EditorProjectBuildKind
  ) -> Bool {
    switch kind {
    case .swiftPackage, .rustCargo, .xcode, .goModule, .zig, .cmake:
      return true
    case .python, .nodePackage, .gradle, .maven, .make, .generic:
      return false
    }
  }

  private static func interpretedProjectEntry(
    activeTab: EditorTab?,
    language: EditorLanguage,
    workspaceURL: URL
  ) -> String? {
    guard [.python, .javascript, .typescript, .ruby, .lua, .php].contains(language),
      let url = activeTab?.url.standardizedFileURL,
      url.path == workspaceURL.path || url.path.hasPrefix(workspaceURL.path + "/"),
      FileManager.default.fileExists(atPath: url.path)
    else { return nil }
    return url.path
  }

  private func effectiveDebugConfiguration(
    for target: EditorDebugLaunchTarget
  ) -> EditorDebugConfiguration {
    var value = debugConfiguration
    let targetKind: EditorExecutionTargetKind =
      switch target {
      case .project: .project
      case .currentFile: .currentFile
      }
    let run =
      runConfigurationController.configurations.first(where: {
        $0.id == runConfigurationController.selectedID && $0.target == targetKind
      }) ?? runConfigurationController.configurations.first(where: { $0.target == targetKind })
    guard let run else { return value }
    if !run.arguments.isEmpty {
      value.arguments = run.arguments.map(Self.shellQuotedArgument).joined(separator: " ")
    }
    value.environment.merge(run.environment) { _, configured in configured }
    if !run.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      value.workingDirectory = run.workingDirectory
    }
    value.buildBeforeLaunch = run.buildBeforeLaunch
    value.stopOnEntry = run.stopOnEntry
    value.terminalMode = run.terminalMode
    if let adapter = run.debuggerAdapterID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !adapter.isEmpty
    {
      value.adapterID = adapter
    }
    return value
  }

  nonisolated private static func shellQuotedArgument(_ value: String) -> String {
    guard !value.isEmpty else { return "''" }
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/@%+=:,"))
    if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\''") + "'"
  }

  private func registerActiveDebugProcess(
    backend: MultiLanguageEditorBackend,
    live: Bool
  ) async {
    let owner: EditorProcessOwner =
      live
      ? .liveDebug(workspacePath: workspaceURL.path)
      : .debug(workspacePath: workspaceURL.path)

    // The backend has already adopted or restarted the new DAP session at this point. Replacing
    // the registry entry must not invoke the previous terminator because both entries can capture
    // the same backend and would otherwise stop the newly installed session.
    let alternateOwner: EditorProcessOwner =
      live
      ? .debug(workspacePath: workspaceURL.path)
      : .liveDebug(workspacePath: workspaceURL.path)
    if let previousLease = debugSessionController.takeProcessLease() {
      await EditorProcessRegistry.shared.unregister(previousLease)
    } else {
      // Recover from older sessions that predate lease tracking without stopping the backend that
      // has just been adopted by this coordinator.
      await EditorProcessRegistry.shared.unregister(owner: owner)
    }
    await EditorProcessRegistry.shared.unregister(owner: alternateOwner)
    let lease = await EditorProcessRegistry.shared.register(
      owner: owner,
      replacementPolicy: .preserveExistingProcess
    ) { [weak self] in
      try? await backend.terminateDebugger()
      try? await backend.disconnectDebugger()
      await self?.dapReverseRequestHost.terminateActiveTerminalProcess()
    }
    _ = debugSessionController.replaceProcessLease(with: lease)
  }

  private func replaceDebugSession(
    using workspace: EditorIDEWorkspace,
    sourceSnapshot: EditorPreparedSourceSnapshot
  ) async throws {
    let launch = try await resolveDebugLaunch(in: workspace, sourceSnapshot: sourceSnapshot)
    var launchConfiguration = effectiveDebugConfiguration(for: debugLaunchTarget)
    launchConfiguration.programPath = launch.programPath
    if case .currentFile = debugLaunchTarget {
      launchConfiguration.workingDirectory = launch.workingDirectory.path
    } else if launchConfiguration.workingDirectory
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      launchConfiguration.workingDirectory = launch.workingDirectory.path
    }
    let adapterID =
      launchConfiguration.adapterID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? workspace.serviceResult.debugAdapter(for: launch.language)?.defaultAdapterID
      ?? launch.language.rawValue
    let arguments = EditorDebugLaunchArguments.make(
      language: launch.language,
      adapterID: adapterID,
      configuration: launchConfiguration,
      workspaceURL: launch.workingDirectory
    )

    isReplacingDebugSession = true
    debugSessionGeneration &+= 1
    let replacementSessionID = UUID()
    defer { isReplacingDebugSession = false }
    clearDebugInspection()
    debugPhase = .starting

    if activeDebugLanguage == launch.language {
      do {
        try await workspace.backend.restartDebugger(arguments: arguments)
        try await synchronizeBreakpoints(using: workspace.backend)
        activeBackendDebugGeneration = await workspace.backend.currentDebugSessionGeneration()
        debugExecutionSessionID = replacementSessionID
        activeDebugLanguage = launch.language
        activeDebugLaunchTarget = debugLaunchTarget
        await registerActiveDebugProcess(backend: workspace.backend, live: true)
        if case .starting = debugPhase { debugPhase = .running }
        appendDebugMessage(
          "Live Debug restarted \(adapterID) at source \(sourceSnapshot.fingerprint)."
        )
        return
      } catch {
        appendDebugMessage(
          "The adapter does not support an in-place restart; replacing the debug session."
        )
      }
    } else {
      appendDebugMessage("Live Debug is switching adapters for the selected target.")
    }

    let prepared = try await workspace.serviceResult.prepareDebugger(
      for: launch.language,
      initializeArguments: InitializeArguments(
        adapterID: adapterID,
        clientID: "Calcite",
        clientName: "Calcite",
        supportsRunInTerminalRequest: true
      ),
      reverseRequestHandler: dapReverseRequestHost
    )
    do {
      // Launch the replacement adapter before sending source breakpoints. DAP
      // adapters commonly emit `initialized` only after the launch request and
      // may reject configuration requests sent earlier. The old session remains
      // active until the replacement has launched and finished configuration.
      try await prepared.launch(arguments: arguments)
      try await synchronizeBreakpoints(using: prepared)
      try await prepared.finishConfiguration()
      try await workspace.backend.replaceWithPreparedDebugger(
        prepared,
        disconnectArguments: DisconnectArguments(
          restart: true,
          terminateDebuggee: true
        )
      )
      activeBackendDebugGeneration = await workspace.backend.currentDebugSessionGeneration()
      debugExecutionSessionID = replacementSessionID
    } catch {
      await prepared.discard()
      throw error
    }
    activeDebugLanguage = launch.language
    activeDebugLaunchTarget = debugLaunchTarget
    await registerActiveDebugProcess(backend: workspace.backend, live: true)
    if case .starting = debugPhase { debugPhase = .running }
    appendDebugMessage(
      "Live Debug replaced \(adapterID) at source \(sourceSnapshot.fingerprint)."
    )
  }

  private func beginDebugging() async {
    guard let workspace = ideWorkspace else { return }
    debugBreakpointVerification.removeAll(keepingCapacity: true)
    debugExecutionOperationID = UUID()
    debugExecutionSessionID = UUID()
    debugPhase = .starting

    let sourceSnapshot: EditorPreparedSourceSnapshot
    do {
      sourceSnapshot = try await prepareSourceSnapshotForDebugTarget(
        reason: isLiveDebugEnabled ? .liveDebug : .debug
      )
    } catch {
      debugPhase = .failed(error.localizedDescription)
      appendDebugMessage("Debug launch preparation failed: \(error.localizedDescription)")
      return
    }

    let configurationTarget: EditorExecutionTargetKind =
      switch debugLaunchTarget {
      case .project: .project
      case .currentFile: .currentFile
      }
    guard
      await runPreLaunchTasks(
        target: configurationTarget,
        sourceSnapshot: sourceSnapshot
      )
    else {
      debugPhase = .failed("A pre-launch task failed.")
      return
    }

    guard await buildDebugLaunchTarget(sourceSnapshot: sourceSnapshot) else {
      debugPhase = .failed("The debug build failed. Open the Build or Problems panel for details.")
      appendDebugMessage("Debug launch cancelled because the build failed.")
      return
    }

    do {
      let launch = try await resolveDebugLaunch(in: workspace, sourceSnapshot: sourceSnapshot)
      var launchConfiguration = effectiveDebugConfiguration(for: debugLaunchTarget)
      launchConfiguration.programPath = launch.programPath
      if case .currentFile = debugLaunchTarget {
        launchConfiguration.workingDirectory = launch.workingDirectory.path
      } else if launchConfiguration.workingDirectory
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        launchConfiguration.workingDirectory = launch.workingDirectory.path
      }
      debugSessionGeneration &+= 1
      let adapterID =
        launchConfiguration.adapterID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? workspace.serviceResult.debugAdapter(for: launch.language)?.defaultAdapterID
        ?? launch.language.rawValue
      let prepared = try await workspace.serviceResult.prepareDebugger(
        for: launch.language,
        initializeArguments: InitializeArguments(
          adapterID: adapterID,
          clientID: "Calcite",
          clientName: "Calcite",
          supportsRunInTerminalRequest: true
        ),
        reverseRequestHandler: dapReverseRequestHost
      )
      do {
        let launchArguments = EditorDebugLaunchArguments.make(
          language: launch.language,
          adapterID: adapterID,
          configuration: launchConfiguration,
          workspaceURL: launch.workingDirectory
        )
        try await prepared.launch(arguments: launchArguments)
        try await synchronizeBreakpoints(using: prepared)
        try await prepared.finishConfiguration()
        try await workspace.backend.adoptPreparedDebugger(prepared)
        activeBackendDebugGeneration = await workspace.backend.currentDebugSessionGeneration()
      } catch {
        await prepared.discard()
        throw error
      }
      activeDebugSourceFingerprint = sourceSnapshot.fingerprint
      activeDebugLanguage = launch.language
      activeDebugLaunchTarget = debugLaunchTarget
      await registerActiveDebugProcess(
        backend: workspace.backend,
        live: isLiveDebugEnabled
      )
      if case .starting = debugPhase { debugPhase = .running }
      if isLiveDebugEnabled { liveDebugController.report(.watching) }
      appendDebugMessage(
        "Started \(adapterID) for \(launch.programPath) at source \(sourceSnapshot.fingerprint)"
      )
    } catch {
      try? await workspace.backend.disconnectDebugger()
      await dapReverseRequestHost.terminateActiveTerminalProcess()
      activeThreadID = nil
      activeDebugSourceFingerprint = nil
      activeBackendDebugGeneration = nil
      debugExecutionSessionID = nil
      activeDebugLanguage = nil
      activeDebugLaunchTarget = nil
      debugPhase = .failed(error.localizedDescription)
      appendDebugMessage("Debug start failed: \(error.localizedDescription)")
    }
  }

  private func synchronizeBreakpoints(
    using prepared: EditorPreparedDebugSession
  ) async throws {
    let requests = preparedBreakpointRequests()
    var verification: [URL: [Breakpoint]] = [:]
    for request in requests {
      let response = try await prepared.setBreakpoints(
        in: request.url,
        breakpoints: request.breakpoints,
        sourceModified: request.sourceModified
      )
      verification[request.url] = response
      breakpointController.applyVerification(
        documentURL: request.url,
        sentRecords: request.records,
        responses: response
      )
    }
    debugBreakpointVerification = verification
    breakpointController.reload()
  }

  private struct PreparedBreakpointRequest {
    let url: URL
    let records: [EditorStoredBreakpoint]
    let breakpoints: [SourceBreakpoint]
    let sourceModified: Bool
  }

  private func preparedBreakpointRequests() -> [PreparedBreakpointRequest] {
    for tab in tabs {
      EditorBreakpointStore.save(tab.breakpoints, for: tab.url)
      _ = EditorBreakpointStore.relocateRecords(for: tab.url, in: tab.text)
    }
    var recordsByURL = EditorBreakpointStore.allRecords(under: workspaceURL)
    for tab in tabs {
      recordsByURL[tab.url.standardizedFileURL] = EditorBreakpointStore.loadRecords(for: tab.url)
    }
    return recordsByURL.keys.sorted(by: { $0.path < $1.path }).map { url in
      var records = recordsByURL[url, default: []]
      if let tab = tabs.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
        records = EditorBreakpointStore.relocateRecords(for: url, in: tab.text)
      } else if let text = try? String(contentsOf: url, encoding: .utf8) {
        records = EditorBreakpointStore.relocateRecords(for: url, in: text)
      }
      let sentRecords = records.filter { record in
        record.isEnabled
          && (record.resolvedLine != nil || record.lineTextHash == nil)
      }
      let values = sentRecords.map { record in
        SourceBreakpoint(
          line: record.resolvedLine ?? record.requestedLine,
          condition: record.condition,
          hitCondition: record.hitCondition,
          logMessage: record.logMessage
        )
      }
      return PreparedBreakpointRequest(
        url: url,
        records: sentRecords,
        breakpoints: values,
        sourceModified: tabs.first(where: {
          $0.url.standardizedFileURL == url.standardizedFileURL
        })?.isDirty ?? false
      )
    }
  }

  private func synchronizeBreakpoints(using backend: MultiLanguageEditorBackend) async throws {
    for tab in tabs {
      EditorBreakpointStore.save(tab.breakpoints, for: tab.url)
      _ = EditorBreakpointStore.relocateRecords(for: tab.url, in: tab.text)
    }

    var workspaceBreakpoints = EditorBreakpointStore.allRecords(under: workspaceURL)
    var modifiedByURL: [URL: Bool] = [:]
    for tab in tabs {
      let key = tab.url.standardizedFileURL
      workspaceBreakpoints[key] = EditorBreakpointStore.loadRecords(for: key)
      modifiedByURL[key] = tab.isDirty
    }

    var verification: [URL: [Breakpoint]] = [:]
    for url in workspaceBreakpoints.keys.sorted(by: { $0.path < $1.path }) {
      var records = workspaceBreakpoints[url, default: []]
      if !tabs.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
        let text = try? String(contentsOf: url, encoding: .utf8)
      {
        records = EditorBreakpointStore.relocateRecords(for: url, in: text)
      }
      let sentRecords = records.filter { record in
        record.isEnabled
          && (record.resolvedLine != nil || record.lineTextHash == nil)
      }
      let values = sentRecords.map { record in
        SourceBreakpoint(
          line: record.resolvedLine ?? record.requestedLine,
          condition: record.condition,
          hitCondition: record.hitCondition,
          logMessage: record.logMessage
        )
      }
      let response = try await backend.setBreakpoints(
        in: url,
        breakpoints: values,
        sourceModified: modifiedByURL[url] ?? false
      )
      verification[url] = response
      breakpointController.applyVerification(
        documentURL: url,
        sentRecords: sentRecords,
        responses: response
      )
    }
    debugBreakpointVerification = verification
    breakpointController.reload()
  }

  private func synchronizeBreakpoints(
    for tab: EditorTab,
    using backend: MultiLanguageEditorBackend
  ) async throws {
    EditorBreakpointStore.save(tab.breakpoints, for: tab.url)
    let records = EditorBreakpointStore.relocateRecords(for: tab.url, in: tab.text)
    let sentRecords = records.filter { record in
      record.isEnabled
        && (record.resolvedLine != nil || record.lineTextHash == nil)
    }
    let values = sentRecords.map { record in
      SourceBreakpoint(
        line: record.resolvedLine ?? record.requestedLine,
        condition: record.condition,
        hitCondition: record.hitCondition,
        logMessage: record.logMessage
      )
    }
    let verification = try await backend.setBreakpoints(
      in: tab.url,
      breakpoints: values,
      sourceModified: tab.isDirty
    )
    debugBreakpointVerification[tab.url.standardizedFileURL] = verification
    breakpointController.applyVerification(
      documentURL: tab.url,
      sentRecords: sentRecords,
      responses: verification
    )
  }

  private func performThreadCommand(
    _ command: (MultiLanguageEditorBackend, Int) async throws -> Void
  ) async {
    guard let backend = ideWorkspace?.backend else { return }
    do {
      let thread = try await resolvedThreadID(using: backend)
      try await command(backend, thread)
    } catch {
      debugPhase = .failed(error.localizedDescription)
      appendDebugMessage(error.localizedDescription)
    }
  }

  private func resolvedThreadID(using backend: MultiLanguageEditorBackend) async throws -> Int {
    if let activeThreadID { return activeThreadID }
    guard let first = try await backend.debugThreads().first else {
      throw EditorWorkspaceRuntimeError.noDebugThread
    }
    activeThreadID = first.id
    return first.id
  }

  private var backendObservationTaskKeys: [WorkspaceTaskKey] {
    [
      .backendMessages,
      .backendDiagnostics,
      .sourceWorkspaceEvents,
      .debugEvents,
      .debugStandardError,
      .debugTransportErrors,
    ]
  }

  private func observeBackend(_ backend: MultiLanguageEditorBackend) {
    cancelBackendObservationTasks()
    backendObservationGeneration &+= 1
    let generation = backendObservationGeneration

    taskSupervisor.replace(.backendMessages) { [weak self] lease in
      for await message in backend.languageServerMessages {
        guard !Task.isCancelled, let self, self.taskSupervisor.isCurrent(lease),
          generation == self.backendObservationGeneration,
          !self.isShuttingDown, !self.hasShutDown
        else { return }
        let service = message.serviceIdentifier.map { "[\($0)] " } ?? ""
        self.appendDebugMessage("LSP \(service)\(message.message)")
        if message.kind == .error,
          message.message.hasPrefix(Self.unexpectedLanguageServerTerminationPrefix)
        {
          self.scheduleLanguageServiceRecovery(
            for: message.serviceIdentifier ?? "unknown"
          )
        }
      }
    }
    projectDiagnosticsByService.removeAll(keepingCapacity: true)
    projectDiagnostics.removeAll(keepingCapacity: true)
    diagnosticsRevision &+= 1
    taskSupervisor.replace(.backendDiagnostics) { [weak self] lease in
      for await batch in backend.diagnostics {
        guard !Task.isCancelled, let self, self.taskSupervisor.isCurrent(lease),
          generation == self.backendObservationGeneration,
          !self.isShuttingDown, !self.hasShutDown
        else { return }
        self.applyProjectDiagnosticBatch(batch)
      }
    }
    taskSupervisor.replace(.sourceWorkspaceEvents) { [weak self] lease in
      let events = await backend.sourceWorkspaceEvents()
      for await event in events {
        guard !Task.isCancelled, let self, self.taskSupervisor.isCurrent(lease),
          generation == self.backendObservationGeneration,
          !self.isShuttingDown, !self.hasShutDown
        else { return }
        await self.handleSourceWorkspaceEvent(event, backend: backend)
      }
    }
    taskSupervisor.replace(.debugEvents) { [weak self] lease in
      for await envelope in backend.debugEventEnvelopes {
        guard !Task.isCancelled, let self, self.taskSupervisor.isCurrent(lease),
          generation == self.backendObservationGeneration,
          !self.isShuttingDown, !self.hasShutDown
        else { return }
        await self.handleDebugEvent(
          envelope.event,
          backend: backend,
          backendGeneration: envelope.generation
        )
      }
    }
    taskSupervisor.replace(.debugStandardError) { [weak self] lease in
      for await envelope in backend.debugAdapterStandardErrorEnvelopes {
        guard !Task.isCancelled, let self, self.taskSupervisor.isCurrent(lease),
          generation == self.backendObservationGeneration,
          self.activeBackendDebugGeneration == envelope.generation,
          !self.isShuttingDown, !self.hasShutDown
        else { continue }
        self.appendDebugMessage(
          "DAP stderr: \(envelope.text)",
          channel: .adapter,
          severity: .warning
        )
      }
    }
    taskSupervisor.replace(.debugTransportErrors) { [weak self] lease in
      for await envelope in backend.debugTransportErrorEnvelopes {
        guard !Task.isCancelled, let self, self.taskSupervisor.isCurrent(lease),
          generation == self.backendObservationGeneration,
          self.activeBackendDebugGeneration == envelope.generation,
          !self.isShuttingDown, !self.hasShutDown
        else { continue }
        let error = envelope.text
        self.appendDebugMessage(
          "DAP: \(error)",
          channel: .adapter,
          severity: .error
        )
        if error.hasPrefix(Self.unexpectedDebugAdapterTerminationPrefix),
          !self.isReplacingDebugSession
        {
          self.activeThreadID = nil
          self.activeBackendDebugGeneration = nil
          self.clearDebugInspection()
          self.debugBreakpointVerification.removeAll(keepingCapacity: true)
          self.debugPhase = .failed(error)
          self.stabilityRecorder.record(
            .error,
            "debug-adapter-terminated",
            detail: error,
            metadata: ["workspace": self.workspaceURL.path]
          )
        }
      }
    }
  }

  private static let unexpectedDebugAdapterTerminationPrefix =
    "DAP process terminated unexpectedly"

  private static let unexpectedLanguageServerTerminationPrefix =
    "Language server process terminated unexpectedly"

  private func scheduleLanguageServiceRecovery(for serviceIdentifier: String) {
    guard runtimeState == .running, !isShuttingDown, !hasShutDown else { return }
    guard let decision = serviceRecoveryPolicy.nextDecision(for: serviceIdentifier) else {
      let message =
        "Automatic restart was stopped for \(serviceIdentifier) after repeated failures."
      appendDebugMessage(message)
      stabilityRecorder.record(
        .warning,
        "language-service-restart-suppressed",
        detail: message,
        metadata: [
          "service": serviceIdentifier,
          "workspace": workspaceURL.path,
        ]
      )
      return
    }

    let key = WorkspaceTaskKey.languageServiceRecovery(serviceIdentifier)
    taskSupervisor.replace(key) { [weak self] lease in
      do {
        try await Task.sleep(for: decision.delay)
      } catch {
        return
      }
      guard let self, !Task.isCancelled, self.taskSupervisor.isCurrent(lease),
        self.runtimeState == .running, !self.isShuttingDown, !self.hasShutDown
      else { return }
      self.stabilityRecorder.record(
        .languageService,
        "language-service-restart",
        metadata: [
          "service": serviceIdentifier,
          "attempt": String(decision.attempt),
          "workspace": self.workspaceURL.path,
        ]
      )
      self.appendDebugMessage(
        "Restarting Editor Services after \(serviceIdentifier) exited "
          + "(attempt \(decision.attempt))."
      )
      self.enqueueServicesReconfiguration(
        self.servicesConfiguration,
        requiresSuccessfulSave: false
      )
    }
  }

  @discardableResult
  private func cancelBackendObservationTasks() -> [Task<Void, Never>] {
    backendObservationGeneration &+= 1
    return backendObservationTaskKeys.compactMap { taskSupervisor.cancelReturningTask($0) }
  }

  private func cancelBackendObservationTasksAndWait() async {
    let tasks = cancelBackendObservationTasks()
    for task in tasks { await task.value }
  }

  private func recordRecentlyChangedSourceFiles(from event: SourceWorkspaceEvent) {
    let urls: [URL] =
      switch event {
      case .added(let file), .changed(let file), .saved(let file), .conflict(let file),
        .reloaded(let file):
        [file.url]
      case .moved(_, _, let file):
        [file.url]
      case .removed(_, let relativePath):
        [workspaceURL.appendingPathComponent(relativePath)]
      case .scanned, .scanFailed, .restored:
        []
      }
    guard !urls.isEmpty else { return }
    let sourceExtensions = ExternalSourceIndexConfiguration.commonExternalSourceExtensions
    var ordered = recentlyChangedSourceFiles
    for url in urls.map(\.standardizedFileURL) {
      guard sourceExtensions.contains(url.pathExtension.lowercased()) else { continue }
      ordered.removeAll { $0 == url }
      ordered.append(url)
    }
    if ordered.count > 128 { ordered.removeFirst(ordered.count - 128) }
    recentlyChangedSourceFiles = ordered
  }

  private func handleSourceWorkspaceEvent(
    _ event: SourceWorkspaceEvent,
    backend: MultiLanguageEditorBackend
  ) async {
    recordRecentlyChangedSourceFiles(from: event)
    let changes = await workspaceFileChanges(for: event, backend: backend)
    if !changes.isEmpty {
      do {
        try await backend.notifyWorkspaceFileChanges(changes)
      } catch {
        appendDebugMessage("LSP workspace update failed: \(error.localizedDescription)")
      }

      for change in changes where change.kind != .deleted {
        let key = change.uri.standardizedFileURL
        guard !tabs.contains(where: { $0.url.standardizedFileURL == key }) else { continue }
        if let batch = try? await backend.pullDiagnostics(for: key) {
          applyProjectDiagnosticBatch(batch)
        }
      }
    }

    switch event {
    case .conflict(let file):
      let url = file.url.standardizedFileURL
      let message = "\(file.name) changed on disk while it is open in the editor."
      let tab = tabs.first { $0.url.standardizedFileURL == url }
      tab?.reportExternalFileIssue(message)
      externalConflictIDs[url] = file.id
      enqueueExternalFileConflict(
        EditorExternalFileConflict(url: url, message: message)
      )
      appendDebugMessage("Workspace conflict: \(file.relativePath)")
      if EditorInterfacePreferences.selectedInterface.usesTerminalEditor,
        tab?.isDirty == false,
        externalFileConflict?.url.standardizedFileURL == url
      {
        resolveExternalFileConflict(using: .useDisk)
      }
    case .removed(_, let relativePath):
      scheduleProjectContextRefresh()
      let url = workspaceURL.appendingPathComponent(relativePath).standardizedFileURL
      clearProjectDiagnostics(for: url)
      guard let tab = tabs.first(where: { $0.url.standardizedFileURL == url }) else { return }
      let message = "\(tab.title) was removed from disk. Save it to recreate the file."
      tab.reportExternalFileIssue(message)
      fileOperationError = message
      appendDebugMessage("Workspace file removed: \(relativePath)")
    case .scanFailed(let message):
      appendDebugMessage("Workspace scan failed: \(message)")
    case .moved(_, let oldRelativePath, _):
      let oldURL = workspaceURL.appendingPathComponent(oldRelativePath).standardizedFileURL
      clearProjectDiagnostics(for: oldURL)
      scheduleProjectContextRefresh()
    case .added:
      scheduleProjectContextRefresh()
    case .changed, .saved, .reloaded, .restored:
      runAuxiliaryTask("invalidate-project-symbols") { [weak self] _ in
        guard let self else { return }
        await self.symbolResolver.invalidate()
      }
    case .scanned:
      break
    }
  }

  private func workspaceFileChanges(
    for event: SourceWorkspaceEvent,
    backend: MultiLanguageEditorBackend
  ) async -> [EditorWorkspaceFileChange] {
    switch event {
    case .added(let file):
      return [.init(uri: file.url.standardizedFileURL, kind: .created)]
    case .changed(let file), .saved(let file), .reloaded(let file), .conflict(let file):
      return [.init(uri: file.url.standardizedFileURL, kind: .changed)]
    case .moved(_, let oldRelativePath, let file):
      return [
        .init(
          uri: workspaceURL.appendingPathComponent(oldRelativePath).standardizedFileURL,
          kind: .deleted),
        .init(uri: file.url.standardizedFileURL, kind: .created),
      ]
    case .removed(_, let relativePath):
      return [
        .init(
          uri: workspaceURL.appendingPathComponent(relativePath).standardizedFileURL,
          kind: .deleted)
      ]
    case .scanned(let report):
      let created = await files(for: report.added, backend: backend).map {
        EditorWorkspaceFileChange(uri: $0.url.standardizedFileURL, kind: .created)
      }
      let changed = await files(for: report.refreshed, backend: backend).map {
        EditorWorkspaceFileChange(uri: $0.url.standardizedFileURL, kind: .changed)
      }
      return created + changed
    case .restored(let report):
      let created = await files(for: report.imported, backend: backend).map {
        EditorWorkspaceFileChange(uri: $0.url.standardizedFileURL, kind: .created)
      }
      let changed = await files(for: report.replaced, backend: backend).map {
        EditorWorkspaceFileChange(uri: $0.url.standardizedFileURL, kind: .changed)
      }
      return created + changed
    case .scanFailed:
      return []
    }
  }

  private func files(
    for ids: [SourceFileID],
    backend: MultiLanguageEditorBackend
  ) async -> [SourceCodeFile] {
    var result: [SourceCodeFile] = []
    result.reserveCapacity(ids.count)
    for id in ids {
      if let file = try? await backend.sourceFile(id: id) { result.append(file) }
    }
    return result
  }

  private func applyProjectDiagnosticBatch(_ batch: DiagnosticBatch) {
    let url = batch.uri.standardizedFileURL
    let aggregateKey = "__calcite_merged__"
    var buckets = projectDiagnosticsByService[url] ?? [:]

    if let serviceIdentifier = batch.serviceIdentifier {
      buckets.removeValue(forKey: aggregateKey)
      if batch.diagnostics.isEmpty {
        buckets.removeValue(forKey: serviceIdentifier)
      } else {
        buckets[serviceIdentifier] = batch.diagnostics
      }
    } else {
      let hasServiceSpecificBatch = buckets.keys.contains { $0 != aggregateKey }
      if !hasServiceSpecificBatch {
        if batch.diagnostics.isEmpty {
          buckets.removeValue(forKey: aggregateKey)
        } else {
          buckets[aggregateKey] = batch.diagnostics
        }
      }
    }

    if buckets.isEmpty {
      projectDiagnosticsByService.removeValue(forKey: url)
      projectDiagnostics.removeValue(forKey: url)
    } else {
      projectDiagnosticsByService[url] = buckets
      var seen = Set<Diagnostic>()
      let merged = buckets.keys.sorted().flatMap { buckets[$0] ?? [] }.filter {
        seen.insert($0).inserted
      }
      if merged.isEmpty {
        projectDiagnostics.removeValue(forKey: url)
      } else {
        projectDiagnostics[url] = merged
      }
    }
    diagnosticsRevision &+= 1
  }

  private func clearProjectDiagnostics(for url: URL) {
    let key = url.standardizedFileURL
    projectDiagnosticsByService.removeValue(forKey: key)
    projectDiagnostics.removeValue(forKey: key)
    diagnosticsRevision &+= 1
  }

  var closedDocumentDiagnostics: [EditorProjectDiagnosticGroup] {
    let openURLs = Set(tabs.map { $0.url.standardizedFileURL })
    return
      projectDiagnostics
      .filter { !openURLs.contains($0.key.standardizedFileURL) && !$0.value.isEmpty }
      .map { EditorProjectDiagnosticGroup(url: $0.key, diagnostics: $0.value) }
      .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
  }

  func openProjectDiagnostic(_ diagnostic: Diagnostic, at url: URL) {
    runAuxiliaryTask("open-project-diagnostic") { [weak self] lease in
      guard let self else { return }
      await self.openDocument(at: url)
      guard self.taskSupervisor.isCurrent(lease),
        let tab = self.tabs.first(where: {
          $0.url.standardizedFileURL == url.standardizedFileURL
        })
      else { return }
      let snapshot = TextSnapshot(text: tab.text)
      if let range = try? snapshot.nsRange(for: diagnostic.range) {
        tab.updateSelection(range)
      }
    }
  }

  private func enqueueExternalFileConflict(_ conflict: EditorExternalFileConflict) {
    let url = conflict.url.standardizedFileURL
    if externalFileConflict?.url.standardizedFileURL == url { return }
    if pendingExternalFileConflicts.contains(where: {
      $0.url.standardizedFileURL == url
    }) {
      return
    }
    if externalFileConflict == nil {
      externalFileConflict = conflict
    } else {
      pendingExternalFileConflicts.append(conflict)
    }
  }

  private func presentNextExternalFileConflict() {
    while !pendingExternalFileConflicts.isEmpty {
      let next = pendingExternalFileConflicts.removeFirst()
      let url = next.url.standardizedFileURL
      guard externalConflictIDs[url] != nil else { continue }
      externalFileConflict = next
      return
    }
  }

  private func handleDebugEvent(
    _ event: DAPEvent,
    backend: MultiLanguageEditorBackend,
    backendGeneration: UInt64
  ) async {
    guard activeBackendDebugGeneration == backendGeneration else {
      appendDebugMessage(
        "Ignored stale DAP event \(event.event) from generation \(backendGeneration)."
      )
      return
    }
    if isReplacingDebugSession,
      event.event == "terminated" || event.event == "exited"
    {
      appendDebugMessage("Ignored \(event.event) from the debug session being replaced.")
      return
    }
    let sessionGeneration = debugSessionGeneration
    appendDebugMessage("DAP event: \(event.event)", channel: .adapter)
    switch event.event {
    case "output":
      if let body = event.body,
        let output = try? body.decode(OutputEventBody.self)
      {
        let channel: EditorExecutionChannel
        switch output.category?.lowercased() {
        case "stderr", "stdout": channel = .debuggee
        case "console", "telemetry": channel = .adapter
        default: channel = .debugger
        }
        let location: EditorExecutionSourceLocation? = {
          guard let path = output.source?.path, !path.isEmpty else { return nil }
          return EditorExecutionSourceLocation(
            url: URL(fileURLWithPath: path),
            line: output.line ?? 1,
            column: output.column ?? 1
          )
        }()
        appendExecutionMessage(
          output.output,
          channel: channel,
          severity: output.category?.lowercased() == "stderr" ? .warning : .info,
          sourceLocation: location
        )
        if !output.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          debugConsole.append(output.output.trimmingCharacters(in: .newlines))
          if debugConsole.count > 500 { debugConsole.removeFirst(debugConsole.count - 500) }
        }
      }
    case "stopped":
      debugPhase = .stopped
      await refreshDebugInspection(using: backend, sessionGeneration: sessionGeneration)
    case "continued":
      clearDebugInspection()
      debugPhase = .running
    case "terminated":
      activeThreadID = nil
      activeDebugSourceFingerprint = nil
      activeBackendDebugGeneration = nil
      debugExecutionSessionID = nil
      activeDebugLanguage = nil
      activeDebugLaunchTarget = nil
      clearDebugInspection()
      try? await backend.disconnectDebugger()
      debugPhase = .idle
    case "exited":
      activeThreadID = nil
      activeDebugSourceFingerprint = nil
      activeBackendDebugGeneration = nil
      debugExecutionSessionID = nil
      activeDebugLanguage = nil
      activeDebugLaunchTarget = nil
      clearDebugInspection()
      debugPhase = .idle
    default:
      break
    }
  }

  private func refreshDebugInspection(
    using backend: MultiLanguageEditorBackend,
    sessionGeneration: UInt64
  ) async {
    do {
      let threads = try await backend.debugThreads()
      guard sessionGeneration == debugSessionGeneration, !isReplacingDebugSession else { return }
      debugThreads = threads
      guard let thread = threads.first else {
        activeThreadID = nil
        debugFrames = []
        debugScopes = []
        return
      }
      activeThreadID = thread.id
      let trace = try await backend.stackTrace(threadID: thread.id, levels: 100)
      guard sessionGeneration == debugSessionGeneration, !isReplacingDebugSession else { return }
      debugFrames = trace.stackFrames
      guard let frame = trace.stackFrames.first else {
        selectedDebugFrameID = nil
        debugScopes = []
        return
      }
      selectedDebugFrameID = frame.id
      await loadDebugScopes(frameID: frame.id, backend: backend)
      await openDebugFrame(frame)
    } catch {
      appendDebugMessage("Debug inspection failed: \(error.localizedDescription)")
    }
  }

  private func loadDebugScopes(
    frameID: Int,
    backend: MultiLanguageEditorBackend
  ) async {
    do {
      let scopes = try await backend.scopes(frameID: frameID)
      var snapshots: [EditorDebugScopeSnapshot] = []
      for scope in scopes {
        let variables = try await backend.variables(
          reference: scope.variablesReference,
          start: 0,
          count: 250
        )
        snapshots.append(EditorDebugScopeSnapshot(scope: scope, variables: variables))
      }
      if selectedDebugFrameID == frameID { debugScopes = snapshots }
    } catch {
      appendDebugMessage("Variable loading failed: \(error.localizedDescription)")
    }
  }

  private func openDebugFrame(_ frame: StackFrame) async {
    guard let path = frame.source?.path, !path.isEmpty else { return }
    let url = URL(fileURLWithPath: path, relativeTo: workspaceURL).standardizedFileURL
    await openDocument(at: url)
    guard let tab = tabs.first(where: { $0.url.standardizedFileURL == url }) else { return }
    selectedTabID = tab.id
    tab.select(line: frame.line, column: frame.column)
  }

  private func clearDebugInspection() {
    debugThreads = []
    debugFrames = []
    debugScopes = []
    selectedDebugFrameID = nil
  }

  private func editorLanguage(for languageID: String) -> EditorLanguage? {
    EditorLanguage.allCases.first { $0.languageIDs.contains(languageID) }
  }

  private func resolvedDebugLanguage(in workspace: EditorIDEWorkspace) async -> EditorLanguage? {
    if let activeTab,
      let language = editorLanguage(for: activeTab.languageID),
      workspace.serviceResult.debugAdapter(for: language) != nil
    {
      return language
    }

    let configuredProgram = debugConfiguration.programPath
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !configuredProgram.isEmpty {
      let languageID = EditorLanguageCatalog.standard.languageID(
        for: URL(fileURLWithPath: configuredProgram, relativeTo: workspaceURL)
      )
      if let language = editorLanguage(for: languageID),
        workspace.serviceResult.debugAdapter(for: language) != nil
      {
        return language
      }
    }

    let projectLanguage: EditorLanguage? =
      switch buildController.plan.projectKind {
      case .xcode, .swiftPackage: .swift
      case .rustCargo: .rust
      case .goModule: .go
      case .nodePackage: .javascript
      case .python: .python
      case .gradle, .maven: .java
      case .zig: .zig
      case .cmake, .make, .generic: nil
      }
    if let projectLanguage, workspace.serviceResult.debugAdapter(for: projectLanguage) != nil {
      return projectLanguage
    }

    for file in await workspace.backend.sourceFiles() {
      let languageID = EditorLanguageCatalog.standard.languageID(for: file.url)
      guard let language = editorLanguage(for: languageID) else { continue }
      if workspace.serviceResult.debugAdapter(for: language) != nil { return language }
    }
    return nil
  }

  private func navigateToDefinition() {
    runAuxiliaryTask("navigate-definition") { [weak self] lease in
      guard let self, let tab = self.activeTab else { return }
      do {
        var locations = try await tab.definitionsAtSelection()
        guard self.taskSupervisor.isCurrent(lease) else { return }
        if locations.isEmpty, let symbol = tab.symbolAtSelection {
          locations = await self.symbolResolver.definitionLocations(
            for: symbol,
            originatingURL: tab.url,
            inMemoryDocuments: self.openDocumentTexts
          )
        }
        guard self.taskSupervisor.isCurrent(lease) else { return }
        locations = uniqueSourceLocations(locations)
        guard let first = locations.first else {
          self.symbolInformation = EditorSymbolInformation(
            title: tab.symbolAtSelection ?? "Definition",
            markdown:
              "No definition was found by the language service or the project symbol fallback."
          )
          return
        }
        if locations.count > 1 {
          self.symbolLocations = EditorSymbolLocationCollection(
            title: "Definitions of \(tab.symbolAtSelection ?? "Symbol")",
            locations: locations
          )
        } else {
          await self.openSourceLocation(first)
        }
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.symbolInformation = EditorSymbolInformation(
          title: tab.symbolAtSelection ?? "Definition",
          markdown: "Definition lookup failed: \(error.localizedDescription)"
        )
      }
    }
  }

  private func navigateToReferences() {
    runAuxiliaryTask("navigate-references") { [weak self] lease in
      guard let self, let tab = self.activeTab else { return }
      do {
        var locations = try await tab.referencesAtSelection()
        guard self.taskSupervisor.isCurrent(lease) else { return }
        if locations.isEmpty, let symbol = tab.symbolAtSelection {
          locations = await self.symbolResolver.referenceLocations(
            for: symbol,
            originatingURL: tab.url,
            inMemoryDocuments: self.openDocumentTexts
          )
        }
        guard self.taskSupervisor.isCurrent(lease) else { return }
        locations = uniqueSourceLocations(locations)
        guard !locations.isEmpty else {
          self.symbolInformation = EditorSymbolInformation(
            title: tab.symbolAtSelection ?? "References",
            markdown:
              "No references were found by the language service or the project symbol fallback."
          )
          return
        }
        self.symbolLocations = EditorSymbolLocationCollection(
          title: "References to \(tab.symbolAtSelection ?? "Symbol")",
          locations: locations
        )
      } catch {
        guard self.taskSupervisor.isCurrent(lease) else { return }
        self.symbolInformation = EditorSymbolInformation(
          title: tab.symbolAtSelection ?? "References",
          markdown: "Reference lookup failed: \(error.localizedDescription)"
        )
      }
    }
  }

  private var openDocumentTexts: [URL: String] {
    Dictionary(uniqueKeysWithValues: tabs.map { ($0.url.standardizedFileURL, $0.text) })
  }

  private func uniqueSourceLocations(_ locations: [SourceLocation]) -> [SourceLocation] {
    var seen = Set<SourceLocation>()
    return locations.filter { seen.insert($0).inserted }
  }

  private func openSourceLocation(_ location: SourceLocation) async {
    await openDocument(at: location.uri)
    guard
      let tab = tabs.first(where: {
        $0.url.standardizedFileURL == location.uri.standardizedFileURL
      })
    else { return }
    selectedTabID = tab.id
    let snapshot = TextSnapshot(text: tab.text)
    if let range = try? snapshot.nsRange(for: location.range) {
      tab.updateSelection(range)
    }
  }

  private func applyBuildDiagnostics(_ values: [EditorBuildDiagnostic]) {
    let grouped = Dictionary(grouping: values) { $0.url.standardizedFileURL }
    for tab in tabs {
      tab.setBuildDiagnostics(grouped[tab.url.standardizedFileURL] ?? [])
    }
  }

  private func clearSupersededServiceDiagnosticsAfterSuccessfulBuild() {
    for tab in tabs {
      tab.clearSupersededServiceDiagnosticsAfterSuccessfulBuild()
    }
  }

  private func selectAdjacentTab(delta: Int) {
    guard let selectedTabID,
      let index = tabs.firstIndex(where: { $0.id == selectedTabID }),
      !tabs.isEmpty
    else { return }
    let next = (index + delta + tabs.count) % tabs.count
    self.selectedTabID = tabs[next].id
  }

  private func handleVimCustomCommand(_ command: String) {
    switch command.lowercased() {
    case "build": onVimCommand?(.build)
    case "run": onVimCommand?(.run)
    case "test": onVimCommand?(.test)
    case "check": onVimCommand?(.check)
    case "debug": onVimCommand?(.startDebug)
    case "terminal":
      onVimCommand?(.showTerminal)
    case "problems":
      onVimCommand?(.showProblems)
    case "save-all":
      onVimCommand?(.saveAll)
    case "force-quit":
      if let tab = activeTab { closeTab(tab) }
    case "find":
      onVimCommand?(.find)
    case "replace":
      onVimCommand?(.replace)
    case "sidebar", "toggle-sidebar":
      onVimCommand?(.toggleSidebar)
    case "next-diagnostic":
      navigateVimDiagnostic(forward: true)
    case "previous-diagnostic":
      navigateVimDiagnostic(forward: false)
    default:
      appendDebugMessage("Unknown Vim command: \(command)")
    }
  }

  private func navigateVimDiagnostic(forward: Bool) {
    guard let tab = activeTab, !tab.diagnostics.isEmpty else { return }
    let snapshot = TextSnapshot(text: tab.text)
    let ranges = tab.diagnostics.compactMap { diagnostic in
      try? snapshot.nsRange(for: diagnostic.range)
    }.sorted { lhs, rhs in
      if lhs.location == rhs.location { return lhs.length < rhs.length }
      return lhs.location < rhs.location
    }
    guard !ranges.isEmpty else { return }

    let cursor = tab.selectedRange.location
    let target: NSRange
    if forward {
      target = ranges.first(where: { $0.location > cursor }) ?? ranges[0]
    } else {
      target = ranges.last(where: { $0.location < cursor }) ?? ranges[ranges.count - 1]
    }
    tab.updateSelection(target)
  }

  private func scheduleSessionPersistence() {
    guard hasRestoredSession, !isShuttingDown, !hasShutDown else { return }
    taskSupervisor.replace(.sessionPersistence) { [weak self] lease in
      do {
        try await Task.sleep(for: .milliseconds(350))
      } catch {
        return
      }
      guard let self, !Task.isCancelled, self.taskSupervisor.isCurrent(lease) else { return }
      await self.persistWorkspaceSession()
    }
  }

  private func persistWorkspaceSession(includeRecoveries: Bool = true) async {
    let selectedURL = activeTab?.url
    let recoveries =
      includeRecoveries
      ? tabs.compactMap { tab -> EditorSessionRecoveryInput? in
        guard tab.isDirty else { return nil }
        return EditorSessionRecoveryInput(
          url: tab.url,
          text: tab.text,
          diskModificationTime: tab.diskModificationTime
        )
      }
      : []
    let presentation = capturePresentationSnapshot?()

    do {
      let report = try await sessionStore.save(
        openDocuments: tabs.map {
          EditorSessionOpenDocumentInput(id: $0.id, url: $0.url)
        },
        selectedURL: selectedURL,
        recoveredDocuments: recoveries,
        presentation: presentation
      )
      if report.hasOmissions {
        let message =
          "Some modified files were not included in crash recovery:\n"
          + report.omittedDocuments.joined(separator: "\n")
        if recoveryWarning != message { recoveryWarning = message }
        appendDebugMessage(message)
      }
    } catch {
      appendDebugMessage("Workspace recovery could not be saved: \(error.localizedDescription)")
    }
  }

  private func restoreWorkspaceSession() async {
    guard let workspace = ideWorkspace else { return }
    let restoration = await sessionStore.load()
    guard !restoration.openRelativePaths.isEmpty || !restoration.recoveredDocuments.isEmpty else {
      return
    }

    let recoveryByPath = Dictionary(
      uniqueKeysWithValues: restoration.recoveredDocuments.map { ($0.relativePath, $0) }
    )
    var restoredTabsByPath: [String: EditorTab.ID] = [:]
    var newlyRestoredTabs: [EditorTab] = []
    var recoveryWarnings: [String] = []

    for path in restoration.openRelativePaths {
      guard let url = await sessionStore.url(forRelativePath: path), isRegularFile(url) else {
        continue
      }

      let tab: EditorTab
      if let existing = tabs.first(where: { $0.url.standardizedFileURL == url }) {
        tab = existing
      } else {
        do {
          tab = try await makeEditorTab(
            at: url,
            using: workspace,
            id: restoration.documentID(forRelativePath: path) ?? UUID()
          )
          newlyRestoredTabs.append(tab)
        } catch {
          recoveryWarnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
          continue
        }
      }
      restoredTabsByPath[path] = tab.id

      guard let recovery = recoveryByPath[path] else { continue }
      if await sessionStore.diskStillMatches(recovery, at: url) {
        do {
          try await tab.restoreRecoveredText(recovery.text)
        } catch {
          recoveryWarnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
        }
      } else {
        recoveryWarnings.append(
          "\(url.lastPathComponent) changed on disk, so its recovery snapshot was not applied."
        )
      }
    }

    if !newlyRestoredTabs.isEmpty {
      tabs.append(contentsOf: newlyRestoredTabs)
    }
    if let selected = restoration.selectedRelativePath,
      let id = restoredTabsByPath[selected]
    {
      selectedTabID = id
    } else if selectedTabID == nil {
      selectedTabID = tabs.first?.id
    }
    if let presentation = restoration.presentation {
      restorePresentationSnapshot?(presentation)
    }
    if !recoveryWarnings.isEmpty {
      fileOperationError = recoveryWarnings.joined(separator: "\n")
      for warning in recoveryWarnings {
        appendDebugMessage(warning)
      }
    }
    scheduleSessionPersistence()
  }

  private func appendDebugMessage(
    _ message: String,
    channel: EditorExecutionChannel = .system,
    severity: EditorExecutionSeverity = .info,
    sourceLocation: EditorExecutionSourceLocation? = nil
  ) {
    logStore.log(.debug, category: "Editor", message: message)
    debugConsole.append(message)
    if debugConsole.count > 500 { debugConsole.removeFirst(debugConsole.count - 500) }
    appendExecutionMessage(
      message.hasSuffix("\n") ? message : message + "\n",
      channel: channel,
      severity: severity,
      sourceLocation: sourceLocation
    )
  }

  private func appendExecutionMessage(
    _ text: String,
    channel: EditorExecutionChannel,
    severity: EditorExecutionSeverity = .info,
    sourceLocation: EditorExecutionSourceLocation? = nil
  ) {
    buildController.executionEvents.append(
      operationID: debugExecutionOperationID,
      sessionID: debugExecutionSessionID,
      channel: channel,
      severity: severity,
      text: text,
      sourceLocation: sourceLocation
    )
  }

  private func performFileOperation(
    _ name: String,
    operation: (MultiLanguageEditorBackend) async throws -> Void
  ) async -> Bool {
    guard let backend = ideWorkspace?.backend else {
      fileOperationError = "Editor Services are not ready."
      return false
    }
    let operationID = logStore.beginOperation(name, category: "Files")
    do {
      try await operation(backend)
      _ = try? await backend.scanSourceWorkspace()
      let externalReport = await backend.externalSourceIndexReport()
      await symbolResolver.invalidate()
      fileOperationError = nil
      logStore.finishOperation(
        operationID,
        metadata: ["external_files": String(externalReport.indexedFileCount)]
      )
      return true
    } catch {
      fileOperationError = "\(name) failed: \(error.localizedDescription)"
      appendDebugMessage(fileOperationError ?? error.localizedDescription)
      logStore.finishOperation(operationID, level: .error, message: fileOperationError)
      return false
    }
  }

  private func childURL(named rawName: String, in directory: URL) throws -> URL {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
      name != ".",
      name != "..",
      !name.contains("/"),
      !name.contains(":")
    else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    let destination = directory.appendingPathComponent(name).standardizedFileURL
    _ = try relativePath(for: destination)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    return destination
  }

  private func relativePath(for url: URL) throws -> String {
    let root = workspaceURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path == root || path.hasPrefix(root + "/") else {
      throw CocoaError(.fileWriteNoPermission)
    }
    let relative = String(path.dropFirst(root.count)).trimmingCharacters(
      in: CharacterSet(charactersIn: "/")
    )
    guard !relative.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
    return relative
  }

  private func availableDuplicateURL(for source: URL) throws -> URL {
    let directory = source.deletingLastPathComponent()
    let extensionName = source.pathExtension
    let stem = source.deletingPathExtension().lastPathComponent
    for index in 1...10_000 {
      let suffix = index == 1 ? " copy" : " copy \(index)"
      let fileName =
        extensionName.isEmpty
        ? stem + suffix
        : stem + suffix + "." + extensionName
      let candidate = directory.appendingPathComponent(fileName)
      if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    throw CocoaError(.fileWriteFileExists)
  }

  private func prepareTabsForMove(
    from source: URL,
    to destination: URL
  ) async throws -> [(source: URL, destination: URL)] {
    let sourcePath = source.standardizedFileURL.path
    let affected = tabs.filter {
      let path = $0.url.standardizedFileURL.path
      return path == sourcePath || path.hasPrefix(sourcePath + "/")
    }
    for tab in affected {
      guard await tab.save() else {
        throw EditorWorkspaceRuntimeError.unsavedDocument(tab.title)
      }
    }

    var reopenURLs: [(source: URL, destination: URL)] = []
    for tab in affected {
      let tabURL = tab.url.standardizedFileURL
      let suffix = String(tabURL.path.dropFirst(sourcePath.count))
      let newURL = URL(fileURLWithPath: destination.path + suffix).standardizedFileURL
      reopenURLs.append((tabURL, newURL))
      await tab.close()
      try? await ideWorkspace?.closeDocument(at: tabURL)
      tabs.removeAll { $0.id == tab.id }
      if selectedTabID == tab.id { selectedTabID = tabs.last?.id }
    }
    return reopenURLs
  }

  private func reopenDocuments(_ urls: [URL]) async {
    for url in urls where FileManager.default.fileExists(atPath: url.path) {
      await openDocument(at: url)
    }
  }

  private func moveItemUsingBackend(
    _ backend: MultiLanguageEditorBackend,
    from source: URL,
    to destination: URL
  ) async throws {
    let oldRelative = try relativePath(for: source)
    let newRelative = try relativePath(for: destination)
    let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    do {
      if isDirectory {
        try await backend.moveSourceDirectory(from: oldRelative, to: newRelative)
      } else {
        let file = try await backend.sourceFile(at: oldRelative)
        _ = try await backend.moveSourceFile(file.id, to: newRelative)
      }
    } catch let error as SourceWorkspaceError where error.isMissingWorkspaceItem {
      try await Task.detached(priority: .userInitiated) {
        try FileManager.default.moveItem(at: source, to: destination)
      }.value
    }
  }

  private func removeItemUsingBackend(
    _ backend: MultiLanguageEditorBackend,
    at target: URL
  ) async throws {
    let relative = try relativePath(for: target)
    let isDirectory = try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    do {
      if isDirectory {
        try await backend.removeSourceDirectory(at: relative, recursively: true)
      } else {
        let file = try await backend.sourceFile(at: relative)
        try await backend.removeSourceFile(file.id)
      }
    } catch let error as SourceWorkspaceError where error.isMissingWorkspaceItem {
      try await Task.detached(priority: .userInitiated) {
        try FileManager.default.removeItem(at: target)
      }.value
    }
  }

  private func removeOpenTabs(under url: URL) async {
    let path = url.standardizedFileURL.path
    let affected = tabs.filter {
      let tabPath = $0.url.standardizedFileURL.path
      return tabPath == path || tabPath.hasPrefix(path + "/")
    }
    for tab in affected {
      await tab.close()
      try? await ideWorkspace?.closeDocument(at: tab.url)
      tabs.removeAll { $0.id == tab.id }
      if selectedTabID == tab.id { selectedTabID = tabs.last?.id }
    }
  }

  private func isRegularFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }
}

extension SourceWorkspaceError {
  fileprivate var isMissingWorkspaceItem: Bool {
    switch self {
    case .fileNotFound, .directoryNotFound, .fileMissingOnDisk:
      return true
    default:
      return false
    }
  }
}

enum ShellArgumentParser {
  static func parse(_ source: String) -> [String] {
    var values: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false

    for character in source {
      if escaped {
        current.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if let activeQuote = quote {
        if character == activeQuote {
          quote = nil
        } else {
          current.append(character)
        }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character.isWhitespace {
        appendIfNeeded(&current, to: &values)
      } else {
        current.append(character)
      }
    }
    if escaped { current.append("\\") }
    appendIfNeeded(&current, to: &values)
    return values
  }

  private static func appendIfNeeded(_ current: inout String, to values: inout [String]) {
    if !current.isEmpty { values.append(current) }
    current.removeAll(keepingCapacity: true)
  }
}
