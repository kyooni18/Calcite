@_spi(Calcite) import EditorVim
import XCTest

final class VimStage7VisualBlockTests: XCTestCase {
  func testControlVCreatesProjectedBlockRanges() throws {
    let engine = VimEngine(text: "abcd\nefgh\nijkl", cursor: 1)
    let controller = VimKeymapController(engine: engine)

    _ = try controller.handle(token: "<C-V>")
    _ = try controller.handle(token: "j")
    _ = try controller.handle(token: "l")

    let visual = try XCTUnwrap(controller.interactionSnapshot.visualSelection)
    XCTAssertEqual(visual.shape, .block)
    XCTAssertEqual(visual.width, 2)
    XCTAssertEqual(visual.height, 2)
    XCTAssertEqual(visual.projectedRanges, [1..<3, 6..<8])
  }

  func testVisualBlockDeleteIsOneUndoTransaction() throws {
    let engine = VimEngine(text: "abcd\nefgh\nijkl", cursor: 1)
    try selectTwoByTwoBlock(engine)
    _ = try engine.executeNotation("d")

    XCTAssertEqual(engine.state.text, "ad\neh\nijkl")
    _ = try engine.execute(.undo)
    XCTAssertEqual(engine.state.text, "abcd\nefgh\nijkl")
  }

  func testVisualBlockYankUsesBlockwisePaste() throws {
    let engine = VimEngine(text: "abcd\nefgh\nijkl", cursor: 1)
    try selectTwoByTwoBlock(engine)
    _ = try engine.executeNotation("y")
    XCTAssertEqual(engine.register(.unnamed), "bc\nfg")

    _ = try engine.executeNotation("p")
    XCTAssertEqual(engine.state.text, "abbccd\neffggh\nijkl")
  }

  func testVisualBlockChangeReplicatesCommittedHangul() throws {
    let engine = VimEngine(text: "abcd\nefgh", cursor: 1)
    let controller = VimKeymapController(engine: engine)
    _ = try controller.handle(token: "<C-V>")
    _ = try controller.handle(token: "j")
    _ = try controller.handle(token: "l")
    _ = try controller.handle(token: "c")
    _ = try controller.handle(event: .compositionStarted)
    _ = try controller.handle(event: .compositionUpdated("한", selectedRange: 1..<1))
    _ = try controller.handle(event: .compositionCommitted("한"))
    _ = try controller.handle(token: "<Esc>")

    XCTAssertEqual(engine.state.text, "a한d\ne한h")
    _ = try engine.execute(.undo)
    XCTAssertEqual(engine.state.text, "abcd\nefgh")
  }

  func testVisualBlockInsertBeforeReplicatesText() throws {
    let engine = VimEngine(text: "abcd\nefgh", cursor: 1)
    _ = try engine.executeNotation("<C-V>jI!<Esc>")
    XCTAssertEqual(engine.state.text, "a!bcd\ne!fgh")
  }

  func testVisualBlockAppendReplicatesText() throws {
    let engine = VimEngine(text: "abcd\nefgh", cursor: 1)
    _ = try engine.executeNotation("<C-V>jlA!<Esc>")
    XCTAssertEqual(engine.state.text, "abc!d\nefg!h")
  }

  func testVisualBlockReplacePreservesGraphemeBoundaries() throws {
    let engine = VimEngine(text: "a한b\nc글d", cursor: 1)
    _ = try engine.executeNotation("<C-V>jr🙂")
    XCTAssertEqual(engine.state.text, "a🙂b\nc🙂d")
  }

  func testVisualBlockCaseConversion() throws {
    let engine = VimEngine(text: "abCD\nefGH", cursor: 0)
    _ = try engine.executeNotation("<C-V>jlU")
    XCTAssertEqual(engine.state.text, "ABCD\nEFGH")
  }

  func testVisualBlockHandlesRaggedLines() throws {
    let engine = VimEngine(text: "abcd\nx\nijkl", cursor: 2)
    _ = try engine.executeNotation("<C-V>jjl")
    let ranges = try XCTUnwrap(engine.selectionSet).projectedRanges
    XCTAssertEqual(ranges.count, 3)
    XCTAssertEqual(ranges[0], 2..<4)
    XCTAssertEqual(ranges[1], 6..<6)
    XCTAssertEqual(ranges[2], 9..<11)
  }

