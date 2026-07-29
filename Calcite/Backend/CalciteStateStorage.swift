import Foundation

nonisolated enum CalciteStateStorage {
  private static let maximumDefaultBytes = 80_000_000

  static var rootURL: URL {
    let applicationSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support", isDirectory: true)
    return applicationSupport.appendingPathComponent("Calcite", isDirectory: true)
  }

  static func globalURL(_ filename: String) -> URL {
    rootURL.appendingPathComponent("Global", isDirectory: true)
      .appendingPathComponent(filename, isDirectory: false)
  }

  static func workspaceURL(_ workspaceURL: URL, filename: String) -> URL {
    rootURL.appendingPathComponent("Workspaces", isDirectory: true)
      .appendingPathComponent(
        stableIdentifier(workspaceURL.standardizedFileURL.path), isDirectory: true
      )
      .appendingPathComponent(filename, isDirectory: false)
  }

  static func load<Value: Decodable>(
    _ type: Value.Type,
    from url: URL,
    maximumBytes: Int = maximumDefaultBytes,
    decoder: JSONDecoder = JSONDecoder()
  ) -> Value? {
    if let value = decode(type, from: url, maximumBytes: maximumBytes, decoder: decoder) {
      return value
    }
    let backup = backupURL(for: url)
    if let value = decode(type, from: backup, maximumBytes: maximumBytes, decoder: decoder) {
      quarantineCorruptedFile(at: url)
      try? FileManager.default.copyItem(at: backup, to: url)
      return value
    }
    quarantineCorruptedFile(at: url)
    quarantineCorruptedFile(at: backup)
    return nil
  }

  static func save<Value: Encodable>(
    _ value: Value,
    to url: URL,
    encoder: JSONEncoder = JSONEncoder()
  ) throws {
    let fileManager = FileManager.default
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try encoder.encode(value)
    let temporary = directory.appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: temporary, options: [.atomic])

    let backup = backupURL(for: url)
    if fileManager.fileExists(atPath: url.path) {
      try? fileManager.removeItem(at: backup)
      try? fileManager.copyItem(at: url, to: backup)
      do {
        _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        return
      } catch {
        // Some sandbox and network volumes do not implement replaceItemAt reliably.
        // Data.write(.atomic) still gives us an atomic rename fallback.
        try? fileManager.removeItem(at: temporary)
        try data.write(to: url, options: [.atomic])
        return
      }
    }
    try fileManager.moveItem(at: temporary, to: url)
  }

  static func remove(at url: URL) throws {
    let fileManager = FileManager.default
    for candidate in [url, backupURL(for: url)] where fileManager.fileExists(atPath: candidate.path)
    {
      try fileManager.removeItem(at: candidate)
    }
  }

  static func stableIdentifier(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }

  private static func decode<Value: Decodable>(
    _ type: Value.Type,
    from url: URL,
    maximumBytes: Int,
    decoder: JSONDecoder
  ) -> Value? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let byteCount = attributes[.size] as? NSNumber,
      byteCount.intValue <= maximumBytes,
      let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
    else { return nil }
    return try? decoder.decode(type, from: data)
  }

  private static func backupURL(for url: URL) -> URL {
    url.appendingPathExtension("backup")
  }

  private static func quarantineCorruptedFile(at url: URL) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else { return }
    let quarantineDirectory = url.deletingLastPathComponent()
      .appendingPathComponent("Quarantine", isDirectory: true)
    try? fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let destination = quarantineDirectory.appendingPathComponent(
      "\(url.lastPathComponent).\(stamp).\(UUID().uuidString).corrupt")
    try? fileManager.moveItem(at: url, to: destination)
  }
}
