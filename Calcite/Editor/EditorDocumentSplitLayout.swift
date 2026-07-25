import SwiftUI

/// Hosts one or two editor panes without imposing absolute pane dimensions.
struct EditorDocumentSplitLayout<Primary: View, Secondary: View>: View {
  let orientation: EditorSplitOrientation?
  let primary: Primary
  let secondary: Secondary

  init(
    orientation: EditorSplitOrientation?,
    @ViewBuilder primary: () -> Primary,
    @ViewBuilder secondary: () -> Secondary
  ) {
    self.orientation = orientation
    self.primary = primary()
    self.secondary = secondary()
  }

  @ViewBuilder
  var body: some View {
    switch orientation {
    case .right:
      HSplitView {
        flexible(primary)
        flexible(secondary)
      }
    case .below:
      VSplitView {
        flexible(primary)
        flexible(secondary)
      }
    case nil:
      flexible(primary)
    }
  }

  private func flexible<Content: View>(_ content: Content) -> some View {
    content
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
      .clipped()
  }
}
