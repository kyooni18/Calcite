import EditorServices
import Foundation

nonisolated enum EditorDebugLaunchTarget: Equatable, Sendable {
  case project
  case currentFile(URL)
}

nonisolated struct EditorStandaloneDebugTarget: Sendable {
  let fileURL: URL
  let language: EditorLanguage
  let buildCommand: EditorBuildCommand?
  let programPath: String
  let workingDirectory: URL

  static func resolve(
    fileURL: URL,
    language: EditorLanguage
  ) throws -> Self {
    let file = fileURL.standardizedFileURL
    guard let plan = EditorBuildDiscovery.singleFilePlan(fileURL: file) else {
      throw EditorExecutionIntegrityError.configuration(
        "No standalone execution provider is available for \(file.lastPathComponent)."
      )
    }

    let buildCommand = plan.command(for: .build)
    let runCommand = plan.command(for: .run)
    let programPath: String
    switch language {
    case .swift, .c, .cpp, .objectiveC, .objectiveCPP, .rust, .zig:
      guard let runCommand else {
        throw EditorExecutionIntegrityError.configuration(
          "The standalone provider did not produce a debuggable executable for \(file.lastPathComponent)."
        )
      }
      let executable = URL(
        fileURLWithPath: runCommand.executable,
        relativeTo: runCommand.workingDirectory
      ).standardizedFileURL
      guard runCommand.executable.contains("/") else {
        throw EditorExecutionIntegrityError.configuration(
          "The standalone provider did not produce a debuggable executable for \(file.lastPathComponent)."
        )
      }
      programPath = executable.path
    case .go, .python, .dart:
      programPath = file.path
    case .csharp, .fsharp:
      throw EditorExecutionIntegrityError.configuration(
        "Standalone Live Debug for \(language.rawValue) requires a project build that emits a debug artifact. Run the file normally or select a project debug configuration."
      )
    default:
      throw EditorExecutionIntegrityError.configuration(
        "No debug adapter is available for standalone \(language.rawValue) files. The file can still be run with Run Current File."
      )
    }

    return Self(
      fileURL: file,
      language: language,
      buildCommand: buildCommand,
      programPath: programPath,
      workingDirectory: file.deletingLastPathComponent()
    )
  }
}
