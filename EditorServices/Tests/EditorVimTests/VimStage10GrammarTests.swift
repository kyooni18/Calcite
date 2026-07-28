import EditorVim
import XCTest

final class VimStage10GrammarTests: XCTestCase {
  func testCountMultiplicationAndAdditionalOperatorMotions() throws {
    let multiplied = VimEngine(text: "one two three four five six seven\n", cursor: 0)
    try multiplied.executeNotation("2d3w")
    XCTAssertEqual(multiplied.state.text, "seven\n")

    let adjacent = VimEngine(text: "one\ntwo\nthree\n", cursor: 0)
    try adjacent.executeNotation("d+")
    XCTAssertEqual(adjacent.state.text, "three\n")

    let column = VimEngine(text: "abcdef\n", cursor: 0)
    try column.executeNotation("d4|")
    XCTAssertEqual(column.state.text, "def\n")
  }

  func testSentenceAndParagraphMotionsWorkWithOperators() throws {
    let sentence = VimEngine(
      text: "one two. Three four.\n\nPara two\nline\n",
      cursor: 0
    )
    try sentence.executeNotation("d)")
    XCTAssertEqual(sentence.state.text, "Three four.\n\nPara two\nline\n")

    let paragraph = VimEngine(text: "one\ntwo\n\nthree\nfour\n", cursor: 0)
    try paragraph.executeNotation("d}")
    XCTAssertEqual(paragraph.state.text, "\nthree\nfour\n")
  }

  func testMarkMotionsWorkWithOperators() throws {
    let characterwise = VimEngine(text: "zero\none\ntwo\nthree\n", cursor: 5)
    try characterwise.executeNotation("majjd`a")
    XCTAssertEqual(characterwise.state.text, "zero\nthree\n")

    let linewise = VimEngine(text: "zero\none\ntwo\nthree\n", cursor: 5)
    try linewise.executeNotation("majjd'a")
    XCTAssertEqual(linewise.state.text, "zero\n")
  }

  func testRepeatFindAndSearchMotionsWorkWithOperators() throws {
    let repeatedFind = VimEngine(text: "a x b x c\n", cursor: 0)
    try repeatedFind.executeNotation("fxd;")
    XCTAssertEqual(repeatedFind.state.text, "a  c\n")

    let reverseFind = VimEngine(text: "a x b x c\n", cursor: 0)
    try reverseFind.executeNotation("2fxd,")
    XCTAssertEqual(reverseFind.state.text, "a x c\n")

    let search = VimEngine(text: "alpha beta gamma beta delta\n", cursor: 0)
    try search.executeNotation("d/beta<CR>")
    XCTAssertEqual(search.state.text, "beta gamma beta delta\n")

    let repeatedSearch = VimEngine(text: "alpha beta gamma beta delta\n", cursor: 0)
    try repeatedSearch.executeNotation("/beta<CR>0dn")
    XCTAssertEqual(repeatedSearch.state.text, "beta gamma beta delta\n")
  }

  func testForcedCharacterLineAndBlockMotionTypes() throws {
    let characterwise = VimEngine(text: "abc def\nghi jkl\n", cursor: 4)
    try characterwise.executeNotation("dvj")
    XCTAssertEqual(characterwise.state.text, "abc jkl\n")

    let linewise = VimEngine(text: "abc def\nghi jkl\n", cursor: 4)
    try linewise.executeNotation("dVw")
    XCTAssertEqual(linewise.state.text, "ghi jkl\n")

    let blockwise = VimEngine(text: "abc\ndef\nghi\n", cursor: 1)
    try blockwise.executeNotation("d<C-V>j")
    XCTAssertEqual(blockwise.state.text, "ac\ndf\nghi\n")
  }

  func testGQAndRot13AreRealOperators() throws {
    let object = VimEngine(text: "one two\n", cursor: 0)
    try object.executeNotation("g?iw")
    XCTAssertEqual(object.state.text, "bar two\n")

    let line = VimEngine(text: "one two\n", cursor: 0)
    try line.executeNotation("g??")
    XCTAssertEqual(line.state.text, "bar gjb\n")

    let format = VimEngine(text: "one two\nthree four\n", cursor: 0)
    try format.executeNotation("gqap")
    XCTAssertEqual(format.state.mode, .normal)
    XCTAssertEqual(format.state.text, "one two three four\n")

    let wrapped = VimEngine(text: "one two three four\n", cursor: 0)
    try wrapped.execute(.ex("set tw=9"))
    try wrapped.executeNotation("gqq")
    XCTAssertEqual(wrapped.state.text, "one two\nthree\nfour\n")
  }

  func testCountedAndNestedTextObjects() throws {
    let aroundWords = VimEngine(text: "one two three four\n", cursor: 0)
    try aroundWords.executeNotation("d2aw")
    XCTAssertEqual(aroundWords.state.text, "three four\n")

    let visualWords = VimEngine(text: "one two three four\n", cursor: 0)
    try visualWords.executeNotation("v3iwx")
    XCTAssertEqual(visualWords.state.text, " three four\n")

    let nested = VimEngine(text: "a (b (c) d) e\n", cursor: 6)
    try nested.executeNotation("d2i(")
    XCTAssertEqual(nested.state.text, "a () e\n")
  }

  func testFailedParsedMotionsDoNotMutateOrCreateUndoEntry() throws {
    let engine = VimEngine(text: "abc\n", cursor: 1)
    engine.setRegister(.unnamed, text: "preserved")
    try engine.executeNotation("d'z")
    XCTAssertEqual(engine.state.text, "abc\n")
    XCTAssertEqual(engine.state.cursor, 1)
    XCTAssertEqual(engine.register(.unnamed), "preserved")

    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "abc\n")
  }
  func testIsKeywordControlsWordMotionsAndTextObjects() throws {
    let defaultWord = VimEngine(text: "foo-bar baz\n", cursor: 0)
    try defaultWord.executeNotation("diw")
    XCTAssertEqual(defaultWord.state.text, "-bar baz\n")

    let configured = VimEngine(text: "foo-bar baz\n", cursor: 0)
    try configured.execute(.ex("set iskeyword+=-"))
    try configured.executeNotation("diw")
    XCTAssertEqual(configured.state.text, " baz\n")

    let reset = VimEngine(text: "foo-bar baz\n", cursor: 0)
    try reset.execute(.ex("set isk+=- isk&"))
    try reset.executeNotation("diw")
    XCTAssertEqual(reset.state.text, "-bar baz\n")
  }

  func testNewParsedCommandsPreserveDotRepeatAndMacroSemantics() throws {
    let repeatedSearch = VimEngine(
      text: "alpha beta gamma beta delta\n",
      cursor: 0
    )
    try repeatedSearch.executeNotation("d/beta<CR>.")
    XCTAssertEqual(repeatedSearch.state.text, "beta delta\n")

    let sentenceMacro = VimEngine(text: "One. Two. Three.\n", cursor: 0)
    try sentenceMacro.executeNotation("qad)q@a")
    XCTAssertEqual(sentenceMacro.state.text, "Three.\n")
  }

}
