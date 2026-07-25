import SwiftUI

/// Top-level workbench chrome for the backend-driven workspace.
struct CalciteWorkbenchRootView<Header: View, Content: View>: View {
  private let header: Header
  private let content: Content

  init(
    @ViewBuilder header: () -> Header,
    @ViewBuilder content: () -> Content
  ) {
    self.header = header()
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
  }
}
