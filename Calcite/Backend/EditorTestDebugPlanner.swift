import EditorServices
import Foundation

nonisolated enum EditorTestDebugPlannerError: LocalizedError, Sendable {
  case unsupported(String)
  case artifactUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .unsupported(let message), .artifactUnavailable(let message): return message
    }
  }
}

nonisolated struct EditorTestDebugPlan: Sendable {
  enum LaunchStyle: Sendable {
    case pythonPytest(nodeID: String)
    case goTest(packageURL: URL, filter: String)
    case nodeTest(executable: String, arguments: [String])
    case nativeTestBinary(filter: String?)
  }

  let language: EditorLanguage
  let buildCommand: EditorBuildCommand?
  let launchStyle: LaunchStyle
  let workingDirectory: URL
  let title: String
}

nonisolated enum EditorTestDebugPlanner {
  static func plan(
    projectKind: EditorProjectBuildKind,
    projectPlan: EditorBuildPlan,
    fileURL: URL,
    workspaceURL: URL,
    symbol: String? = nil
  ) throws -> EditorTestDebugPlan {
    let file = fileURL.standardizedFileURL
    let stem = file.deletingPathExtension().lastPathComponent
    let filter = symbol?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? stem
    switch projectKind {
    case .python:
      return EditorTestDebugPlan(
        language: .python,
        buildCommand: nil,
        launchStyle: .pythonPytest(
          nodeID: symbol == nil ? file.path : file.path + "::" + filter
        ),
        workingDirectory: workspaceURL,
        title: "Debug pytest: \(file.lastPathComponent)"
      )
    case .goModule:
      return EditorTestDebugPlan(
        language: .go,
        buildCommand: nil,
        launchStyle: .goTest(
          packageURL: file.deletingLastPathComponent(),
          filter: filter
        ),
        workingDirectory: file.deletingLastPathComponent(),
        title: "Debug Go tests: \(file.lastPathComponent)"
      )
    case .swiftPackage:
      let base =
        projectPlan.command(for: .test)
        ?? EditorBuildCommand(
          id: "swift-test-build",
          title: "Build Swift Tests",
          kind: .test,
          executable: "swift",
          arguments: ["test"],
          workingDirectory: workspaceURL
        )
      var build = base
      build = command(build, identifiedBy: ".debug-build")
      build.title = "Build Tests for Debugging"
      if !build.arguments.contains("--build-tests") { build.arguments.append("--build-tests") }
      return EditorTestDebugPlan(
        language: .swift,
        buildCommand: build,
        launchStyle: .nativeTestBinary(filter: filter),
        workingDirectory: workspaceURL,
        title: "Debug Swift tests: \(file.lastPathComponent)"
      )
    case .nodePackage:
      guard let command = projectPlan.command(for: .test) else {
        throw EditorTestDebugPlannerError.unsupported(
          "No Node test task was detected for this project."
        )
      }
      var arguments = command.arguments
      let relativePath: String = {
        let root = workspaceURL.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
      }()
      if !relativePath.isEmpty { arguments += ["--", relativePath] }
      if let symbol = symbol?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
        arguments += ["-t", symbol]
      }
      return EditorTestDebugPlan(
        language: file.pathExtension.lowercased() == "ts" ? .typescript : .javascript,
        buildCommand: nil,
        launchStyle: .nodeTest(executable: command.executable, arguments: arguments),
        workingDirectory: command.workingDirectory,
        title: "Debug Node tests: \(file.lastPathComponent)"
      )
    case .rustCargo:
      var build =
        projectPlan.command(for: .test)
        ?? EditorBuildCommand(
          id: "cargo-test-build",
          title: "Build Rust Tests",
          kind: .test,
          executable: "cargo",
          arguments: ["test"],
          workingDirectory: workspaceURL
        )
      build = command(build, identifiedBy: ".debug-build")
      build.title = "Build Tests for Debugging"
      if !build.arguments.contains("--no-run") { build.arguments.append("--no-run") }
      if !build.arguments.contains(where: { $0.hasPrefix("--message-format") }) {
        build.arguments.append("--message-format=json")
      }
      return EditorTestDebugPlan(
        language: .rust,
        buildCommand: build,
        launchStyle: .nativeTestBinary(filter: filter),
        workingDirectory: workspaceURL,
        title: "Debug Rust tests: \(file.lastPathComponent)"
      )
    case .xcode, .gradle, .maven, .zig, .cmake, .make, .generic:
      throw EditorTestDebugPlannerError.unsupported(
        "Debug Current Test is not available for \(projectKind.rawValue) yet. "
          + "Run the test task normally or configure an explicit test executable."
      )
    }
  }

  static func nativeTestArtifact(
    projectKind: EditorProjectBuildKind,
    workspaceURL: URL,
    buildOutput: String,
    buildCommand: EditorBuildCommand
  ) async -> URL? {
    switch projectKind {
    case .swiftPackage:
      return newestExecutable(
        under: workspaceURL.appendingPathComponent(".build", isDirectory: true),
        maximumDepth: 8,
        requiringPathComponentSuffix: ".xctest"
      )
    case .rustCargo:
      return await EditorArtifactResolver.resolve(
        command: buildCommand,
        projectKind: .rustCargo,
        buildProjectURL: workspaceURL,
        buildOutput: buildOutput
      )?.executableURL
    case .goModule, .python, .xcode, .nodePackage, .gradle, .maven, .zig, .cmake,
      .make, .generic:
      return nil
    }
  }

  static func launchArguments(
    plan: EditorTestDebugPlan,
    adapterID: String,
    configuration: EditorDebugConfiguration,
    nativeArtifact: URL?
  ) throws -> DAPValue {
    var values: [String: DAPValue] = [
      "name": .string(plan.title),
      "type": .string(adapterID),
      "request": .string("launch"),
      "cwd": .string(plan.workingDirectory.path),
      "stopOnEntry": .bool(configuration.stopOnEntry),
      "env": .object(configuration.environment.mapValues(DAPValue.string)),
    ]
    switch configuration.terminalMode {
    case .integrated:
      values["terminal"] = .string("integrated")
      values["console"] = .string("integratedTerminal")
    case .external:
      values["terminal"] = .string("external")
      values["console"] = .string("externalTerminal")
    case .debugConsole:
      values["terminal"] = .string("console")
      values["console"] = .string("internalConsole")
    }

    switch plan.launchStyle {
    case .pythonPytest(let nodeID):
      values["module"] = .string("pytest")
      values["args"] = .array([.string(nodeID)])
      values["justMyCode"] = .bool(false)
    case .goTest(let packageURL, let filter):
      values["mode"] = .string("test")
      values["program"] = .string(packageURL.path)
      values["args"] = .array([.string("-test.run"), .string(filter)])
    case .nodeTest(let executable, let arguments):
      values["runtimeExecutable"] = .string(executable)
      values["runtimeArgs"] = .array(arguments.map(DAPValue.string))
      values["program"] = .string("")
      values["skipFiles"] = .array([.string("<node_internals>/**")])
    case .nativeTestBinary(let filter):
      guard let nativeArtifact else {
        throw EditorTestDebugPlannerError.artifactUnavailable(
          "The test build succeeded, but Calcite could not locate its test executable."
        )
      }
      values["program"] = .string(nativeArtifact.path)
      if let filter, !filter.isEmpty {
        values["args"] = .array([.string(filter)])
      } else {
        values["args"] = .array([])
      }
      values["sourceLanguages"] = .array([.string(plan.language.rawValue)])
    }
    return .object(values)
  }

  private static func newestExecutable(
    under directory: URL,
    maximumDepth: Int,
    requiringPathComponentSuffix suffix: String
  ) -> URL? {
    guard maximumDepth >= 0,
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isExecutableKey, .contentModificationDateKey,
        ],
        options: [.skipsHiddenFiles]
      )
    else { return nil }
    var candidates: [URL] = []
    for entry in entries {
      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
      if values?.isDirectory == true {
        candidates += newestExecutableCandidates(
          under: entry,
          remainingDepth: maximumDepth - 1,
          suffix: suffix,
          insideMatchingBundle: entry.pathComponents.contains { $0.hasSuffix(suffix) }
        )
      }
    }
    return candidates.sorted { lhs, rhs in
      let left =
        (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      let right =
        (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return left > right
    }.first
  }

  private static func command(
    _ command: EditorBuildCommand,
    identifiedBy suffix: String
  ) -> EditorBuildCommand {
    EditorBuildCommand(
      id: command.id + suffix,
      title: command.title,
      kind: command.kind,
      executable: command.executable,
      arguments: command.arguments,
      workingDirectory: command.workingDirectory,
      environment: command.environment,
      artifactPath: command.artifactPath
    )
  }

  private static func newestExecutableCandidates(
    under directory: URL,
    remainingDepth: Int,
    suffix: String,
    insideMatchingBundle: Bool
  ) -> [URL] {
    guard remainingDepth >= 0,
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isExecutableKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }
    var result: [URL] = []
    for entry in entries {
      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
      if values?.isDirectory == true {
        result += newestExecutableCandidates(
          under: entry,
          remainingDepth: remainingDepth - 1,
          suffix: suffix,
          insideMatchingBundle: insideMatchingBundle || entry.lastPathComponent.hasSuffix(suffix)
        )
      } else if insideMatchingBundle, FileManager.default.isExecutableFile(atPath: entry.path) {
        result.append(entry)
      }
    }
    return result
  }
}
