import SwiftUI

/// Responsive workbench layout built entirely with SwiftUI.
///
/// The persisted sidebar width is treated as a preference, not a mandatory frame. The
/// visible width is recalculated from the current container so a narrow window never
/// pushes the editor outside its bounds.
struct EditorWorkspaceLayout<Sidebar: View, Detail: View>: View {
  @Binding var sidebarWidth: Double
  let showsSidebar: Bool
  let sidebar: Sidebar
  let detail: Detail

  @State private var dragStartWidth: Double?
  @GestureState private var dragTranslation: CGFloat = 0

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
    GeometryReader { proxy in
      let metrics = LayoutMetrics(
        containerWidth: proxy.size.width,
        preferredSidebarWidth: CGFloat(sidebarWidth),
        showsSidebar: showsSidebar
      )
      let visibleSidebarWidth =
        dragStartWidth.map {
          metrics.clampedSidebarWidth(CGFloat($0) + dragTranslation)
        } ?? metrics.sidebarWidth

      HStack(spacing: 0) {
        if metrics.displaysSidebar {
          sidebar
            .frame(width: visibleSidebarWidth)
            .frame(maxHeight: .infinity)
            .clipped()

          resizeHandle(metrics: metrics)
            .frame(minWidth: 3)
            .onHover(perform: { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                  } else {
                  NSCursor.pop()
                }
              }
            )
        }

        detail
          .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
          .clipped()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
    }
  }

  private func resizeHandle(metrics: LayoutMetrics) -> some View {
    ZStack {
      Rectangle().fill(Color.clear)
      Divider()
    }
    .frame(width: metrics.dividerWidth)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .updating($dragTranslation) { value, state, _ in
          state = value.translation.width
        }
        .onChanged { _ in
          if dragStartWidth == nil {
            dragStartWidth = Double(metrics.sidebarWidth)
          }
        }
        .onEnded { value in
          let start = CGFloat(dragStartWidth ?? Double(metrics.sidebarWidth))
          sidebarWidth = Double(metrics.clampedSidebarWidth(start + value.translation.width))
          dragStartWidth = nil
        }
    )
    .accessibilityLabel("Resize sidebar")
    .accessibilityHint("Drag horizontally to change the sidebar width")
  }
}

private struct LayoutMetrics {
  let containerWidth: CGFloat
  let preferredSidebarWidth: CGFloat
  let showsSidebar: Bool

  let dividerWidth: CGFloat = 10

  var displaysSidebar: Bool {
    showsSidebar && maximumSidebarWidth > minimumUsefulSidebarWidth
  }

  var sidebarWidth: CGFloat {
    clampedSidebarWidth(preferredSidebarWidth)
  }

  func clampedSidebarWidth(_ proposed: CGFloat) -> CGFloat {
    min(max(proposed, minimumSidebarWidth), maximumSidebarWidth)
  }

  private var usableWidth: CGFloat {
    max(0, containerWidth - dividerWidth)
  }

  /// The editor always keeps the larger share of a constrained window. This is derived
  /// from the current container rather than from an absolute editor minimum.
  private var reservedDetailWidth: CGFloat {
    usableWidth * 0.56
  }

  private var maximumSidebarWidth: CGFloat {
    max(0, usableWidth - reservedDetailWidth)
  }

  private var minimumSidebarWidth: CGFloat {
    min(maximumSidebarWidth, usableWidth * 0.1)
  }

  private var minimumUsefulSidebarWidth: CGFloat {
    containerWidth * 0.12
  }
}
