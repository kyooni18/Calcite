import AppKit
import XCTest

@testable import Calcite

@MainActor
final class MarkdownEditorScrollStabilityTests: XCTestCase {
  func testHiddenMarkdownMarkersDoNotChangeGlyphGeometryWhenActiveLineMoves() {
    let profile = makeProfile()
    let source = """
      # Heading One
      Paragraph with **bold** and _italic_ text.

      - First item
      - Second item with [a link](https://example.com)

      ## Heading Two
      More text below the second heading.
      """
    let textView = makeTextView(source: source, width: 440)
    let styler = EditorTextStyler(profile: profile, zoomScale: 1)
    let text = source as NSString
    let firstSelection = NSRange(location: 0, length: 0)
    let secondHeadingLocation = text.range(of: "## Heading Two").location

    styler.apply(
      to: textView,
      languageID: "markdown",
      liveMarkdownStyling: true,
      showsMarkdownSyntax: false,
      syntaxHighlights: [],
      semanticHighlights: [],
      diagnostics: [],
      showsInlineDiagnosticMessages: false,
      selectedRange: firstSelection
    )

    let before = geometrySnapshot(
      forCharacterAt: text.range(of: "More text below").location,
      in: textView
    )
    let firstMarkerFontBefore =
      textView.textStorage?.attribute(
        .font,
        at: 0,
        effectiveRange: nil
      ) as? NSFont
    let firstMarkerKernBefore = textView.textStorage?.attribute(
      .kern,
      at: 0,
      effectiveRange: nil
    )

    let oldLine = text.lineRange(for: firstSelection)
    let newLine = text.lineRange(for: NSRange(location: secondHeadingLocation, length: 0))
    styler.apply(
      to: textView,
      languageID: "markdown",
      liveMarkdownStyling: true,
      showsMarkdownSyntax: false,
      syntaxHighlights: [],
      semanticHighlights: [],
      diagnostics: [],
      showsInlineDiagnosticMessages: false,
      selectedRange: NSRange(location: secondHeadingLocation, length: 0),
      affectedRange: NSUnionRange(oldLine, newLine)
    )

    let after = geometrySnapshot(
      forCharacterAt: text.range(of: "More text below").location,
      in: textView
    )
    let firstMarkerFontAfter =
      textView.textStorage?.attribute(
        .font,
        at: 0,
        effectiveRange: nil
      ) as? NSFont
    let firstMarkerKernAfter = textView.textStorage?.attribute(
      .kern,
      at: 0,
      effectiveRange: nil
    )

    XCTAssertEqual(before.lineMinY, after.lineMinY, accuracy: 0.01)
    XCTAssertEqual(before.lineHeight, after.lineHeight, accuracy: 0.01)
    XCTAssertEqual(before.usedHeight, after.usedHeight, accuracy: 0.01)
    XCTAssertEqual(
      firstMarkerFontBefore?.pointSize ?? 0, firstMarkerFontAfter?.pointSize ?? 0, accuracy: 0.01)
    XCTAssertNil(firstMarkerKernBefore)
    XCTAssertNil(firstMarkerKernAfter)
  }

  private func makeTextView(source: String, width: CGFloat) -> CodeEditorTextView {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(
      containerSize: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    )
    textContainer.widthTracksTextView = true
    layoutManager.addTextContainer(textContainer)
    storage.addLayoutManager(layoutManager)

    let textView = CodeEditorTextView(
      frame: NSRect(x: 0, y: 0, width: width, height: 600),
      textContainer: textContainer
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.string = source
    return textView
  }

  private func geometrySnapshot(
    forCharacterAt characterOffset: Int,
    in textView: NSTextView
  ) -> (lineMinY: CGFloat, lineHeight: CGFloat, usedHeight: CGFloat) {
    guard let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer
    else {
      XCTFail("Expected TextKit objects")
      return (0, 0, 0)
    }

    layoutManager.ensureLayout(for: textContainer)
    let glyph = layoutManager.glyphIndexForCharacter(at: characterOffset)
    let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    let used = layoutManager.usedRect(for: textContainer)
    return (line.minY, line.height, used.height)
  }

  private func makeProfile() -> EditorCustomProfile {
    let suiteName = "MarkdownEditorScrollStabilityTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    return EditorProfileStore.load(defaults: defaults)
  }
}
