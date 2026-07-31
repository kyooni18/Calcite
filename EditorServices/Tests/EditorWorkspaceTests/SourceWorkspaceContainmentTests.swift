import Foundation
import XCTest

@testable import EditorWorkspace

final class SourceWorkspaceContainmentTests: XCTestCase {
  func testContainsRejectsSiblingAndTraversalPaths() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sibling = root.deletingLastPathComponent()
      .appendingPathComponent(root.lastPathComponent + "-sibling", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: sibling)
    }

    let inside = root.appendingPathComponent("Sources/main.swift")
    let outside = sibling.appendingPathComponent("main.swift")
    let workspace = SourceWorkspace(rootURL: root)

    let containsInside = await workspace.contains(inside)
    let containsOutside = await workspace.contains(outside)
    XCTAssertTrue(containsInside)
    XCTAssertFalse(containsOutside)
  }
}
