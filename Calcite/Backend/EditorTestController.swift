import Combine
import EditorServices
import Foundation

nonisolated enum EditorTestStatus: String, Codable, Sendable {
  case passed
  case failed
  case skipped
  case cancelled
  case unknown
}

nonisolated struct EditorTestResult: Identifiable, Hashable, Codable, Sendable {
  var id: String
  var suite: String
  var name: String
  var status: EditorTestStatus
  var durationSeconds: Double?
  var failureLocation: EditorExecutionSourceLocation?
  var message: String?
}

@MainActor
final class EditorTestController: ObservableObject {
  enum Phase: Equatable {
    case idle
    case running(String)
    case completed(passed: Int, failed: Int, skipped: Int)
    case failed(String)
  }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var results: [EditorTestResult] = []
  @Published private(set) var lastScopeDescription = "All Tests"

  private unowned let buildController: EditorBuildController

  init(buildController: EditorBuildController) {
    self.buildController = buildController
  }

  @discardableResult
  func runAll(sourceSnapshot: EditorPreparedSourceSnapshot?) async -> Bool {
    guard let command = buildController.plan.command(for: .test) else {
      phase = .failed("No test task was detected for this project.")
      return false
    }
    return await run(command, scope: "All Tests", sourceSnapshot: sourceSnapshot)
  }

  @discardableResult
  func runCurrentFile(
    _ fileURL: URL,
    sourceSnapshot: EditorPreparedSourceSnapshot?
  ) async -> Bool {
    guard let base = buildController.plan.command(for: .test) else {
      phase = .failed("No test task was detected for this project.")
      return false
    }
    let command = Self.filteredCommand(
      base,
      projectKind: buildController.plan.projectKind,
      fileURL: fileURL,
      symbol: nil
    )
    return await run(
      command,
      scope: "Tests in \(fileURL.lastPathComponent)",
      sourceSnapshot: sourceSnapshot
    )
  }

  @discardableResult
  func runCurrentSymbol(
    _ symbol: String,
    fileURL: URL?,
    sourceSnapshot: EditorPreparedSourceSnapshot?
  ) async -> Bool {
    guard let base = buildController.plan.command(for: .test) else {
      phase = .failed("No test task was detected for this project.")
      return false
    }
    let command = Self.filteredCommand(
      base,
      projectKind: buildController.plan.projectKind,
      fileURL: fileURL,
      symbol: symbol
    )
    return await run(
      command,
      scope: "Test \(symbol)",
      sourceSnapshot: sourceSnapshot
    )
  }

