import EditorCore
import Foundation

/// Owns a complete, editable source tree rooted at one directory.
///
/// The workspace stores source contents even when files are not open in the editor,
/// tracks clean/dirty/conflicted state, validates every relative path, and performs
/// atomic persistence. Open editor documents can mirror their exact snapshots with
/// ``synchronizeOpenDocument(at:snapshot:languageID:)``.
public actor SourceWorkspace {
  private struct Record: Sendable {
    var id: SourceFileID
    var relativePath: String
    var languageID: String
    var buffer: TextBuffer
    var savedVersion: Int?
    var encoding: SourceTextEncoding
    var lineEnding: SourceLineEnding
    var state: SourceFileState
    var persistedContentHash: UInt64?
    var persistedEncoding: SourceTextEncoding?
    var diskFingerprint: SourceDiskFingerprint?
  }

  private struct DiskSource: Sendable {
    var relativePath: String
    var content: String
    var encoding: SourceTextEncoding
    var lineEnding: SourceLineEnding
    var logicalContentHash: UInt64
    var fingerprint: SourceDiskFingerprint
  }

  private struct ScanOutput: Sendable {
    var files: [DiskSource]
    var skipped: [SourceWorkspaceSkippedFile]
  }

  private struct ArchiveDiskState: Sendable {
    var relativePath: String
    var source: DiskSource?
  }

  private final class TreeBuilderNode {
    let name: String
    let relativePath: String
    var directories: [String: TreeBuilderNode] = [:]
    var files: [SourceCodeFileSummary] = []

    init(name: String, relativePath: String) {
      self.name = name
      self.relativePath = relativePath
    }
  }

  public nonisolated let rootURL: URL
  public let configuration: SourceWorkspaceConfiguration

  private var recordsByID: [SourceFileID: Record] = [:]
  private var idByRelativePath: [String: SourceFileID] = [:]
  private var revision: Int = 0
  private var activeFileIO: Set<SourceFileID> = []
  private var eventContinuations: [UUID: AsyncStream<SourceWorkspaceEvent>.Continuation] = [:]

  public init(rootURL: URL, configuration: SourceWorkspaceConfiguration = .init()) {
    self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    self.configuration = configuration
  }

  /// Creates an independent event stream. Every subscriber receives every future event.
  public func events() -> AsyncStream<SourceWorkspaceEvent> {
    let token = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
      eventContinuations[token] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeEventContinuation(token) }
      }
    }
  }

  /// Returns whether a file URL is lexically and physically contained by this workspace.
  public func contains(_ url: URL) -> Bool {
    guard let path = try? relativePath(for: url), !path.isEmpty else { return false }
    return (try? validatedURL(for: path)) != nil
  }

  /// Scans disk and merges source files without discarding unsaved memory edits.
  @discardableResult
  public func scan() async throws -> SourceWorkspaceScanReport {
    let root = rootURL
    let configuration = configuration
    let output: ScanOutput
    do {
      output = try await Task.detached {
        try Self.scanDisk(rootURL: root, configuration: configuration)
      }.value
    } catch let error as SourceWorkspaceError {
      throw error
    } catch {
      throw SourceWorkspaceError.io("Could not scan \(root.path): \(error)")
    }

    let diskByPath = Dictionary(uniqueKeysWithValues: output.files.map { ($0.relativePath, $0) })
    var added: [SourceFileID] = []
    var refreshed: [SourceFileID] = []
    var conflicted: [SourceFileID] = []
    var missing: [SourceFileID] = []

    for disk in output.files.sorted(by: { $0.relativePath < $1.relativePath }) {
      if let id = idByRelativePath[disk.relativePath], var record = recordsByID[id] {
        guard !activeFileIO.contains(id) else { continue }
        let memoryHash = Self.hash(Data(record.buffer.text.utf8))
        let diskChanged = record.diskFingerprint?.contentHash != disk.fingerprint.contentHash
        if diskChanged {
          let memoryChanged =
            record.persistedContentHash == nil
            || memoryHash != record.persistedContentHash
            || record.persistedEncoding != record.encoding
          if memoryChanged {
            record.state = .conflicted
            record.diskFingerprint = disk.fingerprint
            recordsByID[id] = record
            conflicted.append(id)
            emit(.conflict(materialize(record)))
          } else {
            let next = try nextVersion(after: record.buffer.version, path: record.relativePath)
            record.buffer = TextBuffer(text: disk.content, version: next)
            record.savedVersion = next
            record.encoding = disk.encoding
            record.lineEnding = disk.lineEnding
            record.state = .clean
            record.persistedContentHash = disk.logicalContentHash
            record.persistedEncoding = disk.encoding
            record.diskFingerprint = disk.fingerprint
            recordsByID[id] = record
            refreshed.append(id)
            emit(.reloaded(materialize(record)))
          }
        } else if record.state == .missing {
          record.state =
            memoryHash == disk.logicalContentHash && record.encoding == disk.encoding
            ? .clean : .modified
          record.persistedEncoding = disk.encoding
          record.diskFingerprint = disk.fingerprint
          recordsByID[id] = record
          refreshed.append(id)
          emit(.changed(materialize(record)))
        } else {
          record.diskFingerprint = disk.fingerprint
          record.encoding = disk.encoding
          record.persistedEncoding = disk.encoding
          record.lineEnding = disk.lineEnding
          recordsByID[id] = record
        }
      } else {
        let id = SourceFileID()
        let record = Record(
          id: id,
          relativePath: disk.relativePath,
          languageID: configuration.languageCatalog.languageID(forPath: disk.relativePath),
          buffer: TextBuffer(text: disk.content),
          savedVersion: 0,
          encoding: disk.encoding,
          lineEnding: disk.lineEnding,
          state: .clean,
          persistedContentHash: disk.logicalContentHash,
          persistedEncoding: disk.encoding,
          diskFingerprint: disk.fingerprint
        )
        recordsByID[id] = record
        idByRelativePath[disk.relativePath] = id
        added.append(id)
        emit(.added(materialize(record)))
      }
    }

    let presentPaths = Set(diskByPath.keys)
    for (id, var record) in Array(recordsByID) where !presentPaths.contains(record.relativePath) {
      guard !activeFileIO.contains(id) else { continue }
      guard record.diskFingerprint != nil || record.state == .clean else { continue }
      if record.state != .missing {
        record.state = .missing
        record.diskFingerprint = nil
        recordsByID[id] = record
        missing.append(id)
        emit(.changed(materialize(record)))
      }
    }

    if !added.isEmpty || !refreshed.isEmpty || !conflicted.isEmpty || !missing.isEmpty {
      incrementRevision()
    }
    let report = SourceWorkspaceScanReport(
      added: added,
      refreshed: refreshed,
      conflicted: conflicted,
      missing: missing,
      skipped: output.skipped
    )
    emit(.scanned(report))
    return report
  }

  public func snapshot() -> SourceWorkspaceSnapshot {
    let files = recordsByID.values.map(materialize).sorted { $0.relativePath < $1.relativePath }
    return SourceWorkspaceSnapshot(
      rootURL: rootURL,
      revision: revision,
      files: files,
      tree: buildTree(files: files)
    )
  }

  /// Encodes the complete in-memory source tree, including every file's content and path.
  public func encodedSnapshot(prettyPrinted: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
    return try encoder.encode(snapshot())
  }

  /// Returns a portable archive containing every source path and complete content.
  public func archive() -> SourceWorkspaceArchive {
    let current = snapshot()
    return SourceWorkspaceArchive(
      workspaceName: rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent,
      revision: current.revision,
      files: current.files.map(SourceWorkspaceArchiveFile.init(file:))
    )
  }

  /// Encodes a root-independent archive suitable for persistence or transfer.
  public func encodedArchive(prettyPrinted: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
    return try encoder.encode(archive())
  }

  /// Decodes and transactionally restores a portable source archive.
  @discardableResult
  public func restore(
    from data: Data,
    policy: SourceWorkspaceRestorePolicy = .replace,
    mode: SourceWorkspaceRestoreMode = .reconcileWithDisk
  ) async throws -> SourceWorkspaceRestoreReport {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let archive: SourceWorkspaceArchive
    do { archive = try decoder.decode(SourceWorkspaceArchive.self, from: data) } catch {
      throw SourceWorkspaceError.invalidArchive(String(describing: error))
    }
    return try await restore(from: archive, policy: policy, mode: mode)
  }

  /// Transactionally restores all source contents into this workspace's root.
  ///
  /// Restoration changes only the in-memory source store. Call ``saveAll`` to
  /// materialize created or conflicted archive files on disk.
  @discardableResult
  public func restore(
    from archive: SourceWorkspaceArchive,
    policy: SourceWorkspaceRestorePolicy = .replace,
    mode: SourceWorkspaceRestoreMode = .reconcileWithDisk
  ) async throws -> SourceWorkspaceRestoreReport {
    guard activeFileIO.isEmpty else {
      throw SourceWorkspaceError.operationInProgress("workspace restore")
    }
    guard archive.schemaVersion == SourceWorkspaceArchive.currentSchemaVersion else {
      throw SourceWorkspaceError.invalidArchive(
        "Unsupported schema version \(archive.schemaVersion); expected \(SourceWorkspaceArchive.currentSchemaVersion)."
      )
    }

    var seenIDs: Set<SourceFileID> = []
    var seenPaths: Set<String> = []
    var normalized: [(file: SourceWorkspaceArchiveFile, path: String, url: URL)] = []
    normalized.reserveCapacity(archive.files.count)
    for file in archive.files {
      guard file.version >= 0 else {
        throw SourceWorkspaceError.invalidArchive("Negative version for \(file.relativePath).")
      }
      if let savedVersion = file.savedVersion,
        savedVersion < 0 || savedVersion > file.version
      {
        throw SourceWorkspaceError.invalidArchive("Invalid saved version for \(file.relativePath).")
      }
      guard seenIDs.insert(file.id).inserted else {
        throw SourceWorkspaceError.invalidArchive("Duplicate file ID \(file.id).")
      }
      let path = try normalizeFilePath(file.relativePath)
      guard seenPaths.insert(path).inserted else {
        throw SourceWorkspaceError.invalidArchive("Duplicate path \(path).")
      }
      try validateContentSize(file.content, path: path)
      normalized.append((file, path, try validatedURL(for: path)))
    }

    var diskByPath: [String: DiskSource] = [:]
    if mode == .reconcileWithDisk {
      let maximum = configuration.maximumFileSize
      let states = try await withThrowingTaskGroup(of: ArchiveDiskState.self) { group in
        for entry in normalized {
          group.addTask {
            guard FileManager.default.fileExists(atPath: entry.url.path) else {
              return ArchiveDiskState(relativePath: entry.path, source: nil)
            }
            return ArchiveDiskState(
              relativePath: entry.path,
              source: try Self.readDiskSource(
                url: entry.url,
                relativePath: entry.path,
                maximumFileSize: maximum
              )
            )
          }
        }
        var output: [ArchiveDiskState] = []
        output.reserveCapacity(normalized.count)
        for try await state in group { output.append(state) }
        return output
      }
      diskByPath = Dictionary(
        uniqueKeysWithValues: states.compactMap { state in
          state.source.map { (state.relativePath, $0) }
        })
    }

    let oldRecords = recordsByID
    var stagedRecords: [SourceFileID: Record]
    var stagedPaths: [String: SourceFileID]
    switch policy {
    case .replace:
      stagedRecords = [:]
      stagedPaths = [:]
    case .mergeKeepingExisting, .mergeReplacingExisting:
      stagedRecords = recordsByID
      stagedPaths = idByRelativePath
    }

    var imported: [SourceFileID] = []
    var replaced: [SourceFileID] = []
    var skipped: [SourceFileID] = []

    for entry in normalized.sorted(by: { $0.path < $1.path }) {
      let file = entry.file
      let pathCollision = stagedPaths[entry.path]
      let idCollision = stagedRecords[file.id]
      if policy == .mergeKeepingExisting,
        pathCollision != nil || idCollision != nil
      {
        skipped.append(file.id)
        continue
      }
      if policy == .mergeReplacingExisting {
        if let pathCollision, pathCollision != file.id,
          let removed = stagedRecords.removeValue(forKey: pathCollision)
        {
          stagedPaths.removeValue(forKey: removed.relativePath)
          replaced.append(pathCollision)
        }
        if let idCollision, idCollision.relativePath != entry.path {
          stagedPaths.removeValue(forKey: idCollision.relativePath)
          stagedRecords.removeValue(forKey: file.id)
          replaced.append(file.id)
        }
      }

      let disk = diskByPath[entry.path]
      let archiveHash = Self.hash(Data(file.content.utf8))
      let state: SourceFileState
      let savedVersion: Int?
      let persistedHash: UInt64?
      let fingerprint: SourceDiskFingerprint?
      let encoding: SourceTextEncoding
      let lineEnding: SourceLineEnding
      if mode == .memoryOnly {
        state = .created
        savedVersion = nil
        persistedHash = nil
        fingerprint = nil
        encoding = file.encoding
        lineEnding = file.lineEnding
      } else if let disk {
        fingerprint = disk.fingerprint
        if disk.logicalContentHash == archiveHash {
          state = .clean
          savedVersion = file.version
          persistedHash = archiveHash
          encoding = disk.encoding
          lineEnding = disk.lineEnding
        } else {
          state = .conflicted
          savedVersion = file.savedVersion
          persistedHash = disk.logicalContentHash
          encoding = file.encoding
          lineEnding = file.lineEnding
        }
      } else {
        state = .created
        savedVersion = nil
        persistedHash = nil
        fingerprint = nil
        encoding = file.encoding
        lineEnding = file.lineEnding
      }

      stagedRecords[file.id] = Record(
        id: file.id,
        relativePath: entry.path,
        languageID: file.languageID.isEmpty
          ? configuration.languageCatalog.languageID(forPath: entry.path)
          : file.languageID,
        buffer: TextBuffer(text: file.content, version: file.version),
        savedVersion: savedVersion,
        encoding: encoding,
        lineEnding: lineEnding,
        state: state,
        persistedContentHash: persistedHash,
        persistedEncoding: disk?.encoding,
        diskFingerprint: fingerprint
      )
      stagedPaths[entry.path] = file.id
      if oldRecords[file.id] != nil || pathCollision != nil {
        replaced.append(file.id)
      } else {
        imported.append(file.id)
      }
    }

    // Commit only after every archive entry and disk reconciliation succeeded.
    recordsByID = stagedRecords
    idByRelativePath = stagedPaths
    incrementRevision()

    let newIDs = Set(stagedRecords.keys)
    for old in oldRecords.values where !newIDs.contains(old.id) {
      emit(.removed(id: old.id, relativePath: old.relativePath))
    }
    for id in imported {
      if let record = stagedRecords[id] { emit(.added(materialize(record))) }
    }
    for id in Set(replaced) {
      if let record = stagedRecords[id] { emit(.changed(materialize(record))) }
    }
    let report = SourceWorkspaceRestoreReport(
      imported: imported.sorted { $0.description < $1.description },
      replaced: Array(Set(replaced)).sorted { $0.description < $1.description },
      skipped: skipped.sorted { $0.description < $1.description }
    )
    emit(.restored(report))
    return report
  }

  package func reportScanFailure(_ message: String) {
    emit(.scanFailed(message))
  }

  public func files() -> [SourceCodeFile] {
    recordsByID.values.map(materialize).sorted { $0.relativePath < $1.relativePath }
  }

  public func file(id: SourceFileID) throws -> SourceCodeFile {
    guard let record = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(id.description)
    }
    return materialize(record)
  }

  public func file(relativePath: String) throws -> SourceCodeFile {
    let path = try normalize(relativePath)
    guard let id = idByRelativePath[path], let record = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(path)
    }
    return materialize(record)
  }

  public func file(at url: URL) throws -> SourceCodeFile {
    try file(relativePath: relativePath(for: url))
  }

  public func relativePath(for url: URL) throws -> String {
    let candidate = url.standardizedFileURL
    let rootPath = rootURL.path
    let path = candidate.path
    guard path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    else {
      throw SourceWorkspaceError.pathOutsideWorkspace(url)
    }
    guard path != rootPath else { return "" }
    return try normalize(String(path.dropFirst(rootPath.count + (rootPath.hasSuffix("/") ? 0 : 1))))
  }

  public func url(forRelativePath relativePath: String) throws -> URL {
    let path = try normalize(relativePath)
    return try validatedURL(for: path)
  }

  /// Registers or updates a file from an authoritative open editor snapshot.
  /// Files outside the workspace are ignored and return `nil`.
  @discardableResult
  public func synchronizeOpenDocument(
    at url: URL,
    snapshot: TextSnapshot,
    languageID: String? = nil,
    markExternalConflict: Bool = false
  ) throws -> SourceCodeFile? {
    guard let relativePath = try? relativePath(for: url), !relativePath.isEmpty else { return nil }
    _ = try validatedURL(for: relativePath)
    try validateContentSize(snapshot.text, path: relativePath)
    let id = idByRelativePath[relativePath] ?? SourceFileID()
    var record =
      recordsByID[id]
      ?? Record(
        id: id,
        relativePath: relativePath,
        languageID: languageID ?? configuration.languageCatalog.languageID(forPath: relativePath),
        buffer: TextBuffer(text: snapshot.text, version: snapshot.version),
        savedVersion: nil,
        encoding: .utf8,
        lineEnding: Self.detectLineEnding(snapshot.text),
        state: .created,
        persistedContentHash: nil,
        persistedEncoding: nil,
        diskFingerprint: nil
      )
    let wasKnown = recordsByID[id] != nil
    let oldContent = record.buffer.text
    record.buffer = TextBuffer(text: snapshot.text, version: snapshot.version)
    record.languageID = languageID ?? record.languageID
    record.lineEnding = Self.detectLineEnding(snapshot.text)
    let memoryHash = Self.hash(Data(snapshot.text.utf8))
    if markExternalConflict,
      let persisted = record.persistedContentHash,
      memoryHash != persisted
    {
      record.state = .conflicted
    } else {
      record.state = stateForMemory(record)
    }
    recordsByID[id] = record
    idByRelativePath[relativePath] = id
    if oldContent != snapshot.text || !wasKnown {
      incrementRevision()
    }
    let file = materialize(record)
    emit(.changed(file))
    return file
  }

  /// Loads one UTF-8 file from disk without scanning the entire workspace.
  @discardableResult
  public func loadFileFromDisk(at url: URL) async throws -> SourceCodeFile {
    let path = try relativePath(for: url)
    guard !path.isEmpty else { throw SourceWorkspaceError.invalidRelativePath(path) }
    _ = try validatedURL(for: path)
    if let id = idByRelativePath[path], let existing = recordsByID[id] {
      return materialize(existing)
    }
    let maximum = configuration.maximumFileSize
    let source = try await Task.detached { @Sendable in
      try Self.readDiskSource(url: url, relativePath: path, maximumFileSize: maximum)
    }.value
    // The actor can re-enter while disk I/O is running. Reuse a record that
    // another caller installed instead of creating a duplicate stable ID.
    if let id = idByRelativePath[path], let existing = recordsByID[id] {
      return materialize(existing)
    }
    let id = SourceFileID()
    let record = Record(
      id: id,
      relativePath: path,
      languageID: configuration.languageCatalog.languageID(forPath: path),
      buffer: TextBuffer(text: source.content),
      savedVersion: 0,
      encoding: source.encoding,
      lineEnding: source.lineEnding,
      state: .clean,
      persistedContentHash: source.logicalContentHash,
      persistedEncoding: source.encoding,
      diskFingerprint: source.fingerprint
    )
    recordsByID[id] = record
    idByRelativePath[path] = id
    incrementRevision()
    let file = materialize(record)
    emit(.added(file))
    return file
  }

  /// Merges one changed disk file without walking the entire workspace.
  /// Unsaved memory content is preserved and becomes conflicted when disk changed.
  @discardableResult
  public func refreshFileFromDisk(at url: URL) async throws -> SourceCodeFile? {
    let path = try relativePath(for: url)
    guard !path.isEmpty else { throw SourceWorkspaceError.invalidRelativePath(path) }
    let validated = try validatedURL(for: path)

    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: validated.path, isDirectory: &isDirectory)
    guard !isDirectory.boolValue else { return nil }

    if !exists {
      guard let id = idByRelativePath[path], var record = recordsByID[id] else { return nil }
      guard !activeFileIO.contains(id) else { return materialize(record) }
      guard record.diskFingerprint != nil || record.state == .clean else {
        return materialize(record)
      }
      if record.state != .missing {
        record.state = .missing
        record.diskFingerprint = nil
        recordsByID[id] = record
        incrementRevision()
        emit(.changed(materialize(record)))
      }
      return materialize(record)
    }

    if idByRelativePath[path] == nil, !shouldTrackNewDiskFile(path: path, url: validated) {
      return nil
    }

    let maximum = configuration.maximumFileSize
    let disk = try await Task.detached { @Sendable in
      try Self.readDiskSource(url: validated, relativePath: path, maximumFileSize: maximum)
    }.value

    if let id = idByRelativePath[path], var record = recordsByID[id] {
      guard !activeFileIO.contains(id) else { return materialize(record) }
      let memoryHash = Self.hash(Data(record.buffer.text.utf8))
      let diskChanged = record.diskFingerprint?.contentHash != disk.fingerprint.contentHash

      if diskChanged {
        let memoryChanged =
          record.persistedContentHash == nil
          || memoryHash != record.persistedContentHash
          || record.persistedEncoding != record.encoding
        if memoryChanged {
          record.state = .conflicted
          record.diskFingerprint = disk.fingerprint
          recordsByID[id] = record
          incrementRevision()
          let file = materialize(record)
          emit(.conflict(file))
          return file
        }

        let next = try nextVersion(after: record.buffer.version, path: record.relativePath)
        record.buffer = TextBuffer(text: disk.content, version: next)
        record.savedVersion = next
        record.encoding = disk.encoding
        record.lineEnding = disk.lineEnding
        record.state = .clean
        record.persistedContentHash = disk.logicalContentHash
        record.persistedEncoding = disk.encoding
        record.diskFingerprint = disk.fingerprint
        recordsByID[id] = record
        incrementRevision()
        let file = materialize(record)
        emit(.reloaded(file))
        return file
      }

      if record.state == .missing {
        record.state =
          memoryHash == disk.logicalContentHash && record.encoding == disk.encoding
          ? .clean : .modified
        record.persistedEncoding = disk.encoding
        record.diskFingerprint = disk.fingerprint
        recordsByID[id] = record
        incrementRevision()
        let file = materialize(record)
        emit(.changed(file))
        return file
      }

      record.diskFingerprint = disk.fingerprint
      record.encoding = disk.encoding
      record.persistedEncoding = disk.encoding
      record.lineEnding = disk.lineEnding
      recordsByID[id] = record
      return materialize(record)
    }

    let id = SourceFileID()
    let record = Record(
      id: id,
      relativePath: path,
      languageID: configuration.languageCatalog.languageID(forPath: path),
      buffer: TextBuffer(text: disk.content),
      savedVersion: 0,
      encoding: disk.encoding,
      lineEnding: disk.lineEnding,
      state: .clean,
      persistedContentHash: disk.logicalContentHash,
      persistedEncoding: disk.encoding,
      diskFingerprint: disk.fingerprint
    )
    recordsByID[id] = record
    idByRelativePath[path] = id
    incrementRevision()
    let file = materialize(record)
    emit(.added(file))
    return file
  }

  public func dirtyFiles() -> [SourceCodeFile] {
    recordsByID.values
      .filter { $0.state != .clean }
      .map(materialize)
      .sorted { $0.relativePath < $1.relativePath }
  }

  public func files(inDirectory relativePath: String, recursively: Bool = true) throws
    -> [SourceCodeFile]
  {
    if relativePath.isEmpty { return files() }
    let path = try normalizeDirectoryPath(relativePath)
    return recordsByID.values.filter { record in
      guard record.relativePath.hasPrefix(path + "/") else { return false }
      if recursively { return true }
      let remainder = record.relativePath.dropFirst(path.count + 1)
      return !remainder.contains("/")
    }.map(materialize).sorted { $0.relativePath < $1.relativePath }
  }

  /// Searches all stored source contents and returns editor-native UTF-16 ranges.
  public func search(
    _ pattern: SourceSearchPattern,
    options: SourceSearchOptions = .init()
  ) throws -> [SourceSearchMatch] {
    let sourcePattern: String
    switch pattern {
    case .literal(let value):
      guard !value.isEmpty else { return [] }
      sourcePattern = NSRegularExpression.escapedPattern(for: value)
    case .regularExpression(let value):
      guard !value.isEmpty else { return [] }
      sourcePattern = value
    }
    let expressionPattern =
      options.wholeWord
      ? "(?<![\\p{L}\\p{N}_])(?:\(sourcePattern))(?![\\p{L}\\p{N}_])"
      : sourcePattern
    let expression: NSRegularExpression
    do {
      expression = try NSRegularExpression(
        pattern: expressionPattern,
        options: options.caseSensitive ? [] : [.caseInsensitive]
      )
    } catch {
      throw SourceWorkspaceError.invalidSearchPattern(expressionPattern)
    }

    var results: [SourceSearchMatch] = []
    for record in recordsByID.values.sorted(by: { $0.relativePath < $1.relativePath }) {
      if let extensions = options.includedFileExtensions,
        !extensions.contains((record.relativePath as NSString).pathExtension.lowercased())
      {
        continue
      }
      let snapshot = record.buffer.snapshot
      let fullRange = NSRange(location: 0, length: snapshot.utf16Count)
      for match in expression.matches(in: snapshot.text, range: fullRange) {
        guard match.range.location != NSNotFound else { continue }
        let start = try snapshot.position(atUTF16Offset: match.range.location)
        let end = try snapshot.position(atUTF16Offset: NSMaxRange(match.range))
        let matched = (snapshot.text as NSString).substring(with: match.range)
        let lineRange = (snapshot.text as NSString).lineRange(
          for: NSRange(location: match.range.location, length: 0))
        var lineText = (snapshot.text as NSString).substring(with: lineRange)
        lineText = lineText.trimmingCharacters(in: .newlines)
        results.append(
          SourceSearchMatch(
            fileID: record.id,
            relativePath: record.relativePath,
            range: EditorTextRange(start: start, end: end),
            matchedText: matched,
            lineText: lineText
          ))
        if results.count >= options.maximumResults { return results }
      }
    }
    return results
  }

  /// Builds a project-wide replacement plan without mutating any source file.
  ///
  /// For regular expressions, `replacementTemplate` uses Foundation replacement
  /// syntax such as `$1`. For literal searches, the replacement is inserted verbatim.
  public func previewReplacement(
    _ pattern: SourceSearchPattern,
    replacementTemplate: String,
    options: SourceSearchOptions = .init()
  ) throws -> SourceReplacementPreview {
    let expression = try Self.searchExpression(pattern, options: options)
    var fileChanges: [SourceFileReplacement] = []
    var total = 0

    for record in recordsByID.values.sorted(by: { $0.relativePath < $1.relativePath }) {
      if let extensions = options.includedFileExtensions,
        !extensions.contains((record.relativePath as NSString).pathExtension.lowercased())
      {
        continue
      }
      let snapshot = record.buffer.snapshot
      let matches = expression.matches(
        in: snapshot.text,
        range: NSRange(location: 0, length: snapshot.utf16Count)
      )
      if matches.isEmpty { continue }
      var edits: [TextEdit] = []
      for match in matches {
        guard total < options.maximumResults, match.range.location != NSNotFound else { break }
        let start = try snapshot.position(atUTF16Offset: match.range.location)
        let end = try snapshot.position(atUTF16Offset: NSMaxRange(match.range))
        let replacement: String
        switch pattern {
        case .literal:
          replacement = replacementTemplate
        case .regularExpression:
          replacement = expression.replacementString(
            for: match,
            in: snapshot.text,
            offset: 0,
            template: replacementTemplate
          )
        }
        edits.append(TextEdit(range: .init(start: start, end: end), replacement: replacement))
        total += 1
      }
      if !edits.isEmpty {
        fileChanges.append(
          SourceFileReplacement(
            fileID: record.id,
            relativePath: record.relativePath,
            expectedVersion: record.buffer.version,
            edits: edits
          )
        )
      }
      if total >= options.maximumResults { break }
    }

    return SourceReplacementPreview(
      workspaceRevision: revision,
      pattern: pattern,
      replacementTemplate: replacementTemplate,
      options: options,
      files: fileChanges,
      matchCount: total
    )
  }

  /// Applies a previously generated replacement preview as one memory transaction.
  @discardableResult
  public func applyReplacement(_ preview: SourceReplacementPreview) throws -> [SourceCodeFile] {
    try applyAtomically(
      preview.files.map {
        SourceFileEditBatch(
          fileID: $0.fileID,
          edits: $0.edits,
          expectedVersion: $0.expectedVersion
        )
      }
    )
  }

  /// Previews and applies a project-wide replacement atomically.
  @discardableResult
  public func replaceAll(
    _ pattern: SourceSearchPattern,
    with replacementTemplate: String,
    options: SourceSearchOptions = .init()
  ) throws -> [SourceCodeFile] {
    try applyReplacement(
      previewReplacement(
        pattern,
        replacementTemplate: replacementTemplate,
        options: options
      )
    )
  }

  /// Computes project-wide source metrics from the current in-memory contents.
  public func metrics() -> SourceWorkspaceMetrics {
    let records = Array(recordsByID.values)
    var languages: [String: Int] = [:]
    for record in records { languages[record.languageID, default: 0] += 1 }
    return SourceWorkspaceMetrics(
      fileCount: records.count,
      totalUTF8Bytes: records.reduce(0) { $0 + $1.buffer.text.utf8.count },
      totalLines: records.reduce(0) { $0 + $1.buffer.snapshot.lineCount },
      dirtyFileCount: records.filter { $0.state != .clean }.count,
      conflictedFileCount: records.filter { $0.state == .conflicted }.count,
      missingFileCount: records.filter { $0.state == .missing }.count,
      filesByLanguage: languages
    )
  }

  /// Atomically replaces complete contents across multiple source files.
  @discardableResult
  public func setContentsAtomically(_ updates: [SourceFileContentUpdate]) throws
    -> [SourceCodeFile]
  {
    guard Set(updates.map(\.fileID)).count == updates.count else {
      throw SourceWorkspaceError.invalidBatch("A file may appear only once.")
    }
    var staged = recordsByID
    var changed: [SourceFileID] = []
    for update in updates {
      guard var record = staged[update.fileID] else {
        throw SourceWorkspaceError.fileNotFound(update.fileID.description)
      }
      try validateVersion(record, expected: update.expectedVersion)
      try validateContentSize(update.content, path: record.relativePath)
      let next = try nextVersion(after: record.buffer.version, path: record.relativePath)
      record.buffer = TextBuffer(text: update.content, version: next)
      record.lineEnding = Self.detectLineEnding(update.content)
      record.state = stateForMemory(record)
      staged[update.fileID] = record
      changed.append(update.fileID)
    }
    recordsByID = staged
    if !changed.isEmpty { incrementRevision() }
    let files = changed.compactMap { recordsByID[$0].map(materialize) }
    for file in files { emit(.changed(file)) }
    return files
  }

  /// Atomically applies editor-native UTF-16 edits across multiple source files.
  @discardableResult
  public func applyAtomically(_ batches: [SourceFileEditBatch]) throws -> [SourceCodeFile] {
    guard Set(batches.map(\.fileID)).count == batches.count else {
      throw SourceWorkspaceError.invalidBatch("A file may appear only once.")
    }
    var staged = recordsByID
    var changed: [SourceFileID] = []
    for batch in batches {
      guard var record = staged[batch.fileID] else {
        throw SourceWorkspaceError.fileNotFound(batch.fileID.description)
      }
      try validateVersion(record, expected: batch.expectedVersion)
      _ = try record.buffer.apply(batch.edits)
      try validateContentSize(record.buffer.text, path: record.relativePath)
      record.lineEnding = Self.detectLineEnding(record.buffer.text)
      record.state = stateForMemory(record)
      staged[batch.fileID] = record
      changed.append(batch.fileID)
    }
    recordsByID = staged
    if !changed.isEmpty { incrementRevision() }
    let files = changed.compactMap { recordsByID[$0].map(materialize) }
    for file in files { emit(.changed(file)) }
    return files
  }

  @discardableResult
  public func createFile(
    at relativePath: String,
    content: String = "",
    languageID: String? = nil,
    persistImmediately: Bool = true,
    overwrite: Bool = false
  ) async throws -> SourceCodeFile {
    let path = try normalizeFilePath(relativePath)
    try validateContentSize(content, path: path)
    let url = try validatedURL(for: path)
    let existingID = idByRelativePath[path]
    let existingRecord = existingID.flatMap { recordsByID[$0] }
    if let existingID, activeFileIO.contains(existingID) {
      throw SourceWorkspaceError.operationInProgress(path)
    }
    let diskExists = FileManager.default.fileExists(atPath: url.path)

    if existingRecord != nil || diskExists, !overwrite {
      throw SourceWorkspaceError.fileAlreadyExists(path)
    }

    var diskBaseline: DiskSource?
    if diskExists, existingRecord == nil {
      diskBaseline = try Self.readDiskSource(
        url: url,
        relativePath: path,
        maximumFileSize: configuration.maximumFileSize
      )
    }

    let id = existingRecord?.id ?? SourceFileID()
    var record: Record
    if var existingRecord {
      let next = try nextVersion(after: existingRecord.buffer.version, path: path)
      existingRecord.buffer = TextBuffer(text: content, version: next)
      existingRecord.languageID = languageID ?? existingRecord.languageID
      existingRecord.lineEnding = Self.detectLineEnding(content)
      existingRecord.state = stateForMemory(existingRecord)
      record = existingRecord
    } else {
      record = Record(
        id: id,
        relativePath: path,
        languageID: languageID ?? configuration.languageCatalog.languageID(forPath: path),
        buffer: TextBuffer(text: content),
        savedVersion: nil,
        encoding: diskBaseline?.encoding ?? .utf8,
        lineEnding: Self.detectLineEnding(content),
        state: diskBaseline == nil ? .created : .modified,
        persistedContentHash: diskBaseline?.logicalContentHash,
        persistedEncoding: diskBaseline?.encoding,
        diskFingerprint: diskBaseline?.fingerprint
      )
    }

    let previousRecord = existingRecord
    recordsByID[id] = record
    idByRelativePath[path] = id
    incrementRevision()

    if persistImmediately {
      guard activeFileIO.insert(id).inserted else {
        throw SourceWorkspaceError.operationInProgress(path)
      }
      defer { activeFileIO.remove(id) }
      do {
        let originallySaved = record
        let saved = try await saveRecord(record, overwriteExternalChanges: true)
        guard var current = recordsByID[id], current.relativePath == path else {
          throw SourceWorkspaceError.fileNotFound(path)
        }
        if current.buffer.version == originallySaved.buffer.version {
          current = saved
        } else {
          current.savedVersion = originallySaved.buffer.version
          current.persistedContentHash = Self.hash(Data(originallySaved.buffer.text.utf8))
          current.persistedEncoding = originallySaved.encoding
          current.diskFingerprint = saved.diskFingerprint
          current.state = stateForMemory(current)
        }
        recordsByID[id] = current
        record = current
      } catch {
        if let previousRecord {
          recordsByID[id] = previousRecord
          idByRelativePath[path] = id
        } else {
          recordsByID.removeValue(forKey: id)
          idByRelativePath.removeValue(forKey: path)
        }
        incrementRevision()
        throw error
      }
    }
    let file = materialize(record)
    emit(previousRecord == nil ? .added(file) : .changed(file))
    return file
  }

  @discardableResult
  public func setContent(
    _ content: String,
    for id: SourceFileID,
    expectedVersion: Int? = nil
  ) throws -> SourceCodeFile {
    guard var record = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(id.description)
    }
    try validateVersion(record, expected: expectedVersion)
    try validateContentSize(content, path: record.relativePath)
    let next = try nextVersion(after: record.buffer.version, path: record.relativePath)
    record.buffer = TextBuffer(text: content, version: next)
    record.lineEnding = Self.detectLineEnding(content)
    record.state = stateForMemory(record)
    recordsByID[id] = record
    incrementRevision()
    let file = materialize(record)
    emit(.changed(file))
    return file
  }

  @discardableResult
  public func setContent(
    _ content: String,
    at relativePath: String,
    expectedVersion: Int? = nil
  ) throws -> SourceCodeFile {
    let file = try file(relativePath: relativePath)
    return try setContent(content, for: file.id, expectedVersion: expectedVersion)
  }

  @discardableResult
  public func apply(
    _ edit: TextEdit,
    to id: SourceFileID,
    expectedVersion: Int? = nil
  ) throws -> SourceCodeFile {
    try apply([edit], to: id, expectedVersion: expectedVersion)
  }

  @discardableResult
  public func apply(
    _ edits: [TextEdit],
    to id: SourceFileID,
    expectedVersion: Int? = nil
  ) throws -> SourceCodeFile {
    guard var record = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(id.description)
    }
    try validateVersion(record, expected: expectedVersion)
    _ = try record.buffer.apply(edits)
    try validateContentSize(record.buffer.text, path: record.relativePath)
    record.lineEnding = Self.detectLineEnding(record.buffer.text)
    record.state = stateForMemory(record)
    recordsByID[id] = record
    incrementRevision()
    let file = materialize(record)
    emit(.changed(file))
    return file
  }

  /// Overrides the language identifier used by source navigators and future editor opens.
  @discardableResult
  public func setLanguageID(_ languageID: String, for id: SourceFileID) throws -> SourceCodeFile {
    guard var record = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(id.description)
    }
    let normalized = languageID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      throw SourceWorkspaceError.invalidBatch("Language ID cannot be empty.")
    }
    guard normalized != record.languageID else { return materialize(record) }
    record.languageID = normalized
    recordsByID[id] = record
    incrementRevision()
    let file = materialize(record)
    emit(.changed(file))
    return file
  }

  /// Changes whether the next save emits a UTF-8 byte-order mark.
  @discardableResult
  public func setEncoding(_ encoding: SourceTextEncoding, for id: SourceFileID) throws
    -> SourceCodeFile
  {
    guard var record = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(id.description)
    }
    guard encoding != record.encoding else { return materialize(record) }
    record.encoding = encoding
    record.state = stateForMemory(record)
    recordsByID[id] = record
    incrementRevision()
    let file = materialize(record)
    emit(.changed(file))
    return file
  }

  /// Converts all newline sequences to one explicit line-ending style.
  @discardableResult
  public func convertLineEndings(_ ending: SourceLineEnding, for id: SourceFileID) throws
    -> SourceCodeFile
  {
    guard ending == .lineFeed || ending == .carriageReturnLineFeed || ending == .carriageReturn
    else {
      throw SourceWorkspaceError.invalidLineEnding(ending)
    }
    guard var record = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(id.description)
    }
    let converted = try ending.converting(record.buffer.text)
    guard converted != record.buffer.text else {
      record.lineEnding = ending
      recordsByID[id] = record
      return materialize(record)
    }
    let next = try nextVersion(after: record.buffer.version, path: record.relativePath)
    record.buffer = TextBuffer(text: converted, version: next)
    record.lineEnding = ending
    record.state = stateForMemory(record)
    recordsByID[id] = record
    incrementRevision()
    let file = materialize(record)
    emit(.changed(file))
    return file
  }

  @discardableResult
  public func save(
    _ id: SourceFileID,
    overwriteExternalChanges: Bool = false,
    expectedVersion: Int? = nil
  ) async throws -> SourceCodeFile {
    guard let original = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(id.description)
    }
    try validateVersion(original, expected: expectedVersion)
    guard activeFileIO.insert(id).inserted else {
      throw SourceWorkspaceError.operationInProgress(original.relativePath)
    }
    defer { activeFileIO.remove(id) }
    let saved = try await saveRecord(original, overwriteExternalChanges: overwriteExternalChanges)
    guard var current = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(original.relativePath)
    }
    guard current.relativePath == original.relativePath else {
      throw SourceWorkspaceError.operationInProgress(original.relativePath)
    }
    guard current.buffer.version == original.buffer.version else {
      current.savedVersion = original.buffer.version
      current.persistedContentHash = Self.hash(Data(original.buffer.text.utf8))
      current.persistedEncoding = original.encoding
      current.diskFingerprint = saved.diskFingerprint
      current.state = stateForMemory(current)
      recordsByID[id] = current
      incrementRevision()
      emit(.changed(materialize(current)))
      throw SourceWorkspaceError.versionMismatch(
        original.relativePath,
        expected: original.buffer.version,
        actual: current.buffer.version
      )
    }
    recordsByID[id] = saved
    incrementRevision()
    let file = materialize(saved)
    emit(.saved(file))
    return file
  }

  @discardableResult
  public func saveAll(overwriteExternalChanges: Bool = false) async throws -> [SourceCodeFile] {
    var saved: [SourceCodeFile] = []
    for id in recordsByID.values
      .filter({ $0.state != .clean })
      .sorted(by: { $0.relativePath < $1.relativePath })
      .map(\.id)
    {
      saved.append(try await save(id, overwriteExternalChanges: overwriteExternalChanges))
    }
    return saved
  }

  @discardableResult
  public func reloadFromDisk(_ id: SourceFileID) async throws -> SourceCodeFile {
    guard var record = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(id.description)
    }
    guard activeFileIO.insert(id).inserted else {
      throw SourceWorkspaceError.operationInProgress(record.relativePath)
    }
    defer { activeFileIO.remove(id) }
    let relativePath = record.relativePath
    let url = try validatedURL(for: relativePath)
    let maximum = configuration.maximumFileSize
    let disk = try await Task.detached { @Sendable in
      try Self.readDiskSource(url: url, relativePath: relativePath, maximumFileSize: maximum)
    }.value
    guard let current = recordsByID[id], current.buffer.version == record.buffer.version else {
      if var latest = recordsByID[id] {
        latest.diskFingerprint = disk.fingerprint
        latest.state = .conflicted
        recordsByID[id] = latest
        incrementRevision()
        emit(.conflict(materialize(latest)))
        throw SourceWorkspaceError.versionMismatch(
          latest.relativePath,
          expected: record.buffer.version,
          actual: latest.buffer.version
        )
      }
      throw SourceWorkspaceError.fileNotFound(record.relativePath)
    }
    record = current
    let next = try nextVersion(after: record.buffer.version, path: record.relativePath)
    record.buffer = TextBuffer(text: disk.content, version: next)
    record.savedVersion = next
    record.encoding = disk.encoding
    record.lineEnding = disk.lineEnding
    record.state = .clean
    record.persistedContentHash = disk.logicalContentHash
    record.persistedEncoding = disk.encoding
    record.diskFingerprint = disk.fingerprint
    recordsByID[id] = record
    incrementRevision()
    let file = materialize(record)
    emit(.reloaded(file))
    return file
  }

  @discardableResult
  public func resolveConflict(
    _ id: SourceFileID,
    using resolution: SourceWorkspaceConflictResolution
  ) async throws -> SourceCodeFile {
    guard let record = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(id.description)
    }
    guard record.state == .conflicted || record.state == .missing else {
      return materialize(record)
    }
    switch resolution {
    case .useMemory:
      return try await save(id, overwriteExternalChanges: true)
    case .useDisk:
      return try await reloadFromDisk(id)
    }
  }

  @discardableResult
  public func moveFile(
    _ id: SourceFileID,
    to newRelativePath: String,
    moveOnDisk: Bool = true
  ) async throws -> SourceCodeFile {
    guard var record = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(id.description)
    }
    guard !activeFileIO.contains(id) else {
      throw SourceWorkspaceError.operationInProgress(record.relativePath)
    }
    let destination = try normalizeFilePath(newRelativePath)
    guard destination != record.relativePath else { return materialize(record) }
    guard idByRelativePath[destination] == nil else {
      throw SourceWorkspaceError.destinationAlreadyExists(destination)
    }
    let oldPath = record.relativePath
    let oldURL = try validatedURL(for: oldPath)
    let newURL = try validatedURL(for: destination)
    guard !FileManager.default.fileExists(atPath: newURL.path) else {
      throw SourceWorkspaceError.destinationAlreadyExists(destination)
    }

    if moveOnDisk, FileManager.default.fileExists(atPath: oldURL.path) {
      do {
        try FileManager.default.createDirectory(
          at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
      } catch {
        throw SourceWorkspaceError.io("Could not move \(oldPath) to \(destination): \(error)")
      }
    }
    idByRelativePath.removeValue(forKey: oldPath)
    idByRelativePath[destination] = id
    record.relativePath = destination
    record.languageID = configuration.languageCatalog.languageID(forPath: destination)
    if moveOnDisk, record.diskFingerprint != nil {
      record.diskFingerprint = try? Self.fingerprint(url: newURL)
    }
    recordsByID[id] = record
    incrementRevision()
    let file = materialize(record)
    emit(.moved(id: id, oldRelativePath: oldPath, file: file))
    return file
  }

  public func removeFile(
    _ id: SourceFileID,
    deleteFromDisk: Bool = true
  ) async throws {
    guard let record = recordsByID[id] else {
      throw SourceWorkspaceError.fileNotFound(id.description)
    }
    guard !activeFileIO.contains(id) else {
      throw SourceWorkspaceError.operationInProgress(record.relativePath)
    }
    let url = try validatedURL(for: record.relativePath)
    if deleteFromDisk, FileManager.default.fileExists(atPath: url.path) {
      do { try FileManager.default.removeItem(at: url) } catch {
        throw SourceWorkspaceError.io("Could not remove \(record.relativePath): \(error)")
      }
    }
    recordsByID.removeValue(forKey: id)
    idByRelativePath.removeValue(forKey: record.relativePath)
    incrementRevision()
    emit(.removed(id: id, relativePath: record.relativePath))
  }

  public func createDirectory(at relativePath: String) throws {
    let path = try normalizeDirectoryPath(relativePath)
    let url = try validatedURL(for: path)
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw SourceWorkspaceError.io("Could not create directory \(path): \(error)")
    }
    incrementRevision()
  }

  public func moveDirectory(from oldRelativePath: String, to newRelativePath: String) async throws {
    let oldPath = try normalizeDirectoryPath(oldRelativePath)
    let newPath = try normalizeDirectoryPath(newRelativePath)
    guard oldPath != newPath else { return }
    guard !newPath.hasPrefix(oldPath + "/") else {
      throw SourceWorkspaceError.invalidRelativePath(newRelativePath)
    }
    let oldURL = try validatedURL(for: oldPath)
    let newURL = try validatedURL(for: newPath)
    guard FileManager.default.fileExists(atPath: oldURL.path) else {
      throw SourceWorkspaceError.directoryNotFound(oldPath)
    }
    guard !FileManager.default.fileExists(atPath: newURL.path) else {
      throw SourceWorkspaceError.destinationAlreadyExists(newPath)
    }

    let affected = recordsByID.values.filter {
      $0.relativePath == oldPath || $0.relativePath.hasPrefix(oldPath + "/")
    }
    if let active = affected.first(where: { activeFileIO.contains($0.id) }) {
      throw SourceWorkspaceError.operationInProgress(active.relativePath)
    }
    let destinations = affected.map {
      newPath + String($0.relativePath.dropFirst(oldPath.count))
    }
    guard Set(destinations).count == destinations.count,
      destinations.allSatisfy({ idByRelativePath[$0] == nil })
    else { throw SourceWorkspaceError.destinationAlreadyExists(newPath) }

    do {
      try FileManager.default.createDirectory(
        at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: oldURL, to: newURL)
    } catch {
      throw SourceWorkspaceError.io("Could not move directory \(oldPath) to \(newPath): \(error)")
    }

    for var record in affected {
      let oldFilePath = record.relativePath
      let destination = newPath + String(oldFilePath.dropFirst(oldPath.count))
      idByRelativePath.removeValue(forKey: oldFilePath)
      idByRelativePath[destination] = record.id
      record.relativePath = destination
      record.languageID = configuration.languageCatalog.languageID(forPath: destination)
      record.diskFingerprint = try? Self.fingerprint(url: try validatedURL(for: destination))
      recordsByID[record.id] = record
      emit(.moved(id: record.id, oldRelativePath: oldFilePath, file: materialize(record)))
    }
    incrementRevision()
  }

  public func removeDirectory(at relativePath: String, recursively: Bool = false) async throws {
    let path = try normalizeDirectoryPath(relativePath)
    let url = try validatedURL(for: path)
    let affected = recordsByID.values.filter { $0.relativePath.hasPrefix(path + "/") }
    if let active = affected.first(where: { activeFileIO.contains($0.id) }) {
      throw SourceWorkspaceError.operationInProgress(active.relativePath)
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw SourceWorkspaceError.directoryNotFound(path)
    }
    if !recursively {
      let children: [String]
      do { children = try FileManager.default.contentsOfDirectory(atPath: url.path) } catch {
        throw SourceWorkspaceError.io("Could not inspect directory \(path): \(error)")
      }
      guard children.isEmpty else { throw SourceWorkspaceError.directoryNotEmpty(path) }
    }
    do {
      if recursively {
        try Self.removeRecursively(url)
      } else {
        try FileManager.default.removeItem(at: url)
      }
    } catch {
      throw SourceWorkspaceError.io("Could not remove directory \(path): \(error)")
    }
    for record in affected {
      recordsByID.removeValue(forKey: record.id)
      idByRelativePath.removeValue(forKey: record.relativePath)
      emit(.removed(id: record.id, relativePath: record.relativePath))
    }
    incrementRevision()
  }

  private func saveRecord(_ record: Record, overwriteExternalChanges: Bool) async throws -> Record {
    let url = try validatedURL(for: record.relativePath)
    let diskExists = FileManager.default.fileExists(atPath: url.path)
    if diskExists, !overwriteExternalChanges {
      let current = try Self.fingerprint(url: url)
      if let baseline = record.diskFingerprint?.contentHash, current.contentHash != baseline {
        throw SourceWorkspaceError.fileConflict(record.relativePath)
      }
      if record.persistedContentHash == nil {
        throw SourceWorkspaceError.fileAlreadyExists(record.relativePath)
      }
    }
    let data = Self.encode(record.buffer.text, encoding: record.encoding)
    do {
      try await Task.detached {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
      }.value
    } catch {
      throw SourceWorkspaceError.io("Could not save \(record.relativePath): \(error)")
    }
    var saved = record
    let fingerprint = try Self.fingerprint(url: url)
    saved.savedVersion = record.buffer.version
    saved.state = .clean
    saved.persistedContentHash = Self.hash(Data(record.buffer.text.utf8))
    saved.persistedEncoding = record.encoding
    saved.diskFingerprint = fingerprint
    return saved
  }

  private func validateContentSize(_ content: String, path: String) throws {
    let byteCount = content.utf8.count
    guard byteCount <= configuration.maximumFileSize else {
      throw SourceWorkspaceError.fileTooLarge(path, byteCount)
    }
  }

  private func validateVersion(_ record: Record, expected: Int?) throws {
    guard let expected else { return }
    guard expected == record.buffer.version else {
      throw SourceWorkspaceError.versionMismatch(
        record.relativePath, expected: expected, actual: record.buffer.version)
    }
  }

  private func stateForMemory(_ record: Record) -> SourceFileState {
    let memoryHash = Self.hash(Data(record.buffer.text.utf8))
    let metadataChanged =
      record.persistedEncoding != nil && record.persistedEncoding != record.encoding
    if record.state == .conflicted,
      record.persistedContentHash != memoryHash || metadataChanged
    {
      return .conflicted
    }
    guard let persisted = record.persistedContentHash else { return .created }
    guard record.diskFingerprint != nil else { return .missing }
    return memoryHash == persisted && !metadataChanged ? .clean : .modified
  }

  private func materialize(_ record: Record) -> SourceCodeFile {
    SourceCodeFile(
      id: record.id,
      name: (record.relativePath as NSString).lastPathComponent,
      relativePath: record.relativePath,
      url: rootURL.appendingPathComponent(record.relativePath),
      languageID: record.languageID,
      content: record.buffer.text,
      version: record.buffer.version,
      savedVersion: record.savedVersion,
      encoding: record.encoding,
      lineEnding: record.lineEnding,
      state: record.state,
      diskFingerprint: record.diskFingerprint
    )
  }

  private func buildTree(files: [SourceCodeFile]) -> SourceWorkspaceNode {
    let rootName = rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
    let root = TreeBuilderNode(name: rootName, relativePath: "")
    for file in files {
      let components = file.pathComponents
      var node = root
      var accumulated: [String] = []
      for component in components.dropLast() {
        accumulated.append(component)
        let path = accumulated.joined(separator: "/")
        if let existing = node.directories[component] {
          node = existing
        } else {
          let child = TreeBuilderNode(name: component, relativePath: path)
          node.directories[component] = child
          node = child
        }
      }
      node.files.append(SourceCodeFileSummary(file: file))
    }
    func freeze(_ node: TreeBuilderNode) -> SourceWorkspaceNode {
      let directoryChildren = node.directories.values
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        .map(freeze)
      let fileChildren = node.files
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        .map {
          SourceWorkspaceNode(
            id: "file:\($0.id.description)",
            name: $0.name,
            relativePath: $0.relativePath,
            kind: .file,
            file: $0
          )
        }
      return SourceWorkspaceNode(
        id: node.relativePath.isEmpty ? "directory:/" : "directory:\(node.relativePath)",
        name: node.name,
        relativePath: node.relativePath,
        kind: .directory,
        children: directoryChildren + fileChildren
      )
    }
    return freeze(root)
  }

  private func shouldTrackNewDiskFile(path: String, url: URL) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    guard let name = components.last else { return false }
    for directory in components.dropLast() {
      if configuration.excludedDirectoryNames.contains(directory) { return false }
      if !configuration.includeHiddenItems, directory.hasPrefix(".") { return false }
    }
    if configuration.excludedFileNames.contains(name) { return false }
    if !configuration.includeHiddenItems, name.hasPrefix(".") { return false }

    let ext = url.pathExtension.lowercased()
    if let included = configuration.includedFileExtensions,
      !included.contains(ext),
      !(name == "CMakeLists.txt" && included.contains("cmake"))
    {
      return false
    }

    guard
      let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
    else { return false }
    if values.isSymbolicLink == true, !configuration.followSymbolicLinks { return false }
    guard values.isRegularFile == true || values.isSymbolicLink == true else { return false }
    return (values.fileSize ?? 0) <= configuration.maximumFileSize
  }

  private func normalize(_ path: String) throws -> String {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else {
      throw SourceWorkspaceError.invalidRelativePath(path)
    }
    var result: [String] = []
    for raw in path.replacingOccurrences(of: "\\", with: "/").split(
      separator: "/", omittingEmptySubsequences: false)
    {
      let component = String(raw)
      guard !component.isEmpty, component != ".", component != ".." else {
        throw SourceWorkspaceError.invalidRelativePath(path)
      }
      result.append(component)
    }
    guard !result.isEmpty else { throw SourceWorkspaceError.invalidRelativePath(path) }
    return result.joined(separator: "/")
  }

  private func normalizeFilePath(_ path: String) throws -> String {
    let normalized = try normalize(path)
    guard !(normalized as NSString).lastPathComponent.isEmpty else {
      throw SourceWorkspaceError.invalidRelativePath(path)
    }
    return normalized
  }

  private func normalizeDirectoryPath(_ path: String) throws -> String {
    guard !path.isEmpty else { throw SourceWorkspaceError.rootMutationNotAllowed }
    return try normalize(path)
  }

  private func validatedURL(for relativePath: String) throws -> URL {
    let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
    let rootPath = rootURL.path
    guard candidate.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
      throw SourceWorkspaceError.pathOutsideWorkspace(candidate)
    }
    guard !Self.hasEscapingSymlink(candidate, rootURL: rootURL) else {
      throw SourceWorkspaceError.symbolicLinkEscape(candidate)
    }
    return candidate
  }

  private static func hasEscapingSymlink(_ candidate: URL, rootURL: URL) -> Bool {
    let fileManager = FileManager.default
    let standardizedRoot = rootURL.standardizedFileURL

    // A non-existent workspace cannot contain a symlink yet. The lexical
    // containment check in `validatedURL` already guarantees that the
    // candidate is below this root, while `resolvingSymlinksInPath` on the
    // stored root has normalized any existing symlinked parent components.
    guard fileManager.fileExists(atPath: standardizedRoot.path) else { return false }

    let resolvedRoot = standardizedRoot.resolvingSymlinksInPath().standardizedFileURL.path
    var cursor = candidate.standardizedFileURL
    while !fileManager.fileExists(atPath: cursor.path) {
      let parent = cursor.deletingLastPathComponent()
      if parent == cursor { break }
      cursor = parent
    }
    let resolved = cursor.resolvingSymlinksInPath().standardizedFileURL.path
    return
      !(resolved == resolvedRoot
      || resolved.hasPrefix(resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"))
  }

  private func nextVersion(after version: Int, path: String) throws -> Int {
    let (next, overflow) = version.addingReportingOverflow(1)
    guard !overflow else { throw SourceWorkspaceError.versionOverflow(path) }
    return next
  }

  private func incrementRevision() {
    let (next, overflow) = revision.addingReportingOverflow(1)
    revision = overflow ? 0 : next
  }

  private func emit(_ event: SourceWorkspaceEvent) {
    for continuation in eventContinuations.values { continuation.yield(event) }
  }

  private func removeEventContinuation(_ token: UUID) {
    eventContinuations.removeValue(forKey: token)
  }

  private static func searchExpression(
    _ pattern: SourceSearchPattern,
    options: SourceSearchOptions
  ) throws -> NSRegularExpression {
    let sourcePattern: String
    switch pattern {
    case .literal(let value):
      guard !value.isEmpty else { return try NSRegularExpression(pattern: "(?!)") }
      sourcePattern = NSRegularExpression.escapedPattern(for: value)
    case .regularExpression(let value):
      guard !value.isEmpty else { return try NSRegularExpression(pattern: "(?!)") }
      sourcePattern = value
    }
    let expressionPattern =
      options.wholeWord
      ? "(?<![\\p{L}\\p{N}_])(?:\(sourcePattern))(?![\\p{L}\\p{N}_])"
      : sourcePattern
    do {
      return try NSRegularExpression(
        pattern: expressionPattern,
        options: options.caseSensitive ? [] : [.caseInsensitive]
      )
    } catch {
      throw SourceWorkspaceError.invalidSearchPattern(expressionPattern)
    }
  }

  private static func scanDisk(
    rootURL: URL,
    configuration: SourceWorkspaceConfiguration
  ) throws -> ScanOutput {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw SourceWorkspaceError.directoryNotFound(rootURL.path)
    }
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey,
      .fileSizeKey, .contentModificationDateKey,
    ]
    var files: [DiskSource] = []
    var skipped: [SourceWorkspaceSkippedFile] = []
    var visitedDirectories: Set<String> = []

    func visit(directoryURL: URL, relativeDirectory: String) throws {
      let resolvedDirectory = directoryURL.resolvingSymlinksInPath().standardizedFileURL.path
      guard visitedDirectories.insert(resolvedDirectory).inserted else { return }
      let children: [URL]
      do {
        children = try FileManager.default.contentsOfDirectory(
          at: directoryURL,
          includingPropertiesForKeys: Array(keys),
          options: []
        )
      } catch {
        throw SourceWorkspaceError.io("Could not enumerate \(directoryURL.path): \(error)")
      }
      for url in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let name = url.lastPathComponent
        let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
        do {
          let values = try url.resourceValues(forKeys: keys)
          let hidden = values.isHidden == true || name.hasPrefix(".")
          let symbolicLink = values.isSymbolicLink == true
          let effectiveURL = symbolicLink ? url.resolvingSymlinksInPath().standardizedFileURL : url
          if symbolicLink, configuration.followSymbolicLinks {
            let resolved = effectiveURL.path
            let root = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == root || resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            else {
              skipped.append(.init(relativePath: relative, reason: .symbolicLink))
              continue
            }
          }
          let effectiveValues =
            symbolicLink
            ? try effectiveURL.resourceValues(forKeys: keys)
            : values
          if effectiveValues.isDirectory == true {
            if configuration.excludedDirectoryNames.contains(name)
              || (!configuration.includeHiddenItems && hidden)
            {
              continue
            }
            if symbolicLink, !configuration.followSymbolicLinks {
              skipped.append(.init(relativePath: relative, reason: .symbolicLink))
              continue
            }
            try visit(directoryURL: effectiveURL, relativeDirectory: relative)
            continue
          }
          guard effectiveValues.isRegularFile == true else { continue }
          if configuration.excludedFileNames.contains(name)
            || (!configuration.includeHiddenItems && hidden)
          {
            skipped.append(.init(relativePath: relative, reason: .excluded))
            continue
          }
          if symbolicLink, !configuration.followSymbolicLinks {
            skipped.append(.init(relativePath: relative, reason: .symbolicLink))
            continue
          }
          let ext = url.pathExtension.lowercased()
          if let included = configuration.includedFileExtensions,
            !included.contains(ext),
            !(name == "CMakeLists.txt" && included.contains("cmake"))
          {
            skipped.append(.init(relativePath: relative, reason: .unsupportedExtension))
            continue
          }
          let size = effectiveValues.fileSize ?? 0
          guard size <= configuration.maximumFileSize else {
            skipped.append(.init(relativePath: relative, reason: .tooLarge(size)))
            continue
          }
          do {
            files.append(
              try readDiskSource(
                url: effectiveURL,
                relativePath: relative,
                maximumFileSize: configuration.maximumFileSize,
                modificationDate: effectiveValues.contentModificationDate
              ))
          } catch SourceWorkspaceError.invalidUTF8(_) {
            skipped.append(.init(relativePath: relative, reason: .invalidUTF8))
          } catch {
            skipped.append(
              .init(relativePath: relative, reason: .unreadable(String(describing: error))))
          }
        } catch {
          skipped.append(
            .init(relativePath: relative, reason: .unreadable(String(describing: error))))
        }
      }
    }

    try visit(directoryURL: rootURL, relativeDirectory: "")
    return ScanOutput(files: files, skipped: skipped)
  }

  private static func removeRecursively(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    if values.isDirectory == true, values.isSymbolicLink != true {
      for child in try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      ) {
        try removeRecursively(child)
      }
    }
    try FileManager.default.removeItem(at: url)
  }

  private static func readDiskSource(
    url: URL,
    relativePath: String,
    maximumFileSize: Int,
    modificationDate: Date? = nil
  ) throws -> DiskSource {
    let data: Data
    do { data = try Data(contentsOf: url, options: [.mappedIfSafe]) } catch {
      throw SourceWorkspaceError.io("Could not read \(relativePath): \(error)")
    }
    guard data.count <= maximumFileSize else {
      throw SourceWorkspaceError.fileTooLarge(relativePath, data.count)
    }
    let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
    let textData = bom ? data.dropFirst(3) : data[...]
    guard let content = String(data: textData, encoding: .utf8) else {
      throw SourceWorkspaceError.invalidUTF8(relativePath)
    }
    let date =
      modificationDate
      ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    return DiskSource(
      relativePath: relativePath,
      content: content,
      encoding: bom ? .utf8WithByteOrderMark : .utf8,
      lineEnding: detectLineEnding(content),
      logicalContentHash: hash(Data(content.utf8)),
      fingerprint: SourceDiskFingerprint(
        byteCount: data.count,
        contentHash: hash(data),
        modificationDate: date
      )
    )
  }

  private static func fingerprint(url: URL) throws -> SourceDiskFingerprint {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    return SourceDiskFingerprint(
      byteCount: data.count,
      contentHash: hash(data),
      modificationDate: date
    )
  }

  private static func encode(_ content: String, encoding: SourceTextEncoding) -> Data {
    var data = Data()
    if encoding == .utf8WithByteOrderMark { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
    data.append(contentsOf: content.utf8)
    return data
  }

  private static func hash(_ data: Data) -> UInt64 {
    var value: UInt64 = 14_695_981_039_346_656_037
    for byte in data {
      value ^= UInt64(byte)
      value &*= 1_099_511_628_211
    }
    return value
  }

  private static func detectLineEnding(_ text: String) -> SourceLineEnding {
    var lf = 0
    var crlf = 0
    var cr = 0
    let units = Array(text.utf8)
    var index = 0
    while index < units.count {
      if units[index] == 0x0D {
        if index + 1 < units.count, units[index + 1] == 0x0A {
          crlf += 1
          index += 2
        } else {
          cr += 1
          index += 1
        }
      } else if units[index] == 0x0A {
        lf += 1
        index += 1
      } else {
        index += 1
      }
    }
    let kinds = [lf > 0, crlf > 0, cr > 0].filter { $0 }.count
    if kinds == 0 { return .none }
    if kinds > 1 { return .mixed }
    if crlf > 0 { return .carriageReturnLineFeed }
    if cr > 0 { return .carriageReturn }
    return .lineFeed
  }

}
