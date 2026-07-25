import Foundation

nonisolated enum EditorXcodeSchemeSelectionStore {
  static func load(workspaceURL: URL, defaults: UserDefaults = .standard) -> String? {
    defaults.string(forKey: key(for: workspaceURL))
  }

  static func save(_ scheme: String?, workspaceURL: URL, defaults: UserDefaults = .standard) {
    if let scheme, !scheme.isEmpty {
      defaults.set(scheme, forKey: key(for: workspaceURL))
    } else {
      defaults.removeObject(forKey: key(for: workspaceURL))
    }
  }

  private static func key(for workspaceURL: URL) -> String {
    "calcite.xcodeScheme.\(stableKey(workspaceURL))"
  }
}

nonisolated enum EditorPythonInterpreterSelectionStore {
  static func load(workspaceURL: URL, defaults: UserDefaults = .standard) -> URL? {
    guard let path = defaults.string(forKey: key(for: workspaceURL)), !path.isEmpty else {
      return nil
    }
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
      clear(workspaceURL: workspaceURL, defaults: defaults)
      return nil
    }
    return url
  }

  static func save(_ url: URL?, workspaceURL: URL, defaults: UserDefaults = .standard) {
    if let url {
      defaults.set(url.standardizedFileURL.path, forKey: key(for: workspaceURL))
    } else {
      clear(workspaceURL: workspaceURL, defaults: defaults)
    }
  }

  static func clear(workspaceURL: URL, defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key(for: workspaceURL))
  }

  private static func key(for workspaceURL: URL) -> String {
    "calcite.pythonInterpreter.\(stableKey(workspaceURL))"
  }
}

nonisolated private func stableKey(_ url: URL) -> String {
  Data(url.standardizedFileURL.path.utf8).base64EncodedString()
}
