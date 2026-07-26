import AppKit
import XCTest

@testable import Calcite

nonisolated final class TerminalResizeRegressionTests: XCTestCase {
  func testCustomVimLaunchCommandPassesDefaultArgumentsToAnAlias() async {
    await MainActor.run {
      let suiteName = "CalciteTests.launchCommand.\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suiteName)!
      defer { defaults.removePersistentDomain(forName: suiteName) }
      defaults.set("edit", forKey: EditorInterfacePreferences.neovimLaunchCommandKey)

      let command = EditorInterfacePreferences.launchCommand(
        interface: .neovim,
        fileURL: URL(fileURLWithPath: "/tmp/My File.swift"),
        workspaceURL: URL(fileURLWithPath: "/tmp/Project"),
        defaults: defaults
      )

      XCTAssertTrue(command?.hasPrefix("edit --cmd ") == true)
      XCTAssertTrue(command?.contains(" -- '/tmp/My File.swift'") == true)
    }
  }

  func testCustomVimLaunchCommandDoesNotDuplicateExplicitArguments() async {
    await MainActor.run {
      let suiteName = "CalciteTests.launchCommand.\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suiteName)!
      defer { defaults.removePersistentDomain(forName: suiteName) }
      defaults.set("edit --cmd {leaderCommand} -- {file}", forKey: EditorInterfacePreferences.neovimLaunchCommandKey)

      let command = EditorInterfacePreferences.launchCommand(
        interface: .neovim,
        fileURL: URL(fileURLWithPath: "/tmp/File.swift"),
        workspaceURL: URL(fileURLWithPath: "/tmp/Project"),
        defaults: defaults
      )

      XCTAssertEqual(command?.components(separatedBy: "--cmd").count, 2)
      XCTAssertEqual(command?.components(separatedBy: "'/tmp/File.swift'").count, 2)
    }
  }

  func testVimMouseModesEncodeSGRPointerInputAndStopWhenDisabled() async {
    await MainActor.run {
      var decoder = TerminalANSITextDecoder()
      decoder.decode("\u{1B}[?1002;1006h")

      XCTAssertEqual(
        decoder.mouseSequence(for: .buttonDown(0, column: 12, row: 4)),
        "\u{1B}[<0;12;4M"
      )
      XCTAssertEqual(
        decoder.mouseSequence(for: .buttonUp(2, column: 12, row: 4)),
        "\u{1B}[<2;12;4m"
      )
      XCTAssertEqual(
        decoder.mouseSequence(for: .scroll(up: true, column: 12, row: 4)),
        "\u{1B}[<64;12;4M"
      )

      decoder.decode("\u{1B}[?1002;1006l")
      XCTAssertNil(decoder.mouseSequence(for: .buttonDown(0, column: 1, row: 1)))
    }
  }

  func testNeovimScrollRegionKeepsStatusLineDuringGridScroll() async {
    await MainActor.run {
      var decoder = TerminalANSITextDecoder()
      decoder.reset(columns: 40, rows: 5)
      decoder.decode("\u{1B}[?1049h")
      decoder.decode("\u{1B}[5;1Hstatus")
      decoder.decode("\u{1B}[1;4r")
      decoder.decode("\u{1B}[1;1Ha\r\nb\r\nc\r\nd\r\ne")

      XCTAssertEqual(decoder.renderedSnapshot.text, "b\nc\nd\ne\nstatus")
    }
  }

  func testStyledEraseLineRetainsNeovimPopupBackgroundCells() async {
    await MainActor.run {
      var decoder = TerminalANSITextDecoder()
      decoder.reset(columns: 12, rows: 4)
      decoder.preservesEraseCellBackgrounds = true
      decoder.decode("\u{1B}[48;2;32;55;82mitem\u{1B}[K")

      let snapshot = decoder.renderedSnapshot
      XCTAssertEqual(snapshot.text, "item" + String(repeating: " ", count: 8))
      XCTAssertEqual(snapshot.styleSpans.count, 1)
      XCTAssertEqual(snapshot.styleSpans[0].utf16Length, 12)
    }
  }

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
