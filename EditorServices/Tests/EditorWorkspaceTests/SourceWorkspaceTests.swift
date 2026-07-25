import EditorCore
import Foundation
import XCTest

@testable import EditorWorkspace

final class SourceWorkspaceTests: XCTestCase {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("EditorWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ text: String, to url: URL, bom: Bool = false) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = Data()
    if bom { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
    data.append(contentsOf: text.utf8)
    try data.write(to: url)
  }

  func testScanStoresContentMetadataAndDeterministicTree() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("struct App {}\r\n", to: root.appendingPathComponent("Sources/App.swift"), bom: true)
    try write("ignored", to: root.appendingPathComponent("image.bin"))
    try write("ignored", to: root.appendingPathComponent(".build/generated.swift"))

    let workspace = SourceWorkspace(rootURL: root)
    let report = try await workspace.scan()
    XCTAssertEqual(report.added.count, 1)
    XCTAssertTrue(report.skipped.contains { $0.relativePath == "image.bin" })

    let file = try await workspace.file(relativePath: "Sources/App.swift")
    XCTAssertEqual(file.name, "App.swift")
    XCTAssertEqual(file.content, "struct App {}\r\n")
    XCTAssertEqual(file.encoding, .utf8WithByteOrderMark)
    XCTAssertEqual(file.lineEnding, .carriageReturnLineFeed)
    XCTAssertEqual(file.languageID, "swift")
    XCTAssertEqual(file.state, .clean)

    let snapshot = await workspace.snapshot()
    XCTAssertEqual(snapshot.files.map(\.relativePath), ["Sources/App.swift"])
    XCTAssertEqual(snapshot.tree.children.first?.name, "Sources")
    XCTAssertEqual(snapshot.tree.children.first?.children.first?.name, "App.swift")
  }

