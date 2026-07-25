import SwiftUI

struct ThemeBuilderView: View {
  @ObservedObject var controller: EditorWorkspaceController
  @ObservedObject var session: ThemeBuilderSession

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Label("Theme Builder", systemImage: "paintpalette")
          .font(.headline)
        Spacer()
        if session.isDirty {
          Text("Modified")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Revert", role: .destructive) {
            session.discard()
          }
          Button("Keep Changes") {
            session.save()
          }
        }
      }
      .padding(.horizontal, 14)
      .frame(height: 38)
      .background(controller.profile.workbench.toolbarBackground.color)

      Divider()

      EditorProfileSettingsView(controller: controller)
    }
    .background(controller.profile.workbench.windowBackground.color)
    .onAppear {
      session.beginEditing()
    }
  }
}
