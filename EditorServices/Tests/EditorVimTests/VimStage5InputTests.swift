@_spi(Calcite) import EditorVim
import XCTest

final class VimStage5InputTests: XCTestCase {
  func testAutomaticPolicyUsesPhysicalCommandKeyWithKoreanLayout() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    let controller = VimKeymapController(engine: engine)

    let result = try controller.handle(
      event: .key(
        VimKeyStroke(
          physicalKey: .character(unshifted: "x", shifted: "X"),
          logicalText: "ㅌ",
          textIgnoringModifiers: "ㅌ"
        )
      )
    )

    XCTAssertTrue(result.consumed)
    XCTAssertEqual(engine.state.text, "bc")
  }

  func testLogicalPolicyUsesActiveLayoutForCommands() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    let controller = VimKeymapController(engine: engine)
    controller.inputPolicy = .logical

    _ = try controller.handle(
      event: .key(
        VimKeyStroke(
          physicalKey: .character(unshifted: "x", shifted: "X"),
          logicalText: "ㅌ",
          textIgnoringModifiers: "ㅌ"
        )
      )
    )

    XCTAssertEqual(engine.state.text, "abc")
  }

  func testLiteralFindArgumentUsesCommittedUnicodeText() throws {
    let engine = VimEngine(text: "a한b한c", cursor: 0)
    let controller = VimKeymapController(engine: engine)

    _ = try controller.handle(
      event: .key(
        VimKeyStroke(
          physicalKey: .character(unshifted: "f", shifted: "F"),
          logicalText: "ㄹ",
          textIgnoringModifiers: "ㄹ"
        )
      )
    )
    XCTAssertEqual(controller.expectedInput, .literalCharacter)
    _ = try controller.handle(event: .compositionStarted)
    _ = try controller.handle(event: .compositionUpdated("한", selectedRange: 1..<1))
    _ = try controller.handle(event: .compositionCommitted("한"))

    XCTAssertEqual(engine.state.cursor, 1)
    XCTAssertEqual(controller.expectedInput, .command)
  }

  func testEscapeCancelsPromptCompositionBeforePrompt() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "한글"))
    _ = try controller.handle(token: "/")
    _ = try controller.handle(event: .compositionStarted)
    _ = try controller.handle(event: .compositionUpdated("검색", selectedRange: 2..<2))
    XCTAssertEqual(controller.prompt, "/검색")

    _ = try controller.handle(
      event: .key(VimKeyStroke(physicalKey: .special(.escape)))
    )
    XCTAssertEqual(controller.prompt, "/")
    XCTAssertTrue(controller.isPromptActive)

    _ = try controller.handle(
      event: .key(VimKeyStroke(physicalKey: .special(.escape)))
    )
    XCTAssertNil(controller.prompt)
  }

  func testCommittedCompositionIsOneInsertPayload() throws {
    let engine = VimEngine(text: "", cursor: 0)
    let controller = VimKeymapController(engine: engine)
    _ = try controller.handle(token: "i")
    _ = try controller.handle(event: .compositionStarted)
    _ = try controller.handle(event: .compositionUpdated("한글", selectedRange: 2..<2))
    _ = try controller.handle(event: .compositionCommitted("한글"))
    _ = try controller.handle(token: "<Esc>")

    XCTAssertEqual(engine.state.text, "한글")
    _ = try engine.execute(.undo)
    XCTAssertEqual(engine.state.text, "")
  }

  func testUnicodeReplacementArgumentUsesOneGrapheme() throws {
    let engine = VimEngine(text: "a한c", cursor: 0)
    let controller = VimKeymapController(engine: engine)

    _ = try controller.handle(
      event: .key(
        VimKeyStroke(
          physicalKey: .character(unshifted: "r", shifted: "R"),
          logicalText: "ㄱ",
          textIgnoringModifiers: "ㄱ"
        )
      )
    )
    XCTAssertEqual(controller.expectedInput, .replacementCharacter)
    _ = try controller.handle(event: .compositionStarted)
    _ = try controller.handle(event: .compositionUpdated("글", selectedRange: 1..<1))
    _ = try controller.handle(event: .compositionCommitted("글"))

    XCTAssertEqual(engine.state.text, "글한c")
    XCTAssertEqual(engine.state.cursor, 0)
  }

  func testReplaceModeCompositionReplacesByGraphemeCount() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    let controller = VimKeymapController(engine: engine)

    _ = try controller.handle(token: "R")
    _ = try controller.handle(event: .compositionStarted)
    _ = try controller.handle(event: .compositionUpdated("한글", selectedRange: 2..<2))
    _ = try controller.handle(event: .compositionCommitted("한글"))
    _ = try controller.handle(token: "<Esc>")

    XCTAssertEqual(engine.state.text, "한글c")
    _ = try engine.execute(.undo)
    XCTAssertEqual(engine.state.text, "abc")
  }

  func testPhysicalCommandMappingsWorkWithNonLatinLogicalText() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    let controller = VimKeymapController(
      engine: engine,
      mappings: [VimKeyMapping(sequence: "xx", command: "dd")]
    )
    let stroke = VimKeyStroke(
      physicalKey: .character(unshifted: "x", shifted: "X"),
      logicalText: "ㅌ",
      textIgnoringModifiers: "ㅌ"
    )

    let first = try controller.handle(event: .key(stroke))
    XCTAssertTrue(first.awaitingMoreInput)
    _ = try controller.handle(event: .key(stroke))

    XCTAssertEqual(engine.state.text, "")
  }

  func testLanguageMapTranslatesLogicalCommandKeys() throws {
    let engine = VimEngine(text: "abc", cursor: 1)
    let controller = VimKeymapController(engine: engine)
    controller.inputPolicy = .languageMap
    controller.setLanguageMap(["ㅗ": "h"])

    _ = try controller.handle(
      event: .key(
        VimKeyStroke(
          physicalKey: .character(unshifted: "h", shifted: "H"),
          logicalText: "ㅗ",
          textIgnoringModifiers: "ㅗ"
        )
      )
    )

    XCTAssertEqual(engine.state.cursor, 0)
  }

  func testVerticalMotionUsesCJKDisplayColumns() throws {
    let engine = VimEngine(text: "a한x\n12345\n", cursor: 2, tabWidth: 4)
    _ = try engine.execute(.move(.down))
    XCTAssertEqual(engine.state.cursor, 7)
    _ = try engine.execute(.move(.up))
    XCTAssertEqual(engine.state.cursor, 2)
  }

  func testVerticalMotionUsesTabStops() throws {
    let engine = VimEngine(text: "\tx\n12345\n", cursor: 1, tabWidth: 4)
    _ = try engine.execute(.move(.down))
    XCTAssertEqual(engine.state.cursor, 7)
    _ = try engine.execute(.move(.up))
    XCTAssertEqual(engine.state.cursor, 1)
  }
}
