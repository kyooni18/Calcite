import AppKit
@_spi(Calcite) import EditorVim

@MainActor
enum CalciteVimSelectionPresenter {
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
    guard let first = selections.first else {
      return NSRange(location: max(0, state.cursor), length: 0)
    }
    guard selections.count > 1 else { return first }
    if let selectionSet {
      let firstLine = min(selectionSet.anchor.line, selectionSet.active.line)
      let activeIndex = min(
        max(0, selectionSet.active.line - firstLine),
        selections.count - 1
      )
      return selections[activeIndex]
    }
    if let active = selections.first(where: { NSLocationInRange(state.cursor, $0) }) {
      return active
    }
    return first
  }
}
