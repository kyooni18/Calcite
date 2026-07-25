import Foundation
import Combine

@MainActor
final class EditorRecentItemsStore: ObservableObject {
  @Published private(set) var items: [URL] = []
  private let key = "calcite.recentItems"
  private let limit = 10

  init() {
    items = (UserDefaults.standard.array(forKey: key) as? [String] ?? [])
      .map { URL(fileURLWithPath: $0).standardizedFileURL }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  func add(_ url: URL) {
    let url = url.standardizedFileURL
    items.removeAll { $0 == url }
    items.insert(url, at: 0)
    items = Array(items.prefix(limit))
    UserDefaults.standard.set(items.map(\.path), forKey: key)
  }

  func clear() {
    items.removeAll()
    UserDefaults.standard.removeObject(forKey: key)
  }
}
