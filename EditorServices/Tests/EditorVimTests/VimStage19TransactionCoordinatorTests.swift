@_spi(Calcite) import EditorVim
import XCTest

final class VimStage19TransactionCoordinatorTests: XCTestCase {
  func testChangeSetPreservesSeparatedExternalEdits() {
    let changes = VimTextChangeSet.between("alpha beta gamma", and: "ALPHA beta GAMMA")

    XCTAssertEqual(changes.changes.count, 2)
    XCTAssertEqual(changes.applying(to: "alpha beta gamma"), "ALPHA beta GAMMA")
  }

  func testCoordinatorRebasesAcrossTwoNonOverlappingExternalEdits() throws {
    let baseText = "one two three four"
    let transaction = makeTransaction(
      source: baseText,
      edit: VimTransactionEdit(range: 4..<7, replacement: "TWO")
    )
    let currentText = "ONE two three FOUR"

    let prepared = try VimTransactionCoordinator().prepare(
      transaction,
      base: VimTransactionSnapshot(revision: VimDocumentRevision(4), text: baseText),
      current: VimTransactionSnapshot(revision: VimDocumentRevision(6), text: currentText)
    )

    XCTAssertEqual(prepared.transaction.afterState.text, "ONE TWO three FOUR")
    XCTAssertEqual(
      VimTransactionCoordinator.applying(
        prepared.transaction.baseEdits,
        to: currentText
      ),
      "ONE TWO three FOUR"
    )
    XCTAssertEqual(
      prepared.disposition,
      .rebased(from: VimDocumentRevision(4), to: VimDocumentRevision(6))
    )
  }

  func testCoordinatorRejectsRealOverlap() {
    let baseText = "one two three"
    let transaction = makeTransaction(
      source: baseText,
      edit: VimTransactionEdit(range: 4..<7, replacement: "TWO")
    )

    XCTAssertThrowsError(
      try VimTransactionCoordinator().prepare(
        transaction,
        base: VimTransactionSnapshot(revision: VimDocumentRevision(4), text: baseText),
        current: VimTransactionSnapshot(
          revision: VimDocumentRevision(5),
          text: "one second three"
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? VimDocumentTransactionError,
        .conflict(.overlappingExternalEdit)
      )
    }
  }

  func testInsertionAtEditedRangeBoundaryRebasesWithoutCapturingExternalText() throws {
    let baseText = "abcDEFghi"
    let transaction = makeTransaction(
      source: baseText,
      edit: VimTransactionEdit(range: 3..<6, replacement: "def")
    )

    let prepared = try VimTransactionCoordinator().prepare(
      transaction,
      base: VimTransactionSnapshot(revision: VimDocumentRevision(4), text: baseText),
      current: VimTransactionSnapshot(revision: VimDocumentRevision(5), text: "abc!DEFghi")
    )

    XCTAssertEqual(prepared.transaction.afterState.text, "abc!defghi")
    XCTAssertEqual(prepared.transaction.baseEdits.map(\.range), [4..<7])
  }

  func testRepeatedUnicodeRebasesRemainValidUTF16Transactions() throws {
    for index in 0..<128 {
      let baseText = "prefix-\(index)|TARGET|middle-\(index)|END"
      let targetRange = (baseText as NSString).range(of: "TARGET")
      let transaction = makeTransaction(
        source: baseText,
        edit: VimTransactionEdit(
          range: targetRange.location..<NSMaxRange(targetRange),
          replacement: "변경👩‍💻"
        )
      )
      let currentText =
        "한👩‍💻-\(index)-" + baseText.replacingOccurrences(of: "END", with: "FIN-\(index)")

      let prepared = try VimTransactionCoordinator().prepare(
        transaction,
        base: VimTransactionSnapshot(revision: VimDocumentRevision(4), text: baseText),
        current: VimTransactionSnapshot(revision: VimDocumentRevision(5), text: currentText)
      )

      XCTAssertEqual(
        VimTransactionCoordinator.applying(prepared.transaction.baseEdits, to: currentText),
        currentText.replacingOccurrences(of: "TARGET", with: "변경👩‍💻")
      )
    }
  }

  private func makeTransaction(
    source: String,
    edit: VimTransactionEdit
  ) -> VimEditTransaction {
    let result = VimTransactionCoordinator.applying([edit], to: source)!
    return VimEditTransaction(
      baseRevision: VimDocumentRevision(4),
      beforeState: VimState(text: source, cursor: edit.lowerBound),
      afterState: VimState(text: result, cursor: edit.lowerBound),
      sequentialEdits: [edit],
      baseEdits: [edit],
      repeatMetadata: VimRepeatMetadata(isRepeatable: true, finishesInInsertMode: false)
    )
  }
}
