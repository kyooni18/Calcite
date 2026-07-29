import EditorServices
import SwiftUI

/// Main window header backed exclusively by `CalciteBackend` and its window session.
@MainActor
struct CalciteWorkspaceHeader: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession
  let searchFocus: FocusState<Bool>.Binding

  var body: some View {
    ViewThatFits(in: .horizontal) {
      headerContent(mode: .regular)
      headerContent(mode: .compact)
    }
    .frame(height: 32)
    .padding(.horizontal, 8)
    .foregroundStyle(backend.controller.profile.workbench.foreground.color)
    .background(backend.controller.profile.workbench.toolbarBackground.color)
  }

  private func headerContent(mode: CalciteWorkspaceHeaderContent.Mode) -> some View {
    CalciteWorkspaceHeaderContent(
      mode: mode,
      usesLiveMarkdownEditor: binding(
        get: { windowSession.usesLiveMarkdownEditor },
        set: { windowSession.usesLiveMarkdownEditor = $0 }
      ),
      showsMarkdownSyntax: binding(
        get: { windowSession.showsMarkdownSyntax },
        set: { windowSession.showsMarkdownSyntax = $0 }
      ),
      wrapsMarkdownLines: binding(
        get: { windowSession.markdownWrapsLines },
        set: { windowSession.markdownWrapsLines = $0 }
      ),
      showsBuildProjectControl: binding(
        get: { windowSession.showsBuildProjectControl },
        set: { windowSession.showsBuildProjectControl = $0 }
      ),
      showsNowPlaying: binding(
        get: { windowSession.showsNowPlaying },
        set: { windowSession.showsNowPlaying = $0 }
      ),
      searchQuery: binding(
        get: { windowSession.palette.query },
        set: { windowSession.palette.query = $0 }
      ),
      showsSearchResults: binding(
        get: { windowSession.palette.isPresented },
        set: { isPresented in
          if isPresented {
            windowSession.showUnifiedPalette()
          } else {
            windowSession.closeCommandPalette()
          }
        }
      ), backend: backend,
      searchFocus: searchFocus,
      profile: backend.controller.profile,
      activeTabIsMarkdown: activeTabIsMarkdown,
      activeLanguageID: windowSession.selectedDocument?.languageID,
      workspacePhase: backend.workspacePhase,
      serviceReport: backend.serviceReport,
      isBuildRunning: windowSession.commandAvailability.isBuilding,
      canBuild: windowSession.commandAvailability.canBuild,
      canRun: windowSession.commandAvailability.canRun,
      build: { windowSession.perform(.build) },
      run: { windowSession.perform(.run) },
      stop: { windowSession.perform(.stopBuild) },
      openSettings: { windowSession.perform(.openSettings) },
      openThemeBuilder: { windowSession.perform(.openThemeBuilder) },
      showPalette: { windowSession.showUnifiedPalette() },
      searchCommand: { windowSession.sendPaletteKeyboardCommand($0) },
      layout: windowSession.sectionalLayout
    )
  }

  private var activeTabIsMarkdown: Bool {
    guard let tab = windowSession.selectedDocument else { return false }
    return tab.languageID.lowercased() == "markdown"
      || ["md", "markdown", "mdown", "mkd"].contains(tab.url.pathExtension.lowercased())
  }

  private func binding<Value>(
    get: @escaping @MainActor @Sendable () -> Value,
    set: @escaping @MainActor @Sendable (Value) -> Void
  ) -> Binding<Value> {
    Binding(get: get, set: set)
  }
}

private struct CalciteWorkspaceHeaderContent: View {
  enum Mode { case regular, compact }

