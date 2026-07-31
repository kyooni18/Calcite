import EditorCore
import EditorDAP
import EditorLSP
import EditorServiceKit
import EditorTreeSitter
import EditorWorkspace
import Foundation

#if os(macOS)
  import CoreServices
  import FSEventsWrapper
#endif

/// Controls how Swift keyword completions are combined with language-server results.
public enum SwiftEditorCompletionStrategy: Hashable, Sendable {
  /// Return only language-server completions.
  case languageServerOnly
  /// Merge language-server completions with local Swift keywords and propagate LSP errors.
  case mergeKeywords
  /// Merge keywords normally and return keyword completions if the language server fails.
  case mergeKeywordsAndFallbackOnError
}

/// Configuration used by ``SwiftEditorBackend/makeSwift(configuration:)``.
public struct SwiftEditorBackendConfiguration: Sendable {
  public var workspaceURL: URL
  public var sourceKitLSPExecutablePath: String?
  public var environment: [String: String]
  public var languageID: String
  public var enableTreeSitter: Bool
  public var enableLanguageServer: Bool
  public var eagerlyInitializeLanguageServer: Bool
  public var completionStrategy: SwiftEditorCompletionStrategy
  public var completionLimit: Int
  public var languageServerConfigurationProvider: LSPDocumentService.ConfigurationProvider
  public var automaticallyApplyServerWorkspaceEdits: Bool
  public var sourceWorkspaceConfiguration: SourceWorkspaceConfiguration
  public var scanSourceWorkspaceOnConstruction: Bool
  public var sourceWorkspaceMonitoringInterval: Duration?
  public var languageServerInitializationTimeout: Duration?
  public var languageServerShutdownTimeout: Duration

  public init(
    workspaceURL: URL,
    sourceKitLSPExecutablePath: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    languageID: String = "swift",
    enableTreeSitter: Bool = true,
    enableLanguageServer: Bool = true,
    eagerlyInitializeLanguageServer: Bool = true,
    completionStrategy: SwiftEditorCompletionStrategy = .mergeKeywordsAndFallbackOnError,
    completionLimit: Int = 100,
    languageServerConfigurationProvider: @escaping LSPDocumentService.ConfigurationProvider = {
      items in Array(repeating: .null, count: items.count)
    },
    automaticallyApplyServerWorkspaceEdits: Bool = true,
    sourceWorkspaceConfiguration: SourceWorkspaceConfiguration = .init(),
    scanSourceWorkspaceOnConstruction: Bool = true,
    sourceWorkspaceMonitoringInterval: Duration? = nil,
    languageServerInitializationTimeout: Duration? = .seconds(15),
    languageServerShutdownTimeout: Duration = .seconds(5)
  ) {
    self.workspaceURL = workspaceURL
    self.sourceKitLSPExecutablePath = sourceKitLSPExecutablePath
    self.environment = environment
    self.languageID = languageID
    self.enableTreeSitter = enableTreeSitter
    self.enableLanguageServer = enableLanguageServer
    self.eagerlyInitializeLanguageServer = eagerlyInitializeLanguageServer
    self.completionStrategy = completionStrategy
    self.completionLimit = max(1, completionLimit)
    self.languageServerConfigurationProvider = languageServerConfigurationProvider
    self.automaticallyApplyServerWorkspaceEdits = automaticallyApplyServerWorkspaceEdits
    self.sourceWorkspaceConfiguration = sourceWorkspaceConfiguration
    self.scanSourceWorkspaceOnConstruction = scanSourceWorkspaceOnConstruction
    self.sourceWorkspaceMonitoringInterval = sourceWorkspaceMonitoringInterval
    self.languageServerInitializationTimeout = languageServerInitializationTimeout
    self.languageServerShutdownTimeout = languageServerShutdownTimeout
  }
}

/// Process settings for a local Debug Adapter Protocol implementation such as `lldb-dap`.
public struct DebugAdapterProcessConfiguration: Sendable {
  public var executableURL: URL
  public var arguments: [String]
  public var environment: [String: String]?
  public var currentDirectoryURL: URL?
  public var initializeArguments: InitializeArguments

  public init(
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String]? = nil,
    currentDirectoryURL: URL? = nil,
    initializeArguments: InitializeArguments = .init(
      adapterID: "lldb",
      clientID: "EditorServices",
      clientName: "EditorServices"
    )
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.currentDirectoryURL = currentDirectoryURL
    self.initializeArguments = initializeArguments
  }
}

public struct WorkspaceEditApplicationResult: Hashable, Sendable {
  public var appliedDocuments: [URL]
  public var openedDocuments: [URL]
  public var pendingFileOperations: [WorkspaceFileOperation]

  public init(
    appliedDocuments: [URL],
    openedDocuments: [URL] = [],
    pendingFileOperations: [WorkspaceFileOperation] = []
  ) {
    self.appliedDocuments = appliedDocuments
    self.openedDocuments = openedDocuments
    self.pendingFileOperations = pendingFileOperations
  }
}

public enum SwiftEditorBackendError: Error, Equatable, Sendable {
  case documentAlreadyOpen(URL)
  case documentNotOpen(URL)
  case debuggerAlreadyRunning
  case debuggerNotRunning
  case invalidUTF8(URL)
  case workspaceVersionConflict(URL, Int, Int)
  case workspaceVersionMismatch(URL, expected: Int, actual: Int)
  case workspaceRollbackFailed(primary: String, documents: [URL])
  case documentChangedDuringPersistence(URL, attempts: Int)
  case documentChangedWhileAwaitingLanguageEdits(URL, expected: Int, actual: Int)
  case sourceWorkspaceHasOpenDocuments([URL])
  case shutdown
  case unsupportedPlatform(String)
}

extension SwiftEditorBackendError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .documentAlreadyOpen(let url):
      return "The document is already open: \(url.path)"
    case .documentNotOpen(let url):
      return "The document is not open: \(url.path)"
    case .debuggerAlreadyRunning:
      return "A debugger session is already running."
    case .debuggerNotRunning:
      return "No debugger session is running."
    case .invalidUTF8(let url):
      return "The file is not valid UTF-8 text: \(url.path)"
    case .workspaceVersionConflict(let url, let first, let second):
      return
        "The workspace edit contains conflicting versions \(first) and \(second) for \(url.path)."
    case .workspaceVersionMismatch(let url, let expected, let actual):
      return
        "The workspace edit expected version \(expected) for \(url.path), but the open document is version \(actual)."
    case .workspaceRollbackFailed(let primary, let documents):
      let paths = documents.map(\.path).joined(separator: ", ")
      return "The workspace edit failed (\(primary)), and rollback also failed for: \(paths)."
    case .documentChangedDuringPersistence(let url, let attempts):
      return
        "The document kept changing while it was being saved after \(attempts) attempts: \(url.path)"
    case .documentChangedWhileAwaitingLanguageEdits(let url, let expected, let actual):
      return
        "The document changed from version \(expected) to \(actual) while waiting for language-server edits: \(url.path)"
    case .sourceWorkspaceHasOpenDocuments(let urls):
      return "Close source documents before restoring an archive: "
        + urls.map(\.path).joined(separator: ", ")
    case .shutdown:
      return "The editor backend has been shut down."
    case .unsupportedPlatform(let message):
      return message
    }
  }
}

public struct EditorDebugEventEnvelope: Sendable {
  public var generation: UInt64
  public var event: DAPEvent

  public init(generation: UInt64, event: DAPEvent) {
    self.generation = generation
    self.event = event
  }
}

public struct EditorDebugTextEnvelope: Sendable {
  public var generation: UInt64
  public var text: String

  public init(generation: UInt64, text: String) {
    self.generation = generation
    self.text = text
  }
}

/// A single high-level façade for constructing a Swift editor backend.
///
/// `SwiftEditorBackend` owns document buffers, one syntax parser per document,
/// a shared language-server connection, completion fallback, diagnostics, and
/// an optional DAP debug session. Its public methods are safe to call from UI
/// tasks; mutable state is isolated in an internal actor.
public final class SwiftEditorBackend: @unchecked Sendable {
  public typealias SyntaxFactory = @Sendable () throws -> any SyntaxProviding
  public typealias ContextualSyntaxFactory =
    @Sendable (EditorSyntaxServiceContext) throws -> (any SyntaxProviding)?
  public typealias LanguageServerShutdown = @Sendable () async throws -> Void

  static func automaticWorkspaceEditHandler(
    for backend: SwiftEditorBackend
  ) -> LSPDocumentService.WorkspaceEditHandler {
    { [weak backend] edit, _ in
      guard let backend, edit.fileOperations.isEmpty else { return false }
      _ = try await backend.applyWorkspaceEdit(edit, openMissingFiles: true)
      return true
    }
  }

  public let workspaceURL: URL
  public let languageID: String
  public let sourceWorkspace: SourceWorkspace
  /// The runtime router when this backend was constructed with routed language services.
  public let languageServiceRouter: LanguageServiceRouter?
  public let diagnostics: AsyncStream<DiagnosticBatch>
  public let languageServerMessages: AsyncStream<LanguageServerMessage>
  public let debugEvents: AsyncStream<DAPEvent>
  public let debugEventEnvelopes: AsyncStream<EditorDebugEventEnvelope>
  public let debugAdapterStandardError: AsyncStream<String>
  public let debugAdapterStandardErrorEnvelopes: AsyncStream<EditorDebugTextEnvelope>
  public let debugTransportErrors: AsyncStream<String>
  public let debugTransportErrorEnvelopes: AsyncStream<EditorDebugTextEnvelope>

  private let diagnosticContinuation: AsyncStream<DiagnosticBatch>.Continuation
  private let languageServerMessageContinuation: AsyncStream<LanguageServerMessage>.Continuation
  private let diagnosticBroadcaster: DiagnosticBroadcaster
  private var diagnosticTask: Task<Void, Never>?
  private var languageServerMessageTask: Task<Void, Never>?
  private let lifetimeTaskStore = BackendLifetimeTaskStore()
  private let debugEventContinuation: AsyncStream<DAPEvent>.Continuation
  private let debugEventEnvelopeContinuation: AsyncStream<EditorDebugEventEnvelope>.Continuation
  private let debugStandardErrorContinuation: AsyncStream<String>.Continuation
  private let debugStandardErrorEnvelopeContinuation:
    AsyncStream<EditorDebugTextEnvelope>.Continuation
  private let debugTransportErrorContinuation: AsyncStream<String>.Continuation
  private let debugTransportErrorEnvelopeContinuation:
    AsyncStream<EditorDebugTextEnvelope>.Continuation
  private let runtime: Runtime
  // Retains process-backed objects whose deinitializers terminate their child processes.
  private let retainedObjects: [AnyObject]

  /// Creates a backend from injected services. This initializer is suitable
  /// for remote LSP clients, tests, and platforms that cannot spawn processes.
  public convenience init(
    workspaceURL: URL,
    languageID: String = "swift",
    languageService: (any LanguageIntelligenceProviding)? = nil,
    syntaxFactory: SyntaxFactory? = nil,
    contextualSyntaxFactory: ContextualSyntaxFactory? = nil,
    completionStrategy: SwiftEditorCompletionStrategy = .mergeKeywordsAndFallbackOnError,
    completionLimit: Int = 100,
    sourceWorkspaceConfiguration: SourceWorkspaceConfiguration = .init(),
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    languageServerShutdown: @escaping LanguageServerShutdown = {}
  ) {
    self.init(
      workspaceURL: workspaceURL,
      languageID: languageID,
      languageService: languageService,
      syntaxFactory: syntaxFactory,
      contextualSyntaxFactory: contextualSyntaxFactory,
      completionStrategy: completionStrategy,
      completionLimit: completionLimit,
      sourceWorkspaceConfiguration: sourceWorkspaceConfiguration,
      processEnvironment: processEnvironment,
      languageServerShutdown: languageServerShutdown,
      retainedObjects: []
    )
  }

  private init(
    workspaceURL: URL,
    languageID: String,
    languageService: (any LanguageIntelligenceProviding)?,
    syntaxFactory: SyntaxFactory?,
    contextualSyntaxFactory: ContextualSyntaxFactory?,
    completionStrategy: SwiftEditorCompletionStrategy,
    completionLimit: Int,
    sourceWorkspaceConfiguration: SourceWorkspaceConfiguration,
    processEnvironment: [String: String],
    languageServerShutdown: @escaping LanguageServerShutdown,
    retainedObjects: [AnyObject]
  ) {
    self.workspaceURL = workspaceURL
    self.languageID = languageID
    self.sourceWorkspace = SourceWorkspace(
      rootURL: workspaceURL,
      configuration: sourceWorkspaceConfiguration
    )
    self.languageServiceRouter = languageService as? LanguageServiceRouter
    (diagnostics, diagnosticContinuation) = AsyncStream.makeStream(of: DiagnosticBatch.self)
    (languageServerMessages, languageServerMessageContinuation) = AsyncStream.makeStream(
      of: LanguageServerMessage.self)
    self.diagnosticBroadcaster = DiagnosticBroadcaster()
    (debugEvents, debugEventContinuation) = AsyncStream.makeStream(of: DAPEvent.self)
    (debugEventEnvelopes, debugEventEnvelopeContinuation) = AsyncStream.makeStream(
      of: EditorDebugEventEnvelope.self)
    (debugAdapterStandardError, debugStandardErrorContinuation) = AsyncStream.makeStream(
      of: String.self)
    (debugAdapterStandardErrorEnvelopes, debugStandardErrorEnvelopeContinuation) =
      AsyncStream.makeStream(of: EditorDebugTextEnvelope.self)
    (debugTransportErrors, debugTransportErrorContinuation) = AsyncStream.makeStream(
      of: String.self)
    (debugTransportErrorEnvelopes, debugTransportErrorEnvelopeContinuation) =
      AsyncStream.makeStream(of: EditorDebugTextEnvelope.self)
    self.retainedObjects = retainedObjects
    let externalSourceIndex = ExternalSourceIndex(
      workspaceURL: workspaceURL,
      languageCatalog: sourceWorkspaceConfiguration.languageCatalog,
      configuration: sourceWorkspaceConfiguration.externalSourceIndex,
      environment: processEnvironment
    )
    self.runtime = Runtime(
      languageID: languageID,
      languageService: languageService,
      languageCatalog: sourceWorkspaceConfiguration.languageCatalog,
      syntaxFactory: syntaxFactory,
      contextualSyntaxFactory: contextualSyntaxFactory,
      completionStrategy: completionStrategy,
      completionLimit: max(1, completionLimit),
      sourceWorkspace: sourceWorkspace,
      externalSourceIndex: externalSourceIndex,
      languageServerShutdown: languageServerShutdown,
      diagnosticBroadcaster: diagnosticBroadcaster,
      debugEventContinuation: debugEventContinuation,
      debugEventEnvelopeContinuation: debugEventEnvelopeContinuation,
      debugStandardErrorContinuation: debugStandardErrorContinuation,
      debugStandardErrorEnvelopeContinuation: debugStandardErrorEnvelopeContinuation,
      debugTransportErrorContinuation: debugTransportErrorContinuation,
      debugTransportErrorEnvelopeContinuation: debugTransportErrorEnvelopeContinuation
    )
    if let source = languageService?.diagnostics {
      let continuation = diagnosticContinuation
      let broadcaster = diagnosticBroadcaster
      diagnosticTask = Task {
        for await batch in source {
          continuation.yield(batch)
          await broadcaster.publish(batch)
        }
        continuation.finish()
        await broadcaster.finish()
      }
    } else {
      diagnosticContinuation.finish()
    }
    if let source = languageService?.messages {
      let continuation = languageServerMessageContinuation
      languageServerMessageTask = Task {
        for await message in source { continuation.yield(message) }
        continuation.finish()
      }
    } else {
      languageServerMessageContinuation.finish()
    }
  }

