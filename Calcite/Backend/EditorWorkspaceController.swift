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

struct EditorDebugConfiguration: Codable, Equatable, Sendable {
  var programPath: String
  var arguments: String
  var workingDirectory: String
  var stopOnEntry: Bool
  var buildBeforeLaunch: Bool

  var argumentList: [String] { ShellArgumentParser.parse(arguments) }

  init(
    programPath: String,
    arguments: String,
    workingDirectory: String,
    stopOnEntry: Bool,
    buildBeforeLaunch: Bool = true
  ) {
    self.programPath = programPath
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.stopOnEntry = stopOnEntry
    self.buildBeforeLaunch = buildBeforeLaunch
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    programPath = try container.decode(String.self, forKey: .programPath)
    arguments = try container.decode(String.self, forKey: .arguments)
    workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
    stopOnEntry = try container.decode(Bool.self, forKey: .stopOnEntry)
    buildBeforeLaunch = try container.decodeIfPresent(Bool.self, forKey: .buildBeforeLaunch) ?? true
  }
}

@MainActor
final class EditorWorkspaceController: ObservableObject {
  let workspaceURL: URL
  let serviceSettingsModel: EditorServicesSettingsModel
  let buildController: EditorBuildController

  @Published private(set) var tabs: [EditorTab] = []
  @Published var selectedTabID: EditorTab.ID? {
    didSet { scheduleSessionPersistence() }
  }
  @Published private(set) var phase: EditorWorkspacePhase = .idle
  @Published private(set) var serviceReport = EditorServiceAvailabilityReport()
  @Published private(set) var diagnosticsRevision = 0
  @Published private(set) var isPreparingBuildTask = false
  @Published private(set) var debugPhase: EditorDebugPhase = .idle
  @Published private(set) var debugThreads: [DAPThread] = []
  @Published private(set) var debugFrames: [StackFrame] = []
  @Published private(set) var debugScopes: [EditorDebugScopeSnapshot] = []
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
  private var ideWorkspace: EditorIDEWorkspace?
  private var startTask: Task<EditorIDEWorkspace, Error>?
  private var startGeneration = 0
  private var messageTask: Task<Void, Never>?
  private var sourceWorkspaceTask: Task<Void, Never>?
  private var debugEventTask: Task<Void, Never>?
  private var debugStandardErrorTask: Task<Void, Never>?
  private var debugErrorTask: Task<Void, Never>?
  private var activeThreadID: Int?
  private var openingDocumentURLs: Set<URL> = []
  private var externalConflictIDs: [URL: SourceFileID] = [:]
  private var pendingExternalFileConflicts: [EditorExternalFileConflict] = []
  private var sessionPersistenceTask: Task<Void, Never>?
  private var projectContextRefreshTask: Task<Void, Never>?
  private var projectContextRefreshGeneration: UInt64 = 0
  private var reconfigurationTask: Task<Void, Never>?
  private var pendingServicesConfiguration: EditorServicesConfiguration?
  private var buildLaunchTask: Task<Void, Never>?
  private var debugOperationTask: Task<Void, Never>?
  private var debugInspectionTask: Task<Void, Never>?
  private var hasRestoredSession = false
  private var isShuttingDown = false
  private var hasShutDown = false

  var hasUnsavedDocuments: Bool { tabs.contains(where: \.isDirty) }

  var activeTab: EditorTab? {
    guard let selectedTabID else { return nil }
    return tabs.first { $0.id == selectedTabID }
  }

  init(workspaceURL: URL) {
    self.workspaceURL = workspaceURL.standardizedFileURL
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
    self.buildController = EditorBuildController(workspaceURL: workspaceURL)
    self.debugConfiguration =
      EditorDebugPreferencesStore.load(workspaceURL: workspaceURL)
      ?? EditorDebugConfiguration(
        programPath: "",
        arguments: "",
        workingDirectory: workspaceURL.path,
        stopOnEntry: false
      )
    self.buildController.onDiagnostics = { [weak self] diagnostics in
      self?.applyBuildDiagnostics(diagnostics)
    }
  }

