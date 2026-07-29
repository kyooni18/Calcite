import XCTest

@testable import Calcite

final class EditorDocumentRuntimeTests: XCTestCase {
  @MainActor
  func testMutationQueuePreservesSubmissionOrder() async {
    let queue = EditorDocumentMutationQueue()
    var values: [Int] = []

    queue.enqueue { _ in
      try? await Task.sleep(for: .milliseconds(20))
      values.append(1)
    }
    queue.enqueue { _ in values.append(2) }
    queue.enqueue { _ in values.append(3) }

    await queue.waitForIdle()
    XCTAssertEqual(values, [1, 2, 3])
    XCTAssertEqual(queue.pendingCount, 0)
  }
  @MainActor
  func testCancellingQueueRemovesPendingMutations() async {
    let queue = EditorDocumentMutationQueue()
    var didFinish = false

    queue.enqueue { _ in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      didFinish = true
    }
    await Task.yield()
    await queue.cancelAndWait()

    XCTAssertFalse(didFinish)
    XCTAssertEqual(queue.pendingCount, 0)
  }

}
