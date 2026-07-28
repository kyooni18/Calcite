@_spi(Calcite) import EditorVim
import Foundation

/// Revision-aware state shared by the SwiftUI representable and its Vim bridge.
/// It distinguishes acknowledged local transactions from authoritative external
/// snapshots without scattering revision flags through the NSTextView delegate.
final class CalciteVimDocumentSynchronizer {
  enum IncomingSnapshot: Equatable {
    case unchanged
    case acknowledgedLocal
    case external
  }

  private(set) var synchronizedText: String
  private(set) var renderedRevision: UInt64
  private(set) var renderedDocumentID: UUID?
  private(set) var expectedLocalRevision: UInt64?
  private(set) var vimRevision: UInt64?
  private(set) var lastTransactionID: VimEditTransactionID?

  init(text: String, revision: UInt64, documentID: UUID? = nil) {
    self.synchronizedText = text
    self.renderedRevision = revision
    self.renderedDocumentID = documentID
  }

  func classify(text: String, revision: UInt64, documentID: UUID? = nil) -> IncomingSnapshot {
    guard revision != renderedRevision || documentID != renderedDocumentID else {
      return .unchanged
    }
    if documentID == renderedDocumentID,
      expectedLocalRevision == revision,
      text == synchronizedText
    {
      return .acknowledgedLocal
    }
    return .external
  }

  @discardableResult
  func reserveLocalRevision(
    after currentRevision: UInt64,
    resultingText: String,
    transactionID: VimEditTransactionID? = nil
  ) -> UInt64 {
    let target = max(renderedRevision, expectedLocalRevision ?? currentRevision) &+ 1
    expectedLocalRevision = target
    synchronizedText = resultingText
    lastTransactionID = transactionID
    return target
  }

  func acknowledge(text: String, revision: UInt64, documentID: UUID? = nil) {
    synchronizedText = text
    renderedRevision = revision
    renderedDocumentID = documentID
    if expectedLocalRevision == revision { expectedLocalRevision = nil }
  }

  func acceptExternal(text: String, revision: UInt64, documentID: UUID? = nil) {
    synchronizedText = text
    renderedRevision = revision
    renderedDocumentID = documentID
    expectedLocalRevision = nil
    vimRevision = nil
    lastTransactionID = nil
  }

  func updateSynchronizedText(_ text: String) {
    synchronizedText = text
  }

  func updateRenderedRevision(_ revision: UInt64) {
    renderedRevision = revision
  }

  func updateExpectedLocalRevision(_ revision: UInt64?) {
    expectedLocalRevision = revision
  }

  func updateVimRevision(_ revision: UInt64?) {
    vimRevision = revision
  }
}
