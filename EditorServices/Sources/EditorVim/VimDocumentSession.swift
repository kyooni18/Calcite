import EditorCore
import Foundation

public actor VimDocumentSession {
  public let document: EditorDocument
  public let engine: VimEngine

  private let transactionCoordinator = VimTransactionCoordinator()
  private var synchronizedDocumentVersion: Int
  @_spi(Calcite) public private(set) var lastTransactionResult: VimTransactionResult?

  public init(document: EditorDocument, leader: String = "\\", localLeader: String = "\\") async {
    self.document = document
    let snapshot = await document.snapshot
    self.engine = VimEngine(text: snapshot.text, leader: leader, localLeader: localLeader)
    self.synchronizedDocumentVersion = snapshot.version
  }

  public func synchronizeFromDocument() async {
    let snapshot = await document.snapshot
    engine.synchronize(text: snapshot.text)
    synchronizedDocumentVersion = snapshot.version
    lastTransactionResult = nil
  }

  @discardableResult
  public func execute(_ invocation: VimInvocation) async throws -> VimExecutionResult {
    let baseSnapshot = await document.snapshot
    if baseSnapshot.version != synchronizedDocumentVersion
      || baseSnapshot.text != engine.state.text
    {
      engine.synchronize(text: baseSnapshot.text, cursor: engine.state.cursor)
      synchronizedDocumentVersion = baseSnapshot.version
    }

    let originalCursor = engine.state.cursor
    var result = try engine.execute(invocation)
    guard result.didChangeText || result.state.text != baseSnapshot.text else {
      lastTransactionResult = nil
      return result
    }
    guard var transaction = result.transaction else {
      let authoritative = await document.snapshot
      engine.synchronize(text: authoritative.text, cursor: originalCursor)
      synchronizedDocumentVersion = authoritative.version
      let conflict = VimTransactionConflict.invalidEdit
      lastTransactionResult = .rejected(conflict)
      throw VimDocumentTransactionError.conflict(conflict)
    }

    let baseRevision = VimDocumentRevision(UInt64(baseSnapshot.version))
    transaction.baseRevision = baseRevision
    let latestSnapshot = await document.snapshot

    let prepared: VimPreparedCommit
    do {
      prepared = try transactionCoordinator.prepare(
        transaction,
        base: VimTransactionSnapshot(revision: baseRevision, text: baseSnapshot.text),
        current: VimTransactionSnapshot(
          revision: VimDocumentRevision(UInt64(latestSnapshot.version)),
          text: latestSnapshot.text
        )
      )
    } catch let error as VimDocumentTransactionError {
      engine.synchronize(text: latestSnapshot.text, cursor: originalCursor)
      synchronizedDocumentVersion = latestSnapshot.version
      if case .conflict(let conflict) = error {
        lastTransactionResult = .rejected(conflict)
      }
      throw error
    }

    result.state = prepared.transaction.afterState
    result.transaction = prepared.transaction

    do {
      let edits = try Self.textEdits(prepared.transaction.baseEdits, in: latestSnapshot)
      guard !edits.isEmpty else {
        throw VimDocumentTransactionError.conflict(.invalidEdit)
      }
      let applied = try await document.apply(edits)
      let authoritative: TextSnapshot
      if let final = applied.last?.newSnapshot {
        authoritative = final
      } else {
        authoritative = await document.snapshot
      }
      guard authoritative.text == prepared.transaction.afterState.text else {
        throw VimDocumentTransactionError.conflict(.authoritativeTextMismatch)
      }

      engine.synchronize(
        text: authoritative.text,
        cursor: prepared.transaction.afterState.cursor
      )
      synchronizedDocumentVersion = authoritative.version
      switch prepared.disposition {
      case .accepted:
        lastTransactionResult = .accepted(
          VimDocumentRevision(UInt64(authoritative.version))
        )
      case .rebased(let from, _):
        lastTransactionResult = .rebased(
          from: from,
          to: VimDocumentRevision(UInt64(authoritative.version))
        )
      }
      return result
    } catch {
      let authoritative = await document.snapshot
      engine.synchronize(text: authoritative.text, cursor: originalCursor)
      synchronizedDocumentVersion = authoritative.version
      lastTransactionResult = .desynchronized(
        VimDocumentRevision(UInt64(authoritative.version))
      )
      throw error
    }
  }

  private static func textEdits(
    _ edits: [VimTransactionEdit],
    in snapshot: TextSnapshot
  ) throws -> [TextEdit] {
    try edits.map { edit in
      let start = try snapshot.position(atUTF16Offset: edit.lowerBound)
      let end = try snapshot.position(atUTF16Offset: edit.upperBound)
      return TextEdit(
        range: EditorTextRange(start: start, end: end),
        replacement: edit.replacement
      )
    }
  }
}
