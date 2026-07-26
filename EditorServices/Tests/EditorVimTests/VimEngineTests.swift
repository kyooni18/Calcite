import XCTest

@testable import EditorVim

final class VimEngineTests: XCTestCase {
  func testLineEndStopsOnLastCharacterNotNewline() throws {
    let engine = VimEngine(text: "abc\ndef", cursor: 0)
    try engine.execute(.notation("$"))
    XCTAssertEqual(engine.state.cursor, 2)
  }

  func testWordDeleteAndEndSemantics() throws {
    let engine = VimEngine(text: "one two", cursor: 0)
    try engine.execute(.notation("dw"))
    XCTAssertEqual(engine.state.text, "two")
    XCTAssertEqual(engine.register(.unnamed), "one ")

    engine.synchronize(text: "one two", cursor: 0)
    try engine.execute(.notation("de"))
    XCTAssertEqual(engine.state.text, " two")
  }

  func testBackwardWordDelete() throws {
    let engine = VimEngine(text: "one two", cursor: 4)
    try engine.execute(.notation("db"))
    XCTAssertEqual(engine.state.text, "two")
  }

  func testBigWordTreatsPunctuationAsPartOfWord() throws {
    let engine = VimEngine(text: "one.two three", cursor: 0)
    try engine.execute(.notation("W"))
    XCTAssertEqual(engine.state.cursor, 8)
  }

  func testVisualSelectionPreservesAnchorWhenMovingBackward() throws {
    let engine = VimEngine(text: "abcdef", cursor: 3)
    try engine.execute(.notation("vhh"))
    let selection = try XCTUnwrap(engine.state.selection)
    XCTAssertEqual(selection.anchor, 3)
    XCTAssertEqual(selection.head, 1)
    XCTAssertEqual(selection.ranges, [VimSelectionRange(1, 4)])
  }

  func testVisualLineYankIsLinewise() throws {
    let engine = VimEngine(text: "one\ntwo\nthree", cursor: 0)
    try engine.execute(.notation("Vjy"))
    XCTAssertEqual(engine.registerValue(.unnamed).kind, .linewise)
    XCTAssertEqual(engine.register(.unnamed), "one\ntwo\n")
    XCTAssertEqual(engine.state.text, "one\ntwo\nthree")
    XCTAssertEqual(engine.state.mode, .normal)
  }

  func testVisualBlockDeleteTouchesEachLine() throws {
    let engine = VimEngine(text: "abcd\nefgh\nijkl", cursor: 1)
    try engine.execute(.notation("<C-v>jlx"))
    XCTAssertEqual(engine.state.text, "ad\neh\nijkl")
    XCTAssertEqual(engine.registerValue(.unnamed).kind, .blockwise)
    XCTAssertEqual(engine.register(.unnamed), "bc\nfg")
  }

  func testNamedRegisterAppendAndBlackHole() throws {
    let engine = VimEngine(text: "one two", cursor: 0)
    try engine.execute(.notation("\"adw"))
    engine.synchronize(text: "three four", cursor: 0)
    try engine.execute(.notation("\"Adw"))
    XCTAssertEqual(engine.register(.named("a")), "one three ")

    let unnamed = engine.register(.unnamed)
    engine.synchronize(text: "discard me", cursor: 0)
    try engine.execute(.notation("\"_dw"))
    XCTAssertEqual(engine.register(.unnamed), unnamed)
  }

  func testNumberedRegistersRotateForLineDeletes() throws {
    let engine = VimEngine(text: "one\ntwo\nthree\n", cursor: 0)
    try engine.execute(.notation("dd"))
    XCTAssertEqual(engine.register(.numbered(1)), "one\n")
    try engine.execute(.notation("dd"))
    XCTAssertEqual(engine.register(.numbered(1)), "two\n")
    XCTAssertEqual(engine.register(.numbered(2)), "one\n")
  }

