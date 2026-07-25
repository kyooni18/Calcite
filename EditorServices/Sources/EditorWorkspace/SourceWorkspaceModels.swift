import EditorCore
import Foundation

public struct SourceFileID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue.uuidString }
}

public enum SourceTextEncoding: String, Codable, Hashable, Sendable {
  case utf8
  case utf8WithByteOrderMark
}

public enum SourceLineEnding: String, Codable, Hashable, Sendable {
  case none
  case lineFeed
  case carriageReturnLineFeed
  case carriageReturn
  case mixed
}

public enum SourceFileState: String, Codable, Hashable, Sendable {
  /// Memory and disk contain the same source text.
  case clean
  /// Memory has edits that have not been persisted.
  case modified
  /// The file exists only in the workspace store.
  case created
  /// Both memory and disk changed since the last common snapshot.
  case conflicted
  /// The file disappeared from disk while retained in memory.
  case missing
}

public struct SourceDiskFingerprint: Hashable, Codable, Sendable {
  public var byteCount: Int
  public var contentHash: UInt64
  public var modificationDate: Date?

  public init(byteCount: Int, contentHash: UInt64, modificationDate: Date?) {
    self.byteCount = byteCount
    self.contentHash = contentHash
    self.modificationDate = modificationDate
  }
}

/// A complete source file held by ``SourceWorkspace``.
public struct SourceCodeFile: Hashable, Codable, Sendable, Identifiable {
  public let id: SourceFileID
  public let name: String
  public let relativePath: String
  public let url: URL
  public let languageID: String
  public let content: String
  public let version: Int
  public let savedVersion: Int?
  public let encoding: SourceTextEncoding
  public let lineEnding: SourceLineEnding
  public let state: SourceFileState
  public let diskFingerprint: SourceDiskFingerprint?

  public init(
    id: SourceFileID,
    name: String,
    relativePath: String,
    url: URL,
    languageID: String,
    content: String,
    version: Int,
    savedVersion: Int?,
    encoding: SourceTextEncoding,
    lineEnding: SourceLineEnding,
    state: SourceFileState,
    diskFingerprint: SourceDiskFingerprint?
  ) {
    self.id = id
    self.name = name
    self.relativePath = relativePath
    self.url = url
    self.languageID = languageID
    self.content = content
    self.version = version
    self.savedVersion = savedVersion
    self.encoding = encoding
    self.lineEnding = lineEnding
    self.state = state
    self.diskFingerprint = diskFingerprint
  }

  public var snapshot: TextSnapshot { TextSnapshot(text: content, version: version) }
  public var isDirty: Bool { state != .clean }
  public var pathComponents: [String] { relativePath.split(separator: "/").map(String.init) }
  public var parentRelativePath: String {
    let parent = (relativePath as NSString).deletingLastPathComponent
    return parent == "." ? "" : parent
  }
  public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
  public var stem: String { (name as NSString).deletingPathExtension }
  public var utf8ByteCount: Int { content.utf8.count }
  public var lineCount: Int { TextSnapshot(text: content).lineCount }
}

public struct SourceCodeFileSummary: Hashable, Codable, Sendable, Identifiable {
  public let id: SourceFileID
  public let name: String
  public let relativePath: String
  public let url: URL
  public let languageID: String
  public let version: Int
  public let state: SourceFileState

  public init(file: SourceCodeFile) {
    self.id = file.id
    self.name = file.name
    self.relativePath = file.relativePath
    self.url = file.url
    self.languageID = file.languageID
    self.version = file.version
    self.state = file.state
  }
}

public enum SourceWorkspaceNodeKind: String, Hashable, Codable, Sendable {
  case directory
  case file
}

/// A deterministic tree node suitable for a source navigator/sidebar.
public struct SourceWorkspaceNode: Hashable, Codable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let relativePath: String
  public let kind: SourceWorkspaceNodeKind
  public let file: SourceCodeFileSummary?
  public let children: [SourceWorkspaceNode]

  public init(
    id: String,
    name: String,
    relativePath: String,
    kind: SourceWorkspaceNodeKind,
    file: SourceCodeFileSummary? = nil,
    children: [SourceWorkspaceNode] = []
  ) {
    self.id = id
    self.name = name
    self.relativePath = relativePath
    self.kind = kind
    self.file = file
    self.children = children
  }
}