  @discardableResult
  func runChangedFiles(
    _ fileURLs: [URL],
    sourceSnapshot: EditorPreparedSourceSnapshot?
  ) async -> Bool {
    let files = Array(
      Dictionary(
        fileURLs.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) },
        uniquingKeysWith: { first, _ in first }
      ).values
    ).sorted { $0.path < $1.path }
    guard !files.isEmpty else {
      phase = .failed("There are no changed files to test.")
      return false
    }
    guard let base = buildController.plan.command(for: .test) else {
      phase = .failed("No test task was detected for this project.")
      return false
    }
    let command = Self.changedFilesCommand(
      base,
      projectKind: buildController.plan.projectKind,
      fileURLs: files
    )
    return await run(
      command,
      scope: "Changed Files (\(files.count))",
      sourceSnapshot: sourceSnapshot
    )
  }

  @discardableResult
  func rerunFailed(sourceSnapshot: EditorPreparedSourceSnapshot?) async -> Bool {
    let failed = results.filter { $0.status == .failed }
    guard !failed.isEmpty else {
      phase = .failed("There are no failed tests to rerun.")
      return false
    }
    guard let base = buildController.plan.command(for: .test) else {
      phase = .failed("No test task was detected for this project.")
      return false
    }
    let command = Self.failedTestsCommand(
      base,
      projectKind: buildController.plan.projectKind,
      failed: failed
    )
    return await run(command, scope: "Failed Tests", sourceSnapshot: sourceSnapshot)
  }

  func clear() {
    results.removeAll(keepingCapacity: true)
    phase = .idle
  }

  private func run(
    _ command: EditorBuildCommand,
    scope: String,
    sourceSnapshot: EditorPreparedSourceSnapshot?
  ) async -> Bool {
    guard !buildController.phase.isRunning else { return false }
    lastScopeDescription = scope
    phase = .running(scope)
    results.removeAll(keepingCapacity: true)
    let succeeded = await buildController.run(command, sourceSnapshot: sourceSnapshot)
    results = EditorTestOutputParser.parse(
      buildController.output,
      workingDirectory: command.workingDirectory
    )
    let passed = results.count { $0.status == .passed }
    let failed = results.count { $0.status == .failed }
    let skipped = results.count { $0.status == .skipped }
    if succeeded || !results.isEmpty {
      phase = .completed(passed: passed, failed: failed, skipped: skipped)
    } else {
      phase = .failed("The test task did not produce a successful result.")
    }
    return succeeded && failed == 0
  }

  private static func filteredCommand(
    _ command: EditorBuildCommand,
    projectKind: EditorProjectBuildKind,
    fileURL: URL?,
    symbol: String?
  ) -> EditorBuildCommand {
    var command = command
    command = Self.command(command, identifiedBy: ".filtered.\(UUID().uuidString)")
    command.title =
      symbol.map { "Test \($0)" }
      ?? fileURL.map { "Test \($0.lastPathComponent)" }
      ?? "Filtered Tests"

    let relativeFile = fileURL.flatMap {
      $0.path.hasPrefix(command.workingDirectory.path)
        ? String($0.path.dropFirst(command.workingDirectory.path.count))
          .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        : $0.path
    }
    let filter = symbol ?? fileURL?.deletingPathExtension().lastPathComponent

    switch projectKind {
    case .swiftPackage:
      if let filter, !filter.isEmpty { command.arguments += ["--filter", filter] }
    case .rustCargo:
      if let filter, !filter.isEmpty { command.arguments.append(filter) }
    case .goModule:
      if let fileURL {
        command.workingDirectory = fileURL.deletingLastPathComponent()
      }
      if let filter, !filter.isEmpty { command.arguments += ["-run", filter] }
    case .python:
      if let relativeFile { command.arguments.append(relativeFile) }
      if let symbol, !symbol.isEmpty { command.arguments += ["-k", symbol] }
    case .nodePackage:
      if let relativeFile { command.arguments += ["--", relativeFile] }
      if let symbol, !symbol.isEmpty { command.arguments += ["-t", symbol] }
    case .gradle:
      if let filter, !filter.isEmpty { command.arguments += ["--tests", "*\(filter)*"] }
    case .maven:
      if let filter, !filter.isEmpty { command.arguments.append("-Dtest=*\(filter)*") }
    case .xcode, .zig, .cmake, .make, .generic:
      break
    }
    return command
  }

  private static func changedFilesCommand(
    _ command: EditorBuildCommand,
    projectKind: EditorProjectBuildKind,
    fileURLs: [URL]
  ) -> EditorBuildCommand {
    var command = command
    command = Self.command(command, identifiedBy: ".changed.\(UUID().uuidString)")
    command.title = "Test Changed Files"
    let relativeFiles = fileURLs.map { file -> String in
      let root = command.workingDirectory.standardizedFileURL.path
      let path = file.standardizedFileURL.path
      guard path.hasPrefix(root + "/") else { return path }
      return String(path.dropFirst(root.count + 1))
    }
    let stems = fileURLs.map { $0.deletingPathExtension().lastPathComponent }

    switch projectKind {
    case .swiftPackage:
      command.arguments += ["--filter", stems.joined(separator: "|")]
    case .rustCargo:
      if let first = stems.first { command.arguments.append(first) }
    case .goModule:
      let directories = Set(fileURLs.map { $0.deletingLastPathComponent().standardizedFileURL })
      if directories.count == 1, let directory = directories.first {
        command.workingDirectory = directory
      }
    case .python:
      command.arguments += relativeFiles
    case .nodePackage:
      command.arguments += ["--"] + relativeFiles
    case .gradle:
      for stem in stems { command.arguments += ["--tests", "*\(stem)*"] }
    case .maven:
      command.arguments.append("-Dtest=" + stems.joined(separator: ","))
    case .xcode, .zig, .cmake, .make, .generic:
      break
    }
    return command
  }

  private static func failedTestsCommand(
    _ command: EditorBuildCommand,
    projectKind: EditorProjectBuildKind,
    failed: [EditorTestResult]
  ) -> EditorBuildCommand {
    var command = command
    command = Self.command(command, identifiedBy: ".failed.\(UUID().uuidString)")
    command.title = "Rerun Failed Tests"
    let names = failed.map(\.name)
    switch projectKind {
    case .swiftPackage:
      command.arguments += ["--filter", names.joined(separator: "|")]
    case .rustCargo:
      if let first = names.first { command.arguments.append(first) }
    case .goModule:
      command.arguments += ["-run", names.joined(separator: "|")]
    case .python:
      command.arguments += ["-k", names.joined(separator: " or ")]
    case .nodePackage:
      command.arguments += ["--", "-t", names.joined(separator: "|")]
    case .gradle:
      for name in names { command.arguments += ["--tests", "*\(name)"] }
    case .maven:
      command.arguments.append("-Dtest=" + names.joined(separator: ","))
    case .xcode, .zig, .cmake, .make, .generic:
      break
    }
    return command
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
}

