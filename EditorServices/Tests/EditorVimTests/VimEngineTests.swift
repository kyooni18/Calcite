import XCTest

@testable import EditorVim

final class VimEngineTests: XCTestCase {
  func testMethodEditingAndUndo() throws {
    let vim = VimEngine(text: "hello world")
    _ = try vim.execute(.action(.operatorMotion(.delete, .wordForward)))
    XCTAssertEqual(vim.state.text, "world")
    _ = try vim.execute(.action(.undo))
    XCTAssertEqual(vim.state.text, "hello world")
  }

  func testNotationAndLeader() throws {
    let vim = VimEngine(text: "abc")
    vim.mapLeader("ff", to: .action(.host(.custom("find-file"))))
    let result = try vim.execute(.leader("ff"))
    XCTAssertEqual(result.hostRequests, [.custom("find-file")])
    _ = try vim.execute(.notation("A!<Esc>"))
    XCTAssertEqual(vim.state.text, "abc!")
  }

  func testRegistersAndPaste() throws {
    let vim = VimEngine(text: "abc def")
    _ = try vim.execute(.action(.operatorMotion(.yank, .wordForward)))
    _ = try vim.execute(.action(.move(.documentEnd)))
    _ = try vim.execute(.action(.pasteAfter))
    XCTAssertTrue(vim.state.text.contains("abc"))
  }

  func testExHostCommands() throws {
    let vim = VimEngine()
    XCTAssertEqual(try vim.execute(.ex(":wq")).hostRequests, [.writeAndQuit])
  }
}

extension VimEngineTests {
  func testKeymapControllerRetainsOperatorAcrossKeyEvents() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "one two"))
    let first = try controller.handle(token: "d")
    XCTAssertTrue(first.awaitingMoreInput)
    let second = try controller.handle(token: "w")
    XCTAssertFalse(second.awaitingMoreInput)
    XCTAssertEqual(controller.engine.state.text, "two")
  }

  func testKeymapControllerExpandsLeaderAndEmitsHostCommand() throws {
    let engine = VimEngine(text: "value", leader: " ")
    let controller = VimKeymapController(
      engine: engine,
      mappings: [.init(sequence: "<leader>b", command: "<host:build>")]
    )
    XCTAssertTrue(try controller.handle(token: " ").awaitingMoreInput)
    let result = try controller.handle(token: "b")
    XCTAssertEqual(result.execution?.hostRequests, [.custom("build")])
  }

  func testInsertModeIsHandledByTheModalEngine() throws {
    let engine = VimEngine(text: "abc")
    _ = try engine.execute(.action(.enterInsert))
    let controller = VimKeymapController(engine: engine)
    XCTAssertTrue(try controller.handle(token: "x").consumed)
    XCTAssertTrue(try controller.handle(token: "<CR>").consumed)
    XCTAssertTrue(try controller.handle(token: "y").consumed)
    XCTAssertTrue(try controller.handle(token: "<BS>").consumed)
    XCTAssertEqual(engine.state.text, "x\nabc")
    XCTAssertTrue(try controller.handle(token: "<Esc>").consumed)
    XCTAssertEqual(engine.state.mode, .normal)
  }

  func testKeymapControllerRetainsCountAcrossEvents() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "one two three four", cursor: 0))
    XCTAssertTrue(try controller.handle(token: "3").awaitingMoreInput)
    let result = try controller.handle(token: "w")
    XCTAssertEqual(result.execution?.state.cursor, 14)
  }

  func testCommandPromptEmitsWriteRequest() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "value"))
    XCTAssertTrue(try controller.handle(token: ":").awaitingMoreInput)
    XCTAssertEqual(controller.prompt, ":")
    _ = try controller.handle(token: "w")
    XCTAssertEqual(controller.prompt, ":w")
    let result = try controller.handle(token: "<CR>")
    XCTAssertNil(controller.prompt)
    XCTAssertEqual(result.execution?.hostRequests, [.write])
  }

  func testSearchPromptAndRepeatSearch() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "x two y two", cursor: 0))
    _ = try controller.handle(token: "/")
    for token in ["t", "w", "o"] { _ = try controller.handle(token: token) }
    let first = try controller.handle(token: "<CR>")
    XCTAssertEqual(first.execution?.state.cursor, 2)
    let next = try controller.handle(token: "n")
    XCTAssertEqual(next.execution?.state.cursor, 8)
    let previous = try controller.handle(token: "N")
    XCTAssertEqual(previous.execution?.state.cursor, 2)
  }

  func testOperatorCountsAndTextObjectsAcrossEvents() throws {
    let countController = VimKeymapController(
      engine: VimEngine(text: "one two three four five", cursor: 0)
    )
    for token in ["2", "d", "2"] {
      XCTAssertTrue(try countController.handle(token: token).awaitingMoreInput)
    }
    _ = try countController.handle(token: "w")
    XCTAssertEqual(countController.engine.state.text, "five")

    let objectController = VimKeymapController(engine: VimEngine(text: "alpha beta", cursor: 2))
    XCTAssertTrue(try objectController.handle(token: "d").awaitingMoreInput)
    XCTAssertTrue(try objectController.handle(token: "i").awaitingMoreInput)
    _ = try objectController.handle(token: "w")
    XCTAssertEqual(objectController.engine.state.text, " beta")
  }

  func testCommonNormalModeMotionsAndOpenLine() throws {
    let vim = VimEngine(text: "first\nsecond\nthird", cursor: 7)
    _ = try vim.execute(.notation("gg"))
    XCTAssertEqual(vim.state.cursor, 0)
    _ = try vim.execute(.notation("G"))
    XCTAssertGreaterThan(vim.state.cursor, 0)
    _ = try vim.execute(.notation("Ohello<Esc>"))
    XCTAssertTrue(vim.state.text.contains("hello"))
  }

  func testVisualCharacterAndVisualLineOperators() throws {
    let characters = VimEngine(text: "alpha beta")
    _ = try characters.execute(.notation("vlll"))
    XCTAssertEqual(characters.state.mode, .visualCharacter)
    _ = try characters.execute(.notation("d"))
    XCTAssertEqual(characters.state.text, "a beta")
    XCTAssertEqual(characters.state.mode, .normal)

    let lines = VimEngine(text: "one\ntwo\nthree")
    _ = try lines.execute(.notation("Vjd"))
    XCTAssertEqual(lines.state.text, "three")
    XCTAssertEqual(lines.state.mode, .normal)
  }

  func testFindReplaceMarksMacrosAndSubstitute() throws {
    let vim = VimEngine(text: "abcabc")
    _ = try vim.execute(.notation("fb"))
    XCTAssertEqual(vim.state.cursor, 1)
    _ = try vim.execute(.notation("rZ"))
    XCTAssertEqual(vim.state.text, "aZcabc")
    _ = try vim.execute(.notation("ma"))
    _ = try vim.execute(.notation("G`a"))
    XCTAssertEqual(vim.state.cursor, 1)
    _ = try vim.execute(.notation("qxllq"))
    _ = try vim.execute(.notation("0@x"))
    XCTAssertEqual(vim.state.cursor, 2)
    _ = try vim.execute(.notation("0s!<Esc>"))
    XCTAssertTrue(vim.state.text.hasPrefix("!"))
  }

}
