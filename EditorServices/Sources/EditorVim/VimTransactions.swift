import Foundation

/// A stable identifier for one logical Vim mutation.
@_spi(Calcite)
public struct VimEditTransactionID: Hashable, Sendable, Codable {
  public var rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

/// A host or document revision associated with a Vim transaction.
@_spi(Calcite)
public struct VimDocumentRevision: Hashable, Sendable, Codable, Comparable {
  public var value: UInt64

  public init(_ value: UInt64) {
    self.value = value
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.value < rhs.value
  }
}

@_spi(Calcite)
public enum VimEditOrigin: Hashable, Sendable, Codable {
  case vim
  case nativeInput
  case inputMethod
  case formatter
  case languageServer
  case reload
  case external(String)
}

/// A UTF-16 replacement. Sequential edits are expressed against the text that
/// exists immediately before each edit. Base edits are all expressed against
/// the transaction's initial snapshot.
@_spi(Calcite)
public struct VimTransactionEdit: Hashable, Sendable, Codable {
  public var lowerBound: Int
  public var upperBound: Int
  public var replacement: String

  public init(range: Range<Int>, replacement: String) {
    self.lowerBound = range.lowerBound
    self.upperBound = range.upperBound
    self.replacement = replacement
  }

  public var range: Range<Int> {
    lowerBound..<upperBound
  }
}

@_spi(Calcite)
public struct VimRepeatMetadata: Hashable, Sendable, Codable {
  public var isRepeatable: Bool
  public var finishesInInsertMode: Bool

  public init(isRepeatable: Bool, finishesInInsertMode: Bool) {
    self.isRepeatable = isRepeatable
    self.finishesInInsertMode = finishesInInsertMode
  }
}

/// One logical Vim command, including its exact edit script and a normalized
/// non-overlapping batch suitable for an atomic host document API.
@_spi(Calcite)
public struct VimEditTransaction: Hashable, Sendable {
  public var id: VimEditTransactionID
  public var baseRevision: VimDocumentRevision?
  public var origin: VimEditOrigin
  public var beforeState: VimState
  public var afterState: VimState
  public var sequentialEdits: [VimTransactionEdit]
  public var baseEdits: [VimTransactionEdit]
  public var repeatMetadata: VimRepeatMetadata

  public init(
    id: VimEditTransactionID = VimEditTransactionID(),
    baseRevision: VimDocumentRevision? = nil,
    origin: VimEditOrigin = .vim,
    beforeState: VimState,
    afterState: VimState,
    sequentialEdits: [VimTransactionEdit],
    baseEdits: [VimTransactionEdit],
    repeatMetadata: VimRepeatMetadata
  ) {
    self.id = id
    self.baseRevision = baseRevision
    self.origin = origin
    self.beforeState = beforeState
    self.afterState = afterState
    self.sequentialEdits = sequentialEdits
    self.baseEdits = baseEdits
    self.repeatMetadata = repeatMetadata
  }

  public func withBaseRevision(_ revision: VimDocumentRevision) -> Self {
    var copy = self
    copy.baseRevision = revision
    return copy
  }

  public static func merging(
    _ first: VimEditTransaction?,
    _ second: VimEditTransaction?
  ) -> VimEditTransaction? {
    switch (first, second) {
    case (.none, .none):
      return nil
    case (.some(let value), .none), (.none, .some(let value)):
      return value
    case (.some(let first), .some(let second)):
      let sequential = first.sequentialEdits + second.sequentialEdits
      let base =
        normalizedBaseEdits(
          source: first.beforeState.text,
          expected: second.afterState.text,
          sequentialEdits: sequential
        )
        ?? fallbackBaseEdit(
          source: first.beforeState.text,
          expected: second.afterState.text
        )
      return VimEditTransaction(
        id: first.id,
        baseRevision: first.baseRevision,
        origin: first.origin,
        beforeState: first.beforeState,
        afterState: second.afterState,
        sequentialEdits: sequential,
        baseEdits: base,
        repeatMetadata: second.repeatMetadata.isRepeatable
          ? second.repeatMetadata
          : first.repeatMetadata
      )
    }
  }
}

@_spi(Calcite)
public enum VimTransactionConflict: Hashable, Sendable {
  case staleRevision(expected: VimDocumentRevision, actual: VimDocumentRevision)
  case overlappingExternalEdit
  case invalidEdit
  case authoritativeTextMismatch
}

@_spi(Calcite)
public enum VimTransactionResult: Hashable, Sendable {
  case accepted(VimDocumentRevision)
  case rebased(from: VimDocumentRevision, to: VimDocumentRevision)
  case rejected(VimTransactionConflict)
  case desynchronized(VimDocumentRevision)
}

// MARK: - Sequential-to-base edit normalization

extension VimEditTransaction {
  static func make(
    before: VimState,
    after: VimState,
    deltas: [VimEditDelta],
    repeatRecord: VimRepeatRecord?
  ) -> VimEditTransaction? {
    guard before.text != after.text else { return nil }
    let sequential = deltas.map {
      VimTransactionEdit(range: $0.forwardRange, replacement: $0.insertedText)
    }
    let base =
      normalizedBaseEdits(
        source: before.text,
        expected: after.text,
        sequentialEdits: sequential
      ) ?? fallbackBaseEdit(source: before.text, expected: after.text)
    return VimEditTransaction(
      beforeState: before,
      afterState: after,
      sequentialEdits: sequential,
      baseEdits: base,
      repeatMetadata: VimRepeatMetadata(
        isRepeatable: repeatRecord != nil,
        finishesInInsertMode: repeatRecord?.finishesInInsertMode ?? false
      )
    )
  }

