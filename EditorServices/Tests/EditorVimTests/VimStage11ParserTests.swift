@_spi(Calcite) @testable import EditorVim
import XCTest

final class VimStage11ParserTests: XCTestCase {
  func testParserProducesNormalizedOperatorCommands() throws {
    XCTAssertEqual(
      try parse("\"ad2w"),
      .operation(
        .delete,
        motion: .standard(.wordForward),
        count: 2,
        register: .named("a"),
        forcedKind: nil
      )
    )
    XCTAssertEqual(
      try parse("2d3w"),
      .operation(
        .delete,
        motion: .standard(.wordForward),
        count: 6,
        register: .unnamed,
        forcedKind: nil
      )
    )
    XCTAssertEqual(
      try parse("d<C-V>j"),
      .operation(
        .delete,
        motion: .standard(.down),
        count: 1,
        register: .unnamed,
        forcedKind: .blockwise
      )
    )
    XCTAssertEqual(
      try parse("dfx"),
      .operation(
        .delete,
        motion: .standard(.findForward("x")),
        count: 1,
        register: .unnamed,
        forcedKind: nil
      )
    )
    XCTAssertEqual(
      try parse("d/foo<CR>"),
      .operation(
        .delete,
        motion: .search("foo", forward: true),
        count: 1,
        register: .unnamed,
        forcedKind: nil
      )
    )
  }

  func testParserProducesCaseAndVisualTextObjectCommands() throws {
    XCTAssertEqual(
      try parse("gUiw"),
      .operation(
        .uppercase,
        motion: .textObject(.word, inner: true),
        count: 1,
        register: .unnamed,
        forcedKind: nil
      )
    )

    var parser = VimCommandParser()
    XCTAssertEqual(try parser.consume("2", mode: .visualCharacter), .awaitingMoreInput)
    XCTAssertEqual(try parser.consume("a", mode: .visualCharacter), .awaitingMoreInput)
    XCTAssertEqual(
      try parser.consume("w", mode: .visualCharacter),
      .command(.motion(.textObject(.word, inner: false), count: 2))
    )
    XCTAssertTrue(parser.isAtCommandBoundary)
  }

  func testEscapeAtomicallyCancelsEveryIncompleteState() throws {
    let prefixes = ["3d", "\"ad", "dg", "df", "d/", "gU", "2a"]
    for prefix in prefixes {
      var parser = VimCommandParser()
      for token in VimCommandParser.tokens(in: prefix) {
        _ = try parser.consume(token, mode: prefix == "2a" ? .visualCharacter : .normal)
      }
      XCTAssertFalse(parser.isAtCommandBoundary, prefix)
      XCTAssertEqual(try parser.consume("<Esc>", mode: .normal), .cancelled, prefix)
      XCTAssertTrue(parser.isAtCommandBoundary, prefix)
    }
  }