  func testVisualBlockUsesTabAndCJKVirtualColumns() throws {
    let engine = VimEngine(text: "\t한x\n1234567", cursor: 1, tabWidth: 4)
    let controller = VimKeymapController(engine: engine)
    _ = try controller.handle(token: "<C-V>")
    _ = try controller.handle(token: "j")

    let visual = try XCTUnwrap(controller.interactionSnapshot.visualSelection)
    XCTAssertEqual(visual.shape, .block)
    XCTAssertEqual(visual.height, 2)
    XCTAssertEqual(visual.projectedRanges.count, 2)
  }

  func testVisualBlockStatusSurvivesBlockInsertComposition() throws {
    let engine = VimEngine(text: "ab\ncd", cursor: 0)
    let controller = VimKeymapController(engine: engine)
    _ = try controller.handle(token: "<C-V>")
    _ = try controller.handle(token: "j")
    _ = try controller.handle(token: "I")
    _ = try controller.handle(event: .compositionStarted)
    _ = try controller.handle(event: .compositionUpdated("한", selectedRange: 1..<1))

    let visual = try XCTUnwrap(controller.interactionSnapshot.visualSelection)
    XCTAssertEqual(visual.shape, .block)
    XCTAssertEqual(visual.height, 2)
    XCTAssertTrue(visual.isBlockInsertion)
    XCTAssertTrue(controller.interactionSnapshot.isComposingText)
  }

  func testDotRepeatsVisualBlockDeleteRelativeToCursor() throws {
    let engine = VimEngine(text: "abcd\nefgh\nijkl\nmnop", cursor: 0)
    _ = try engine.executeNotation("<C-V>jld")
    XCTAssertEqual(engine.state.text, "cd\ngh\nijkl\nmnop")
    engine.synchronize(text: engine.state.text, cursor: 6)
    _ = try engine.execute(.repeatLastChange)
    XCTAssertEqual(engine.state.text, "cd\ngh\nkl\nop")
  }

  func testDotRepeatsVisualBlockInsertionRelativeToCursor() throws {
    let engine = VimEngine(text: "abcd\nefgh\nijkl\nmnop", cursor: 0)
    _ = try engine.executeNotation("<C-V>jI!<Esc>")
    XCTAssertEqual(engine.state.text, "!abcd\n!efgh\nijkl\nmnop")
    engine.synchronize(text: engine.state.text, cursor: 12)
    _ = try engine.execute(.repeatLastChange)
    XCTAssertEqual(engine.state.text, "!abcd\n!efgh\n!ijkl\n!mnop")
  }

  func testMacroReplaysVisualBlockDelete() throws {
    let engine = VimEngine(text: "abcd\nefgh\nijkl\nmnop", cursor: 0)
    _ = try engine.executeNotation("qa<C-V>jldq")
    XCTAssertEqual(engine.state.text, "cd\ngh\nijkl\nmnop")
    engine.synchronize(text: engine.state.text, cursor: 6)
    _ = try engine.executeNotation("@a")
    XCTAssertEqual(engine.state.text, "cd\ngh\nkl\nop")
  }

  func testDotRepeatsVisualBlockReplacement() throws {
    let engine = VimEngine(text: "abcd\nefgh\nijkl\nmnop", cursor: 0)
    _ = try engine.executeNotation("<C-V>jlrX")
    XCTAssertEqual(engine.state.text, "XXcd\nXXgh\nijkl\nmnop")
    engine.synchronize(text: engine.state.text, cursor: 10)
    _ = try engine.execute(.repeatLastChange)
    XCTAssertEqual(engine.state.text, "XXcd\nXXgh\nXXkl\nXXop")
  }

  func testVisualBlockSubstituteUsesBlockChange() throws {
    let engine = VimEngine(text: "abcd\nefgh", cursor: 1)
    _ = try engine.executeNotation("<C-V>jls!<Esc>")
    XCTAssertEqual(engine.state.text, "a!d\ne!h")
  }

  func testBlockwisePasteCreatesMissingLines() throws {
    let engine = VimEngine(text: "ab\ncd\nef", cursor: 0)
    _ = try engine.executeNotation("<C-V>jjy")
    engine.synchronize(text: "x", cursor: 0)
    _ = try engine.executeNotation("p")
    XCTAssertEqual(engine.state.text, "xa\n c\n e")
  }

  private func selectTwoByTwoBlock(_ engine: VimEngine) throws {
    _ = try engine.executeNotation("<C-V>jl")
  }
}
