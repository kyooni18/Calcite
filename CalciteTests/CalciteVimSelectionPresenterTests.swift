import AppKit
@_spi(Calcite) import EditorVim
import XCTest

@testable import Calcite

@MainActor
final class CalciteVimSelectionPresenterTests: XCTestCase {
  func testBlockPresentationMakesTheActiveRowAppKitsPrimaryRange() {
    let state = VimState(
      text: "ab\ncd\nef",
      cursor: 7,
      mode: .visualCharacter,
      selection: 0..<8
    )
    let selectionSet = VimSelectionSet(
      anchor: VimSelectionEndpoint(utf16Offset: 0, line: 1, virtualColumn: 0),
      active: VimSelectionEndpoint(utf16Offset: 7, line: 3, virtualColumn: 1),
      shape: .block,
      projectedRanges: [0..<2, 3..<5, 6..<8]
    )

    let presentation = CalciteVimSelectionPresenter.presentation(
      for: state,
      selectionSet: selectionSet
    )

    XCTAssertEqual(
      presentation.ranges,
      [
        NSRange(location: 0, length: 2),
        NSRange(location: 3, length: 2),
        NSRange(location: 6, length: 2),
      ]
    )
    XCTAssertEqual(presentation.activeRangeIndex, 2)
    XCTAssertEqual(presentation.primaryRange, NSRange(location: 6, length: 2))
    XCTAssertEqual(
      presentation.nativeRanges,
      [
        NSRange(location: 6, length: 2),
        NSRange(location: 0, length: 2),
        NSRange(location: 3, length: 2),
      ]
    )
  }

  func testBlockPresentationPreservesEmptyRangesOnRaggedLines() {
    let state = VimState(
      text: "abcd\nx\n",
      cursor: 6,
      mode: .visualCharacter,
      selection: 2..<6
    )
    let selectionSet = VimSelectionSet(
      anchor: VimSelectionEndpoint(utf16Offset: 2, line: 1, virtualColumn: 2),
      active: VimSelectionEndpoint(utf16Offset: 6, line: 2, virtualColumn: 2),
      shape: .block,
      projectedRanges: [2..<4, 6..<6]
    )

    let presentation = CalciteVimSelectionPresenter.presentation(
      for: state,
      selectionSet: selectionSet
    )

    XCTAssertEqual(presentation.primaryRange, NSRange(location: 6, length: 0))
    XCTAssertEqual(
      presentation.nativeRanges,
      [
        NSRange(location: 6, length: 0),
        NSRange(location: 2, length: 2),
      ]
    )
  }
}
