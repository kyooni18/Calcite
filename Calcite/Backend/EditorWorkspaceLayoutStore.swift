import Foundation

/// Persists lightweight workbench layout choices per workspace.
///
/// Dimensions are stored as user preferences rather than as layout constraints. Each
/// responsive view derives its actual size from the current window and clamps the stored
/// preference locally, preventing an old large-window value from overflowing a small window.
enum EditorWorkspaceLayoutStore {
  private enum Defaults {
    static let sidebarVisible = true
    static let sidebarWidth = 240.0
    static let bottomPanelHeight = 220.0
  }

  static func loadBottomPanel(
    for workspaceURL: URL, defaults: UserDefaults = .standard
  ) -> EditorBottomPanel? {
    guard let rawValue = defaults.string(forKey: key("bottomPanel", workspaceURL))
    else {
      return nil
    }
    return EditorBottomPanel(rawValue: rawValue)
  }

  static func saveBottomPanel(
    _ panel: EditorBottomPanel?, for workspaceURL: URL, defaults: UserDefaults = .standard
  ) {
    let defaultsKey = key("bottomPanel", workspaceURL)
    if let panel {
      defaults.set(panel.rawValue, forKey: defaultsKey)
    } else {
      defaults.removeObject(forKey: defaultsKey)
    }
  }

  static func loadSidebarVisibility(
    for workspaceURL: URL, defaults: UserDefaults = .standard
  ) -> Bool {
    let defaultsKey = key("sidebarVisible", workspaceURL)
    guard defaults.object(forKey: defaultsKey) != nil else {
      return Defaults.sidebarVisible
    }
    return defaults.bool(forKey: defaultsKey)
  }

  static func saveSidebarVisibility(
    _ isVisible: Bool, for workspaceURL: URL, defaults: UserDefaults = .standard
  ) {
    defaults.set(isVisible, forKey: key("sidebarVisible", workspaceURL))
  }

  static func loadSidebarWidth(
    for workspaceURL: URL, defaults: UserDefaults = .standard
  ) -> Double {
    loadDimension(
      key: key("sidebarWidth", workspaceURL),
      defaultValue: Defaults.sidebarWidth,
      defaults: defaults
    )
  }

  static func saveSidebarWidth(
    _ width: Double, for workspaceURL: URL, defaults: UserDefaults = .standard
  ) {
    saveDimension(width, key: key("sidebarWidth", workspaceURL), defaults: defaults)
  }

  static func loadBottomPanelHeight(
    for workspaceURL: URL, defaults: UserDefaults = .standard
  ) -> Double {
    loadDimension(
      key: key("bottomPanelHeight", workspaceURL),
      defaultValue: Defaults.bottomPanelHeight,
      defaults: defaults
    )
  }

  static func saveBottomPanelHeight(
    _ height: Double, for workspaceURL: URL, defaults: UserDefaults = .standard
  ) {
    saveDimension(height, key: key("bottomPanelHeight", workspaceURL), defaults: defaults)
  }

  private static func loadDimension(
    key: String,
    defaultValue: Double,
    defaults: UserDefaults
  ) -> Double {
    guard let number = defaults.object(forKey: key) as? NSNumber else {
      return defaultValue
    }
    let value = number.doubleValue
    guard value.isFinite, value > 0 else { return defaultValue }
    return value
  }

  private static func saveDimension(
    _ value: Double,
    key: String,
    defaults: UserDefaults
  ) {
    guard value.isFinite, value > 0 else { return }
    defaults.set(value, forKey: key)
  }

  private static func key(_ component: String, _ workspaceURL: URL) -> String {
    "calcite.workspaceLayout.\(component).\(workspaceID(for: workspaceURL))"
  }

  private static func workspaceID(for workspaceURL: URL) -> String {
    workspaceURL.standardizedFileURL.path
      .replacingOccurrences(of: "/", with: "%2F")
  }
}
