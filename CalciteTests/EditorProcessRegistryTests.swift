import XCTest
@testable import Calcite

@MainActor
final class EditorProcessRegistryTests: XCTestCase {
  private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
  }

  func testReplacingOwnerTerminatesPreviousRegistrationExactlyOnce() async {
    let registry = EditorProcessRegistry()
    let counter = Counter()
    let owner = EditorProcessOwner.debug(workspacePath: "/tmp/CalciteTests/process")

    _ = await registry.register(owner: owner) {
      await counter.increment()
    }
    let current = await registry.register(owner: owner) {}

    let terminationCount = await counter.value
    let activeBeforeCleanup = await registry.activeCount
    let didUnregister = await registry.unregister(current)
    let activeAfterCleanup = await registry.activeCount
    XCTAssertEqual(terminationCount, 1)
    XCTAssertEqual(activeBeforeCleanup, 1)
    XCTAssertTrue(didUnregister)
    XCTAssertEqual(activeAfterCleanup, 0)
  }

  func testStaleLeaseCannotUnregisterReplacement() async {
    let registry = EditorProcessRegistry()
    let owner = EditorProcessOwner.run(
      workspacePath: "/tmp/CalciteTests/process",
      generation: 1
    )

    let stale = await registry.register(owner: owner) {}
    let current = await registry.register(owner: owner) {}

    let staleDidUnregister = await registry.unregister(stale)
    let registeredLease = await registry.currentLease(for: owner)
    let activeCount = await registry.activeCount
    let currentDidUnregister = await registry.unregister(current)
    XCTAssertFalse(staleDidUnregister)
    XCTAssertEqual(registeredLease, current)
    XCTAssertEqual(activeCount, 1)
    XCTAssertTrue(currentDidUnregister)
  }

  func testPreservingExistingProcessReplacesOnlyOwnershipRecord() async {
    let registry = EditorProcessRegistry()
    let counter = Counter()
    let owner = EditorProcessOwner.liveDebug(workspacePath: "/tmp/CalciteTests/process")

    let stale = await registry.register(owner: owner) {
      await counter.increment()
    }
    let current = await registry.register(
      owner: owner,
      replacementPolicy: .preserveExistingProcess
    ) {}

    let terminationCount = await counter.value
    let staleDidUnregister = await registry.unregister(stale)
    let currentDidUnregister = await registry.unregister(current)
    XCTAssertEqual(terminationCount, 0)
    XCTAssertFalse(staleDidUnregister)
    XCTAssertTrue(currentDidUnregister)
  }
}