  func testLinewisePasteUsesLineBoundaries() throws {
    let engine = VimEngine(text: "one\ntwo\n", cursor: 0)
    engine.setRegister(.unnamed, value: VimRegisterValue(text: "middle\n", kind: .linewise))
    try engine.execute(.notation("p"))
    XCTAssertEqual(engine.state.text, "one\nmiddle\ntwo\n")
    XCTAssertEqual(engine.state.cursor, 4)
  }

  func testInsertSessionIsSingleUndoUnit() throws {
    let engine = VimEngine(text: "tail", cursor: 0)
    try engine.execute(.notation("iabc<Esc>"))
    XCTAssertEqual(engine.state.text, "abctail")
    try engine.execute(.notation("u"))
    XCTAssertEqual(engine.state.text, "tail")
  }

  func testEmptyInsertDoesNotMoveCursorOrCreateUndo() throws {
    let engine = VimEngine(text: "abc", cursor: 1)
    try engine.execute(.notation("i<Esc>"))
    XCTAssertEqual(engine.state.cursor, 1)
    try engine.execute(.notation("u"))
    XCTAssertEqual(engine.state.text, "abc")
  }

  func testDotRepeatsCompleteInsertChange() throws {
    let engine = VimEngine(text: "ab", cursor: 0)
    try engine.execute(.notation("iX<Esc>l."))
    XCTAssertEqual(engine.state.text, "XXab")
  }

  func testOpenLineIsSingleUndoUnit() throws {
    let engine = VimEngine(text: "one\ntwo", cursor: 0)
    try engine.execute(.notation("ohello<Esc>"))
    XCTAssertEqual(engine.state.text, "one\nhello\ntwo")
    try engine.execute(.notation("u"))
    XCTAssertEqual(engine.state.text, "one\ntwo")
  }

