import EditorCore
import EditorVim
import XCTest

final class VimEngineTests: XCTestCase {
  func testMarkTracksInsertionBeforeIt() throws {
    let engine = VimEngine(text: "abc", cursor: 1)
    try engine.executeNotation("ma0iX<Esc>`a")
    XCTAssertEqual(engine.state.cursor, 2)
  }

  func testLinewisePasteIntoEmptyBufferDoesNotCreateLeadingBlankLine() throws {
    let engine = VimEngine()
    engine.setRegister(.unnamed, text: "one\n")
    try engine.executeNotation("p")
    XCTAssertEqual(engine.state.text, "one")
  }

  func testSentenceObjectDoesNotCrashBeforeEmoji() throws {
    let engine = VimEngine(text: "Hello. 👩‍💻 Next.", cursor: 1)
    try engine.executeNotation("dis")
    XCTAssertEqual(engine.state.text, " 👩‍💻 Next.")
  }

  func testNotationReportsAggregatedTextChange() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    let result = try engine.executeNotation("iX<Esc>")
    XCTAssertTrue(result.didChangeText)
  }

  func testOperatorRightDeletesLastCharacter() throws {
    let engine = VimEngine(text: "abc", cursor: 2)
    try engine.execute(.operatorMotion(.delete, .right))
    XCTAssertEqual(engine.state.text, "ab")
  }

  func testCRLFLineEndAndDeletePreserveTerminator() throws {
    let engine = VimEngine(text: "abc def\r\nnext", cursor: 4)
    try engine.executeNotation("D")
    XCTAssertEqual(engine.state.text, "abc \r\nnext")
  }

  func testRandomizedCompleteCommandsKeepValidUTF16Cursor() throws {
    let commands = [
      "h", "j", "k", "l", "w", "b", "e", "0", "$", "x", "~", "J",
      "dw", "de", "dd", "u", "<c-r>", "iX<Esc>", "aY<Esc>", "p",
    ]
    var seed: UInt64 = 0xC0FFEE
    func nextIndex(_ upperBound: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      return Int(seed % UInt64(upperBound))
    }

    for outer in 0..<30 {
      let engine = VimEngine(text: "A👩‍💻-word\r\n짧음\nlast", cursor: 0)
      for inner in 0..<100 {
        let command = commands[nextIndex(commands.count)]
        _ = try? engine.executeNotation(command)
        XCTAssertGreaterThanOrEqual(engine.state.cursor, 0)
        XCTAssertLessThanOrEqual(engine.state.cursor, engine.state.text.utf16.count)
        let utf16Index = engine.state.text.utf16.index(
          engine.state.text.utf16.startIndex,
          offsetBy: engine.state.cursor
        )
        XCTAssertNotNil(
          String.Index(utf16Index, within: engine.state.text),
          "outer=\(outer) inner=\(inner) command=\(command) cursor=\(engine.state.cursor) text=\(engine.state.text.debugDescription)"
        )
      }
    }
  }

  func testNormalLineEndStopsOnLastCharacter() throws {
    let engine = VimEngine(text: "abc\ndef", cursor: 0)
    try engine.executeNotation("$")
    XCTAssertEqual(engine.state.cursor, 2)
  }

  func testDDoesNotJoinNextLine() throws {
    let engine = VimEngine(text: "abc def\nnext", cursor: 4)
    try engine.executeNotation("D")
    XCTAssertEqual(engine.state.text, "abc \nnext")
    XCTAssertEqual(engine.register(.unnamed), "def")
  }

  func testInsertSessionIsSingleUndoUnit() throws {
    let engine = VimEngine(text: "tail", cursor: 0)
    try engine.executeNotation("iabc<Esc>")
    XCTAssertEqual(engine.state.text, "abctail")
    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "tail")
    try engine.executeNotation("<c-r>")
    XCTAssertEqual(engine.state.text, "abctail")
  }

  func testDotRepeatsCompleteInsert() throws {
    let engine = VimEngine(text: "one two", cursor: 0)
    try engine.executeNotation("iX<Esc>")
    try engine.executeNotation("w.")
    XCTAssertEqual(engine.state.text, "Xone Xtwo")
  }

  func testOpenLineBelowTypesIntoCreatedLine() throws {
    let engine = VimEngine(text: "one\ntwo", cursor: 0)
    try engine.executeNotation("oX<Esc>")
    XCTAssertEqual(engine.state.text, "one\nX\ntwo")
  }

  func testOpenLineAboveTypesIntoCreatedLine() throws {
    let engine = VimEngine(text: "one\ntwo", cursor: 4)
    try engine.executeNotation("OX<Esc>")
    XCTAssertEqual(engine.state.text, "one\nX\ntwo")
  }

  func testInsertBackspaceDoesNotOverwriteUnnamedRegister() throws {
    let engine = VimEngine(text: "one two", cursor: 0)
    try engine.executeNotation("yw")
    let before = engine.register(.unnamed)
    try engine.executeNotation("A!<BS><Esc>")
    XCTAssertEqual(engine.register(.unnamed), before)
  }

  func testChangeWordPreservesFollowingWhitespace() throws {
    let engine = VimEngine(text: "alpha beta", cursor: 0)
    try engine.executeNotation("cwX<Esc>")
    XCTAssertEqual(engine.state.text, "X beta")
  }

  func testChangeWordAndTypedReplacementUndoTogether() throws {
    let engine = VimEngine(text: "alpha beta", cursor: 0)
    try engine.executeNotation("cwX<Esc>")
    XCTAssertEqual(engine.state.text, "X beta")
    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "alpha beta")
  }

  func testNamedRegisterPrefixAndUppercaseAppend() throws {
    let engine = VimEngine(text: "one\ntwo\n", cursor: 0)
    try engine.executeNotation("\"ayy")
    try engine.executeNotation("j\"Ayy")
    XCTAssertEqual(engine.register(.named("a")), "one\ntwo\n")
  }

  func testNumberedDeleteRegistersRotate() throws {
    let engine = VimEngine(text: "one\ntwo\nthree\n", cursor: 0)
    try engine.executeNotation("dd")
    try engine.executeNotation("dd")
    XCTAssertEqual(engine.register(.numbered(1)), "two\n")
    XCTAssertEqual(engine.register(.numbered(2)), "one\n")
  }

  func testBlackHoleRegisterPreservesUnnamed() throws {
    let engine = VimEngine(text: "one two", cursor: 0)
    try engine.executeNotation("yw")
    let previous = engine.register(.unnamed)
    try engine.executeNotation("\"_dw")
    XCTAssertEqual(engine.register(.unnamed), previous)
  }

  func testLinewisePasteUsesLineBoundaries() throws {
    let engine = VimEngine(text: "one\ntwo\n", cursor: 0)
    try engine.executeNotation("yyp")
    XCTAssertEqual(engine.state.text, "one\none\ntwo\n")
  }

  func testReverseVisualSelectionKeepsAnchor() throws {
    let engine = VimEngine(text: "abcd", cursor: 3)
    try engine.executeNotation("vhhx")
    XCTAssertEqual(engine.state.text, "a")
  }

  func testVerticalMovementPreservesDesiredColumn() throws {
    let engine = VimEngine(text: "abcdef\nx\nabcdef\n", cursor: 5)
    try engine.executeNotation("jj")
    XCTAssertEqual(engine.state.cursor, 14)
  }

  func testNestedParenthesesTextObject() throws {
    let engine = VimEngine(text: "a(b(c)d)e", cursor: 4)
    try engine.executeNotation("di(")
    XCTAssertEqual(engine.state.text, "a(b()d)e")
  }

  func testWordAndWORDTextObjectsDiffer() throws {
    let word = VimEngine(text: "foo-bar baz", cursor: 1)
    try word.executeNotation("diw")
    XCTAssertEqual(word.state.text, "-bar baz")

    let whole = VimEngine(text: "foo-bar baz", cursor: 1)
    try whole.executeNotation("diW")
    XCTAssertEqual(whole.state.text, " baz")
  }

  func testQuoteObjectIgnoresEscapedQuote() throws {
    let engine = VimEngine(text: #"let x = "a\"b""#, cursor: 10)
    try engine.executeNotation("di\"")
    XCTAssertEqual(engine.state.text, #"let x = """#)
  }

  func testTagTextObjectHandlesNestedTags() throws {
    let engine = VimEngine(text: "<a><b>text</b></a>", cursor: 7)
    try engine.executeNotation("dit")
    XCTAssertEqual(engine.state.text, "<a><b></b></a>")
  }

  func testMacroRecursionIsBounded() throws {
    let engine = VimEngine()
    engine.setMacro("a", actions: [.playMacro("a")])
    XCTAssertThrowsError(try engine.execute(.playMacro("a"))) { error in
      XCTAssertEqual(error as? VimError, .macroRecursionLimit)
    }
  }

  func testFindRepeatStaysOnCurrentLine() throws {
    let engine = VimEngine(text: "a-b-c\na-b", cursor: 0)
    try engine.executeNotation("f-;")
    XCTAssertEqual(engine.state.cursor, 3)
  }

  func testSubstituteDefaultsToCurrentLine() throws {
    let engine = VimEngine(text: "one one\none one", cursor: 0)
    try engine.execute(.ex("s/one/X/g"))
    XCTAssertEqual(engine.state.text, "X X\none one")
  }

  func testWholeDocumentSubstitute() throws {
    let engine = VimEngine(text: "one one\none", cursor: 0)
    try engine.execute(.ex("%s/one/X/g"))
    XCTAssertEqual(engine.state.text, "X X\nX")
  }

  func testUnicodeOffsetsRemainOnCharacterBoundaries() throws {
    let engine = VimEngine(text: "A👩‍💻B", cursor: 1)
    try engine.executeNotation("x")
    XCTAssertEqual(engine.state.text, "AB")
    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "A👩‍💻B")
  }

  func testCursorOnlySynchronizationPreservesUndoHistory() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    try engine.executeNotation("iX<Esc>")
    engine.synchronize(text: engine.state.text, cursor: 2)
    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "abc")
  }

  func testExternalSynchronizationIsUndoableAndPreservesMarks() throws {
    let engine = VimEngine(text: "abc", cursor: 1)
    try engine.executeNotation("ma")
    engine.synchronize(text: "Xabc", cursor: 2)
    try engine.executeNotation("`a")
    XCTAssertEqual(engine.state.cursor, 2)
    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "abc")
  }

  func testCountedInsertRepeatsCommittedText() throws {
    let engine = VimEngine(text: "tail", cursor: 0)
    try engine.executeNotation("3iX<Esc>")
    XCTAssertEqual(engine.state.text, "XXXtail")
    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "tail")
  }

  func testReplaceModeBackspaceRestoresOriginalText() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    try engine.executeNotation("RX<BS><Esc>")
    XCTAssertEqual(engine.state.text, "abc")
  }

  func testAdditionalLineAndColumnMotions() throws {
    let engine = VimEngine(text: "  one\n    two\nthree", cursor: 2)
    try engine.executeNotation("+")
    XCTAssertEqual(engine.state.cursor, 10)
    try engine.executeNotation("-")
    XCTAssertEqual(engine.state.cursor, 2)
    try engine.executeNotation("2|")
    XCTAssertEqual(engine.state.cursor, 1)
    try engine.executeNotation("2_")
    XCTAssertEqual(engine.state.cursor, 10)
  }

  func testPreviousWordEndMotions() throws {
    let engine = VimEngine(text: "one two-three four", cursor: 15)
    try engine.executeNotation("ge")
    XCTAssertEqual(engine.state.cursor, 12)
    try engine.executeNotation("gE")
    XCTAssertEqual(engine.state.cursor, 2)
  }

  func testRegexSearchAndSetOptions() throws {
    let engine = VimEngine(text: "Alpha\nbeta\nALPHA", cursor: 0)
    try engine.execute(.ex("set ignorecase smartcase"))
    try engine.execute(.search("alpha", forward: true))
    XCTAssertEqual(engine.state.cursor, 11)
    try engine.execute(.ex("set nowrapscan"))
    try engine.execute(.search("beta$", forward: true))
    XCTAssertEqual(engine.state.cursor, 11)
  }

  func testExRangesDeleteYankPutAndNormal() throws {
    let engine = VimEngine(text: "one\ntwo\nthree\n", cursor: 0)
    try engine.execute(.ex("2yank"))
    XCTAssertEqual(engine.register(.unnamed), "two\n")
    try engine.execute(.ex("3put"))
    XCTAssertEqual(engine.state.text, "one\ntwo\nthree\ntwo\n")
    try engine.execute(.ex("1delete"))
    XCTAssertEqual(engine.state.text, "two\nthree\ntwo\n")
    try engine.execute(.ex("normal ggx"))
    XCTAssertEqual(engine.state.text, "wo\nthree\ntwo\n")
  }

  func testMacroRetainsCountAndRegister() throws {
    let engine = VimEngine(text: "one two", cursor: 0)
    try engine.executeNotation("qad2wq")
    engine.synchronize(text: "one two three", cursor: 0)
    try engine.executeNotation("@a")
    XCTAssertEqual(engine.state.text, "three")
  }

  func testInsertControlOTemporarilyExecutesNormalCommand() throws {
    let engine = VimEngine(text: "abc", cursor: 2)
    try engine.executeNotation("iX<c-o>0Y<Esc>")
    XCTAssertEqual(engine.state.text, "YabXc")
    XCTAssertEqual(engine.state.mode, .normal)
    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "abc")
  }

  func testJumpListMovesBackwardAndForward() throws {
    let engine = VimEngine(text: "one\ntwo\nthree", cursor: 0)
    try engine.executeNotation("G")
    let lastLineCursor = engine.state.cursor
    XCTAssertGreaterThan(lastLineCursor, 0)
    try engine.executeNotation("<c-o>")
    XCTAssertEqual(engine.state.cursor, 0)
    try engine.executeNotation("<c-i>")
    XCTAssertEqual(engine.state.cursor, lastLineCursor)
  }

  func testChangeListNavigation() throws {
    let engine = VimEngine(text: "abc def", cursor: 0)
    try engine.executeNotation("x$x0")
    try engine.executeNotation("g;")
    XCTAssertGreaterThan(engine.state.cursor, 0)
    try engine.executeNotation("g;")
    XCTAssertEqual(engine.state.cursor, 0)
    try engine.executeNotation("g,")
    XCTAssertGreaterThan(engine.state.cursor, 0)
  }

  func testSpecialRegistersExposeInsertSearchAndCommandHistory() throws {
    let engine = VimEngine(text: "one two", cursor: 0)
    try engine.executeNotation("iX<Esc>")
    XCTAssertEqual(engine.register(.named(".")), "X")
    try engine.execute(.search("two", forward: true))
    XCTAssertEqual(engine.register(.named("/")), "two")
    _ = try engine.execute(.ex("set ignorecase"))
    XCTAssertEqual(engine.register(.named(":")), "set ignorecase")
  }

  func testExRelativeAndMarkedRanges() throws {
    let engine = VimEngine(text: "one\ntwo\nthree\nfour\n", cursor: 0)
    try engine.executeNotation("jma")
    _ = try engine.execute(.ex(".+1delete"))
    XCTAssertEqual(engine.state.text, "one\ntwo\nfour\n")
    _ = try engine.execute(.ex("'a,$yank"))
    XCTAssertEqual(engine.register(.unnamed), "two\nfour\n")
  }

  func testExCopyAndMove() throws {
    let copy = VimEngine(text: "one\ntwo\nthree\n", cursor: 0)
    _ = try copy.execute(.ex("1copy 3"))
    XCTAssertEqual(copy.state.text, "one\ntwo\nthree\none\n")

    let move = VimEngine(text: "one\ntwo\nthree\n", cursor: 0)
    _ = try move.execute(.ex("1move 3"))
    XCTAssertEqual(move.state.text, "two\nthree\none\n")
  }

  func testRangedSubstituteAndVimReplacementTokens() throws {
    let engine = VimEngine(text: "ab12\ncd34\nef56\n", cursor: 0)
    _ = try engine.execute(.ex("2,3s/([a-z]+)([0-9]+)/\\2-\\1-&/"))
    XCTAssertEqual(engine.state.text, "ab12\n34-cd-cd34\n56-ef-ef56\n")
    XCTAssertEqual(engine.register(.named("/")), "([a-z]+)([0-9]+)")
  }

  func testConcurrentAccessMaintainsValidUTF16State() async {
    let text = String(repeating: "alpha 👩‍💻 beta\n", count: 200)
    let engine = VimEngine(text: text, cursor: 0)

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<200 {
        group.addTask {
          if index.isMultiple(of: 2) {
            _ = try? engine.executeNotation("j")
          } else {
            _ = try? engine.executeNotation("k")
          }
          _ = engine.state
          _ = engine.register(.unnamed)
        }
      }
    }

    let state = engine.state
    XCTAssertGreaterThanOrEqual(state.cursor, 0)
    XCTAssertLessThanOrEqual(state.cursor, (state.text as NSString).length)
    let utf16Index = state.text.utf16.index(state.text.utf16.startIndex, offsetBy: state.cursor)
    XCTAssertNotNil(String.Index(utf16Index, within: state.text))
  }

  func testLargeBufferMotionSmoke() throws {
    let text = String(repeating: "0123456789 abcdefghijklmnopqrstuvwxyz\n", count: 25_000)
    let engine = VimEngine(text: text, cursor: 0)

    for _ in 0..<2_000 {
      try engine.execute(.move(.down))
    }
    for _ in 0..<1_000 {
      try engine.execute(.move(.wordForward))
    }

    let state = engine.state
    XCTAssertEqual(state.text, text)
    XCTAssertGreaterThan(state.cursor, 0)
    XCTAssertLessThanOrEqual(state.cursor, (text as NSString).length)
  }
}
