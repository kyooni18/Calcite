import Foundation

struct EditorSessionRecoveryInput: Sendable {
  var url: URL
  var text: String
  var diskModificationTime: TimeInterval?
}

nonisolated struct EditorRecoveredDocument: Codable, Equatable, Sendable {
  var relativePath: String
  var text: String
  var diskModificationTime: TimeInterval?
  var diskByteCount: Int?
  var diskFingerprint: String?
  var capturedAt: Date

  nonisolated init(
    relativePath: String,
    text: String,
    diskModificationTime: TimeInterval?,
    diskByteCount: Int? = nil,
    diskFingerprint: String? = nil,
    capturedAt: Date
  ) {
    self.relativePath = relativePath
    self.text = text
    self.diskModificationTime = diskModificationTime
    self.diskByteCount = diskByteCount
    self.diskFingerprint = diskFingerprint
    self.capturedAt = capturedAt
  }
}

struct EditorWorkspaceSessionSaveReport: Equatable, Sendable {
  var omittedDocuments: [String] = []
  var hasOmissions: Bool { !omittedDocuments.isEmpty }
}

struct EditorWorkspaceRestoration: Codable, Equatable, Sendable {
  var openRelativePaths: [String] = []
  var selectedRelativePath: String?
  var recoveredDocuments: [EditorRecoveredDocument] = []
}

actor EditorWorkspaceSessionStore {
  private struct StoredState: Codable {
    var schemaVersion = 1
    var restoration = EditorWorkspaceRestoration()
  }

  private static let maximumDocumentBytes = 8_000_000
  private static let maximumTotalRecoveryBytes = 64_000_000
  private static let maximumDocumentCount = 100

  private let workspaceURL: URL
  private let storageURL: URL
  private var state: StoredState

  init(workspaceURL: URL) {
    self.workspaceURL = workspaceURL.standardizedFileURL
    self.storageURL = Self.storageURL(for: self.workspaceURL)
    self.state = Self.readState(from: storageURL)
  }

  func load() -> EditorWorkspaceRestoration {
    sanitize(state.restoration)
  }

  @discardableResult
  func save(
    openURLs: [URL],
    selectedURL: URL?,
    recoveredDocuments: [EditorSessionRecoveryInput]
  ) throws -> EditorWorkspaceSessionSaveReport {
    let openPaths = uniqueRelativePaths(openURLs)
    let selectedPath = selectedURL.flatMap(relativePath)

    var report = EditorWorkspaceSessionSaveReport()
    var recoveries: [EditorRecoveredDocument] = []
    var totalBytes = 0
    for value in recoveredDocuments.reversed() {
      guard let path = relativePath(value.url) else {
        report.omittedDocuments.append("\(value.url.lastPathComponent): outside the workspace")
        continue
      }
      guard recoveries.count < Self.maximumDocumentCount else {
        report.omittedDocuments.append("\(path): recovery document limit reached")
        continue
      }
      let byteCount = value.text.utf8.count
      guard byteCount <= Self.maximumDocumentBytes else {
        report.omittedDocuments.append("\(path): larger than 8 MB")
        continue
      }
      guard totalBytes + byteCount <= Self.maximumTotalRecoveryBytes else {
        report.omittedDocuments.append("\(path): total recovery limit reached")
        continue
      }
      totalBytes += byteCount
      let diskData = try? Data(contentsOf: value.url, options: [.mappedIfSafe])
      recoveries.append(
        EditorRecoveredDocument(
          relativePath: path,
          text: value.text,
          diskModificationTime: value.diskModificationTime,
          diskByteCount: diskData?.count,
          diskFingerprint: diskData.map(Self.fingerprint),
          capturedAt: Date()
        )
      )
    }

    state.restoration = EditorWorkspaceRestoration(
      openRelativePaths: openPaths,
      selectedRelativePath: selectedPath,
      recoveredDocuments: recoveries.reversed()
    )
    try persist()
    return report
  }

  func clear() throws {
    state = StoredState()
    try CalciteStateStorage.remove(at: storageURL)
  }

  func url(forRelativePath path: String) -> URL? {
    guard Self.isSafeRelativePath(path) else { return nil }
    let candidate = workspaceURL.appendingPathComponent(path).standardizedFileURL
    let rootPath = workspaceURL.path
    guard candidate.path.hasPrefix(rootPath + "/") else { return nil }
    return candidate
  }

  func diskStillMatches(_ recovery: EditorRecoveredDocument, at url: URL) -> Bool {
    if let storedCount = recovery.diskByteCount,
      let storedFingerprint = recovery.diskFingerprint,
      let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
    {
      return data.count == storedCount && Self.fingerprint(data) == storedFingerprint
    }
    let current = Self.modificationTime(for: url)
    switch (recovery.diskModificationTime, current) {
    case (nil, nil): return true
    case (.some(let stored), .some(let current)):
      return abs(stored - current) < 0.001
    default:
      return false
    }
  }

  private func persist() throws {
    try CalciteStateStorage.save(
      state,
      to: storageURL,
      encoder: JSONEncoder.sessionEncoder
    )
  }

  private func sanitize(_ restoration: EditorWorkspaceRestoration) -> EditorWorkspaceRestoration {
    let openPaths = restoration.openRelativePaths.filter(Self.isSafeRelativePath)
    let selected = restoration.selectedRelativePath.flatMap {
      Self.isSafeRelativePath($0) ? $0 : nil
    }
    let recoveries = restoration.recoveredDocuments.filter {
      Self.isSafeRelativePath($0.relativePath)
        && $0.text.utf8.count <= Self.maximumDocumentBytes
    }
    return EditorWorkspaceRestoration(
      openRelativePaths: Array(openPaths.prefix(Self.maximumDocumentCount)),
      selectedRelativePath: selected,
      recoveredDocuments: Array(recoveries.prefix(Self.maximumDocumentCount))
    )
  }

  private func uniqueRelativePaths(_ urls: [URL]) -> [String] {
    var seen: Set<String> = []
    return urls.compactMap(relativePath).filter { seen.insert($0).inserted }.prefix(
      Self.maximumDocumentCount
    ).map {
      $0
    }
  }

  private func relativePath(_ url: URL) -> String? {
    let rootPath = workspaceURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return nil }
    let relative = String(path.dropFirst(rootPath.count + 1))
    return Self.isSafeRelativePath(relative) ? relative : nil
  }

  nonisolated private static func readState(from url: URL) -> StoredState {
    CalciteStateStorage.load(
      StoredState.self,
      from: url,
      maximumBytes: maximumTotalRecoveryBytes + 1_000_000,
      decoder: JSONDecoder.sessionDecoder
    ) ?? StoredState()
  }

  private static func storageURL(for workspaceURL: URL) -> URL {
    CalciteStateStorage.workspaceURL(workspaceURL, filename: "session.json")
  }

  nonisolated private static func fingerprint(_ data: Data) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in data {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }

  private static func modificationTime(for url: URL) -> TimeInterval? {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
    return values?.contentModificationDate?.timeIntervalSince1970
  }

  private static func isSafeRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

extension JSONEncoder {
  nonisolated fileprivate static var sessionEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  nonisolated fileprivate static var sessionDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
