import SwiftUI

@MainActor
struct CalciteEditorEmptyState: View {
  @ObservedObject var backend: CalciteBackend

  @ViewBuilder
  var body: some View {
    switch backend.workspacePhase {
    case .starting:
      VStack(spacing: 9) {
        ProgressView()
          .controlSize(.small)
        Text("Preparing editor")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

    case .failed(let message):
      ContentUnavailableView(
        "Editor Failed",
        systemImage: "exclamationmark.triangle",
        description: Text(message)
      )
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

    case .idle, .ready:
      ContentUnavailableView {
        Label("No File Open", systemImage: "doc.text")
      } description: {
        Text("Select a file.")
      }
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
  }
}