public struct SourceWorkspaceSnapshot: Hashable, Codable, Sendable {
  public let rootURL: URL
  public let revision: Int
  public let files: [SourceCodeFile]
  public let tree: SourceWorkspaceNode

  public init(rootURL: URL, revision: Int, files: [SourceCodeFile], tree: SourceWorkspaceNode) {
    self.rootURL = rootURL
    self.revision = revision
    self.files = files
    self.tree = tree
  }
}

public enum SourceWorkspaceSkipReason: Hashable, Codable, Sendable {
  case excluded
  case symbolicLink
  case unsupportedExtension
  case tooLarge(Int)
  case invalidUTF8
  case unreadable(String)
}

public struct SourceWorkspaceSkippedFile: Hashable, Codable, Sendable {
  public let relativePath: String
  public let reason: SourceWorkspaceSkipReason

  public init(relativePath: String, reason: SourceWorkspaceSkipReason) {
    self.relativePath = relativePath
    self.reason = reason
  }
}

public struct SourceWorkspaceScanReport: Hashable, Codable, Sendable {
  public let added: [SourceFileID]
  public let refreshed: [SourceFileID]
  public let conflicted: [SourceFileID]
  public let missing: [SourceFileID]
  public let skipped: [SourceWorkspaceSkippedFile]

  public init(
    added: [SourceFileID] = [],
    refreshed: [SourceFileID] = [],
    conflicted: [SourceFileID] = [],
    missing: [SourceFileID] = [],
    skipped: [SourceWorkspaceSkippedFile] = []
  ) {
    self.added = added
    self.refreshed = refreshed
    self.conflicted = conflicted
    self.missing = missing
    self.skipped = skipped
  }
}

public enum SourceWorkspaceConflictResolution: Hashable, Sendable {
  /// Keep memory and overwrite the external disk version.
  case useMemory
  /// Discard memory and reload the current disk version.
  case useDisk
}

public enum SourceWorkspaceEvent: Hashable, Codable, Sendable {
  case scanned(SourceWorkspaceScanReport)
  case added(SourceCodeFile)
  case changed(SourceCodeFile)
  case saved(SourceCodeFile)
  case moved(id: SourceFileID, oldRelativePath: String, file: SourceCodeFile)
  case removed(id: SourceFileID, relativePath: String)
  case conflict(SourceCodeFile)
  case reloaded(SourceCodeFile)
  case scanFailed(String)
  case restored(SourceWorkspaceRestoreReport)
}

/// Controls the read-only source index used for dependencies and external libraries.
///
/// External files are intentionally kept outside ``SourceWorkspace`` so they cannot be edited,
/// saved, restored, or shown as project-owned files by accident. They are used only as
/// completion and symbol context by higher-level editor backends.
public struct ExternalSourceIndexConfiguration: Hashable, Codable, Sendable {
  /// Source and interface formats that are useful for dependency symbol discovery.
  /// Documentation and generated metadata are excluded so package limits are spent on code.
  public static let commonExternalSourceExtensions: Set<String> = [
    "swift", "swiftinterface", "c", "h", "hh", "hpp", "hxx", "inc", "ipp", "tcc",
    "m", "mm", "cc", "cpp", "cxx", "rs", "go", "java", "kt", "kts",
    "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "py", "pyi", "pyw",
    "rb", "php", "cs", "fs", "fsx", "scala", "lua", "sh", "bash", "zsh", "fish",
    "proto", "graphql", "gql", "metal", "glsl", "wgsl", "zig", "nim", "nims",
    "hs", "lhs", "ml", "mli", "ex", "exs", "erl", "hrl", "dart", "r", "jl",
    "clj", "cljs", "cljc", "vue", "svelte", "modulemap",
  ]

  public var isEnabled: Bool
  public var discoversPackageRootsAutomatically: Bool
  public var explicitRootURLs: [URL]
  public var includedFileExtensions: Set<String>
  public var excludedDirectoryNames: Set<String>
  public var includesTestsAndExamples: Bool
  public var maximumFileCount: Int
  public var maximumFileCountPerPackage: Int
  public var maximumFileSize: Int
  public var maximumDirectoryDepth: Int

