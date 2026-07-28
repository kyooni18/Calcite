import EditorVim
import XCTest

final class VimStage9OperatorMotionTests: XCTestCase {
  func testUppercaseWordMotionsWorkWithOperators() throws {
    let deleteWORD = VimEngine(text: "foo-bar baz\n", cursor: 0)
    try deleteWORD.executeNotation("dW")
    XCTAssertEqual(deleteWORD.state.text, "baz\n")
    XCTAssertEqual(deleteWORD.state.cursor, 0)

    let changeWORD = VimEngine(text: "foo-bar baz\n", cursor: 0)
    try changeWORD.executeNotation("cWX<Esc>")
    XCTAssertEqual(changeWORD.state.text, "X baz\n")
    XCTAssertEqual(changeWORD.state.cursor, 0)

    let deleteBackwardWORD = VimEngine(text: "one foo-bar baz\n", cursor: 8)
    try deleteBackwardWORD.executeNotation("dB")
    XCTAssertEqual(deleteBackwardWORD.state.text, "one bar baz\n")

    let deleteWORDEnd = VimEngine(text: "foo-bar baz\n", cursor: 0)
    try deleteWORDEnd.executeNotation("dE")
    XCTAssertEqual(deleteWORDEnd.state.text, " baz\n")

    let yankWORD = VimEngine(text: "foo-bar baz\n", cursor: 0)
    try yankWORD.executeNotation("yW")
    XCTAssertEqual(yankWORD.register(.unnamed), "foo-bar ")
    XCTAssertEqual(yankWORD.state.text, "foo-bar baz\n")
  }

  func testPreviousWordEndMotionsWorkWithOperators() throws {
    let word = VimEngine(text: "one two three\n", cursor: 8)
    try word.executeNotation("dge")
    XCTAssertEqual(word.state.text, "one twhree\n")
    XCTAssertEqual(word.state.cursor, 6)

    let wholeWord = VimEngine(text: "one-two three\n", cursor: 8)
    try wholeWord.executeNotation("dgE")
    XCTAssertEqual(wholeWord.state.text, "one-twhree\n")
    XCTAssertEqual(wholeWord.state.cursor, 6)
  }

  func testFindAndTillMotionsWorkWithOperators() throws {
    let forward = VimEngine(text: "abcxdef\n", cursor: 0)
    try forward.executeNotation("dfx")
    XCTAssertEqual(forward.state.text, "def\n")

    let tillForward = VimEngine(text: "abc,def\n", cursor: 0)
    try tillForward.executeNotation("ct,X<Esc>")
    XCTAssertEqual(tillForward.state.text, "X,def\n")

    let yankForward = VimEngine(text: "abcxdef\n", cursor: 0)
    try yankForward.executeNotation("yfx")
    XCTAssertEqual(yankForward.register(.unnamed), "abcx")

    let backward = VimEngine(text: "xabcx\n", cursor: 4)
    try backward.executeNotation("dFx")
    XCTAssertEqual(backward.state.text, "x\n")

    let tillBackward = VimEngine(text: "xabcx\n", cursor: 4)
    try tillBackward.executeNotation("dTx")
    XCTAssertEqual(tillBackward.state.text, "xx\n")
  }

  func testCaseOperatorsWaitForMotion() throws {
    let engine = VimEngine(text: "one two\n", cursor: 0)
    let controller = VimKeymapController(engine: engine)

    XCTAssertTrue(try controller.handle(token: "g").awaitingMoreInput)
    XCTAssertTrue(try controller.handle(token: "U").awaitingMoreInput)
    XCTAssertEqual(engine.state.text, "one two\n")
    XCTAssertFalse(try controller.handle(token: "w").awaitingMoreInput)
    XCTAssertEqual(engine.state.text, "ONE two\n")

    let lower = VimEngine(text: "ONE TWO\n", cursor: 0)
    try lower.executeNotation("guw")
    XCTAssertEqual(lower.state.text, "one TWO\n")

    let swapped = VimEngine(text: "One TWO\n", cursor: 0)
    try swapped.executeNotation("g~w")
    XCTAssertEqual(swapped.state.text, "oNE TWO\n")

    let line = VimEngine(text: "one two\nnext\n", cursor: 0)
    try line.executeNotation("gUU")
    XCTAssertEqual(line.state.text, "ONE TWO\nnext\n")
  }

  func testLinewiseChangePreservesOneBlankLine() throws {
    let cc = VimEngine(text: "  one two\nnext\n", cursor: 2)
    try cc.executeNotation("ccX<Esc>")
    XCTAssertEqual(cc.state.text, "X\nnext\n")
    XCTAssertEqual(cc.state.cursor, 0)

    let substituteLine = VimEngine(text: "  one two\nnext\n", cursor: 2)
    try substituteLine.executeNotation("SX<Esc>")
    XCTAssertEqual(substituteLine.state.text, "X\nnext\n")

    let counted = VimEngine(text: "one\ntwo\nthree\n", cursor: 0)
    try counted.executeNotation("2ccX<Esc>")
    XCTAssertEqual(counted.state.text, "X\nthree\n")
  }

