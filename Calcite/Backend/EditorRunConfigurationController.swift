import Combine
import EditorServices
import Foundation

nonisolated enum EditorExecutionTargetKind: String, Codable, CaseIterable, Sendable {
  case project
  case currentFile
}

nonisolated enum EditorTerminalMode: String, Codable, CaseIterable, Sendable {
  case integrated
  case external
  case debugConsole
}

nonisolated struct EditorRunConfiguration: Codable, Identifiable, Equatable, Sendable {
  var id: UUID
  var name: String
  var target: EditorExecutionTargetKind
  var projectTargetName: String?
  var arguments: [String]
  var environment: [String: String]
  var workingDirectory: String
  var toolchainPath: String?
  var buildBeforeLaunch: Bool
  var stopOnEntry: Bool
  var terminalMode: EditorTerminalMode
  var debuggerAdapterID: String?
  var preLaunchTaskIDs: [String]
  var postDebugTaskIDs: [String]
  var liveDebugWatchRoots: [String]
  var liveDebugExclusions: [String]
  /// Shared configurations are written to `.calcite/run-configurations.json`.
  /// Machine-local paths, adapter overrides, and environment values remain in
  /// Calcite's private workspace state and are merged at load time.
  var isShared: Bool

  init(
    id: UUID = UUID(),
    name: String,
    target: EditorExecutionTargetKind,
    projectTargetName: String? = nil,
    arguments: [String] = [],
    environment: [String: String] = [:],
    workingDirectory: String = "",
    toolchainPath: String? = nil,
    buildBeforeLaunch: Bool = true,
    stopOnEntry: Bool = false,
    terminalMode: EditorTerminalMode = .integrated,
    debuggerAdapterID: String? = nil,
    preLaunchTaskIDs: [String] = [],
    postDebugTaskIDs: [String] = [],
    liveDebugWatchRoots: [String] = [],
    liveDebugExclusions: [String] = [],
    isShared: Bool = false
  ) {
    self.id = id
    self.name = name
    self.target = target
    self.projectTargetName = projectTargetName
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.toolchainPath = toolchainPath
    self.buildBeforeLaunch = buildBeforeLaunch
    self.stopOnEntry = stopOnEntry
    self.terminalMode = terminalMode
    self.debuggerAdapterID = debuggerAdapterID
    self.preLaunchTaskIDs = preLaunchTaskIDs
    self.postDebugTaskIDs = postDebugTaskIDs
    self.liveDebugWatchRoots = liveDebugWatchRoots
    self.liveDebugExclusions = liveDebugExclusions
    self.isShared = isShared
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Configuration"
    target =
      try container.decodeIfPresent(EditorExecutionTargetKind.self, forKey: .target) ?? .project
    projectTargetName = try container.decodeIfPresent(String.self, forKey: .projectTargetName)
    arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
    environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
    toolchainPath = try container.decodeIfPresent(String.self, forKey: .toolchainPath)
    buildBeforeLaunch = try container.decodeIfPresent(Bool.self, forKey: .buildBeforeLaunch) ?? true
    stopOnEntry = try container.decodeIfPresent(Bool.self, forKey: .stopOnEntry) ?? false
    terminalMode =
      try container.decodeIfPresent(EditorTerminalMode.self, forKey: .terminalMode) ?? .integrated
    debuggerAdapterID = try container.decodeIfPresent(String.self, forKey: .debuggerAdapterID)
    preLaunchTaskIDs = try container.decodeIfPresent([String].self, forKey: .preLaunchTaskIDs) ?? []
    postDebugTaskIDs = try container.decodeIfPresent([String].self, forKey: .postDebugTaskIDs) ?? []
    liveDebugWatchRoots =
      try container.decodeIfPresent([String].self, forKey: .liveDebugWatchRoots) ?? []
    liveDebugExclusions =
      try container.decodeIfPresent([String].self, forKey: .liveDebugExclusions) ?? []
    isShared = try container.decodeIfPresent(Bool.self, forKey: .isShared) ?? false
  }

  static func projectDefault(workspaceURL: URL) -> EditorRunConfiguration {
    EditorRunConfiguration(
      name: "Project",
      target: .project,
      workingDirectory: workspaceURL.path
    )
  }

  static func currentFileDefault(workspaceURL: URL) -> EditorRunConfiguration {
    EditorRunConfiguration(
      name: "Current File",
      target: .currentFile,
      workingDirectory: workspaceURL.path
    )
  }
}

