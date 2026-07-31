import Foundation

nonisolated struct EditorStoredBreakpoint: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var documentURL: URL?
  var requestedLine: Int
  var lineTextHash: String?
  var leadingContextHash: String?
  var trailingContextHash: String?
  var condition: String?
  var hitCondition: String?
  var logMessage: String?
  var isEnabled: Bool
  var resolvedLine: Int?
  var verificationMessage: String?

  init(
    id: UUID = UUID(),
    documentURL: URL? = nil,
    requestedLine: Int,
    lineTextHash: String? = nil,
    leadingContextHash: String? = nil,
    trailingContextHash: String? = nil,
    condition: String? = nil,
    hitCondition: String? = nil,
    logMessage: String? = nil,
    isEnabled: Bool = true,
    resolvedLine: Int? = nil,
    verificationMessage: String? = nil
  ) {
    self.id = id
    self.documentURL = documentURL?.standardizedFileURL
    self.requestedLine = requestedLine
    self.lineTextHash = lineTextHash
    self.leadingContextHash = leadingContextHash
    self.trailingContextHash = trailingContextHash
    self.condition = condition
    self.hitCondition = hitCondition
    self.logMessage = logMessage
    self.isEnabled = isEnabled
    self.resolvedLine = resolvedLine
    self.verificationMessage = verificationMessage
  }

  var effectiveLine: Int { resolvedLine ?? requestedLine }
}

