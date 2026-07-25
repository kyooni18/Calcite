import SwiftUI

/// A responsive SwiftUI splitter for the editor and bottom panel.
///
/// The stored panel height remains a preference. Its effective height is clamped to a
/// fraction of the current container, so shrinking the window cannot collapse both panes.
struct EditorBottomPanelLayout<EditorContent: View, PanelContent: View>: View {
  @Binding var preferredPanelHeight: Double
  let editor: EditorContent
  let panel: PanelContent

  @State private var dragStartHeight: Double?
  @GestureState private var dragTranslation: CGFloat = 0

  init(
    preferredPanelHeight: Binding<Double>,
    @ViewBuilder editor: () -> EditorContent,
    @ViewBuilder panel: () -> PanelContent
  ) {
    _preferredPanelHeight = preferredPanelHeight
    self.editor = editor()
    self.panel = panel()
  }

  var body: some View {
    GeometryReader { proxy in
      let metrics = BottomPanelMetrics(
        containerHeight: proxy.size.height,
        preferredPanelHeight: CGFloat(preferredPanelHeight)
      )
      let visiblePanelHeight =
        dragStartHeight.map {
          metrics.clampedPanelHeight(CGFloat($0) - dragTranslation)
        } ?? metrics.panelHeight

      VStack(spacing: 0) {
        editor
          .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
          .layoutPriority(1)
          .clipped()

        resizeHandle(metrics: metrics)
          .frame(minHeight: 3)
          .onHover(perform: { hovering in
              if hovering {
                  NSCursor.pointingHand.push()
                } else {
                NSCursor.pop()
              }
            }
          )
        

        panel
          .frame(minWidth: 0, maxWidth: .infinity)
          .frame(height: visiblePanelHeight)
          .clipped()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
    }
  }

  private func resizeHandle(metrics: BottomPanelMetrics) -> some View {
    ZStack {
      Rectangle().fill(Color.clear)
      Divider()
    }
    .frame(height: metrics.dividerHeight)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .updating($dragTranslation) { value, state, _ in
          state = value.translation.height
        }
        .onChanged { _ in
          if dragStartHeight == nil {
            dragStartHeight = Double(metrics.panelHeight)
          }
        }
        .onEnded { value in
          let start = CGFloat(dragStartHeight ?? Double(metrics.panelHeight))
          preferredPanelHeight = Double(
            metrics.clampedPanelHeight(start - value.translation.height)
          )
          dragStartHeight = nil
        }
    )
    .accessibilityLabel("Resize bottom panel")
    .accessibilityHint("Drag vertically to change the bottom panel height")
  }
}

private struct BottomPanelMetrics {
  let containerHeight: CGFloat
  let preferredPanelHeight: CGFloat

  var dividerHeight: CGFloat {
    min(8, max(0, containerHeight * 0.08))
  }

  var panelHeight: CGFloat {
    clampedPanelHeight(preferredPanelHeight)
  }

  func clampedPanelHeight(_ proposed: CGFloat) -> CGFloat {
    min(max(proposed, minimumPanelHeight), maximumPanelHeight)
  }

  private var usableHeight: CGFloat {
    max(0, containerHeight - dividerHeight)
  }

  private var minimumPanelHeight: CGFloat {
    usableHeight * 0.16
  }

  private var maximumPanelHeight: CGFloat {
    usableHeight * 0.74
  }
}
