import EditorServices
import Foundation

enum EditorDebugLaunchArguments {
  static func make(
    language: EditorLanguage,
    adapterID: String,
    configuration: EditorDebugConfiguration,
    workspaceURL: URL
  ) -> DAPValue {
    let program = NSString(string: configuration.programPath).expandingTildeInPath
    let workingDirectory = configuration.workingDirectory
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let cwd = workingDirectory.isEmpty ? workspaceURL.path : workingDirectory
    let arguments = DAPValue.array(configuration.argumentList.map { .string($0) })

    var values: [String: DAPValue] = [
      "name": .string("Calcite Debug"),
      "type": .string(adapterID),
      "request": .string("launch"),
      "args": arguments,
      "cwd": .string(cwd),
      "stopOnEntry": .bool(configuration.stopOnEntry),
    ]

    EditorDebugLanguageStrategyRegistry.strategy(for: language).configureLaunch(
      language: language,
      values: &values,
      program: program,
      arguments: arguments,
      workspaceURL: workspaceURL
    )
    return .object(values)
  }
}
