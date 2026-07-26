import AppKit
import XCTest

@testable import Calcite

nonisolated final class TerminalResizeRegressionTests: XCTestCase {
  func testZshResizeRepaintDoesNotAddTrailingDocumentLines() async {
    await MainActor.run {
      let prompt = "PROMPT> echo 1234567890abcdefghijklmnopqrstuvwxyz"
      var decoder = TerminalANSITextDecoder()
      decoder.reset(columns: 80, rows: 24)
      decoder.decode("e\u{8}echo 1234567890abcdefghijklmnopqrstuvwxyz")

      decoder.resize(columns: 20, rows: 24)
      decoder.decode(
        [
          "\r\r", "\u{1B}[0m", "\u{1B}[27m", "\u{1B}[24m", "\u{1B}[J", prompt,
          "\u{1B}[K",
        ].joined()
      )

      decoder.resize(columns: 100, rows: 24)
      decoder.decode(
        [
          "\u{1B}[A", "\u{1B}[A", "\r\r", "\u{1B}[0m", "\u{1B}[27m", "\u{1B}[24m",
          "\u{1B}[J", prompt, "\r\r\n", "\u{1B}[K", "\r\r\n", "\u{1B}[K", "\u{1B}[A",
          "\u{1B}[A", "\u{1B}[49C",
        ].joined()
      )

      let snapshot = decoder.renderedSnapshot
      XCTAssertEqual(snapshot.text, prompt)
      XCTAssertEqual(snapshot.cursorUTF16Location, (prompt as NSString).length)

      decoder.decode("Z")
      XCTAssertEqual(decoder.renderedSnapshot.text, prompt + "Z")
    }
  }

  func testSnapshotKeepsCursorRowAndContentBelowIt() async {
    await MainActor.run {
      var decoder = TerminalANSITextDecoder()
      decoder.reset(columns: 80, rows: 24)
      decoder.decode("top\r\nbottom\u{1B}[A")

      let snapshot = decoder.renderedSnapshot
      XCTAssertEqual(snapshot.text, "top\nbottom")
      XCTAssertEqual(snapshot.cursorUTF16Location, 3)

      decoder.reset(columns: 80, rows: 24)
      decoder.decode("top\r\n")
      XCTAssertEqual(decoder.renderedSnapshot.text, "top\n")
    }
  }

  @MainActor
  func testHorizontalResizePublishesOnlySettledWidthAndSendsNoInput() async throws {
    var publishedSizes: [(columns: Int, rows: Int)] = []
    var sentInput: [String] = []
    let view = TerminalTextView(
      snapshot: TerminalRenderedSnapshot(text: "", styleSpans: []),
      outputEpoch: 0,
      preferences: .default,
      appearanceRevision: 0,
      send: { sentInput.append($0) },
      clear: {},
      resize: { publishedSizes.append(($0, $1)) }
    )
    let coordinator = TerminalTextView.Coordinator(parent: view)

    for columns in [20, 28, 36, 45, 54, 62, 70, 80, 90, 100] {
      coordinator.scheduleResizePublication((columns: columns, rows: 24))
      try await Task.sleep(for: .milliseconds(3))
    }
    try await Task.sleep(for: .milliseconds(80))

    XCTAssertEqual(publishedSizes.map(\.columns), [100])
    XCTAssertEqual(publishedSizes.map(\.rows), [24])
    XCTAssertTrue(sentInput.isEmpty)
  }

  func testEditorCursorAtEOFUsesFinalGlyphInsteadOfEmptyExtraFragment() async throws {
    try await MainActor.run {
      let storage = NSTextStorage()
      let layoutManager = NSLayoutManager()
      let textContainer = NSTextContainer(containerSize: NSSize(width: 400, height: 400))
      storage.addLayoutManager(layoutManager)
      layoutManager.addTextContainer(textContainer)

      let textView = CodeEditorTextView(
        frame: NSRect(x: 0, y: 0, width: 400, height: 400),
        textContainer: textContainer
      )
      textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
      textView.string = "abc"
      textView.setSelectedRange(NSRange(location: 3, length: 0))
      textView.vimCursorStyle = .block

      let cursorRect = try XCTUnwrap(textView.customInsertionPointRect())
      let finalGlyphRect = layoutManager.boundingRect(
        forGlyphRange: NSRange(location: 2, length: 1),
        in: textContainer
      )

      XCTAssertEqual(cursorRect.minX, finalGlyphRect.maxX, accuracy: 0.5)
      XCTAssertEqual(cursorRect.minY, finalGlyphRect.minY, accuracy: 0.5)
      XCTAssertGreaterThan(cursorRect.width, 2)
      XCTAssertGreaterThan(cursorRect.height, 0)

      textView.setSelectedRange(NSRange(location: 1, length: 0))
      textView.vimCursorStyle = .line
      let insertCursorRect = try XCTUnwrap(textView.customInsertionPointRect())
      XCTAssertGreaterThanOrEqual(insertCursorRect.width, 1.5)
      XCTAssertLessThanOrEqual(insertCursorRect.width, 2)

      textView.vimCursorStyle = .underline
      let replaceCursorRect = try XCTUnwrap(textView.customInsertionPointRect())
      XCTAssertEqual(replaceCursorRect.height, 2)
      XCTAssertGreaterThan(replaceCursorRect.width, 2)
    }
  }
}