  public init(
    isEnabled: Bool = true,
    discoversPackageRootsAutomatically: Bool = true,
    explicitRootURLs: [URL] = [],
    includedFileExtensions: Set<String> = ExternalSourceIndexConfiguration
      .commonExternalSourceExtensions,
    excludedDirectoryNames: Set<String> = [
      ".git", ".hg", ".svn", ".build", ".swiftpm", "DerivedData", "build", "dist",
      "out", "target", "node_modules", "__pycache__", ".cache", ".idea", ".vscode",
    ],
    includesTestsAndExamples: Bool = false,
    maximumFileCount: Int = 32_000,
    maximumFileCountPerPackage: Int = 6_000,
    maximumFileSize: Int = 2 * 1024 * 1024,
    maximumDirectoryDepth: Int = 16
  ) {
    self.isEnabled = isEnabled
    self.discoversPackageRootsAutomatically = discoversPackageRootsAutomatically
    self.explicitRootURLs = explicitRootURLs.map(\.standardizedFileURL)
    self.includedFileExtensions = Set(
      includedFileExtensions.map {
        $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      }
    )
    self.excludedDirectoryNames = excludedDirectoryNames
    self.includesTestsAndExamples = includesTestsAndExamples
    self.maximumFileCount = max(1, maximumFileCount)
    self.maximumFileCountPerPackage = max(1, maximumFileCountPerPackage)
    self.maximumFileSize = max(1, maximumFileSize)
    self.maximumDirectoryDepth = max(1, maximumDirectoryDepth)
  }
}

public struct SourceWorkspaceConfiguration: Hashable, Codable, Sendable {
  public static let commonSourceExtensions: Set<String> = [
    "swift", "c", "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "hxx",
    "rs", "go", "java", "kt", "kts", "js", "jsx", "ts", "tsx", "py",
    "rb", "php", "cs", "fs", "fsx", "scala", "lua", "sh", "bash", "zsh",
    "fish", "sql", "html", "htm", "css", "scss", "sass", "less", "xml",
    "json", "jsonc", "yaml", "yml", "toml", "ini", "cfg", "md", "txt",
    "proto", "graphql", "gql", "metal", "glsl", "wgsl", "cmake",
    "swiftinterface", "modulemap", "inc", "ipp", "tcc",
    "pyi", "pyw", "hh", "jsx", "mjs", "cjs", "mts", "cts", "java",
    "hs", "lhs", "ml", "mli", "ex", "exs", "erl", "hrl", "dart", "r",
    "rmd", "jl", "zig", "nim", "nims", "clj", "cljs", "cljc", "edn",
    "tf", "tfvars", "hcl", "vue", "svelte", "dockerfile",
  ]

  public var includedFileExtensions: Set<String>?
  public var languageCatalog: EditorLanguageCatalog
  public var excludedDirectoryNames: Set<String>
  public var excludedFileNames: Set<String>
  public var includeHiddenItems: Bool
  public var followSymbolicLinks: Bool
  public var maximumFileSize: Int
  public var externalSourceIndex: ExternalSourceIndexConfiguration?

