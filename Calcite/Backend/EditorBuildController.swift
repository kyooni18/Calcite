import Combine
import EditorServices
import Foundation

@MainActor
enum EditorBuildPhase: Equatable {
  case idle
  case running(String)
  case cancelling(String)
  case cancelled(String)
  case succeeded(String)
  case failed(String)

  var isRunning: Bool {
    switch self {
    case .running, .cancelling: return true
    case .idle, .cancelled, .succeeded, .failed: return false
    }
  }
}

@MainActor
final class EditorBuildController: ObservableObject {
  let workspaceURL: URL
  @Published private(set) var buildProjectURL: URL
  @Published private(set) var plan: EditorBuildPlan
  @Published private(set) var phase: EditorBuildPhase = .idle
  @Published private(set) var output = ""
  @Published private(set) var diagnostics: [EditorBuildDiagnostic] = []
  @Published private(set) var discoveryWarnings: [String] = []
  @Published private(set) var availableXcodeSchemes: [String] = []
  @Published private(set) var selectedXcodeScheme: String?
  @Published private(set) var selectedPythonInterpreterURL: URL?
  @Published private(set) var detectedPythonEnvironment: EditorPythonEnvironment?
  @Published var selectedCommandID: String?

  var onDiagnostics: (@MainActor ([EditorBuildDiagnostic]) -> Void)?

  private let runner = EditorBuildRunner()
  private let logStore = CalciteLogStore.shared
  private var cancellationTask: Task<Void, Never>?
  private var outputFlushTask: Task<Void, Never>?
  private var pendingOutput = ""
  private var pendingOutputUTF8Count = 0
  private var outputUTF8Count = 0
  private var runGeneration: UInt64 = 0

  init(workspaceURL: URL) {
    self.workspaceURL = workspaceURL.standardizedFileURL
    let buildProjectURL =
      EditorBuildProjectSelectionStore.load(workspaceURL: self.workspaceURL) ?? self.workspaceURL
    self.buildProjectURL = buildProjectURL
    let selectedScheme = EditorXcodeSchemeSelectionStore.load(workspaceURL: buildProjectURL)
    let selectedPython = EditorPythonInterpreterSelectionStore.load(workspaceURL: buildProjectURL)
    self.selectedXcodeScheme = selectedScheme
    self.selectedPythonInterpreterURL = selectedPython
    self.availableXcodeSchemes = EditorBuildDiscovery.xcodeSchemes(workspaceURL: buildProjectURL)
    self.detectedPythonEnvironment = Self.detectPythonEnvironment(
      buildProjectURL: buildProjectURL,
      workspaceURL: self.workspaceURL,
      explicitInterpreterURL: selectedPython
    )
    let discovered = Self.discover(
      workspaceURL: buildProjectURL, preferredXcodeScheme: selectedScheme)
    self.plan = discovered.plan
    self.discoveryWarnings = discovered.warnings
    self.selectedCommandID =
      discovered.plan.command(for: .build)?.id
      ?? discovered.plan.command(for: .check)?.id
      ?? discovered.plan.commands.first?.id
  }

  isolated deinit {
    cancellationTask?.cancel()
    outputFlushTask?.cancel()
    let runner = runner
    Task { await runner.cancel(gracePeriod: .milliseconds(200)) }
  }

  var selectedCommand: EditorBuildCommand? {
    guard let selectedCommandID else { return nil }
    return plan.commands.first { $0.id == selectedCommandID }
  }

