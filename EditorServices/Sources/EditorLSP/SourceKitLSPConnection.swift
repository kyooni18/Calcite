import EditorCore
import Foundation
import JSONRPC
import LanguageClient
import LanguageServerProtocol
import ProcessEnv

#if os(macOS) || os(Linux)
  public enum SourceKitLSPResolutionError: Error, Equatable, Sendable {
    case executableNotFound
    case notExecutable(String)
  }

  public enum SourceKitLSPResolver {
    public static func resolve(
      explicitPath: String? = nil,
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
      if let explicitPath { return try validateAuthoritativePath(explicitPath) }
      if let override = environment["SOURCEKIT_LSP_PATH"] ?? environment["SOURCEKIT_LSP"] {
        return try validateAuthoritativePath(override)
      }

      var candidates: [String] = []
      for directory in (environment["PATH"] ?? "").split(separator: ":") {
        candidates.append(String(directory) + "/sourcekit-lsp")
      }
      candidates += ["/usr/local/swift/usr/bin/sourcekit-lsp", "/usr/bin/sourcekit-lsp"]
      #if os(macOS)
        if let xcrunPath = findWithXcrun() { candidates.append(xcrunPath) }
      #endif

      for candidate in candidates {
        if let valid = try? validateExistingCandidate(candidate) { return valid }
      }
      throw SourceKitLSPResolutionError.executableNotFound
    }

    private static func validateAuthoritativePath(_ path: String) throws -> String {
      guard FileManager.default.fileExists(atPath: path) else {
        throw SourceKitLSPResolutionError.executableNotFound
      }
      return try validateExistingCandidate(path)
    }

    private static func validateExistingCandidate(_ path: String) throws -> String {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        throw SourceKitLSPResolutionError.executableNotFound
      }
      guard FileManager.default.isExecutableFile(atPath: path) else {
        throw SourceKitLSPResolutionError.notExecutable(path)
      }
      return path
    }

    #if os(macOS)
      private static func findWithXcrun() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "sourcekit-lsp"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
          let finished = DispatchSemaphore(value: 0)
          process.terminationHandler = { _ in finished.signal() }
          try process.run()
          guard finished.wait(timeout: .now() + 2) == .success else {
            LSPProcessLifecycle.terminate(process)
            _ = finished.wait(timeout: .now() + .milliseconds(250))
            return nil
          }
          guard process.terminationStatus == 0 else { return nil }
          let value = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
          ).trimmingCharacters(in: .whitespacesAndNewlines)
          return value.isEmpty ? nil : value
        } catch {
          LSPProcessLifecycle.terminate(process)
          return nil
        }
      }
    #endif
  }

  public final class SourceKitLSPConnection: @unchecked Sendable {
    public let transport: LanguageClientServer
    public let service: LSPDocumentService
    public let standardError: AsyncStream<String>
    public let terminationEvents: AsyncStream<LSPProcessTermination>
    private let process: Process
    private let terminationRelay: LSPProcessTerminationRelay

    public init(
      workspaceURL: URL,
      executablePath: String? = nil,
      environment: [String: String] = ProcessInfo.processInfo.environment,
      configurationProvider: @escaping LSPDocumentService.ConfigurationProvider = { items in
        Array(repeating: .null, count: items.count)
      },
      workspaceEditHandler: LSPDocumentService.WorkspaceEditHandler? = nil
    ) throws {
      let path = try SourceKitLSPResolver.resolve(
        explicitPath: executablePath, environment: environment)
      let parameters = Process.ExecutionParameters(
        path: path, environment: environment, currentDirectoryURL: workspaceURL)
      let terminationRelay = LSPProcessTerminationRelay()
      let result = try DataChannel.localProcessChannelWithStandardError(
        parameters: parameters,
        terminationHandler: { terminationRelay.processDidTerminate() }
      )
      terminationRelay.attach(result.process)
      self.terminationRelay = terminationRelay
      self.terminationEvents = terminationRelay.events
      self.process = result.process
      self.standardError = result.standardError
      let connection = JSONRPCServerConnection(dataChannel: result.channel)
      let workspace = WorkspaceFolder(
        uri: workspaceURL.absoluteString, name: workspaceURL.lastPathComponent)
      let provider: InitializingServer.InitializeParamsProvider = {
        let completionItem = CompletionClientCapabilities.CompletionItem(
          snippetSupport: true, commitCharactersSupport: true,
          documentationFormat: [.markdown, .plaintext], deprecatedSupport: true,
          preselectSupport: true, insertReplaceSupport: true,
          resolveSupport: .init(properties: [
            "documentation", "detail", "additionalTextEdits", "command",
          ]),
          labelDetailsSupport: true
        )
        let text = TextDocumentClientCapabilities(
          synchronization: TextDocumentSyncClientCapabilities(
            dynamicRegistration: true, willSave: true, willSaveWaitUntil: true, didSave: true),
          completion: CompletionClientCapabilities(
            completionItem: completionItem, contextSupport: true),
          hover: HoverClientCapabilities(
            dynamicRegistration: true, contentFormat: [.markdown, .plaintext]),
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
            relatedInformation: true, versionSupport: true, codeDescriptionSupport: true),
          semanticTokens: SemanticTokensClientCapabilities(),
          inlayHint: InlayHintClientCapabilities(dynamicRegistration: true)
        )
        let capabilities = ClientCapabilities(
          workspace: nil, textDocument: text, window: nil, general: nil, experimental: nil)
        return InitializeParams(
          processId: Int(ProcessInfo.processInfo.processIdentifier),
          clientInfo: .init(name: "EditorServices", version: "1.0"),
          locale: Locale.current.identifier,
          rootPath: workspaceURL.path, rootUri: workspaceURL.absoluteString,
          initializationOptions: nil, capabilities: capabilities, trace: .off,
          workspaceFolders: [workspace]
        )
      }
      let initialized = InitializingServer(server: connection, initializeParamsProvider: provider)
      let transport = LanguageClientServer(server: initialized)
      self.transport = transport
      self.service = LSPDocumentService(
        transport: transport,
        workspaceFolders: [workspace],
        configurationProvider: configurationProvider,
        workspaceEditHandler: workspaceEditHandler
      )
    }

    deinit {
      terminationRelay.markExpected()
      LSPProcessLifecycle.terminate(process)
    }

    public func shutdown() async throws {
      try await shutdown(timeout: .seconds(5))
    }

    public func shutdown(timeout: Duration) async throws {
      terminationRelay.markExpected()
      do {
        try await service.shutdown(timeout: timeout)
      } catch {
        LSPProcessLifecycle.terminate(process)
        throw error
      }
      LSPProcessLifecycle.terminate(process)
    }

    public func terminate() {
      terminationRelay.markExpected()
      LSPProcessLifecycle.terminate(process)
    }
  }
#endif
