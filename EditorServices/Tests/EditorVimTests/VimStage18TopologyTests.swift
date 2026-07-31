@_spi(Calcite) import EditorVim
import XCTest

final class VimStage18TopologyTests: XCTestCase {
  func testDetachUsesAlternateThenMRUInsteadOfDictionaryOrder() {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let first = VimBufferID(UUID())
    let second = VimBufferID(UUID())
    let third = VimBufferID(UUID())

    attach(first, to: window, coordinator: coordinator, attachment: .activate)
    attach(second, to: window, coordinator: coordinator, attachment: .activate)
    attach(third, to: window, coordinator: coordinator, attachment: .activate)

    XCTAssertEqual(coordinator.currentBuffer(for: window), third)
    XCTAssertEqual(coordinator.alternateBuffer(for: window), second)

    coordinator.detachBuffer(third, from: window)
    XCTAssertEqual(coordinator.currentBuffer(for: window), second)

    coordinator.detachBuffer(second, from: window)
    XCTAssertEqual(coordinator.currentBuffer(for: window), first)
  }

  func testUnloadedCurrentBufferFallsBackToMostRecentLoadedBuffer() {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let first = VimBufferID(UUID())
    let second = VimBufferID(UUID())
    let third = VimBufferID(UUID())

    attach(first, to: window, coordinator: coordinator, attachment: .activate)
    attach(second, to: window, coordinator: coordinator, attachment: .activate)
    attach(third, to: window, coordinator: coordinator, attachment: .activate)
    XCTAssertTrue(coordinator.switchBuffer(in: window, to: second))

    coordinator.unloadBuffer(second)
    XCTAssertEqual(coordinator.currentBuffer(for: window), third)
    XCTAssertNil(coordinator.view(for: window, displaying: second))
  }

  func testWipedBufferDoesNotRemainAsAlternate() {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let first = VimBufferID(UUID())
    let second = VimBufferID(UUID())

    attach(first, to: window, coordinator: coordinator, attachment: .activate)
    attach(second, to: window, coordinator: coordinator, attachment: .activate)
    XCTAssertEqual(coordinator.alternateBuffer(for: window), first)

    coordinator.wipeBuffer(first)
    XCTAssertNil(coordinator.alternateBuffer(for: window))
    XCTAssertEqual(coordinator.currentBuffer(for: window), second)
  }

  private func attach(
    _ buffer: VimBufferID,
    to window: VimWindowID,
    coordinator: VimSessionCoordinator,
    attachment: VimControllerAttachment
  ) {
    _ = coordinator.controller(
      for: window,
      displaying: buffer,
      text: "\(buffer.rawValue.uuidString)\n",
      cursor: 0,
      name: buffer.rawValue.uuidString,
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      attachment: attachment
    )
  }
}
