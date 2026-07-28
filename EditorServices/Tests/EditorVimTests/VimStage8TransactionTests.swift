import EditorCore
@_spi(Calcite) import EditorVim
import XCTest

final class VimStage8TransactionTests: XCTestCase {
  func testVisualBlockDeleteProducesOneAtomicBaseBatch() throws {
    let engine = VimEngine(text: "abcd\nefgh\nijkl", cursor: 1)
    let result = try engine.execute(.notation("<C-V>jld"))
    let transaction = try XCTUnwrap(result.transaction)

    XCTAssertEqual(transaction.beforeState.text, "abcd\nefgh\nijkl")
    XCTAssertEqual(transaction.afterState.text, "ad\neh\nijkl")
    XCTAssertGreaterThanOrEqual(transaction.sequentialEdits.count, 2)
    XCTAssertEqual(
      apply(transaction.baseEdits, to: transaction.beforeState.text), transaction.afterState.text)
  }

  func testKeymapControllerPublishesTransactionForFinalBlockCommand() throws {
    let engine = VimEngine(text: "abcd\nefgh", cursor: 0)
    let controller = VimKeymapController(engine: engine)
    _ = try controller.handle(token: "<C-V>")
    _ = try controller.handle(token: "j")
    _ = try controller.handle(token: "l")
    let handled = try controller.handle(token: "d")

    let transaction = try XCTUnwrap(handled.execution?.transaction)
    XCTAssertEqual(transaction.beforeState.text, "abcd\nefgh")
    XCTAssertEqual(transaction.afterState.text, "cd\ngh")
    XCTAssertEqual(apply(transaction.baseEdits, to: transaction.beforeState.text), "cd\ngh")
  }

  func testDocumentSessionAcceptsAtomicVisualBlockTransaction() async throws {
    let document = EditorDocument(
      uri: URL(fileURLWithPath: "/tmp/vim-stage8-block.txt"),
      languageID: "text",
      text: "abcd\nefgh\nijkl"
    )
    try await document.open()
    let session = await VimDocumentSession(document: document)

    let result = try await session.execute(.notation("<C-V>jld"))
    XCTAssertNotNil(result.transaction)
    let snapshot = await document.snapshot
    XCTAssertEqual(snapshot.text, "cd\ngh\nijkl")
    guard case .accepted = await session.lastTransactionResult else {
      return XCTFail("Expected an accepted transaction")
    }
  }

  func testNonOverlappingExternalEditPreservesVisualState() throws {
    let engine = VimEngine(text: "abcd\nefgh", cursor: 0)
    _ = try engine.executeNotation("vl")
    let result = engine.reconcileExternalText("abcd\nefgh!", cursor: 1)

    XCTAssertEqual(result, .preserved)
    XCTAssertEqual(engine.state.mode, .visualCharacter)
    XCTAssertNotNil(engine.selectionSet)
  }

  func testOverlappingExternalEditCancelsVisualState() throws {
    let engine = VimEngine(text: "abcd\nefgh", cursor: 0)
    _ = try engine.executeNotation("vl")
    let result = engine.reconcileExternalText("Xcd\nefgh", cursor: 0)

    guard case .cancelledConflict(let message) = result else {
      return XCTFail("Expected conflict cancellation")
    }
    XCTAssertEqual(message.code, "VIM_EXTERNAL_CONFLICT")
    XCTAssertEqual(engine.state.mode, .normal)
    XCTAssertNil(engine.selectionSet)
  }

  func testExternalEditDuringInsertCancelsOnlyTransientInteraction() throws {
    let engine = VimEngine(text: "abc", cursor: 1)
    _ = try engine.execute(.enterInsert)
    _ = try engine.execute(.insert("x"))

    let result = engine.reconcileExternalText("axbc!", cursor: 2)
    guard case .cancelledConflict = result else {
      return XCTFail("Expected insert-mode conflict cancellation")
    }
    XCTAssertEqual(engine.state.text, "axbc!")
    XCTAssertEqual(engine.state.mode, .normal)
  }

  func testHostVisualGeometryOverridesDisplayLineMovementOnly() throws {
    let engine = VimEngine(text: "abc\ndef", cursor: 1)
    let geometry = FixedGeometryProvider(verticalOffset: 0, preferredColumn: 320)
    engine.installVisualGeometryProvider(geometry)

    _ = try engine.executeNotation("j")
    XCTAssertEqual(engine.state.cursor, 5)
    XCTAssertEqual(geometry.moveCallCount, 0)

    _ = try engine.executeNotation("gk")
    XCTAssertEqual(engine.state.cursor, 0)
    XCTAssertEqual(geometry.moveCallCount, 1)
    XCTAssertNil(geometry.receivedPreferredColumns[0])

    _ = try engine.executeNotation("gj")
    XCTAssertEqual(engine.state.cursor, 5)
    XCTAssertEqual(geometry.moveCallCount, 2)
    XCTAssertEqual(geometry.receivedPreferredColumns[1], 320)
  }

  func testHostCapabilitiesReturnStructuredUnsupportedMessage() {
    let capabilities = VimHostCapabilities([.write])
    XCTAssertTrue(capabilities.supports(.write))
    XCTAssertFalse(capabilities.supports(.writeAndQuit))
    XCTAssertFalse(capabilities.supports(.definition))

    let response = VimHostResponse.rejected(
      .unsupportedCapability(VimHostCapabilities.capability(for: .definition))
    )
    XCTAssertEqual(response.message?.code, "HOST_UNSUPPORTED")
  }

  private func apply(_ edits: [VimTransactionEdit], to source: String) -> String {
    edits.sorted {
      if $0.lowerBound != $1.lowerBound { return $0.lowerBound > $1.lowerBound }
      return $0.upperBound > $1.upperBound
    }.reduce(source) { value, edit in
      (value as NSString).replacingCharacters(
        in: NSRange(location: edit.lowerBound, length: edit.upperBound - edit.lowerBound),
        with: edit.replacement
      )
    }
  }
}

private final class FixedGeometryProvider: @unchecked Sendable, VimVisualGeometryProviding {
  let verticalOffset: Int
  let preferredColumn: Int
  private(set) var moveCallCount = 0
  private(set) var receivedPreferredColumns: [Int?] = []

  init(verticalOffset: Int, preferredColumn: Int) {
    self.verticalOffset = verticalOffset
    self.preferredColumn = preferredColumn
  }

  func visualColumn(atUTF16Offset: Int, logicalLineStart: Int, text: String) -> Int? {
    nil
  }

  func utf16Offset(
    inLogicalLineStartingAt: Int,
    atVisualColumn: Int,
    contentEnd: Int,
    text: String,
    roundForward: Bool
  ) -> Int? {
    nil
  }

  func visualWidth(atUTF16Offset: Int, logicalLineStart: Int, text: String) -> Int? {
    nil
  }

  func moveVertically(
    fromUTF16Offset: Int,
    direction: Int,
    preferredColumn: Int?,
    text: String
  ) -> VimVisualMovement? {
    moveCallCount += 1
    receivedPreferredColumns.append(preferredColumn)
    let offset = direction < 0 ? verticalOffset : min(text.utf16.count, 5)
    return VimVisualMovement(
      utf16Offset: offset,
      preferredColumn: self.preferredColumn
    )
  }
}
