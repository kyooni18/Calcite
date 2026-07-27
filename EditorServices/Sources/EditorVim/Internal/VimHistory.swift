import Foundation

/// A single UTF-16 replacement captured at the point where it was applied.
///
/// Locations are relative to the buffer state immediately before this edit.
/// Applying a transaction forward therefore uses source order, while undo uses
/// reverse order. This representation supports non-contiguous Vim commands
/// without broadening them into one large replacement.
struct VimEditDelta: Sendable, Equatable {
  var location: Int
  var removedText: String
  var insertedText: String

  var removedUTF16Count: Int { removedText.utf16.count }
  var insertedUTF16Count: Int { insertedText.utf16.count }
  var forwardRange: Range<Int> { location..<(location + removedUTF16Count) }
  var backwardRange: Range<Int> { location..<(location + insertedUTF16Count) }

  static func between(_ oldText: String, and newText: String) -> VimEditDelta? {
    guard oldText != newText else { return nil }

    let oldUnits = oldText.utf16
    let newUnits = newText.utf16
    var oldPrefixIndex = oldUnits.startIndex
    var newPrefixIndex = newUnits.startIndex
    var prefix = 0
    while oldPrefixIndex < oldUnits.endIndex, newPrefixIndex < newUnits.endIndex,
      oldUnits[oldPrefixIndex] == newUnits[newPrefixIndex]
    {
      prefix += 1
      oldPrefixIndex = oldUnits.index(after: oldPrefixIndex)
      newPrefixIndex = newUnits.index(after: newPrefixIndex)
    }

    var oldSuffixIndex = oldUnits.endIndex
    var newSuffixIndex = newUnits.endIndex
    var oldSuffix = oldUnits.count
    var newSuffix = newUnits.count
    while oldSuffix > prefix, newSuffix > prefix {
      let previousOld = oldUnits.index(before: oldSuffixIndex)
      let previousNew = newUnits.index(before: newSuffixIndex)
      guard oldUnits[previousOld] == newUnits[previousNew] else { break }
      oldSuffixIndex = previousOld
      newSuffixIndex = previousNew
      oldSuffix -= 1
      newSuffix -= 1
    }

    prefix = normalizedBoundary(prefix, in: oldText, forward: false)
    let newPrefix = normalizedBoundary(prefix, in: newText, forward: false)
    oldSuffix = normalizedBoundary(oldSuffix, in: oldText, forward: true)
    newSuffix = normalizedBoundary(newSuffix, in: newText, forward: true)

    let oldNS = oldText as NSString
    let newNS = newText as NSString
    return VimEditDelta(
      location: prefix,
      removedText: oldNS.substring(with: NSRange(location: prefix, length: oldSuffix - prefix)),
      insertedText: newNS.substring(
        with: NSRange(location: newPrefix, length: newSuffix - newPrefix))
    )
  }

  func applyingForward(to text: String) -> String? {
    replacing(text, range: forwardRange, with: insertedText)
  }

  func applyingBackward(to text: String) -> String? {
    replacing(text, range: backwardRange, with: removedText)
  }

  private func replacing(_ text: String, range: Range<Int>, with replacement: String) -> String? {
    let ns = text as NSString
    guard range.lowerBound >= 0, range.upperBound >= range.lowerBound,
      range.upperBound <= ns.length
    else { return nil }
    return ns.replacingCharacters(
      in: NSRange(location: range.lowerBound, length: range.count),
      with: replacement
    )
  }

  private static func normalizedBoundary(
    _ offset: Int,
    in text: String,
    forward: Bool
  ) -> Int {
    let count = text.utf16.count
    var candidate = max(0, min(offset, count))
    func isBoundary(_ value: Int) -> Bool {
      let index = text.utf16.index(text.utf16.startIndex, offsetBy: value)
      return String.Index(index, within: text) != nil
    }
    if isBoundary(candidate) { return candidate }
    if forward {
      while candidate < count {
        candidate += 1
        if isBoundary(candidate) { return candidate }
      }
      return count
    }
    while candidate > 0 {
      candidate -= 1
      if isBoundary(candidate) { return candidate }
    }
    return 0
  }
}

struct VimChangeTransaction: Sendable {
  var edits: [VimEditDelta]
  var before: VimStateMetadata
  var after: VimStateMetadata

  static func make(
    before: VimState,
    after: VimState,
    edits capturedEdits: [VimEditDelta] = []
  ) -> VimChangeTransaction? {
    guard before.text != after.text else { return nil }
    let edits =
      capturedEdits.isEmpty
      ? VimEditDelta.between(before.text, and: after.text).map { [$0] } ?? []
      : capturedEdits
    guard !edits.isEmpty else { return nil }
    return VimChangeTransaction(
      edits: edits,
      before: VimStateMetadata(before),
      after: VimStateMetadata(after)
    )
  }

  func applyingForward(to text: String) -> String? {
    var result = text
    for edit in edits {
      guard let next = edit.applyingForward(to: result) else { return nil }
      result = next
    }
    return result
  }

  func applyingBackward(to text: String) -> String? {
    var result = text
    for edit in edits.reversed() {
      guard let next = edit.applyingBackward(to: result) else { return nil }
      result = next
    }
    return result
  }
}

