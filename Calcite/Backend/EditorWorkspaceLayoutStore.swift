import Foundation

/// Persists window-level visibility that is not encoded in the sectional layout tree.
enum EditorWorkspaceLayoutStore {
  private static let defaultSidebarVisibility = true

  static func loadSidebarVisibility(
    for workspaceURL: URL,
    defaults: UserDefaults = .standard
  ) -> Bool {
    let defaultsKey = key("sidebarVisible", workspaceURL)
    guard defaults.object(forKey: defaultsKey) != nil else {
      return defaultSidebarVisibility
    }
    return defaults.bool(forKey: defaultsKey)
  }

  static func saveSidebarVisibility(
    _ isVisible: Bool,
    for workspaceURL: URL,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(isVisible, forKey: key("sidebarVisible", workspaceURL))
  }

  private static func key(_ component: String, _ workspaceURL: URL) -> String {
    "calcite.workspaceLayout.\(component).\(workspaceID(for: workspaceURL))"
  }

  private static func workspaceID(for workspaceURL: URL) -> String {
    workspaceURL.standardizedFileURL.path
      .replacingOccurrences(of: "/", with: "%2F")
  }
}
