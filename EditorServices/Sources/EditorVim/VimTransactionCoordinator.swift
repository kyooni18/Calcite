import Foundation

/// An immutable document state used to validate and, when safe, rebase a Vim edit.
@_spi(Calcite)
public struct VimTransactionSnapshot: Hashable, Sendable {
  public var revision: VimDocumentRevision
  public var text: String

  public init(revision: VimDocumentRevision, text: String) {
    self.revision = revision
    self.text = text
  }
}

/// One external replacement expressed against the original transaction base text.
@_spi(Calcite)
public struct VimExternalTextChange: Hashable, Sendable {
  public var range: Range<Int>
  public var replacement: String

  public init(range: Range<Int>, replacement: String) {
    self.range = range
    self.replacement = replacement
  }

  public var insertedUTF16Count: Int { replacement.utf16.count }
  public var removedUTF16Count: Int { range.count }
  public var shift: Int { insertedUTF16Count - removedUTF16Count }
}

/// A normalized, non-overlapping set of external changes in UTF-16 base coordinates.
@_spi(Calcite)
public struct VimTextChangeSet: Hashable, Sendable {
  public var changes: [VimExternalTextChange]

  public init(changes: [VimExternalTextChange]) {
    self.changes = changes.sorted {
      if $0.range.lowerBound != $1.range.lowerBound {
        return $0.range.lowerBound < $1.range.lowerBound
      }
      return $0.range.upperBound < $1.range.upperBound
    }
  }

  public static func between(_ base: String, and current: String) -> Self {
    guard base != current else { return Self(changes: []) }

    let source = Array(base.utf16)
    let target = Array(current.utf16)
    let difference = target.difference(from: source)
    var removals = Set<Int>()
    var insertions = Set<Int>()
    for change in difference {
      switch change {
      case .remove(let offset, _, _): removals.insert(offset)
      case .insert(let offset, _, _): insertions.insert(offset)
      }
    }

    var sourceIndex = 0
    var targetIndex = 0
    var edits: [VimExternalTextChange] = []
    while sourceIndex < source.count || targetIndex < target.count {
      if sourceIndex < source.count,
        targetIndex < target.count,
        !removals.contains(sourceIndex),
        !insertions.contains(targetIndex),
        source[sourceIndex] == target[targetIndex]
      {
        sourceIndex += 1
        targetIndex += 1
        continue
      }

      let start = sourceIndex
      var replacement: [UInt16] = []
      var progressed = false
      while true {
        if targetIndex < target.count, insertions.contains(targetIndex) {
          replacement.append(target[targetIndex])
          targetIndex += 1
          progressed = true
          continue
        }
        if sourceIndex < source.count, removals.contains(sourceIndex) {
          sourceIndex += 1
          progressed = true
          continue
        }
        break
      }

      guard progressed else {
        // CollectionDifference should always provide a walkable script. Keep a
        // conservative single replacement as a safety net rather than emitting
        // a malformed multi-edit set.
        if let delta = VimEditDelta.between(base, and: current) {
          return Self(changes: [
            VimExternalTextChange(range: delta.forwardRange, replacement: delta.insertedText)
          ])
        }
        return Self(changes: [])
      }
      edits.append(
        VimExternalTextChange(
          range: start..<sourceIndex,
          replacement: String(decoding: replacement, as: UTF16.self)
        )
      )
    }

    let result = Self(changes: edits)
    guard result.applying(to: base) == current else {
      if let delta = VimEditDelta.between(base, and: current) {
        return Self(changes: [
          VimExternalTextChange(range: delta.forwardRange, replacement: delta.insertedText)
        ])
      }
      return Self(changes: [])
    }
    return result
  }

