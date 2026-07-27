@_spi(Calcite) import EditorVim
import XCTest

final class VimStage6UXTests: XCTestCase {
  func testPendingCommandSnapshotTracksCountAndOperator() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "one two"))

    _ = try controller.handle(token: "3")
    XCTAssertEqual(controller.interactionSnapshot.pendingCommand.notation, "3")
    XCTAssertEqual(controller.interactionSnapshot.pendingCommand.count, 3)

    _ = try controller.handle(token: "d")
    let snapshot = controller.interactionSnapshot
    XCTAssertEqual(snapshot.pendingCommand.notation, "3d")
    XCTAssertEqual(snapshot.pendingCommand.operatorName, "delete")
    XCTAssertEqual(snapshot.pendingCommand.expectedInput, .command)
  }

  func testCommandLineSnapshotExposesVisibleCaretAndComposition() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "alpha beta"))
    _ = try controller.handle(token: ":")
    for token in ["e", "d", "i", "t"] { _ = try controller.handle(token: token) }
    _ = try controller.handle(token: "<Left>")
    _ = try controller.handle(event: .compositionStarted)
    _ = try controller.handle(event: .compositionUpdated("한", selectedRange: 1..<1))

    let commandLine = try XCTUnwrap(controller.interactionSnapshot.commandLine)
    XCTAssertEqual(commandLine.prefix, ":")
    XCTAssertEqual(commandLine.text, "edit")
    XCTAssertEqual(commandLine.cursorOffset, 3)
    XCTAssertEqual(commandLine.markedText, "한")
    XCTAssertTrue(controller.interactionSnapshot.isComposingText)
  }

  func testCommandHistoryNavigationUsesCurrentPrefix() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "abc"))
    for command in ["set ignorecase", "edit main.swift", "set smartcase"] {
      _ = try controller.handle(token: ":")
      for character in command { _ = try controller.handle(token: String(character)) }
      _ = try controller.handle(token: "<CR>")
    }

    _ = try controller.handle(token: ":")
    for character in "set" { _ = try controller.handle(token: String(character)) }
    _ = try controller.handle(token: "<Up>")
    XCTAssertEqual(controller.prompt, ":set smartcase")
    _ = try controller.handle(token: "<Up>")
    XCTAssertEqual(controller.prompt, ":set ignorecase")
    _ = try controller.handle(token: "<Down>")
    XCTAssertEqual(controller.prompt, ":set smartcase")
  }

  func testUnknownExCommandPublishesVisibleMessage() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "abc"))
    _ = try controller.handle(token: ":")
    for character in "doesnotexist" { _ = try controller.handle(token: String(character)) }
    _ = try controller.handle(token: "<CR>")

    let message = try XCTUnwrap(controller.interactionSnapshot.message)
    XCTAssertEqual(message.code, "E492")
    XCTAssertTrue(message.text.contains("doesnotexist"))
  }

  func testFailedSearchPublishesPatternNotFoundMessage() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "alpha beta"))
    _ = try controller.handle(token: "/")
    for character in "missing" { _ = try controller.handle(token: String(character)) }
    _ = try controller.handle(token: "<CR>")

    let message = try XCTUnwrap(controller.interactionSnapshot.message)
    XCTAssertEqual(message.code, "E486")
  }

  func testMissingMarkPublishesMessage() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "alpha"))
    _ = try controller.handle(token: "`")
    _ = try controller.handle(token: "a")

    let message = try XCTUnwrap(controller.interactionSnapshot.message)
    XCTAssertEqual(message.code, "E20")
  }

  func testMappingPrefixIsDisplayedImmediatelyAndClearsOnTimeout() throws {
    let controller = VimKeymapController(
      engine: VimEngine(text: "abc", leader: " "),
      mappings: [VimKeyMapping(sequence: "<leader>k", command: "<Esc>")]
    )
    _ = try controller.handle(token: " ")
    XCTAssertTrue(controller.interactionSnapshot.pendingCommand.isMappingPrefix)
    XCTAssertEqual(controller.interactionSnapshot.pendingCommand.notation, "<leader>")
    _ = try controller.handle(event: .mappingTimeout)

    XCTAssertFalse(controller.interactionSnapshot.pendingCommand.isMappingPrefix)
    XCTAssertNil(controller.interactionSnapshot.message)
  }
  func testInsertModeNonRecursiveMappingUsesCommittedText() throws {
    let engine = VimEngine(text: "", cursor: 0)
    let controller = VimKeymapController(engine: engine)
    controller.setMappings([
      VimKeyMappingV2(
        sequence: "jj",
        command: "<Esc>",
        modes: [.insert],
        recursive: false,
        inputDomain: .logicalText
      )
    ])

    _ = try controller.handle(token: "i")
    XCTAssertTrue(try controller.handle(event: .textCommit("j")).awaitingMoreInput)
    _ = try controller.handle(event: .textCommit("j"))

    XCTAssertEqual(engine.state.mode, .normal)
    XCTAssertEqual(engine.state.text, "")
  }

  func testNowaitMappingWinsOverLongerPrefix() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    let controller = VimKeymapController(engine: engine)
    controller.setMappings([
      VimKeyMappingV2(sequence: "g", command: "x", nowait: true),
      VimKeyMappingV2(sequence: "gg", command: "dd"),
    ])

    let result = try controller.handle(token: "g")
    XCTAssertFalse(result.awaitingMoreInput)
    XCTAssertEqual(engine.state.text, "bc")
  }

  func testNonRecursiveMappingDoesNotReenterMappingQueue() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    let controller = VimKeymapController(engine: engine)
    controller.setMappings([
      VimKeyMappingV2(sequence: "x", command: "x", recursive: false)
    ])

    _ = try controller.handle(token: "x")
    XCTAssertEqual(engine.state.text, "bc")
  }

  func testMappingConflictDiagnosticsAreModeSpecific() {
    let controller = VimKeymapController()
    controller.setMappings([
      VimKeyMappingV2(sequence: "jk", command: "<Esc>", modes: [.insert]),
      VimKeyMappingV2(sequence: "jk", command: "<Esc>", modes: [.insert]),
      VimKeyMappingV2(sequence: "jk", command: "x", modes: [.normal]),
    ])

    XCTAssertEqual(
      controller.mappingConflicts,
      [VimMappingConflict(sequence: "jk", mode: .insert)]
    )
  }

  func testMappingInputDomainsRemainIndependent() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    let controller = VimKeymapController(engine: engine)
    controller.setMappings([
      VimKeyMappingV2(
        sequence: "j",
        command: "l",
        modes: [.normal],
        recursive: false,
        inputDomain: .command
      ),
      VimKeyMappingV2(
        sequence: "j",
        command: "iX<Esc>",
        modes: [.normal],
        recursive: true,
        inputDomain: .logicalText
      ),
    ])

    XCTAssertTrue(controller.mappingConflicts.isEmpty)
    _ = try controller.handle(token: "j")
    XCTAssertEqual(engine.state.cursor, 1)
    XCTAssertEqual(engine.state.text, "abc")

    engine.synchronize(text: "abc", cursor: 0)
    _ = try controller.handle(event: .textCommit("j"))
    XCTAssertEqual(engine.state.text, "Xabc")
  }

  func testCommandLineLogicalTextMappingUsesCommittedTextOnly() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "abc"))
    controller.setMappings([
      VimKeyMappingV2(
        sequence: "jj",
        command: "<Esc>",
        modes: [.commandLine],
        recursive: false,
        inputDomain: .logicalText
      )
    ])

    _ = try controller.handle(token: ":")
    _ = try controller.handle(event: .textCommit("j"))
    XCTAssertNotNil(controller.interactionSnapshot.commandLine)
    _ = try controller.handle(event: .textCommit("j"))
    XCTAssertNil(controller.interactionSnapshot.commandLine)
  }

  func testCommandLineOptionArrowsMoveByWords() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "abc"))
    _ = try controller.handle(token: ":")
    _ = try controller.handle(event: .textCommit("edit one two"))

    _ = try controller.handle(
      event: .key(
        VimKeyStroke(
          physicalKey: .special(.left),
          modifiers: [.option]
        )
      )
    )
    XCTAssertEqual(controller.interactionSnapshot.commandLine?.cursorOffset, 9)

    _ = try controller.handle(
      event: .key(
        VimKeyStroke(
          physicalKey: .special(.left),
          modifiers: [.option]
        )
      )
    )
    XCTAssertEqual(controller.interactionSnapshot.commandLine?.cursorOffset, 5)

    _ = try controller.handle(
      event: .key(
        VimKeyStroke(
          physicalKey: .special(.right),
          modifiers: [.option]
        )
      )
    )
    XCTAssertEqual(controller.interactionSnapshot.commandLine?.cursorOffset, 9)
  }

}
