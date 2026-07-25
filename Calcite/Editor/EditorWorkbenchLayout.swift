import SwiftUI

/// The top-level workbench chrome. The native macOS title bar owns the traffic-light area, while
/// this SwiftUI hierarchy begins below it and remains responsible only for application content.
struct EditorWorkbenchRootView<Header: View, Content: View>: View {
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

/// A strongly typed SwiftUI container for the primary sidebar/detail split.
struct EditorWorkspaceContentView<Sidebar: View, Detail: View>: View {
  @Binding private var sidebarWidth: Double
  private let showsSidebar: Bool
  private let sidebar: Sidebar
  private let detail: Detail

  init(
    sidebarWidth: Binding<Double>,
    showsSidebar: Bool,
    @ViewBuilder sidebar: () -> Sidebar,
    @ViewBuilder detail: () -> Detail
  ) {
    _sidebarWidth = sidebarWidth
    self.showsSidebar = showsSidebar
    self.sidebar = sidebar()
    self.detail = detail()
  }

  var body: some View {
    EditorWorkspaceLayout(
      sidebarWidth: $sidebarWidth,
      showsSidebar: showsSidebar
    ) {
      sidebar
    } detail: {
      detail
    }
  }
}
