import Foundation

/// Persists the last explicitly opened project without silently choosing a broad user directory.
enum EditorWorkspaceSelectionStore {
  private static let key = "calcite.lastWorkspacePath"

  static func load() -> URL? {
    guard let rawPath = UserDefaults.standard.string(forKey: key), !rawPath.isEmpty else {
      return nil
    }
    let url = URL(fileURLWithPath: rawPath).standardizedFileURL
    guard validationError(for: url) == nil else {
      clear()
      return nil
    }
    return url
  }

  static func save(_ url: URL) {
    UserDefaults.standard.set(url.standardizedFileURL.path, forKey: key)
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: key)
  }

  /// Rejects roots that are valid folders but too broad to be treated as an IDE workspace.
  static func validationError(for candidate: URL) -> String? {
    let url = candidate.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      FileManager.default.isReadableFile(atPath: url.path)
    else {
      return "The selected item is not a readable directory."
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    let unsafeRoots = Set(
      [
        URL(fileURLWithPath: "/", isDirectory: true).standardizedFileURL.path,
        home.path,
        home.appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL.path,
        home.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL.path,
        home.appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL.path,
        home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path,
      ]
    )
    guard !unsafeRoots.contains(url.path) else {
      return
        "Choose the project folder itself rather than a broad system folder such as Desktop, Downloads, Documents, or your home directory."
    }
    return nil
  }
}
