import Foundation
import XCTest

@testable import EditorLSP

#if os(macOS) || os(Linux)
  final class LSPProcessConnectionLifecycleTests: XCTestCase {
    func testUnexpectedProcessExitIsPublished() async throws {
      let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "LSPProcessConnectionLifecycleTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: workspace) }

      let connection = try LSPProcessConnection(
        workspaceURL: workspace,
        configuration: LSPProcessConfiguration(
          executable: "/bin/sh",
          arguments: ["-c", "exit 7"]
        )
      )

      let event = await firstValue(from: connection.terminationEvents, timeout: .seconds(2))
      XCTAssertEqual(event?.status, 7)
      XCTAssertEqual(event?.reason, .exit)
      XCTAssertEqual(event?.expected, false)
    }

    private func firstValue<Value: Sendable>(
      from stream: AsyncStream<Value>,
      timeout: Duration
    ) async -> Value? {
      await withTaskGroup(of: Value?.self) { group in
        group.addTask {
          var iterator = stream.makeAsyncIterator()
          return await iterator.next()
        }
        group.addTask {
          try? await Task.sleep(for: timeout)
          return nil
        }
        let value = await group.next() ?? nil
        group.cancelAll()
        return value
      }
    }
  }
#endif