  let mode: Mode
  @Binding var usesLiveMarkdownEditor: Bool
  @Binding var showsMarkdownSyntax: Bool
  @Binding var wrapsMarkdownLines: Bool
  @Binding var showsBuildProjectControl: Bool
  @Binding var showsNowPlaying: Bool
  @Binding var searchQuery: String
  @Binding var showsSearchResults: Bool
    @State var backend: CalciteBackend
  let searchFocus: FocusState<Bool>.Binding
  let profile: EditorCustomProfile
  let activeTabIsMarkdown: Bool
  let activeLanguageID: String?
  let workspacePhase: EditorWorkspacePhase
  let serviceReport: EditorServiceAvailabilityReport
  let isBuildRunning: Bool
  let canBuild: Bool
  let canRun: Bool
  let build: () -> Void
  let run: () -> Void
  let stop: () -> Void
  let openSettings: () -> Void
  let openThemeBuilder: () -> Void
  let showPalette: () -> Void
  let searchCommand: (CalciteCommandPaletteSurface.KeyboardCommand) -> Void
  let layout: MainSectionalLayoutController

  var body: some View {
    HStack(spacing: 8) {
      CalciteWorkspaceSettingsMenu(
        openSettings: openSettings,
        openThemeBuilder: openThemeBuilder
      )
      CalciteWorkspaceSidebarSectionsMenu(
        showsBuildProjectControl: $showsBuildProjectControl,
        showsNowPlaying: $showsNowPlaying
      )

      if mode == .regular {
        EditorLanguageServerStatusIndicator(
          languageID: activeLanguageID,
          workspacePhase: workspacePhase,
          report: serviceReport,
          backend: backend
        )
          
        
          
        Spacer(minLength: 0)
        CalciteTopSearchField(
          profile: profile,
          query: $searchQuery,
          showsResults: $showsSearchResults,
          focus: searchFocus,
          showPalette: showPalette,
          sendCommand: searchCommand
        )
        .layoutPriority(1)
        Spacer(minLength: 0)
      } else {
        CalciteCompactSearchButton(query: searchQuery, action: showPalette)
        Spacer(minLength: 0)
      }

      CalciteBuildRunControls(
        isRunning: isBuildRunning,
        canBuild: canBuild,
        canRun: canRun,
        build: build,
        run: run,
        stop: stop
      )

      if mode == .regular, activeTabIsMarkdown {
        CalciteMarkdownEditorControls(
          usesLiveEditor: $usesLiveMarkdownEditor,
          showsSyntax: $showsMarkdownSyntax,
          wrapsLines: $wrapsMarkdownLines
        )
      }

      CalciteLayoutCustomizationControls(layout: layout)
    }
  }
}

private struct CalciteWorkspaceSettingsMenu: View {
  let openSettings: () -> Void
  let openThemeBuilder: () -> Void

  var body: some View {
    Menu {
      Button("Settings", systemImage: "gearshape", action: openSettings)
      Button("Theme Builder", systemImage: "paintpalette", action: openThemeBuilder)
    } label: {
      Image(systemName: "gearshape")
    }
    .menuStyle(.borderlessButton)
    .accessibilityLabel("Workspace settings")
    .help("Workspace settings")
  }
}

private struct CalciteWorkspaceSidebarSectionsMenu: View {
  @Binding var showsBuildProjectControl: Bool
  @Binding var showsNowPlaying: Bool

  var body: some View {
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
  }
}

private struct CalciteTopSearchField: View {
  let profile: EditorCustomProfile
  @Binding var query: String
  @Binding var showsResults: Bool
  let focus: FocusState<Bool>.Binding
  let showPalette: () -> Void
  let sendCommand: (CalciteCommandPaletteSurface.KeyboardCommand) -> Void

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: query.hasPrefix("/") ? "command" : "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search files or run a command", text: $query)
        .accessibilityIdentifier(EditorInitialFocusGuard.searchAccessibilityIdentifier)
        .textFieldStyle(.plain)
        .focused(focus)
        .onSubmit { sendCommand(.submit) }
        .onKeyPress(.downArrow) {
          sendCommand(.moveDown)
          return .handled
        }
        .onKeyPress(.upArrow) {
          sendCommand(.moveUp)
          return .handled
        }
        .onKeyPress(.tab) {
          sendCommand(.moveDown)
          return .handled
        }
        .onKeyPress(.escape) {
          sendCommand(.dismiss)
          return .handled
        }
      if query.isEmpty {
        Text("⌘P").font(.caption2).foregroundStyle(.tertiary)
      } else {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .font(.callout)
    .padding(.horizontal, 10)
    .frame(minWidth: 160, idealWidth: 300, maxWidth: 420, minHeight: 24, maxHeight: 24)
    .foregroundStyle(profile.workbench.foreground.color)
    .background(profile.workbench.inputBackground.color, in: RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(profile.workbench.border.color.opacity(0.7), lineWidth: 0.5)
    }
    .contentShape(RoundedRectangle(cornerRadius: 6))
    .onTapGesture { showPalette() }
    .onChange(of: query) { _, _ in
      if focus.wrappedValue, !showsResults { showPalette() }
    }
    .accessibilityLabel("Search files or run a command")
    .help("Search files or run a command (Command-P)")
  }
}

