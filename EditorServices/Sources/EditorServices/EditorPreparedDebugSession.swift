import EditorDAP
import Foundation

public enum EditorPreparedDebugSessionError: LocalizedError, Sendable {
  case consumed

  public var errorDescription: String? {
    switch self {
    case .consumed: return "The prepared debug session has already been activated or discarded."
    }
  }
}

public actor EditorPreparedDebugSession {
  private var client: DAPClient?
  private var connection: DAPProcessConnection?

  init(client: DAPClient, connection: DAPProcessConnection) {
    self.client = client
    self.connection = connection
  }

  deinit { connection?.terminate() }

  public var capabilities: Capabilities? {
    get async { await client?.capabilities }
  }

  public func setBreakpoints(
    in sourceURL: URL,
    breakpoints: [SourceBreakpoint],
    sourceModified: Bool? = nil
  ) async throws -> [Breakpoint] {
    try await requireClient().setBreakpoints(
      .init(
        source: Source(name: sourceURL.lastPathComponent, path: sourceURL.path),
        breakpoints: breakpoints,
        sourceModified: sourceModified
      )
    )
  }

  public func launch(arguments: DAPValue) async throws {
    try await requireClient().launch(arguments)
  }

  public func attach(arguments: DAPValue) async throws {
    try await requireClient().attach(arguments)
  }

  public func finishConfiguration() async throws {
    try await requireClient().configurationDone()
  }

  public func discard() async {
    guard let client else { return }
    try? await client.disconnect(
      DisconnectArguments(restart: false, terminateDebuggee: true)
    )
    connection?.terminate()
    self.client = nil
    connection = nil
  }

  func consume() throws -> (DAPClient, DAPProcessConnection) {
    guard let client, let connection else { throw EditorPreparedDebugSessionError.consumed }
    self.client = nil
    self.connection = nil
    return (client, connection)
  }

  private func requireClient() throws -> DAPClient {
    guard let client else { throw EditorPreparedDebugSessionError.consumed }
    return client
  }
}

#if os(macOS) || os(Linux)
  extension EditorServiceBootstrapResult {
    public func prepareDebugger(
      for language: EditorLanguage,
      environment: [String: String]? = ProcessInfo.processInfo.environment,
      initializeArguments: InitializeArguments? = nil,
      reverseRequestHandler: (any DAPReverseRequestHandler)? = nil
    ) async throws -> EditorPreparedDebugSession {
      guard let adapter = debugAdapter(for: language) else {
        throw EditorDebugAdapterSelectionError.unavailable(language)
      }
      let configuration = adapter.processConfiguration(
        workspaceURL: projectInspection?.workspaceURL ?? backend.workspaceURL,
        environment: environment,
        initializeArguments: initializeArguments
      )
      let connection = try DAPProcessConnection(
        executableURL: configuration.executableURL,
        arguments: configuration.arguments,
        environment: configuration.environment,
        currentDirectoryURL: configuration.currentDirectoryURL ?? backend.workspaceURL
      )
      let client = DAPClient(
        session: connection.session,
        reverseRequestHandler: reverseRequestHandler
      )
      do {
        _ = try await client.initialize(configuration.initializeArguments)
        return EditorPreparedDebugSession(client: client, connection: connection)
      } catch {
        connection.terminate()
        throw error
      }
    }
  }
#endif