  isolated deinit {
    startTask?.cancel()
    startTask = nil
    startGeneration &+= 1
    messageTask?.cancel()
    sourceWorkspaceTask?.cancel()
    debugEventTask?.cancel()
    debugStandardErrorTask?.cancel()
    debugErrorTask?.cancel()
    sessionPersistenceTask?.cancel()
    projectContextRefreshTask?.cancel()
    reconfigurationTask?.cancel()
    buildLaunchTask?.cancel()
    debugOperationTask?.cancel()
    debugInspectionTask?.cancel()
  }

  func start() async {
    guard !isShuttingDown else { return }
    if phase == .ready { return }
    phase = .starting
    let operationID: UUID?

    if startTask == nil {
      operationID = logStore.beginOperation(
        "Preparing editor services",
        category: "Workspace",
        detail: workspaceURL.path
      )
      startGeneration &+= 1
      let configuration = servicesConfiguration
      startTask = Task {
        try await EditorIDEWorkspace.open(
          configuration: configuration,
          documentConfiguration: .init(
            analysisDebounce: .milliseconds(70),
            semanticAnalysisDebounce: .milliseconds(500),
            includeSemanticHighlights: true
          )
        )
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
      phase = .ready
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
    } catch is CancellationError {
      guard generation == startGeneration else {
        if let operationID {
          logStore.finishOperation(
            operationID, level: .notice, message: "Editor startup superseded")
        }
        return
      }
      if ideWorkspace == nil { phase = .idle }
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
      phase = .failed(error.localizedDescription)
      if let operationID {
        logStore.finishOperation(operationID, level: .error, message: error.localizedDescription)
      }
    }
    if generation == startGeneration { startTask = nil }
  }

  func applyServicesConfiguration(_ configuration: EditorServicesConfiguration) {
    guard !isShuttingDown else { return }
    var configuration = configuration
    configuration.environment = resolvedPythonProcessEnvironment()
    pendingServicesConfiguration = configuration
    guard reconfigurationTask == nil else { return }
    reconfigurationTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled, let next = self.pendingServicesConfiguration {
        self.pendingServicesConfiguration = nil
        await self.reconfigure(using: next)
      }
      self.reconfigurationTask = nil
    }
  }

  func openDocument(at url: URL) async {
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
    selectedRange: NSRange? = nil
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
    tab.onDiagnosticsChange = { [weak self] in
      self?.diagnosticsRevision &+= 1
    }
    tab.onContentStateChange = { [weak self] in
      self?.scheduleSessionPersistence()
    }
    tab.setBuildDiagnostics(
      buildController.diagnostics.filter { $0.url.standardizedFileURL == key }
    )
    return tab
  }