private struct CalciteCompactSearchButton: View {
  let query: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: query.isEmpty ? "magnifyingglass" : "magnifyingglass.circle.fill")
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Search files or run a command")
    .help("Search files or run a command (Command-P)")
  }
}

private struct CalciteBuildRunControls: View {
  let isRunning: Bool
  let canBuild: Bool
  let canRun: Bool
  let build: () -> Void
  let run: () -> Void
  let stop: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      if isRunning {
        Button(action: stop) { Image(systemName: "stop.fill") }
          .buttonStyle(.borderless)
          .accessibilityLabel("Stop build or run")
          .help("Stop (Command-Period)")
      } else {
        Button(action: build) { Image(systemName: "hammer") }
          .buttonStyle(.borderless)
          .disabled(!canBuild)
          .accessibilityLabel("Build")
          .help("Build (Command-B)")

        Button(action: run) { Image(systemName: "play.fill") }
          .buttonStyle(.borderless)
          .disabled(!canRun)
          .accessibilityLabel("Run")
          .help("Run (Command-R)")
      }
    }
    .padding(.trailing, 4)
  }
}

private struct CalciteMarkdownEditorControls: View {
  @Binding var usesLiveEditor: Bool
  @Binding var showsSyntax: Bool
  @Binding var wrapsLines: Bool

  var body: some View {
    Group {
      if usesLiveEditor {
        Button {
          showsSyntax.toggle()
        } label: {
          Label(
            showsSyntax ? "Syntax Shown" : "Syntax Hidden",
            systemImage: showsSyntax ? "text.badge.checkmark" : "text.badge.xmark"
          ).font(.caption)
        }
        .buttonStyle(.borderless)
        .help(showsSyntax ? "Hide Markdown syntax markers" : "Show Markdown syntax markers")
        .padding(.trailing, 6)

        Button {
          wrapsLines.toggle()
        } label: {
          Label(
            wrapsLines ? "Line Wrap On" : "Line Wrap Off",
            systemImage: wrapsLines ? "text.word.spacing" : "arrow.left.and.right.text.vertical"
          ).font(.caption)
        }
        .buttonStyle(.borderless)
        .help(wrapsLines ? "Wrap long Markdown lines" : "Allow horizontal scrolling")
        .padding(.trailing, 6)
      }

      Button {
        usesLiveEditor.toggle()
      } label: {
        Label(
          usesLiveEditor ? "Live Markdown" : "Plain Editor",
          systemImage: usesLiveEditor ? "textformat.alt" : "doc.plaintext"
        ).font(.caption)
      }
      .buttonStyle(.borderless)
      .help(
        usesLiveEditor
          ? "Live Markdown Editor — click for Plain Editor"
          : "Plain Editor — click for Live Markdown Editor"
      )
      .padding(.trailing, 8)
    }
  }
}

private struct CalciteLayoutCustomizationControls: View {
  @ObservedObject var layout: MainSectionalLayoutController
  @State private var isShowingSaveProfileAlert = false
  @State private var isShowingRenameProfileAlert = false
  @State private var profileName = ""

