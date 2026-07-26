import Foundation

nonisolated enum EditorInterface: String, CaseIterable, Identifiable, Sendable {
  case builtIn
  case neovim
  case vim

  var id: String { rawValue }

  var title: String {
    switch self {
    case .builtIn: "Built-in Editor"
    case .neovim: "Neovim (Terminal)"
    case .vim: "Vim (Terminal)"
    }
  }

  var executableName: String? {
    switch self {
    case .builtIn: nil
    case .neovim: "nvim"
    case .vim: "vim"
    }
  }

  var usesTerminalEditor: Bool {
    self != .builtIn
  }
}

nonisolated enum EditorInterfacePreferences {
  static let interfaceKey = "editorInterface"

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
    fileURL: URL
  ) -> String? {
    guard let executableURL = executableURL(for: interface) else { return nil }
    return [executableURL.path, "--", fileURL.standardizedFileURL.path]
      .map(shellQuote)
      .joined(separator: " ")
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