  func testReplaceModeOverwritesCharacters() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    try engine.execute(.notation("Rxy<Esc>"))
    XCTAssertEqual(engine.state.text, "xyc")
  }

  func testVerticalMotionKeepsPreferredColumnAcrossShortLine() throws {
    let engine = VimEngine(text: "abcd\nx\nwxyz", cursor: 3)
    try engine.execute(.notation("jj"))
    XCTAssertEqual(engine.state.cursor, 10)
  }

  func testFindRepeatAndReverseRepeat() throws {
    let engine = VimEngine(text: "a-b-a-b", cursor: 0)
    try engine.execute(.notation("fb;"))
    XCTAssertEqual(engine.state.cursor, 6)
    try engine.execute(.notation(","))
    XCTAssertEqual(engine.state.cursor, 2)
  }

  func testSearchWrapsAndWordSearchUsesCurrentWord() throws {
    let engine = VimEngine(text: "one two one", cursor: 8)
    try engine.execute(.action(.search("one", forward: true)))
    XCTAssertEqual(engine.state.cursor, 0)
    try engine.execute(.notation("w*"))
    XCTAssertEqual(engine.state.cursor, 4)
  }

  func testNestedPairTextObjectChange() throws {
    let engine = VimEngine(text: "call((value))", cursor: 7)
    try engine.execute(.notation("ci(X<Esc>"))
    XCTAssertEqual(engine.state.text, "call((X))")
  }

  func testAroundWordIncludesTrailingWhitespace() throws {
    let engine = VimEngine(text: "one two", cursor: 1)
    try engine.execute(.notation("daw"))
    XCTAssertEqual(engine.state.text, "two")
  }

  func testCaseOperators() throws {
    let engine = VimEngine(text: "One TWO", cursor: 0)
    try engine.execute(.notation("guw"))
    XCTAssertEqual(engine.state.text, "one TWO")
    engine.synchronize(text: "one TWO", cursor: 0)
    try engine.execute(.notation("gUw"))
    XCTAssertEqual(engine.state.text, "ONE TWO")
    engine.synchronize(text: "Abc", cursor: 0)
    try engine.execute(.notation("g~w"))
    XCTAssertEqual(engine.state.text, "aBC")
  }

  func testMacroRecordsCountsAndCanRepeat() throws {
    let engine = VimEngine(text: "a", cursor: 0)
    try engine.execute(.notation("qaix<Esc>q"))
    try engine.execute(.notation("2@a"))
    XCTAssertEqual(engine.state.text, "xxxa")
  }

  func testMacroRecursionLimitIsEnforced() throws {
    let engine = VimEngine(text: "a")
    engine.macroRecursionLimit = 3
    engine.setMacro("a", actions: [.playMacro("a")])
    XCTAssertThrowsError(try engine.execute(.action(.playMacro("a")))) { error in
      XCTAssertEqual(error as? VimError, .macroRecursionLimit)
    }
  }

  func testCurrentLineSubstituteAndGlobalRangeSubstitute() throws {
    let engine = VimEngine(text: "one one\none one", cursor: 0)
    try engine.execute(.ex(":s/one/two/"))
    XCTAssertEqual(engine.state.text, "two one\none one")
    try engine.execute(.ex(":%s/one/three/g"))
    XCTAssertEqual(engine.state.text, "two three\nthree three")
  }

  func testExLineRangeDelete() throws {
    let engine = VimEngine(text: "one\ntwo\nthree\n", cursor: 0)
    try engine.execute(.ex(":2,3delete"))
    XCTAssertEqual(engine.state.text, "one\n")
    XCTAssertEqual(engine.registerValue(.unnamed).kind, .linewise)
  }

  func testCommandPromptChangesModeAndKeepsHistory() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "abc"))
    _ = try controller.handle(token: ":")
    XCTAssertEqual(controller.engine.state.mode, .commandLine)
    _ = try controller.handle(token: "w")
    let result = try controller.handle(token: "<CR>")
    XCTAssertEqual(result.execution?.hostRequests, [.write])
    XCTAssertEqual(controller.engine.state.mode, .normal)

    _ = try controller.handle(token: ":")
    _ = try controller.handle(token: "<Up>")
    XCTAssertEqual(controller.prompt, ":w")
  }

  func testInsertControlWordDeleteStaysInInsertMode() throws {
    let controller = VimKeymapController(engine: VimEngine(text: ""))
    for token in ["i", "o", "n", "e", " ", "t", "w", "o", "<C-w>"] {
      _ = try controller.handle(token: token)
    }
    XCTAssertEqual(controller.engine.state.text, "one ")
    XCTAssertEqual(controller.engine.state.mode, .insert)
  }

  func testUserMappingAndLeaderMapping() throws {
    let engine = VimEngine(text: "abc")
    let controller = VimKeymapController(
      engine: engine,
      mappings: [VimKeyMapping(sequence: "<leader>w", command: ":w")]
    )
    _ = try controller.handle(token: "\\")
    let result = try controller.handle(token: "w")
    XCTAssertEqual(result.execution?.hostRequests, [.write])
  }

  func testModeSpecificInsertMappingAndRecursiveMapping() throws {
    let controller = VimKeymapController(
      engine: VimEngine(text: ""),
      mappings: [
        VimKeyMapping(sequence: "jk", command: "<Esc>", modes: [.insert]),
        VimKeyMapping(sequence: "Q", command: "dd"),
      ]
    )
    _ = try controller.handle(token: "i")
    _ = try controller.handle(token: "a")
    _ = try controller.handle(token: "j")
    XCTAssertEqual(controller.engine.state.text, "a")
    _ = try controller.handle(token: "k")
    XCTAssertEqual(controller.engine.state.mode, .normal)

    controller.synchronize(text: "one\ntwo\n", cursor: 0)
    _ = try controller.handle(token: "Q")
    XCTAssertEqual(controller.engine.state.text, "two\n")
  }

  func testUnicodeOffsetsRemainOnCharacterBoundaries() throws {
    let engine = VimEngine(text: "a😀b", cursor: 0)
    try engine.execute(.notation("llx"))
    XCTAssertEqual(engine.state.text, "a😀")
    XCTAssertEqual(engine.state.cursor, 1)
  }

  func testMarksTrackInsertionsBeforeTheirPosition() throws {
    let engine = VimEngine(text: "one two", cursor: 4)
    try engine.execute(.notation("ma"))
    engine.synchronize(text: engine.state.text, cursor: 0)
    try engine.execute(.notation("iX<Esc>`a"))
    XCTAssertEqual(engine.state.cursor, 5)
  }

  func testDocumentAndParagraphMotions() throws {
    let engine = VimEngine(text: "one\n\ntwo\n\nthree", cursor: 10)
    try engine.execute(.notation("gg"))
    XCTAssertEqual(engine.state.cursor, 0)
    try engine.execute(.notation("G"))
    XCTAssertEqual(engine.state.cursor, 14)
    try engine.execute(.notation("{"))
    XCTAssertEqual(engine.state.cursor, 5)
  }

  func testHorizontalMotionsAndDeletesStayOnCurrentLine() throws {
    let engine = VimEngine(text: "ab\ncd", cursor: 1)
    try engine.execute(.notation("l"))
    XCTAssertEqual(engine.state.cursor, 1)
    try engine.execute(.notation("x"))
    XCTAssertEqual(engine.state.text, "a\ncd")
    try engine.execute(.notation("X"))
    XCTAssertEqual(engine.state.text, "a\ncd")
    try engine.execute(.notation("X"))
    XCTAssertEqual(engine.state.text, "a\ncd")
  }

  func testCountedLineEndAndExplicitG() throws {
    let engine = VimEngine(text: "one\ntwo\nthree", cursor: 0)
    try engine.execute(.notation("2$"))
    XCTAssertEqual(engine.state.cursor, 6)
    try engine.execute(.notation("1G"))
    XCTAssertEqual(engine.state.cursor, 0)
    try engine.execute(.notation("G"))
    XCTAssertEqual(engine.state.cursor, 12)
  }

  func testColumnZeroAndShortVisualBlockDoNotSelectLastCharacter() throws {
    let engine = VimEngine(text: "abcd\nx\nwxyz", cursor: 3)
    try engine.execute(.notation("j"))
    XCTAssertEqual(engine.state.cursor, 5)
    try engine.execute(.notation("<C-v>j"))
    let selection = try XCTUnwrap(engine.state.selection)
    XCTAssertEqual(selection.ranges[0], VimSelectionRange(5, 6))
    XCTAssertEqual(selection.ranges[1], VimSelectionRange(7, 8))

    engine.synchronize(text: "abcd\nx\nwxyz", cursor: 3)
    try engine.execute(.notation("<C-v>j"))
    XCTAssertEqual(engine.state.selection?.ranges[1], VimSelectionRange(6, 6))
  }

  func testBlockPastePadsShortLines() throws {
    let engine = VimEngine(text: "abcd\nx", cursor: 2)
    engine.setRegister(
      .unnamed,
      value: VimRegisterValue(text: "Q\nR", kind: .blockwise)
    )
    try engine.execute(.notation("p"))
    XCTAssertEqual(engine.state.text, "abcQd\nx  R")
  }

  func testVisualPasteReplacesSelectionUsingOriginalRegister() throws {
    let engine = VimEngine(text: "one two", cursor: 0)
    engine.setRegister(.unnamed, text: "X")
    try engine.execute(.notation("vep"))
    XCTAssertEqual(engine.state.text, "X two")
    XCTAssertEqual(engine.register(.unnamed), "one")
    XCTAssertEqual(engine.state.mode, .normal)
  }

  func testVisualReplaceAndJoin() throws {
    let engine = VimEngine(text: "ab\ncd", cursor: 0)
    try engine.execute(.notation("vlrX"))
    XCTAssertEqual(engine.state.text, "XX\ncd")

    engine.synchronize(text: "one\n  two\nthree", cursor: 0)
    try engine.execute(.notation("VjJ"))
    XCTAssertEqual(engine.state.text, "one two\nthree")
    XCTAssertEqual(engine.state.mode, .normal)
  }

  func testLinewiseChangePreservesIndentAndUndo() throws {
    let engine = VimEngine(text: "  one\n  two", cursor: 2)
    try engine.execute(.notation("ccX<Esc>"))
    XCTAssertEqual(engine.state.text, "  X\n  two")
    try engine.execute(.notation("u"))
    XCTAssertEqual(engine.state.text, "  one\n  two")
  }

  func testPasteCursorPlacementAndFinalLineSeparator() throws {
    let engine = VimEngine(text: "ab", cursor: 0)
    engine.setRegister(.unnamed, text: "XY")
    try engine.execute(.notation("p"))
    XCTAssertEqual(engine.state.text, "aXYb")
    XCTAssertEqual(engine.state.cursor, 2)

    engine.synchronize(text: "ab", cursor: 1)
    engine.setRegister(.unnamed, text: "XY")
    try engine.execute(.notation("P"))
    XCTAssertEqual(engine.state.text, "aXYb")
    XCTAssertEqual(engine.state.cursor, 1)

    engine.synchronize(text: "one", cursor: 0)
    engine.setRegister(.unnamed, value: VimRegisterValue(text: "two\n", kind: .linewise))
    try engine.execute(.notation("p"))
    XCTAssertEqual(engine.state.text, "one\ntwo\n")
    XCTAssertEqual(engine.state.cursor, 4)
  }

  func testReplaceCharacterDoesNotCrossLineOrExtendPastEnd() throws {
    let engine = VimEngine(text: "ab\ncd", cursor: 1)
    try engine.execute(.notation("2rX"))
    XCTAssertEqual(engine.state.text, "ab\ncd")
    try engine.execute(.notation("rX"))
    XCTAssertEqual(engine.state.text, "aX\ncd")
  }

  func testInsertSpecialKeysRemainInsideEngineTransaction() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "ab\ncd", cursor: 0))
    for token in ["i", "X", "<End>", "Y", "<Down>", "<Home>", "Z", "<Esc>"] {
      _ = try controller.handle(token: token)
    }
    XCTAssertEqual(controller.engine.state.text, "XabY\nZcd")
    try controller.engine.execute(.notation("u"))
    XCTAssertEqual(controller.engine.state.text, "ab\ncd")
  }

  func testWindowTabAndDiagnosticCommandsEmitHostRequests() throws {
    let engine = VimEngine(text: "abc")
    XCTAssertEqual(
      try engine.execute(.notation("<C-w>h")).hostRequests,
      [.custom("section-left")]
    )
    XCTAssertEqual(try engine.execute(.notation("gt")).hostRequests, [.nextTab])
    XCTAssertEqual(try engine.execute(.notation("gT")).hostRequests, [.previousTab])
    XCTAssertEqual(
      try engine.execute(.notation("]d")).hostRequests,
      [.custom("next-diagnostic")]
    )
  }

  func testNumberIncrementSupportsDecimalAndHex() throws {
    let engine = VimEngine(text: "value 009 and 0x0F", cursor: 0)
    try engine.execute(.notation("<C-a>"))
    XCTAssertEqual(engine.state.text, "value 010 and 0x0F")
    engine.synchronize(text: engine.state.text, cursor: 14)
    try engine.execute(.notation("2<C-x>"))
    XCTAssertEqual(engine.state.text, "value 010 and 0x0D")
  }

  func testPipeDelimitedSubstituteCanBeChained() throws {
    let engine = VimEngine(text: "one one", cursor: 0)
    let result = try engine.execute(.ex(":s|one|two|g|w"))
    XCTAssertEqual(engine.state.text, "two two")
    XCTAssertEqual(result.hostRequests, [.write])
  }
}
