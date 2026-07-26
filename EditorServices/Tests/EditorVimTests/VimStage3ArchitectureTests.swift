import EditorCore
import XCTest

@testable import EditorVim

final class VimStage3ArchitectureTests: XCTestCase {
  func testFacadeDelegatesToSplitInternalSubsystems() throws {
    let engine = VimEngine(text: "one two\nthree", cursor: 0)
    let before = engine.state
    let result = engine.evaluateMotion(.wordEnd, count: 1, from: before.cursor)

    XCTAssertEqual(result.destination, 2)
    XCTAssertTrue(result.inclusive)
    XCTAssertEqual(engine.state, before, "Pure motion evaluation must not mutate live editor state")
  }

  func testOperatorRangeEvaluationDoesNotMoveCursor() {
    let engine = VimEngine(text: "one two", cursor: 0)
    let before = engine.state
    let range = engine.operatorRange(for: .wordEnd, count: 1)

    XCTAssertEqual(range.range, 0..<3)
    XCTAssertFalse(range.linewise)
    XCTAssertEqual(engine.state, before)
  }

  func testMultiLineIndentRecordsDiscreteEditsAsOneUndoUnit() throws {
    let engine = VimEngine(text: "a\nb\nc\n", cursor: 0, tabWidth: 2)
    try engine.executeNotation("2>>")

    XCTAssertEqual(engine.state.text, "  a\n  b\nc\n")
    XCTAssertEqual(engine.undoStack.last?.edits.count, 2)

    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "a\nb\nc\n")
    try engine.executeNotation("<c-r>")
    XCTAssertEqual(engine.state.text, "  a\n  b\nc\n")
  }

  func testExMoveRecordsRemovalAndInsertionInOneTransaction() throws {
    let engine = VimEngine(text: "one\ntwo\nthree\nfour\n", cursor: 0)
    try engine.execute(.ex("1,2move4"))

    XCTAssertEqual(engine.undoStack.last?.edits.count, 2)
    let moved = engine.state.text
    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "one\ntwo\nthree\nfour\n")
    try engine.executeNotation("<c-r>")
    XCTAssertEqual(engine.state.text, moved)
  }

  func testIncrementalLineIndexTracksCRLFAndInsertedLines() throws {
    let engine = VimEngine(text: "one\r\ntwo\r\nthree", cursor: 5)
    try engine.executeNotation("iA\nB<Esc>")

    engine.lineIndex.synchronize(with: engine.state.text)
    XCTAssertEqual(engine.lineIndex.lineCount, 4)
    XCTAssertEqual(engine.lineIndex.offset(ofOneBasedLine: 3), 7)

    try engine.executeNotation("u")
    engine.lineIndex.synchronize(with: engine.state.text)
    XCTAssertEqual(engine.lineIndex.lineCount, 3)
    XCTAssertEqual(engine.lineIndex.offset(ofOneBasedLine: 3), 10)
  }

  func testEmptyInsertSessionDoesNotLeakEditCapture() throws {
    let engine = VimEngine(text: "abc", cursor: 0)
    try engine.executeNotation("i<Esc>x")

    XCTAssertEqual(engine.editCaptureDepth, 0)
    XCTAssertTrue(engine.capturedEdits.isEmpty)
    XCTAssertEqual(engine.state.text, "bc")
    try engine.executeNotation("u")
    XCTAssertEqual(engine.state.text, "abc")
  }

  func testControllerKeepsOnePersistentBuiltinParserAcrossKeys() throws {
    let engine = VimEngine(text: "one two three", cursor: 0)
    let controller = VimKeymapController(engine: engine)

    XCTAssertTrue(try controller.handle(token: "2").awaitingMoreInput)
    XCTAssertEqual(controller.pendingNotation, "2")
    XCTAssertTrue(try controller.handle(token: "d").awaitingMoreInput)
    XCTAssertEqual(controller.pendingNotation, "2d")
    XCTAssertFalse(try controller.handle(token: "w").awaitingMoreInput)
    XCTAssertEqual(controller.pendingNotation, "")
    XCTAssertEqual(engine.state.text, "three")
  }

  func testIncrementalLineIndexHandlesTerminatorReplacementAtBoundary() throws {
    let engine = VimEngine(text: "a\r\nb\nc", cursor: 1)
    engine.synchronize(text: "a\nb\nc", cursor: 1)
    engine.lineIndex.synchronize(with: engine.state.text)

    XCTAssertEqual(engine.state.text, "a\nb\nc")
    XCTAssertEqual(engine.lineIndex.lineCount, 3)
    XCTAssertEqual(engine.lineIndex.offset(ofOneBasedLine: 2), 2)
    XCTAssertEqual(engine.lineIndex.offset(ofOneBasedLine: 3), 4)
  }

  func testIncrementalLineIndexMatchesFullRebuildAfterRandomizedEdits() {
    var generator = DeterministicGenerator(seed: 0xC0FFEE)
    var text = "alpha\r\nbeta\ngamma\rdelta"
    let incremental = VimLineIndex()
    incremental.synchronize(with: text)

    let insertions = ["", "x", "\n", "\r", "\r\n", "u\nv", "끝", "🙂"]

    for _ in 0..<500 {
      let boundaries = utf16Boundaries(in: text)
      let lowerIndex = Int(generator.next() % UInt64(boundaries.count))
      let upperIndex = lowerIndex + Int(generator.next() % UInt64(boundaries.count - lowerIndex))
      let lower = boundaries[lowerIndex]
      let upper = boundaries[upperIndex]
      let range = lower..<upper
      let replacement = insertions[Int(generator.next() % UInt64(insertions.count))]
      let removed = (text as NSString).substring(
        with: NSRange(location: lower, length: upper - lower))
      let next = (text as NSString).replacingCharacters(
        in: NSRange(location: lower, length: upper - lower),
        with: replacement
      )

      incremental.apply(
        replacementRange: range,
        removedText: removed,
        insertedText: replacement,
        resultingText: next
      )
      text = next

      let rebuilt = VimLineIndex()
      rebuilt.synchronize(with: text)
      XCTAssertEqual(incremental.lineCount, rebuilt.lineCount)
      for line in 1...rebuilt.lineCount {
        XCTAssertEqual(
          incremental.offset(ofOneBasedLine: line),
          rebuilt.offset(ofOneBasedLine: line),
          "Line start mismatch at line \(line) for text \(String(reflecting: text))"
        )
        let offset = rebuilt.offset(ofOneBasedLine: line)
        XCTAssertEqual(
          incremental.contentEnd(containing: offset, textLength: text.utf16.count),
          rebuilt.contentEnd(containing: offset, textLength: text.utf16.count)
        )
        XCTAssertEqual(
          incremental.endIncludingTerminator(containing: offset, textLength: text.utf16.count),
          rebuilt.endIncludingTerminator(containing: offset, textLength: text.utf16.count)
        )
      }
    }
  }

  private func utf16Boundaries(in text: String) -> [Int] {
    var boundaries: [Int] = [0]
    var offset = 0
    for character in text {
      offset += String(character).utf16.count
      boundaries.append(offset)
    }
    return boundaries
  }

}

private struct DeterministicGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}