  func testDeletingWholeDocumentKeepsBlankLine() throws {
    let linewise = VimEngine(text: "one", cursor: 0)
    try linewise.executeNotation("dd")
    XCTAssertEqual(linewise.state.text, "\n")
    XCTAssertEqual(linewise.state.cursor, 0)

    let characterwise = VimEngine(text: "a", cursor: 0)
    try characterwise.executeNotation("x")
    XCTAssertEqual(characterwise.state.text, "\n")
    XCTAssertEqual(characterwise.state.cursor, 0)
  }

  func testFailedPercentOperatorIsNoOp() throws {
    let engine = VimEngine(text: "abc\n", cursor: 1)
    try engine.executeNotation("d%")
    XCTAssertEqual(engine.state.text, "abc\n")
    XCTAssertEqual(engine.state.cursor, 1)
  }

  func testCountedReplaceLeavesCursorOnLastReplacementAndRepeats() throws {
    let engine = VimEngine(text: "abcdef abcdef\n", cursor: 1)
    try engine.executeNotation("3rX")
    XCTAssertEqual(engine.state.text, "aXXXef abcdef\n")
    XCTAssertEqual(engine.state.cursor, 3)

    try engine.executeNotation("w.")
    XCTAssertEqual(engine.state.text, "aXXXef XXXdef\n")
    XCTAssertEqual(engine.state.cursor, 9)
  }

  func testAroundWordOnWhitespaceIncludesFollowingWord() throws {
    let around = VimEngine(text: "one   two\n", cursor: 3)
    try around.executeNotation("daw")
    XCTAssertEqual(around.state.text, "one\n")
    XCTAssertEqual(around.state.cursor, 2)

    let inner = VimEngine(text: "one   two\n", cursor: 3)
    try inner.executeNotation("diw")
    XCTAssertEqual(inner.state.text, "onetwo\n")

    let aroundWORD = VimEngine(text: "one   two-three\n", cursor: 3)
    try aroundWORD.executeNotation("daW")
    XCTAssertEqual(aroundWORD.state.text, "one\n")
  }

  func testVisualWordTextObjectsSelectObject() throws {
    let inner = VimEngine(text: "one two\n", cursor: 1)
    try inner.executeNotation("viwx")
    XCTAssertEqual(inner.state.text, " two\n")
    XCTAssertEqual(inner.state.cursor, 0)

    let around = VimEngine(text: "one two\n", cursor: 1)
    try around.executeNotation("vawx")
    XCTAssertEqual(around.state.text, "two\n")
    XCTAssertEqual(around.state.cursor, 0)

    let aroundWhitespace = VimEngine(text: "one   two\n", cursor: 3)
    try aroundWhitespace.executeNotation("vawx")
    XCTAssertEqual(aroundWhitespace.state.text, "one\n")
    XCTAssertEqual(aroundWhitespace.state.cursor, 2)

    let innerWORD = VimEngine(text: "one.two three\n", cursor: 1)
    try innerWORD.executeNotation("viWx")
    XCTAssertEqual(innerWORD.state.text, " three\n")
  }

  func testCountedLogicalMotionsClampAndPreserveWantedColumn() throws {
    let lines = (0..<20).map { "line\($0)-value" }.joined(separator: "\n")
    let engine = VimEngine(text: lines, cursor: 3)

    try engine.executeNotation("13j")
    let expectedLineStart = (lines as NSString).range(of: "line13-value").location
    XCTAssertEqual(engine.state.cursor, expectedLineStart + 3)

    try engine.executeNotation("999k")
    XCTAssertEqual(engine.state.cursor, 3)

    try engine.executeNotation("999l")
    XCTAssertEqual(engine.state.cursor, 10)
    try engine.executeNotation("999h")
    XCTAssertEqual(engine.state.cursor, 0)
  }

  func testDollarKeepsEndOfLineGoalAcrossVerticalMotions() throws {
    let engine = VimEngine(text: "abcdef\nx\nabcdefgh", cursor: 0)
    try engine.executeNotation("$jj")
    XCTAssertEqual(engine.state.cursor, 16)
  }

  func testVisualEscapeAcceptsCanonicalSpecialKeySpelling() throws {
    for notation in ["v<Esc>", "V<Esc>", "<C-V><Esc>"] {
      let engine = VimEngine(text: "abc\ndef", cursor: 0)
      try engine.executeNotation(notation)
      XCTAssertEqual(engine.state.mode, .normal, notation)
      XCTAssertNil(engine.state.selection, notation)
    }
  }

  func testParsedOperatorMotionRepeatsAndReplaysInMacro() throws {
    let repeated = VimEngine(text: "one.two three.four", cursor: 0)
    try repeated.executeNotation("dWw.")
    XCTAssertEqual(repeated.state.text, "three")

    let macro = VimEngine(text: "one.two three.four", cursor: 0)
    try macro.executeNotation("qadWqw@a")
    XCTAssertEqual(macro.state.text, "three")
  }

  func testVeryLargeCountSaturatesWithoutOverflowOrIterationStall() throws {
    let engine = VimEngine(text: "a\nb\nc", cursor: 0)
    let hugeCount = String(repeating: "9", count: 200)
    try engine.executeNotation(hugeCount + "j")
    XCTAssertEqual(engine.state.cursor, 4)

    let word = VimEngine(text: "one two", cursor: 0)
    try word.executeNotation(hugeCount + "W")
    XCTAssertEqual(word.state.cursor, 6)
  }

}
