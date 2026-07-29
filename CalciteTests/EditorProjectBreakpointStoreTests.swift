import Foundation
import XCTest

@testable import Calcite

final class EditorProjectBreakpointStoreTests: XCTestCase {
  func testProjectEnumerationIncludesClosedFilesAndExcludesOtherWorkspaces() {
    let identifier = UUID().uuidString
    let workspace = URL(fileURLWithPath: "/tmp/CalciteBreakpointTests/\(identifier)")
    let first = workspace.appendingPathComponent("Sources/First.swift")
    let second = workspace.appendingPathComponent("Sources/Second.swift")
    let outside = URL(fileURLWithPath: "/tmp/Other/\(identifier)/Outside.swift")
    defer {
      EditorBreakpointStore.remove(under: workspace)
      EditorBreakpointStore.remove(under: outside)
    }

    EditorBreakpointStore.save([3, 8], for: first)
    EditorBreakpointStore.save([12], for: second)
    EditorBreakpointStore.save([99], for: outside)

    let values = EditorBreakpointStore.all(under: workspace)

    XCTAssertEqual(values[first.standardizedFileURL], Set([3, 8]))
    XCTAssertEqual(values[second.standardizedFileURL], Set([12]))
    XCTAssertNil(values[outside.standardizedFileURL])
  }
}