  func rediscover() {
    let previous = selectedCommandID
    availableXcodeSchemes = EditorBuildDiscovery.xcodeSchemes(workspaceURL: buildProjectURL)
    if let selectedXcodeScheme, !availableXcodeSchemes.contains(selectedXcodeScheme) {
      self.selectedXcodeScheme = nil
      EditorXcodeSchemeSelectionStore.save(nil, workspaceURL: buildProjectURL)
    }
    selectedPythonInterpreterURL = EditorPythonInterpreterSelectionStore.load(
      workspaceURL: buildProjectURL)
    detectedPythonEnvironment = Self.detectPythonEnvironment(
      buildProjectURL: buildProjectURL,
      workspaceURL: workspaceURL,
      explicitInterpreterURL: selectedPythonInterpreterURL
    )
    let discovered = Self.discover(
      workspaceURL: buildProjectURL,
      preferredXcodeScheme: selectedXcodeScheme
    )
    plan = discovered.plan
    discoveryWarnings = discovered.warnings
    selectedCommandID =
      plan.commands.contains { $0.id == previous }
      ? previous
      : plan.command(for: .build)?.id ?? plan.command(for: .check)?.id ?? plan.commands.first?.id
  }

  func selectXcodeScheme(_ scheme: String?) {
    guard !phase.isRunning else { return }
    selectedXcodeScheme = scheme
    EditorXcodeSchemeSelectionStore.save(scheme, workspaceURL: buildProjectURL)
    rediscover()
  }

  func selectPythonInterpreter(_ url: URL?) {
    guard !phase.isRunning else { return }
    EditorPythonInterpreterSelectionStore.save(url, workspaceURL: buildProjectURL)
    selectedPythonInterpreterURL = url?.standardizedFileURL
    detectedPythonEnvironment = Self.detectPythonEnvironment(
      buildProjectURL: buildProjectURL,
      workspaceURL: workspaceURL,
      explicitInterpreterURL: selectedPythonInterpreterURL
    )
  }

  func createCustomTaskFileIfNeeded() throws -> URL {
    try EditorCustomBuildTaskStore.createTemplateIfNeeded(workspaceURL: buildProjectURL)
  }

  func selectBuildProjectFolder(_ url: URL) {
    guard !phase.isRunning else { return }
    buildProjectURL = url.standardizedFileURL
    EditorBuildProjectSelectionStore.save(buildProjectURL, workspaceURL: workspaceURL)
    selectedXcodeScheme = EditorXcodeSchemeSelectionStore.load(workspaceURL: buildProjectURL)
    selectedPythonInterpreterURL = EditorPythonInterpreterSelectionStore.load(
      workspaceURL: buildProjectURL)
    rediscover()
  }

  func useWorkspaceAsBuildProject() {
    guard !phase.isRunning else { return }
    buildProjectURL = workspaceURL
    EditorBuildProjectSelectionStore.clear(workspaceURL: workspaceURL)
    selectedXcodeScheme = EditorXcodeSchemeSelectionStore.load(workspaceURL: buildProjectURL)
    selectedPythonInterpreterURL = EditorPythonInterpreterSelectionStore.load(
      workspaceURL: buildProjectURL)
    rediscover()
  }

  @discardableResult
  func run(kind: EditorBuildTaskKind) async -> Bool {
    guard let command = plan.command(for: kind) else {
      phase = .failed("No \(kind.rawValue) task was detected for this project.")
      return false
    }
    return await run(command)
  }

  @discardableResult
  func runSingleFile(_ fileURL: URL, kind: EditorBuildTaskKind) async -> Bool {
    guard let filePlan = EditorBuildDiscovery.singleFilePlan(fileURL: fileURL) else {
      phase = .failed("No standalone runner is available for \(fileURL.lastPathComponent).")
      return false
    }
    if kind == .run, let build = filePlan.command(for: .build) {
      guard await run(build, resettingOutput: true) else { return false }
      guard let runCommand = filePlan.command(for: .run) else { return true }
      return await run(runCommand, resettingOutput: false)
    }
    guard let command = filePlan.command(for: kind) else {
      phase = .failed(
        "No standalone \(kind.rawValue) task is available for \(fileURL.lastPathComponent).")
      return false
    }
    return await run(command, resettingOutput: true)
  }