  public func applying(to text: String) -> String? {
    var value = text
    for change in changes.sorted(by: Self.reverseEditOrder) {
      let ns = value as NSString
      guard change.range.lowerBound >= 0,
        change.range.upperBound >= change.range.lowerBound,
        change.range.upperBound <= ns.length
      else { return nil }
      value = ns.replacingCharacters(
        in: NSRange(location: change.range.lowerBound, length: change.range.count),
        with: change.replacement
      )
    }
    return value
  }

  private static func reverseEditOrder(
    _ lhs: VimExternalTextChange,
    _ rhs: VimExternalTextChange
  ) -> Bool {
    if lhs.range.lowerBound != rhs.range.lowerBound {
      return lhs.range.lowerBound > rhs.range.lowerBound
    }
    return lhs.range.upperBound > rhs.range.upperBound
  }
}

@_spi(Calcite)
public enum VimPreparedCommitDisposition: Hashable, Sendable {
  case accepted(at: VimDocumentRevision)
  case rebased(from: VimDocumentRevision, to: VimDocumentRevision)
}

@_spi(Calcite)
public struct VimPreparedCommit: Hashable, Sendable {
  public var transaction: VimEditTransaction
  public var disposition: VimPreparedCommitDisposition

  public init(
    transaction: VimEditTransaction,
    disposition: VimPreparedCommitDisposition
  ) {
    self.transaction = transaction
    self.disposition = disposition
  }
}

/// The single validation and rebase policy used by document-backed and Calcite-hosted Vim edits.
@_spi(Calcite)
public struct VimTransactionCoordinator: Sendable {
  public init() {}

  public func prepare(
    _ transaction: VimEditTransaction,
    base: VimTransactionSnapshot,
    current: VimTransactionSnapshot
  ) throws -> VimPreparedCommit {
    if let expected = transaction.baseRevision, expected != base.revision {
      throw VimDocumentTransactionError.conflict(
        .staleRevision(expected: expected, actual: base.revision)
      )
    }
    guard transaction.beforeState.text == base.text,
      Self.applying(transaction.baseEdits, to: base.text) == transaction.afterState.text
    else {
      throw VimDocumentTransactionError.conflict(.invalidEdit)
    }

    if base.text == current.text {
      var accepted = transaction
      accepted.baseRevision = current.revision
      return VimPreparedCommit(
        transaction: accepted,
        disposition: .accepted(at: current.revision)
      )
    }

    let external = VimTextChangeSet.between(base.text, and: current.text)
    guard external.applying(to: base.text) == current.text,
      let rebasedEdits = Self.rebase(transaction.baseEdits, across: external)
    else {
      throw VimDocumentTransactionError.conflict(.overlappingExternalEdit)
    }
    guard let rebasedText = Self.applying(rebasedEdits, to: current.text) else {
      throw VimDocumentTransactionError.conflict(.invalidEdit)
    }

    var rebased = transaction
    rebased.baseRevision = current.revision
    rebased.beforeState = VimState(
      text: current.text,
      cursor: Self.rebasedOffset(
        transaction.beforeState.cursor,
        across: external,
        resultingText: current.text
      ),
      mode: transaction.beforeState.mode,
      selection: transaction.beforeState.selection.map {
        VimSelection(
          Self.rebasedOffset($0.lowerBound, across: external, resultingText: current.text),
          Self.rebasedOffset($0.upperBound, across: external, resultingText: current.text)
        )
      }
    )
    let rebasedAfterSelection = transaction.afterState.selection.map {
      VimSelection(
        Self.rebasedOffset($0.lowerBound, across: external, resultingText: rebasedText),
        Self.rebasedOffset($0.upperBound, across: external, resultingText: rebasedText)
      )
    }
    rebased.afterState = VimState(
      text: rebasedText,
      cursor: Self.rebasedOffset(
        transaction.afterState.cursor,
        across: external,
        resultingText: rebasedText
      ),
      mode: transaction.afterState.mode,
      selection: rebasedAfterSelection
    )
    let atomicOrder = rebasedEdits.sorted(by: Self.reverseEditOrder)
    rebased.baseEdits = atomicOrder
    rebased.sequentialEdits = atomicOrder

    return VimPreparedCommit(
      transaction: rebased,
      disposition: .rebased(from: base.revision, to: current.revision)
    )
  }

