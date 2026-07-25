#if os(macOS)
  import AppKit
  import Foundation

  enum EditorExternalTerminalApplication: String, CaseIterable, Identifiable {
    case automatic
    case terminal
    case iTerm2
    case warp
    case wezTerm
    case alacritty
    case kitty
    case custom

    var id: String { rawValue }

    var title: String {
      switch self {
      case .automatic: "Automatic"
      case .terminal: "Terminal"
      case .iTerm2: "iTerm2"
      case .warp: "Warp"
      case .wezTerm: "WezTerm"
      case .alacritty: "Alacritty"
      case .kitty: "kitty"
      case .custom: "Custom Command"
      }
    }

    var bundleIdentifier: String? {
      switch self {
      case .terminal: "com.apple.Terminal"
      case .iTerm2: "com.googlecode.iterm2"
      case .warp: "dev.warp.Warp-Stable"
      case .wezTerm: "com.github.wez.wezterm"
      case .alacritty: "org.alacritty"
      case .kitty: "net.kovidgoyal.kitty"
      case .automatic, .custom: nil
      }
    }
  }

  enum EditorExternalTerminalPreferences {
    static let applicationKey = "externalTerminalApplication"
    static let customCommandKey = "externalTerminalCommand"

    static var application: EditorExternalTerminalApplication {
      get {
        UserDefaults.standard.string(forKey: applicationKey)
          .flatMap(EditorExternalTerminalApplication.init(rawValue:)) ?? .automatic
      }
      set { UserDefaults.standard.set(newValue.rawValue, forKey: applicationKey) }
    }

    static var customCommand: String {
      get { UserDefaults.standard.string(forKey: customCommandKey) ?? "" }
      set { UserDefaults.standard.set(newValue, forKey: customCommandKey) }
    }

    static func resolvedApplicationURL(
      workspace: NSWorkspace = .shared
    ) -> URL? {
      let selected = application
      if let identifier = selected.bundleIdentifier,
        let url = workspace.urlForApplication(withBundleIdentifier: identifier)
      {
        return url
      }
      guard selected == .automatic else { return nil }
      let preferred: [EditorExternalTerminalApplication] = [
        .iTerm2, .warp, .wezTerm, .alacritty, .kitty, .terminal,
      ]
      return preferred.lazy.compactMap { choice in
        choice.bundleIdentifier.flatMap(workspace.urlForApplication(withBundleIdentifier:))
      }.first
    }

    static func expandedCustomCommand(for workspaceURL: URL) -> String? {
      let command = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !command.isEmpty else { return nil }
      let quotedPath = shellQuote(workspaceURL.path)
      if command.contains("{path}") {
        return command.replacingOccurrences(of: "{path}", with: quotedPath)
      }
      return "\(command) \(quotedPath)"
    }

    private static func shellQuote(_ value: String) -> String {
      "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
  }
#endif
