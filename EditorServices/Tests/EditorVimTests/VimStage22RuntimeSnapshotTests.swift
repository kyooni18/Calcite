@_spi(Calcite) import EditorVim
import XCTest

final class VimStage22RuntimeSnapshotTests: XCTestCase {
  func testRuntimeSnapshotRestoresReversedVisualSelectionAndViewport() throws {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let buffer = VimBufferID(UUID())
    let text = "abcdef\nsecond\n"
    let controller = coordinator.controller(
      for: window,
      displaying: buffer,
      text: text,
      cursor: 5,
      name: "runtime.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )

    _ = try controller.engine.execute(.enterVisualCharacter)
    _ = try controller.engine.execute(.move(.left), count: 2)
    controller.engine.updateWindowPresentation(
      inputSourceIdentifier: "com.apple.keylayout.ABC",
      updatesInputSource: true,
      horizontalScrollOffset: 12,
      verticalScrollOffset: 340,
      zoomScale: 1.25
    )

    let captured = try XCTUnwrap(
      coordinator.runtimeSnapshot(for: window, displaying: buffer)
    )
    XCTAssertEqual(captured.cursor, 3)
    XCTAssertEqual(captured.visualAnchor, 5)
    XCTAssertEqual(captured.mode, .visualCharacter)

    coordinator.removeWindow(window)
    let restoredController = coordinator.controller(
      for: window,
      displaying: buffer,
      text: text,
      cursor: 0,
      name: "runtime.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    XCTAssertTrue(
      coordinator.restoreRuntimeSnapshot(
        captured,
        for: window,
        displaying: buffer
      )
    )

    XCTAssertEqual(restoredController.engine.state.cursor, 3)
    XCTAssertEqual(restoredController.engine.state.mode, .visualCharacter)
    XCTAssertEqual(restoredController.engine.selectionSet?.anchor.utf16Offset, 5)
    XCTAssertEqual(restoredController.engine.selectionSet?.active.utf16Offset, 3)
    XCTAssertEqual(restoredController.engine.windowPresentationState.verticalScrollOffset, 340)
    XCTAssertEqual(restoredController.engine.windowPresentationState.zoomScale, 1.25)
  }

  func testRuntimeSnapshotCodableRoundTripPreservesWindowState() throws {
    let value = VimViewRuntimeSnapshot(
      cursor: 12,
      mode: .visualLine,
      visualAnchor: 4,
      visualSelectionShape: .line,
      preferredColumn: 9,
      preferredVisualColumn: 8,
      inputSourceIdentifier: "input.source",
      horizontalScrollOffset: 3,
      verticalScrollOffset: 240,
      zoomScale: 1.4,
      viewportTopLine: 11,
      viewportBottomLine: 35
    )

    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(VimViewRuntimeSnapshot.self, from: data)
    XCTAssertEqual(decoded, value)
  }

  func testTransientPromptModeRestoresAsNormal() {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let buffer = VimBufferID(UUID())
    let controller = coordinator.controller(
      for: window,
      displaying: buffer,
      text: "command\n",
      cursor: 2,
      name: "prompt.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )

    XCTAssertTrue(
      coordinator.restoreRuntimeSnapshot(
        VimViewRuntimeSnapshot(cursor: 2, mode: .commandLine),
        for: window,
        displaying: buffer
      )
    )
    XCTAssertEqual(controller.engine.state.mode, .normal)
    XCTAssertEqual(controller.engine.state.cursor, 2)
  }

  func testRuntimeSnapshotRestoresPreferredColumnsAndNormalCursor() throws {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let buffer = VimBufferID(UUID())
    let controller = coordinator.controller(
      for: window,
      displaying: buffer,
      text: "one\ntwo\nthree\n",
      cursor: 0,
      name: "columns.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    let requested = VimViewRuntimeSnapshot(
      cursor: 9,
      mode: .normal,
      preferredColumn: 7,
      preferredVisualColumn: 6,
      horizontalScrollOffset: 4,
      verticalScrollOffset: 90,
      zoomScale: 0.9,
      viewportTopLine: 3,
      viewportBottomLine: 12
    )

    XCTAssertTrue(
      coordinator.restoreRuntimeSnapshot(
        requested,
        for: window,
        displaying: buffer
      )
    )
    let restored = try XCTUnwrap(
      coordinator.runtimeSnapshot(for: window, displaying: buffer)
    )

    XCTAssertEqual(controller.engine.state.cursor, 9)
    XCTAssertEqual(restored.mode, .normal)
    XCTAssertEqual(restored.preferredColumn, 7)
    XCTAssertEqual(restored.preferredVisualColumn, 6)
    XCTAssertEqual(restored.viewportTopLine, 3)
    XCTAssertEqual(restored.viewportBottomLine, 12)
  }
}
