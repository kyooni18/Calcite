@_spi(Calcite) @testable import EditorVim
import XCTest

final class VimStage4Tests: XCTestCase {
  func testUndoTreePreservesAlternateBranchAndPrefersNewestBranch() throws {
    let engine = VimEngine(text: "x", cursor: 0)
    try engine.executeNotation("iA<Esc>")
    try engine.executeNotation("aB<Esc>")
    XCTAssertEqual(engine.state.text, "ABx")

    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "Ax")
    try engine.executeNotation("aC<Esc>")
    XCTAssertEqual(engine.state.text, "ACx")
    XCTAssertEqual(engine.undoTree.current.parent?.children.count, 2)

    try engine.executeNotation("u")
    try engine.executeNotation("<c-r>")
    XCTAssertEqual(engine.state.text, "ACx")
  }

  func testDotRepeatCapturesResolvedPasteValue() throws {
    let engine = VimEngine(text: "ab", cursor: 0)
    engine.setRegister(.named("a"), text: "X")
    try engine.executeNotation("\"ap")
    engine.setRegister(.named("a"), text: "Y")
    try engine.executeNotation("l.")
    XCTAssertEqual(engine.state.text, "aXbX")
  }

  func testMacroCapturesResolvedPasteValue() throws {
    let engine = VimEngine(text: "ab", cursor: 0)
    engine.setRegister(.named("a"), text: "X")
    try engine.executeNotation("qa\"apq")
    engine.setRegister(.named("a"), text: "Y")
    try engine.executeNotation("l@a")
    XCTAssertEqual(engine.state.text, "aXbX")
  }

  func testVimRegexWordBoundariesCaseOverrideAndVeryNomagic() throws {
    let word = VimEngine(text: "foobar foo", cursor: 0)
    try word.execute(.search("\\<foo\\>", forward: true))
    XCTAssertEqual(word.state.cursor, 7)

    let literal = VimEngine(text: "fooXbar foo.bar", cursor: 0)
    try literal.execute(.search("\\Vfoo.bar", forward: true))
    XCTAssertEqual(literal.state.cursor, 8)

    let caseInsensitive = VimEngine(text: "zero FOO", cursor: 0)
    try caseInsensitive.execute(.search("foo\\c", forward: true))
    XCTAssertEqual(caseInsensitive.state.cursor, 5)
  }

  func testSubstituteProducesDiscreteIncrementalEdits() throws {
    let engine = VimEngine(text: "a a\na", cursor: 0)
    try engine.execute(.ex("%s/a/A/g"))
    XCTAssertEqual(engine.state.text, "A A\nA")
    XCTAssertEqual(engine.completedExecutionEdits.count, 3)

    var reconstructed = "a a\na"
    for edit in engine.completedExecutionEdits {
      reconstructed = (reconstructed as NSString).replacingCharacters(
        in: NSRange(location: edit.location, length: edit.removedUTF16Count),
        with: edit.insertedText
      )
    }
    XCTAssertEqual(reconstructed, engine.state.text)
  }

  func testChainedExCommandsAreOneUndoUnit() throws {
    let engine = VimEngine(text: "b\na\n", cursor: 0)
    try engine.execute(.ex("%sort|%s/a/A/g"))
    XCTAssertEqual(engine.state.text, "A\nb\n")
    XCTAssertEqual(engine.undoStack.count, 1)
    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "b\na\n")
  }

  func testGlobalAndVGlobalExecuteNestedCommands() throws {
    let matching = VimEngine(text: "foo\nbar\nfoo two\n", cursor: 0)
    try matching.execute(.ex("g/foo/delete"))
    XCTAssertEqual(matching.state.text, "bar\n")

    let inverse = VimEngine(text: "foo\nbar\nfoo two\n", cursor: 0)
    try inverse.execute(.ex("v/foo/delete"))
    XCTAssertEqual(inverse.state.text, "foo\nfoo two\n")
  }

  func testRangedNormalAndSort() throws {
    let normal = VimEngine(text: "one\ntwo\nthree\n", cursor: 0)
    try normal.execute(.ex("1,2normal A!<Esc>"))
    XCTAssertEqual(normal.state.text, "one!\ntwo!\nthree\n")
    try normal.executeNotation("u")
    XCTAssertEqual(normal.state.text, "one\ntwo\nthree\n")

    let sorted = VimEngine(text: "10\n2\n1\n", cursor: 0)
    try sorted.execute(.ex("%sort n"))
    XCTAssertEqual(sorted.state.text, "1\n2\n10\n")
  }

  func testVisualEndpointSwapAndReplacementPaste() throws {
    let swapped = VimEngine(text: "abcd", cursor: 0)
    try swapped.executeNotation("vllo")
    XCTAssertEqual(swapped.visualAnchor, 2)
    XCTAssertEqual(swapped.state.cursor, 0)
    XCTAssertEqual(swapped.state.selection, VimSelection(0, 3))

    let pasted = VimEngine(text: "abcd", cursor: 0)
    pasted.setRegister(.named("a"), text: "X")
    try pasted.executeNotation("vll\"ap")
    XCTAssertEqual(pasted.state.text, "Xd")
    XCTAssertEqual(pasted.register(.named("a")), "X")
    XCTAssertEqual(pasted.register(.unnamed), "abc")
  }

  func testVisualCommandPromptStartsWithVisualRange() throws {
    let controller = VimKeymapController(engine: VimEngine(text: "one\ntwo\n", cursor: 0))
    _ = try controller.handle(token: "V")
    _ = try controller.handle(token: "j")
    let result = try controller.handle(token: ":")
    XCTAssertTrue(result.awaitingMoreInput)
    XCTAssertEqual(controller.prompt, ":'<,'>")
  }

  func testRepeatSubstituteAndSearchAddress() throws {
    let engine = VimEngine(text: "one\ntwo one\nthree one\n", cursor: 0)
    try engine.execute(.ex("2s/one/X/"))
    try engine.execute(.ex("3&"))
    XCTAssertEqual(engine.state.text, "one\ntwo X\nthree X\n")

    try engine.execute(.ex("/two/delete"))
    XCTAssertEqual(engine.state.text, "one\nthree X\n")
  }
  func testViewportMotionsAndPageCountsUseProvidedContext() throws {
    let text = (1...30).map { "line\($0)" }.joined(separator: "\n")
    let engine = VimEngine(text: text, cursor: 0)
    let top = engine.lineOffset(10)
    let bottom = engine.lineEndIncludingNewline(at: engine.lineOffset(19))
    engine.updateViewportContext(visibleUTF16Range: top..<bottom)

    try engine.executeNotation("H")
    XCTAssertEqual(engine.currentLineNumber(), 10)
    try engine.executeNotation("M")
    XCTAssertEqual(engine.currentLineNumber(), 14)
    try engine.executeNotation("L")
    XCTAssertEqual(engine.currentLineNumber(), 19)

    try engine.executeNotation("10gg<c-f>")
    XCTAssertEqual(engine.currentLineNumber(), 20)
    try engine.executeNotation("<c-u>")
    XCTAssertEqual(engine.currentLineNumber(), 15)
  }

  func testMappedCommandProducesOneBoundedExactEditBatch() throws {
    let engine = VimEngine(text: "x", cursor: 0)
    let controller = VimKeymapController(
      engine: engine,
      mappings: [VimKeyMapping(sequence: "jj", command: "iAB<Esc>")]
    )
    _ = try controller.handle(token: "j")
    let result = try controller.handle(token: "j")
    XCTAssertEqual(result.execution?.state.text, "ABx")
    let edits = engine.consumeCompletedEdits()
    XCTAssertFalse(edits.isEmpty)
    XCTAssertEqual(
      edits.reduce("x") { current, edit in
        (current as NSString).replacingCharacters(
          in: NSRange(location: edit.range.lowerBound, length: edit.range.count),
          with: edit.replacement
        )
      }, "ABx")
    XCTAssertTrue(engine.consumeCompletedEdits().isEmpty)
  }

}