  public init(
    includedFileExtensions: Set<String>? = SourceWorkspaceConfiguration.commonSourceExtensions,
    languageCatalog: EditorLanguageCatalog = .standard,
    excludedDirectoryNames: Set<String> = [
      ".git", ".build", ".swiftpm", "DerivedData", "Pods", "Carthage", "node_modules",
      "Vendor",
    ],
    excludedFileNames: Set<String> = [".DS_Store"],
    includeHiddenItems: Bool = false,
    followSymbolicLinks: Bool = false,
    maximumFileSize: Int = 8 * 1024 * 1024,
    externalSourceIndex: ExternalSourceIndexConfiguration? = .init()
  ) {
    self.includedFileExtensions = includedFileExtensions.map {
      Set($0.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
    }
    self.languageCatalog = languageCatalog
    self.excludedDirectoryNames = excludedDirectoryNames
    self.excludedFileNames = excludedFileNames
    self.includeHiddenItems = includeHiddenItems
    self.followSymbolicLinks = followSymbolicLinks
    self.maximumFileSize = max(1, maximumFileSize)
    self.externalSourceIndex = externalSourceIndex
  }
}

public enum SourceWorkspaceError: Error, Equatable, Sendable {
  case invalidRelativePath(String)
  case pathOutsideWorkspace(URL)
  case symbolicLinkEscape(URL)
  case fileAlreadyExists(String)
  case fileNotFound(String)
  case directoryNotFound(String)
  case destinationAlreadyExists(String)
  case invalidUTF8(String)
  case fileTooLarge(String, Int)
  case fileConflict(String)
  case fileMissingOnDisk(String)
  case versionMismatch(String, expected: Int, actual: Int)
  case versionOverflow(String)
  case directoryNotEmpty(String)
  case rootMutationNotAllowed
  case invalidSearchPattern(String)
  case invalidArchive(String)
  case invalidBatch(String)
  case operationInProgress(String)
  case invalidLineEnding(SourceLineEnding)
  case io(String)
}

extension SourceWorkspaceError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidRelativePath(let path): return "Invalid workspace-relative path: \(path)"
    case .pathOutsideWorkspace(let url):
      return "The path is outside the source workspace: \(url.path)"
    case .symbolicLinkEscape(let url):
      return "A symbolic link escapes the source workspace: \(url.path)"
    case .fileAlreadyExists(let path): return "A source file already exists at \(path)."
    case .fileNotFound(let path): return "No source file is stored at \(path)."
    case .directoryNotFound(let path): return "No directory exists at \(path)."
    case .destinationAlreadyExists(let path): return "The destination already exists: \(path)"
    case .invalidUTF8(let path): return "The source file is not valid UTF-8: \(path)"
    case .fileTooLarge(let path, let bytes):
      return "The source file is too large (\(bytes) bytes): \(path)"
    case .fileConflict(let path):
      return "The source file changed both in memory and on disk: \(path)"
    case .fileMissingOnDisk(let path): return "The source file is missing on disk: \(path)"
    case .versionMismatch(let path, let expected, let actual):
      return "Expected source version \(expected), but \(path) is version \(actual)."
    case .versionOverflow(let path): return "The source version overflowed for \(path)."
    case .directoryNotEmpty(let path): return "The directory is not empty: \(path)"
    case .rootMutationNotAllowed: return "The workspace root cannot be renamed or deleted."
    case .invalidSearchPattern(let pattern): return "Invalid source-search pattern: \(pattern)"
    case .invalidArchive(let message): return "Invalid source-workspace archive: \(message)"
    case .invalidBatch(let message): return "Invalid source-workspace batch: \(message)"
    case .operationInProgress(let path):
      return "A disk operation is already in progress for \(path)."
    case .invalidLineEnding(let ending):
      return "The line ending \(ending.rawValue) cannot be used for conversion."
    case .io(let message): return message
    }
  }
}

public enum SourceSearchPattern: Hashable, Codable, Sendable {
  case literal(String)
  case regularExpression(String)
}

public struct SourceSearchOptions: Hashable, Codable, Sendable {
  public var caseSensitive: Bool
  public var wholeWord: Bool
  public var maximumResults: Int
  public var includedFileExtensions: Set<String>?

  public init(
    caseSensitive: Bool = true,
    wholeWord: Bool = false,
    maximumResults: Int = 1_000,
    includedFileExtensions: Set<String>? = nil
  ) {
    self.caseSensitive = caseSensitive
    self.wholeWord = wholeWord
    self.maximumResults = max(1, maximumResults)
    self.includedFileExtensions = includedFileExtensions.map {
      Set($0.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
    }
  }
}

public struct SourceSearchMatch: Hashable, Codable, Sendable, Identifiable {
  public let id: String
  public let fileID: SourceFileID
  public let relativePath: String
  public let range: EditorTextRange
  public let matchedText: String
  public let lineText: String

  public init(
    fileID: SourceFileID,
    relativePath: String,
    range: EditorTextRange,
    matchedText: String,
    lineText: String
  ) {
    self.id =
      "\(fileID.description):\(range.start.line):\(range.start.utf16Column):\(range.end.utf16Column)"
    self.fileID = fileID
    self.relativePath = relativePath
    self.range = range
    self.matchedText = matchedText
    self.lineText = lineText
  }
}

/// A portable, root-independent representation of one source file.
public struct SourceWorkspaceArchiveFile: Hashable, Codable, Sendable, Identifiable {
  public let id: SourceFileID
  public let relativePath: String
  public let languageID: String
  public let content: String
  public let version: Int
  public let savedVersion: Int?
  public let encoding: SourceTextEncoding
  public let lineEnding: SourceLineEnding