  deinit {
    diagnosticTask?.cancel()
    languageServerMessageTask?.cancel()
    lifetimeTaskStore.cancelAll()
    diagnosticContinuation.finish()
    languageServerMessageContinuation.finish()
    let broadcaster = diagnosticBroadcaster
    Task { await broadcaster.finish() }
    debugEventContinuation.finish()
    debugEventEnvelopeContinuation.finish()
    debugStandardErrorContinuation.finish()
    debugStandardErrorEnvelopeContinuation.finish()
    debugTransportErrorContinuation.finish()
    debugTransportErrorEnvelopeContinuation.finish()
  }

  #if os(macOS) || os(Linux)
    /// Constructs the standard local Swift stack with default settings.
    ///
    /// This is the shortest supported integration path for a local macOS or
    /// Linux editor. Use the configuration overload when individual services,
    /// executable paths, or completion behavior must be customized.
    public static func makeSwift(workspaceURL: URL) async throws -> SwiftEditorBackend {
      try await makeSwift(configuration: .init(workspaceURL: workspaceURL))
    }

    /// Constructs the standard local Swift stack: Tree-sitter plus SourceKit-LSP.
    public static func makeSwift(
      configuration: SwiftEditorBackendConfiguration
    ) async throws -> SwiftEditorBackend {
      let syntaxFactory: SyntaxFactory?
      if configuration.enableTreeSitter {
        syntaxFactory = { () throws -> any SyntaxProviding in
          try TreeSitterSyntaxService.swift()
        }
      } else {
        syntaxFactory = nil
      }

      guard configuration.enableLanguageServer else {
        let router = try await LanguageServiceRouter()
        let backend = SwiftEditorBackend(
          workspaceURL: configuration.workspaceURL,
          languageID: configuration.languageID,
          languageService: router,
          syntaxFactory: syntaxFactory,
          contextualSyntaxFactory: nil,
          completionStrategy: configuration.completionStrategy,
          completionLimit: configuration.completionLimit,
          sourceWorkspaceConfiguration: configuration.sourceWorkspaceConfiguration,
          processEnvironment: configuration.environment,
          languageServerShutdown: { try await router.shutdown() }
        )
        do {
          if configuration.scanSourceWorkspaceOnConstruction {
            _ = try await backend.scanSourceWorkspace()
          }
          if let interval = configuration.sourceWorkspaceMonitoringInterval {
            await backend.startSourceWorkspaceMonitoring(every: interval)
          }
          return backend
        } catch {
          try? await backend.shutdown()
          throw error
        }
      }

      let connection = try SourceKitLSPConnection(
        workspaceURL: configuration.workspaceURL,
        executablePath: configuration.sourceKitLSPExecutablePath,
        environment: configuration.environment,
        configurationProvider: configuration.languageServerConfigurationProvider
      )
      let router = try await LanguageServiceRouter(registrations: [
        .init(
          id: "sourcekit-lsp",
          service: connection.service,
          role: .primary,
          priority: 100,
          selector: .init(languageIDs: [configuration.languageID]),
          shutdown: {
            try await connection.shutdown(
              timeout: configuration.languageServerShutdownTimeout
            )
          }
        )
      ])
      let backend = SwiftEditorBackend(
        workspaceURL: configuration.workspaceURL,
        languageID: configuration.languageID,
        languageService: router,
        syntaxFactory: syntaxFactory,
        contextualSyntaxFactory: nil,
        completionStrategy: configuration.completionStrategy,
        completionLimit: configuration.completionLimit,
        sourceWorkspaceConfiguration: configuration.sourceWorkspaceConfiguration,
        processEnvironment: configuration.environment,
        languageServerShutdown: { try await router.shutdown() },
        retainedObjects: [connection]
      )
      forwardStandardError(
        connection.standardError,
        serviceIdentifier: "sourcekit-lsp",
        to: backend
      )
      forwardTermination(
        connection.terminationEvents,
        serviceIdentifier: "sourcekit-lsp",
        to: backend
      )
      do {
        if configuration.automaticallyApplyServerWorkspaceEdits {
          await connection.service.setWorkspaceEditHandler(
            automaticWorkspaceEditHandler(for: backend)
          )
        }
        if configuration.eagerlyInitializeLanguageServer {
          _ = try await connection.service.initialize(
            timeout: configuration.languageServerInitializationTimeout
          )
        }
        if configuration.scanSourceWorkspaceOnConstruction {
          _ = try await backend.scanSourceWorkspace()
        }
        if let interval = configuration.sourceWorkspaceMonitoringInterval {
          await backend.startSourceWorkspaceMonitoring(every: interval)
        }
        return backend
      } catch {
        try? await backend.shutdown()
        throw error
      }
    }

    private static func forwardStandardError(
      _ stream: AsyncStream<String>,
      serviceIdentifier: String,
      to backend: SwiftEditorBackend
    ) {
      let task = Task { [weak backend] in
        for await line in stream {
          guard let backend, !Task.isCancelled else { return }
          backend.reportLanguageServerMessage(
            LanguageServerMessage(
              kind: .log,
              message: line,
              serviceIdentifier: serviceIdentifier
            )
          )
        }
      }
      backend.retainLifetimeTask(task)
    }

    private static func forwardTermination(
      _ stream: AsyncStream<LSPProcessTermination>,
      serviceIdentifier: String,
      to backend: SwiftEditorBackend
    ) {
      let task = Task { [weak backend] in
        for await event in stream {
          guard let backend, !Task.isCancelled, !event.expected else { return }
          backend.reportLanguageServerMessage(
            LanguageServerMessage(
              kind: .error,
              message:
                "Language server process terminated unexpectedly "
                + "(reason: \(event.reason.rawValue), status: \(event.status)).",
              serviceIdentifier: serviceIdentifier
            )
          )
        }
      }
      backend.retainLifetimeTask(task)
    }

  #endif

  // MARK: - Source workspace

  /// Subscribes to source-tree changes. Each caller receives an independent stream.
  func reportLanguageServerMessage(_ message: LanguageServerMessage) {
    languageServerMessageContinuation.yield(message)
  }

  func retainLifetimeTask(_ task: Task<Void, Never>) {
    lifetimeTaskStore.insert(task)
  }

  public func sourceWorkspaceEvents() async -> AsyncStream<SourceWorkspaceEvent> {
    await sourceWorkspace.events()
  }

  /// Recursively discovers source files and merges external disk changes.
  @discardableResult
  public func scanSourceWorkspace() async throws -> SourceWorkspaceScanReport {
    try await runtime.scanSourceWorkspace()
  }

  /// Rebuilds the read-only dependency/library completion index without changing project files.
  @discardableResult
  public func refreshExternalSourceIndex() async -> ExternalSourceIndexReport {
    await runtime.refreshExternalSourceIndex()
  }

  /// Returns the latest dependency/library indexing statistics.
  public func externalSourceIndexReport() async -> ExternalSourceIndexReport {
    await runtime.externalSourceIndexReport()
  }

  public func sourceWorkspaceSnapshot() async -> SourceWorkspaceSnapshot {
    await sourceWorkspace.snapshot()
  }

  public func encodedSourceWorkspaceSnapshot(prettyPrinted: Bool = true) async throws -> Data {
    try await sourceWorkspace.encodedSnapshot(prettyPrinted: prettyPrinted)
  }

  /// Returns a root-independent archive containing every path and complete source content.
  public func sourceWorkspaceArchive() async -> SourceWorkspaceArchive {
    await sourceWorkspace.archive()
  }

  public func encodedSourceWorkspaceArchive(prettyPrinted: Bool = true) async throws -> Data {
    try await sourceWorkspace.encodedArchive(prettyPrinted: prettyPrinted)
  }

  public func sourceWorkspaceMetrics() async -> SourceWorkspaceMetrics {
    await sourceWorkspace.metrics()
  }

  /// Restores a portable archive. Open source documents must be closed explicitly,
  /// or `closeOpenDocuments` can close them before the transaction begins.
  @discardableResult
  public func restoreSourceWorkspace(
    from archive: SourceWorkspaceArchive,
    policy: SourceWorkspaceRestorePolicy = .replace,
    mode: SourceWorkspaceRestoreMode = .reconcileWithDisk,
    closeOpenDocuments: Bool = false
  ) async throws -> SourceWorkspaceRestoreReport {
    try await runtime.restoreSourceWorkspace(
      from: archive,
      policy: policy,
      mode: mode,
      closeOpenDocuments: closeOpenDocuments
    )
  }

  @discardableResult
  public func restoreSourceWorkspace(
    from data: Data,
    policy: SourceWorkspaceRestorePolicy = .replace,
    mode: SourceWorkspaceRestoreMode = .reconcileWithDisk,
    closeOpenDocuments: Bool = false
  ) async throws -> SourceWorkspaceRestoreReport {
    try await runtime.restoreSourceWorkspace(
      from: data,
      policy: policy,
      mode: mode,
      closeOpenDocuments: closeOpenDocuments
    )
  }

  public func startSourceWorkspaceMonitoring(every interval: Duration = .seconds(1)) async {
    await runtime.startSourceWorkspaceMonitoring(every: interval)
  }

  public func stopSourceWorkspaceMonitoring() async {
    await runtime.stopSourceWorkspaceMonitoring()
  }

  public func isSourceWorkspaceMonitoring() async -> Bool {
    await runtime.isSourceWorkspaceMonitoring()
  }

  public func sourceFiles() async -> [SourceCodeFile] {
    await sourceWorkspace.files()
  }

  public func dirtySourceFiles() async throws -> [SourceCodeFile] {
    try await runtime.dirtySourceFiles()
  }

  public func searchSource(
    _ pattern: SourceSearchPattern,
    options: SourceSearchOptions = .init()
  ) async throws -> [SourceSearchMatch] {
    try await runtime.searchSource(pattern, options: options)
  }

  public func previewSourceReplacement(
    _ pattern: SourceSearchPattern,
    with replacementTemplate: String,
    options: SourceSearchOptions = .init()
  ) async throws -> SourceReplacementPreview {
    try await runtime.previewSourceReplacement(
      pattern,
      replacementTemplate: replacementTemplate,
      options: options
    )
  }

  @discardableResult
  public func applySourceReplacement(
    _ preview: SourceReplacementPreview
  ) async throws -> [SourceCodeFile] {
    try await runtime.applySourceReplacement(preview)
  }

  @discardableResult
  public func replaceAllSource(
    _ pattern: SourceSearchPattern,
    with replacementTemplate: String,
    options: SourceSearchOptions = .init()
  ) async throws -> [SourceCodeFile] {
    let preview = try await previewSourceReplacement(
      pattern,
      with: replacementTemplate,
      options: options
    )
    return try await applySourceReplacement(preview)
  }

  @discardableResult
  public func saveAllSourceFiles(
    overwriteExternalChanges: Bool = false
  ) async throws -> [SourceCodeFile] {
    try await runtime.saveAllSourceFiles(overwriteExternalChanges: overwriteExternalChanges)
  }

  public func sourceFile(id: SourceFileID) async throws -> SourceCodeFile {
    try await runtime.sourceFile(id: id)
  }

  public func sourceFile(at relativePath: String) async throws -> SourceCodeFile {
    try await runtime.sourceFile(relativePath: relativePath)
  }

  public func sourceFileSession(id: SourceFileID) async throws -> SwiftSourceFileSession {
    _ = try await sourceFile(id: id)
    return SwiftSourceFileSession(backend: self, id: id)
  }

  public func sourceFileSession(at relativePath: String) async throws -> SwiftSourceFileSession {
    let file = try await sourceFile(at: relativePath)
    return SwiftSourceFileSession(backend: self, id: file.id)
  }

  /// Creates a stored source file and optionally opens it in the editor backend.
  @discardableResult
  public func createSourceFile(
    at relativePath: String,
    content: String = "",
    languageID: String? = nil,
    persistImmediately: Bool = true,
    openInEditor: Bool = false
  ) async throws -> SourceCodeFile {
    try await runtime.createSourceFile(
      at: relativePath,
      content: content,
      languageID: languageID,
      persistImmediately: persistImmediately,
      openInEditor: openInEditor
    )
  }

  public func openSourceFile(_ id: SourceFileID) async throws -> SwiftEditorDocumentSession {
    let url = try await runtime.openSourceFile(id: id)
    let documentLanguageID = try await runtime.documentLanguageID(uri: url)
    return SwiftEditorDocumentSession(
      backend: self, uri: url, languageID: documentLanguageID)
  }

  @discardableResult
  public func setSourceFileContent(
    _ content: String,
    for id: SourceFileID,
    expectedVersion: Int? = nil
  ) async throws -> SourceCodeFile {
    try await runtime.setSourceFileContent(content, for: id, expectedVersion: expectedVersion)
  }

  @discardableResult
  public func applySourceFileEdits(
    _ edits: [TextEdit],
    to id: SourceFileID,
    expectedVersion: Int? = nil
  ) async throws -> SourceCodeFile {
    try await runtime.applySourceFileEdits(
      edits, to: id, expectedVersion: expectedVersion)
  }

