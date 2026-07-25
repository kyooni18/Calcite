import Foundation

enum EditorBreakpointStore {
  private static let key = "editorBreakpointsByFile.v1"

  static func load(for url: URL) -> Set<Int> {
    let values = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
    return Set((values[url.standardizedFileURL.path] ?? []).filter { $0 > 0 })
  }

  static func save(_ breakpoints: Set<Int>, for url: URL) {
    var values = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
    let path = url.standardizedFileURL.path
    if breakpoints.isEmpty {
      values.removeValue(forKey: path)
    } else {
      values[path] = breakpoints.filter { $0 > 0 }.sorted()
    }
    UserDefaults.standard.set(values, forKey: key)
  }

  static func move(from sourceURL: URL, to destinationURL: URL) {
    var values = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
    let source = sourceURL.standardizedFileURL.path
    let destination = destinationURL.standardizedFileURL.path
    let affected = values.keys.filter { $0 == source || $0.hasPrefix(source + "/") }
    guard !affected.isEmpty else { return }
    for oldPath in affected {
      let suffix = String(oldPath.dropFirst(source.count))
      values[destination + suffix] = values.removeValue(forKey: oldPath)
    }
    UserDefaults.standard.set(values, forKey: key)
  }

  static func remove(under targetURL: URL) {
    var values = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
    let target = targetURL.standardizedFileURL.path
    values = values.filter { path, _ in path != target && !path.hasPrefix(target + "/") }
    UserDefaults.standard.set(values, forKey: key)
  }

}
