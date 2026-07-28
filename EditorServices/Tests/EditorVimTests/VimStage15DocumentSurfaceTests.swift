@_spi(Calcite) @testable import EditorVim
import XCTest

final class VimStage15DocumentSurfaceTests: XCTestCase {
  func testRetainedInactiveSurfaceDoesNotChangeCurrentOrAlternateBuffer() {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let activeBuffer = VimBufferID(UUID())
    let inactiveBuffer = VimBufferID(UUID())

    let active = coordinator.controller(
      for: window,
      displaying: activeBuffer,
      text: "active\n",
      cursor: 3,
      name: "active.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )

    let inactive = coordinator.controller(
      for: window,
      displaying: inactiveBuffer,
      text: "inactive\n",
      cursor: 5,
      name: "inactive.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      makeCurrent: false
    )

    XCTAssertNotIdentical(active, inactive)
    XCTAssertEqual(coordinator.currentBuffer(for: window), activeBuffer)
    XCTAssertNil(coordinator.alternateBuffer(for: window))
    XCTAssertTrue(
      coordinator.existingController(for: window, displaying: inactiveBuffer) === inactive
    )
  }

  func testMakingRetainedSurfaceActiveUpdatesBufferRelationshipOnce() {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let firstBuffer = VimBufferID(UUID())
    let secondBuffer = VimBufferID(UUID())

    _ = coordinator.controller(
      for: window,
      displaying: firstBuffer,
      text: "first\n",
      cursor: 0,
      name: "first.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    let retained = coordinator.controller(
      for: window,
      displaying: secondBuffer,
      text: "second\n",
      cursor: 2,
      name: "second.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      makeCurrent: false
    )

    let activated = coordinator.controller(
      for: window,
      displaying: secondBuffer,
      text: "second\n",
      cursor: 0,
      name: "second.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      makeCurrent: true
    )

    XCTAssertTrue(activated === retained)
    XCTAssertEqual(coordinator.currentBuffer(for: window), secondBuffer)
    XCTAssertEqual(coordinator.alternateBuffer(for: window), firstBuffer)
    XCTAssertEqual(activated.engine.state.cursor, 2)
  }
}