  /// Atomically replaces complete contents across open and closed source files.
  @discardableResult
  public func setSourceFileContentsAtomically(
    _ updates: [SourceFileContentUpdate]
  ) async throws -> [SourceCodeFile] {
    try await runtime.setSourceFileContentsAtomically(updates)
  }

  /// Atomically applies UTF-16 edits across open and closed source files.
  @discardableResult
  public func applySourceFileEditsAtomically(
    _ batches: [SourceFileEditBatch]
  ) async throws -> [SourceCodeFile] {
    try await runtime.applySourceFileEditsAtomically(batches)
  }

  /// Changes whether the file is saved as UTF-8 with or without a BOM.
  @discardableResult
  public func setSourceFileEncoding(
    _ encoding: SourceTextEncoding,
    for id: SourceFileID
  ) async throws -> SourceCodeFile {
    try await runtime.setSourceFileEncoding(encoding, for: id)
  }

  /// Converts the file's complete content to one newline style.
  @discardableResult
  public func convertSourceFileLineEndings(
    _ ending: SourceLineEnding,
    for id: SourceFileID
  ) async throws -> SourceCodeFile {
    try await runtime.convertSourceFileLineEndings(ending, for: id)
  }

  @discardableResult
  public func saveSourceFile(
    _ id: SourceFileID,
    overwriteExternalChanges: Bool = false
  ) async throws -> SourceCodeFile {
    try await runtime.saveSourceFile(id, overwriteExternalChanges: overwriteExternalChanges)
  }

  @discardableResult
  public func reloadSourceFile(_ id: SourceFileID) async throws -> SourceCodeFile {
    try await runtime.reloadSourceFile(id)
  }

  @discardableResult
  public func resolveSourceFileConflict(
    _ id: SourceFileID,
    using resolution: SourceWorkspaceConflictResolution
  ) async throws -> SourceCodeFile {
    try await runtime.resolveSourceFileConflict(id, using: resolution)
  }

  @discardableResult
  public func moveSourceFile(
    _ id: SourceFileID,
    to newRelativePath: String
  ) async throws -> SourceCodeFile {
    try await runtime.moveSourceFile(id, to: newRelativePath)
  }

  public func removeSourceFile(_ id: SourceFileID, deleteFromDisk: Bool = true) async throws {
    try await runtime.removeSourceFile(id, deleteFromDisk: deleteFromDisk)
  }

  public func createSourceDirectory(at relativePath: String) async throws {
    try await runtime.createSourceDirectory(at: relativePath)
  }

  public func moveSourceDirectory(from oldRelativePath: String, to newRelativePath: String)
    async throws
  {
    try await runtime.moveSourceDirectory(from: oldRelativePath, to: newRelativePath)
  }

  public func removeSourceDirectory(at relativePath: String, recursively: Bool = false) async throws
  {
    try await runtime.removeSourceDirectory(at: relativePath, recursively: recursively)
  }

  public func openDocument(at uri: URL, text: String = "") async throws {
    try await runtime.openDocument(uri: uri, text: text, languageID: nil)
  }

  /// Opens an in-memory document using a language identifier specific to that document.
  public func openDocument(at uri: URL, text: String = "", languageID: String) async throws {
    try await runtime.openDocument(uri: uri, text: text, languageID: languageID)
  }

  public func openDocumentSession(at uri: URL, text: String = "") async throws
    -> SwiftEditorDocumentSession
  {
    try await openDocument(at: uri, text: text)
    let documentLanguageID = try await runtime.documentLanguageID(uri: uri)
    return SwiftEditorDocumentSession(
      backend: self, uri: uri, languageID: documentLanguageID)
  }

  public func openDocumentSession(at uri: URL, text: String = "", languageID: String) async throws
    -> SwiftEditorDocumentSession
  {
    try await openDocument(at: uri, text: text, languageID: languageID)
    return SwiftEditorDocumentSession(backend: self, uri: uri, languageID: languageID)
  }

  public func documentSession(at uri: URL) async throws -> SwiftEditorDocumentSession {
    guard await isDocumentOpen(at: uri) else { throw SwiftEditorBackendError.documentNotOpen(uri) }
    let documentLanguageID = try await runtime.documentLanguageID(uri: uri)
    return SwiftEditorDocumentSession(
      backend: self, uri: uri, languageID: documentLanguageID)
  }

  /// Returns the language identifier used by the open document and its routed services.
  public func documentLanguageID(at uri: URL) async throws -> String {
    try await runtime.documentLanguageID(uri: uri)
  }

  /// Loads a UTF-8 source file and opens it as an editor document.
  /// Workspace files retain their encoding, path, and disk-conflict metadata.
  public func openFile(at uri: URL) async throws {
    try await runtime.openFile(uri: uri, languageID: nil)
  }

  public func openFile(at uri: URL, languageID: String) async throws {
    try await runtime.openFile(uri: uri, languageID: languageID)
  }

  public func openFileSession(at uri: URL) async throws -> SwiftEditorDocumentSession {
    try await openFile(at: uri)
    let documentLanguageID = try await runtime.documentLanguageID(uri: uri)
    return SwiftEditorDocumentSession(
      backend: self, uri: uri, languageID: documentLanguageID)
  }

  public func openFileSession(at uri: URL, languageID: String) async throws
    -> SwiftEditorDocumentSession
  {
    try await openFile(at: uri, languageID: languageID)
    return SwiftEditorDocumentSession(backend: self, uri: uri, languageID: languageID)
  }

  /// Atomically writes the current UTF-8 snapshot to disk and emits `didSave`.
  public func persistDocument(
    at uri: URL,
    overwriteExternalChanges: Bool = false
  ) async throws {
    try await runtime.persistDocument(
      at: uri,
      overwriteExternalChanges: overwriteExternalChanges
    )
  }

  public func diagnostics(for uri: URL, replayLatest: Bool = true) async -> AsyncStream<
    DiagnosticBatch
  > {
    await diagnosticBroadcaster.stream(for: uri, replayLatest: replayLatest)
  }

  public func closeDocument(at uri: URL) async throws {
    try await runtime.closeDocument(uri: uri)
  }

  public func closeAllDocuments() async throws {
    try await runtime.closeAllDocuments()
  }

  public func openDocumentURLs() async -> [URL] {
    await runtime.openDocumentURLs()
  }

  /// Returns whether the document is currently owned by this backend.
  public func isDocumentOpen(at uri: URL) async -> Bool {
    await runtime.isDocumentOpen(uri: uri)
  }

  public func snapshot(of uri: URL) async throws -> TextSnapshot {
    try await runtime.snapshot(of: uri)
  }

  /// Returns the synchronized text without exposing the snapshot metadata.
  public func text(of uri: URL) async throws -> String {
    try await snapshot(of: uri).text
  }

  public func state(of uri: URL) async throws -> EditorDocument.State {
    try await runtime.state(of: uri)
  }

  @discardableResult
  public func apply(_ edit: TextEdit, to uri: URL) async throws -> AppliedTextEdit {
    try await runtime.apply(edit, to: uri)
  }

  @discardableResult
  public func apply(_ edits: [TextEdit], to uri: URL) async throws -> [AppliedTextEdit] {
    try await runtime.apply(edits, to: uri)
  }

  /// Applies a native text-view edit expressed as a UTF-16 `NSRange`.
  ///
  /// `NSTextView` and `UITextView` delegate ranges use the same UTF-16 unit
  /// convention as this method. The range is checked against the current
  /// synchronized snapshot before any service is mutated.
  @discardableResult
  public func applyUTF16Edit(
    _ range: NSRange,
    replacement: String,
    to uri: URL
  ) async throws -> AppliedTextEdit {
    let snapshot = try await snapshot(of: uri)
    guard range.location >= 0, range.length >= 0 else {
      throw TextBufferError.invalidUTF16Offset(range.location)
    }
    let (upperOffset, overflow) = range.location.addingReportingOverflow(range.length)
    guard !overflow else {
      throw TextBufferError.invalidUTF16Offset(range.location)
    }
    let start = try snapshot.position(atUTF16Offset: range.location)
    let end = try snapshot.position(atUTF16Offset: upperOffset)
    return try await apply(
      TextEdit(range: EditorTextRange(start: start, end: end), replacement: replacement),
      to: uri
    )
  }

  @discardableResult
  public func replaceText(in uri: URL, with text: String) async throws -> AppliedTextEdit {
    try await runtime.replaceText(in: uri, with: text)
  }

  public func resynchronizeDocument(at uri: URL) async throws {
    try await runtime.resynchronize(uri: uri)
  }

  public func highlights(in uri: URL, range: EditorTextRange? = nil) async throws -> [Highlight] {
    try await runtime.highlights(in: uri, range: range)
  }

  public func foldingRanges(in uri: URL) async throws -> [FoldingRange] {
    try await runtime.foldingRanges(in: uri)
  }

  public func completions(
    in uri: URL,
    at position: TextPosition,
    triggerCharacter: String? = nil
  ) async throws -> [Completion] {
    let invocation = triggerCharacter.map(EditorCompletionInvocation.triggerCharacter) ?? .explicit
    return try await runtime.completions(in: uri, at: position, invocation: invocation)
  }

  public func completions(
    in uri: URL,
    at position: TextPosition,
    invocation: EditorCompletionInvocation
  ) async throws -> [Completion] {
    try await runtime.completions(in: uri, at: position, invocation: invocation)
  }

  public func resolveCompletion(_ completion: Completion, in uri: URL) async throws -> Completion {
    try await runtime.resolveCompletion(completion, in: uri)
  }

  public func recordCompletionUsage(_ completion: Completion, in uri: URL) async {
    await runtime.recordCompletionUsage(completion, in: uri)
  }

  @discardableResult
  public func applyCompletion(
    _ completion: Completion,
    in uri: URL,
    at position: TextPosition,
    replacing replacementRange: EditorTextRange? = nil,
    snippetVariables: [String: String] = [:]
  ) async throws -> CompletionApplicationResult {
    try await runtime.applyCompletion(
      completion, in: uri, at: position, replacing: replacementRange,
      snippetVariables: snippetVariables
    )
  }

  public func hover(in uri: URL, at position: TextPosition) async throws -> HoverResult? {
    try await runtime.hover(in: uri, at: position)
  }

  public func definitions(in uri: URL, at position: TextPosition) async throws -> [SourceLocation] {
    try await runtime.definitions(in: uri, at: position)
  }

  public func references(
    in uri: URL,
    at position: TextPosition,
    includeDeclaration: Bool = true
  ) async throws -> [SourceLocation] {
    try await runtime.references(in: uri, at: position, includeDeclaration: includeDeclaration)
  }

  public func formattingEdits(
    in uri: URL,
    options: EditorFormattingOptions = .init()
  ) async throws -> [TextEdit] {
    try await runtime.formattingEdits(in: uri, options: options)
  }

  public func rangeFormattingEdits(
    in uri: URL,
    range: EditorTextRange,
    options: EditorFormattingOptions = .init()
  ) async throws -> [TextEdit] {
    try await runtime.rangeFormattingEdits(in: uri, range: range, options: options)
  }

  @discardableResult
  public func formatDocument(in uri: URL, options: EditorFormattingOptions = .init()) async throws
    -> [AppliedTextEdit]
  {
    try await runtime.formatDocument(in: uri, options: options)
  }

  @discardableResult
  public func formatRange(
    in uri: URL, range: EditorTextRange, options: EditorFormattingOptions = .init()
  )
    async throws -> [AppliedTextEdit]
  {
    try await runtime.formatRange(in: uri, range: range, options: options)
  }

  public func prepareRename(in uri: URL, at position: TextPosition) async throws
    -> RenamePreparation?
  {
    try await runtime.prepareRename(in: uri, at: position)
  }

  public func rename(
    in uri: URL,
    at position: TextPosition,
    to newName: String
  ) async throws -> EditorWorkspaceEdit? {
    try await runtime.rename(in: uri, at: position, to: newName)
  }

  public func semanticHighlights(in uri: URL) async throws -> [SemanticHighlight] {
    try await runtime.semanticHighlights(in: uri)
  }

  public func signatureHelp(in uri: URL, at position: TextPosition) async throws
    -> EditorSignatureHelp?
  {
    try await runtime.signatureHelp(in: uri, at: position)
  }

  public func documentSymbols(in uri: URL) async throws -> [EditorDocumentSymbol] {
    try await runtime.documentSymbols(in: uri)
  }

  public func workspaceSymbols(matching query: String) async throws -> [EditorWorkspaceSymbol] {
    try await runtime.workspaceSymbols(matching: query)
  }

  public func notifyWorkspaceFileChanges(_ changes: [EditorWorkspaceFileChange]) async throws {
    try await runtime.notifyWorkspaceFileChanges(changes)
  }

  public func pullDiagnostics(
    for uri: URL,
    previousResultID: String? = nil
  ) async throws -> DiagnosticBatch {
    try await runtime.pullDiagnostics(for: uri, previousResultID: previousResultID)
  }

  public func codeActions(
    in uri: URL,
    range: EditorTextRange,
    diagnostics: [Diagnostic] = [],
    only: [String]? = nil
  ) async throws -> [EditorCodeAction] {
    try await runtime.codeActions(in: uri, range: range, diagnostics: diagnostics, only: only)
  }

  public func inlayHints(in uri: URL, range: EditorTextRange) async throws -> [EditorInlayHint] {
    try await runtime.inlayHints(in: uri, range: range)
  }

  public func executeLanguageCommand(_ command: EditorCommand) async throws -> EditorJSONValue? {
    try await runtime.executeLanguageCommand(command)
  }

  /// Applies all text-document edits from a rename or code action.
  ///
  /// File create/rename/delete operations are returned in the result rather
  /// than executed automatically. Set `openMissingFiles` to load UTF-8 files
  /// that are not already open. All edits are validated before mutation, and
  /// already-applied documents are restored if a later document fails.
  @discardableResult
  public func applyWorkspaceEdit(
    _ edit: EditorWorkspaceEdit,
    openMissingFiles: Bool = false
  ) async throws -> WorkspaceEditApplicationResult {
    try await runtime.applyWorkspaceEdit(edit, openMissingFiles: openMissingFiles)
  }

  public func saveDocument(at uri: URL) async throws {
    try await runtime.saveDocument(at: uri)
  }

