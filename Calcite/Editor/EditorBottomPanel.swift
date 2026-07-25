import EditorServices
import SwiftUI

#if os(macOS)
  enum EditorBottomPanel: String, CaseIterable, Identifiable {
    case problems = "Problems"
    case build = "Build"
    case debug = "Debug"
    case terminal = "Terminal"

    var id: String { rawValue }
    var systemImage: String {
      switch self {
      case .problems: return "exclamationmark.triangle"
      case .build: return "hammer"
      case .debug: return "ladybug"
      case .terminal: return "terminal"
      }
    }
  }

  struct EditorBottomPanelView: View {
    @ObservedObject var controller: EditorWorkspaceController
    @ObservedObject var terminal: EditorTerminalSession
    @Binding var selection: EditorBottomPanel?

    var body: some View {
      VStack(spacing: 0) {
        Group {
          switch selection {
          case .problems:
            EditorProblemsView(
              controller: controller,
              buildController: controller.buildController
            )
          case .build:
            EditorBuildOutputView(
              controller: controller,
              buildController: controller.buildController
            )
          case .debug: EditorDebugPanelView(controller: controller)
          case .terminal:
            EditorTerminalView(session: terminal, themeProfile: controller.profile.terminal)
          case nil: EmptyView()
          }
        }
        .id(selection?.id ?? "closed")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .foregroundStyle(controller.profile.workbench.foreground.color)
      .background(controller.profile.workbench.panelBackground.color)
      Divider()
      footer
    }

    private var footer: some View {
      HStack(spacing: 2) {
        ForEach(EditorBottomPanel.allCases) { item in
          Button {
            selection = item
          } label: {
            Label(item.rawValue, systemImage: item.systemImage)
              .font(.caption)
              .padding(.horizontal, 8)
              .frame(height: 28)
              .background(selection == item ? Color.accentColor.opacity(0.14) : .clear)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        Spacer()
        if let selection {
          Button("Close Panel", systemImage: "xmark") { self.selection = nil }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help("Close \(selection.rawValue)")
        }
      }
      .background(controller.profile.workbench.toolbarBackground.color)
    }
  }
#endif
