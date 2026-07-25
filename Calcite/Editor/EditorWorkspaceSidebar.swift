import AppKit
import SwiftUI

struct EditorWorkspaceSidebar: View {
  @ObservedObject var controller: EditorWorkspaceController
  @ObservedObject var terminal: EditorTerminalSession
  @Binding var selectedFileURL: URL?
  @Binding var showsBuildProjectControl: Bool
  @Binding var showsNowPlaying: Bool
  @ObservedObject var nowPlaying: NowPlayingController
  let openFile: (URL) -> Void
  let openFileToSide: (URL) -> Void
  @ObservedObject var fileVisibility: FileVisibilitySettings
  let openSettings: () -> Void
  let openThemeBuilder: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      EditorFileTree(
        controller: controller,
        terminal: terminal,
        selectedFileURL: $selectedFileURL,
        openFile: openFile,
        openFileToSide: openFileToSide,
        fileVisibility: fileVisibility
      )
      if showsBuildProjectControl {
        Divider()
        EditorBuildProjectControl(controller: controller)
      }
      if showsNowPlaying, nowPlaying.source != nil {
        Divider()
        NowPlayingSidebarView(controller: nowPlaying)
        Divider()
      }
      EditorSidebarFooter(
        phase: controller.phase,
        showsBuildProjectControl: $showsBuildProjectControl,
        showsNowPlaying: $showsNowPlaying,
        openSettings: openSettings,
        openThemeBuilder: openThemeBuilder
      )
    }
    .onChange(of: selectedFileURL) { _, newValue in
      guard let newValue else { return }
      openFile(newValue)
    }
    .onAppear { nowPlaying.start() }
    .onDisappear { nowPlaying.stop() }
  }
}

private struct EditorFileTree: View {
  @ObservedObject var controller: EditorWorkspaceController
  @ObservedObject var terminal: EditorTerminalSession
  @Binding var selectedFileURL: URL?
  let openFile: (URL) -> Void
  let openFileToSide: (URL) -> Void
  @ObservedObject var fileVisibility: FileVisibilitySettings

  var body: some View {
    FilesListView(
      rootURL: controller.workspaceURL,
      visibility: fileVisibility,
      selectedURL: $selectedFileURL,
      onOpen: openFile,
      onOpenToSide: openFileToSide,
      onCreateFile: { directory, name in await controller.createFile(in: directory, name: name) },
      onCreateDirectory: { directory, name in
        await controller.createDirectory(in: directory, name: name)
      },
      onRename: { url, name in await controller.renameItem(at: url, to: name) },
      onDuplicate: { url in await controller.duplicateFile(at: url) },
      onDelete: { url in await controller.deleteItem(at: url) },
      hasUnsavedChanges: controller.hasUnsavedChanges,
      onTreeChange: {
        controller.refreshProjectContext()
        terminal.refreshEnvironment()
      }
    )
  }
}

private struct EditorBuildProjectControl: View {
  @ObservedObject var controller: EditorWorkspaceController

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "hammer").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text("Build folder").font(.caption).foregroundStyle(.secondary)
        Text(controller.buildController.buildProjectURL.lastPathComponent).lineLimit(1)
      }
      Spacer(minLength: 0)
      Button(action: chooseFolder) { Image(systemName: "folder") }
        .buttonStyle(.plain).help("Choose build folder")
        .disabled(controller.buildController.phase.isRunning)
    }
    .font(.callout).padding(9)
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.title = "Choose Build Project Folder"
    panel.message = "Calcite will detect and run build tasks from this folder."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = controller.buildController.buildProjectURL
    guard panel.runModal() == .OK, let url = panel.url else { return }
    controller.buildController.selectBuildProjectFolder(url)
  }
}

private struct EditorSidebarFooter: View {
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
        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
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
      EditorWorkspaceStatus(phase: phase)
    }
    .padding(9)
  }
}

private struct EditorWorkspaceStatus: View {
  let phase: EditorWorkspacePhase

  var body: some View {
    Group {
      switch phase {
      case .idle: Image(systemName: "circle")
      case .starting: ProgressView().controlSize(.small)
      case .ready: Image(systemName: "checkmark.circle")
      case .failed(let message): Image(systemName: "exclamationmark.triangle").help(message)
      }
    }
    .foregroundStyle(.secondary)
  }
}