  @discardableResult
  func runSelected() async -> Bool {
    guard let selectedCommand else {
      phase = .failed("No build task is selected.")
      return false
    }
    return await run(selectedCommand)
  }

  @discardableResult
  func run(_ command: EditorBuildCommand) async -> Bool {
    await run(command, resettingOutput: true)
  }

  @discardableResult
  private func run(_ command: EditorBuildCommand, resettingOutput: Bool) async -> Bool {
    guard !phase.isRunning else { return false }
    runGeneration &+= 1
    let generation = runGeneration
    cancellationTask?.cancel()
    cancellationTask = nil
    outputFlushTask?.cancel()
    outputFlushTask = nil
    pendingOutput = ""
    pendingOutputUTF8Count = 0
    if resettingOutput {
      output = ""
      outputUTF8Count = 0
      diagnostics = []
      onDiagnostics?([])
    } else {
      append("\n")
    }
    phase = .running(command.title)
    let operationID = logStore.beginOperation(
      command.title,
      category: "Build",
      detail: command.workingDirectory.path
    )
    defer {
      switch phase {
      case .succeeded(let message):
        logStore.finishOperation(
          operationID, message: message, metadata: ["command": command.executable])
      case .failed(let message):
        logStore.finishOperation(
          operationID, level: .error, message: message, metadata: ["command": command.executable])
      case .cancelled(let message), .cancelling(let message):
        logStore.finishOperation(
          operationID, level: .notice, message: message, metadata: ["command": command.executable])
      case .idle, .running:
        logStore.finishOperation(
          operationID, level: .notice, message: "Build operation ended",
          metadata: ["command": command.executable])
      }
    }
    append("$ cd \(command.workingDirectory.path)\n")
    let executable = URL(fileURLWithPath: command.executable).lastPathComponent
    append("$ \(([executable] + command.arguments).map(shellQuote).joined(separator: " "))\n")

    do {
      let python = Self.detectPythonEnvironment(
        buildProjectURL: command.workingDirectory,
        workspaceURL: workspaceURL,
        explicitInterpreterURL: selectedPythonInterpreterURL
      )
      let activated = EditorPythonEnvironmentResolver.activatedEnvironment(
        workspaceURL: python?.rootURL ?? command.workingDirectory,
        base: ProcessInfo.processInfo.environment,
        explicitInterpreterURL: python?.executableURL ?? selectedPythonInterpreterURL
      )
      detectedPythonEnvironment = activated.python
      // Keep the selected project environment authoritative for build commands. The runner
      // also prepares GUI-safe PATH values, but must receive the activated venv first so
      // commands such as `python`, `pytest`, and project task wrappers resolve inside it.
      let buildEnvironment = activated.environment.merging(command.environment) { _, value in value }
      let stream = try await runner.run(command, environment: buildEnvironment)
      var receivedFinishedEvent = false
      await withTaskCancellationHandler {
        for await event in stream {
          guard generation == runGeneration, !Task.isCancelled else { break }
          if case .finished = event { receivedFinishedEvent = true }
          self.consume(event)
        }
      } onCancel: { [runner] in
        Task { await runner.cancel(gracePeriod: .milliseconds(200)) }
      }
      flushPendingOutput()
      guard generation == runGeneration else { return false }
      if Task.isCancelled {
        if phase.isRunning { phase = .cancelled("Cancelled") }
      } else if !receivedFinishedEvent, phase.isRunning {
        phase = .failed("The task ended without a completion result.")
      }
    } catch {
      flushPendingOutput()
      guard generation == runGeneration else { return false }
      if error is CancellationError {
        phase = .cancelled("Cancelled")
        return false
      }
      phase = .failed(error.localizedDescription)
      append("\(error.localizedDescription)\n")
      flushPendingOutput()
    }
    if case .succeeded = phase { return true }
    return false
  }