nonisolated enum EditorTestOutputParser {
  private static func patterns()
    ->
    [(NSRegularExpression, (_ match: NSTextCheckingResult, _ line: String) -> EditorTestResult?)]
  {
        func regex(_ value: String) -> NSRegularExpression {
          try! NSRegularExpression(pattern: value)
        }
        return [
          (
            regex(
              #"Test Case ['\"](?:-\[[^ ]+ )?([^'\"]+?)(?:\])?['\"] (passed|failed|skipped)(?: \(([0-9.]+) seconds\))?"#
            ),
            { match, line in
              result(match, line: line, nameGroup: 1, statusGroup: 2, durationGroup: 3)
            }
          ),
          (
            regex(#"^test ([^ ]+) \.\.\. (ok|FAILED|ignored)$"#),
            { match, line in
              result(match, line: line, nameGroup: 1, statusGroup: 2, durationGroup: nil)
            }
          ),
          (
            regex(#"^--- (PASS|FAIL|SKIP): ([^ ]+)(?: \(([0-9.]+)s\))?"#),
            { match, line in
              result(match, line: line, nameGroup: 2, statusGroup: 1, durationGroup: 3)
            }
          ),
          (
            regex(#"^([^ ]+::[^ ]+) (PASSED|FAILED|SKIPPED)(?: \[[^\]]+\])?$"#),
            { match, line in
              result(match, line: line, nameGroup: 1, statusGroup: 2, durationGroup: nil)
            }
          ),
          (
            regex(#"^[[:space:]]*[✓✔] (.+?)(?: \(([0-9.]+) ?m?s\))?$"#),
            { match, line in
              result(match, line: line, nameGroup: 1, fixedStatus: .passed, durationGroup: 2)
            }
          ),
          (
            regex(#"^[[:space:]]*[✕×] (.+)$"#),
            { match, line in
              result(match, line: line, nameGroup: 1, fixedStatus: .failed, durationGroup: nil)
            }
          ),
        ]
  }

  static func parse(_ output: String, workingDirectory: URL) -> [EditorTestResult] {
    var values: [EditorTestResult] = []
    var seen = Set<String>()
    for line in output.split(whereSeparator: \Character.isNewline).map(String.init) {
      let range = NSRange(line.startIndex..<line.endIndex, in: line)
      for (pattern, builder) in patterns() {
        guard let match = pattern.firstMatch(in: line, range: range),
          var value = builder(match, line)
        else { continue }
        value.failureLocation = failureLocation(in: line, workingDirectory: workingDirectory)
        if seen.insert(value.id).inserted { values.append(value) }
        break
      }
    }
    return values
  }

  private static func result(
    _ match: NSTextCheckingResult,
    line: String,
    nameGroup: Int,
    statusGroup: Int? = nil,
    fixedStatus: EditorTestStatus? = nil,
    durationGroup: Int?
  ) -> EditorTestResult? {
    guard let name = group(match, nameGroup, in: line) else { return nil }
    let status = fixedStatus ?? group(match, statusGroup ?? 0, in: line).map(status) ?? .unknown
    let duration = durationGroup.flatMap { group(match, $0, in: line) }.flatMap(Double.init)
    let suite =
      name.contains(".")
      ? String(name.split(separator: ".").dropLast().joined(separator: ".")) : "Tests"
    return EditorTestResult(
      id: suite + "::" + name,
      suite: suite,
      name: name,
      status: status,
      durationSeconds: duration,
      failureLocation: nil,
      message: status == .failed ? line : nil
    )
  }

  private static func group(
    _ match: NSTextCheckingResult,
    _ index: Int,
    in string: String
  ) -> String? {
    guard index < match.numberOfRanges else { return nil }
    let range = match.range(at: index)
    guard range.location != NSNotFound, let value = Range(range, in: string) else { return nil }
    return String(string[value])
  }

  private static func status(_ value: String) -> EditorTestStatus {
    switch value.lowercased() {
    case "passed", "pass", "ok": return .passed
    case "failed", "fail": return .failed
    case "skipped", "skip", "ignored": return .skipped
    case "cancelled", "canceled": return .cancelled
    default: return .unknown
    }
  }

  private static func failureLocation(
    in line: String,
    workingDirectory: URL
  ) -> EditorExecutionSourceLocation? {
    let pattern = try! NSRegularExpression(
      pattern: #"((?:/|[A-Za-z]:\\)[^:\n]+):([0-9]+)(?::([0-9]+))?"#)
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = pattern.firstMatch(in: line, range: range),
      let path = group(match, 1, in: line),
      let lineValue = group(match, 2, in: line).flatMap(Int.init)
    else { return nil }
    let url =
      path.hasPrefix("/")
      ? URL(fileURLWithPath: path)
      : workingDirectory.appendingPathComponent(path)
    return EditorExecutionSourceLocation(
      url: url,
      line: lineValue,
      column: group(match, 3, in: line).flatMap(Int.init) ?? 1
    )
  }
}
