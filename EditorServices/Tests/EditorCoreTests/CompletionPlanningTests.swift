import EditorCore
import XCTest

final class CompletionPlanningTests: XCTestCase {
  func testPlannedCompletionDoesNotMutateBaseSnapshotAndPlacesSnippetStops() throws {
    let snapshot = TextSnapshot(text: "let value = pri", version: 7)
    let position = try snapshot.position(atUTF16Offset: snapshot.utf16Count)
    let completion = Completion(
      label: "print",
      insertText: "print(${1:value})$0",
      insertTextFormat: .snippet
    )

    let planned = try CompletionUtilities.plannedApplication(
      for: completion,
      in: snapshot,
      at: position
    )

    XCTAssertEqual(snapshot.text, "let value = pri")
    XCTAssertEqual(planned.snapshot.text, "let value = print(value)")
    XCTAssertEqual(planned.edits.count, 1)
    XCTAssertEqual(planned.tabStops.count, 1)
    XCTAssertEqual(
      try planned.snapshot.nsRange(for: planned.initialSelection),
      NSRange(location: 18, length: 5)
    )
    XCTAssertEqual(try planned.snapshot.utf16Offset(of: planned.finalCursor), 24)
  }

  func testAdditionalEditBeforePrimaryAdjustsInsertedRange() throws {
    let snapshot = TextSnapshot(text: "foo()", version: 3)
    let position = try snapshot.position(atUTF16Offset: 3)
    let importRange = EditorTextRange(
      start: try snapshot.position(atUTF16Offset: 0),
      end: try snapshot.position(atUTF16Offset: 0)
    )
    let completion = Completion(
      label: "bar",
      insertText: "bar",
      additionalEdits: [TextEdit(range: importRange, replacement: "import X\n")]
    )

    let planned = try CompletionUtilities.plannedApplication(
      for: completion,
      in: snapshot,
      at: position
    )

    XCTAssertEqual(planned.snapshot.text, "import X\nbar()")
    XCTAssertEqual(
      try planned.snapshot.nsRange(for: planned.insertedRange),
      NSRange(location: 9, length: 3)
    )
  }
}
