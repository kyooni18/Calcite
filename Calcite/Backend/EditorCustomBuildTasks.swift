import EditorServices
import Foundation

struct EditorCustomBuildTaskLoadResult {
  var commands: [EditorBuildCommand]
  var warnings: [String]
}

enum EditorCustomBuildTaskStore {
  static func load(workspaceURL: URL) -> EditorCustomBuildTaskLoadResult {
    let url = taskFileURL(workspaceURL: workspaceURL)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return EditorCustomBuildTaskLoadResult(commands: [], warnings: [])
    }

    do {
      let data = try Data(contentsOf: url)
      let file = try JSONDecoder().decode(TaskFile.self, from: data)
      var commands: [EditorBuildCommand] = []
      var warnings: [String] = []
      var identifiers: Set<String> = []

      for (index, task) in file.tasks.enumerated() {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
          warnings.append("Custom build task #\(index + 1) has no title and was ignored.")
          continue
        }
        let identifier = normalizedIdentifier(task.id, fallback: title, index: index)
        guard identifiers.insert(identifier).inserted else {
          warnings.append("Custom build task ID '\(identifier)' is duplicated and was ignored.")
          continue
        }
        guard !(task.arguments ?? []).isEmpty || task.executable != nil else {
          warnings.append("Custom build task '\(title)' has no command and was ignored.")
          continue
        }

        let workingDirectory = resolvedWorkingDirectory(task, workspaceURL: workspaceURL)
        let invocation = resolvedInvocation(task, workingDirectory: workingDirectory)
        commands.append(
          EditorBuildCommand(
            id: "custom-\(identifier)",
            title: title,
            kind: task.kind ?? .custom,
            executable: invocation.executable,
            arguments: invocation.arguments,
            workingDirectory: workingDirectory
          )
        )
      }
      return EditorCustomBuildTaskLoadResult(commands: commands, warnings: warnings)
    } catch {
      return EditorCustomBuildTaskLoadResult(
        commands: [],
        warnings: ["Could not load .calcite/tasks.json: \(error.localizedDescription)"]
      )
    }
  }

  static func merge(
    detected: EditorBuildPlan,
    workspaceURL: URL
  ) -> (plan: EditorBuildPlan, warnings: [String]) {
    let custom = load(workspaceURL: workspaceURL)
    guard !custom.commands.isEmpty else { return (detected, custom.warnings) }

    var commands = detected.commands
    for command in custom.commands {
      if let index = commands.firstIndex(where: { $0.id == command.id }) {
        commands[index] = command
      } else {
        commands.append(command)
      }
    }
    return (
      EditorBuildPlan(projectKind: detected.projectKind, commands: commands),
      custom.warnings
    )
  }

  static func createTemplateIfNeeded(workspaceURL: URL) throws -> URL {
    let url = taskFileURL(workspaceURL: workspaceURL)
    guard !FileManager.default.fileExists(atPath: url.path) else { return url }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let template = """
      {
        "tasks": [
          {
            "id": "project-check",
            "title": "Project Check",
            "kind": "check",
            "executable": "echo",
            "arguments": ["Configure this task in .calcite/tasks.json"],
            "workingDirectory": "."
          }
        ]
      }
      """
    try template.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  static func taskFileURL(workspaceURL: URL) -> URL {
    workspaceURL.standardizedFileURL.appendingPathComponent(".calcite/tasks.json")
  }

  private struct TaskFile: Decodable {
    var tasks: [TaskDefinition]

    init(from decoder: Decoder) throws {
      if let array = try? decoder.singleValueContainer().decode([TaskDefinition].self) {
        tasks = array
        return
      }
      let container = try decoder.container(keyedBy: CodingKeys.self)
      tasks = try container.decode([TaskDefinition].self, forKey: .tasks)
    }

    private enum CodingKeys: String, CodingKey {
      case tasks
    }
  }

  private struct TaskDefinition: Decodable {
    var id: String?
    var title: String
    var kind: EditorBuildTaskKind?
    var executable: String?
    var arguments: [String]?
    var workingDirectory: String?
  }

  private static func resolvedInvocation(
    _ task: TaskDefinition,
    workingDirectory: URL
  ) -> (executable: String, arguments: [String]) {
    let configured = task.executable?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let arguments = task.arguments ?? []
    guard !configured.isEmpty else {
      guard let executable = arguments.first else { return ("", []) }
      return (executable, Array(arguments.dropFirst()))
    }

    let expanded = NSString(string: configured).expandingTildeInPath
    if expanded.contains("/") {
      let url = URL(fileURLWithPath: expanded, relativeTo: workingDirectory).standardizedFileURL
      return (url.path, arguments)
    }
    return (expanded, arguments)
  }

  private static func resolvedWorkingDirectory(
    _ task: TaskDefinition,
    workspaceURL: URL
  ) -> URL {
    guard let value = task.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return workspaceURL.standardizedFileURL }
    let expanded = NSString(string: value).expandingTildeInPath
    return URL(fileURLWithPath: expanded, relativeTo: workspaceURL).standardizedFileURL
  }

  private static func normalizedIdentifier(
    _ configured: String?,
    fallback: String,
    index: Int
  ) -> String {
    let source: String
    if let configured, !configured.isEmpty {
      source = configured
    } else {
      source = fallback
    }
    let mapped = String(
      source.lowercased().map { character in
        character.isLetter || character.isNumber ? character : "-"
      }
    )
    let value = mapped.split(separator: "-").joined(separator: "-")
    return value.isEmpty ? "task-\(index + 1)" : value
  }
}