  /// Installs an already-created DAP session. Useful for remote adapters and tests.
  @discardableResult
  public func startDebugger(
    session: DAPSession,
    initializeArguments: InitializeArguments = .init(
      adapterID: "lldb",
      clientID: "EditorServices",
      clientName: "EditorServices"
    )
  ) async throws -> Capabilities {
    try await startDebugger(
      session: session,
      initializeArguments: initializeArguments,
      reverseRequestHandler: nil
    )
  }

  /// Installs an already-created DAP session with a host for adapter reverse requests.
  @discardableResult
  public func startDebugger(
    session: DAPSession,
    initializeArguments: InitializeArguments = .init(
      adapterID: "lldb",
      clientID: "EditorServices",
      clientName: "EditorServices"
    ),
    reverseRequestHandler: (any DAPReverseRequestHandler)?
  ) async throws -> Capabilities {
    try await runtime.startDebugger(
      session: session,
      connection: nil,
      initializeArguments: initializeArguments,
      reverseRequestHandler: reverseRequestHandler
    )
  }

  #if os(macOS) || os(Linux)
    /// Starts a local DAP process and initializes the debug session.
    @discardableResult
    public func startDebugger(
      process configuration: DebugAdapterProcessConfiguration
    ) async throws -> Capabilities {
      try await startDebugger(process: configuration, reverseRequestHandler: nil)
    }

    /// Starts a local DAP process with a host for adapter reverse requests.
    @discardableResult
    public func startDebugger(
      process configuration: DebugAdapterProcessConfiguration,
      reverseRequestHandler: (any DAPReverseRequestHandler)?
    ) async throws -> Capabilities {
      let connection = try DAPProcessConnection(
        executableURL: configuration.executableURL,
        arguments: configuration.arguments,
        environment: configuration.environment,
        currentDirectoryURL: configuration.currentDirectoryURL ?? workspaceURL
      )
      do {
        return try await runtime.startDebugger(
          session: connection.session,
          connection: connection,
          initializeArguments: configuration.initializeArguments,
          reverseRequestHandler: reverseRequestHandler
        )
      } catch {
        connection.terminate()
        throw error
      }
    }
    public func adoptPreparedDebugger(
      _ prepared: EditorPreparedDebugSession
    ) async throws {
      try await runtime.adoptPreparedDebugger(prepared)
    }

    /// Atomically installs an initialized replacement session, then disconnects
    /// the previous adapter. The replacement is consumed before the active
    /// session is detached, so a consumed/invalid prepared session cannot tear
    /// down a working debugger.
    public func replaceWithPreparedDebugger(
      _ prepared: EditorPreparedDebugSession,
      disconnectArguments: DisconnectArguments = .init(
        restart: true,
        terminateDebuggee: true
      )
    ) async throws {
      try await runtime.replaceWithPreparedDebugger(
        prepared,
        disconnectArguments: disconnectArguments
      )
    }

    /// Resolves and starts the locally installed `lldb-dap` adapter.
    @discardableResult
    public func startLLDBDebugger(
      executablePath: String? = nil,
      arguments: [String] = [],
      environment: [String: String] = ProcessInfo.processInfo.environment,
      initializeArguments: InitializeArguments = .init(
        adapterID: "lldb",
        clientID: "EditorServices",
        clientName: "EditorServices"
      )
    ) async throws -> Capabilities {
      try await startLLDBDebugger(
        executablePath: executablePath,
        arguments: arguments,
        environment: environment,
        initializeArguments: initializeArguments,
        reverseRequestHandler: nil
      )
    }

    /// Resolves and starts `lldb-dap` with a host for adapter reverse requests.
    @discardableResult
    public func startLLDBDebugger(
      executablePath: String? = nil,
      arguments: [String] = [],
      environment: [String: String] = ProcessInfo.processInfo.environment,
      initializeArguments: InitializeArguments = .init(
        adapterID: "lldb",
        clientID: "EditorServices",
        clientName: "EditorServices"
      ),
      reverseRequestHandler: (any DAPReverseRequestHandler)?
    ) async throws -> Capabilities {
      let path = try LLDBDAPResolver.resolve(
        explicitPath: executablePath,
        environment: environment
      )
      return try await startDebugger(
        process: .init(
          executableURL: URL(fileURLWithPath: path),
          arguments: arguments,
          environment: environment,
          currentDirectoryURL: workspaceURL,
          initializeArguments: initializeArguments
        ),
        reverseRequestHandler: reverseRequestHandler
      )
    }
  #endif

  public func currentDebugSessionGeneration() async -> UInt64 {
    await runtime.currentDebugSessionGeneration()
  }

  public func debugState() async throws -> DebugSessionState {
    try await runtime.debugState()
  }

  public func debugCapabilities() async throws -> Capabilities? {
    try await runtime.debugCapabilities()
  }

  public func launchDebugger(arguments: DAPValue) async throws {
    try await runtime.launchDebugger(arguments: arguments)
  }

  public func attachDebugger(arguments: DAPValue) async throws {
    try await runtime.attachDebugger(arguments: arguments)
  }

  public func finishDebuggerConfiguration() async throws {
    try await runtime.finishDebuggerConfiguration()
  }

  public func setBreakpoints(
    in sourceURL: URL,
    breakpoints: [SourceBreakpoint],
    sourceModified: Bool? = nil
  ) async throws -> [Breakpoint] {
    try await runtime.setBreakpoints(
      in: sourceURL,
      breakpoints: breakpoints,
      sourceModified: sourceModified
    )
  }

  public func debugThreads() async throws -> [DAPThread] {
    try await runtime.debugThreads()
  }

  public func setFunctionBreakpoints(_ breakpoints: [FunctionBreakpoint]) async throws
    -> [Breakpoint]
  {
    try await runtime.setFunctionBreakpoints(breakpoints)
  }

  public func setExceptionBreakpoints(_ filters: [String]) async throws {
    try await runtime.setExceptionBreakpoints(filters)
  }

  public func stackTrace(
    threadID: Int,
    startFrame: Int? = nil,
    levels: Int? = nil
  ) async throws -> StackTraceResponseBody {
    try await runtime.stackTrace(threadID: threadID, startFrame: startFrame, levels: levels)
  }

  public func scopes(frameID: Int) async throws -> [Scope] {
    try await runtime.scopes(frameID: frameID)
  }

  public func variables(
    reference: Int,
    filter: String? = nil,
    start: Int? = nil,
    count: Int? = nil
  ) async throws -> [Variable] {
    try await runtime.variables(reference: reference, filter: filter, start: start, count: count)
  }

  public func evaluate(
    _ expression: String,
    frameID: Int? = nil,
    context: String? = nil
  ) async throws -> EvaluateResponseBody {
    try await runtime.evaluate(expression, frameID: frameID, context: context)
  }

  public func setVariable(
    reference: Int,
    name: String,
    value: String
  ) async throws -> SetVariableResponseBody {
    try await runtime.setVariable(reference: reference, name: name, value: value)
  }

  public func exceptionInfo(threadID: Int) async throws -> ExceptionInfoResponseBody {
    try await runtime.exceptionInfo(threadID: threadID)
  }

  public func debugSource(reference: Int, source: Source? = nil) async throws -> SourceResponseBody
  {
    try await runtime.debugSource(reference: reference, source: source)
  }

  public func debugModules(start: Int? = nil, count: Int? = nil) async throws -> ModulesResponseBody
  {
    try await runtime.debugModules(start: start, count: count)
  }

  public func loadedDebugSources() async throws -> [Source] {
    try await runtime.loadedDebugSources()
  }

  public func continueExecution(threadID: Int, singleThread: Bool? = nil) async throws
    -> ContinueResponseBody
  {
    try await runtime.continueExecution(threadID: threadID, singleThread: singleThread)
  }

  public func pause(threadID: Int) async throws {
    try await runtime.pause(threadID: threadID)
  }

  public func stepOver(threadID: Int, singleThread: Bool? = nil) async throws {
    try await runtime.stepOver(threadID: threadID, singleThread: singleThread)
  }

  public func stepIn(threadID: Int, singleThread: Bool? = nil) async throws {
    try await runtime.stepIn(threadID: threadID, singleThread: singleThread)
  }

  public func stepOut(threadID: Int, singleThread: Bool? = nil) async throws {
    try await runtime.stepOut(threadID: threadID, singleThread: singleThread)
  }

  public func stepBack(threadID: Int, singleThread: Bool? = nil) async throws {
    try await runtime.stepBack(threadID: threadID, singleThread: singleThread)
  }

  public func reverseContinue(threadID: Int, singleThread: Bool? = nil) async throws {
    try await runtime.reverseContinue(threadID: threadID, singleThread: singleThread)
  }

  public func restartFrame(_ frameID: Int) async throws {
    try await runtime.restartFrame(frameID)
  }

  public func restartDebugger(arguments: DAPValue = [:]) async throws {
    try await runtime.restartDebugger(arguments: arguments)
  }

  public func terminateDebugger() async throws {
    try await runtime.terminateDebugger()
  }

  public func rawDebugRequest(
    command: String,
    arguments: DAPValue? = nil
  ) async throws -> DAPResponse {
    try await runtime.rawDebugRequest(command: command, arguments: arguments)
  }

  public func disconnectDebugger(
    arguments: DisconnectArguments = .init()
  ) async throws {
    try await runtime.disconnectDebugger(arguments: arguments)
  }

  /// Closes documents, disconnects the debugger, and shuts down the language server.
  public func shutdown() async throws {
    do {
      try await runtime.shutdown()
    } catch {
      languageServerMessageTask?.cancel()
      await lifetimeTaskStore.cancelAllAndWait()
      languageServerMessageContinuation.finish()
      throw error
    }
    languageServerMessageTask?.cancel()
    await lifetimeTaskStore.cancelAllAndWait()
    languageServerMessageContinuation.finish()
  }
}

private final class BackendLifetimeTaskStore: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [Task<Void, Never>] = []

  func insert(_ task: Task<Void, Never>) {
    lock.lock()
    tasks.append(task)
    lock.unlock()
  }

  func cancelAll() {
    let pending = takeAll()
    for task in pending { task.cancel() }
  }

  func cancelAllAndWait() async {
    let pending = takeAll()
    for task in pending { task.cancel() }
    for task in pending { await task.value }
  }

  private func takeAll() -> [Task<Void, Never>] {
    lock.lock()
    let pending = tasks
    tasks.removeAll(keepingCapacity: false)
    lock.unlock()
    return pending
  }
}

/// A shorter alias for applications that only host one editor backend.
public typealias EditorBackend = SwiftEditorBackend

