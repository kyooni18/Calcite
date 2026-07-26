import Foundation

nonisolated enum EditorInterface: String, CaseIterable, Identifiable, Sendable {
  case builtIn
  case calciteVim
  case neovim
  case vim

  var id: String { rawValue }

  var title: String {
    switch self {
    case .builtIn: "Default"
    case .calciteVim: "Calcite Vim"
    case .neovim: "Neovim"
    case .vim: "Vim"
    }
  }

  var executableName: String? {
    switch self {
    case .builtIn, .calciteVim: nil
    case .neovim: "nvim"
    case .vim: "vim"
    }
  }

  var usesTerminalEditor: Bool {
    self == .neovim || self == .vim
  }

  var usesCalciteVim: Bool {
    self == .calciteVim
  }

  var next: EditorInterface {
    let modes = Self.allCases
    guard let index = modes.firstIndex(of: self) else { return .builtIn }
    return modes[(index + 1) % modes.count]
  }
}

nonisolated enum EditorInterfacePreferences {
  static let interfaceKey = "editorInterface"
  static let neovimLaunchCommandKey = "neovimLaunchCommand"
  static let vimLaunchCommandKey = "vimLaunchCommand"
  static let terminalLeaderKey = "terminalEditorLeader"
  static let showsEditorTabBarKey = "showsEditorTabBar"

  static var selectedInterface: EditorInterface {
    EditorInterface(
      rawValue: UserDefaults.standard.string(forKey: interfaceKey)
        ?? EditorInterface.builtIn.rawValue
    ) ?? .builtIn
  }

  static func executableURL(for interface: EditorInterface) -> URL? {
    guard let name = interface.executableName else { return nil }

    let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let pathDirectories = environmentPath.split(separator: ":").map(String.init)
    let commonDirectories = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
    ]

    for directory in pathDirectories + commonDirectories {
      let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
      if FileManager.default.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
      }
    }
    return nil
  }

  static func launchCommand(
    interface: EditorInterface,
    fileURL: URL,
    workspaceURL: URL,
    defaults: UserDefaults = .standard
  ) -> String? {
    let leader = normalizedTerminalLeader(defaults: defaults)
    let leaderCommand =
      "let mapleader = '\(vimString(leader))' | "
      + "let maplocalleader = '\(vimString(leader))'"
    let templateKey =
      interface == .neovim ? neovimLaunchCommandKey : vimLaunchCommandKey
    let template = defaults.string(forKey: templateKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if !template.isEmpty {
      let executable = executableURL(for: interface)?.path
        ?? interface.executableName
        ?? ""
      var command = template
        .replacingOccurrences(of: "{executable}", with: shellQuote(executable))
        .replacingOccurrences(of: "{file}", with: shellQuote(fileURL.standardizedFileURL.path))
        .replacingOccurrences(
          of: "{workspace}", with: shellQuote(workspaceURL.standardizedFileURL.path))
        .replacingOccurrences(of: "{leader}", with: shellQuote(leader))
        .replacingOccurrences(of: "{leaderCommand}", with: shellQuote(leaderCommand))

      // A custom value is commonly a shell alias or function name (for example
      // `edit`). Treat it as the editor invocation and retain Calcite's required
      // Vim setup and document argument. Placeholders remain available when a
      // command needs to control either argument explicitly.
      if !template.contains("{leaderCommand}") {
        command += " --cmd \(shellQuote(leaderCommand))"
      }
      if !template.contains("{file}") {
        command += " -- \(shellQuote(fileURL.standardizedFileURL.path))"
      }
      return command
    }

    guard let executableURL = executableURL(for: interface) else { return nil }
    return [executableURL.path, "--cmd", leaderCommand, "--", fileURL.standardizedFileURL.path]
      .map(shellQuote)
      .joined(separator: " ")
  }

  static func normalizedTerminalLeader(defaults: UserDefaults = .standard) -> String {
    let value = defaults.string(forKey: terminalLeaderKey) ?? "\\"
    guard let leader = value.first, !leader.isWhitespace else { return "\\" }
    return String(leader)
  }

  static func selectNext(defaults: UserDefaults = .standard) {
    let current =
      EditorInterface(
        rawValue: defaults.string(forKey: interfaceKey)
          ?? EditorInterface.builtIn.rawValue
      ) ?? .builtIn
    defaults.set(current.next.rawValue, forKey: interfaceKey)
  }

  private static func vimString(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
  }

  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