/// Compatibility name retained internally while history migrates to ordered,
/// multi-edit transactions.
typealias VimHistoryEntry = VimChangeTransaction
<<<<<<< HEAD

/// A branch-preserving undo history. Creating a change after undo adds a new
/// child instead of discarding the previous redo path.
final class VimUndoNode: @unchecked Sendable {
  let transaction: VimChangeTransaction?
  weak var parent: VimUndoNode?
  var children: [VimUndoNode] = []
  var preferredChildIndex = 0
  let sequence: UInt64
  let timestamp: ContinuousClock.Instant
  let estimatedUTF16Cost: Int

  init(
    transaction: VimChangeTransaction?,
    parent: VimUndoNode?,
    sequence: UInt64,
    timestamp: ContinuousClock.Instant = .now
  ) {
    self.transaction = transaction
    self.parent = parent
    self.sequence = sequence
    self.timestamp = timestamp
    self.estimatedUTF16Cost =
      transaction?.edits.reduce(0) {
        $0 + $1.removedUTF16Count + $1.insertedUTF16Count
      } ?? 0
  }
}

final class VimUndoTree: @unchecked Sendable {
  private(set) var root: VimUndoNode
  private(set) var current: VimUndoNode
  private var nextSequence: UInt64 = 1
  private var retainedUTF16Cost = 0
  var maximumUTF16Cost = 16 * 1_024 * 1_024

  init() {
    let root = VimUndoNode(transaction: nil, parent: nil, sequence: 0)
    self.root = root
    self.current = root
  }

  var canUndo: Bool { current !== root }
  var canRedo: Bool { !current.children.isEmpty }
  var currentSequence: UInt64 { current.sequence }

  func append(_ transaction: VimChangeTransaction) {
    let node = VimUndoNode(
      transaction: transaction,
      parent: current,
      sequence: nextSequence
    )
    nextSequence &+= 1
    current.children.append(node)
    current.preferredChildIndex = current.children.count - 1
    current = node
    retainedUTF16Cost += node.estimatedUTF16Cost
    trimIfNeeded()
  }

  func transactionForUndo() -> VimChangeTransaction? {
    guard current !== root, let transaction = current.transaction else { return nil }
    let child = current
    guard let parent = child.parent else { return nil }
    if let index = parent.children.firstIndex(where: { $0 === child }) {
      parent.preferredChildIndex = index
    }
    current = parent
    return transaction
  }

  func transactionForRedo() -> VimChangeTransaction? {
    guard !current.children.isEmpty else { return nil }
    let index = min(max(0, current.preferredChildIndex), current.children.count - 1)
    let child = current.children[index]
    current = child
    return child.transaction
  }

  func reset() {
    let newRoot = VimUndoNode(transaction: nil, parent: nil, sequence: nextSequence)
    nextSequence &+= 1
    root = newRoot
    current = newRoot
    retainedUTF16Cost = 0
  }

  func branchCount(at node: VimUndoNode? = nil) -> Int {
    (node ?? current).children.count
  }

  func activeTransactions() -> [VimChangeTransaction] {
    var values: [VimChangeTransaction] = []
    var node: VimUndoNode? = current
    while let value = node, value !== root {
      if let transaction = value.transaction { values.append(transaction) }
      node = value.parent
    }
    return values.reversed()
  }

  func preferredRedoTransactions() -> [VimChangeTransaction] {
    var values: [VimChangeTransaction] = []
    var node = current
    while !node.children.isEmpty {
      let index = min(max(0, node.preferredChildIndex), node.children.count - 1)
      node = node.children[index]
      if let transaction = node.transaction { values.append(transaction) }
    }
    return values
  }

  private func trimIfNeeded() {
    guard retainedUTF16Cost > maximumUTF16Cost else { return }
    // Preserve the active ancestry and remove the oldest inactive root branches
    // first. If the active branch alone exceeds the budget, history remains
    // valid and is allowed to temporarily exceed the soft limit.
    let activePath = Set(ObjectIdentifierSequence(from: current))
    var candidates = root.children
      .filter { !activePath.contains(ObjectIdentifier($0)) }
      .sorted { $0.sequence < $1.sequence }
    while retainedUTF16Cost > maximumUTF16Cost, let candidate = candidates.first {
      candidates.removeFirst()
      removeSubtree(candidate)
    }
  }

  private func removeSubtree(_ node: VimUndoNode) {
    guard let parent = node.parent,
      let index = parent.children.firstIndex(where: { $0 === node })
    else { return }
    retainedUTF16Cost -= subtreeCost(node)
    parent.children.remove(at: index)
    if parent.children.isEmpty {
      parent.preferredChildIndex = 0
    } else {
      parent.preferredChildIndex = min(parent.preferredChildIndex, parent.children.count - 1)
    }
  }

  private func subtreeCost(_ node: VimUndoNode) -> Int {
    node.estimatedUTF16Cost + node.children.reduce(0) { $0 + subtreeCost($1) }
  }
}

private struct ObjectIdentifierSequence: Sequence {
  let start: VimUndoNode

  init(from start: VimUndoNode) {
    self.start = start
  }

  func makeIterator() -> AnyIterator<ObjectIdentifier> {
    var node: VimUndoNode? = start
    return AnyIterator {
      guard let value = node else { return nil }
      node = value.parent
      return ObjectIdentifier(value)
    }
  }
}
=======
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
