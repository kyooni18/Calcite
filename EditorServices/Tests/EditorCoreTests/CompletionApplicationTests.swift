import Foundation
import XCTest

@testable import EditorCore

final class CompletionApplicationTests: XCTestCase {
  func testSnippetExpansionTracksMirrorsChoicesAndFinalCursor() throws {
    let expansion = try SnippetExpansion.expand(
      "func ${1:name}(${2|Int,String|} value: $1) {\n  $0\n}"
    )

    XCTAssertEqual(expansion.text, "func name(Int value: name) {\n  \n}")
    XCTAssertEqual(expansion.tabStops.map(\.index), [1, 2])
    XCTAssertEqual(expansion.tabStops[0].ranges.count, 2)
    XCTAssertEqual(expansion.tabStops[1].choices, ["Int", "String"])
    let marker = (expansion.text as NSString).range(of: "\n  \n")
    XCTAssertNotEqual(marker.location, NSNotFound)
    XCTAssertEqual(expansion.finalCursorUTF16Offset, marker.location + 3)
  }

  func testSnippetExpansionSupportsVariablesDefaultsAndEscapes() throws {
    let expansion = try SnippetExpansion.expand(
      "${TM_FILENAME:Fallback.swift}: \\${1:literal} ${SELECTED_TEXT:selection}",
      variables: ["TM_FILENAME": "Main.swift", "SELECTED_TEXT": "선택"]
    )

    XCTAssertEqual(expansion.text, "Main.swift: ${1:literal} 선택")
    XCTAssertTrue(expansion.tabStops.isEmpty)
  }

  func testSnippetExpansionRejectsTransformsAndMalformedInput() throws {
    XCTAssertThrowsError(try SnippetExpansion.expand("${1/foo/bar/}")) { error in
      XCTAssertEqual(error as? SnippetExpansionError, .unsupportedTransform)
    }
    XCTAssertThrowsError(try SnippetExpansion.expand("${1:missing")) { error in
      guard case .malformed = error as? SnippetExpansionError else {
        return XCTFail("Expected malformed snippet, got \(error)")
      }
    }
  }

  func testUnicodeIdentifierRangeUsesSwiftIdentifierScalars() throws {
    let snapshot = TextSnapshot(text: "let 카운트_값 = 1")
    let end = TextPosition(line: 0, utf16Column: "let 카운트_값".utf16.count)
    let range = try CompletionUtilities.inferredIdentifierRange(in: snapshot, endingAt: end)

    XCTAssertEqual(range.start, TextPosition(line: 0, utf16Column: "let ".utf16.count))
    XCTAssertEqual(range.end, end)
  }

  func testApplicationPlanCombinesPrimaryAndAdditionalEditsAtomically() throws {
    let snapshot = TextSnapshot(text: "// header\npri")
    let completion = Completion(
      label: "print",
      insertText: "print(${1:item})$0",
      insertTextFormat: .snippet,
      additionalEdits: [
        TextEdit(
          range: TextRange(start: .zero, end: .zero),
          replacement: "import Foundation\n"
        )
      ]
    )
    let plan = try CompletionUtilities.applicationPlan(
      for: completion,
      in: snapshot,
      at: TextPosition(line: 1, utf16Column: 3)
    )

    XCTAssertEqual(
      plan.primaryRange,
      TextRange(
        start: TextPosition(line: 1, utf16Column: 0),
        end: TextPosition(line: 1, utf16Column: 3)
      ))
    XCTAssertEqual(plan.expansion.text, "print(item)")
    XCTAssertEqual(plan.edits.count, 2)

    var buffer = TextBuffer(text: snapshot.text)
    _ = try buffer.apply(plan.edits)
    XCTAssertEqual(buffer.snapshot.text, "import Foundation\n// header\nprint(item)")
  }

  func testApplicationPlanRejectsOverlappingServerEditsWithoutMutation() throws {
    let snapshot = TextSnapshot(text: "value")
    let completion = Completion(
      label: "replacement",
      primaryEdit: TextEdit(
        range: TextRange(
          start: .zero,
          end: TextPosition(line: 0, utf16Column: 5)
        ),
        replacement: "item"
      ),
      additionalEdits: [
        TextEdit(
          range: TextRange(
            start: TextPosition(line: 0, utf16Column: 1),
            end: TextPosition(line: 0, utf16Column: 2)
          ),
          replacement: "x"
        )
      ]
    )

    XCTAssertThrowsError(
      try CompletionUtilities.applicationPlan(
        for: completion,
        in: snapshot,
        at: TextPosition(line: 0, utf16Column: 5)
      )
    )
    XCTAssertEqual(snapshot.text, "value")
  }
}
