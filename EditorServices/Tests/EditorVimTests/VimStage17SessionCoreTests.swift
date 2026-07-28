@_spi(Calcite) @testable import EditorVim
import XCTest

final class VimStage17SessionCoreTests: XCTestCase {
  func testCoordinatorUsesOneSessionEngineAndOneControllerPerWindow() {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let firstBuffer = VimBufferID(UUID())
    let secondBuffer = VimBufferID(UUID())

    let firstController = coordinator.controller(
      for: window,
      displaying: firstBuffer,
      text: "first\n",
      cursor: 1,
      name: "first.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    let secondController = coordinator.controller(
      for: window,
      displaying: secondBuffer,
      text: "second\n",
      cursor: 3,
      name: "second.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      attachment: .retain
    )

    XCTAssertIdentical(firstController, secondController)
    XCTAssertIdentical(firstController.sessionEngine, coordinator.engine)
    XCTAssertEqual(coordinator.view(for: window, displaying: firstBuffer)?.state.cursor, 1)
    XCTAssertEqual(coordinator.view(for: window, displaying: secondBuffer)?.state.cursor, 3)

    XCTAssertTrue(coordinator.switchBuffer(in: window, to: secondBuffer))
    XCTAssertEqual(firstController.engine.state.cursor, 3)
  }

  func testSharedBufferEditsAndUndoPropagateWithoutManualReconciliation() throws {
    let coordinator = VimSessionCoordinator()
    let buffer = VimBufferID(UUID())
    let first = coordinator.controller(
      for: VimWindowID(UUID()),
      displaying: buffer,
      text: "alpha beta\n",
      cursor: 0,
      name: "shared.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    let second = coordinator.controller(
      for: VimWindowID(UUID()),
      displaying: buffer,
      text: "alpha beta\n",
      cursor: 6,
      name: "shared.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )

    try first.engine.executeNotation("0x")
    XCTAssertEqual(first.engine.state.text, "lpha beta\n")
    XCTAssertEqual(second.engine.state.text, "lpha beta\n")
    XCTAssertEqual(second.engine.state.cursor, 5)

    try second.engine.executeNotation("u")
    XCTAssertEqual(first.engine.state.text, "alpha beta\n")
    XCTAssertEqual(second.engine.state.text, "alpha beta\n")
  }

  func testRevisionCheckedExternalSnapshotRejectsStaleBase() throws {
    let coordinator = VimSessionCoordinator()
    let buffer = VimBufferID(UUID())
    let first = coordinator.controller(
      for: VimWindowID(UUID()),
      displaying: buffer,
      text: "abc\n",
      cursor: 0,
      name: "shared.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    let second = coordinator.controller(
      for: VimWindowID(UUID()),
      displaying: buffer,
      text: "abc\n",
      cursor: 2,
      name: "shared.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )

    let initial = try XCTUnwrap(coordinator.bufferSnapshot(buffer))
    try first.engine.executeNotation("x")
    let edited = try XCTUnwrap(coordinator.bufferSnapshot(buffer))
    XCTAssertGreaterThan(edited.revision, initial.revision)

    XCTAssertEqual(
      coordinator.applyExternalSnapshot(
        "stale\n",
        to: buffer,
        baseRevision: initial.revision
      ),
      .conflict(current: edited)
    )

    let result = coordinator.applyExternalSnapshot(
      "external\n",
      to: buffer,
      baseRevision: edited.revision
    )
    guard case .committed(let committed) = result else {
      return XCTFail("Expected committed external snapshot")
    }
    XCTAssertEqual(committed.text, "external\n")
    XCTAssertEqual(first.engine.state.text, "external\n")
    XCTAssertEqual(second.engine.state.text, "external\n")
  }


  func testMappingTimeoutRemainsBoundToOriginViewAfterBufferSwitch() async throws {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let firstBuffer = VimBufferID(UUID())
    let secondBuffer = VimBufferID(UUID())
    let controller = coordinator.controller(
      for: window,
      displaying: firstBuffer,
      text: "",
      cursor: 0,
      name: "first.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    _ = coordinator.controller(
      for: window,
      displaying: secondBuffer,
      text: "second\n",
      cursor: 0,
      name: "second.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      attachment: .retain
    )
    _ = controller.applyConfiguration(
      signature: "stage17-timeout",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      startInInsertMode: true,
      inputPolicy: .automatic,
      languageMap: [:],
      mappings: [
        VimKeyMappingV2(sequence: "jk", command: "<Esc>", modes: [.insert])
      ]
    )
    XCTAssertTrue(try controller.handle(token: "j").awaitingMoreInput)

    let notification = expectation(description: "origin-view mapping timeout")
    controller.scheduleMappingTimeout(milliseconds: 5) {
      notification.fulfill()
    }
    XCTAssertTrue(coordinator.switchBuffer(in: window, to: secondBuffer))
    await fulfillment(of: [notification], timeout: 1)

    XCTAssertEqual(controller.engine.state.text, "second\n")
    XCTAssertTrue(coordinator.switchBuffer(in: window, to: firstBuffer))
    XCTAssertEqual(controller.consumePendingAsynchronousResults().count, 1)
    XCTAssertEqual(controller.engine.state.text, "j")
    XCTAssertEqual(controller.engine.state.mode, .insert)
  }

  func testDetachAndWindowRemovalRepairEngineLifecycle() {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let first = VimBufferID(UUID())
    let second = VimBufferID(UUID())

    _ = coordinator.controller(
      for: window,
      displaying: first,
      text: "first\n",
      cursor: 0,
      name: "first.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    _ = coordinator.controller(
      for: window,
      displaying: second,
      text: "second\n",
      cursor: 0,
      name: "second.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      attachment: .activate
    )

    coordinator.detachBuffer(second, from: window)
    XCTAssertEqual(coordinator.currentBuffer(for: window), first)
    XCTAssertNil(coordinator.view(for: window, displaying: second))

    coordinator.removeWindow(window)
    XCTAssertNil(coordinator.currentBuffer(for: window))
    XCTAssertNil(coordinator.existingController(for: window, displaying: first))
  }
}