  func closeTab(_ tab: EditorTab, saving: Bool = false) {
    Task { [weak self] in
      guard let self else { return }
      if saving, !(await tab.save()) { return }
      await tab.close()
      try? await self.ideWorkspace?.closeDocument(at: tab.url)
      withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
        self.tabs.removeAll { $0.id == tab.id }
        if self.selectedTabID == tab.id {
          self.selectedTabID = self.tabs.last?.id
        }
      }
      self.scheduleSessionPersistence()
    }
  }

  func saveActiveDocument() {
    guard let activeTab else { return }
    Task { await activeTab.save() }
  }

  @discardableResult
  func saveAllDocuments() async -> Bool {
    var succeeded = true
    for tab in tabs {
      if !(await tab.save()) { succeeded = false }
    }
    return succeeded
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
    guard buildLaunchTask == nil, !buildController.phase.isRunning else { return }
    isPreparingBuildTask = true
    buildLaunchTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isPreparingBuildTask = false
        self.buildLaunchTask = nil
      }
      guard await self.saveAllDocuments(), !Task.isCancelled,
        let target = self.resolvedBuildTask(kind)
      else { return }
      self.isPreparingBuildTask = false
      switch target {
      case .project(let command):
        if await self.buildController.run(command) {
          self.clearSupersededServiceDiagnosticsAfterSuccessfulBuild()
        }
      case .standalone(let fileURL, _):
        if await self.buildController.runSingleFile(fileURL, kind: kind) {
          self.clearSupersededServiceDiagnosticsAfterSuccessfulBuild()
        }
      }
    }
  }

  func runSelectedBuildTask() {
    guard buildLaunchTask == nil, !buildController.phase.isRunning else { return }
    isPreparingBuildTask = true
    buildLaunchTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isPreparingBuildTask = false
        self.buildLaunchTask = nil
      }
      guard await self.saveAllDocuments(), !Task.isCancelled else { return }
      self.isPreparingBuildTask = false
      if let selected = self.buildController.selectedCommand {
        if await self.buildController.run(selected) {
          self.clearSupersededServiceDiagnosticsAfterSuccessfulBuild()
        }
      } else if let target = self.resolvedBuildTask(.run) {
        switch target {
        case .project(let command):
          if await self.buildController.run(command) {
            self.clearSupersededServiceDiagnosticsAfterSuccessfulBuild()
          }
        case .standalone(let fileURL, _):
          if await self.buildController.runSingleFile(fileURL, kind: .run) {
            self.clearSupersededServiceDiagnosticsAfterSuccessfulBuild()
          }
        }
      }
    }
  }

  func cancelBuildTask() {
    buildLaunchTask?.cancel()
    buildController.cancel()
  }

  func openBuildDiagnostic(_ diagnostic: EditorBuildDiagnostic) {
    Task { [weak self] in
      guard let self else { return }
      await self.openDocument(at: diagnostic.url)
      guard
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
    projectContextRefreshGeneration &+= 1
    let generation = projectContextRefreshGeneration
    projectContextRefreshTask?.cancel()
    projectContextRefreshTask = Task { [weak self] in
      if delay > .zero {
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
      }
      guard let self, !Task.isCancelled, !self.isShuttingDown,
        self.projectContextRefreshGeneration == generation
      else { return }
      self.buildController.rediscover()
      self.synchronizePythonProcessEnvironment()
      guard !Task.isCancelled, self.projectContextRefreshGeneration == generation else { return }
      if let backend = self.ideWorkspace?.backend {
        _ = await backend.refreshExternalSourceIndex()
      }
      guard !Task.isCancelled, self.projectContextRefreshGeneration == generation else { return }
      await self.symbolResolver.invalidate()
      guard self.projectContextRefreshGeneration == generation else { return }
      self.projectContextRefreshTask = nil
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
    case .write, .writeAndQuit, .quit, .closeTab, .split, .scroll,
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
      Task { await openDocument(at: url.standardizedFileURL) }
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
    Task { [weak self] in
      guard let self else { return }
      do {
        guard try await tab.prepareRenameAtSelection() != nil else {
          self.fileOperationError = "The active language service cannot rename this symbol."
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
        guard !name.isEmpty, let edit = try await tab.renameAtSelection(to: name) else { return }
        try await self.applyLanguageWorkspaceEdit(edit, description: "Rename")
      } catch {
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
    Task { [weak self] in
      guard let self else { return }
      do {
        let actions = try await tab.codeActionsAtSelection().filter { !$0.isDisabled }
        guard !actions.isEmpty else {
          self.fileOperationError = "No code actions are available at the cursor."
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
          ordered.indices.contains(popup.indexOfSelectedItem)
        else { return }
        let action = ordered[popup.indexOfSelectedItem]
        if let edit = action.edit {
          try await self.applyLanguageWorkspaceEdit(edit, description: action.title)
        }
        if let command = action.command, let backend = self.ideWorkspace?.backend {
          _ = try await backend.executeLanguageCommand(command)
        }
      } catch {
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
    Task { [weak self] in
      guard let self, let tab = self.activeTab else { return }
      do {
        guard let hover = try await tab.hoverAtSelection(), !hover.markdown.isEmpty else {
          self.symbolInformation = EditorSymbolInformation(
            title: tab.symbolAtSelection ?? "Quick Help",
            markdown: "No symbol information was returned by the active language service."
          )
          return
        }
        self.symbolInformation = EditorSymbolInformation(
          title: tab.symbolAtSelection ?? "Quick Help",
          markdown: hover.markdown
        )
      } catch {
        self.symbolInformation = EditorSymbolInformation(
          title: tab.symbolAtSelection ?? "Quick Help",
          markdown: "Quick Help failed: \(error.localizedDescription)"
        )
      }
    }
  }

  func openSymbolLocation(_ location: SourceLocation) {
    symbolLocations = nil
    Task { [weak self] in
      await self?.openSourceLocation(location)
    }
  }

  func toggleBreakpointAtCurrentLine() {
    guard let tab = activeTab else { return }
    tab.toggleBreakpointAtCurrentLine()
    guard debugPhase == .running || debugPhase == .stopped else { return }
    Task { [weak self] in
      guard let self, let backend = self.ideWorkspace?.backend else { return }
      do {
        try await self.synchronizeBreakpoints(for: tab, using: backend)
      } catch {
        self.appendDebugMessage("Breakpoint update failed: \(error.localizedDescription)")
      }
    }
  }

  func startDebugging() {
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
    debugInspectionTask?.cancel()
    debugInspectionTask = Task { [weak self] in
      guard let self, let backend = self.ideWorkspace?.backend else { return }
      await self.loadDebugScopes(frameID: frame.id, backend: backend)
      guard !Task.isCancelled, self.selectedDebugFrameID == frame.id else { return }
      await self.openDebugFrame(frame)
      self.debugInspectionTask = nil
    }
  }

  func resolveExternalFileConflict(using resolution: SourceWorkspaceConflictResolution) {
    guard let conflict = externalFileConflict else { return }
    let url = conflict.url.standardizedFileURL
    guard let id = externalConflictIDs[url], let backend = ideWorkspace?.backend else {
      externalFileConflict = nil
      return
    }
    Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await backend.resolveSourceFileConflict(id, using: resolution)
        if let tab = self.tabs.first(where: { $0.url.standardizedFileURL == url }) {
          switch resolution {
          case .useDisk:
            try await tab.applyDiskReload()
          case .useMemory:
            tab.markExternalConflictResolved()
          }
        }
        self.externalConflictIDs.removeValue(forKey: url)
        if self.externalFileConflict?.url.standardizedFileURL == url {
          self.externalFileConflict = nil
          self.presentNextExternalFileConflict()
        }
        self.appendDebugMessage("Resolved external file conflict: \(url.lastPathComponent)")
      } catch {
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
    runDebugOperation {
      guard let backend = self.ideWorkspace?.backend else { return }
      try? await backend.terminateDebugger()
      try? await backend.disconnectDebugger()
      self.activeThreadID = nil
      self.clearDebugInspection()
      self.debugPhase = .idle
    }
  }

  @discardableResult
  func shutdown(saveChanges: Bool = true) async -> Bool {
    if hasShutDown { return true }
    guard !isShuttingDown else { return false }
    isShuttingDown = true
    pendingServicesConfiguration = nil
    if let task = reconfigurationTask { await task.value }
    buildLaunchTask?.cancel()
    if buildController.phase.isRunning { buildController.cancel() }
    if let buildLaunchTask { await buildLaunchTask.value }
    self.buildLaunchTask = nil
    debugOperationTask?.cancel()
    debugInspectionTask?.cancel()
    projectContextRefreshTask?.cancel()
    projectContextRefreshTask = nil
    projectContextRefreshGeneration &+= 1

    if saveChanges {
      await persistWorkspaceSession(includeRecoveries: true)
      guard await saveAllDocuments() else {
        phase = .failed("One or more documents could not be saved.")
        isShuttingDown = false
        return false
      }
    } else {
      await persistWorkspaceSession(includeRecoveries: false)
    }

    startTask?.cancel()
    startTask = nil
    startGeneration &+= 1
    messageTask?.cancel()
    sourceWorkspaceTask?.cancel()
    debugEventTask?.cancel()
    debugStandardErrorTask?.cancel()
    debugErrorTask?.cancel()
    try? await ideWorkspace?.shutdown()
    ideWorkspace = nil
    phase = .idle
    await persistWorkspaceSession(includeRecoveries: false)
    hasShutDown = true
    isShuttingDown = false
    return true
  }

  private func runDebugOperation(
    _ operation: @escaping @MainActor () async -> Void
  ) {
    guard debugOperationTask == nil, !isShuttingDown else { return }
    debugOperationTask = Task { [weak self] in
      guard let self else { return }
      await operation()
      self.debugOperationTask = nil
    }
  }

  private struct ReconfigurationTabState {
    var id: UUID
    var url: URL
    var selectedRange: NSRange
  }

  private func reconfigure(using configuration: EditorServicesConfiguration) async {
    guard !isShuttingDown else { return }
    let tabStates = tabs.map {
      ReconfigurationTabState(id: $0.id, url: $0.url, selectedRange: $0.selectedRange)
    }
    let previouslySelectedID = selectedTabID
    guard await saveAllDocuments() else {
      phase = .failed(
        "Editor Services were not reconfigured because a document could not be saved.")
      return
    }

    startTask?.cancel()
    startTask = nil
    startGeneration &+= 1
    projectContextRefreshTask?.cancel()
    projectContextRefreshTask = nil
    projectContextRefreshGeneration &+= 1
    for tab in tabs { await tab.close() }
    try? await ideWorkspace?.shutdown()
    ideWorkspace = nil
    servicesConfiguration = configuration
    EditorServicePreferencesStore.save(configuration: configuration)
    phase = .idle
    await start()
    guard !isShuttingDown, phase == .ready, let workspace = ideWorkspace else { return }

    var reopenedTabs: [EditorTab] = []
    reopenedTabs.reserveCapacity(tabStates.count)
    for state in tabStates {
      guard isRegularFile(state.url) else { continue }
      do {
        let tab = try await makeEditorTab(
          at: state.url,
          using: workspace,
          id: state.id,
          selectedRange: state.selectedRange
        )
        reopenedTabs.append(tab)
      } catch {
        appendDebugMessage(
          "Could not reopen \(state.url.lastPathComponent) after reconfiguration: "
            + error.localizedDescription
        )
      }
    }

    // Replace the collection once, preserving IDs and selection. Split panes key their state by
    // tab ID, so they do not collapse or switch documents while the backend is recreated.
    tabs = reopenedTabs
    if let previouslySelectedID, reopenedTabs.contains(where: { $0.id == previouslySelectedID }) {
      selectedTabID = previouslySelectedID
    } else {
      selectedTabID = reopenedTabs.first?.id
    }
    scheduleSessionPersistence()
  }

  private func beginDebugging() async {
    guard let workspace = ideWorkspace, let tab = activeTab else { return }
    guard let language = editorLanguage(for: tab.languageID) else {
      debugPhase = .failed("No debug language mapping exists for \(tab.languageID).")
      return
    }

    debugPhase = .starting
    guard await saveAllDocuments() else {
      debugPhase = .failed("One or more documents could not be saved before debugging.")
      return
    }

    if debugConfiguration.buildBeforeLaunch,
      buildController.plan.command(for: .build) != nil
    {
      appendDebugMessage("Building project before launch…")
      guard await buildController.run(kind: .build) else {
        debugPhase = .failed("The build failed. Open the Build or Problems panel for details.")
        appendDebugMessage("Debug launch cancelled because the build failed.")
        return
      }
      clearSupersededServiceDiagnosticsAfterSuccessfulBuild()
    }

    let resolver = EditorDebugProgramResolver(workspaceURL: workspaceURL)
    guard
      let program = resolver.resolve(
        configuredPath: debugConfiguration.programPath,
        projectKind: buildController.plan.projectKind
      )
    else {
      debugPhase = .failed(
        "No executable was found. Build the project or set an executable in Debug Settings."
      )
      return
    }
    var launchConfiguration = debugConfiguration
    launchConfiguration.programPath = program
    if launchConfiguration.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      launchConfiguration.workingDirectory = workspaceURL.path
    }

    do {
      _ = try await workspace.serviceResult.startDebugger(for: language)
      let adapterID =
        workspace.serviceResult.debugAdapter(for: language)?.defaultAdapterID
        ?? language.rawValue
      try await workspace.backend.launchDebugger(
        arguments: EditorDebugLaunchArguments.make(
          language: language,
          adapterID: adapterID,
          configuration: launchConfiguration,
          workspaceURL: workspaceURL
        ))
      try await synchronizeBreakpoints(using: workspace.backend)
      try await workspace.backend.finishDebuggerConfiguration()
      debugPhase = .running
      appendDebugMessage("Started \(adapterID) for \(program)")
    } catch {
      try? await workspace.backend.disconnectDebugger()
      activeThreadID = nil
      debugPhase = .failed(error.localizedDescription)
      appendDebugMessage("Debug start failed: \(error.localizedDescription)")
    }
  }

  private func synchronizeBreakpoints(using backend: MultiLanguageEditorBackend) async throws {
    for tab in tabs {
      try await synchronizeBreakpoints(for: tab, using: backend)
    }
  }

  private func synchronizeBreakpoints(
    for tab: EditorTab,
    using backend: MultiLanguageEditorBackend
  ) async throws {
    let values = tab.breakpoints.sorted().map { SourceBreakpoint(line: $0) }
    _ = try await backend.setBreakpoints(
      in: tab.url,
      breakpoints: values,
      sourceModified: tab.isDirty
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

  private func observeBackend(_ backend: MultiLanguageEditorBackend) {
    messageTask?.cancel()
    sourceWorkspaceTask?.cancel()
    debugEventTask?.cancel()
    debugStandardErrorTask?.cancel()
    debugErrorTask?.cancel()

    messageTask = Task { [weak self] in
      for await message in backend.languageServerMessages {
        guard let self else { return }
        let service = message.serviceIdentifier.map { "[\($0)] " } ?? ""
        self.appendDebugMessage("LSP \(service)\(message.message)")
      }
    }
    sourceWorkspaceTask = Task { [weak self] in
      let events = await backend.sourceWorkspaceEvents()
      for await event in events {
        guard let self else { return }
        self.handleSourceWorkspaceEvent(event)
      }
    }
    debugEventTask = Task { [weak self] in
      for await event in backend.debugEvents {
        guard let self else { return }
        await self.handleDebugEvent(event, backend: backend)
      }
    }
    debugStandardErrorTask = Task { [weak self] in
      for await line in backend.debugAdapterStandardError {
        guard let self else { return }
        self.appendDebugMessage("DAP stderr: \(line)")
      }
    }
    debugErrorTask = Task { [weak self] in
      for await error in backend.debugTransportErrors {
        guard let self else { return }
        self.appendDebugMessage("DAP: \(error)")
      }
    }
  }

  private func handleSourceWorkspaceEvent(_ event: SourceWorkspaceEvent) {
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
      guard let tab = tabs.first(where: { $0.url.standardizedFileURL == url }) else { return }
      let message = "\(tab.title) was removed from disk. Save it to recreate the file."
      tab.reportExternalFileIssue(message)
      fileOperationError = message
      appendDebugMessage("Workspace file removed: \(relativePath)")
    case .scanFailed(let message):
      appendDebugMessage("Workspace scan failed: \(message)")
    case .added, .moved:
      scheduleProjectContextRefresh()
    case .changed, .saved, .reloaded, .restored:
      Task { await symbolResolver.invalidate() }
    case .scanned:
      break
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
    backend: MultiLanguageEditorBackend
  ) async {
    appendDebugMessage("DAP event: \(event.event)")
    switch event.event {
    case "stopped":
      debugPhase = .stopped
      await refreshDebugInspection(using: backend)
    case "continued":
      clearDebugInspection()
      debugPhase = .running
    case "terminated":
      activeThreadID = nil
      clearDebugInspection()
      try? await backend.disconnectDebugger()
      debugPhase = .idle
    case "exited":
      activeThreadID = nil
      clearDebugInspection()
      debugPhase = .idle
    default:
      break
    }
  }

  private func refreshDebugInspection(using backend: MultiLanguageEditorBackend) async {
    do {
      let threads = try await backend.debugThreads()
      debugThreads = threads
      guard let thread = threads.first else {
        activeThreadID = nil
        debugFrames = []
        debugScopes = []
        return
      }
      activeThreadID = thread.id
      let trace = try await backend.stackTrace(threadID: thread.id, levels: 100)
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

  private func navigateToDefinition() {
    Task { [weak self] in
      guard let self, let tab = self.activeTab else { return }
      do {
        var locations = try await tab.definitionsAtSelection()
        if locations.isEmpty, let symbol = tab.symbolAtSelection {
          locations = await self.symbolResolver.definitionLocations(
            for: symbol,
            originatingURL: tab.url,
            inMemoryDocuments: self.openDocumentTexts
          )
        }
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
        self.symbolInformation = EditorSymbolInformation(
          title: tab.symbolAtSelection ?? "Definition",
          markdown: "Definition lookup failed: \(error.localizedDescription)"
        )
      }
    }
  }

  private func navigateToReferences() {
    Task { [weak self] in
      guard let self, let tab = self.activeTab else { return }
      do {
        var locations = try await tab.referencesAtSelection()
        if locations.isEmpty, let symbol = tab.symbolAtSelection {
          locations = await self.symbolResolver.referenceLocations(
            for: symbol,
            originatingURL: tab.url,
            inMemoryDocuments: self.openDocumentTexts
          )
        }
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
    guard hasRestoredSession else { return }
    sessionPersistenceTask?.cancel()
    sessionPersistenceTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(350))
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
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
      } : []
    do {
      let report = try await sessionStore.save(
        openURLs: tabs.map(\.url),
        selectedURL: selectedURL,
        recoveredDocuments: recoveries
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
    let restoration = await sessionStore.load()
    guard !restoration.openRelativePaths.isEmpty || !restoration.recoveredDocuments.isEmpty else {
      return
    }

    let recoveryByPath = Dictionary(
      uniqueKeysWithValues: restoration.recoveredDocuments.map { ($0.relativePath, $0) }
    )
    var restoredTabs: [String: EditorTab.ID] = [:]
    var recoveryWarnings: [String] = []

    for path in restoration.openRelativePaths {
      guard let url = await sessionStore.url(forRelativePath: path), isRegularFile(url) else {
        continue
      }
      await openDocument(at: url)
      guard let tab = tabs.first(where: { $0.url.standardizedFileURL == url }) else { continue }
      restoredTabs[path] = tab.id

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

    if let selected = restoration.selectedRelativePath, let id = restoredTabs[selected] {
      selectedTabID = id
    }
    if !recoveryWarnings.isEmpty {
      fileOperationError = recoveryWarnings.joined(separator: "\n")
      recoveryWarnings.forEach(appendDebugMessage)
    }
    scheduleSessionPersistence()
  }

  private func appendDebugMessage(_ message: String) {
    logStore.log(.debug, category: "Editor", message: message)
    debugConsole.append(message)
    if debugConsole.count > 500 { debugConsole.removeFirst(debugConsole.count - 500) }
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

private enum ShellArgumentParser {
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
