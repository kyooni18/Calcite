import Foundation

extension Notification.Name {
  static let calciteCommitEditorStateForExecution = Notification.Name(
    "Calcite.CommitEditorStateForExecution"
  )
}

nonisolated enum EditorExecutionPreparationReason: String, Sendable {
  case build
  case run
  case debug
  case liveDebug
  case test
  case singleFileRun
  case singleFileTest
  case singleFileDebug
}

nonisolated struct EditorPreparedDocumentSnapshot: Equatable, Sendable {
  let url: URL
  let revision: UInt64?
  let contentHash: String
  let byteCount: Int
  let modificationDate: Date?
}

nonisolated struct EditorPreparedSourceSnapshot: Equatable, Sendable, Identifiable {
  let id: UUID
  let reason: EditorExecutionPreparationReason
  let workspaceURL: URL
  let documents: [EditorPreparedDocumentSnapshot]
  let fingerprint: String
  let preparedAt: Date

  var documentCount: Int { documents.count }
}

nonisolated struct EditorBuildArtifactSnapshot: Equatable, Sendable, Identifiable {
  let id: UUID
  let commandID: String
  let sourceSnapshotID: UUID
  let sourceFingerprint: String
  let executableURL: URL?
  let productName: String?
  let architecture: String?
  let resolver: EditorArtifactResolverKind?
  let completedAt: Date
}

nonisolated enum EditorExecutionIntegrityError: LocalizedError, Sendable {
  case documentSaveFailed(String)
  case documentUnavailable(String)
  case sourceMismatch(String)
  case configuration(String)
  case noSourceFiles

  var errorDescription: String? {
    switch self {
    case .documentSaveFailed(let name):
      return "Execution was stopped because \(name) could not be saved."
    case .documentUnavailable(let path):
      return "Execution was stopped because the source file is unavailable: \(path)"
    case .sourceMismatch(let name):
      return "Execution was stopped because the editor text does not match the saved file: \(name)"
    case .configuration(let message):
      return message
    case .noSourceFiles:
      return "Execution was stopped because no source files could be fingerprinted."
    }
  }
}

/// Small deterministic hash used only for source identity. It deliberately avoids process-randomized
/// `Hasher` values and has no platform crypto dependency, so snapshots compare across launches.
nonisolated enum EditorSourceFingerprint {
  private static let offset: UInt64 = 0xcbf2_9ce4_8422_2325
  private static let prime: UInt64 = 0x100_0000_01b3

  static func hash(_ data: Data) -> String {
    var value = offset
    for byte in data {
      value ^= UInt64(byte)
      value &*= prime
    }
    return String(format: "%016llx", value)
  }

  static func hash(_ string: String) -> String {
    hash(Data(string.utf8))
  }

  static func combine(_ values: some Sequence<String>) -> String {
    var value = offset
    for component in values {
      for byte in component.utf8 {
        value ^= UInt64(byte)
        value &*= prime
      }
      value ^= 0xff
      value &*= prime
    }
    return String(format: "%016llx", value)
  }
}

