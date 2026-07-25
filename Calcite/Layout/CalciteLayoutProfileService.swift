import AppKit

/// Central policy for the default geometry of a window's sectional workbench.
///
/// Divider positions changed by the user continue to be stored by `NSSplitView`; this service
/// is consulted only when a new split has no saved position yet.
@MainActor
final class CalciteLayoutProfileService {
  /// Keeps the bottom panel available without taking equal space from the editor by default.
  let defaultBottomPanelFraction: CGFloat

  init(defaultBottomPanelFraction: CGFloat = 0.22) {
    self.defaultBottomPanelFraction = defaultBottomPanelFraction
  }

  func defaultSecondaryFraction(
    for axis: MainSectionSplitAxis?,
    childCount: Int
  ) -> CGFloat? {
    guard axis == .vertical, childCount == 2 else { return nil }
    return defaultBottomPanelFraction
  }
}