nonisolated enum EditorBreakpointStore {
  private struct PayloadV3: Codable {
    var schemaVersion = 3
    var values: [String: [EditorStoredBreakpoint]] = [:]
  }

  private struct PayloadV2: Codable {
    var schemaVersion = 2
    var values: [String: [Int]] = [:]
  }

  private static let legacyKey = "editorBreakpointsByFile.v1"
  private static let storageURL = CalciteStateStorage.globalURL("breakpoints.json")
  private static let queue = DispatchQueue(label: "Calcite.EditorBreakpointStore")

  static func load(for url: URL) -> Set<Int> {
    queue.sync {
      Set(
        records(in: loadPayload(), for: url)
          .filter(\.isEnabled)
          .map(\.effectiveLine)
          .filter { $0 > 0 }
      )
    }
  }

  static func loadRecords(for url: URL) -> [EditorStoredBreakpoint] {
    queue.sync { records(in: loadPayload(), for: url) }
  }

  static func save(_ breakpoints: Set<Int>, for url: URL) {
    queue.sync {
      var payload = loadPayload()
      let standardizedURL = url.standardizedFileURL
      let path = standardizedURL.path
      let previousRecords = payload.values[path] ?? []
      let context = sourceContext(for: standardizedURL)
      var consumedRecordIDs: Set<UUID> = []
      var records =
        breakpoints
        .filter { $0 > 0 }
        .sorted()
        .map { line -> EditorStoredBreakpoint in
          let previous = previousRecords.first {
            !consumedRecordIDs.contains($0.id) && $0.isEnabled && $0.effectiveLine == line
          }
          var record = previous ?? EditorStoredBreakpoint(requestedLine: line)
          consumedRecordIDs.insert(record.id)
          record.documentURL = standardizedURL
          record.requestedLine = line
          record.resolvedLine = nil
          record.verificationMessage = nil
          record.isEnabled = true
          record.lineTextHash = context.hash(at: line)
          record.leadingContextHash = context.hash(at: line - 1)
          record.trailingContextHash = context.hash(at: line + 1)
          return record
        }

      // Disabled records are not represented by the editor's Set<Int>. Keep them unless an active
      // breakpoint now owns the same effective line.
      let activeLines = Set(records.map(\.effectiveLine))
      records.append(
        contentsOf: previousRecords.filter {
          !$0.isEnabled && !activeLines.contains($0.effectiveLine)
        }
      )

      if records.isEmpty {
        payload.values.removeValue(forKey: path)
      } else {
        payload.values[path] = sanitizeRecords(records)
      }
      persist(payload)
    }
  }

  /// Moves persisted breakpoint records after an in-memory document edit while preserving their
  /// identity, conditions, hit counts, and log messages.
  @discardableResult
  static func remapRecords(
    for url: URL,
    lineMapping: [Int: Int],
    in text: String
  ) -> [EditorStoredBreakpoint] {
    queue.sync {
      var payload = loadPayload()
      let standardizedURL = url.standardizedFileURL
      let path = standardizedURL.path
      let remapped = remappedRecords(
        payload.values[path] ?? [],
        lineMapping: lineMapping,
        documentURL: standardizedURL,
        text: text
      )
      if remapped.isEmpty {
        payload.values.removeValue(forKey: path)
      } else {
        payload.values[path] = remapped
      }
      persist(payload)
      return remapped
    }
  }

  static func remappedRecords(
    _ records: [EditorStoredBreakpoint],
    lineMapping: [Int: Int],
    documentURL: URL,
    text: String
  ) -> [EditorStoredBreakpoint] {
    let context = SourceContext(lines: text.components(separatedBy: .newlines))
    var result: [EditorStoredBreakpoint] = []
    var occupiedLines: Set<Int> = []

    for original in records.sorted(by: breakpointRecordPriority) {
      let oldLine = original.effectiveLine
      guard let newLine = lineMapping[oldLine], newLine > 0 else { continue }
      guard occupiedLines.insert(newLine).inserted else { continue }

      var record = original
      record.documentURL = documentURL.standardizedFileURL
      record.requestedLine = newLine
      record.resolvedLine = nil
      record.verificationMessage = nil
      record.lineTextHash = context.hash(at: newLine)
      record.leadingContextHash = context.hash(at: newLine - 1)
      record.trailingContextHash = context.hash(at: newLine + 1)
      result.append(record)
    }

    return sanitizeRecords(result)
  }

  static func saveRecords(_ records: [EditorStoredBreakpoint], for url: URL) {
    queue.sync {
      var payload = loadPayload()
      let path = url.standardizedFileURL.path
      let valid = sanitizeRecords(records).map { value -> EditorStoredBreakpoint in
        var value = value
        value.documentURL = url.standardizedFileURL
        return value
      }
      if valid.isEmpty {
        payload.values.removeValue(forKey: path)
      } else {
        payload.values[path] = valid
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
        let lines = Set(
          entry.value.filter(\.isEnabled).map(\.requestedLine).filter { $0 > 0 }
        )
        guard !lines.isEmpty else { return }
        result[URL(fileURLWithPath: path)] = lines
      }
    }
  }

  static func allRecords(under workspaceURL: URL) -> [URL: [EditorStoredBreakpoint]] {
    queue.sync {
      let values = loadPayload().values
      let root = workspaceURL.standardizedFileURL.path
      return values.reduce(into: [URL: [EditorStoredBreakpoint]]()) { result, entry in
        let path = URL(fileURLWithPath: entry.key).standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let records = sanitizeRecords(entry.value).map { value -> EditorStoredBreakpoint in
          var value = value
          value.documentURL = url
          return value
        }
        guard !records.isEmpty else { return }
        result[url] = records
      }
    }
  }

  @discardableResult
  static func relocateRecords(for url: URL, in text: String) -> [EditorStoredBreakpoint] {
    queue.sync {
      var payload = loadPayload()
      let path = url.standardizedFileURL.path
      let current = payload.values[path] ?? []
      let relocated = EditorBreakpointRelocator.relocate(current, in: text).map {
        value -> EditorStoredBreakpoint in
        var value = value
        value.documentURL = url.standardizedFileURL
        return value
      }
      if relocated.isEmpty {
        payload.values.removeValue(forKey: path)
      } else {
        payload.values[path] = relocated
      }
      persist(payload)
      return relocated
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

  private static func records(in payload: PayloadV3, for url: URL) -> [EditorStoredBreakpoint] {
    let url = url.standardizedFileURL
    return (payload.values[url.path] ?? []).map { value in
      var value = value
      value.documentURL = url
      return value
    }
  }

  private static func loadPayload() -> PayloadV3 {
    if let payload = CalciteStateStorage.load(PayloadV3.self, from: storageURL) {
      return sanitize(payload)
    }

    if let payload = CalciteStateStorage.load(PayloadV2.self, from: storageURL) {
      let migrated = PayloadV3(
        values: payload.values.mapValues { lines in
          lines.filter { $0 > 0 }.map { EditorStoredBreakpoint(requestedLine: $0) }
        }
      )
      let sanitized = sanitize(migrated)
      persist(sanitized)
      return sanitized
    }

    let legacy = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: [Int]] ?? [:]
    guard !legacy.isEmpty else { return PayloadV3() }
    let migrated = sanitize(
      PayloadV3(
        values: legacy.mapValues { lines in
          lines.filter { $0 > 0 }.map { EditorStoredBreakpoint(requestedLine: $0) }
        }
      )
    )
    persist(migrated)
    UserDefaults.standard.removeObject(forKey: legacyKey)
    return migrated
  }

  private static func persist(_ payload: PayloadV3) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try CalciteStateStorage.save(sanitize(payload), to: storageURL, encoder: encoder)
    } catch {
      // Breakpoint persistence must never break editing or debugging. The next mutation retries.
    }
  }

  private static func sanitize(_ payload: PayloadV3) -> PayloadV3 {
    var values: [String: [EditorStoredBreakpoint]] = [:]
    for (path, records) in payload.values {
      guard path.hasPrefix("/") else { continue }
      let valid = sanitizeRecords(records)
      if !valid.isEmpty { values[path] = valid }
    }
    return PayloadV3(schemaVersion: max(3, payload.schemaVersion), values: values)
  }

  private static func sanitizeRecords(
    _ records: [EditorStoredBreakpoint]
  ) -> [EditorStoredBreakpoint] {
    var seen: Set<Int> = []
    return
      records
      .filter { $0.requestedLine > 0 }
      .sorted { $0.requestedLine < $1.requestedLine }
      .filter { seen.insert($0.requestedLine).inserted }
  }

  private static func breakpointRecordPriority(
    _ lhs: EditorStoredBreakpoint,
    _ rhs: EditorStoredBreakpoint
  ) -> Bool {
    func score(_ value: EditorStoredBreakpoint) -> Int {
      var result = value.isEnabled ? 8 : 0
      if value.condition?.isEmpty == false { result += 4 }
      if value.hitCondition?.isEmpty == false { result += 2 }
      if value.logMessage?.isEmpty == false { result += 2 }
      return result
    }
    let lhsScore = score(lhs)
    let rhsScore = score(rhs)
    if lhsScore != rhsScore { return lhsScore > rhsScore }
    if lhs.effectiveLine != rhs.effectiveLine { return lhs.effectiveLine < rhs.effectiveLine }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private struct SourceContext {
    var lines: [String]

    func hash(at oneBasedLine: Int) -> String? {
      guard oneBasedLine > 0, oneBasedLine <= lines.count else { return nil }
      return EditorSourceFingerprint.hash(lines[oneBasedLine - 1])
    }
  }

  private static func sourceContext(for url: URL) -> SourceContext {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      return SourceContext(lines: [])
    }
    return SourceContext(lines: text.components(separatedBy: .newlines))
  }
}
