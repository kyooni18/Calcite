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
