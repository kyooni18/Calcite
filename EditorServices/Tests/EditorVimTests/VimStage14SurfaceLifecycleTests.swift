@_spi(Calcite) @testable import EditorVim
import XCTest

final class VimStage14SurfaceLifecycleTests: XCTestCase {

  func testExistingControllerLookupDoesNotCreateOrSwitchWindowState() {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let firstBuffer = VimBufferID(UUID())
    let unseenBuffer = VimBufferID(UUID())
    let controller = coordinator.controller(
      for: window,
      displaying: firstBuffer,
      text: "first\n",
      cursor: 2,
      name: "first.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )

    XCTAssertTrue(
      coordinator.existingController(for: window, displaying: firstBuffer) === controller
    )
    XCTAssertNil(coordinator.existingController(for: window, displaying: unseenBuffer))
    XCTAssertEqual(coordinator.currentBuffer(for: window), firstBuffer)
    XCTAssertNil(coordinator.alternateBuffer(for: window))
  }

  func testWindowBufferControllerRestoresCursorModeAndVisualStateAfterTabRoundTrip() throws {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let firstBuffer = VimBufferID(UUID())
    let secondBuffer = VimBufferID(UUID())

    let first = coordinator.controller(
      for: window,
      displaying: firstBuffer,
      text: "alpha beta gamma\n",
      cursor: 0,
      name: "first.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    try first.engine.executeNotation("vll")
    let preservedState = first.engine.state
    let preservedSelection = first.engine.selectionSet

    _ = coordinator.controller(
      for: window,
      displaying: secondBuffer,
      text: "second\n",
      cursor: 3,
      name: "second.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )

    let restored = coordinator.controller(
      for: window,
      displaying: firstBuffer,
      text: "alpha beta gamma\n",
      cursor: 12,
      name: "first.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )

    XCTAssertTrue(restored === first)
    XCTAssertEqual(restored.engine.state, preservedState)
    XCTAssertEqual(restored.engine.selectionSet, preservedSelection)
  }

  func testIdenticalConfigurationDoesNotClearPendingOperatorOrMapping() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "alpha\n"))
    let mappings = [
      VimKeyMappingV2(sequence: "jk", command: "<Esc>", modes: [.insert])
    ]

    XCTAssertTrue(
      controller.applyConfiguration(
        signature: "config-a",
        leader: " ",
        localLeader: " ",
        tabWidth: 2,
        startInInsertMode: false,
        inputPolicy: .automatic,
        languageMap: [:],
        mappings: mappings
      )
    )

    let pending = try controller.handle(token: "d")
    XCTAssertTrue(pending.awaitingMoreInput)
    XCTAssertEqual(controller.pendingNotation, "d")
    XCTAssertEqual(controller.interactionSnapshot.pendingCommand.operatorName, "delete")

    XCTAssertFalse(
      controller.applyConfiguration(
        signature: "config-a",
        leader: " ",
        localLeader: " ",
        tabWidth: 2,
        startInInsertMode: false,
        inputPolicy: .automatic,
        languageMap: [:],
        mappings: mappings
      )
    )
    XCTAssertEqual(controller.pendingNotation, "d")
    XCTAssertEqual(controller.interactionSnapshot.pendingCommand.operatorName, "delete")
  }

  func testConfigurationChangeStillCancelsIncompatiblePendingInput() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "alpha\n"))
    _ = controller.applyConfiguration(
      signature: "config-a",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      startInInsertMode: false,
      inputPolicy: .automatic,
      languageMap: [:],
      mappings: []
    )
    _ = try controller.handle(token: "d")
    XCTAssertFalse(controller.pendingNotation.isEmpty)

    XCTAssertTrue(
      controller.applyConfiguration(
        signature: "config-b",
        leader: " ",
        localLeader: " ",
        tabWidth: 4,
        startInInsertMode: false,
        inputPolicy: .physicalUS,
        languageMap: [:],
        mappings: []
      )
    )
    XCTAssertTrue(controller.pendingNotation.isEmpty)
    XCTAssertNil(controller.interactionSnapshot.pendingCommand.operatorName)
  }

  func testIdenticalConfigurationPreservesAmbiguousMappingPrefix() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "alpha\n"))
    let mappings = [
      VimKeyMappingV2(
        sequence: "jk",
        command: "<Esc>",
        modes: [.insert],
        inputDomain: .command
      )
    ]
    _ = controller.applyConfiguration(
      signature: "mapping-config",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      startInInsertMode: true,
      inputPolicy: .automatic,
      languageMap: [:],
      mappings: mappings
    )

    let pending = try controller.handle(token: "j")
    XCTAssertTrue(pending.awaitingMoreInput)
    XCTAssertEqual(controller.pendingNotation, "j")

    XCTAssertFalse(
      controller.applyConfiguration(
        signature: "mapping-config",
        leader: "\\",
        localLeader: "\\",
        tabWidth: 2,
        startInInsertMode: true,
        inputPolicy: .automatic,
        languageMap: [:],
        mappings: mappings
      )
    )
    XCTAssertEqual(controller.pendingNotation, "j")
    XCTAssertTrue(controller.interactionSnapshot.pendingCommand.isMappingPrefix)
  }

  func testHostCursorMoveChangesCursorWithoutReplacingTextOrUndoState() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "alpha beta\n", cursor: 0))
    let beforeText = controller.engine.state.text

    let state = controller.acceptHostCursorMove(toUTF16Offset: 6, source: .pointer)

    XCTAssertEqual(state.cursor, 6)
    XCTAssertEqual(state.text, beforeText)
    try controller.engine.executeNotation("x")
    XCTAssertEqual(controller.engine.state.text, "alpha eta\n")
    try controller.engine.executeNotation("u")
    XCTAssertEqual(controller.engine.state.text, beforeText)
  }

  func testHostCursorMovePreservesInsertAndReplaceModes() throws {
    let insert = VimKeymapController(engine: VimEngine(text: "abcdef\n", cursor: 0))
    _ = try insert.engine.executeNotation("i")
    XCTAssertEqual(insert.engine.state.mode, .insert)
    insert.acceptHostCursorMove(toUTF16Offset: 4, source: .pointer)
    XCTAssertEqual(insert.engine.state.mode, .insert)
    XCTAssertEqual(insert.engine.state.cursor, 4)

    let replace = VimKeymapController(engine: VimEngine(text: "abcdef\n", cursor: 0))
    _ = try replace.engine.executeNotation("R")
    XCTAssertEqual(replace.engine.state.mode, .replace)
    replace.acceptHostCursorMove(toUTF16Offset: 3, source: .pointer)
    XCTAssertEqual(replace.engine.state.mode, .replace)
    XCTAssertEqual(replace.engine.state.cursor, 3)
  }

  func testHostCursorMoveNormalizesLineEndEmptyLineEOFAndUnicodeOffsets() {
    let lineEnd = VimKeymapController(engine: VimEngine(text: "abc\n\nxyz", cursor: 0))
    lineEnd.acceptHostCursorMove(toUTF16Offset: 3, source: .pointer)
    XCTAssertEqual(lineEnd.engine.state.cursor, 2, "normal mode stops before a non-empty line end")

    lineEnd.acceptHostCursorMove(toUTF16Offset: 4, source: .pointer)
    XCTAssertEqual(lineEnd.engine.state.cursor, 4, "empty lines retain their only valid position")

    lineEnd.acceptHostCursorMove(toUTF16Offset: 8, source: .pointer)
    XCTAssertEqual(lineEnd.engine.state.cursor, 7, "normal mode clamps EOF to the final character")

    let unicode = VimKeymapController(engine: VimEngine(text: "😀x\n", cursor: 0))
    unicode.acceptHostCursorMove(toUTF16Offset: 1, source: .pointer)
    XCTAssertEqual(
      unicode.engine.state.cursor,
      0,
      "clicks never leave the cursor inside a surrogate pair"
    )
  }

  func testPlainHostCursorMoveLeavesVisualModeAndCancelsPromptAndParserState() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "alpha beta\n", cursor: 0))
    _ = try controller.engine.executeNotation("vll")
    XCTAssertEqual(controller.engine.state.mode, .visualCharacter)

    controller.acceptHostCursorMove(toUTF16Offset: 6, source: .pointer)

    XCTAssertEqual(controller.engine.state.mode, .normal)
    XCTAssertNil(controller.engine.selectionSet)
    XCTAssertEqual(controller.engine.state.cursor, 6)

    _ = try controller.handle(token: "d")
    XCTAssertFalse(controller.pendingNotation.isEmpty)
    controller.acceptHostCursorMove(toUTF16Offset: 2, source: .pointer)
    XCTAssertTrue(controller.pendingNotation.isEmpty)

    _ = try controller.handle(token: ":")
    XCTAssertTrue(controller.isPromptActive)
    controller.acceptHostCursorMove(toUTF16Offset: 2, source: .pointer)
    XCTAssertFalse(controller.isPromptActive)
    XCTAssertNil(controller.prompt)
  }

  func testSameBufferKeepsIndependentCursorPerWindowAfterHostMoves() {
    let coordinator = VimSessionCoordinator()
    let buffer = VimBufferID(UUID())
    let firstWindow = VimWindowID(UUID())
    let secondWindow = VimWindowID(UUID())
    let first = coordinator.controller(
      for: firstWindow,
      displaying: buffer,
      text: "abcdef\n",
      cursor: 0,
      name: "shared.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    let second = coordinator.controller(
      for: secondWindow,
      displaying: buffer,
      text: "abcdef\n",
      cursor: 1,
      name: "shared.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )

    first.acceptHostCursorMove(toUTF16Offset: 4, source: .pointer)
    second.acceptHostCursorMove(toUTF16Offset: 2, source: .pointer)

    XCTAssertEqual(first.engine.state.cursor, 4)
    XCTAssertEqual(second.engine.state.cursor, 2)
  }
}
