import EditorDAP
import Foundation

public enum EditorDebugAdapterSelectionError: Error, Hashable, Sendable {
  case unavailable(EditorLanguage)
}

extension EditorDebugAdapterSelectionError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .unavailable(let language):
      return "No available debug adapter was discovered for \(language.displayName)."
    }
  }

  public var recoverySuggestion: String? {
    "Install a supported adapter or provide a manual debugAdapterExecutables override."
  }
}

#if os(macOS) || os(Linux)
  extension EditorDebugAdapterConfiguration {
    public var defaultAdapterID: String {
      switch id {
      case "lldb-dap": return "lldb"
      case "delve": return "go"
      case "debugpy": return "python"
      case "netcoredbg": return "coreclr"
      case "dart-debug-adapter": return "dart"
      default: return id
      }
    }

    public func processConfiguration(
      workspaceURL: URL,
      environment: [String: String]? = ProcessInfo.processInfo.environment,
      initializeArguments: InitializeArguments? = nil
    ) -> DebugAdapterProcessConfiguration {
      .init(
        executableURL: URL(fileURLWithPath: executable),
        arguments: arguments,
        environment: environment,
        currentDirectoryURL: workspaceURL,
        initializeArguments: initializeArguments
          ?? .init(
            adapterID: defaultAdapterID,
            clientID: "EditorServices",
            clientName: "EditorServices"
          )
      )
    }
  }

  extension EditorServiceBootstrapResult {
    /// Starts the adapter selected during project inspection for the requested language.
    @discardableResult
    public func startDebugger(
      for language: EditorLanguage,
      environment: [String: String]? = ProcessInfo.processInfo.environment,
      initializeArguments: InitializeArguments? = nil
    ) async throws -> Capabilities {
      try await startDebugger(
        for: language,
        environment: environment,
        initializeArguments: initializeArguments,
        reverseRequestHandler: nil
      )
    }

    /// Starts the selected adapter with a host for adapter reverse requests.
    @discardableResult
    public func startDebugger(
      for language: EditorLanguage,
      environment: [String: String]? = ProcessInfo.processInfo.environment,
      initializeArguments: InitializeArguments? = nil,
      reverseRequestHandler: (any DAPReverseRequestHandler)?
    ) async throws -> Capabilities {
      guard let adapter = debugAdapter(for: language) else {
        throw EditorDebugAdapterSelectionError.unavailable(language)
      }
      return try await backend.startDebugger(
        process: adapter.processConfiguration(
          workspaceURL: projectInspection?.workspaceURL ?? backend.workspaceURL,
          environment: environment,
          initializeArguments: initializeArguments
        ),
        reverseRequestHandler: reverseRequestHandler
      )
    }
  }
#endif
