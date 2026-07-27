import EditorCore
import EditorVim
import XCTest

final class VimKeymapControllerTests: XCTestCase {
  func testMappingLongestMatchAndTimeoutFlush() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    let controller = VimKeymapController(
      engine: engine,
      mappings: [
        VimKeyMapping(sequence: "g", command: "x"),
        VimKeyMapping(sequence: "gg", command: "dd"),
      ]
    )

    XCTAssertTrue(try controller.handle(token: "g").awaitingMoreInput)
    _ = try controller.handle(token: "<timeout>")
    XCTAssertEqual(engine.state.text, "bc")
  }

  func testInsertModeSpecialTokensAreNotInsertedLiterally() throws {
    let engine = VimEngine(text: "", cursor: 0)
    let controller = VimKeymapController(engine: engine)
    _ = try controller.handle(token: "i")
    _ = try controller.handle(token: "<Tab>")
    _ = try controller.handle(token: "x")
    _ = try controller.handle(token: "<Esc>")
    XCTAssertEqual(engine.state.text, "\tx")
  }

  func testRecursiveMappingProcessesRemainderThroughMappingQueue() throws {
    let engine = VimEngine(text: "abcd", cursor: 0)
    let controller = VimKeymapController(
      engine: engine,
      mappings: [
        VimKeyMapping(sequence: "a", command: "b"),
        VimKeyMapping(sequence: "b", command: "x"),
      ]
    )
    _ = try controller.handle(token: "a")
    XCTAssertEqual(engine.state.text, "bcd")
  }

  func testMappingRecursionIsBounded() throws {
    let controller = VimKeymapController(
      mappings: [VimKeyMapping(sequence: "x", command: "x")]
    )
    XCTAssertThrowsError(try controller.handle(token: "x")) { error in
      XCTAssertEqual(error as? VimError, .macroRecursionLimit)
    }
  }

  func testBuiltinPrefixSurvivesMappingTimeout() throws {
    let engine = VimEngine(text: "one\ntwo\n", cursor: 0)
    let controller = VimKeymapController(engine: engine)
    XCTAssertTrue(try controller.handle(token: "d").awaitingMoreInput)
    XCTAssertTrue(try controller.handle(token: "<timeout>").awaitingMoreInput)
    _ = try controller.handle(token: "d")
    XCTAssertEqual(engine.state.text, "two\n")
  }

  func testPromptHistoryNavigation() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "abc"))
    _ = try controller.handle(token: ":")
    for token in ["s", "e", "t", "<CR>"] { _ = try controller.handle(token: token) }
    _ = try controller.handle(token: ":")
    _ = try controller.handle(token: "<Up>")
    XCTAssertEqual(controller.prompt, ":set")
  }
}
