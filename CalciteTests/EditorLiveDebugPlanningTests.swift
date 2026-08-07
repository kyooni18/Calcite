import XCTest
@testable import Calcite

final class EditorLiveDebugPlanningTests: XCTestCase {
  func testSwiftPMChangeRebuildsReverseDependencies() throws {
    let root = try makeTemporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    try """
      // swift-tools-version: 6.0
      import PackageDescription
      let package = Package(
        name: "Fixture",
        targets: [
          .target(name: "Core"),
          .executableTarget(name: "App", dependencies: ["Core"]),
        ]
      )
      """.write(
        to: root.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8
      )
    let source = root.appendingPathComponent("Sources/Core/Value.swift")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "struct Value {}".write(to: source, atomically: true, encoding: .utf8)

    let impact = EditorFileChangeImpactResolver.resolve(
      changedURL: source,
      workspaceURL: root,
      launchTarget: .project
    )

    XCTAssertEqual(impact, .rebuildDependents(["Core", "App"]))
  }

  func testManifestChangeReloadsProjectGraph() throws {
    let root = try makeTemporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = root.appendingPathComponent("Package.swift")
    try "// swift-tools-version: 6.0".write(
      to: manifest,
      atomically: true,
      encoding: .utf8
    )

    XCTAssertEqual(
      EditorFileChangeImpactResolver.resolve(
        changedURL: manifest,
        workspaceURL: root,
        launchTarget: .project
      ),
      .projectGraphReload
    )
  }

  func testGeneratedBuildProductsAreIgnored() throws {
    let root = try makeTemporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let generated = root.appendingPathComponent(".build/debug/Fixture")
    try FileManager.default.createDirectory(
      at: generated.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data().write(to: generated)

    XCTAssertEqual(
      EditorFileChangeImpactResolver.resolve(
        changedURL: generated,
        workspaceURL: root,
        launchTarget: .project
      ),
      .ignore
    )
  }

  func testStandaloneCurrentFileIgnoresUnrelatedSibling() throws {
    let root = try makeTemporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("Standalone/main.py")
    let sibling = root.appendingPathComponent("Standalone/helper.py")
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "print('main')".write(to: target, atomically: true, encoding: .utf8)
    try "print('helper')".write(to: sibling, atomically: true, encoding: .utf8)

    XCTAssertEqual(
      EditorFileChangeImpactResolver.resolve(
        changedURL: sibling,
        workspaceURL: root.appendingPathComponent("DifferentProject"),
        launchTarget: .currentFile(target)
      ),
      .ignore
    )
  }

  func testChangeAccumulatorCoalescesAndDrainsAtomically() {
    let first = URL(fileURLWithPath: "/tmp/CalciteTests/first.swift")
    let second = URL(fileURLWithPath: "/tmp/CalciteTests/second.swift")
    var accumulator = EditorLiveDebugChangeAccumulator()

    let firstGeneration = accumulator.merge(
      ProjectFileChangeBatch(changedPaths: [first])
    )
    let secondGeneration = accumulator.merge(
      ProjectFileChangeBatch(
        removedPaths: [second],
        requiresFullRescan: true
      )
    )
    let drained = accumulator.drain()

    XCTAssertEqual(firstGeneration, 1)
    XCTAssertEqual(secondGeneration, 2)
    XCTAssertEqual(drained.generation, 2)
    XCTAssertEqual(drained.batch.changedPaths, [first])
    XCTAssertEqual(drained.batch.removedPaths, [second])
    XCTAssertTrue(drained.batch.requiresFullRescan)
    XCTAssertTrue(accumulator.isEmpty)
  }

  @MainActor
  func testLiveDebugProcessesAnInMemoryEditWithoutAFileSystemCommit() async throws {
    let root = try makeTemporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("main.swift")
    try "print(1)".write(to: source, atomically: true, encoding: .utf8)

    let processed = expectation(description: "Live Debug processed the edit")
    var receivedPaths: Set<URL> = []
    let controller = EditorLiveDebugController(
      rootResolver: { _ in [root] },
      filter: { _, _ in true },
      settleDelay: .milliseconds(50),
      applyChanges: { batch, _ in
        receivedPaths.formUnion(batch.changedPaths)
        processed.fulfill()
      }
    )
    controller.configure(enabled: true, target: .project)
    controller.enqueueFullRestart(for: [source])

    await fulfillment(of: [processed], timeout: 1)
    XCTAssertEqual(receivedPaths, [source.standardizedFileURL])
  }

  private func makeTemporaryWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteTests")
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
