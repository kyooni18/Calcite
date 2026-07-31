#if os(macOS)
  import AppKit
  import Darwin
  import EditorServices
  import Foundation

  final class EditorDAPReverseRequestHost: DAPReverseRequestHandler, @unchecked Sendable {
    private actor State {
      var activeTerminalSessionID: UUID?

      func replaceSessionID(_ value: UUID?) -> UUID? {
        let old = activeTerminalSessionID
        activeTerminalSessionID = value
        return old
      }
    }

    private struct ExternalTerminalLaunch: Sendable {
      let sessionID: UUID
      let shellProcessID: Int?
      let scriptURL: URL
      let pidURL: URL
    }

    private let workspaceURL: URL
    private let state = State()

    init(workspaceURL: URL) {
      self.workspaceURL = workspaceURL.standardizedFileURL
    }

    func handleReverseRequest(_ request: DAPRequest) async -> DAPReverseRequestResponse {
      switch request.command {
      case "runInTerminal":
        return await handleRunInTerminal(request)
      case "startDebugging":
        return .failed("Nested debug sessions are not supported by this Calcite session.")
      default:
        return .failed("Unsupported DAP reverse request: \(request.command)")
      }
    }

    func terminateActiveTerminalProcess() async {
      guard let sessionID = await state.replaceSessionID(nil) else { return }
      await EditorProcessRegistry.shared.terminate(
        owner: .terminal(workspacePath: workspaceURL.path, sessionID: sessionID)
      )
    }

    private func handleRunInTerminal(_ request: DAPRequest) async -> DAPReverseRequestResponse {
      do {
        let arguments = try (request.arguments ?? .object([:])).decode(
          RunInTerminalArguments.self)
        guard !arguments.args.isEmpty else {
          return .failed("runInTerminal did not provide a command.")
        }
        let command = Self.commandLine(for: arguments)
        switch arguments.kind ?? .integrated {
        case .integrated:
          return try await launchIntegratedTerminal(command: command, arguments: arguments)
        case .external:
          return try await launchExternalTerminal(command: command, arguments: arguments)
        }
      } catch {
        return .failed("runInTerminal failed: \(error.localizedDescription)")
      }
    }

    private func launchIntegratedTerminal(
      command: String,
      arguments: RunInTerminalArguments
    ) async throws -> DAPReverseRequestResponse {
      let sessionID = UUID()
      if let previous = await state.replaceSessionID(sessionID) {
        await EditorProcessRegistry.shared.terminate(
          owner: .terminal(workspacePath: workspaceURL.path, sessionID: previous)
        )
      }
      let session = await MainActor.run {
        EditorTerminalSessionRegistry.shared.createDebugSession(
          workspaceURL: workspaceURL,
          id: sessionID,
          command: command,
          title: arguments.title
        )
      }
      let shellPID = await session.shellProcessIdentifier()
      await EditorProcessRegistry.shared.register(
        owner: .terminal(workspacePath: workspaceURL.path, sessionID: sessionID)
      ) { [weak session] in
        await MainActor.run {
          session?.interruptForegroundProcess()
          EditorTerminalSessionRegistry.shared.removeDebugSession(id: sessionID)
        }
      }
      return .succeeded(
        body: try DAPValue.encode(
          RunInTerminalResponseBody(
            processId: nil,
            shellProcessId: shellPID
          )
        )
      )
    }

    private func launchExternalTerminal(
      command: String,
      arguments: RunInTerminalArguments
    ) async throws -> DAPReverseRequestResponse {
      let sessionID = UUID()
      if let previous = await state.replaceSessionID(sessionID) {
        await EditorProcessRegistry.shared.terminate(
          owner: .terminal(workspacePath: workspaceURL.path, sessionID: previous)
        )
      }
      let launch = try await Self.createAndOpenExternalTerminal(
        sessionID: sessionID,
        command: command,
        title: arguments.title,
        workspaceURL: workspaceURL
      )
      let processLease = await EditorProcessRegistry.shared.register(
        owner: .terminal(workspacePath: workspaceURL.path, sessionID: sessionID)
      ) {
        if let pid = launch.shellProcessID { await Self.terminateProcessTree(pid_t(pid)) }
        try? FileManager.default.removeItem(at: launch.scriptURL)
        try? FileManager.default.removeItem(at: launch.pidURL)
      }
      Task.detached(priority: .utility) {
        var observedPID = launch.shellProcessID
        let discoveryDeadline = ContinuousClock.now + .seconds(10)
        while observedPID == nil, ContinuousClock.now < discoveryDeadline {
          if let value = try? String(contentsOf: launch.pidURL, encoding: .utf8),
            let pid = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
          {
            observedPID = pid
            break
          }
          if !FileManager.default.fileExists(atPath: launch.scriptURL.path) { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        if let observedPID {
          while Self.processExists(pid_t(observedPID)) {
            try? await Task.sleep(for: .milliseconds(250))
          }
        } else {
          while FileManager.default.fileExists(atPath: launch.scriptURL.path) {
            try? await Task.sleep(for: .milliseconds(250))
          }
        }
        await EditorProcessRegistry.shared.unregister(processLease)
        try? FileManager.default.removeItem(at: launch.scriptURL)
        try? FileManager.default.removeItem(at: launch.pidURL)
      }
      return .succeeded(
        body: try DAPValue.encode(
          RunInTerminalResponseBody(
            processId: nil,
            shellProcessId: launch.shellProcessID
          )
        )
      )
    }

    private static func commandLine(for arguments: RunInTerminalArguments) -> String {
      let cwd = arguments.cwd.isEmpty ? nil : arguments.cwd
      var components: [String] = []
      if let cwd {
        components.append("cd -- \(shellQuote(cwd))")
      }
      let environment = (arguments.env ?? [:]).keys.sorted().compactMap { key -> String? in
        guard let value = arguments.env?[key] else { return nil }
        return "\(shellQuote(key))=\(shellQuote(value))"
      }
      let invocation: String
      if arguments.argsCanBeInterpretedByShell == true {
        invocation = arguments.args.joined(separator: " ")
      } else {
        invocation = arguments.args.map(shellQuote).joined(separator: " ")
      }
      let launched =
        environment.isEmpty
        ? invocation
        : "env \(environment.joined(separator: " ")) \(invocation)"
      components.append(launched)
      return components.joined(separator: " && ")
    }

    private static func shellQuote(_ value: String) -> String {
      guard !value.isEmpty else { return "''" }
      return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func createAndOpenExternalTerminal(
      sessionID: UUID,
      command: String,
      title: String?,
      workspaceURL: URL
    ) async throws -> ExternalTerminalLaunch {
      let cacheRoot = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first!
      .appendingPathComponent("Calcite", isDirectory: true)
      .appendingPathComponent("DebugTerminals", isDirectory: true)
      try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
      let script = cacheRoot.appendingPathComponent(sessionID.uuidString + ".command")
      let pidURL = cacheRoot.appendingPathComponent(sessionID.uuidString + ".pid")
      let titleLine = title.map { "printf '\\033]0;\(escapeForPrintf($0))\\007'\n" } ?? ""
      let cleanup = "rm -f -- \(shellQuote(script.path)) \(shellQuote(pidURL.path))"
      let contents = """
        #!/bin/zsh
        printf '%d' $$ > \(shellQuote(pidURL.path))
        trap \(shellQuote(cleanup)) EXIT
        cd -- \(shellQuote(workspaceURL.path))
        \(titleLine)\(command)
        status=$?
        printf '\\n[Calcite debug process exited with status %d]\\n' $status
        exit $status
        """
      try contents.write(to: script, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: script.path
      )

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = [script.path]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw NSError(
          domain: "Calcite.DAP.RunInTerminal",
          code: Int(process.terminationStatus),
          userInfo: [NSLocalizedDescriptionKey: "The external terminal could not be opened."]
        )
      }

      let deadline = ContinuousClock.now + .seconds(2)
      var shellPID: Int?
      while ContinuousClock.now < deadline {
        if let value = try? String(contentsOf: pidURL, encoding: .utf8),
          let pid = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        {
          shellPID = pid
          break
        }
        try? await Task.sleep(for: .milliseconds(30))
      }
      return ExternalTerminalLaunch(
        sessionID: sessionID,
        shellProcessID: shellPID,
        scriptURL: script,
        pidURL: pidURL
      )
    }

    private static func processExists(_ pid: pid_t) -> Bool {
      guard pid > 0 else { return false }
      if Darwin.kill(pid, 0) == 0 { return true }
      return errno == EPERM
    }

    private static func terminateProcessTree(_ pid: pid_t) async {
      guard pid > 0, processExists(pid) else { return }
      signalProcessTree(pid, signal: SIGINT)
      try? await Task.sleep(for: .milliseconds(100))
      guard processExists(pid) else { return }
      signalProcessTree(pid, signal: SIGTERM)
      try? await Task.sleep(for: .milliseconds(250))
      guard processExists(pid) else { return }
      signalProcessTree(pid, signal: SIGKILL)
    }

    private static func signalProcessTree(_ pid: pid_t, signal: Int32) {
      // Terminal.app does not guarantee that the script shell is a process-group leader. Signal
      // both its process group and the recursively discovered child processes so a debugger stop
      // cannot leave the launched program behind.
      _ = Darwin.kill(-pid, signal)
      for child in descendantProcessIDs(of: pid).reversed() {
        _ = Darwin.kill(child, signal)
      }
      _ = Darwin.kill(pid, signal)
    }

    private static func descendantProcessIDs(of parent: pid_t) -> [pid_t] {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
      process.arguments = ["-P", String(parent)]
      process.standardOutput = pipe
      process.standardError = Pipe()
      guard (try? process.run()) != nil else { return [] }
      process.waitUntilExit()
      let output = String(
        decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      )
      let direct = output.split(whereSeparator: \.isNewline).compactMap {
        pid_t(String($0))
      }
      return direct + direct.flatMap(descendantProcessIDs)
    }

    private static func escapeForPrintf(_ value: String) -> String {
      value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "'\\''")
        .replacingOccurrences(of: "%", with: "%%")
    }
  }
#endif
