import EditorServices
import Foundation

/// Supplies only the launch arguments that genuinely differ by language.
/// Session lifecycle, breakpoint synchronization, and DAP state handling remain shared.
protocol EditorDebugLanguageStrategy: Sendable {
  var languages: Set<EditorLanguage> { get }

  func configureLaunch(
    language: EditorLanguage,
    values: inout [String: DAPValue],
    program: String,
    arguments: DAPValue,
    workspaceURL: URL
  )
}

enum EditorDebugLanguageStrategyRegistry {
  private static let strategies: [any EditorDebugLanguageStrategy] = [
    EditorLLDBDebugLanguageStrategy(),
    EditorGoDebugLanguageStrategy(),
    EditorPythonDebugLanguageStrategy(),
    EditorRubyDebugLanguageStrategy(),
    EditorGenericDebugLanguageStrategy(),
  ]

  static func strategy(for language: EditorLanguage) -> any EditorDebugLanguageStrategy {
    strategies.first { $0.languages.contains(language) }
      ?? EditorGenericDebugLanguageStrategy()
  }
}

private struct EditorLLDBDebugLanguageStrategy: EditorDebugLanguageStrategy {
  let languages: Set<EditorLanguage> = [
    .rust, .swift, .c, .cpp, .objectiveC, .objectiveCPP, .zig,
  ]

  func configureLaunch(
    language: EditorLanguage,
    values: inout [String: DAPValue],
    program: String,
    arguments: DAPValue,
    workspaceURL: URL
  ) {
    values["program"] = .string(program)
    values["sourceLanguages"] = .array([.string(language.rawValue)])

    // Calcite does not yet expose a DAP runInTerminal host to EditorServices.
    // CodeLLDB's console target keeps the debug launch fully functional instead
    // of advertising an unsupported reverse request and stalling at launch.
    values["terminal"] = .string("console")
  }

}

private struct EditorGoDebugLanguageStrategy: EditorDebugLanguageStrategy {
  let languages: Set<EditorLanguage> = [.go]

  func configureLaunch(
    language: EditorLanguage,
    values: inout [String: DAPValue],
    program: String,
    arguments: DAPValue,
    workspaceURL: URL
  ) {
    values["program"] = .string(program)
    values["mode"] = .string("debug")
  }
}

private struct EditorPythonDebugLanguageStrategy: EditorDebugLanguageStrategy {
  let languages: Set<EditorLanguage> = [.python]

  func configureLaunch(
    language: EditorLanguage,
    values: inout [String: DAPValue],
    program: String,
    arguments: DAPValue,
    workspaceURL: URL
  ) {
    values["program"] = .string(program)
    values["justMyCode"] = .bool(false)
    values["console"] = .string("internalConsole")
  }
}

private struct EditorRubyDebugLanguageStrategy: EditorDebugLanguageStrategy {
  let languages: Set<EditorLanguage> = [.ruby]

  func configureLaunch(
    language: EditorLanguage,
    values: inout [String: DAPValue],
    program: String,
    arguments: DAPValue,
    workspaceURL: URL
  ) {
    values["program"] = .string(program)
    values["programArgs"] = arguments
    values["useBundler"] = .bool(true)
  }
}

private struct EditorGenericDebugLanguageStrategy: EditorDebugLanguageStrategy {
  let languages: Set<EditorLanguage> = Set(EditorLanguage.allCases)

  func configureLaunch(
    language: EditorLanguage,
    values: inout [String: DAPValue],
    program: String,
    arguments: DAPValue,
    workspaceURL: URL
  ) {
    values["program"] = .string(program)
  }
}