  public static func applying(
    _ edits: [VimTransactionEdit],
    to text: String
  ) -> String? {
    var value = text
    let sorted = edits.sorted(by: reverseEditOrder)
    for pair in zip(sorted, sorted.dropFirst()) {
      if pair.1.upperBound > pair.0.lowerBound { return nil }
    }
    for edit in sorted {
      let ns = value as NSString
      guard edit.lowerBound >= 0,
        edit.upperBound >= edit.lowerBound,
        edit.upperBound <= ns.length
      else { return nil }
      value = ns.replacingCharacters(
        in: NSRange(location: edit.lowerBound, length: edit.range.count),
        with: edit.replacement
      )
    }
    return value
  }

  private static func rebase(
    _ edits: [VimTransactionEdit],
    across external: VimTextChangeSet
  ) -> [VimTransactionEdit]? {
    var result: [VimTransactionEdit] = []
    result.reserveCapacity(edits.count)
    for edit in edits {
      guard edit.lowerBound >= 0, edit.upperBound >= edit.lowerBound else { return nil }
      for change in external.changes where conflicts(edit, with: change) {
        return nil
      }
      let lower = transformedLowerBound(edit.lowerBound, across: external)
      let upper = transformedUpperBound(edit.upperBound, across: external)
      guard lower <= upper else { return nil }
      result.append(VimTransactionEdit(range: lower..<upper, replacement: edit.replacement))
    }
    return result
  }

  private static func conflicts(
    _ edit: VimTransactionEdit,
    with external: VimExternalTextChange
  ) -> Bool {
    let lhs = edit.range
    let rhs = external.range
    if lhs.isEmpty, rhs.isEmpty {
      return lhs.lowerBound == rhs.lowerBound
    }
    if lhs.isEmpty {
      return lhs.lowerBound > rhs.lowerBound && lhs.lowerBound < rhs.upperBound
    }
    if rhs.isEmpty {
      return rhs.lowerBound > lhs.lowerBound && rhs.lowerBound < lhs.upperBound
    }
    return lhs.overlaps(rhs)
  }

  private static func transformedLowerBound(
    _ offset: Int,
    across external: VimTextChangeSet
  ) -> Int {
    var shift = 0
    for change in external.changes {
      if change.range.isEmpty {
        if change.range.lowerBound <= offset { shift += change.shift }
      } else if change.range.upperBound <= offset {
        shift += change.shift
      }
    }
    return offset + shift
  }

  private static func transformedUpperBound(
    _ offset: Int,
    across external: VimTextChangeSet
  ) -> Int {
    var shift = 0
    for change in external.changes {
      if change.range.isEmpty {
        if change.range.lowerBound < offset { shift += change.shift }
      } else if change.range.upperBound <= offset {
        shift += change.shift
      }
    }
    return offset + shift
  }

  private static func rebasedOffset(
    _ offset: Int,
    across external: VimTextChangeSet,
    resultingText: String
  ) -> Int {
    var mapped = offset
    for change in external.changes {
      if change.range.isEmpty {
        if change.range.lowerBound <= offset { mapped += change.shift }
      } else if offset >= change.range.upperBound {
        mapped += change.shift
      } else if offset > change.range.lowerBound {
        mapped = change.range.lowerBound + change.insertedUTF16Count
      }
    }
    return normalizedVimUTF16Offset(mapped, in: resultingText)
  }

  private static func reverseEditOrder(
    _ lhs: VimTransactionEdit,
    _ rhs: VimTransactionEdit
  ) -> Bool {
    if lhs.lowerBound != rhs.lowerBound { return lhs.lowerBound > rhs.lowerBound }
    return lhs.upperBound > rhs.upperBound
  }
}