nonisolated enum EditorWorkspaceSourceScanner {
  private static let sourceExtensions: Set<String> = [
    "swift", "c", "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "hh",
    "rs", "go", "py", "pyw", "js", "jsx", "mjs", "cjs", "ts", "tsx",
    "java", "kt", "kts", "scala", "sc", "groovy", "gradle", "lua", "rb",
    "php", "pl", "pm", "r", "dart", "cs", "fs", "fsx", "vb", "zig",
    "hs", "lhs", "ex", "exs", "erl", "hrl", "clj", "cljs", "cljc", "sh",
    "bash", "zsh", "fish", "sql", "proto", "metal",
  ]

  private static let manifestNames: Set<String> = [
    "Package.swift", "Package.resolved", "Cargo.toml", "Cargo.lock", "go.mod", "go.sum",
    "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "pyproject.toml",
    "requirements.txt", "Pipfile", "poetry.lock", "build.gradle", "build.gradle.kts",
    "settings.gradle", "settings.gradle.kts", "pom.xml", "CMakeLists.txt", "Makefile",
    "build.zig", "pubspec.yaml",
  ]

  private static let skippedDirectoryNames: Set<String> = [
    ".git", ".svn", ".hg", ".build", "build", "DerivedData", "Pods", ".swiftpm",
    "node_modules", ".venv", "venv", "target", ".idea", ".vscode", ".calcite",
  ]

  static func sourceURLs(under rootURL: URL) -> [URL] {
    let root = rootURL.standardizedFileURL
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles],
        errorHandler: { _, _ in true }
      )
    else { return [] }

    var result: [URL] = []
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
      if values?.isDirectory == true {
        if skippedDirectoryNames.contains(url.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values?.isRegularFile == true else { continue }
      let extensionName = url.pathExtension.lowercased()
      if sourceExtensions.contains(extensionName) || manifestNames.contains(url.lastPathComponent) {
        result.append(url.standardizedFileURL)
      }
    }
    return result.sorted { $0.path < $1.path }
  }

  static func snapshot(
    fileURL: URL,
    reason: EditorExecutionPreparationReason,
    openDocument: (revision: UInt64, text: String)?
  ) throws -> EditorPreparedSourceSnapshot {
    let file = fileURL.standardizedFileURL
    guard let data = try? Data(contentsOf: file) else {
      throw EditorExecutionIntegrityError.documentUnavailable(file.path)
    }
    if let openDocument {
      let diskText = String(decoding: data, as: UTF8.self)
      guard diskText == openDocument.text else {
        throw EditorExecutionIntegrityError.sourceMismatch(file.lastPathComponent)
      }
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
    let document = EditorPreparedDocumentSnapshot(
      url: file,
      revision: openDocument?.revision,
      contentHash: EditorSourceFingerprint.hash(data),
      byteCount: data.count,
      modificationDate: attributes?[.modificationDate] as? Date
    )
    return EditorPreparedSourceSnapshot(
      id: UUID(),
      reason: reason,
      workspaceURL: file.deletingLastPathComponent(),
      documents: [document],
      fingerprint: EditorSourceFingerprint.combine([
        file.path, document.contentHash, String(document.byteCount),
      ]),
      preparedAt: Date()
    )
  }

  static func snapshot(
    workspaceURL: URL,
    reason: EditorExecutionPreparationReason,
    openDocuments: [URL: (revision: UInt64, text: String)]
  ) throws -> EditorPreparedSourceSnapshot {
    var urls = Set(sourceURLs(under: workspaceURL))
    urls.formUnion(openDocuments.keys.map(\.standardizedFileURL))
    guard !urls.isEmpty else { throw EditorExecutionIntegrityError.noSourceFiles }

    var documents: [EditorPreparedDocumentSnapshot] = []
    documents.reserveCapacity(urls.count)
    for url in urls.sorted(by: { $0.path < $1.path }) {
      guard let data = try? Data(contentsOf: url) else {
        if openDocuments[url] != nil {
          throw EditorExecutionIntegrityError.documentUnavailable(url.path)
        }
        continue
      }
      if let open = openDocuments[url] {
        let diskText = String(decoding: data, as: UTF8.self)
        guard diskText == open.text else {
          throw EditorExecutionIntegrityError.sourceMismatch(url.lastPathComponent)
        }
      }
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      documents.append(
        EditorPreparedDocumentSnapshot(
          url: url,
          revision: openDocuments[url]?.revision,
          contentHash: EditorSourceFingerprint.hash(data),
          byteCount: data.count,
          modificationDate: attributes?[.modificationDate] as? Date
        ))
    }
    guard !documents.isEmpty else { throw EditorExecutionIntegrityError.noSourceFiles }
    let fingerprint = EditorSourceFingerprint.combine(
      documents.flatMap { [$0.url.path, $0.contentHash, String($0.byteCount)] }
    )
    return EditorPreparedSourceSnapshot(
      id: UUID(),
      reason: reason,
      workspaceURL: workspaceURL.standardizedFileURL,
      documents: documents,
      fingerprint: fingerprint,
      preparedAt: Date()
    )
  }
}
