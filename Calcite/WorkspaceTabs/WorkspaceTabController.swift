import Combine
import Foundation

nonisolated enum WorkspaceTabID: Hashable, Identifiable, Codable, Sendable {
  case document(UUID)
  case settings
  case themeBuilder

  var id: String {
    switch self {
    case .document(let id): "document:\(id.uuidString)"
    case .settings: "settings"
    case .themeBuilder: "themeBuilder"
    }
  }

  var isUtility: Bool {
    switch self {
    case .document: false
    case .settings, .themeBuilder: true
    }
  }
}

@MainActor
final class WorkspaceTabController: ObservableObject {
  @Published private(set) var utilityTabs: [WorkspaceTabID]
  @Published private(set) var selection: WorkspaceTabID?

  private let workspaceURL: URL
  private let defaults: UserDefaults

  init(workspaceURL: URL, defaults: UserDefaults = .standard) {
    self.workspaceURL = workspaceURL.standardizedFileURL
    self.defaults = defaults
    let snapshot = WorkspaceTabPersistence.load(for: workspaceURL, defaults: defaults)
    utilityTabs = snapshot.utilityTabs.reduce(into: []) { result, tab in
      guard tab.isUtility, !result.contains(tab) else { return }
      result.append(tab)
    }
    if let selected = snapshot.selectedUtilityTab, utilityTabs.contains(selected) {
      selection = selected
    } else {
      selection = nil
    }
  }

  func selectDocument(_ id: UUID) {
    selection = .document(id)
    persist()
  }

  func selectUtility(_ tab: WorkspaceTabID) {
    guard tab.isUtility, utilityTabs.contains(tab) else { return }
    selection = tab
    persist()
  }

  func openSettings() {
    openUtility(.settings)
  }

  func openThemeBuilder() {
    openUtility(.themeBuilder)
  }

  func closeUtility(_ tab: WorkspaceTabID, fallbackDocumentID: UUID?) {
    guard tab.isUtility else { return }
    utilityTabs.removeAll { $0 == tab }
    if selection == tab {
      selection =
        fallbackDocumentID.map(WorkspaceTabID.document)
        ?? utilityTabs.last
    }
    persist()
  }

  func reconcile(documentIDs: [UUID], selectedDocumentID: UUID?) {
    let available = Set(documentIDs)
    if case .document(let id) = selection, !available.contains(id) {
      selection =
        selectedDocumentID.map(WorkspaceTabID.document)
        ?? documentIDs.first.map(WorkspaceTabID.document)
        ?? utilityTabs.last
    }

    if selection == nil {
      selection =
        selectedDocumentID.map(WorkspaceTabID.document)
        ?? documentIDs.first.map(WorkspaceTabID.document)
        ?? utilityTabs.last
    }
    persist()
  }

  func synchronizeSelectedDocument(_ id: UUID?) {
    guard let id else { return }
    if selection?.isUtility != true {
      selection = .document(id)
      persist()
    }
  }

  private func openUtility(_ tab: WorkspaceTabID) {
    if !utilityTabs.contains(tab) {
      utilityTabs.append(tab)
    }
    selection = tab
    persist()
  }

  private func persist() {
    WorkspaceTabPersistence.save(
      .init(
        utilityTabs: utilityTabs,
        selectedUtilityTab: selection?.isUtility == true ? selection : nil
      ),
      for: workspaceURL,
      defaults: defaults
    )
  }
}

private enum WorkspaceTabPersistence {
  nonisolated struct Snapshot: Codable, Sendable {
    var utilityTabs: [WorkspaceTabID]
    var selectedUtilityTab: WorkspaceTabID?
  }

  static func load(for workspaceURL: URL, defaults: UserDefaults) -> Snapshot {
    guard let data = defaults.data(forKey: key(for: workspaceURL)),
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
    else {
      return Snapshot(utilityTabs: [], selectedUtilityTab: nil)
    }
    return snapshot
  }

  static func save(_ snapshot: Snapshot, for workspaceURL: URL, defaults: UserDefaults) {
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    defaults.set(data, forKey: key(for: workspaceURL))
  }

  private static func key(for workspaceURL: URL) -> String {
    let encoded = Data(workspaceURL.standardizedFileURL.path.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "=", with: "")
    return "workspaceTabs.\(encoded)"
  }
}
