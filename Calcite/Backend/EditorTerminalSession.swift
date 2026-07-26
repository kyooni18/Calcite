#if os(macOS)
  import AppKit
  import Combine
  import Darwin
  import EditorServices
  import Foundation

  @MainActor
  final class EditorTerminalSession: ObservableObject {
    let workspaceURL: URL
    let shellPath: String
    private let initialCommand: String?
    private let monitorsPythonEnvironment: Bool

    @Published private(set) var output = ""
    @Published private(set) var outputEpoch: UInt64 = 0
    @Published private(set) var renderedSnapshot = TerminalRenderedSnapshot(
      text: "", styleSpans: [])
    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var exitDescription: String?
    @Published private(set) var pythonEnvironment: EditorPythonEnvironment?

    private let worker: EditorTerminalWorker
    private var eventTask: Task<Void, Never>?
    private var environmentMonitorTask: Task<Void, Never>?
    private var environmentRefreshTask: Task<Void, Never>?
    private var pendingOutput = ""
    private var pendingOutputUTF8Count = 0
    private var outputUTF8Count = 0
    private var outputFlushTask: Task<Void, Never>?
    private var terminalDecoder = TerminalANSITextDecoder()
    private var terminalQueryBuffer = ""
    private var terminalSize = (columns: 100, rows: 32)
    private var visibleGeneration: UInt64 = 0
    private var startRequested = false
    private var attachedViewCount = 0

    init(
      workspaceURL: URL,
      initialCommand: String? = nil,
      monitorsPythonEnvironment: Bool = true
    ) {
      let workspaceURL = workspaceURL.standardizedFileURL
      let shellPath = Self.defaultShellPath()
      let eventChannel = AsyncStream<EditorTerminalEvent>.makeStream(
        bufferingPolicy: .bufferingNewest(4_096)
      )

      self.workspaceURL = workspaceURL
      self.shellPath = shellPath
      self.initialCommand = initialCommand
      self.monitorsPythonEnvironment = monitorsPythonEnvironment
      let pythonSelection = Self.pythonSelection(for: workspaceURL)
      self.pythonEnvironment =
        monitorsPythonEnvironment
        ? EditorPythonEnvironmentResolver.detect(
          workspaceURL: pythonSelection.workspaceURL,
          explicitInterpreterURL: pythonSelection.interpreterURL
        )
        : nil
      self.worker = EditorTerminalWorker(
        workspaceURL: workspaceURL,
        shellPath: shellPath,
        events: eventChannel.continuation
      )
      self.eventTask = Task { [weak self] in
        for await event in eventChannel.stream {
          guard let self, !Task.isCancelled else { return }
          self.consume(event)
        }
      }
    }

    isolated deinit {
      eventTask?.cancel()
      environmentMonitorTask?.cancel()
      environmentRefreshTask?.cancel()
      outputFlushTask?.cancel()
      let worker = worker
      Task.detached(priority: .utility) {
        await worker.shutdown()
      }
    }

    func start() {
      startIfNeeded()
    }

    func startIfNeeded() {
      guard !startRequested, !isRunning, !isStopping else { return }
      startRequested = true
      refreshEnvironment()
      let worker = worker
      Task { await worker.start() }
    }

    /// Reconnects a newly mounted terminal view without restarting the shell.
    func reattachView() {
      attachedViewCount += 1
      startEnvironmentMonitoringIfNeeded()
      // Force a full render from the session-owned terminal screen. The PTY and
      // ANSI state stay alive independently of the SwiftUI panel lifecycle.
      outputEpoch &+= 1
      renderedSnapshot = terminalDecoder.renderedSnapshot
      start()
    }

    func detachView() {
      attachedViewCount = max(0, attachedViewCount - 1)
      guard attachedViewCount == 0 else { return }
      environmentMonitorTask?.cancel()
      environmentMonitorTask = nil
    }

    private func startEnvironmentMonitoringIfNeeded() {
      guard monitorsPythonEnvironment, attachedViewCount > 0, environmentMonitorTask == nil else {
        return
      }
      environmentMonitorTask = Task { [weak self] in
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: .seconds(5))
          } catch {
            return
          }
          guard let self, self.attachedViewCount > 0, !Task.isCancelled else { return }
          self.refreshEnvironment(restartIfChanged: true)
        }
      }
    }

    func restart() {
      refreshEnvironment()
      let worker = worker
      Task { await worker.restart() }
    }

    func refreshEnvironment(restartIfChanged: Bool = false) {
      guard monitorsPythonEnvironment else { return }
      guard environmentRefreshTask == nil else { return }
      let workspaceURL = workspaceURL
      environmentRefreshTask = Task { [weak self] in
        let detected = await Task.detached(priority: .utility) {
          let selection = Self.pythonSelection(for: workspaceURL)
          return EditorPythonEnvironmentResolver.detect(
            workspaceURL: selection.workspaceURL,
            explicitInterpreterURL: selection.interpreterURL
          )
        }.value
        guard let self, !Task.isCancelled else { return }
        self.environmentRefreshTask = nil

        let previous = self.pythonEnvironment
        self.pythonEnvironment = detected
        guard restartIfChanged, previous != detected, self.isRunning, !self.isStopping else {
          return
        }
        // A venv can appear while the terminal is already in use (for example after
        // `python -m venv .venv`). Restarting the PTY here kills the command that created
        // the environment and loses the user's shell state. Activate it in the existing
        // shell instead.
        let activation = EditorPythonEnvironmentResolver.shellActivationCommand(
          for: detected,
          shellPath: self.shellPath
        )
        let worker = self.worker
        Task { await worker.send(activation) }
      }
    }

    func stop() {
      let worker = worker
      Task { await worker.stop() }
    }

    func send(_ value: String) {
      guard !value.isEmpty else { return }
      let worker = worker
      Task { await worker.send(value) }
    }

    func resize(columns: Int, rows: Int) {
      let next = (columns: max(2, columns), rows: max(2, rows))
      if terminalSize != next {
        terminalSize = next
        terminalDecoder.resize(columns: next.columns, rows: next.rows)
        renderedSnapshot = terminalDecoder.renderedSnapshot
      }
      let worker = worker
      Task {
        await worker.resize(columns: next.columns, rows: next.rows)
      }
    }

    func clear() {
      outputFlushTask?.cancel()
      outputFlushTask = nil
      pendingOutput = ""
      pendingOutputUTF8Count = 0
      outputEpoch &+= 1
      output = ""
      outputUTF8Count = 0
      terminalDecoder.reset(columns: terminalSize.columns, rows: terminalSize.rows)
      renderedSnapshot = terminalDecoder.renderedSnapshot
    }

    func openExternalTerminal() {
      if EditorExternalTerminalPreferences.application == .custom {
        guard
          let command = EditorExternalTerminalPreferences.expandedCustomCommand(
            for: workspaceURL)
        else {
          exitDescription = "Set a custom external terminal command in Settings."
          return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        do {
          try process.run()
          exitDescription = nil
        } catch {
          exitDescription = "Could not run terminal command: \(error.localizedDescription)"
        }
        return
      }

      guard let terminalURL = EditorExternalTerminalPreferences.resolvedApplicationURL() else {
        exitDescription = "The selected terminal application is not installed."
        return
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.open(
        [workspaceURL],
        withApplicationAt: terminalURL,
        configuration: configuration
      ) { [weak self] _, error in
        Task { @MainActor [weak self] in
          if let error {
            self?.exitDescription = "Could not open terminal: \(error.localizedDescription)"
          } else {
            self?.exitDescription = nil
          }
        }
      }
    }

    private func consume(_ event: EditorTerminalEvent) {
      switch event {
      case .starting(let generation):
        startRequested = true
        visibleGeneration = generation
        isRunning = false
        isStopping = false
        exitDescription = "Starting"

      case .started(let generation):
        guard generation >= visibleGeneration else { return }
        startRequested = false
        refreshEnvironment()
        visibleGeneration = generation
        outputFlushTask?.cancel()
        outputFlushTask = nil
        pendingOutput = ""
        pendingOutputUTF8Count = 0
        outputEpoch &+= 1
        output = ""
        outputUTF8Count = 0
        terminalQueryBuffer = ""
        terminalDecoder.reset(columns: terminalSize.columns, rows: terminalSize.rows)
        renderedSnapshot = terminalDecoder.renderedSnapshot
        isRunning = true
        isStopping = false
        exitDescription = nil
        if let initialCommand {
          let worker = worker
          Task { await worker.send(initialCommand + "\r") }
        }

      case .stopping(let generation, let restarting):
        guard generation == visibleGeneration else { return }
        startRequested = restarting
        isRunning = false
        isStopping = true
        exitDescription = restarting ? "Restarting" : "Stopping"
        flushPendingOutput()

      case .output(let value, let generation):
        guard generation == visibleGeneration else { return }
        respondToTerminalQueries(in: value)
        enqueueOutput(value)

      case .finished(let generation, let description, let restarting):
        guard generation == visibleGeneration else { return }
        startRequested = restarting
        flushPendingOutput()
        isRunning = false
        isStopping = restarting
        exitDescription = description

      case .failed(let generation, let message):
        guard generation >= visibleGeneration else { return }
        startRequested = false
        visibleGeneration = generation
        flushPendingOutput()
        isRunning = false
        isStopping = false
        exitDescription = message
      }
    }

    /// Respond to the small set of terminal identity queries that interactive editors use
    /// during startup. In particular, Neovim asks OSC 11 for the background color; leaving
    /// that unanswered delays startup and produces an on-screen E1568 warning.
    private func respondToTerminalQueries(in output: String) {
      terminalQueryBuffer += output

      let backgroundQueries = [
        "\u{1b}]11;?\u{7}",
        "\u{1b}]11;?\u{1b}\\",
      ]
      let backgroundResponse = "\u{1b}]11;rgb:1c1c/1d1d/2323\u{7}"
      for query in backgroundQueries where terminalQueryBuffer.contains(query) {
        let worker = worker
        Task { await worker.send(backgroundResponse) }
        terminalQueryBuffer = terminalQueryBuffer.replacingOccurrences(of: query, with: "")
      }

      // Device-status reports are used as the reply boundary for Neovim's color
      // probe. A normal "terminal OK" response avoids its E1568 startup warning.
      if terminalQueryBuffer.contains("\u{1b}[5n") {
        let worker = worker
        Task { await worker.send("\u{1b}[0n") }
        terminalQueryBuffer = terminalQueryBuffer.replacingOccurrences(
          of: "\u{1b}[5n", with: "")
      }

      // Preserve enough trailing output to recognize a query that arrives across PTY reads.
      if terminalQueryBuffer.utf8.count > 64 {
        terminalQueryBuffer = String(terminalQueryBuffer.suffix(64))
      }
    }

    private func enqueueOutput(_ value: String) {
      pendingOutput += value
      pendingOutputUTF8Count += value.utf8.count
      guard outputFlushTask == nil else { return }
      outputFlushTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(16))
        guard let self, !Task.isCancelled else { return }
        self.outputFlushTask = nil
        self.flushPendingOutput()
      }
    }

    private func flushPendingOutput() {
      guard !pendingOutput.isEmpty else { return }
      let chunk = pendingOutput
      output += chunk
      outputUTF8Count += pendingOutputUTF8Count
      pendingOutput = ""
      pendingOutputUTF8Count = 0

      terminalDecoder.decode(chunk)
      let nextSnapshot = terminalDecoder.renderedSnapshot
      if nextSnapshot != renderedSnapshot {
        renderedSnapshot = nextSnapshot
      }

      if outputUTF8Count > 4_000_000 {
        // Raw output is only a bounded diagnostic transcript now. The terminal
        // screen model is retained separately, so trimming cannot sever an ANSI
        // sequence and corrupt the next view attachment.
        output = BoundedUTF8Text.suffix(of: output, maximumBytes: 3_000_000)
        outputUTF8Count = output.utf8.count
      }
    }

    nonisolated private static func pythonSelection(
      for workspaceURL: URL
    ) -> (workspaceURL: URL, interpreterURL: URL?) {
      let buildProjectURL =
        EditorBuildProjectSelectionStore.load(workspaceURL: workspaceURL) ?? workspaceURL
      return (
        buildProjectURL,
        EditorPythonInterpreterSelectionStore.load(workspaceURL: buildProjectURL)
      )
    }

    private static func defaultShellPath() -> String {
      let configured = ProcessInfo.processInfo.environment["SHELL"]
        .map { NSString(string: $0).expandingTildeInPath }
      if let configured, FileManager.default.isExecutableFile(atPath: configured) {
        return configured
      }
      if let passwordEntry = getpwuid(getuid()),
        let shellPointer = passwordEntry.pointee.pw_shell
      {
        let loginShell = String(cString: shellPointer)
        if FileManager.default.isExecutableFile(atPath: loginShell) { return loginShell }
      }
      for candidate in ["/bin/zsh", "/bin/bash", "/bin/sh"]
      where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
      return "/bin/sh"
    }
  }

  nonisolated private enum EditorTerminalEvent: Sendable {
    case starting(generation: UInt64)
    case started(generation: UInt64)
    case stopping(generation: UInt64, restarting: Bool)
    case output(String, generation: UInt64)
    case finished(generation: UInt64, description: String, restarting: Bool)
    case failed(generation: UInt64, message: String)
  }

  private actor EditorTerminalWorker {
    private let workspaceURL: URL
    private let shellPath: String
    private let events: AsyncStream<EditorTerminalEvent>.Continuation

    private var generation: UInt64 = 0
    private var masterFileDescriptor: Int32 = -1
    private var childPID: pid_t = 0
    private var isStopping = false
    private var restartAfterExit = false
    private var pendingInput = ""
    // View attachment can report a size before the shell process is started or while a
    // previous process is being restarted. Preserve the latest dimensions so the next
    // PTY is created at the correct size instead of briefly falling back to 100×32.
    private var requestedColumns = 100
    private var requestedRows = 32
    private var readTask: Task<Void, Never>?
    private var processMonitorTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(
      workspaceURL: URL,
      shellPath: String,
      events: AsyncStream<EditorTerminalEvent>.Continuation
    ) {
      self.workspaceURL = workspaceURL
      self.shellPath = shellPath
      self.events = events
    }

    func start() {
      guard !isShuttingDown else { return }
      if childPID > 0 { return }
      if isStopping {
        restartAfterExit = true
        return
      }
      launchShell()
    }

    func restart() {
      guard !isShuttingDown else { return }
      pendingInput = ""
      if childPID > 0 || isStopping {
        requestStop(restarting: true)
      } else {
        launchShell()
      }
    }

    func stop() {
      pendingInput = ""
      restartAfterExit = false
      requestStop(restarting: false)
    }

    func send(_ value: String) {
      guard !value.isEmpty, !isShuttingDown else { return }
      guard childPID > 0, masterFileDescriptor >= 0, !isStopping else {
        appendPendingInput(value)
        if isStopping {
          restartAfterExit = true
        } else if childPID == 0 {
          launchShell()
        }
        return
      }
      if !Self.writeAll(Data(value.utf8), to: masterFileDescriptor) {
        appendPendingInput(value)
        requestStop(restarting: true)
      }
    }

    func resize(columns: Int, rows: Int) {
      requestedColumns = max(1, columns)
      requestedRows = max(1, rows)
      guard childPID > 0, masterFileDescriptor >= 0, !isStopping else { return }
      var size = winsize(
        ws_row: UInt16(clamping: requestedRows),
        ws_col: UInt16(clamping: requestedColumns),
        ws_xpixel: 0,
        ws_ypixel: 0
      )
      // On macOS, a successful TIOCSWINSZ delivers SIGWINCH to the PTY's
      // foreground process group. Sending another signal makes shells repaint twice.
      _ = ioctl(masterFileDescriptor, TIOCSWINSZ, &size)
    }

    func shutdown() async {
      guard !isShuttingDown else { return }
      isShuttingDown = true
      restartAfterExit = false
      requestStop(restarting: false)
      if let processMonitorTask { await processMonitorTask.value }
      readTask?.cancel()
      readTask = nil
      closeMasterFileDescriptor()
      events.finish()
    }

    private func launchShell() {
      guard !isShuttingDown, childPID == 0, !isStopping else { return }

      generation &+= 1
      let currentGeneration = generation
      events.yield(.starting(generation: currentGeneration))

      guard let workingDirectoryPointer = strdup(workspaceURL.path),
        let shellPointer = strdup(shellPath),
        let loginNamePointer = strdup("-\(URL(fileURLWithPath: shellPath).lastPathComponent)")
      else {
        events.yield(
          .failed(
            generation: currentGeneration,
            message: "Launch failed"
          ))
        return
      }
      var argumentPointers: [UnsafeMutablePointer<CChar>?] = [loginNamePointer, nil]
      var environmentPointers: [UnsafeMutablePointer<CChar>?] =
        shellEnvironment().map { strdup($0) }
      guard !environmentPointers.contains(where: { $0 == nil }) else {
        free(workingDirectoryPointer)
        free(shellPointer)
        free(loginNamePointer)
        for case let pointer? in environmentPointers { free(pointer) }
        events.yield(
          .failed(
            generation: currentGeneration,
            message: "Launch failed"
          ))
        return
      }
      environmentPointers.append(nil)
      defer {
        free(workingDirectoryPointer)
        free(shellPointer)
        free(loginNamePointer)
        for case let pointer? in environmentPointers { free(pointer) }
      }

      var master: Int32 = -1
      var windowSize = winsize(
        ws_row: UInt16(clamping: requestedRows),
        ws_col: UInt16(clamping: requestedColumns),
        ws_xpixel: 0,
        ws_ypixel: 0
      )
      let pid = argumentPointers.withUnsafeMutableBufferPointer { arguments in
        environmentPointers.withUnsafeMutableBufferPointer { environment in
          let pid = forkpty(&master, nil, nil, &windowSize)
          if pid == 0 {
            _ = chdir(workingDirectoryPointer)
            guard let argumentBase = arguments.baseAddress,
              let environmentBase = environment.baseAddress
            else { _exit(127) }
            execve(shellPointer, argumentBase, environmentBase)
            _exit(127)
          }
          return pid
        }
      }
      guard pid >= 0 else {
        events.yield(
          .failed(
            generation: currentGeneration,
            message: String(cString: strerror(errno))
          ))
        return
      }

      let existingFlags = fcntl(master, F_GETFL)
      if existingFlags >= 0 { _ = fcntl(master, F_SETFL, existingFlags | O_NONBLOCK) }

      childPID = pid
      masterFileDescriptor = master
      isStopping = false
      restartAfterExit = false
      events.yield(.started(generation: currentGeneration))

      let continuation = events
      readTask = Task.detached(priority: .userInitiated) {
        Self.readLoop(
          fileDescriptor: master,
          generation: currentGeneration,
          events: continuation
        )
      }

      processMonitorTask = Task.detached(priority: .utility) { [weak self] in
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        await self?.processDidExit(
          pid: pid,
          generation: currentGeneration,
          status: status
        )
      }

      drainPendingInput()
    }

    private func requestStop(restarting: Bool) {
      restartAfterExit = restarting
      guard childPID > 0 else {
        // A process-exit cleanup may still be draining the old reader. Keep the
        // desired restart state, but never launch until that reader has ended.
        if isStopping { return }
        if restarting, !isShuttingDown { launchShell() }
        return
      }
      guard !isStopping else { return }

      isStopping = true
      events.yield(.stopping(generation: generation, restarting: restarting))
      readTask?.cancel()
      closeMasterFileDescriptor()

      Self.terminateProcessGroup(childPID)
    }

    private func processDidExit(
      pid: pid_t,
      generation processGeneration: UInt64,
      status: Int32
    ) async {
      guard childPID == pid, generation == processGeneration else { return }

      let reader = readTask
      readTask = nil
      reader?.cancel()
      closeMasterFileDescriptor()
      childPID = 0
      processMonitorTask = nil

      let wasStopping = isStopping
      isStopping = true
      if let reader { await reader.value }

      guard generation == processGeneration, childPID == 0 else { return }
      let shouldRestart = restartAfterExit && !isShuttingDown
      isStopping = false
      restartAfterExit = false

      let description: String
      if wasStopping {
        description = shouldRestart ? "Restarting" : "Stopped"
      } else {
        description = Self.exitDescription(for: status)
      }
      events.yield(
        .finished(
          generation: processGeneration,
          description: description,
          restarting: shouldRestart
        ))

      if shouldRestart { launchShell() }
    }

    private func closeMasterFileDescriptor() {
      guard masterFileDescriptor >= 0 else { return }
      let descriptor = masterFileDescriptor
      masterFileDescriptor = -1
      _ = Darwin.close(descriptor)
    }

    private func appendPendingInput(_ value: String) {
      pendingInput += value
      if pendingInput.utf8.count > 64_000 {
        pendingInput = BoundedUTF8Text.suffix(of: pendingInput, maximumBytes: 48_000)
      }
    }

    private func drainPendingInput() {
      guard masterFileDescriptor >= 0, !pendingInput.isEmpty else { return }
      let value = pendingInput
      pendingInput = ""
      if !Self.writeAll(Data(value.utf8), to: masterFileDescriptor) {
        appendPendingInput(value)
        requestStop(restarting: true)
      }
    }

    nonisolated private static func readLoop(
      fileDescriptor: Int32,
      generation: UInt64,
      events: AsyncStream<EditorTerminalEvent>.Continuation
    ) {
      var decoder = IncrementalUTF8Decoder()
      var pollDescriptor = pollfd(
        fd: fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
      var shouldFinish = false

      while !Task.isCancelled, !shouldFinish {
        pollDescriptor.revents = 0
        let pollResult = Darwin.poll(&pollDescriptor, 1, 100)
        if pollResult < 0 {
          if errno == EINTR { continue }
          break
        }
        if pollResult == 0 { continue }

        while !Task.isCancelled {
          var buffer = [UInt8](repeating: 0, count: 16_384)
          let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
          if count > 0 {
            let text = decoder.decode(Data(buffer.prefix(count)))
            if !text.isEmpty {
              events.yield(.output(text, generation: generation))
            }
            continue
          }
          if count == 0 {
            shouldFinish = true
            break
          }
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK { break }
          shouldFinish = true
          break
        }

        if pollDescriptor.revents & Int16(POLLNVAL) != 0 { break }
        if pollDescriptor.revents & Int16(POLLHUP | POLLERR) != 0 {
          shouldFinish = true
        }
      }

      let tail = decoder.finish()
      if !tail.isEmpty { events.yield(.output(tail, generation: generation)) }
    }

    nonisolated private static func writeAll(_ data: Data, to fileDescriptor: Int32) -> Bool {
      data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return true }
        var remaining = rawBuffer.count
        var pointer = baseAddress
        while remaining > 0 {
          let written = Darwin.write(fileDescriptor, pointer, remaining)
          if written > 0 {
            remaining -= written
            pointer = pointer.advanced(by: written)
            continue
          }
          if written < 0, errno == EINTR { continue }
          if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
            if Darwin.poll(&descriptor, 1, 250) > 0 { continue }
          }
          return false
        }
        return true
      }
    }

    nonisolated private func shellEnvironment() -> [String] {
      var environment = EditorProcessEnvironment.prepared(
        base: {
          let buildProjectURL =
            EditorBuildProjectSelectionStore.load(workspaceURL: workspaceURL) ?? workspaceURL
          return EditorPythonEnvironmentResolver.activatedEnvironment(
            workspaceURL: buildProjectURL,
            explicitInterpreterURL: EditorPythonInterpreterSelectionStore.load(
              workspaceURL: buildProjectURL)
          ).environment
        }(),
        workingDirectory: workspaceURL
      )
      environment["TERM"] = "xterm-256color"
      environment["COLORTERM"] = "truecolor"
      environment["TERM_PROGRAM"] = "Calcite"
      environment["TERM_PROGRAM_VERSION"] = "1"
      environment["PWD"] = workspaceURL.path
      environment["CALCITE_TERMINAL"] = "1"
      return environment.keys.sorted().compactMap { key in
        environment[key].map { "\(key)=\($0)" }
      }
    }

    nonisolated private static func signalProcessGroup(_ pid: pid_t, signal: Int32) {
      if Darwin.kill(-pid, signal) != 0 { _ = Darwin.kill(pid, signal) }
    }

    nonisolated private static func terminateProcessGroup(_ pid: pid_t) {
      signalProcessGroup(pid, signal: SIGHUP)
      usleep(250_000)
      if Darwin.kill(pid, 0) == 0 {
        signalProcessGroup(pid, signal: SIGTERM)
        usleep(350_000)
      }
      if Darwin.kill(pid, 0) == 0 { signalProcessGroup(pid, signal: SIGKILL) }
    }

    nonisolated private static func exitDescription(for status: Int32) -> String {
      let terminationSignal = status & 0x7f
      if terminationSignal == 0 {
        let exitStatus = (status >> 8) & 0xff
        return "Exit \(exitStatus)"
      }
      if terminationSignal != 0x7f {
        return "Signal \(terminationSignal)"
      }
      return "Ended"
    }
  }
#endif
