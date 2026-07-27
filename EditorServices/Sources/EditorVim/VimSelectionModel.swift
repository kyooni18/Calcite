import Foundation

@_spi(Calcite)
public enum VimSelectionShape: String, Hashable, Sendable, Codable {
  case character
  case line
  case block
}

@_spi(Calcite)
public struct VimSelectionEndpoint: Hashable, Sendable {
  public var utf16Offset: Int
  public var line: Int
  public var virtualColumn: Int

  public init(utf16Offset: Int, line: Int, virtualColumn: Int) {
    self.utf16Offset = max(0, utf16Offset)
    self.line = max(1, line)
    self.virtualColumn = max(0, virtualColumn)
  }
}

@_spi(Calcite)
public struct VimSelectionSet: Hashable, Sendable {
  public var anchor: VimSelectionEndpoint
  public var active: VimSelectionEndpoint
  public var shape: VimSelectionShape
  public var projectedRanges: [Range<Int>]

  public init(
    anchor: VimSelectionEndpoint,
    active: VimSelectionEndpoint,
    shape: VimSelectionShape,
    projectedRanges: [Range<Int>]
  ) {
    self.anchor = anchor
    self.active = active
    self.shape = shape
    self.projectedRanges = projectedRanges
  }
}

@_spi(Calcite)
public struct VimVisualSelectionSnapshot: Hashable, Sendable {
  public var shape: VimSelectionShape
  public var characterCount: Int
  public var lineCount: Int
  public var width: Int?
  public var height: Int
  public var virtualColumnRange: Range<Int>?
  public var projectedRanges: [Range<Int>]
  public var isBlockInsertion: Bool
  public var isBlockAppend: Bool

  public init(
    shape: VimSelectionShape,
    characterCount: Int,
    lineCount: Int,
    width: Int? = nil,
    height: Int,
    virtualColumnRange: Range<Int>? = nil,
    projectedRanges: [Range<Int>],
    isBlockInsertion: Bool = false,
    isBlockAppend: Bool = false
  ) {
    self.shape = shape
    self.characterCount = max(0, characterCount)
    self.lineCount = max(0, lineCount)
    self.width = width.map { max(0, $0) }
    self.height = max(0, height)
    self.virtualColumnRange = virtualColumnRange
    self.projectedRanges = projectedRanges
    self.isBlockInsertion = isBlockInsertion
    self.isBlockAppend = isBlockAppend
  }
}

struct VimBlockInsertSession: Sendable {
  var originalText: String
  var primaryOffset: Int
  var targetOffsets: [Int]
  var append: Bool
  var height: Int
}

extension VimEngine {
  @_spi(Calcite)
  public var selectionSet: VimSelectionSet? {
    lock.withLock { selectionSetUnlocked() }
  }

  func selectionSetUnlocked() -> VimSelectionSet? {
    guard let anchorOffset = visualAnchor,
      state.mode == .visualCharacter || state.mode == .visualLine
    else { return nil }

    lineIndex.synchronize(with: state.text)
    let activeOffset = clamp(state.cursor)
    let anchorStart = lineStart(at: anchorOffset)
    let activeStart = lineStart(at: activeOffset)
    let anchorLine = lineIndex.oneBasedLine(
      containing: anchorOffset,
      textLength: state.text.utf16.count
    )
    let activeLine = lineIndex.oneBasedLine(
      containing: activeOffset,
      textLength: state.text.utf16.count
    )
    let anchorColumn = displayColumn(from: anchorStart, to: anchorOffset)
    let activeColumn = displayColumn(from: activeStart, to: activeOffset)
    let shape = visualSelectionShape
    let ranges = projectedVisualRanges()

    return VimSelectionSet(
      anchor: VimSelectionEndpoint(
        utf16Offset: anchorOffset,
        line: anchorLine,
        virtualColumn: anchorColumn
      ),
      active: VimSelectionEndpoint(
        utf16Offset: activeOffset,
        line: activeLine,
        virtualColumn: activeColumn
      ),
      shape: shape,
      projectedRanges: ranges
    )
  }

  func visualSelectionSnapshotUnlocked() -> VimVisualSelectionSnapshot? {
    guard let selection = selectionSetUnlocked() else {
      if let session = blockInsertSession {
        return VimVisualSelectionSnapshot(
          shape: .block,
          characterCount: 0,
          lineCount: session.height,
          width: nil,
          height: session.height,
          projectedRanges: [],
          isBlockInsertion: !session.append,
          isBlockAppend: session.append
        )
      }
      return nil
    }

    let characterCount = selection.projectedRanges.reduce(0) { partial, range in
      partial + substring(range).count
    }
    let lineCount = max(1, selection.projectedRanges.count)
    if selection.shape == .block {
      let fallbackColumns =
        min(
          selection.anchor.virtualColumn,
          selection.active.virtualColumn
        )..<max(selection.anchor.virtualColumn, selection.active.virtualColumn) + 1
      let columns = visualBlockColumnBounds() ?? fallbackColumns
      return VimVisualSelectionSnapshot(
        shape: .block,
        characterCount: characterCount,
        lineCount: lineCount,
        width: columns.count,
        height: lineCount,
        virtualColumnRange: columns,
        projectedRanges: selection.projectedRanges
      )
    }
    return VimVisualSelectionSnapshot(
      shape: selection.shape,
      characterCount: characterCount,
      lineCount: lineCount,
      height: lineCount,
      projectedRanges: selection.projectedRanges
    )
  }
}
