import XCTest

@testable import Calcite

final class WorkspaceRuntimeSupportTests: XCTestCase {
  @MainActor
  func testReplacementCancelsAndSerializesTaskSlot() async {
    let supervisor = WorkspaceTaskSupervisor()
    var events: [String] = []

    supervisor.replace(.auxiliary("test")) { _ in
      events.append("first-start")
      do {
        try await Task.sleep(for: .milliseconds(100))
      } catch {
        events.append("first-cancel")
        return
      }
      events.append("first-end")
    }
    await Task.yield()
    supervisor.replace(.auxiliary("test")) { lease in
      XCTAssertTrue(supervisor.isCurrent(lease))
      events.append("second")
    }

    await supervisor.cancelAndWait(.auxiliary("test"))
    XCTAssertEqual(Array(events.prefix(2)), ["first-start", "first-cancel"])
    XCTAssertFalse(supervisor.contains(.auxiliary("test")))
  }

  @MainActor
  func testRuntimeStateRejectsImpossibleTransition() {
    XCTAssertTrue(WorkspaceRuntimeState.idle.permitsTransition(to: .starting(UUID())))
    XCTAssertFalse(WorkspaceRuntimeState.terminated.permitsTransition(to: .running))
    XCTAssertTrue(WorkspaceRuntimeState.shuttingDown.permitsTransition(to: .terminated))
  }
  func testServiceRecoveryPolicyBacksOffAndStopsRestartLoop() {
    var policy = WorkspaceServiceRecoveryPolicy(
      maximumAttempts: 3,
      attemptWindow: 60,
      baseDelayMilliseconds: 250
    )
    let now = Date(timeIntervalSince1970: 1_000)

    XCTAssertEqual(
      policy.nextDecision(for: "sourcekit-lsp", now: now),
      WorkspaceServiceRecoveryDecision(attempt: 1, delay: .milliseconds(250))
    )
    XCTAssertEqual(
      policy.nextDecision(for: "sourcekit-lsp", now: now.addingTimeInterval(1)),
      WorkspaceServiceRecoveryDecision(attempt: 2, delay: .milliseconds(500))
    )
    XCTAssertEqual(
      policy.nextDecision(for: "sourcekit-lsp", now: now.addingTimeInterval(2)),
      WorkspaceServiceRecoveryDecision(attempt: 3, delay: .milliseconds(1_000))
    )
    XCTAssertNil(
      policy.nextDecision(for: "sourcekit-lsp", now: now.addingTimeInterval(3))
    )
    XCTAssertEqual(
      policy.nextDecision(for: "sourcekit-lsp", now: now.addingTimeInterval(70))?.attempt,
      1
    )
  }

  @MainActor
  func testSupervisorRejectsWorkAfterShutdownBarrier() async {
    let supervisor = WorkspaceTaskSupervisor()
    var didRun = false

    await supervisor.cancelAllAndWait(rejectingNewTasks: true)
    let lease = supervisor.replace(.auxiliary("after-shutdown")) { _ in didRun = true }

    XCTAssertNil(lease)
    XCTAssertFalse(didRun)
    XCTAssertEqual(supervisor.activeCount, 0)
  }

}
