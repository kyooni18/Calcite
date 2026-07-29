import Foundation
import XCTest

@testable import EditorDAP

#if os(macOS) || os(Linux)
  final class DAPProcessConnectionLifecycleTests: XCTestCase {
    func testUnexpectedProcessExitIsPublished() async throws {
      let connection = try DAPProcessConnection(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exit 9"]
      )

      let event = await firstValue(from: connection.terminationEvents, timeout: .seconds(2))
      XCTAssertEqual(event?.status, 9)
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
