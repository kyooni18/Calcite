import AppKit
import XCTest

@testable import Calcite

@MainActor
final class CodeEditorTextViewPointerSelectionTests: XCTestCase {
  func testPlainClickUsesPhysicalHitTargetWhenVimReappliesPreviousSelection() {
    let resolved = CodeEditorTextView.resolvedPointerSelection(
      hitTested: NSRange(location: 14, length: 0),
      selectionBeforeMouseDown: NSRange(location: 2, length: 0),
      selectionAfterMouseDown: NSRange(location: 2, length: 0),
      isPlainSingleClick: true
    )

    XCTAssertEqual(resolved, NSRange(location: 14, length: 0))
  }

  func testPlainClickPrefersPhysicalHitTargetOverTransientNativeSelection() {
    let resolved = CodeEditorTextView.resolvedPointerSelection(
      hitTested: NSRange(location: 14, length: 0),
      selectionBeforeMouseDown: NSRange(location: 2, length: 0),
      selectionAfterMouseDown: NSRange(location: 7, length: 0),
      isPlainSingleClick: true
    )

    XCTAssertEqual(resolved, NSRange(location: 14, length: 0))
  }

  func testNormalLineCursorUsesNativeAppKitInsertionPoint() {
    let textView = CodeEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
    textView.string = "let value = 1"
    textView.editorCursorColor = .systemGreen
    textView.editorCursorStyle = .line
    textView.vimCursorStyle = nil
    textView.vimCursorLocation = nil
    textView.refreshInsertionPointRendering()

    XCTAssertTrue(textView.shouldDrawInsertionPoint)
    XCTAssertTrue(textView.insertionPointColor.isEqual(NSColor.systemGreen))

    textView.vimCursorStyle = .block
    XCTAssertFalse(textView.shouldDrawInsertionPoint)
    XCTAssertTrue(textView.insertionPointColor.isEqual(NSColor.clear))

    textView.vimCursorStyle = nil
    XCTAssertTrue(textView.shouldDrawInsertionPoint)
    XCTAssertTrue(textView.insertionPointColor.isEqual(NSColor.systemGreen))
  }

  func testLiveMarkdownPresentationKeepsStableCustomLineCaret() {
    let textView = CodeEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
    textView.string = "# Heading"
    textView.editorCursorColor = .systemOrange
    textView.editorCursorStyle = .line
    textView.vimCursorStyle = nil
    textView.vimCursorLocation = nil

    textView.requiresPresentationAwareInsertionPoint = true

    XCTAssertFalse(textView.shouldDrawInsertionPoint)
    XCTAssertTrue(textView.insertionPointColor.isEqual(NSColor.clear))

    textView.requiresPresentationAwareInsertionPoint = false

    XCTAssertTrue(textView.shouldDrawInsertionPoint)
    XCTAssertTrue(textView.insertionPointColor.isEqual(NSColor.systemOrange))
  }

  func testExtendedSelectionKeepsAppKitResult() {
    let selection = NSRange(location: 4, length: 8)
    let resolved = CodeEditorTextView.resolvedPointerSelection(
      hitTested: NSRange(location: 14, length: 0),
      selectionBeforeMouseDown: NSRange(location: 2, length: 0),
      selectionAfterMouseDown: selection,
      isPlainSingleClick: false
    )

    XCTAssertEqual(resolved, selection)
  }
}