  public init(
    id: SourceFileID,
    relativePath: String,
    languageID: String,
    content: String,
    version: Int,
    savedVersion: Int?,
    encoding: SourceTextEncoding,
    lineEnding: SourceLineEnding
  ) {
    self.id = id
    self.relativePath = relativePath
    self.languageID = languageID
    self.content = content
    self.version = version
    self.savedVersion = savedVersion
    self.encoding = encoding
    self.lineEnding = lineEnding
  }

  public init(file: SourceCodeFile) {
    self.init(
      id: file.id,
      relativePath: file.relativePath,
      languageID: file.languageID,
      content: file.content,
      version: file.version,
      savedVersion: file.savedVersion,
      encoding: file.encoding,
      lineEnding: file.lineEnding
    )
  }
}

/// A portable archive containing every source path and its complete content.
///
/// Unlike ``SourceWorkspaceSnapshot``, this type intentionally omits absolute
/// URLs and disk fingerprints, so it can be restored under a different root.
public struct SourceWorkspaceArchive: Hashable, Codable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let workspaceName: String
  public let exportedAt: Date
  public let revision: Int
  public let files: [SourceWorkspaceArchiveFile]

  public init(
    schemaVersion: Int = SourceWorkspaceArchive.currentSchemaVersion,
    workspaceName: String,
    exportedAt: Date = Date(),
    revision: Int,
    files: [SourceWorkspaceArchiveFile]
  ) {
    self.schemaVersion = schemaVersion
    self.workspaceName = workspaceName
    self.exportedAt = exportedAt
    self.revision = revision
    self.files = files
  }
}

public enum SourceWorkspaceRestorePolicy: String, Hashable, Codable, Sendable {
  /// Replace the complete in-memory workspace with the archive.
  case replace
  /// Import only files whose IDs and paths do not already exist.
  case mergeKeepingExisting
  /// Replace existing files when either their stable ID or path collides.
  case mergeReplacingExisting
}

public enum SourceWorkspaceRestoreMode: String, Hashable, Codable, Sendable {
  /// Restore all files as unsaved in-memory source files without reading disk.
  case memoryOnly
  /// Compare imported content with disk and mark files clean, created, or conflicted.
  case reconcileWithDisk
}

public struct SourceWorkspaceRestoreReport: Hashable, Codable, Sendable {
  public let imported: [SourceFileID]
  public let replaced: [SourceFileID]
  public let skipped: [SourceFileID]

  public init(
    imported: [SourceFileID] = [],
    replaced: [SourceFileID] = [],
    skipped: [SourceFileID] = []
  ) {
    self.imported = imported
    self.replaced = replaced
    self.skipped = skipped
  }
}

/// One optimistic-concurrency guarded full-content update.
public struct SourceFileContentUpdate: Hashable, Codable, Sendable {
  public let fileID: SourceFileID
  public let content: String
  public let expectedVersion: Int?

  public init(fileID: SourceFileID, content: String, expectedVersion: Int? = nil) {
    self.fileID = fileID
    self.content = content
    self.expectedVersion = expectedVersion
  }
}

public struct SourceWorkspaceMetrics: Hashable, Codable, Sendable {
  public let fileCount: Int
  public let totalUTF8Bytes: Int
  public let totalLines: Int
  public let dirtyFileCount: Int
  public let conflictedFileCount: Int
  public let missingFileCount: Int
  public let filesByLanguage: [String: Int]

  public init(
    fileCount: Int,
    totalUTF8Bytes: Int,
    totalLines: Int,
    dirtyFileCount: Int,
    conflictedFileCount: Int,
    missingFileCount: Int,
    filesByLanguage: [String: Int]
  ) {
    self.fileCount = fileCount
    self.totalUTF8Bytes = totalUTF8Bytes
    self.totalLines = totalLines
    self.dirtyFileCount = dirtyFileCount
    self.conflictedFileCount = conflictedFileCount
    self.missingFileCount = missingFileCount
    self.filesByLanguage = filesByLanguage
  }
}

/// One optimistic-concurrency guarded group of text edits for a source file.
public struct SourceFileEditBatch: Hashable, Codable, Sendable {
  public let fileID: SourceFileID
  public let edits: [TextEdit]
  public let expectedVersion: Int?