@MainActor
final class EditorRunConfigurationController: ObservableObject {
  private struct LegacyPayload: Codable {
    var schemaVersion: Int?
    var selectedID: UUID?
    var configurations: [EditorRunConfiguration]
  }

  private struct LocalOverride: Codable {
    var environment: [String: String]
    var workingDirectory: String
    var toolchainPath: String?
    var debuggerAdapterID: String?
  }

  private struct LocalPayload: Codable {
    var schemaVersion = 3
    var selectedID: UUID?
    var privateConfigurations: [EditorRunConfiguration]
    var sharedOverrides: [String: LocalOverride]
  }

  private struct SharedPayload: Codable {
    var schemaVersion = 1
    var configurations: [EditorRunConfiguration]
  }

  @Published private(set) var configurations: [EditorRunConfiguration]
  @Published var selectedID: UUID? {
    didSet { persist() }
  }

  private let workspaceURL: URL
  private let storageURL: URL
  private let sharedStorageURL: URL

  init(workspaceURL: URL) {
    self.workspaceURL = workspaceURL.standardizedFileURL
    self.storageURL = CalciteStateStorage.workspaceURL(
      workspaceURL,
      filename: "run-configurations.json"
    )
    self.sharedStorageURL = workspaceURL.standardizedFileURL
      .appendingPathComponent(".calcite", isDirectory: true)
      .appendingPathComponent("run-configurations.json")

    let loaded = Self.loadConfigurations(
      localURL: storageURL,
      sharedURL: sharedStorageURL
    )
    if loaded.configurations.isEmpty {
      let project = EditorRunConfiguration.projectDefault(workspaceURL: workspaceURL)
      let file = EditorRunConfiguration.currentFileDefault(workspaceURL: workspaceURL)
      self.configurations = [project, file]
      self.selectedID = project.id
    } else {
      self.configurations = loaded.configurations
      self.selectedID = loaded.selectedID ?? loaded.configurations.first?.id
    }
  }

  var selected: EditorRunConfiguration {
    configurations.first(where: { $0.id == selectedID })
      ?? configurations.first
      ?? .projectDefault(workspaceURL: workspaceURL)
  }

  func configuration(for target: EditorExecutionTargetKind) -> EditorRunConfiguration? {
    configurations.first(where: { $0.id == selectedID && $0.target == target })
      ?? configurations.first(where: { $0.target == target })
  }

  func configuration(id: UUID) -> EditorRunConfiguration? {
    configurations.first { $0.id == id }
  }

  func select(target: EditorExecutionTargetKind) {
    if let value = configurations.first(where: { $0.target == target }) {
      selectedID = value.id
      return
    }
    let value =
      target == .project
      ? EditorRunConfiguration.projectDefault(workspaceURL: workspaceURL)
      : EditorRunConfiguration.currentFileDefault(workspaceURL: workspaceURL)
    configurations.append(value)
    selectedID = value.id
    persist()
  }

  func add(target: EditorExecutionTargetKind = .project) -> EditorRunConfiguration {
    var value =
      target == .project
      ? EditorRunConfiguration.projectDefault(workspaceURL: workspaceURL)
      : EditorRunConfiguration.currentFileDefault(workspaceURL: workspaceURL)
    value.id = UUID()
    value.name = uniqueName(value.name)
    configurations.append(value)
    selectedID = value.id
    persist()
    return value
  }

  func duplicate(_ configuration: EditorRunConfiguration) {
    var copy = configuration
    copy.id = UUID()
    copy.name = uniqueName(configuration.name + " Copy")
    configurations.append(copy)
    selectedID = copy.id
    persist()
  }