  func testPathTraversalAndAbsolutePathsAreRejected() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    await assertThrowsErrorAsync { try await workspace.createFile(at: "../escape.swift") }
    await assertThrowsErrorAsync { try await workspace.createFile(at: "/tmp/escape.swift") }
    await assertThrowsErrorAsync { try await workspace.createFile(at: "a//b.swift") }
  }

  func testBOMFileUsesLogicalHashForDirtyStateAndPreservesEncoding() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("BOM.swift")
    try write("let value = 1\n", to: url, bom: true)
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.scan()
    let file = try await workspace.file(relativePath: "BOM.swift")
    _ = try await workspace.setContent("let value = 2\n", for: file.id)
    let reverted = try await workspace.setContent("let value = 1\n", for: file.id)
    XCTAssertEqual(reverted.state, .clean)
    let saved = try await workspace.save(file.id)
    XCTAssertEqual(saved.encoding, .utf8WithByteOrderMark)
    let bytes = try Data(contentsOf: url)
    XCTAssertTrue(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
  }

  func testCreateEditSaveAndPreserveStableIdentity() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)

    let created = try await workspace.createFile(
      at: "Sources/Main.swift", content: "print(1)\n", persistImmediately: false)
    XCTAssertEqual(created.state, .created)
    XCTAssertFalse(FileManager.default.fileExists(atPath: created.url.path))

    let changed = try await workspace.setContent(
      "print(2)\n", for: created.id, expectedVersion: created.version)
    XCTAssertEqual(changed.id, created.id)
    XCTAssertEqual(changed.version, created.version + 1)
    XCTAssertEqual(changed.state, .created)

    let saved = try await workspace.save(changed.id, expectedVersion: changed.version)
    XCTAssertEqual(saved.id, created.id)
    XCTAssertEqual(saved.state, .clean)
    XCTAssertEqual(try String(contentsOf: saved.url, encoding: .utf8), "print(2)\n")
  }

  func testTextEditsUseUTF16AndAreAtomic() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let file = try await workspace.createFile(
      at: "Unicode.swift", content: "let 값 = \"😀\"", persistImmediately: false)

    let updated = try await workspace.apply(
      .init(
        range: .init(
          start: .init(line: 0, utf16Column: 4),
          end: .init(line: 0, utf16Column: 5)
        ),
        replacement: "이름"
      ),
      to: file.id
    )
    XCTAssertEqual(updated.content, "let 이름 = \"😀\"")

    await assertThrowsErrorAsync {
      _ = try await workspace.apply(
        [
          .init(
            range: .init(start: .zero, end: .init(line: 0, utf16Column: 3)), replacement: "var"),
          .init(
            range: .init(
              start: .init(line: 0, utf16Column: 2), end: .init(line: 0, utf16Column: 4)),
            replacement: "x"),
        ],
        to: file.id
      )
    }
    let afterFailedBatch = try await workspace.file(id: file.id)
    XCTAssertEqual(afterFailedBatch.content, "let 이름 = \"😀\"")
  }

  func testCleanExternalChangeRefreshesButDirtyChangeConflicts() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("A.swift")
    try write("let a = 1\n", to: url)
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.scan()
    let original = try await workspace.file(relativePath: "A.swift")

    try write("let a = 2\n", to: url)
    let refreshedReport = try await workspace.scan()
    XCTAssertEqual(refreshedReport.refreshed, [original.id])
    let refreshed = try await workspace.file(id: original.id)
    XCTAssertEqual(refreshed.content, "let a = 2\n")
    XCTAssertEqual(refreshed.state, .clean)

    _ = try await workspace.setContent("let a = 3\n", for: original.id)
    try write("let a = 4\n", to: url)
    let conflictReport = try await workspace.scan()
    XCTAssertEqual(conflictReport.conflicted, [original.id])
    let conflicted = try await workspace.file(id: original.id)
    XCTAssertEqual(conflicted.content, "let a = 3\n")
    XCTAssertEqual(conflicted.state, .conflicted)
  }

  func testConflictCanResolveUsingDiskOrMemory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("A.swift")
    try write("one", to: url)
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.scan()
    let file = try await workspace.file(relativePath: "A.swift")

    _ = try await workspace.setContent("memory", for: file.id)
    try write("disk", to: url)
    _ = try await workspace.scan()
    let disk = try await workspace.resolveConflict(file.id, using: .useDisk)
    XCTAssertEqual(disk.content, "disk")
    XCTAssertEqual(disk.state, .clean)

    _ = try await workspace.setContent("memory2", for: file.id)
    try write("disk2", to: url)
    _ = try await workspace.scan()
    let memory = try await workspace.resolveConflict(file.id, using: .useMemory)
    XCTAssertEqual(memory.content, "memory2")
    XCTAssertEqual(memory.state, .clean)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "memory2")
  }

  func testSaveDetectsUnscannedExternalConflict() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("A.swift")
    try write("base", to: url)
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.scan()
    let file = try await workspace.file(relativePath: "A.swift")
    _ = try await workspace.setContent("memory", for: file.id)
    try write("external", to: url)

    await assertThrowsErrorAsync { _ = try await workspace.save(file.id) }
    let saved = try await workspace.save(file.id, overwriteExternalChanges: true)
    XCTAssertEqual(saved.state, .clean)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "memory")
  }

  func testMoveFileKeepsIdentityAndMovesDisk() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let file = try await workspace.createFile(at: "A.swift", content: "a")
    let moved = try await workspace.moveFile(file.id, to: "Sources/B.swift")

    XCTAssertEqual(moved.id, file.id)
    XCTAssertEqual(moved.name, "B.swift")
    XCTAssertEqual(moved.relativePath, "Sources/B.swift")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("A.swift").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: moved.url.path))
  }

  func testMoveAndRemoveDirectoryUpdateStoredTree() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let a = try await workspace.createFile(at: "Old/A.swift", content: "a")
    let b = try await workspace.createFile(at: "Old/Nested/B.swift", content: "b")

    try await workspace.moveDirectory(from: "Old", to: "New")
    let movedA = try await workspace.file(id: a.id)
    let movedB = try await workspace.file(id: b.id)
    XCTAssertEqual(movedA.relativePath, "New/A.swift")
    XCTAssertEqual(movedB.relativePath, "New/Nested/B.swift")
    await assertThrowsErrorAsync { try await workspace.removeDirectory(at: "New") }
    try await workspace.removeDirectory(at: "New", recursively: true)
    let remaining = await workspace.files()
    XCTAssertTrue(remaining.isEmpty)
  }

  func testMissingFilesRemainRecoverableInMemory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("A.swift")
    try write("a", to: url)
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.scan()
    let file = try await workspace.file(relativePath: "A.swift")
    try FileManager.default.removeItem(at: url)

    let report = try await workspace.scan()
    XCTAssertEqual(report.missing, [file.id])
    let missing = try await workspace.file(id: file.id)
    XCTAssertEqual(missing.content, "a")
    XCTAssertEqual(missing.state, .missing)
    let restored = try await workspace.resolveConflict(file.id, using: .useMemory)
    XCTAssertEqual(restored.state, .clean)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  func testSymlinkEscapeIsRejected() async throws {
    let root = try temporaryDirectory()
    let outside = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape"),
      withDestinationURL: outside
    )
    let workspace = SourceWorkspace(rootURL: root)
    await assertThrowsErrorAsync {
      _ = try await workspace.createFile(at: "escape/A.swift", content: "bad")
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: outside.appendingPathComponent("A.swift").path))
  }

  func testSizeAndInvalidUTF8AreReportedWithoutBreakingScan() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0x61, count: 20).write(to: root.appendingPathComponent("Large.swift"))
    try Data([0xFF, 0xFE]).write(to: root.appendingPathComponent("Bad.swift"))
    try write("ok", to: root.appendingPathComponent("Good.swift"))
    let workspace = SourceWorkspace(
      rootURL: root,
      configuration: .init(maximumFileSize: 10)
    )
    let report = try await workspace.scan()
    let storedPaths = await workspace.files().map(\.relativePath)
    XCTAssertEqual(storedPaths, ["Good.swift"])
    XCTAssertTrue(report.skipped.contains { $0.relativePath == "Large.swift" })
    XCTAssertTrue(report.skipped.contains { $0.relativePath == "Bad.swift" })
  }

  func testIndependentEventSubscribersReceiveChanges() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let first = await workspace.events()
    let second = await workspace.events()
    let firstTask = Task {
      var iterator = first.makeAsyncIterator()
      return await iterator.next()
    }
    let secondTask = Task {
      var iterator = second.makeAsyncIterator()
      return await iterator.next()
    }

    let file = try await workspace.createFile(at: "A.swift", persistImmediately: false)
    guard case .added(let eventFile)? = await firstTask.value else {
      return XCTFail("First subscriber did not receive an add event")
    }
    guard case .added(let secondFile)? = await secondTask.value else {
      return XCTFail("Second subscriber did not receive an add event")
    }
    XCTAssertEqual(eventFile.id, file.id)
    XCTAssertEqual(secondFile.id, file.id)
  }

  func testOpenDocumentSynchronizationPreservesExactVersion() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let url = root.appendingPathComponent("A.swift")
    let synchronized = try await workspace.synchronizeOpenDocument(
      at: url,
      snapshot: TextSnapshot(text: "let 값 = 1", version: 42),
      languageID: "swift"
    )
    XCTAssertEqual(synchronized?.version, 42)
    XCTAssertEqual(synchronized?.content, "let 값 = 1")
    XCTAssertEqual(synchronized?.state, .created)

    let outside = root.deletingLastPathComponent().appendingPathComponent("Outside.swift")
    let ignored = try await workspace.synchronizeOpenDocument(
      at: outside,
      snapshot: TextSnapshot(text: "x", version: 1)
    )
    XCTAssertNil(ignored)
  }

  func testSearchSupportsUnicodeRegexWholeWordFiltersAndLimits() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.createFile(
      at: "A.swift", content: "let 값 = alpha\nlet alphabet = 값\n", persistImmediately: false)
    _ = try await workspace.createFile(
      at: "B.txt", content: "ALPHA 값 alpha", persistImmediately: false)

    let wholeWord = try await workspace.search(
      .literal("alpha"),
      options: .init(caseSensitive: false, wholeWord: true, maximumResults: 10)
    )
    XCTAssertEqual(wholeWord.count, 3)
    XCTAssertFalse(
      wholeWord.contains { $0.matchedText == "alpha" && $0.lineText.contains("alphabet") })

    let unicode = try await workspace.search(.regularExpression("값"))
    XCTAssertEqual(unicode.count, 3)
    XCTAssertEqual(unicode.first?.range.start, .init(line: 0, utf16Column: 4))

    let swiftOnly = try await workspace.search(
      .literal("alpha"),
      options: .init(maximumResults: 1, includedFileExtensions: ["swift"])
    )
    XCTAssertEqual(swiftOnly.count, 1)
    XCTAssertEqual(swiftOnly.first?.relativePath, "A.swift")

    await assertThrowsErrorAsync {
      _ = try await workspace.search(.regularExpression("["))
    }
  }

  func testEncodedSnapshotContainsFullContentPathAndTree() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.createFile(
      at: "Sources/App.swift", content: "struct App {}", persistImmediately: false)
    let data = try await workspace.encodedSnapshot()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SourceWorkspaceSnapshot.self, from: data)
    XCTAssertEqual(decoded.files.first?.relativePath, "Sources/App.swift")
    XCTAssertEqual(decoded.files.first?.content, "struct App {}")
    XCTAssertEqual(decoded.tree.children.first?.name, "Sources")
  }

  func testDirectoryQueriesAndRescanKeepStableIDs() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a", to: root.appendingPathComponent("Sources/A.swift"))
    try write("b", to: root.appendingPathComponent("Sources/Nested/B.swift"))
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.scan()
    let original = try await workspace.file(relativePath: "Sources/A.swift")
    _ = try await workspace.scan()
    let rescanned = try await workspace.file(relativePath: "Sources/A.swift")
    XCTAssertEqual(rescanned.id, original.id)
    let direct = try await workspace.files(inDirectory: "Sources", recursively: false)
    let recursive = try await workspace.files(inDirectory: "Sources", recursively: true)
    XCTAssertEqual(direct.map(\.relativePath), ["Sources/A.swift"])
    XCTAssertEqual(recursive.map(\.relativePath), ["Sources/A.swift", "Sources/Nested/B.swift"])
  }

  func testExpectedVersionPreventsLostUpdates() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let file = try await workspace.createFile(
      at: "A.swift", content: "a", persistImmediately: false)
    let changed = try await workspace.setContent("b", for: file.id, expectedVersion: file.version)
    await assertThrowsErrorAsync {
      _ = try await workspace.setContent("c", for: file.id, expectedVersion: file.version)
    }
    let latest = try await workspace.file(id: file.id)
    XCTAssertEqual(latest.content, changed.content)
  }

  func testFollowingSymlinksCannotEscapeWorkspaceAndCyclesTerminate() async throws {
    let root = try temporaryDirectory()
    let outside = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try write("secret", to: outside.appendingPathComponent("Secret.swift"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("Escape.swift"),
      withDestinationURL: outside.appendingPathComponent("Secret.swift")
    )
    try write("let local = true", to: root.appendingPathComponent("Sources/A.swift"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("Sources/loop"),
      withDestinationURL: root.appendingPathComponent("Sources")
    )

    let workspace = SourceWorkspace(
      rootURL: root,
      configuration: .init(followSymbolicLinks: true)
    )
    let report = try await workspace.scan()
    let paths = await workspace.files().map(\.relativePath)
    XCTAssertEqual(paths, ["Sources/A.swift"])
    XCTAssertTrue(
      report.skipped.contains {
        $0.relativePath == "Escape.swift" && $0.reason == .symbolicLink
      })
  }

  func testNonRecursiveDirectoryRemovalProtectsUntrackedDiskFiles() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("binary-ish", to: root.appendingPathComponent("Assets/data.bin"))
    let workspace = SourceWorkspace(rootURL: root)

    await assertThrowsErrorAsync {
      try await workspace.removeDirectory(at: "Assets", recursively: false)
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/data.bin").path))
    try await workspace.removeDirectory(at: "Assets", recursively: true)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets").path))
  }

  func testDirectoryCannotMoveIntoItsOwnDescendant() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.createFile(at: "Sources/A.swift", content: "a")
    await assertThrowsErrorAsync {
      try await workspace.moveDirectory(from: "Sources", to: "Sources/Nested")
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/A.swift").path))
  }

  func testConcurrentSingleFileLoadsReuseOneStableIdentity() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Large.swift")
    try write(String(repeating: "let value = 1\n", count: 20_000), to: url)
    let workspace = SourceWorkspace(rootURL: root)

    let ids = try await withThrowingTaskGroup(of: SourceFileID.self) { group in
      for _ in 0..<24 {
        group.addTask { try await workspace.loadFileFromDisk(at: url).id }
      }
      var output: [SourceFileID] = []
      for try await id in group { output.append(id) }
      return output
    }
    XCTAssertEqual(Set(ids).count, 1)
    let count = await workspace.files().count
    XCTAssertEqual(count, 1)
  }

  func testOverwriteKeepsStableIdentityAndRollsBackOnPersistenceFailure() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let file = try await workspace.createFile(
      at: "A.swift", content: "old", persistImmediately: false)
    let overwritten = try await workspace.createFile(
      at: "A.swift", content: "new", persistImmediately: false, overwrite: true)
    XCTAssertEqual(overwritten.id, file.id)
    XCTAssertEqual(overwritten.content, "new")

    try FileManager.default.createDirectory(at: overwritten.url, withIntermediateDirectories: true)
    await assertThrowsErrorAsync {
      _ = try await workspace.createFile(
        at: "A.swift", content: "should roll back", persistImmediately: true, overwrite: true)
    }
    let restored = try await workspace.file(id: file.id)
    XCTAssertEqual(restored.content, "new")
    XCTAssertEqual(restored.id, file.id)
  }

  func testMaximumSizeAppliesToEveryMemoryMutationPath() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(
      rootURL: root,
      configuration: .init(maximumFileSize: 4)
    )
    await assertThrowsErrorAsync {
      _ = try await workspace.createFile(
        at: "TooLarge.swift", content: "12345", persistImmediately: false)
    }
    let file = try await workspace.createFile(
      at: "A.swift", content: "1234", persistImmediately: false)
    await assertThrowsErrorAsync {
      _ = try await workspace.setContent("12345", for: file.id)
    }
    let unchanged = try await workspace.file(id: file.id)
    XCTAssertEqual(unchanged.content, "1234")
  }

  func testPortableArchiveRoundTripReconcilesCleanCreatedAndConflictedFiles() async throws {
    let sourceRoot = try temporaryDirectory()
    let destinationRoot = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationRoot)
    }
    let source = SourceWorkspace(rootURL: sourceRoot)
    let clean = try await source.createFile(at: "Clean.swift", content: "clean")
    let created = try await source.createFile(
      at: "Created.swift", content: "memory", persistImmediately: false)
    let conflict = try await source.createFile(
      at: "Conflict.swift", content: "archive", persistImmediately: false)
    let archiveData = try await source.encodedArchive()

    try write("clean", to: destinationRoot.appendingPathComponent("Clean.swift"))
    try write("disk", to: destinationRoot.appendingPathComponent("Conflict.swift"))
    let destination = SourceWorkspace(rootURL: destinationRoot)
    let report = try await destination.restore(from: archiveData)
    XCTAssertEqual(Set(report.imported), Set([clean.id, created.id, conflict.id]))
    let restoredClean = try await destination.file(id: clean.id)
    let restoredCreated = try await destination.file(id: created.id)
    let restoredConflict = try await destination.file(id: conflict.id)
    XCTAssertEqual(restoredClean.state, .clean)
    XCTAssertEqual(restoredCreated.state, .created)
    XCTAssertEqual(restoredConflict.state, .conflicted)
    XCTAssertEqual(restoredConflict.content, "archive")
    XCTAssertEqual(
      try String(
        contentsOf: destinationRoot.appendingPathComponent("Conflict.swift"), encoding: .utf8),
      "disk")
  }

  func testInvalidArchiveDoesNotPartiallyMutateWorkspace() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let existing = try await workspace.createFile(
      at: "Existing.swift", content: "existing", persistImmediately: false)
    let duplicateID = SourceFileID()
    let archive = SourceWorkspaceArchive(
      workspaceName: "Bad",
      revision: 1,
      files: [
        .init(
          id: duplicateID, relativePath: "A.swift", languageID: "swift", content: "a", version: 0,
          savedVersion: nil, encoding: .utf8, lineEnding: .none),
        .init(
          id: duplicateID, relativePath: "B.swift", languageID: "swift", content: "b", version: 0,
          savedVersion: nil, encoding: .utf8, lineEnding: .none),
      ]
    )
    await assertThrowsErrorAsync { _ = try await workspace.restore(from: archive) }
    let files = await workspace.files()
    XCTAssertEqual(files.map(\.id), [existing.id])
    XCTAssertEqual(files.first?.content, "existing")
  }

  func testArchiveMergePoliciesAreDeterministic() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let original = try await workspace.createFile(
      at: "A.swift", content: "old", persistImmediately: false)
    let importedID = SourceFileID()
    let archive = SourceWorkspaceArchive(
      workspaceName: "Import",
      revision: 0,
      files: [
        .init(
          id: importedID, relativePath: "A.swift", languageID: "swift", content: "new", version: 7,
          savedVersion: nil, encoding: .utf8, lineEnding: .none)
      ]
    )

    let kept = try await workspace.restore(
      from: archive, policy: .mergeKeepingExisting, mode: .memoryOnly)
    XCTAssertEqual(kept.skipped, [importedID])
    let keptOriginal = try await workspace.file(id: original.id)
    XCTAssertEqual(keptOriginal.content, "old")

    let replaced = try await workspace.restore(
      from: archive, policy: .mergeReplacingExisting, mode: .memoryOnly)
    XCTAssertTrue(replaced.replaced.contains(importedID))
    let current = try await workspace.file(relativePath: "A.swift")
    XCTAssertEqual(current.id, importedID)
    XCTAssertEqual(current.content, "new")
    XCTAssertEqual(current.version, 7)
  }

  func testAtomicMultiFileUpdatesRollBackCompletelyOnAnyFailure() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let a = try await workspace.createFile(at: "A.swift", content: "a", persistImmediately: false)
    let b = try await workspace.createFile(at: "B.swift", content: "b", persistImmediately: false)

    await assertThrowsErrorAsync {
      _ = try await workspace.setContentsAtomically([
        .init(fileID: a.id, content: "A", expectedVersion: a.version),
        .init(fileID: b.id, content: "B", expectedVersion: b.version + 1),
      ])
    }
    let unchangedA = try await workspace.file(id: a.id)
    let unchangedB = try await workspace.file(id: b.id)
    XCTAssertEqual(unchangedA.content, "a")
    XCTAssertEqual(unchangedB.content, "b")

    let changed = try await workspace.setContentsAtomically([
      .init(fileID: a.id, content: "A", expectedVersion: a.version),
      .init(fileID: b.id, content: "B", expectedVersion: b.version),
    ])
    XCTAssertEqual(Set(changed.map(\.content)), Set(["A", "B"]))
  }

  func testWorkspaceMetricsDescribeCurrentInMemoryProject() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.createFile(at: "A.swift", content: "a\nb", persistImmediately: false)
    _ = try await workspace.createFile(at: "B.py", content: "x", persistImmediately: false)
    let metrics = await workspace.metrics()
    XCTAssertEqual(metrics.fileCount, 2)
    XCTAssertEqual(metrics.totalUTF8Bytes, 4)
    XCTAssertEqual(metrics.totalLines, 3)
    XCTAssertEqual(metrics.dirtyFileCount, 2)
    XCTAssertEqual(metrics.filesByLanguage, ["swift": 1, "python": 1])
  }

  func testEncodingChangeIsDirtyAndSaveWritesUTF8BOM() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let file = try await workspace.createFile(at: "A.swift", content: "let a = 1")
    let changed = try await workspace.setEncoding(.utf8WithByteOrderMark, for: file.id)
    XCTAssertEqual(changed.state, .modified)
    XCTAssertEqual(changed.encoding, .utf8WithByteOrderMark)

    let saved = try await workspace.save(file.id)
    XCTAssertEqual(saved.state, .clean)
    let data = try Data(contentsOf: saved.url)
    XCTAssertTrue(data.starts(with: [0xEF, 0xBB, 0xBF]))
    XCTAssertEqual(String(data: data.dropFirst(3), encoding: .utf8), "let a = 1")
  }

  func testLineEndingConversionUpdatesContentVersionAndMetadata() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let file = try await workspace.createFile(
      at: "A.swift", content: "a\r\nb\rc\nd", persistImmediately: false)
    XCTAssertEqual(file.lineEnding, .mixed)
    let converted = try await workspace.convertLineEndings(.carriageReturnLineFeed, for: file.id)
    XCTAssertEqual(converted.content, "a\r\nb\r\nc\r\nd")
    XCTAssertEqual(converted.lineEnding, .carriageReturnLineFeed)
    XCTAssertEqual(converted.version, file.version + 1)
    await assertThrowsErrorAsync {
      _ = try await workspace.convertLineEndings(.mixed, for: file.id)
    }
  }

  func testLanguageIDOverridePersistsAcrossContentChanges() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let file = try await workspace.createFile(
      at: "template.txt", content: "value", persistImmediately: false)
    let changed = try await workspace.setLanguageID("swift", for: file.id)
    XCTAssertEqual(changed.languageID, "swift")
    let edited = try await workspace.setContent("let value = 1", for: file.id)
    XCTAssertEqual(edited.languageID, "swift")
  }

  func testReplacementPreviewSupportsRegexCapturesAndUnicodeRanges() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let a = try await workspace.createFile(
      at: "A.swift", content: "let 값1 = 10\nlet 값2 = 20\n", persistImmediately: false)
    _ = try await workspace.createFile(
      at: "B.txt", content: "값3 = 30", persistImmediately: false)

    let preview = try await workspace.previewReplacement(
      .regularExpression("값([0-9])"),
      replacementTemplate: "value$1",
      options: .init(includedFileExtensions: ["swift"])
    )
    XCTAssertEqual(preview.matchCount, 2)
    XCTAssertEqual(preview.files.count, 1)
    XCTAssertEqual(preview.files.first?.fileID, a.id)
    XCTAssertEqual(preview.files.first?.edits.first?.range.start, .init(line: 0, utf16Column: 4))
    XCTAssertEqual(preview.files.first?.edits.first?.replacement, "value1")

    let changed = try await workspace.applyReplacement(preview)
    XCTAssertEqual(changed.first?.content, "let value1 = 10\nlet value2 = 20\n")
  }

  func testStaleReplacementPreviewRollsBackAllFiles() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let a = try await workspace.createFile(at: "A.swift", content: "foo", persistImmediately: false)
    let b = try await workspace.createFile(at: "B.swift", content: "foo", persistImmediately: false)
    let preview = try await workspace.previewReplacement(
      .literal("foo"), replacementTemplate: "bar")
    _ = try await workspace.setContent("changed", for: b.id)

    await assertThrowsErrorAsync { _ = try await workspace.applyReplacement(preview) }
    let currentA = try await workspace.file(id: a.id)
    let currentB = try await workspace.file(id: b.id)
    XCTAssertEqual(currentA.content, "foo")
    XCTAssertEqual(currentB.content, "changed")
  }

  func testReplacementLimitIsDeterministicAcrossSortedPaths() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.createFile(at: "B.swift", content: "x x", persistImmediately: false)
    _ = try await workspace.createFile(at: "A.swift", content: "x x", persistImmediately: false)
    let preview = try await workspace.previewReplacement(
      .literal("x"), replacementTemplate: "y", options: .init(maximumResults: 3))
    XCTAssertEqual(preview.matchCount, 3)
    XCTAssertEqual(preview.files.map(\.relativePath), ["A.swift", "B.swift"])
    XCTAssertEqual(preview.files[0].edits.count, 2)
    XCTAssertEqual(preview.files[1].edits.count, 1)
  }
  func testSingleFileRefreshReloadsCleanContentWithoutWorkspaceScan() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("main.swift")
    try "let value = 1\n".write(to: url, atomically: true, encoding: .utf8)
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.scan()

    try "let value = 2\n".write(to: url, atomically: true, encoding: .utf8)
    let refreshed = try await workspace.refreshFileFromDisk(at: url)

    XCTAssertEqual(refreshed?.content, "let value = 2\n")
    XCTAssertEqual(refreshed?.state, .clean)
  }

  func testSingleFileRefreshPreservesUnsavedContentAsConflict() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("main.swift")
    try "let value = 1\n".write(to: url, atomically: true, encoding: .utf8)
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.scan()
    let file = try await workspace.file(at: url)
    _ = try await workspace.setContent("let value = 3\n", for: file.id)

    try "let value = 2\n".write(to: url, atomically: true, encoding: .utf8)
    let refreshed = try await workspace.refreshFileFromDisk(at: url)

    XCTAssertEqual(refreshed?.content, "let value = 3\n")
    XCTAssertEqual(refreshed?.state, .conflicted)
  }

  func testSingleFileRefreshIgnoresUnsupportedNewFiles() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SourceWorkspace(rootURL: root)
    let asset = root.appendingPathComponent("image.bin")
    try Data([0x00, 0xFF, 0x00]).write(to: asset)

    let refreshed = try await workspace.refreshFileFromDisk(at: asset)

    let files = await workspace.files()
    XCTAssertNil(refreshed)
    XCTAssertTrue(files.isEmpty)
  }

  func testSingleFileRefreshMarksDeletedFileMissing() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("main.swift")
    try "let value = 1\n".write(to: url, atomically: true, encoding: .utf8)
    let workspace = SourceWorkspace(rootURL: root)
    _ = try await workspace.scan()

    try FileManager.default.removeItem(at: url)
    let refreshed = try await workspace.refreshFileFromDisk(at: url)

    XCTAssertEqual(refreshed?.state, .missing)
    XCTAssertEqual(refreshed?.content, "let value = 1\n")
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @escaping @Sendable () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw", file: file, line: line)
  } catch {}
}