  public init(fileID: SourceFileID, edits: [TextEdit], expectedVersion: Int? = nil) {
    self.fileID = fileID
    self.edits = edits
    self.expectedVersion = expectedVersion
  }
}

extension SourceLineEnding {
  /// Converts every newline sequence in `text` to this explicit style.
  public func converting(_ text: String) throws -> String {
    let separator: String
    switch self {
    case .lineFeed: separator = "\n"
    case .carriageReturnLineFeed: separator = "\r\n"
    case .carriageReturn: separator = "\r"
    case .none, .mixed: throw SourceWorkspaceError.invalidLineEnding(self)
    }
    let normalized =
      text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    return normalized.replacingOccurrences(of: "\n", with: separator)
  }
}

public struct SourceFileReplacement: Hashable, Codable, Sendable, Identifiable {
  public var id: SourceFileID { fileID }
  public let fileID: SourceFileID
  public let relativePath: String
  public let expectedVersion: Int
  public let edits: [TextEdit]

  public init(
    fileID: SourceFileID,
    relativePath: String,
    expectedVersion: Int,
    edits: [TextEdit]
  ) {
    self.fileID = fileID
    self.relativePath = relativePath
    self.expectedVersion = expectedVersion
    self.edits = edits
  }
}

/// An immutable project-wide replacement plan that can be previewed before application.
public struct SourceReplacementPreview: Hashable, Codable, Sendable {
  public let workspaceRevision: Int
  public let pattern: SourceSearchPattern
  public let replacementTemplate: String
  public let options: SourceSearchOptions
  public let files: [SourceFileReplacement]
  public let matchCount: Int

  public init(
    workspaceRevision: Int,
    pattern: SourceSearchPattern,
    replacementTemplate: String,
    options: SourceSearchOptions,
    files: [SourceFileReplacement],
    matchCount: Int
  ) {
    self.workspaceRevision = workspaceRevision
    self.pattern = pattern
    self.replacementTemplate = replacementTemplate
    self.options = options
    self.files = files
    self.matchCount = matchCount
  }
}

extension SourceWorkspaceConfiguration {
  private enum CodingKeys: String, CodingKey {
    case includedFileExtensions
    case languageCatalog
    case excludedDirectoryNames
    case excludedFileNames
    case includeHiddenItems
    case followSymbolicLinks
    case maximumFileSize
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let includedFileExtensions: Set<String>?
    if container.contains(.includedFileExtensions) {
      includedFileExtensions = try container.decodeIfPresent(
        Set<String>.self,
        forKey: .includedFileExtensions
      )
    } else {
      includedFileExtensions = SourceWorkspaceConfiguration.commonSourceExtensions
    }
    self.init(
      includedFileExtensions: includedFileExtensions,
      languageCatalog: try container.decodeIfPresent(
        EditorLanguageCatalog.self,
        forKey: .languageCatalog
      ) ?? .standard,
      excludedDirectoryNames: try container.decodeIfPresent(
        Set<String>.self,
        forKey: .excludedDirectoryNames
      ) ?? SourceWorkspaceConfiguration().excludedDirectoryNames,
      excludedFileNames: try container.decodeIfPresent(
        Set<String>.self,
        forKey: .excludedFileNames
      ) ?? SourceWorkspaceConfiguration().excludedFileNames,
      includeHiddenItems: try container.decodeIfPresent(
        Bool.self,
        forKey: .includeHiddenItems
      ) ?? false,
      followSymbolicLinks: try container.decodeIfPresent(
        Bool.self,
        forKey: .followSymbolicLinks
      ) ?? false,
      maximumFileSize: try container.decodeIfPresent(
        Int.self,
        forKey: .maximumFileSize
      ) ?? 8 * 1024 * 1024
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(includedFileExtensions, forKey: .includedFileExtensions)
    try container.encode(languageCatalog, forKey: .languageCatalog)
    try container.encode(excludedDirectoryNames, forKey: .excludedDirectoryNames)
    try container.encode(excludedFileNames, forKey: .excludedFileNames)
    try container.encode(includeHiddenItems, forKey: .includeHiddenItems)
    try container.encode(followSymbolicLinks, forKey: .followSymbolicLinks)
    try container.encode(maximumFileSize, forKey: .maximumFileSize)
  }
}
