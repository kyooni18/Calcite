import Foundation

#if os(macOS) || os(Linux)
  public enum LLDBDAPResolutionError: Error, Equatable, Sendable {
    case executableNotFound
    case notExecutable(String)
  }

  extension LLDBDAPResolutionError: LocalizedError {
    public var errorDescription: String? {
      switch self {
      case .executableNotFound:
        return "No LLDB Debug Adapter Protocol executable was found."
      case .notExecutable(let path):
        return "The configured LLDB DAP file is not executable: \(path)."
      }
    }

    public var recoverySuggestion: String? {
      switch self {
      case .executableNotFound:
        return "Install lldb-dap with Swift or LLVM, install CodeLLDB, or set LLDB_DAP_PATH."
      case .notExecutable:
        return "Fix the executable permission or configure another debug adapter path."
      }
    }
  }

  public enum LLDBDAPResolver {
    public static func resolve(
      explicitPath: String? = nil,
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
      if let explicitPath {
        return try validateAuthoritativePath(explicitPath)
      }
      if let override = environment["LLDB_DAP_PATH"] ?? environment["LLDB_DAP"] {
        return try validateAuthoritativePath(override)
      }

      var candidates: [String] = []
      for directory in (environment["PATH"] ?? "").split(separator: ":") {
        candidates.append(String(directory) + "/lldb-dap")
        candidates.append(String(directory) + "/codelldb")
      }
      candidates += [
        "/usr/local/swift/usr/bin/lldb-dap",
        "/usr/bin/lldb-dap",
        "/opt/homebrew/bin/lldb-dap",
        "/usr/local/bin/lldb-dap",
      ]
      candidates.append(contentsOf: codeLLDBCandidates())

      #if os(macOS)
        if let xcrunPath = findWithXcrun() { candidates.insert(xcrunPath, at: 0) }
      #endif

      for candidate in candidates {
        if let valid = try? validateExistingCandidate(candidate) { return valid }
      }
      throw LLDBDAPResolutionError.executableNotFound
    }

    private static func validateAuthoritativePath(_ path: String) throws -> String {
      guard FileManager.default.fileExists(atPath: path) else {
        throw LLDBDAPResolutionError.executableNotFound
      }
      return try validateExistingCandidate(path)
    }

    private static func validateExistingCandidate(_ path: String) throws -> String {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        throw LLDBDAPResolutionError.executableNotFound
      }
      guard FileManager.default.isExecutableFile(atPath: path) else {
        throw LLDBDAPResolutionError.notExecutable(path)
      }
      return path
    }

    private static func codeLLDBCandidates() -> [String] {
      let roots = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          ".vscode/extensions"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          ".vscode-insiders/extensions"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          ".cursor/extensions"),
      ]
      var values: [String] = []
      for root in roots {
        guard
          let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
          )
        else { continue }
        for child in children where child.lastPathComponent.hasPrefix("vadimcn.vscode-lldb-") {
          values.append(child.appendingPathComponent("adapter/codelldb").path)
        }
      }
      return values.sorted(by: >)
    }

    #if os(macOS)
      private static func findWithXcrun() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "lldb-dap"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
          let finished = DispatchSemaphore(value: 0)
          process.terminationHandler = { _ in finished.signal() }
          try process.run()
          guard finished.wait(timeout: .now() + 2) == .success else {
            if process.isRunning { process.terminate() }
            _ = finished.wait(timeout: .now() + .milliseconds(250))
            return nil
          }
          guard process.terminationStatus == 0 else { return nil }
          let path = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
          ).trimmingCharacters(in: .whitespacesAndNewlines)
          return path.isEmpty ? nil : path
        } catch {
          if process.isRunning { process.terminate() }
          return nil
        }
      }
    #endif
  }
#endif