  private enum Segment {
    case source(Range<Int>)
    case inserted(String)

    var utf16Count: Int {
      switch self {
      case .source(let range): return range.count
      case .inserted(let value): return value.utf16.count
      }
    }
  }

  private static func normalizedBaseEdits(
    source: String,
    expected: String,
    sequentialEdits: [VimTransactionEdit]
  ) -> [VimTransactionEdit]? {
    guard !sequentialEdits.isEmpty else { return nil }
    var segments: [Segment] = source.isEmpty ? [] : [.source(0..<source.utf16.count)]

    for edit in sequentialEdits {
      guard edit.lowerBound >= 0, edit.upperBound >= edit.lowerBound else { return nil }
      let currentLength = segments.reduce(0) { $0 + $1.utf16Count }
      guard edit.upperBound <= currentLength else { return nil }
      guard splitSegments(&segments, at: edit.lowerBound),
        splitSegments(&segments, at: edit.upperBound)
      else { return nil }

      var offset = 0
      var firstRemovalIndex: Int?
      var lastRemovalIndex: Int?
      for index in segments.indices {
        let next = offset + segments[index].utf16Count
        if offset >= edit.lowerBound, next <= edit.upperBound, next > offset {
          firstRemovalIndex = firstRemovalIndex ?? index
          lastRemovalIndex = index
        }
        offset = next
      }

      let insertionIndex: Int
      if let firstRemovalIndex, let lastRemovalIndex {
        segments.removeSubrange(firstRemovalIndex...lastRemovalIndex)
        insertionIndex = firstRemovalIndex
      } else {
        insertionIndex = indexAtBoundary(edit.lowerBound, in: segments)
      }
      if !edit.replacement.isEmpty {
        segments.insert(.inserted(edit.replacement), at: insertionIndex)
      }
      coalesceInsertedSegments(&segments)
    }

    guard render(segments, source: source) == expected else { return nil }

    var edits: [VimTransactionEdit] = []
    var sourceCursor = 0
    var pendingReplacement = ""
    for segment in segments {
      switch segment {
      case .inserted(let value):
        pendingReplacement += value
      case .source(let range):
        guard range.lowerBound >= sourceCursor else { return nil }
        if range.lowerBound > sourceCursor || !pendingReplacement.isEmpty {
          edits.append(
            VimTransactionEdit(
              range: sourceCursor..<range.lowerBound,
              replacement: pendingReplacement
            )
          )
          pendingReplacement = ""
        }
        sourceCursor = range.upperBound
      }
    }
    if sourceCursor < source.utf16.count || !pendingReplacement.isEmpty {
      edits.append(
        VimTransactionEdit(
          range: sourceCursor..<source.utf16.count,
          replacement: pendingReplacement
        )
      )
    }
    return edits
  }

  private static func splitSegments(_ segments: inout [Segment], at target: Int) -> Bool {
    if target == 0 { return true }
    var offset = 0
    for index in segments.indices {
      let length = segments[index].utf16Count
      let next = offset + length
      if target == offset || target == next { return true }
      guard target > offset, target < next else {
        offset = next
        continue
      }
      let local = target - offset
      switch segments[index] {
      case .source(let range):
        let split = range.lowerBound + local
        segments.replaceSubrange(
          index...index,
          with: [
            .source(range.lowerBound..<split),
            .source(split..<range.upperBound),
          ])
      case .inserted(let value):
        let ns = value as NSString
        let left = ns.substring(with: NSRange(location: 0, length: local))
        let right = ns.substring(with: NSRange(location: local, length: ns.length - local))
        segments.replaceSubrange(index...index, with: [.inserted(left), .inserted(right)])
      }
      return true
    }
    return target == offset
  }

  private static func indexAtBoundary(_ target: Int, in segments: [Segment]) -> Int {
    var offset = 0
    for (index, segment) in segments.enumerated() {
      if target == offset { return index }
      offset += segment.utf16Count
      if target == offset { return index + 1 }
    }
    return segments.count
  }

  private static func coalesceInsertedSegments(_ segments: inout [Segment]) {
    var result: [Segment] = []
    for segment in segments {
      if case .inserted(let value) = segment, value.isEmpty { continue }
      if case .inserted(let value) = segment,
        case .inserted(let previous)? = result.last
      {
        result[result.count - 1] = .inserted(previous + value)
      } else {
        result.append(segment)
      }
    }
    segments = result
  }

  private static func render(_ segments: [Segment], source: String) -> String {
    let ns = source as NSString
    var value = ""
    for segment in segments {
      switch segment {
      case .source(let range):
        value += ns.substring(
          with: NSRange(location: range.lowerBound, length: range.count)
        )
      case .inserted(let inserted):
        value += inserted
      }
    }
    return value
  }

  private static func fallbackBaseEdit(source: String, expected: String) -> [VimTransactionEdit] {
    guard let delta = VimEditDelta.between(source, and: expected) else { return [] }
    return [VimTransactionEdit(range: delta.forwardRange, replacement: delta.insertedText)]
  }
}

@_spi(Calcite)
public enum VimDocumentTransactionError: Error, Equatable, Sendable {
  case conflict(VimTransactionConflict)
}
