import AppKit
@_spi(Calcite) import EditorVim

@MainActor
enum CalciteVimSelectionPresenter {
  struct Presentation {
    let ranges: [NSRange]
    let primaryRange: NSRange
    let activeRangeIndex: Int
    let shape: VimSelectionShape?

    /// AppKit treats the first selected range as the primary selection. Keep Vim's active row
    /// first while retaining the logical top-to-bottom order in `ranges`.
    var nativeRanges: [NSRange] {
      guard ranges.indices.contains(activeRangeIndex), activeRangeIndex != 0 else {
        return ranges
      }
      var ordered = ranges
      let active = ordered.remove(at: activeRangeIndex)
      ordered.insert(active, at: 0)
      return ordered
    }

    var isVisual: Bool { shape != nil }
  }

  static func presentation(
    for state: VimState,
    selectionSet: VimSelectionSet?
  ) -> Presentation {
    let selections = ranges(for: state, selectionSet: selectionSet)
    let activeIndex = activeRangeIndex(
      in: selections,
      state: state,
      selectionSet: selectionSet
    )
    return Presentation(
      ranges: selections,
      primaryRange: selections.indices.contains(activeIndex)
        ? selections[activeIndex]
        : NSRange(location: max(0, state.cursor), length: 0),
      activeRangeIndex: activeIndex,
      shape: selectionSet?.shape
    )
  }

  static func ranges(
    for state: VimState,
    selectionSet: VimSelectionSet?
  ) -> [NSRange] {
    let length = (state.text as NSString).length
    if let selectionSet, !selectionSet.projectedRanges.isEmpty {
      return selectionSet.projectedRanges.map { range in
        let lower = min(max(range.lowerBound, 0), length)
        let upper = min(max(range.upperBound, lower), length)
        return NSRange(location: lower, length: upper - lower)
      }
    }
    if let visual = state.selection {
      let lower = min(max(visual.lowerBound, 0), length)
      let upper = min(max(visual.upperBound, lower), length)
      return [NSRange(location: lower, length: upper - lower)]
    }
    return [NSRange(location: min(max(state.cursor, 0), length), length: 0)]
  }

  static func primaryRange(
    from selections: [NSRange],
    state: VimState,
    selectionSet: VimSelectionSet?
  ) -> NSRange {
    let index = activeRangeIndex(
      in: selections,
      state: state,
      selectionSet: selectionSet
    )
    guard selections.indices.contains(index) else {
      return NSRange(location: max(0, state.cursor), length: 0)
    }
    return selections[index]
  }

  private static func activeRangeIndex(
    in selections: [NSRange],
    state: VimState,
    selectionSet: VimSelectionSet?
  ) -> Int {
    guard !selections.isEmpty else { return 0 }
    guard selections.count > 1 else { return 0 }
    if let selectionSet {
      let firstLine = min(selectionSet.anchor.line, selectionSet.active.line)
      return min(
        max(0, selectionSet.active.line - firstLine),
        selections.count - 1
      )
    }
    if let index = selections.firstIndex(where: { NSLocationInRange(state.cursor, $0) }) {
      return index
    }
    return 0
  }
}
