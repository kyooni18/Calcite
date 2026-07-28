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
