import EditorCore
import Foundation

public actor VimDocumentSession {
  public let document: EditorDocument
  public let engine: VimEngine

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

    let before = engine.state
    var result = try engine.execute(invocation)
    guard result.didChangeText || result.state.text != before.text else {
      lastTransactionResult = nil
      return result
    }
    guard var transaction = result.transaction else {
      return try await applyFallbackResult(result, before: before, baseSnapshot: baseSnapshot)
    }
    transaction.baseRevision = VimDocumentRevision(UInt64(baseSnapshot.version))
    result.transaction = transaction

    // The document can change while this actor is suspended on the document actor.
    let latestSnapshot = await document.snapshot
    if latestSnapshot.version != baseSnapshot.version {
      return try await applyRebased(
        result,
        transaction: transaction,
        from: baseSnapshot,
        to: latestSnapshot,
        originalCursor: before.cursor
      )
    }

    do {
      let edits = try Self.textEdits(transaction.baseEdits, in: baseSnapshot)
      let applied = try await document.apply(edits)
      let authoritative: TextSnapshot
      if let final = applied.last?.newSnapshot {
        authoritative = final
      } else {
        authoritative = await document.snapshot
      }
      guard authoritative.text == transaction.afterState.text else {
        throw VimDocumentTransactionError.conflict(.authoritativeTextMismatch)
      }
      synchronizedDocumentVersion = authoritative.version
      lastTransactionResult = .accepted(VimDocumentRevision(UInt64(authoritative.version)))
      return result
    } catch {
      let authoritative = await document.snapshot
      engine.synchronize(text: authoritative.text, cursor: before.cursor)
      synchronizedDocumentVersion = authoritative.version
      lastTransactionResult = .desynchronized(VimDocumentRevision(UInt64(authoritative.version)))
      throw error
    }
  }

  private func applyRebased(
    _ originalResult: VimExecutionResult,
    transaction: VimEditTransaction,
    from baseSnapshot: TextSnapshot,
    to latestSnapshot: TextSnapshot,
    originalCursor: Int
  ) async throws -> VimExecutionResult {
    guard let externalDelta = VimEditDelta.between(baseSnapshot.text, and: latestSnapshot.text),
      let rebasedEdits = Self.rebase(
        transaction.baseEdits,
        across: externalDelta,
        originalTextLength: baseSnapshot.utf16Count
      )
    else {
      engine.synchronize(text: latestSnapshot.text, cursor: originalCursor)
      synchronizedDocumentVersion = latestSnapshot.version
      let conflict = VimTransactionConflict.overlappingExternalEdit
      lastTransactionResult = .rejected(conflict)
      throw VimDocumentTransactionError.conflict(conflict)
    }

    let rebasedText = try Self.applying(rebasedEdits, to: latestSnapshot.text)
    var result = originalResult
    var afterState = transaction.afterState
    afterState.text = rebasedText
    afterState.cursor = Self.rebasedOffset(
      transaction.afterState.cursor,
      across: externalDelta,
      resultingText: rebasedText
    )
    afterState.selection = transaction.afterState.selection.map {
      VimSelection(
        Self.rebasedOffset($0.lowerBound, across: externalDelta, resultingText: rebasedText),
        Self.rebasedOffset($0.upperBound, across: externalDelta, resultingText: rebasedText)
      )
    }
    var rebasedTransaction = transaction
    rebasedTransaction.baseRevision = VimDocumentRevision(UInt64(latestSnapshot.version))
    rebasedTransaction.beforeState = VimState(
      text: latestSnapshot.text,
      cursor: Self.rebasedOffset(
        transaction.beforeState.cursor,
        across: externalDelta,
        resultingText: latestSnapshot.text
      ),
      mode: transaction.beforeState.mode,
      selection: transaction.beforeState.selection
    )
    rebasedTransaction.afterState = afterState
    rebasedTransaction.baseEdits = rebasedEdits
    result.state = afterState
    result.transaction = rebasedTransaction

    do {
      let edits = try Self.textEdits(rebasedEdits, in: latestSnapshot)
      let applied = try await document.apply(edits)
      let authoritative: TextSnapshot
      if let final = applied.last?.newSnapshot {
        authoritative = final
      } else {
        authoritative = await document.snapshot
      }
      guard authoritative.text == rebasedText else {
        throw VimDocumentTransactionError.conflict(.authoritativeTextMismatch)
      }
      engine.synchronize(text: authoritative.text, cursor: afterState.cursor)
      synchronizedDocumentVersion = authoritative.version
      lastTransactionResult = .rebased(
        from: VimDocumentRevision(UInt64(baseSnapshot.version)),
        to: VimDocumentRevision(UInt64(authoritative.version))
      )
      return result
    } catch {
      let authoritative = await document.snapshot
      engine.synchronize(text: authoritative.text, cursor: originalCursor)
      synchronizedDocumentVersion = authoritative.version
      lastTransactionResult = .desynchronized(VimDocumentRevision(UInt64(authoritative.version)))
      throw error
    }
  }

  private func applyFallbackResult(
    _ result: VimExecutionResult,
    before: VimState,
    baseSnapshot: TextSnapshot
  ) async throws -> VimExecutionResult {
    let latestSnapshot = await document.snapshot
    guard latestSnapshot.version == baseSnapshot.version else {
      engine.synchronize(text: latestSnapshot.text, cursor: before.cursor)
      synchronizedDocumentVersion = latestSnapshot.version
      let conflict = VimTransactionConflict.staleRevision(
        expected: VimDocumentRevision(UInt64(baseSnapshot.version)),
        actual: VimDocumentRevision(UInt64(latestSnapshot.version))
      )
      lastTransactionResult = .rejected(conflict)
      throw VimDocumentTransactionError.conflict(conflict)
    }
    guard let edit = try Self.incrementalEdit(from: before.text, to: result.state.text) else {
      return result
    }
    do {
      let applied = try await document.apply(edit)
      synchronizedDocumentVersion = applied.newSnapshot.version
      lastTransactionResult = .accepted(
        VimDocumentRevision(UInt64(applied.newSnapshot.version))
      )
      return result
    } catch {
      let authoritative = await document.snapshot
      engine.synchronize(text: authoritative.text, cursor: before.cursor)
      synchronizedDocumentVersion = authoritative.version
      lastTransactionResult = .desynchronized(VimDocumentRevision(UInt64(authoritative.version)))
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

  private static func rebase(
    _ edits: [VimTransactionEdit],
    across external: VimEditDelta,
    originalTextLength: Int
  ) -> [VimTransactionEdit]? {
    let externalRange = external.forwardRange
    let shift = external.insertedUTF16Count - external.removedUTF16Count

    func conflicts(_ edit: VimTransactionEdit) -> Bool {
      let range = edit.range
      if range.isEmpty {
        if externalRange.isEmpty { return range.lowerBound == externalRange.lowerBound }
        return range.lowerBound > externalRange.lowerBound
          && range.lowerBound < externalRange.upperBound
      }
      if externalRange.isEmpty {
        return externalRange.lowerBound > range.lowerBound
          && externalRange.lowerBound < range.upperBound
      }
      return range.overlaps(externalRange)
    }

    func transformed(_ offset: Int, isUpperBound: Bool) -> Int {
      if offset < externalRange.lowerBound { return offset }
      if offset > externalRange.upperBound { return offset + shift }
      if offset == externalRange.lowerBound {
        return isUpperBound && externalRange.isEmpty ? offset + shift : offset
      }
      if offset == externalRange.upperBound { return offset + shift }
      return externalRange.lowerBound + external.insertedUTF16Count
    }

    var result: [VimTransactionEdit] = []
    result.reserveCapacity(edits.count)
    for edit in edits {
      guard edit.lowerBound <= originalTextLength, edit.upperBound <= originalTextLength,
        !conflicts(edit)
      else { return nil }
      let lower = transformed(edit.lowerBound, isUpperBound: false)
      let upper = transformed(edit.upperBound, isUpperBound: true)
      result.append(
        VimTransactionEdit(
          range: lower..<max(lower, upper),
          replacement: edit.replacement
        )
      )
    }
    return result
  }

  private static func applying(_ edits: [VimTransactionEdit], to text: String) throws -> String {
    var value = text
    for edit in edits.sorted(by: {
      if $0.lowerBound != $1.lowerBound { return $0.lowerBound > $1.lowerBound }
      return $0.upperBound > $1.upperBound
    }) {
      let ns = value as NSString
      guard edit.lowerBound >= 0, edit.upperBound >= edit.lowerBound,
        edit.upperBound <= ns.length
      else { throw VimDocumentTransactionError.conflict(.invalidEdit) }
      value = ns.replacingCharacters(
        in: NSRange(location: edit.lowerBound, length: edit.upperBound - edit.lowerBound),
        with: edit.replacement
      )
    }
    return value
  }

  private static func rebasedOffset(
    _ offset: Int,
    across external: VimEditDelta,
    resultingText: String
  ) -> Int {
    let range = external.forwardRange
    let shift = external.insertedUTF16Count - external.removedUTF16Count
    let value: Int
    if offset <= range.lowerBound {
      value = offset
    } else if offset >= range.upperBound {
      value = offset + shift
    } else {
      value = range.lowerBound + external.insertedUTF16Count
    }
    return normalizedVimUTF16Offset(value, in: resultingText)
  }

  private static func incrementalEdit(from oldText: String, to newText: String) throws -> TextEdit?
  {
    guard oldText != newText else { return nil }
    guard let delta = VimEditDelta.between(oldText, and: newText) else { return nil }
    let oldSnapshot = TextSnapshot(text: oldText)
    let start = try oldSnapshot.position(atUTF16Offset: delta.location)
    let end = try oldSnapshot.position(
      atUTF16Offset: delta.location + delta.removedUTF16Count
    )
    return TextEdit(
      range: EditorTextRange(start: start, end: end),
      replacement: delta.insertedText
    )
  }
}