/// Coordinates operations that arrive while a document is still completing its open lifecycle.
/// Language servers may send workspace requests immediately after `didOpen`; those requests must
/// wait for the document to become fully synchronized instead of observing a transient missing state.
private actor EditorDocumentOpenGate {
  private var result: Result<Void, any Error>?
  private var waiters: [CheckedContinuation<Void, any Error>] = []

  func wait() async throws {
    if let result { return try result.get() }
    try await withCheckedThrowingContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func resolve(_ result: Result<Void, any Error>) {
    guard self.result == nil else { return }
    self.result = result
    let pending = waiters
    waiters.removeAll(keepingCapacity: false)
    for continuation in pending {
      switch result {
      case .success: continuation.resume()
      case .failure(let error): continuation.resume(throwing: error)
      }
    }
  }
}

private actor Runtime {
  private enum Lifecycle {
    case active
    case shuttingDown
    case shutDown
  }

  private let languageID: String
  private let languageService: (any LanguageIntelligenceProviding)?
  private let languageCatalog: EditorLanguageCatalog
  private let syntaxFactory: SwiftEditorBackend.SyntaxFactory?
  private let contextualSyntaxFactory: SwiftEditorBackend.ContextualSyntaxFactory?
  private let completionStrategy: SwiftEditorCompletionStrategy
  private let completionLimit: Int
  private let sourceWorkspace: SourceWorkspace
  private let externalSourceIndex: ExternalSourceIndex
  private let languageServerShutdown: SwiftEditorBackend.LanguageServerShutdown
  private let diagnosticBroadcaster: DiagnosticBroadcaster
  private let debugEventContinuation: AsyncStream<DAPEvent>.Continuation
  private let debugEventEnvelopeContinuation: AsyncStream<EditorDebugEventEnvelope>.Continuation
  private let debugStandardErrorContinuation: AsyncStream<String>.Continuation
  private let debugStandardErrorEnvelopeContinuation:
    AsyncStream<EditorDebugTextEnvelope>.Continuation
  private let debugTransportErrorContinuation: AsyncStream<String>.Continuation
  private let debugTransportErrorEnvelopeContinuation:
    AsyncStream<EditorDebugTextEnvelope>.Continuation
  private var contextualCompletionProvider = ContextualCompletionProvider()
  private var completionUsageHistory = CompletionUsageHistory()

  private var documents: [URL: EditorDocument] = [:]
  private var openingDocuments: [URL: EditorDocumentOpenGate] = [:]
  private var sourceMonitorTask: Task<Void, Never>?
  private var sourceMonitorDebounceTask: Task<Void, Never>?
  private var sourceMonitorGeneration: UInt64 = 0
  private var pendingSourceEventPaths: Set<String> = []
  private var sourceMonitorRequiresFullScan = false
  private var debugConnection: DAPProcessConnection?
  private var debugClient: DAPClient?
  private var debugSessionGeneration: UInt64 = 0
  private var debugEventTask: Task<Void, Never>?
  private var debugStandardErrorTask: Task<Void, Never>?
  private var debugTransportErrorTask: Task<Void, Never>?
  private var debugTerminationTask: Task<Void, Never>?
  private var lifecycle = Lifecycle.active
  private var shutdownResult: Result<Void, any Error>?
  private var shutdownWaiters: [CheckedContinuation<Void, any Error>] = []

  init(
    languageID: String,
    languageService: (any LanguageIntelligenceProviding)?,
    languageCatalog: EditorLanguageCatalog,
    syntaxFactory: SwiftEditorBackend.SyntaxFactory?,
    contextualSyntaxFactory: SwiftEditorBackend.ContextualSyntaxFactory?,
    completionStrategy: SwiftEditorCompletionStrategy,
    completionLimit: Int,
    sourceWorkspace: SourceWorkspace,
    externalSourceIndex: ExternalSourceIndex,
    languageServerShutdown: @escaping SwiftEditorBackend.LanguageServerShutdown,
    diagnosticBroadcaster: DiagnosticBroadcaster,
    debugEventContinuation: AsyncStream<DAPEvent>.Continuation,
    debugEventEnvelopeContinuation: AsyncStream<EditorDebugEventEnvelope>.Continuation,
    debugStandardErrorContinuation: AsyncStream<String>.Continuation,
    debugStandardErrorEnvelopeContinuation: AsyncStream<EditorDebugTextEnvelope>.Continuation,
    debugTransportErrorContinuation: AsyncStream<String>.Continuation,
    debugTransportErrorEnvelopeContinuation: AsyncStream<EditorDebugTextEnvelope>.Continuation
  ) {
    self.languageID = languageID
    self.languageService = languageService
    self.languageCatalog = languageCatalog
    self.syntaxFactory = syntaxFactory
    self.contextualSyntaxFactory = contextualSyntaxFactory
    self.completionStrategy = completionStrategy
    self.completionLimit = completionLimit
    self.sourceWorkspace = sourceWorkspace
    self.externalSourceIndex = externalSourceIndex
    self.languageServerShutdown = languageServerShutdown
    self.diagnosticBroadcaster = diagnosticBroadcaster
    self.debugEventContinuation = debugEventContinuation
    self.debugEventEnvelopeContinuation = debugEventEnvelopeContinuation
    self.debugStandardErrorContinuation = debugStandardErrorContinuation
    self.debugStandardErrorEnvelopeContinuation = debugStandardErrorEnvelopeContinuation
    self.debugTransportErrorContinuation = debugTransportErrorContinuation
    self.debugTransportErrorEnvelopeContinuation = debugTransportErrorEnvelopeContinuation
  }

  func startSourceWorkspaceMonitoring(every interval: Duration) {
    guard sourceMonitorTask == nil else { return }
    sourceMonitorGeneration &+= 1
    let generation = sourceMonitorGeneration
    let debounceInterval = interval < .milliseconds(100) ? .milliseconds(100) : interval

    #if os(macOS)
      let rootPath = sourceWorkspace.rootURL.path
      sourceMonitorTask = Task { [weak self] in
        guard let self else { return }
        let flags = FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagIgnoreSelf
        )
        let events = FSEventAsyncStream(path: rootPath, flags: flags)
        let safetyScan = Task { [weak self] in
          while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) } catch { break }
            guard let self, !Task.isCancelled else { break }
            await self.performSourceMonitorScan(expectedGeneration: generation)
          }
        }
        defer { safetyScan.cancel() }

        for await event in events {
          guard !Task.isCancelled else { break }
          await self.enqueueSourceMonitorEvent(
            event,
            debounceInterval: debounceInterval,
            generation: generation
          )
        }
        await self.sourceMonitorDidFinish(generation: generation)
      }
    #else
      // FSEvents is macOS-only. Other supported platforms retain a conservative
      // fallback instead of continuously rescanning the workspace every second.
      let fallbackInterval = max(debounceInterval, .seconds(10))
      sourceMonitorTask = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: fallbackInterval) } catch { break }
          guard let self, !Task.isCancelled else { break }
          await self.performSourceMonitorScan(expectedGeneration: generation)
        }
        await self?.sourceMonitorDidFinish(generation: generation)
      }
    #endif
  }

  #if os(macOS)
    private func enqueueSourceMonitorEvent(
      _ event: FSEvent,
      debounceInterval: Duration,
      generation: UInt64
    ) {
      guard generation == sourceMonitorGeneration else { return }
      switch event {
      case .streamHistoryDone:
        return
      case .mustScanSubDirs(_, _), .eventIdsWrapped, .rootChanged(_, _),
        .volumeMounted(_, _, _), .volumeUnmounted(_, _, _):
        sourceMonitorRequiresFullScan = true
      case .generic(let path, _, _):
        pendingSourceEventPaths.insert(path)
      case .itemCreated(let path, let type, _, _),
        .itemRemoved(let path, let type, _, _),
        .itemInodeMetadataModified(let path, let type, _, _),
        .itemRenamed(let path, let type, _, _),
        .itemDataModified(let path, let type, _, _),
        .itemFinderInfoModified(let path, let type, _, _),
        .itemOwnershipModified(let path, let type, _, _),
        .itemXattrModified(let path, let type, _, _),
        .itemClonedAtPath(let path, let type, _, _):
        if case .dir = type {
          sourceMonitorRequiresFullScan = true
        } else {
          pendingSourceEventPaths.insert(path)
        }
      }

      sourceMonitorDebounceTask?.cancel()
      sourceMonitorDebounceTask = Task { [weak self] in
        do { try await Task.sleep(for: debounceInterval) } catch { return }
        guard let self, !Task.isCancelled else { return }
        await self.flushPendingSourceMonitorRefresh(generation: generation)
      }
    }
  #endif

  private func flushPendingSourceMonitorRefresh(generation: UInt64) async {
    guard generation == sourceMonitorGeneration else { return }
    let paths = pendingSourceEventPaths
    let forceFullScan = sourceMonitorRequiresFullScan
    pendingSourceEventPaths.removeAll(keepingCapacity: true)
    sourceMonitorRequiresFullScan = false
    sourceMonitorDebounceTask = nil

    guard forceFullScan || !paths.isEmpty else { return }
    if forceFullScan || paths.count > 128 {
      await performSourceMonitorScan(expectedGeneration: generation)
      return
    }

    var refreshExternalSources = false
    do {
      for path in paths.sorted() {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard await sourceWorkspace.contains(url) else { continue }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue
        {
          await performSourceMonitorScan(expectedGeneration: generation)
          return
        }

        let previous = try? await sourceWorkspace.file(at: url)
        let key = documentKey(url)
        let openDocument = documents[key]
        let openSnapshot: TextSnapshot?
        let openLanguageID: String?
        if let openDocument {
          openSnapshot = await openDocument.snapshot
          openLanguageID = await openDocument.languageID
        } else {
          openSnapshot = nil
          openLanguageID = nil
        }
        let refreshed = try await sourceWorkspace.refreshFileFromDisk(at: url)

        let contentChanged =
          previous == nil
          || previous?.diskFingerprint?.contentHash != refreshed?.diskFingerprint?.contentHash
          || refreshed?.state == .missing
          || refreshed?.state == .conflicted
        if contentChanged, let openSnapshot, let openLanguageID {
          _ = try await sourceWorkspace.synchronizeOpenDocument(
            at: key,
            snapshot: openSnapshot,
            languageID: openLanguageID,
            markExternalConflict: true
          )
        }

        refreshExternalSources = refreshExternalSources || shouldRefreshExternalSources(for: url)
      }
      if refreshExternalSources { _ = await externalSourceIndex.refresh() }
    } catch {
      await sourceWorkspace.reportScanFailure(String(describing: error))
      await performSourceMonitorScan(expectedGeneration: generation)
    }
  }

  private func shouldRefreshExternalSources(for url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    if [
      "package.swift", "package.resolved", "cargo.toml", "cargo.lock", "package.json",
      "pyproject.toml", "requirements.txt", "pipfile", "pipfile.lock", "poetry.lock",
      "uv.lock", "pyvenv.cfg", ".python-version", "go.mod", "go.sum", "pom.xml",
      "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
    ].contains(name) {
      return true
    }
    if name.hasPrefix("requirements") && name.hasSuffix(".txt") { return true }

    let components = url.pathComponents.map { $0.lowercased() }
    for index in components.indices {
      let component = components[index]
      if component == "node_modules" || component == "vendor" || component == "pods"
        || component == "carthage" || component == ".venv" || component == "venv"
      {
        return true
      }
      if component == ".build", components.indices.contains(index + 1),
        ["checkouts", "artifacts"].contains(components[index + 1])
      {
        return true
      }
    }
    return false
  }

  private func performSourceMonitorScan(expectedGeneration: UInt64? = nil) async {
    if let expectedGeneration, expectedGeneration != sourceMonitorGeneration { return }
    do {
      _ = try await scanSourceWorkspace()
    } catch {
      await sourceWorkspace.reportScanFailure(String(describing: error))
    }
  }

  private func sourceMonitorDidFinish(generation: UInt64) {
    guard generation == sourceMonitorGeneration else { return }
    sourceMonitorTask = nil
    cancelPendingSourceMonitorRefresh()
  }

  private func cancelPendingSourceMonitorRefresh() {
    sourceMonitorDebounceTask?.cancel()
    sourceMonitorDebounceTask = nil
    pendingSourceEventPaths.removeAll(keepingCapacity: true)
    sourceMonitorRequiresFullScan = false
  }

  func stopSourceWorkspaceMonitoring() {
    sourceMonitorGeneration &+= 1
    sourceMonitorTask?.cancel()
    sourceMonitorTask = nil
    cancelPendingSourceMonitorRefresh()
  }

  func isSourceWorkspaceMonitoring() -> Bool {
    sourceMonitorTask != nil
  }

  func scanSourceWorkspace() async throws -> SourceWorkspaceScanReport {
    try ensureActive()
    var openFiles: [(URL, SourceFileID?, TextSnapshot, String)] = []
    for (uri, document) in documents {
      let id = try? await sourceWorkspace.file(at: uri).id
      openFiles.append((uri, id, await document.snapshot, await document.languageID))
    }
    let report = try await sourceWorkspace.scan()
    let externallyChanged = Set(report.refreshed + report.conflicted + report.missing)
    // Open editor buffers remain authoritative. A disk change becomes a conflict
    // instead of replacing the text currently displayed by the editor.
    for (uri, id, snapshot, documentLanguageID) in openFiles {
      _ = try await sourceWorkspace.synchronizeOpenDocument(
        at: uri,
        snapshot: snapshot,
        languageID: documentLanguageID,
        markExternalConflict: id.map(externallyChanged.contains) ?? false
      )
    }
    _ = await externalSourceIndex.refresh()
    return report
  }

  func refreshExternalSourceIndex() async -> ExternalSourceIndexReport {
    await externalSourceIndex.refresh()
  }

  func externalSourceIndexReport() async -> ExternalSourceIndexReport {
    await externalSourceIndex.report()
  }

  func restoreSourceWorkspace(
    from archive: SourceWorkspaceArchive,
    policy: SourceWorkspaceRestorePolicy,
    mode: SourceWorkspaceRestoreMode,
    closeOpenDocuments: Bool
  ) async throws -> SourceWorkspaceRestoreReport {
    try ensureActive()
    var workspaceOpenURLs: [URL] = []
    for uri in documents.keys where await sourceWorkspace.contains(uri) {
      workspaceOpenURLs.append(uri)
    }
    workspaceOpenURLs.sort { $0.absoluteString < $1.absoluteString }
    guard closeOpenDocuments || workspaceOpenURLs.isEmpty else {
      throw SwiftEditorBackendError.sourceWorkspaceHasOpenDocuments(workspaceOpenURLs)
    }
    let captured = try await captureAndClose(workspaceOpenURLs)
    do {
      return try await sourceWorkspace.restore(from: archive, policy: policy, mode: mode)
    } catch {
      for (uri, snapshot, languageID) in captured {
        try? await openDocument(uri: uri, text: snapshot.text, languageID: languageID)
      }
      throw error
    }
  }

  func restoreSourceWorkspace(
    from data: Data,
    policy: SourceWorkspaceRestorePolicy,
    mode: SourceWorkspaceRestoreMode,
    closeOpenDocuments: Bool
  ) async throws -> SourceWorkspaceRestoreReport {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let archive: SourceWorkspaceArchive
    do { archive = try decoder.decode(SourceWorkspaceArchive.self, from: data) } catch {
      throw SourceWorkspaceError.invalidArchive(String(describing: error))
    }
    return try await restoreSourceWorkspace(
      from: archive,
      policy: policy,
      mode: mode,
      closeOpenDocuments: closeOpenDocuments
    )
  }

  func setSourceFileContentsAtomically(_ updates: [SourceFileContentUpdate]) async throws
    -> [SourceCodeFile]
  {
    try ensureActive()
    guard Set(updates.map(\.fileID)).count == updates.count else {
      throw SourceWorkspaceError.invalidBatch("A file may appear only once.")
    }
    var documentEdits: [WorkspaceDocumentEdit] = []
    documentEdits.reserveCapacity(updates.count)
    for update in updates {
      let file = try await sourceFile(id: update.fileID)
      let snapshot = file.snapshot
      let end = try snapshot.position(atUTF16Offset: snapshot.utf16Count)
      documentEdits.append(
        WorkspaceDocumentEdit(
          uri: file.url,
          version: update.expectedVersion,
          edits: [TextEdit(range: .init(start: .zero, end: end), replacement: update.content)]
        )
      )
    }
    let application = try await applyWorkspaceEdit(
      EditorWorkspaceEdit(documentEdits: documentEdits),
      openMissingFiles: true
    )
    for uri in application.openedDocuments { try? await closeDocument(uri: uri) }
    var output: [SourceCodeFile] = []
    for update in updates { output.append(try await sourceWorkspace.file(id: update.fileID)) }
    return output
  }

  func applySourceFileEditsAtomically(_ batches: [SourceFileEditBatch]) async throws
    -> [SourceCodeFile]
  {
    try ensureActive()
    guard Set(batches.map(\.fileID)).count == batches.count else {
      throw SourceWorkspaceError.invalidBatch("A file may appear only once.")
    }
    var documentEdits: [WorkspaceDocumentEdit] = []
    documentEdits.reserveCapacity(batches.count)
    for batch in batches {
      let file = try await sourceFile(id: batch.fileID)
      documentEdits.append(
        WorkspaceDocumentEdit(
          uri: file.url,
          version: batch.expectedVersion,
          edits: batch.edits
        )
      )
    }
    let application = try await applyWorkspaceEdit(
      EditorWorkspaceEdit(documentEdits: documentEdits),
      openMissingFiles: true
    )
    for uri in application.openedDocuments { try? await closeDocument(uri: uri) }
    var output: [SourceCodeFile] = []
    for batch in batches { output.append(try await sourceWorkspace.file(id: batch.fileID)) }
    return output
  }

  func dirtySourceFiles() async throws -> [SourceCodeFile] {
    try ensureActive()
    try await synchronizeAllOpenDocuments()
    return await sourceWorkspace.dirtyFiles()
  }

  func searchSource(_ pattern: SourceSearchPattern, options: SourceSearchOptions) async throws
    -> [SourceSearchMatch]
  {
    try ensureActive()
    try await synchronizeAllOpenDocuments()
    return try await sourceWorkspace.search(pattern, options: options)
  }

  func previewSourceReplacement(
    _ pattern: SourceSearchPattern,
    replacementTemplate: String,
    options: SourceSearchOptions
  ) async throws -> SourceReplacementPreview {
    try ensureActive()
    for (uri, document) in documents where await sourceWorkspace.contains(uri) {
      _ = try await sourceWorkspace.synchronizeOpenDocument(
        at: uri,
        snapshot: await document.snapshot,
        languageID: await document.languageID
      )
    }
    return try await sourceWorkspace.previewReplacement(
      pattern,
      replacementTemplate: replacementTemplate,
      options: options
    )
  }

  func applySourceReplacement(_ preview: SourceReplacementPreview) async throws
    -> [SourceCodeFile]
  {
    try await applySourceFileEditsAtomically(
      preview.files.map {
        SourceFileEditBatch(
          fileID: $0.fileID,
          edits: $0.edits,
          expectedVersion: $0.expectedVersion
        )
      }
    )
  }

  func saveAllSourceFiles(overwriteExternalChanges: Bool) async throws -> [SourceCodeFile] {
    try ensureActive()
    try await synchronizeAllOpenDocuments()
    let dirty = await sourceWorkspace.dirtyFiles()
    var results: [SourceCodeFile] = []
    for file in dirty {
      results.append(
        try await saveSourceFile(file.id, overwriteExternalChanges: overwriteExternalChanges))
    }
    return results
  }

  func sourceFile(id: SourceFileID) async throws -> SourceCodeFile {
    try ensureActive()
    let stored = try await sourceWorkspace.file(id: id)
    if let document = documents[stored.url] {
      _ = try await sourceWorkspace.synchronizeOpenDocument(
        at: stored.url,
        snapshot: await document.snapshot,
        languageID: await document.languageID)
      return try await sourceWorkspace.file(id: id)
    }
    return stored
  }

  func sourceFile(relativePath: String) async throws -> SourceCodeFile {
    try ensureActive()
    let stored = try await sourceWorkspace.file(relativePath: relativePath)
    return try await sourceFile(id: stored.id)
  }

  func createSourceFile(
    at relativePath: String,
    content: String,
    languageID explicitLanguageID: String?,
    persistImmediately: Bool,
    openInEditor: Bool
  ) async throws -> SourceCodeFile {
    try ensureActive()
    let file = try await sourceWorkspace.createFile(
      at: relativePath,
      content: content,
      languageID: explicitLanguageID,
      persistImmediately: persistImmediately
    )
    guard openInEditor else { return file }
    do {
      try await openDocument(uri: file.url, text: file.content, languageID: file.languageID)
      return try await sourceWorkspace.file(id: file.id)
    } catch {
      try? await sourceWorkspace.removeFile(file.id, deleteFromDisk: persistImmediately)
      throw error
    }
  }

  func openSourceFile(id: SourceFileID) async throws -> URL {
    try ensureActive()
    let file = try await sourceWorkspace.file(id: id)
    if documents[file.url] == nil {
      try await openDocument(
        uri: file.url, text: file.content, languageID: file.languageID)
    }
    return file.url
  }

  func setSourceFileContent(
    _ content: String,
    for id: SourceFileID,
    expectedVersion: Int?
  ) async throws -> SourceCodeFile {
    try ensureActive()
    let file = try await sourceWorkspace.file(id: id)
    if let document = documents[file.url] {
      let current = await document.snapshot
      if let expectedVersion, expectedVersion != current.version {
        throw SourceWorkspaceError.versionMismatch(
          file.relativePath, expected: expectedVersion, actual: current.version)
      }
      _ = try await replaceText(in: file.url, with: content)
      return try await sourceWorkspace.file(id: id)
    }
    return try await sourceWorkspace.setContent(
      content, for: id, expectedVersion: expectedVersion)
  }

  func applySourceFileEdits(
    _ edits: [TextEdit],
    to id: SourceFileID,
    expectedVersion: Int?
  ) async throws -> SourceCodeFile {
    try ensureActive()
    let file = try await sourceWorkspace.file(id: id)
    if let document = documents[file.url] {
      let current = await document.snapshot
      if let expectedVersion, expectedVersion != current.version {
        throw SourceWorkspaceError.versionMismatch(
          file.relativePath, expected: expectedVersion, actual: current.version)
      }
      _ = try await apply(edits, to: file.url)
      return try await sourceWorkspace.file(id: id)
    }
    return try await sourceWorkspace.apply(
      edits, to: id, expectedVersion: expectedVersion)
  }

  func setSourceFileEncoding(_ encoding: SourceTextEncoding, for id: SourceFileID) async throws
    -> SourceCodeFile
  {
    try ensureActive()
    return try await sourceWorkspace.setEncoding(encoding, for: id)
  }

  func convertSourceFileLineEndings(_ ending: SourceLineEnding, for id: SourceFileID) async throws
    -> SourceCodeFile
  {
    try ensureActive()
    let file = try await sourceFile(id: id)
    let converted = try ending.converting(file.content)
    guard converted != file.content else { return file }
    return try await setSourceFileContent(converted, for: id, expectedVersion: file.version)
  }

  func saveSourceFile(_ id: SourceFileID, overwriteExternalChanges: Bool) async throws
    -> SourceCodeFile
  {
    try ensureActive()
    let file = try await sourceWorkspace.file(id: id)
    if documents[file.url] != nil {
      try await persistDocument(at: file.url, overwriteExternalChanges: overwriteExternalChanges)
      return try await sourceWorkspace.file(id: id)
    }
    return try await sourceWorkspace.save(
      id, overwriteExternalChanges: overwriteExternalChanges)
  }

  func reloadSourceFile(_ id: SourceFileID) async throws -> SourceCodeFile {
    try ensureActive()
    let existing = try await sourceWorkspace.file(id: id)
    let reloaded = try await sourceWorkspace.reloadFromDisk(id)
    if documents[existing.url] != nil {
      _ = try await replaceText(in: existing.url, with: reloaded.content)
    }
    return try await sourceWorkspace.file(id: id)
  }

  func resolveSourceFileConflict(
    _ id: SourceFileID,
    using resolution: SourceWorkspaceConflictResolution
  ) async throws -> SourceCodeFile {
    try ensureActive()
    switch resolution {
    case .useMemory:
      return try await saveSourceFile(id, overwriteExternalChanges: true)
    case .useDisk:
      return try await reloadSourceFile(id)
    }
  }

  func moveSourceFile(_ id: SourceFileID, to newRelativePath: String) async throws -> SourceCodeFile
  {
    try ensureActive()
    let oldFile = try await sourceWorkspace.file(id: id)
    guard let openDocument = documents[oldFile.url] else {
      return try await sourceWorkspace.moveFile(id, to: newRelativePath)
    }
    let oldSnapshot = await openDocument.snapshot
    try await openDocument.close()
    documents.removeValue(forKey: oldFile.url)
    do {
      let moved = try await sourceWorkspace.moveFile(id, to: newRelativePath)
      do {
        try await self.openDocument(
          uri: moved.url, text: oldSnapshot.text, languageID: oldFile.languageID)
        return try await sourceWorkspace.file(id: id)
      } catch {
        _ = try? await sourceWorkspace.moveFile(id, to: oldFile.relativePath)
        try? await self.openDocument(
          uri: oldFile.url, text: oldSnapshot.text, languageID: oldFile.languageID)
        throw error
      }
    } catch {
      try? await self.openDocument(
        uri: oldFile.url, text: oldSnapshot.text, languageID: oldFile.languageID)
      throw error
    }
  }

  func removeSourceFile(_ id: SourceFileID, deleteFromDisk: Bool) async throws {
    try ensureActive()
    let file = try await sourceWorkspace.file(id: id)
    let openSnapshot: TextSnapshot?
    if let document = documents[file.url] {
      openSnapshot = await document.snapshot
      try await document.close()
      documents.removeValue(forKey: file.url)
      await diagnosticBroadcaster.clear(file.url)
    } else {
      openSnapshot = nil
    }
    do {
      try await sourceWorkspace.removeFile(id, deleteFromDisk: deleteFromDisk)
    } catch {
      if let openSnapshot {
        try? await openDocument(
          uri: file.url, text: openSnapshot.text, languageID: file.languageID)
      }
      throw error
    }
  }

  func createSourceDirectory(at relativePath: String) async throws {
    try ensureActive()
    try await sourceWorkspace.createDirectory(at: relativePath)
  }

  func moveSourceDirectory(from oldRelativePath: String, to newRelativePath: String) async throws {
    try ensureActive()
    let oldPrefix = try await sourceWorkspace.url(forRelativePath: oldRelativePath).path
    let open = documents.keys.filter { $0.path.hasPrefix(oldPrefix + "/") }
      .sorted { $0.path < $1.path }
    let snapshots = try await captureAndClose(open)
    var reopenedNewURLs: [URL] = []
    do {
      try await sourceWorkspace.moveDirectory(from: oldRelativePath, to: newRelativePath)
      let newRoot = try await sourceWorkspace.url(forRelativePath: newRelativePath)
      for (oldURL, snapshot, documentLanguageID) in snapshots {
        let suffix = String(oldURL.path.dropFirst(oldPrefix.count))
        let newURL = URL(fileURLWithPath: newRoot.path + suffix)
        try await openDocument(
          uri: newURL, text: snapshot.text, languageID: documentLanguageID)
        reopenedNewURLs.append(newURL)
      }
    } catch {
      for url in reopenedNewURLs.reversed() {
        if let document = documents[url] { try? await document.close() }
        documents.removeValue(forKey: url)
        await diagnosticBroadcaster.clear(url)
      }
      try? await sourceWorkspace.moveDirectory(from: newRelativePath, to: oldRelativePath)
      for (url, snapshot, documentLanguageID) in snapshots where documents[url] == nil {
        try? await openDocument(
          uri: url, text: snapshot.text, languageID: documentLanguageID)
      }
      throw error
    }
  }

  func removeSourceDirectory(at relativePath: String, recursively: Bool) async throws {
    try ensureActive()
    let directoryURL = try await sourceWorkspace.url(forRelativePath: relativePath)
    let open = documents.keys.filter { $0.path.hasPrefix(directoryURL.path + "/") }
    if !recursively, !open.isEmpty { throw SourceWorkspaceError.directoryNotEmpty(relativePath) }
    let snapshots = try await captureAndClose(open)
    do {
      try await sourceWorkspace.removeDirectory(at: relativePath, recursively: recursively)
    } catch {
      for (url, snapshot, documentLanguageID) in snapshots {
        try? await openDocument(
          uri: url, text: snapshot.text, languageID: documentLanguageID)
      }
      throw error
    }
  }

  private func captureAndClose(_ urls: [URL]) async throws -> [(URL, TextSnapshot, String)] {
    var captured: [(URL, TextSnapshot, String)] = []
    do {
      for url in urls {
        guard let document = documents[url] else { continue }
        let snapshot = await document.snapshot
        try await document.close()
        documents.removeValue(forKey: url)
        await diagnosticBroadcaster.clear(url)
        captured.append((url, snapshot, await document.languageID))
      }
      return captured
    } catch {
      for (url, snapshot, documentLanguageID) in captured {
        try? await openDocument(
          uri: url, text: snapshot.text, languageID: documentLanguageID)
      }
      throw error
    }
  }

  func openFile(uri: URL, languageID explicitLanguageID: String?) async throws {
    try ensureActive()
    let key = documentKey(uri)
    if let opening = openingDocuments[key] {
      try await opening.wait()
      return
    }
    guard documents[key] == nil else { throw SwiftEditorBackendError.documentAlreadyOpen(key) }
    if await sourceWorkspace.contains(key) {
      let file: SourceCodeFile
      do {
        file = try await sourceWorkspace.file(at: key)
      } catch SourceWorkspaceError.fileNotFound {
        file = try await sourceWorkspace.loadFileFromDisk(at: key)
      }
      try await openDocument(
        uri: key,
        text: file.content,
        languageID: explicitLanguageID ?? file.languageID
      )
      return
    }
    let data = try await Task.detached { @Sendable in try Data(contentsOf: key) }.value
    guard let text = String(data: data, encoding: .utf8) else {
      throw SwiftEditorBackendError.invalidUTF8(key)
    }
    try await openDocument(uri: key, text: text, languageID: explicitLanguageID)
  }

  func openDocument(uri: URL, text: String, languageID explicitLanguageID: String?) async throws {
    try ensureActive()
    let key = documentKey(uri)
    if let opening = openingDocuments[key] {
      try await opening.wait()
      return
    }
    guard documents[key] == nil else { throw SwiftEditorBackendError.documentAlreadyOpen(key) }

    let opening = EditorDocumentOpenGate()
    openingDocuments[key] = opening
    let inferredLanguageID = languageCatalog.languageID(for: key)
    let documentLanguageID =
      explicitLanguageID
      ?? (inferredLanguageID == languageCatalog.fallbackLanguageID
        ? languageID : inferredLanguageID)
    let context = EditorSyntaxServiceContext(uri: key, languageID: documentLanguageID)
    let syntax = try contextualSyntaxFactory?(context) ?? syntaxFactory?()
    let document = EditorDocument(
      uri: key,
      languageID: documentLanguageID,
      text: text,
      syntax: syntax,
      language: languageService
    )

    // Publish the document before awaiting external services. Re-entrant workspace requests can
    // locate it, but `requireDocument` waits on the gate until opening and source synchronization
    // have completed.
    documents[key] = document
    do {
      try await document.open()
      _ = try await sourceWorkspace.synchronizeOpenDocument(
        at: key,
        snapshot: await document.snapshot,
        languageID: documentLanguageID
      )
      await diagnosticBroadcaster.clear(key)
      openingDocuments.removeValue(forKey: key)
      await opening.resolve(.success(()))
    } catch {
      documents.removeValue(forKey: key)
      openingDocuments.removeValue(forKey: key)
      try? await document.close()
      await opening.resolve(.failure(error))
      throw error
    }
  }

  func closeDocument(uri: URL) async throws {
    let key = documentKey(uri)
    let document = try await requireDocument(key)
    try await document.close()
    documents.removeValue(forKey: key)
    await diagnosticBroadcaster.clear(key)
  }

  func closeAllDocuments() async throws {
    var firstError: Error?
    for uri in documents.keys.sorted(by: { $0.absoluteString < $1.absoluteString }) {
      guard let document = documents[uri] else { continue }
      do {
        try await document.close()
        documents.removeValue(forKey: uri)
      } catch {
        if firstError == nil { firstError = error }
      }
    }
    if let firstError { throw firstError }
  }

  func openDocumentURLs() -> [URL] {
    documents.keys.sorted { $0.absoluteString < $1.absoluteString }
  }

  func isDocumentOpen(uri: URL) -> Bool {
    documents[documentKey(uri)] != nil
  }

  func documentLanguageID(uri: URL) async throws -> String {
    let document = try await requireDocument(uri)
    return await document.languageID
  }

  func snapshot(of uri: URL) async throws -> TextSnapshot {
    let document = try await requireDocument(uri)
    return await document.snapshot
  }

  func state(of uri: URL) async throws -> EditorDocument.State {
    let document = try await requireDocument(uri)
    return await document.state
  }

  func apply(_ edit: TextEdit, to uri: URL) async throws -> AppliedTextEdit {
    let document = try await requireDocument(uri)
    let original = await document.snapshot
    let documentLanguageID = await document.languageID
    let applied = try await document.apply(edit)
    do {
      _ = try await sourceWorkspace.synchronizeOpenDocument(
        at: uri,
        snapshot: applied.newSnapshot,
        languageID: documentLanguageID
      )
      return applied
    } catch {
      try? await document.restore(snapshot: original)
      _ = try? await sourceWorkspace.synchronizeOpenDocument(
        at: uri, snapshot: original, languageID: documentLanguageID)
      throw error
    }
  }

  func apply(_ edits: [TextEdit], to uri: URL) async throws -> [AppliedTextEdit] {
    let document = try await requireDocument(uri)
    let original = await document.snapshot
    let documentLanguageID = await document.languageID
    let applied = try await document.apply(edits)
    do {
      _ = try await sourceWorkspace.synchronizeOpenDocument(
        at: uri,
        snapshot: await document.snapshot,
        languageID: documentLanguageID
      )
      return applied
    } catch {
      try? await document.restore(snapshot: original)
      _ = try? await sourceWorkspace.synchronizeOpenDocument(
        at: uri, snapshot: original, languageID: documentLanguageID)
      throw error
    }
  }

  func replaceText(in uri: URL, with text: String) async throws -> AppliedTextEdit {
    let document = try await requireDocument(uri)
    let snapshot = await document.snapshot
    let end = try snapshot.position(atUTF16Offset: snapshot.utf16Count)
    return try await apply(
      TextEdit(range: EditorTextRange(start: .zero, end: end), replacement: text),
      to: uri
    )
  }

  func resynchronize(uri: URL) async throws {
    try await (try await requireDocument(uri)).resynchronize()
  }

  func highlights(in uri: URL, range: EditorTextRange?) async throws -> [Highlight] {
    try await (try await requireDocument(uri)).highlights(in: range)
  }

  func foldingRanges(in uri: URL) async throws -> [FoldingRange] {
    try await (try await requireDocument(uri)).foldingRanges()
  }

  func completions(
    in uri: URL,
    at position: TextPosition,
    invocation: EditorCompletionInvocation
  ) async throws -> [Completion] {
    let document = try await requireDocument(uri)
    let snapshot = await document.snapshot
    let documentLanguageID = await document.languageID
    let (rankingPoolLimitValue, rankingPoolOverflow) =
      completionLimit.multipliedReportingOverflow(by: 5)
    let expandedRankingPoolLimit = rankingPoolOverflow ? Int.max : rankingPoolLimitValue
    let rankingPoolLimit: Int
    if completionLimit > 2_000 {
      rankingPoolLimit = completionLimit
    } else {
      rankingPoolLimit = min(max(expandedRankingPoolLimit, 500), 2_000)
    }
    let workspaceFiles = await sourceWorkspace.files()
    let externalSnapshot = await externalSourceIndex.snapshot()
    let fallbackResult = try contextualCompletionProvider.completions(
      snapshot: snapshot,
      uri: uri,
      languageID: documentLanguageID,
      position: position,
      triggerCharacter: invocation.triggerCharacter,
      allowEmptyPrefix: invocation == .explicit,
      workspaceFiles: workspaceFiles,
      externalFiles: externalSnapshot.files,
      externalGeneration: externalSnapshot.generation,
      limit: rankingPoolLimit
    )
    let fallback = fallbackResult.completions

    let candidates: [Completion]
    if !invocation.usesLanguageServices {
      candidates = fallback
    } else {
      switch completionStrategy {
      case .languageServerOnly:
        candidates = try await document.completions(
          at: position,
          triggerCharacter: invocation.triggerCharacter
        )
      case .mergeKeywords:
        let preferred = try await document.completions(
          at: position,
          triggerCharacter: invocation.triggerCharacter
        )
        candidates = CompletionUtilities.merge(
          preferred: preferred, fallback: fallback, limit: rankingPoolLimit
        )
      case .mergeKeywordsAndFallbackOnError:
        do {
          let preferred = try await document.completions(
            at: position,
            triggerCharacter: invocation.triggerCharacter
          )
          candidates = CompletionUtilities.merge(
            preferred: preferred, fallback: fallback, limit: rankingPoolLimit
          )
        } catch {
          candidates = fallback
        }
      }
    }

    return try CompletionRankingEngine.rank(
      candidates,
      snapshot: snapshot,
      position: position,
      invocation: invocation,
      languageID: documentLanguageID,
      usageHistory: completionUsageHistory,
      limit: completionLimit,
      currentURI: uri,
      projectSymbols: fallbackResult.projectSymbols
    )
  }

  func resolveCompletion(_ completion: Completion, in uri: URL) async throws -> Completion {
    try await (try await requireDocument(uri)).resolveCompletion(completion)
  }

  func recordCompletionUsage(_ completion: Completion, in uri: URL) async {
    guard let document = try? await requireDocument(uri) else { return }
    let documentLanguageID = await document.languageID
    completionUsageHistory.record(completion, languageID: documentLanguageID)
  }

  func applyCompletion(
    _ completion: Completion, in uri: URL, at position: TextPosition,
    replacing replacementRange: EditorTextRange?, snippetVariables: [String: String]
  ) async throws -> CompletionApplicationResult {
    let document = try await requireDocument(uri)
    let resolved =
      completion.resolutionID == nil ? completion : try await document.resolveCompletion(completion)
    let oldSnapshot = await document.snapshot
    let planned = try CompletionUtilities.plannedApplication(
      for: resolved,
      in: oldSnapshot,
      at: position,
      replacing: replacementRange,
      snippetVariables: snippetVariables
    )
    let documentLanguageID = await document.languageID
    let applied = try await document.apply(planned.edits)
    do {
      _ = try await sourceWorkspace.synchronizeOpenDocument(
        at: uri,
        snapshot: await document.snapshot,
        languageID: documentLanguageID
      )
    } catch {
      try? await document.restore(snapshot: oldSnapshot)
      _ = try? await sourceWorkspace.synchronizeOpenDocument(
        at: uri, snapshot: oldSnapshot, languageID: documentLanguageID)
      throw error
    }
    completionUsageHistory.record(resolved, languageID: documentLanguageID)
    return CompletionApplicationResult(
      appliedEdits: applied,
      snapshot: await document.snapshot,
      insertedRange: planned.insertedRange,
      tabStops: planned.tabStops,
      initialSelection: planned.initialSelection,
      finalCursor: planned.finalCursor,
      command: planned.command
    )
  }

  func hover(in uri: URL, at position: TextPosition) async throws -> HoverResult? {
    try await (try await requireDocument(uri)).hover(at: position)
  }

  func definitions(in uri: URL, at position: TextPosition) async throws -> [SourceLocation] {
    try await (try await requireDocument(uri)).definitions(at: position)
  }

  func references(in uri: URL, at position: TextPosition, includeDeclaration: Bool) async throws
    -> [SourceLocation]
  {
    try await (try await requireDocument(uri)).references(
      at: position, includeDeclaration: includeDeclaration)
  }

  func formattingEdits(in uri: URL, options: EditorFormattingOptions) async throws -> [TextEdit] {
    try await (try await requireDocument(uri)).formatting(options: options)
  }

  func rangeFormattingEdits(in uri: URL, range: EditorTextRange, options: EditorFormattingOptions)
    async throws -> [TextEdit]
  {
    try await (try await requireDocument(uri)).rangeFormatting(range, options: options)
  }

  func formatDocument(in uri: URL, options: EditorFormattingOptions) async throws
    -> [AppliedTextEdit]
  {
    let document = try await requireDocument(uri)
    let expected = await document.snapshot
    let edits = try await document.formatting(options: options)
    return try await applyLanguageEdits(
      edits, to: document, uri: uri, expectedVersion: expected.version)
  }

  func formatRange(in uri: URL, range: EditorTextRange, options: EditorFormattingOptions)
    async throws
    -> [AppliedTextEdit]
  {
    let document = try await requireDocument(uri)
    let expected = await document.snapshot
    let edits = try await document.rangeFormatting(range, options: options)
    return try await applyLanguageEdits(
      edits, to: document, uri: uri, expectedVersion: expected.version)
  }

  private func applyLanguageEdits(
    _ edits: [TextEdit], to document: EditorDocument, uri: URL, expectedVersion: Int
  ) async throws -> [AppliedTextEdit] {
    let current = await document.snapshot
    guard current.version == expectedVersion else {
      throw SwiftEditorBackendError.documentChangedWhileAwaitingLanguageEdits(
        uri, expected: expectedVersion, actual: current.version)
    }
    return edits.isEmpty ? [] : try await apply(edits, to: uri)
  }

  func prepareRename(in uri: URL, at position: TextPosition) async throws -> RenamePreparation? {
    try await (try await requireDocument(uri)).prepareRename(at: position)
  }

  func rename(in uri: URL, at position: TextPosition, to newName: String) async throws
    -> EditorWorkspaceEdit?
  {
    try await (try await requireDocument(uri)).rename(at: position, newName: newName)
  }

  func semanticHighlights(in uri: URL) async throws -> [SemanticHighlight] {
    try await (try await requireDocument(uri)).semanticHighlights()
  }

  func signatureHelp(in uri: URL, at position: TextPosition) async throws -> EditorSignatureHelp? {
    try await (try await requireDocument(uri)).signatureHelp(at: position)
  }

  func documentSymbols(in uri: URL) async throws -> [EditorDocumentSymbol] {
    try await (try await requireDocument(uri)).documentSymbols()
  }

  func workspaceSymbols(matching query: String) async throws -> [EditorWorkspaceSymbol] {
    try ensureActive()
    guard let languageService else {
      throw LanguageFeatureError.unsupported("workspace/symbol")
    }
    return try await languageService.workspaceSymbols(query: query)
  }

  func notifyWorkspaceFileChanges(_ changes: [EditorWorkspaceFileChange]) async throws {
    try ensureActive()
    guard let languageService else { return }
    try await languageService.notifyWorkspaceFileChanges(changes)
  }

  func pullDiagnostics(for uri: URL, previousResultID: String?) async throws -> DiagnosticBatch {
    try ensureActive()
    guard let languageService else {
      throw LanguageFeatureError.unsupported("textDocument/diagnostic")
    }
    return try await languageService.pullDiagnostics(
      uri: documentKey(uri), previousResultID: previousResultID)
  }

  func codeActions(
    in uri: URL,
    range: EditorTextRange,
    diagnostics: [Diagnostic],
    only: [String]?
  ) async throws -> [EditorCodeAction] {
    try await (try await requireDocument(uri)).codeActions(
      in: range, diagnostics: diagnostics, only: only)
  }

  func inlayHints(in uri: URL, range: EditorTextRange) async throws -> [EditorInlayHint] {
    try await (try await requireDocument(uri)).inlayHints(in: range)
  }

  func executeLanguageCommand(_ command: EditorCommand) async throws -> EditorJSONValue? {
    try ensureActive()
    guard let languageService else {
      throw LanguageFeatureError.unsupported("workspace/executeCommand")
    }
    return try await languageService.executeCommand(command)
  }

  func applyWorkspaceEdit(
    _ workspaceEdit: EditorWorkspaceEdit,
    openMissingFiles: Bool
  ) async throws -> WorkspaceEditApplicationResult {
    try ensureActive()
    let documentEdits = workspaceEdit.documentEdits.map { item in
      WorkspaceDocumentEdit(
        uri: documentKey(item.uri),
        version: item.version,
        edits: item.edits
      )
    }

    // Preserve the order supplied by the language server. For the legacy
    // `changes` dictionary, LSPConversions establishes a stable URI order.
    var orderedURIs: [URL] = []
    var seenURIs: Set<URL> = []
    for item in documentEdits where seenURIs.insert(item.uri).inserted {
      orderedURIs.append(item.uri)
    }

    var newlyOpened: [URL] = []
    do {
      for uri in orderedURIs where documents[uri] == nil {
        guard openMissingFiles else { throw SwiftEditorBackendError.documentNotOpen(uri) }
        try await openFile(uri: uri, languageID: nil)
        newlyOpened.append(uri)
      }

      // Validate the complete transaction against virtual buffers before
      // mutating any live document. This also models multiple ordered
      // TextDocumentEdit entries for the same URI correctly.
      var originals: [URL: TextSnapshot] = [:]
      var simulated: [URL: TextBuffer] = [:]
      for uri in orderedURIs {
        let document = try await requireDocument(uri)
        let snapshot = await document.snapshot
        originals[uri] = snapshot
        simulated[uri] = TextBuffer(text: snapshot.text, version: snapshot.version)
      }
      for item in documentEdits {
        guard var buffer = simulated[item.uri] else {
          throw SwiftEditorBackendError.documentNotOpen(item.uri)
        }
        if let expected = item.version, expected != buffer.version {
          throw SwiftEditorBackendError.workspaceVersionMismatch(
            item.uri,
            expected: expected,
            actual: buffer.version
          )
        }
        _ = try buffer.apply(item.edits)
        simulated[item.uri] = buffer
      }

      var appliedURIs: [URL] = []
      var appliedSet: Set<URL> = []
      do {
        for item in documentEdits {
          _ = try await apply(item.edits, to: item.uri)
          if appliedSet.insert(item.uri).inserted { appliedURIs.append(item.uri) }
        }
      } catch {
        var rollbackFailures: [URL] = []
        for uri in appliedURIs.reversed() {
          guard let original = originals[uri] else { continue }
          do {
            let document = try await requireDocument(uri)
            let documentLanguageID = await document.languageID
            try await document.restore(snapshot: original)
            _ = try await sourceWorkspace.synchronizeOpenDocument(
              at: uri, snapshot: original, languageID: documentLanguageID)
          } catch {
            rollbackFailures.append(uri)
          }
        }
        for uri in newlyOpened.reversed() {
          if let document = documents[uri] {
            try? await document.close()
            documents.removeValue(forKey: uri)
          }
        }
        if !rollbackFailures.isEmpty {
          throw SwiftEditorBackendError.workspaceRollbackFailed(
            primary: String(describing: error),
            documents: rollbackFailures.sorted { $0.absoluteString < $1.absoluteString }
          )
        }
        throw error
      }

      return WorkspaceEditApplicationResult(
        appliedDocuments: appliedURIs,
        openedDocuments: newlyOpened,
        pendingFileOperations: workspaceEdit.fileOperations
      )
    } catch {
      for uri in newlyOpened.reversed() {
        if let document = documents[uri] {
          try? await document.close()
          documents.removeValue(forKey: uri)
        }
      }
      throw error
    }
  }

  func persistDocument(
    at uri: URL,
    overwriteExternalChanges: Bool = false
  ) async throws {
    let document = try await requireDocument(uri)
    let documentLanguageID = await document.languageID
    let maxAttempts = 8
    for _ in 0..<maxAttempts {
      let snapshot = await document.snapshot
      if let stored = try await sourceWorkspace.synchronizeOpenDocument(
        at: uri,
        snapshot: snapshot,
        languageID: documentLanguageID
      ) {
        do {
          _ = try await sourceWorkspace.save(
            stored.id,
            overwriteExternalChanges: overwriteExternalChanges,
            expectedVersion: snapshot.version
          )
        } catch SourceWorkspaceError.versionMismatch {
          continue
        }
      } else {
        let data = Data(snapshot.text.utf8)
        try await Task.detached { @Sendable in
          try data.write(to: uri, options: .atomic)
        }.value
      }
      guard await document.snapshot == snapshot else { continue }
      try await document.save(snapshot: snapshot)
      // The language server save notification is asynchronous and can yield.
      // If the user edited during that interval, persist the newer snapshot
      // and emit a matching didSave before reporting success.
      guard await document.snapshot == snapshot else { continue }
      return
    }
    throw SwiftEditorBackendError.documentChangedDuringPersistence(uri, attempts: maxAttempts)
  }

  func saveDocument(at uri: URL) async throws {
    try await (try await requireDocument(uri)).save()
  }

  func startDebugger(
    session: DAPSession,
    connection: DAPProcessConnection?,
    initializeArguments: InitializeArguments,
    reverseRequestHandler: (any DAPReverseRequestHandler)?
  ) async throws -> Capabilities {
    try ensureActive()
    guard debugClient == nil else { throw SwiftEditorBackendError.debuggerAlreadyRunning }
    let client = DAPClient(
      session: session,
      reverseRequestHandler: reverseRequestHandler
    )
    do {
      let capabilities = try await client.initialize(initializeArguments)
      installDebugClient(client, connection: connection)
      return capabilities
    } catch {
      connection?.terminate()
      throw error
    }
  }

  func adoptPreparedDebugger(_ prepared: EditorPreparedDebugSession) async throws {
    try ensureActive()
    guard debugClient == nil else { throw SwiftEditorBackendError.debuggerAlreadyRunning }
    let (client, connection) = try await prepared.consume()
    installDebugClient(client, connection: connection)
  }

  func replaceWithPreparedDebugger(
    _ prepared: EditorPreparedDebugSession,
    disconnectArguments: DisconnectArguments
  ) async throws {
    try ensureActive()
    // Consume first. If the prepared session was discarded or already adopted,
    // the current debugger remains completely untouched.
    let (replacementClient, replacementConnection) = try await prepared.consume()
    let previousClient = debugClient
    let previousConnection = debugConnection
    detachDebugObservers()
    debugClient = nil
    debugConnection = nil
    installDebugClient(replacementClient, connection: replacementConnection)

    guard let previousClient else {
      previousConnection?.terminate()
      return
    }
    do {
      try await previousClient.disconnect(disconnectArguments)
    } catch {
      // The replacement is already active. A failed old-adapter disconnect must
      // not roll the new session back or leak its process tree.
    }
    previousConnection?.terminate()
  }

  private func installDebugClient(
    _ client: DAPClient,
    connection: DAPProcessConnection?
  ) {
    debugSessionGeneration &+= 1
    let generation = debugSessionGeneration
    debugClient = client
    debugConnection = connection
    let eventContinuation = debugEventContinuation
    let eventEnvelopeContinuation = debugEventEnvelopeContinuation
    debugEventTask = Task {
      for await event in client.events {
        eventContinuation.yield(event)
        eventEnvelopeContinuation.yield(
          EditorDebugEventEnvelope(generation: generation, event: event)
        )
      }
    }
    if let connection {
      let standardErrorContinuation = debugStandardErrorContinuation
      let standardErrorEnvelopeContinuation = debugStandardErrorEnvelopeContinuation
      let transportErrorContinuation = debugTransportErrorContinuation
      let transportErrorEnvelopeContinuation = debugTransportErrorEnvelopeContinuation
      debugStandardErrorTask = Task {
        for await line in connection.standardError {
          standardErrorContinuation.yield(line)
          standardErrorEnvelopeContinuation.yield(
            EditorDebugTextEnvelope(generation: generation, text: line)
          )
        }
      }
      debugTransportErrorTask = Task {
        for await error in connection.transportErrors {
          transportErrorContinuation.yield(error)
          transportErrorEnvelopeContinuation.yield(
            EditorDebugTextEnvelope(generation: generation, text: error)
          )
        }
      }
      debugTerminationTask = Task {
        for await termination in connection.terminationEvents {
          guard !termination.expected else { continue }
          let message =
            "DAP process terminated unexpectedly (reason: \(termination.reason.rawValue), status: \(termination.status))."
          transportErrorContinuation.yield(message)
          transportErrorEnvelopeContinuation.yield(
            EditorDebugTextEnvelope(generation: generation, text: message)
          )
        }
      }
    }
  }

  func currentDebugSessionGeneration() -> UInt64 {
    debugSessionGeneration
  }

  func debugState() async throws -> DebugSessionState {
    let client = try requireDebugClient()
    return await client.state
  }

  func debugCapabilities() async throws -> Capabilities? {
    let client = try requireDebugClient()
    return await client.capabilities
  }

  func launchDebugger(arguments: DAPValue) async throws {
    try await requireDebugClient().launch(arguments)
  }

  func attachDebugger(arguments: DAPValue) async throws {
    try await requireDebugClient().attach(arguments)
  }

  func finishDebuggerConfiguration() async throws {
    try await requireDebugClient().configurationDone()
  }

  func setBreakpoints(in sourceURL: URL, breakpoints: [SourceBreakpoint], sourceModified: Bool?)
    async throws -> [Breakpoint]
  {
    try await requireDebugClient().setBreakpoints(
      .init(
        source: Source(name: sourceURL.lastPathComponent, path: sourceURL.path),
        breakpoints: breakpoints,
        sourceModified: sourceModified
      ))
  }

  func debugThreads() async throws -> [DAPThread] {
    try await requireDebugClient().threads()
  }

  func setFunctionBreakpoints(_ breakpoints: [FunctionBreakpoint]) async throws -> [Breakpoint] {
    try await requireDebugClient().setFunctionBreakpoints(breakpoints)
  }

  func setExceptionBreakpoints(_ filters: [String]) async throws {
    try await requireDebugClient().setExceptionBreakpoints(filters)
  }

  func stackTrace(threadID: Int, startFrame: Int?, levels: Int?) async throws
    -> StackTraceResponseBody
  {
    try await requireDebugClient().stackTrace(
      threadId: threadID, startFrame: startFrame, levels: levels)
  }

  func scopes(frameID: Int) async throws -> [Scope] {
    try await requireDebugClient().scopes(frameId: frameID)
  }

  func variables(reference: Int, filter: String?, start: Int?, count: Int?) async throws
    -> [Variable]
  {
    try await requireDebugClient().variables(
      reference: reference, filter: filter, start: start, count: count)
  }

  func evaluate(_ expression: String, frameID: Int?, context: String?) async throws
    -> EvaluateResponseBody
  {
    try await requireDebugClient().evaluate(expression, frameId: frameID, context: context)
  }

  func setVariable(reference: Int, name: String, value: String) async throws
    -> SetVariableResponseBody
  {
    try await requireDebugClient().setVariable(reference: reference, name: name, value: value)
  }

  func exceptionInfo(threadID: Int) async throws -> ExceptionInfoResponseBody {
    try await requireDebugClient().exceptionInfo(threadId: threadID)
  }

  func debugSource(reference: Int, source: Source?) async throws -> SourceResponseBody {
    try await requireDebugClient().source(reference: reference, source: source)
  }

  func debugModules(start: Int?, count: Int?) async throws -> ModulesResponseBody {
    try await requireDebugClient().modules(start: start, count: count)
  }

  func loadedDebugSources() async throws -> [Source] {
    try await requireDebugClient().loadedSources()
  }

  func continueExecution(threadID: Int, singleThread: Bool?) async throws -> ContinueResponseBody {
    try await requireDebugClient().continueExecution(threadId: threadID, singleThread: singleThread)
  }

  func pause(threadID: Int) async throws {
    try await requireDebugClient().pause(threadId: threadID)
  }

  func stepOver(threadID: Int, singleThread: Bool?) async throws {
    try await requireDebugClient().next(threadId: threadID, singleThread: singleThread)
  }

  func stepIn(threadID: Int, singleThread: Bool?) async throws {
    try await requireDebugClient().stepIn(threadId: threadID, singleThread: singleThread)
  }

  func stepOut(threadID: Int, singleThread: Bool?) async throws {
    try await requireDebugClient().stepOut(threadId: threadID, singleThread: singleThread)
  }

  func stepBack(threadID: Int, singleThread: Bool?) async throws {
    try await requireDebugClient().stepBack(threadId: threadID, singleThread: singleThread)
  }

  func reverseContinue(threadID: Int, singleThread: Bool?) async throws {
    try await requireDebugClient().reverseContinue(threadId: threadID, singleThread: singleThread)
  }

  func restartFrame(_ frameID: Int) async throws {
    try await requireDebugClient().restartFrame(frameID)
  }

  func restartDebugger(arguments: DAPValue) async throws {
    try await requireDebugClient().restart(arguments)
  }

  func terminateDebugger() async throws {
    try await requireDebugClient().terminate()
  }

  func rawDebugRequest(command: String, arguments: DAPValue?) async throws -> DAPResponse {
    try await requireDebugClient().rawRequest(command: command, arguments: arguments)
  }

  func disconnectDebugger(arguments: DisconnectArguments) async throws {
    let client = try requireDebugClient()
    do {
      try await client.disconnect(arguments)
    } catch {
      clearDebuggerState()
      throw error
    }
    clearDebuggerState()
  }

  func shutdown() async throws {
    switch lifecycle {
    case .active:
      lifecycle = .shuttingDown
    case .shuttingDown:
      try await withCheckedThrowingContinuation { continuation in
        shutdownWaiters.append(continuation)
      }
      return
    case .shutDown:
      if case .failure(let error) = shutdownResult { throw error }
      return
    }

    stopSourceWorkspaceMonitoring()
    var firstError: (any Error)?
    do { try await closeAllDocuments() } catch { firstError = error }
    if let client = debugClient {
      do { try await client.disconnect() } catch { if firstError == nil { firstError = error } }
      clearDebuggerState()
    }
    do { try await languageServerShutdown() } catch { if firstError == nil { firstError = error } }
    debugEventContinuation.finish()
    debugEventEnvelopeContinuation.finish()
    debugStandardErrorContinuation.finish()
    debugStandardErrorEnvelopeContinuation.finish()
    debugTransportErrorContinuation.finish()
    debugTransportErrorEnvelopeContinuation.finish()
    await diagnosticBroadcaster.finish()

    let result: Result<Void, any Error> = firstError.map(Result.failure) ?? .success(())
    shutdownResult = result
    lifecycle = .shutDown
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll()
    for waiter in waiters {
      switch result {
      case .success:
        waiter.resume()
      case .failure(let error):
        waiter.resume(throwing: error)
      }
    }
    try result.get()
  }

  private func synchronizeAllOpenDocuments() async throws {
    for (uri, document) in documents {
      _ = try await sourceWorkspace.synchronizeOpenDocument(
        at: uri,
        snapshot: await document.snapshot,
        languageID: await document.languageID
      )
    }
  }

  private func detachDebugObservers() {
    debugEventTask?.cancel()
    debugStandardErrorTask?.cancel()
    debugTransportErrorTask?.cancel()
    debugTerminationTask?.cancel()
    debugEventTask = nil
    debugStandardErrorTask = nil
    debugTransportErrorTask = nil
    debugTerminationTask = nil
  }

  private func clearDebuggerState() {
    detachDebugObservers()
    debugConnection?.terminate()
    debugConnection = nil
    debugClient = nil
  }

  private func ensureActive() throws {
    guard case .active = lifecycle else { throw SwiftEditorBackendError.shutdown }
  }

  private func requireDocument(_ uri: URL) async throws -> EditorDocument {
    try ensureActive()
    let key = documentKey(uri)
    if let opening = openingDocuments[key] { try await opening.wait() }
    guard let document = documents[key] else { throw SwiftEditorBackendError.documentNotOpen(key) }
    return document
  }

  private func documentKey(_ uri: URL) -> URL {
    uri.isFileURL ? uri.standardizedFileURL : uri
  }

  private func requireDebugClient() throws -> DAPClient {
    try ensureActive()
    guard let debugClient else { throw SwiftEditorBackendError.debuggerNotRunning }
    return debugClient
  }

  private func identifierPrefix(in snapshot: TextSnapshot, at position: TextPosition) throws
    -> String
  {
    let range = try CompletionUtilities.inferredIdentifierRange(in: snapshot, endingAt: position)
    return try snapshot.substring(in: range)
  }
}
