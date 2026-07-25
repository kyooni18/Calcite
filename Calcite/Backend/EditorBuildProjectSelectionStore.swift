import Foundation

/// Stores an optional build-project folder for each opened workspace.
nonisolated enum EditorBuildProjectSelectionStore {
  static func load(workspaceURL: URL, defaults: UserDefaults = .standard) -> URL? {
    guard let path = defaults.string(forKey: key(for: workspaceURL)), !path.isEmpty else {
      return nil
    }
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      FileManager.default.isReadableFile(atPath: url.path)
    else {
      clear(workspaceURL: workspaceURL, defaults: defaults)
      return nil
    }
    return url
  }

  static func save(_ url: URL, workspaceURL: URL, defaults: UserDefaults = .standard) {
    defaults.set(url.standardizedFileURL.path, forKey: key(for: workspaceURL))
  }

  static func clear(workspaceURL: URL, defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key(for: workspaceURL))
  }

  private static func key(for workspaceURL: URL) -> String {
    let encoded = Data(workspaceURL.standardizedFileURL.path.utf8).base64EncodedString()
    return "calcite.buildProject.\(encoded)"
  }
}