  var body: some View {
    HStack(spacing: 5) {
      if layout.isCustomizing {
        Button("Undo Layout", systemImage: "arrow.uturn.backward") {
          layout.undo()
        }
        .disabled(!layout.canUndo)

        Button("Redo Layout", systemImage: "arrow.uturn.forward") {
          layout.redo()
        }
        .disabled(!layout.canRedo)

        Menu {
          Section("Built-in Profiles") {
            ForEach(layout.layoutProfiles.filter(\.isBuiltIn)) { profile in
              Button {
                layout.applyLayoutProfile(id: profile.id)
              } label: {
                Label(
                  profile.name,
                  systemImage: layout.activeLayoutProfileID == profile.id
                    ? "checkmark.circle.fill"
                    : (profile.builtInPreset?.systemImage ?? "rectangle.3.group")
                )
              }
            }
          }

          let customProfiles = layout.layoutProfiles.filter { !$0.isBuiltIn }
          if !customProfiles.isEmpty {
            Section("Custom Profiles") {
              ForEach(customProfiles) { profile in
                Button {
                  layout.applyLayoutProfile(id: profile.id)
                } label: {
                  Label(
                    profile.name,
                    systemImage: layout.activeLayoutProfileID == profile.id
                      ? "checkmark.circle.fill"
                      : "rectangle.3.group.bubble"
                  )
                }
              }
            }
          }

          Divider()
          Button("Save Current Layout as Profile", systemImage: "plus.rectangle.on.rectangle") {
            profileName = ""
            isShowingSaveProfileAlert = true
          }
          if let activeProfile = layout.activeLayoutProfile {
            Button("Duplicate Active Profile", systemImage: "plus.square.on.square") {
              layout.duplicateLayoutProfile(id: activeProfile.id)
            }
            if !activeProfile.isBuiltIn {
              Button("Rename Active Profile", systemImage: "pencil") {
                profileName = activeProfile.name
                isShowingRenameProfileAlert = true
              }

              Button("Update Active Profile", systemImage: "square.and.arrow.down") {
                layout.updateActiveLayoutProfile()
              }
              .disabled(!layout.isActiveLayoutProfileModified)

              Button("Delete Active Profile", systemImage: "trash", role: .destructive) {
                layout.deleteLayoutProfile(id: activeProfile.id)
              }
            }
          }
          Divider()
          Button("Reset Layout", systemImage: "arrow.counterclockwise") {
            layout.reset()
          }
        } label: {
          Label(
            layout.activeLayoutProfile?.name ?? "Layout Profiles",
            systemImage: "rectangle.3.group"
          )
        }
        .menuStyle(.borderlessButton)
      }

      Button {
        withAnimation(.easeInOut(duration: 0.16)) {
          layout.isCustomizing.toggle()
        }
      } label: {
        Image(systemName: "slider.horizontal.3")
          .foregroundStyle(layout.isCustomizing ? Color.accentColor : .primary)
      }
      .accessibilityLabel(
        layout.isCustomizing ? "Finish layout customization" : "Customize layout"
      )
      .help(layout.isCustomizing ? "Finish layout customization" : "Customize layout")
    }
    .buttonStyle(.plain)
    .labelStyle(.iconOnly)
    .transition(.opacity.combined(with: .move(edge: .trailing)))
    .alert("Save Layout Profile", isPresented: $isShowingSaveProfileAlert) {
      TextField("Profile name", text: $profileName)
      Button("Cancel", role: .cancel) {}
      Button("Save") { layout.saveCurrentLayoutProfile(named: profileName) }
    } message: {
      Text("Save the current section arrangement and divider sizes.")
    }
    .alert("Rename Layout Profile", isPresented: $isShowingRenameProfileAlert) {
      TextField("Profile name", text: $profileName)
      Button("Cancel", role: .cancel) {}
      Button("Rename") {
        guard let profile = layout.activeLayoutProfile else { return }
        layout.renameLayoutProfile(id: profile.id, to: profileName)
      }
    }
  }
}
