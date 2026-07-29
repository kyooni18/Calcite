import Foundation

nonisolated enum EditorBreakpointStore {
  private struct Payload: Codable {
    var schemaVersion = 2
    var values: [String: [Int]] = [:]
  }

  private static let legacyKey = "editorBreakpointsByFile.v1"
  private static let storageURL = CalciteStateStorage.globalURL("breakpoints.json")
  private static let queue = DispatchQueue(label: "Calcite.EditorBreakpointStore")

  static func load(for url: URL) -> Set<Int> {
    queue.sync {
      let values = loadPayload().values
      return Set((values[url.standardizedFileURL.path] ?? []).filter { $0 > 0 })
    }
  }

  static func save(_ breakpoints: Set<Int>, for url: URL) {
    queue.sync {
      var payload = loadPayload()
      let path = url.standardizedFileURL.path
      if breakpoints.isEmpty {
        payload.values.removeValue(forKey: path)
      } else {
        payload.values[path] = breakpoints.filter { $0 > 0 }.sorted()
      }
      persist(payload)
    }
  }

  /// Returns every persisted breakpoint owned by the workspace, including files that are not
  /// currently open in an editor tab.
  static func all(under workspaceURL: URL) -> [URL: Set<Int>] {
    queue.sync {
      let values = loadPayload().values
      let root = workspaceURL.standardizedFileURL.path
      return values.reduce(into: [URL: Set<Int>]()) { result, entry in
        let path = URL(fileURLWithPath: entry.key).standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { return }
        let lines = Set(entry.value.filter { $0 > 0 })
        guard !lines.isEmpty else { return }
        result[URL(fileURLWithPath: path)] = lines
      }
    }
  }

  static func move(from sourceURL: URL, to destinationURL: URL) {
    queue.sync {
      var payload = loadPayload()
      let source = sourceURL.standardizedFileURL.path
      let destination = destinationURL.standardizedFileURL.path
      let affected = payload.values.keys.filter { $0 == source || $0.hasPrefix(source + "/") }
      guard !affected.isEmpty else { return }
      for oldPath in affected {
        let suffix = String(oldPath.dropFirst(source.count))
        payload.values[destination + suffix] = payload.values.removeValue(forKey: oldPath)
      }
      persist(payload)
    }
  }

  static func remove(under targetURL: URL) {
    queue.sync {
      var payload = loadPayload()
      let target = targetURL.standardizedFileURL.path
      payload.values = payload.values.filter {
        path, _ in path != target && !path.hasPrefix(target + "/")
      }
      persist(payload)
    }
  }

  private static func loadPayload() -> Payload {
    if let payload = CalciteStateStorage.load(Payload.self, from: storageURL) {
      return sanitize(payload)
    }

    let legacy = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: [Int]] ?? [:]
    guard !legacy.isEmpty else { return Payload() }
    let migrated = sanitize(Payload(values: legacy))
    persist(migrated)
    UserDefaults.standard.removeObject(forKey: legacyKey)
    return migrated
  }

  private static func persist(_ payload: Payload) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try CalciteStateStorage.save(sanitize(payload), to: storageURL, encoder: encoder)
    } catch {
      // Breakpoint persistence must never break editing or debugging. The next mutation retries.
    }
  }

  private static func sanitize(_ payload: Payload) -> Payload {
    var values: [String: [Int]] = [:]
    for (path, lines) in payload.values {
      guard path.hasPrefix("/") else { continue }
      let valid = Array(Set(lines.filter { $0 > 0 })).sorted()
      if !valid.isEmpty { values[path] = valid }
    }
    return Payload(schemaVersion: max(2, payload.schemaVersion), values: values)
  }
}
