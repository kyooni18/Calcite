import EditorCore
import Foundation
import JSONRPC
import LanguageClient
import LanguageServerProtocol
import ProcessEnv

#if os(macOS) || os(Linux)
  public enum LSPExecutableResolutionError: Error, Equatable, Sendable {
    case emptyCommand
    case executableNotFound(String)
    case notExecutable(String)
  }

  extension LSPExecutableResolutionError: LocalizedError {
    public var errorDescription: String? {
      switch self {
      case .emptyCommand:
        return "The language-server executable command is empty."
      case .executableNotFound(let value):
        return "The language-server executable could not be found: \(value)."
      case .notExecutable(let path):
        return "The language-server file exists but is not executable: \(path)."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .emptyCommand:
        return "Provide an executable path or command name."
      case .executableNotFound:
        return
          "Install the language server, add it to PATH, or provide an absolute executable path."
      case .notExecutable:
        return "Fix the file permissions or select another executable."
      }
    }
  }

  /// Resolves either an absolute executable path or a command available through `PATH`.
  public enum LSPExecutableResolver {
    public static func resolve(
      _ commandOrPath: String,
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
      let value = commandOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { throw LSPExecutableResolutionError.emptyCommand }
      if value.contains("/") { return try validate(value) }

      for directory in (environment["PATH"] ?? "").split(separator: ":") {
        let candidate = String(directory) + "/" + value
        if let path = try? validate(candidate) { return path }
      }
      throw LSPExecutableResolutionError.executableNotFound(value)
    }

    private static func validate(_ path: String) throws -> String {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { throw LSPExecutableResolutionError.executableNotFound(path) }
      guard FileManager.default.isExecutableFile(atPath: path) else {
        throw LSPExecutableResolutionError.notExecutable(path)
      }
      return path
    }
  }

  /// Process and initialization settings for any Language Server Protocol server using stdio.
  public struct LSPProcessConfiguration: Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectoryURL: URL?
    public var initializationOptions: EditorJSONValue?
    public var clientName: String
    public var clientVersion: String?
    public var locale: String?
    public var trace: Tracing

    public init(
      executable: String,
      arguments: [String] = [],
      environment: [String: String] = ProcessInfo.processInfo.environment,
      currentDirectoryURL: URL? = nil,
      initializationOptions: EditorJSONValue? = nil,
      clientName: String = "EditorServices",
      clientVersion: String? = "1.0",
      locale: String? = Locale.current.identifier,
      trace: Tracing = .off
    ) {
      self.executable = executable
      self.arguments = arguments
      self.environment = environment
      self.currentDirectoryURL = currentDirectoryURL
      self.initializationOptions = initializationOptions
      self.clientName = clientName
      self.clientVersion = clientVersion
      self.locale = locale
      self.trace = trace
    }
  }

  /// Standard client capabilities advertised to generic language servers.
  public enum EditorLSPClientCapabilities {
    public static var standard: ClientCapabilities {
      let completionItem = CompletionClientCapabilities.CompletionItem(
        snippetSupport: true,
        commitCharactersSupport: true,
        documentationFormat: [.markdown, .plaintext],
        deprecatedSupport: true,
        preselectSupport: true,
        insertReplaceSupport: true,
        resolveSupport: .init(properties: [
          "documentation", "detail", "additionalTextEdits", "command",
        ]),
        labelDetailsSupport: true
      )
      let text = TextDocumentClientCapabilities(
        synchronization: TextDocumentSyncClientCapabilities(
          dynamicRegistration: true,
          willSave: true,
          willSaveWaitUntil: true,
          didSave: true
        ),
        completion: CompletionClientCapabilities(
          completionItem: completionItem,
          contextSupport: true
        ),
        hover: HoverClientCapabilities(
          dynamicRegistration: true,
          contentFormat: [.markdown, .plaintext]
        ),
        signatureHelp: SignatureHelpClientCapabilities(
          dynamicRegistration: true,
          signatureInformation: .init(
            documentationFormat: [.markdown, .plaintext],
            labelOffsetSupport: true,
            activeParameterSupport: true
          ),
          contextSupport: false
        ),
        documentSymbol: DocumentSymbolClientCapabilities(
          dynamicRegistration: true,
          hierarchicalDocumentSymbolSupport: true,
          labelSupport: true
        ),
        codeAction: CodeActionClientCapabilities(
          dynamicRegistration: true,
          isPreferredSupport: true,
          disabledSupport: true
        ),
        publishDiagnostics: PublishDiagnosticsClientCapabilities(
          relatedInformation: true,
          versionSupport: true,
          codeDescriptionSupport: true
        ),
        semanticTokens: SemanticTokensClientCapabilities(),
        inlayHint: InlayHintClientCapabilities(dynamicRegistration: true)
      )
      return ClientCapabilities(
        workspace: nil,
        textDocument: text,
        window: nil,
        general: nil,
        experimental: nil
      )
    }
  }

  /// Owns a local stdio language-server process and exposes it as ``LSPDocumentService``.
  ///
  /// No server-specific protocol code is used. Any implementation conforming to the Language Server
  /// Protocol over standard input/output can be connected by supplying its executable and arguments.
  public final class LSPProcessConnection: @unchecked Sendable {
    public let transport: LanguageClientServer
    public let service: LSPDocumentService
    public let executablePath: String
    public let processIdentifier: Int32
    public let standardError: AsyncStream<String>

    private let process: Process

    public init(
      workspaceURL: URL,
      configuration: LSPProcessConfiguration,
      workspaceURLs: [URL]? = nil,
      capabilities: ClientCapabilities = EditorLSPClientCapabilities.standard,
      configurationProvider: @escaping LSPDocumentService.ConfigurationProvider = { items in
        Array(repeating: .null, count: items.count)
      },
      workspaceEditHandler: LSPDocumentService.WorkspaceEditHandler? = nil
    ) throws {
      let path = try LSPExecutableResolver.resolve(
        configuration.executable,
        environment: configuration.environment
      )
      let folders = (workspaceURLs ?? [workspaceURL]).map {
        WorkspaceFolder(uri: $0.absoluteString, name: $0.lastPathComponent)
      }
      let parameters = Process.ExecutionParameters(
        path: path,
        arguments: configuration.arguments,
        environment: configuration.environment,
        currentDirectoryURL: configuration.currentDirectoryURL ?? workspaceURL
      )
      let result = try DataChannel.localProcessChannelWithStandardError(
        parameters: parameters,
        terminationHandler: {}
      )
      self.process = result.process
      self.executablePath = path
      self.processIdentifier = result.process.processIdentifier
      self.standardError = result.standardError

      let connection = JSONRPCServerConnection(dataChannel: result.channel)
      let provider: InitializingServer.InitializeParamsProvider = {
        InitializeParams(
          processId: Int(ProcessInfo.processInfo.processIdentifier),
          clientInfo: .init(
            name: configuration.clientName,
            version: configuration.clientVersion
          ),
          locale: configuration.locale,
          rootPath: workspaceURL.path,
          rootUri: workspaceURL.absoluteString,
          initializationOptions: configuration.initializationOptions.map(LSPConversion.lspJSON),
          capabilities: capabilities,
          trace: configuration.trace,
          workspaceFolders: folders
        )
      }
      let initialized = InitializingServer(
        server: connection,
        initializeParamsProvider: provider
      )
      let transport = LanguageClientServer(server: initialized)
      self.transport = transport
      self.service = LSPDocumentService(
        transport: transport,
        workspaceFolders: folders,
        configurationProvider: configurationProvider,
        workspaceEditHandler: workspaceEditHandler
      )
    }

    deinit {
      if process.isRunning { process.terminate() }
    }

    public var isRunning: Bool { process.isRunning }

    public func shutdown() async throws {
      try await shutdown(timeout: .seconds(5))
    }

    public func shutdown(timeout: Duration) async throws {
      do {
        try await service.shutdown(timeout: timeout)
      } catch {
        if process.isRunning { process.terminate() }
        throw error
      }
      if process.isRunning { process.terminate() }
    }

    public func terminate() {
      if process.isRunning { process.terminate() }
    }
  }
#endif