  func update(_ configuration: EditorRunConfiguration) {
    if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
      configurations[index] = sanitized(configuration)
    } else {
      configurations.append(sanitized(configuration))
    }
    selectedID = configuration.id
    persist()
  }

  func remove(_ configuration: EditorRunConfiguration) {
    guard configurations.count > 1 else { return }
    configurations.removeAll { $0.id == configuration.id }
    if selectedID == configuration.id { selectedID = configurations.first?.id }
    persist()
  }

  func taskCommands(
    _ identifiers: [String],
    plan: EditorBuildPlan
  ) -> (commands: [EditorBuildCommand], missing: [String]) {
    var commands: [EditorBuildCommand] = []
    var missing: [String] = []
    var seen = Set<String>()
    for identifier in identifiers where seen.insert(identifier).inserted {
      if let command = plan.commands.first(where: { $0.id == identifier }) {
        commands.append(command)
      } else {
        missing.append(identifier)
      }
    }
    return (commands, missing)
  }

  func configuredCommand(
    _ command: EditorBuildCommand,
    target: EditorExecutionTargetKind,
    plan: EditorBuildPlan
  ) -> EditorBuildCommand {
    guard
      let configuration = configurations.first(where: {
        $0.id == selectedID && $0.target == target
      }) ?? configurations.first(where: { $0.target == target })
    else { return command }
    var command = command
    if target == .project,
      let selectedTarget = configuration.projectTargetName?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !selectedTarget.isEmpty
    {
      command = Self.applyingProjectTarget(selectedTarget, to: command, plan: plan)
    }
    if command.kind == .run, !configuration.arguments.isEmpty,
      [.rustCargo, .nodePackage].contains(plan.projectKind)
    {
      if !command.arguments.contains("--") { command.arguments.append("--") }
      command.arguments += configuration.arguments
    } else {
      command.arguments += configuration.arguments
    }
    command.environment.merge(configuration.environment) { _, configured in configured }
    command = Self.applyingToolchain(configuration.toolchainPath, to: command)
    let cwd = NSString(string: configuration.workingDirectory).expandingTildeInPath
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !cwd.isEmpty {
      let url = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
      if FileManager.default.fileExists(atPath: url.path) { command.workingDirectory = url }
    }
    return command
  }

  private static func loadConfigurations(
    localURL: URL,
    sharedURL: URL
  ) -> (selectedID: UUID?, configurations: [EditorRunConfiguration]) {
    let shared =
      CalciteStateStorage.load(SharedPayload.self, from: sharedURL)?
      .configurations.map { value -> EditorRunConfiguration in
        var value = value
        value.isShared = true
        value.environment = [:]
        value.workingDirectory = ""
        value.toolchainPath = nil
        value.debuggerAdapterID = nil
        return value
      } ?? []

    if let local = CalciteStateStorage.load(LocalPayload.self, from: localURL) {
      var merged = shared.map { value -> EditorRunConfiguration in
        var value = value
        if let override = local.sharedOverrides[value.id.uuidString] {
          value.environment = override.environment
          value.workingDirectory = override.workingDirectory
          value.toolchainPath = override.toolchainPath
          value.debuggerAdapterID = override.debuggerAdapterID
        }
        return value
      }
      merged += local.privateConfigurations.map { value -> EditorRunConfiguration in
        var value = value
        value.isShared = false
        return value
      }
      return (local.selectedID, deduplicated(merged))
    }

    if let legacy = CalciteStateStorage.load(LegacyPayload.self, from: localURL) {
      return (legacy.selectedID, deduplicated(legacy.configurations))
    }
    return (nil, deduplicated(shared))
  }

  private func persist() {
    let values = configurations.map(sanitized)
    let shared = values.filter(\.isShared)
    let privateValues = values.filter { !$0.isShared }
    var overrides: [String: LocalOverride] = [:]
    for value in shared {
      overrides[value.id.uuidString] = LocalOverride(
        environment: value.environment,
        workingDirectory: value.workingDirectory,
        toolchainPath: value.toolchainPath,
        debuggerAdapterID: value.debuggerAdapterID
      )
    }

    let localPayload = LocalPayload(
      selectedID: selectedID,
      privateConfigurations: privateValues,
      sharedOverrides: overrides
    )
    let sharedPayload = SharedPayload(
      configurations: shared.map { value -> EditorRunConfiguration in
        var value = value
        value.environment = [:]
        value.workingDirectory = ""
        value.toolchainPath = nil
        value.debuggerAdapterID = nil
        return value
      }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? CalciteStateStorage.save(localPayload, to: storageURL, encoder: encoder)
    do {
      if shared.isEmpty {
        try? FileManager.default.removeItem(at: sharedStorageURL)
      } else {
        try FileManager.default.createDirectory(
          at: sharedStorageURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try CalciteStateStorage.save(sharedPayload, to: sharedStorageURL, encoder: encoder)
      }
    } catch {
      // Local settings remain authoritative when the project directory is read-only.
    }
  }

  private func sanitized(_ value: EditorRunConfiguration) -> EditorRunConfiguration {
    var value = value
    value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.name.isEmpty { value.name = "Configuration" }
    value.projectTargetName =
      value.projectTargetName?
      .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    value.arguments = value.arguments.filter { !$0.isEmpty }
    value.toolchainPath =
      value.toolchainPath?
      .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    value.environment = value.environment.filter { !$0.key.isEmpty }
    value.preLaunchTaskIDs = value.preLaunchTaskIDs.filter { !$0.isEmpty }
    value.postDebugTaskIDs = value.postDebugTaskIDs.filter { !$0.isEmpty }
    value.liveDebugWatchRoots = value.liveDebugWatchRoots.filter { !$0.isEmpty }
    value.liveDebugExclusions = value.liveDebugExclusions.filter { !$0.isEmpty }
    return value
  }

  private static func applyingToolchain(
    _ configuredPath: String?,
    to command: EditorBuildCommand
  ) -> EditorBuildCommand {
    guard
      let configuredPath = configuredPath?
        .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    else { return command }

    var command = command
    let expanded = NSString(string: configuredPath).expandingTildeInPath
    let root = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    let bin =
      root.lastPathComponent == "bin" ? root : root.appendingPathComponent("bin", isDirectory: true)
    let executableName = URL(fileURLWithPath: command.executable).lastPathComponent
    let candidate = bin.appendingPathComponent(executableName)
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
      command.executable = candidate.path
    }

    let inheritedPATH =
      command.environment["PATH"]
      ?? ProcessInfo.processInfo.environment["PATH"]
      ?? ""
    let components = inheritedPATH.split(separator: ":").map(String.init)
    if !components.contains(bin.path) {
      command.environment["PATH"] = ([bin.path] + components).joined(separator: ":")
    }
    return command
  }

  private static func applyingProjectTarget(
    _ target: String,
    to command: EditorBuildCommand,
    plan: EditorBuildPlan
  ) -> EditorBuildCommand {
    var command = command
    switch plan.projectKind {
    case .swiftPackage:
      if command.executable == "swift" {
        if command.arguments.first == "run" {
          if command.arguments.count == 1 { command.arguments.append(target) }
        } else if command.arguments.first == "build",
          !command.arguments.contains("--product"),
          !command.arguments.contains("--target")
        {
          command.arguments += ["--product", target]
        }
      }
    case .rustCargo:
      if command.executable == "cargo",
        !command.arguments.contains("--bin"),
        !command.arguments.contains("--package"),
        !command.arguments.contains("-p")
      {
        command.arguments += ["--bin", target]
      }
    case .goModule:
      if command.executable == "go", command.arguments.first == "run" {
        command.arguments.append(target)
      }
    case .xcode:
      if !command.arguments.contains("-scheme") {
        command.arguments += ["-scheme", target]
      }
    case .gradle:
      if !command.arguments.contains(target) { command.arguments.append(target) }
    case .maven, .nodePackage, .python, .zig, .cmake, .make, .generic:
      break
    }
    return command
  }

  private static func deduplicated(
    _ values: [EditorRunConfiguration]
  ) -> [EditorRunConfiguration] {
    var seen = Set<UUID>()
    return values.filter { seen.insert($0.id).inserted }
  }

  private func uniqueName(_ base: String) -> String {
    let names = Set(configurations.map(\.name))
    guard names.contains(base) else { return base }
    var index = 2
    while names.contains("\(base) \(index)") { index += 1 }
    return "\(base) \(index)"
  }
}