  func testRandomTokenStreamsAlwaysResetOnEscape() throws {
    let tokens = ["d", "c", "y", "g", "i", "a", "f", "/", "?", "1", "9", "w", "j", "x"]
    var seed: UInt64 = 0xC0FFEE
    for _ in 0..<500 {
      var parser = VimCommandParser()
      for _ in 0..<20 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let token = tokens[Int(seed % UInt64(tokens.count))]
        do {
          _ = try parser.consume(token, mode: .normal)
        } catch {
          // Invalid continuations are allowed, but must remain cancellable.
        }
      }
      _ = try parser.consume("<Esc>", mode: .normal)
      XCTAssertTrue(parser.isAtCommandBoundary)
    }
  }

  func testPercentScansCurrentLineAndCountJumpsByPercentage() throws {
    let pair = VimEngine(text: "abc (de) x\n", cursor: 0)
    try pair.executeNotation("%")
    XCTAssertEqual(pair.state.cursor, 7)

    let delete = VimEngine(text: "abc (de) x\n", cursor: 0)
    try delete.executeNotation("d%")
    XCTAssertEqual(delete.state.text, " x\n")

    let percentage = VimEngine(
      text: (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n",
      cursor: 0
    )
    try percentage.executeNotation("50%")
    XCTAssertEqual(percentage.state.cursor, "line1\nline2\nline3\nline4\n".utf16.count)
  }

  func testViewportLastNonBlankAndWordSearchMotionsWorkWithOperators() throws {
    let lastNonBlank = VimEngine(text: "abc   \n", cursor: 0)
    try lastNonBlank.executeNotation("dg_")
    XCTAssertEqual(lastNonBlank.state.text, "   \n")

    let viewport = VimEngine(text: "one\ntwo\nthree\nfour\nfive\n", cursor: 8)
    viewport.updateViewport(visibleUTF16Range: 4..<19)
    try viewport.executeNotation("dH")
    XCTAssertEqual(viewport.state.text, "one\nfour\nfive\n")

    let wordSearch = VimEngine(text: "foo xx foo yy\n", cursor: 0)
    try wordSearch.executeNotation("d*")
    XCTAssertEqual(wordSearch.state.text, "foo yy\n")

    let nonBoundary = VimEngine(text: "foo xx foobar yy\n", cursor: 0)
    try nonBoundary.executeNotation("dg*")
    XCTAssertEqual(nonBoundary.state.text, "foobar yy\n")
  }

  func testGnSelectsAndDeletesOnlyTheSearchMatch() throws {
    let select = VimEngine(text: "foo xx foo yy\n", cursor: 0)
    try select.execute(.search("foo", forward: true))
    select.synchronize(text: select.state.text, cursor: 0)
    try select.executeNotation("gn")
    XCTAssertEqual(select.state.mode, .visualCharacter)
    XCTAssertEqual(select.state.selection, VimSelection(0, 3))

    let delete = VimEngine(text: "foo xx foo yy\n", cursor: 0)
    try delete.execute(.search("foo", forward: true))
    delete.synchronize(text: delete.state.text, cursor: 0)
    try delete.executeNotation("dgn")
    XCTAssertEqual(delete.state.text, " xx foo yy\n")
  }

  func testKeymapRoutesGQuestionThroughOperatorParser() throws {
    let engine = VimEngine(text: "abc def\n", cursor: 0)
    let controller = VimKeymapController(engine: engine)

    for token in ["g", "?", "i", "w"] {
      _ = try controller.handle(token: token)
    }

    XCTAssertNil(controller.prompt)
    XCTAssertEqual(engine.state.text, "nop def\n")
  }

  func testKeymapRoutesOperatorSearchWithoutOpeningStandalonePrompt() throws {
    let engine = VimEngine(text: "one two three\n", cursor: 0)
    let controller = VimKeymapController(engine: engine)

    for token in ["d", "/", "t", "w", "o", "<CR>"] {
      _ = try controller.handle(token: token)
    }

    XCTAssertNil(controller.prompt)
    XCTAssertEqual(engine.state.text, "two three\n")
  }

  func testTemporaryNormalWaitsForOneCompleteSemanticCommand() throws {
    let engine = VimEngine(text: "one two\n", cursor: 0)
    try engine.executeNotation("i<C-O>dwX<Esc>")
    XCTAssertEqual(engine.state.text, "Xtwo\n")
    XCTAssertEqual(engine.state.mode, .normal)
  }

  func testCancelledAndFailedCommandsDoNotBecomeRepeatOrMacroEntries() throws {
    let engine = VimEngine(text: "abc\n", cursor: 0)
    try engine.executeNotation("df<Esc>.")
    XCTAssertEqual(engine.state.text, "abc\n")

    try engine.executeNotation("qadf<Esc>q@a")
    XCTAssertEqual(engine.state.text, "abc\n")
  }

  private func parse(_ notation: String) throws -> VimSemanticCommand? {
    var parser = VimCommandParser()
    var command: VimSemanticCommand?
    for token in VimCommandParser.tokens(in: notation) {
      if case .command(let value) = try parser.consume(token, mode: .normal) {
        command = value
      }
    }
    XCTAssertTrue(parser.isAtCommandBoundary, notation)
    return command
  }
}