  func cancel() {
    guard case .running(let title) = phase else { return }
    phase = .cancelling(title)
    cancellationTask?.cancel()
    cancellationTask = Task { [weak self] in
      guard let self else { return }
      await self.runner.cancel()
      guard !Task.isCancelled else { return }
      if case .cancelling = self.phase {
        self.phase = .cancelled("Cancelled")
      }
      self.cancellationTask = nil
    }
  }

  func clear() {
    outputFlushTask?.cancel()
    outputFlushTask = nil
    pendingOutput = ""
    pendingOutputUTF8Count = 0
    output = ""
    outputUTF8Count = 0
    diagnostics = []
    onDiagnostics?([])
    if !phase.isRunning { phase = .idle }
  }

  private static func discover(
    workspaceURL: URL,
    preferredXcodeScheme: String? = nil
  ) -> (plan: EditorBuildPlan, warnings: [String]) {
    let detected = EditorBuildDiscovery.inspect(
      workspaceURL: workspaceURL,
      preferredXcodeScheme: preferredXcodeScheme
    )
    return EditorCustomBuildTaskStore.merge(detected: detected, workspaceURL: workspaceURL)
  }

  private static func detectPythonEnvironment(
    buildProjectURL: URL,
    workspaceURL: URL,
    explicitInterpreterURL: URL?
  ) -> EditorPythonEnvironment? {
    EditorPythonEnvironmentResolver.detect(
      workspaceURL: buildProjectURL,
      explicitInterpreterURL: explicitInterpreterURL
    ) ?? {
      guard buildProjectURL.standardizedFileURL != workspaceURL.standardizedFileURL else {
        return nil
      }
      return EditorPythonEnvironmentResolver.detect(
        workspaceURL: workspaceURL,
        explicitInterpreterURL: explicitInterpreterURL
      )
    }()
  }

  private func consume(_ event: EditorBuildEvent) {
    switch event {
    case .started:
      if let python = detectedPythonEnvironment
        ?? EditorPythonEnvironmentResolver.detect(
          workspaceURL: buildProjectURL,
          explicitInterpreterURL: selectedPythonInterpreterURL
        )
      {
        append("Python: \(python.rootURL.lastPathComponent)\n")
      }
    case .output(let text, _):
      append(text)
    case .diagnostic(let diagnostic):
      let duplicate = diagnostics.contains {
        $0.url == diagnostic.url && $0.line == diagnostic.line && $0.column == diagnostic.column
          && $0.severity == diagnostic.severity
          && $0.message.trimmingCharacters(in: .whitespacesAndNewlines)
            == diagnostic.message.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if !duplicate {
        diagnostics.append(diagnostic)
        onDiagnostics?(diagnostics)
      }
    case .finished(let result):
      cancellationTask?.cancel()
      cancellationTask = nil
      flushPendingOutput()
      if result.wasCancelled {
        phase = .cancelled("Cancelled after \(durationText(result.duration))")
      } else if result.succeeded {
        phase = .succeeded("Completed in \(durationText(result.duration))")
      } else {
        phase = .failed("Exited with status \(result.exitCode)")
      }
    }
  }

  private func append(_ value: String) {
    guard !value.isEmpty else { return }
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
    outputFlushTask?.cancel()
    outputFlushTask = nil
    guard !pendingOutput.isEmpty else { return }
    output += pendingOutput
    outputUTF8Count += pendingOutputUTF8Count
    pendingOutput = ""
    pendingOutputUTF8Count = 0
    if outputUTF8Count > 10_000_000 {
      output = BoundedUTF8Text.suffix(of: output, maximumBytes: 8_000_000)
      outputUTF8Count = output.utf8.count
    }
  }

  private func shellQuote(_ value: String) -> String {
    guard !value.isEmpty else { return "''" }
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/@%+=:,"))
    if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
      return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func durationText(_ duration: Duration) -> String {
    let components = duration.components
    let seconds =
      Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
    return String(format: "%.2fs", seconds)
  }
}
