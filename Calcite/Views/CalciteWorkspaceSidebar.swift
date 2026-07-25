import AppKit
import SwiftUI

/// Project sidebar driven by the shared backend and window session.
@MainActor
struct CalciteWorkspaceSidebar: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession

  var body: some View {
    VStack(spacing: 0) {
      CalciteProjectFileTree(
        backend: backend,
        windowSession: windowSession
      )

      if windowSession.showsBuildProjectControl {
        Divider()
        CalciteBuildProjectControl(backend: backend)
      }

      if windowSession.showsNowPlaying, windowSession.nowPlaying.source != nil {
        Divider()
        CalciteNowPlayingSidebarSection(windowSession: windowSession)
        Divider()
      }

      CalciteSidebarFooter(
        phase: backend.workspacePhase,
        showsBuildProjectControl: binding(
          get: { windowSession.showsBuildProjectControl },
          set: { windowSession.showsBuildProjectControl = $0 }
        ),
        showsNowPlaying: binding(
          get: { windowSession.showsNowPlaying },
          set: { windowSession.showsNowPlaying = $0 }
        ),
        openSettings: { windowSession.perform(.openSettings) },
        openThemeBuilder: { windowSession.perform(.openThemeBuilder) }
      )
    }
    .onChange(of: windowSession.selectedFileURL) { _, url in
      guard let url else { return }
      Task { @MainActor in
        _ = await windowSession.openDocument(at: url)
      }
    }
    .onAppear(perform: windowSession.startNowPlaying)
    .onDisappear(perform: windowSession.stopNowPlaying)
  }

  private func binding<Value>(
    get: @escaping @MainActor @Sendable () -> Value,
    set: @escaping @MainActor @Sendable (Value) -> Void
  ) -> Binding<Value> {
    Binding(get: get, set: set)
  }
}

@MainActor
private struct CalciteProjectFileTree: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession

  var body: some View {
    FilesListView(
      rootURL: backend.workspaceURL,
      visibility: backend.fileVisibility,
      selectedURL: Binding(
        get: { windowSession.selectedFileURL },
        set: { selectedURL in
          // FilesListView can write its selection while SwiftUI is evaluating its body.
          // Publish on the next main-actor turn instead of mutating observable state mid-update.
          guard windowSession.selectedFileURL != selectedURL else { return }
          Task { @MainActor in
            await Task.yield()
            guard windowSession.selectedFileURL != selectedURL else { return }
            windowSession.selectedFileURL = selectedURL
          }
        }
      ),
      onOpen: { url in
        Task { @MainActor in
          _ = await windowSession.openDocument(at: url)
        }
      },
      onCreateFile: { directory, name in
        await backend.createFile(in: directory, name: name)
      },
      onCreateDirectory: { directory, name in
        await backend.createDirectory(in: directory, name: name)
      },
      onRename: { url, name in
        await backend.renameItem(at: url, to: name)
      },
      onDuplicate: { url in
        await backend.duplicateFile(at: url)
      },
      onDelete: { url in
        await backend.deleteItem(at: url)
      },
      hasUnsavedChanges: { url in
        backend.hasUnsavedChanges(under: url)
      },
      onTreeChange: {
        backend.refreshProjectContext()
        backend.refreshTerminalEnvironment()
      }
    )
  }

}

@MainActor
private struct CalciteBuildProjectControl: View {
  @ObservedObject var backend: CalciteBackend

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "hammer")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text("Build folder")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(backend.buildController.buildProjectURL.lastPathComponent)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Button(action: chooseFolder) {
        Image(systemName: "folder")
      }
      .buttonStyle(.plain)
      .help("Choose build folder")
      .disabled(backend.buildController.phase.isRunning)
    }
    .font(.callout)
    .padding(9)
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.title = "Choose Build Project Folder"
    panel.message = "Calcite will detect and run build tasks from this folder."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = backend.buildController.buildProjectURL
    guard panel.runModal() == .OK, let url = panel.url else { return }
    backend.selectBuildProjectFolder(url)
  }
}

@MainActor
private struct CalciteNowPlayingSidebarSection: View {
  @ObservedObject var windowSession: CalciteBackendWindowSession

  var body: some View {
    CalciteNowPlayingSurface(controller: windowSession.nowPlaying)
  }
}

private struct CalciteSidebarFooter: View {
  let phase: EditorWorkspacePhase
  @Binding var showsBuildProjectControl: Bool
  @Binding var showsNowPlaying: Bool
  let openSettings: () -> Void
  let openThemeBuilder: () -> Void

  var body: some View {
    HStack {
      Menu {
        Toggle("Now Playing", systemImage: "music.note", isOn: $showsNowPlaying)
        Toggle("Build folder", systemImage: "hammer", isOn: $showsBuildProjectControl)
      } label: {
        Image(systemName: "ellipsis.circle")
          .foregroundStyle(.secondary)
      }
      .menuStyle(.borderlessButton)
      .accessibilityLabel("Sidebar sections")
      .help("Show or hide sidebar sections")

      Menu {
        Button("Settings", systemImage: "gearshape", action: openSettings)
        Button("Theme Builder", systemImage: "paintpalette", action: openThemeBuilder)
      } label: {
        Image(systemName: "gearshape")
      }
      .menuStyle(.borderlessButton)
      .accessibilityLabel("Workspace settings")

      Spacer()
      CalciteWorkspaceStatus(phase: phase)
    }
    .padding(9)
  }
}

private struct CalciteWorkspaceStatus: View {
  let phase: EditorWorkspacePhase

  var body: some View {
    Group {
      switch phase {
      case .idle:
        Image(systemName: "circle")
      case .starting:
        ProgressView()
          .controlSize(.small)
      case .ready:
        Image(systemName: "checkmark.circle")
      case .failed(let message):
        Image(systemName: "exclamationmark.triangle")
          .help(message)
      }
    }
    .foregroundStyle(.secondary)
  }
}
