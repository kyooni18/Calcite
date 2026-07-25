import EditorServices
import SwiftUI

struct EditorWorkspaceHeader: View {
  @Binding var showsSidebar: Bool
  @Binding var bottomPanel: EditorBottomPanel?
  @Binding var usesLiveMarkdownEditor: Bool
  @Binding var showsMarkdownSyntax: Bool
  @Binding var wrapsMarkdownLines: Bool
  @Binding var searchQuery: String
  @Binding var showsSearchResults: Bool
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
  let showPalette: () -> Void
  let searchCommand: (EditorCommandPalette.KeyboardCommand) -> Void
  let toggleBottomBar: () -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      EditorWorkspaceHeaderContent(
        mode: .regular,
        showsSidebar: $showsSidebar,
        bottomPanel: $bottomPanel,
        usesLiveMarkdownEditor: $usesLiveMarkdownEditor,
        showsMarkdownSyntax: $showsMarkdownSyntax,
        wrapsMarkdownLines: $wrapsMarkdownLines,
        searchQuery: $searchQuery,
        showsSearchResults: $showsSearchResults,
        searchFocus: searchFocus,
        profile: profile,
        activeTabIsMarkdown: activeTabIsMarkdown,
        activeLanguageID: activeLanguageID,
        workspacePhase: workspacePhase,
        serviceReport: serviceReport,
        isBuildRunning: isBuildRunning,
        canBuild: canBuild,
        canRun: canRun,
        build: build,
        run: run,
        stop: stop,
        showPalette: showPalette,
        searchCommand: searchCommand,
        toggleBottomBar: toggleBottomBar
      )
      EditorWorkspaceHeaderContent(
        mode: .compact,
        showsSidebar: $showsSidebar,
        bottomPanel: $bottomPanel,
        usesLiveMarkdownEditor: $usesLiveMarkdownEditor,
        showsMarkdownSyntax: $showsMarkdownSyntax,
        wrapsMarkdownLines: $wrapsMarkdownLines,
        searchQuery: $searchQuery,
        showsSearchResults: $showsSearchResults,
        searchFocus: searchFocus,
        profile: profile,
        activeTabIsMarkdown: activeTabIsMarkdown,
        activeLanguageID: activeLanguageID,
        workspacePhase: workspacePhase,
        serviceReport: serviceReport,
        isBuildRunning: isBuildRunning,
        canBuild: canBuild,
        canRun: canRun,
        build: build,
        run: run,
        stop: stop,
        showPalette: showPalette,
        searchCommand: searchCommand,
        toggleBottomBar: toggleBottomBar
      )
    }
    .frame(height: 32)
    .padding(.horizontal, 8)
    .foregroundStyle(profile.workbench.foreground.color)
    .background(profile.workbench.toolbarBackground.color)
  }
}

private struct EditorWorkspaceHeaderContent: View {
  enum Mode { case regular, compact }

  let mode: Mode
  @Binding var showsSidebar: Bool
  @Binding var bottomPanel: EditorBottomPanel?
  @Binding var usesLiveMarkdownEditor: Bool
  @Binding var showsMarkdownSyntax: Bool
  @Binding var wrapsMarkdownLines: Bool
  @Binding var searchQuery: String
  @Binding var showsSearchResults: Bool
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
  let showPalette: () -> Void
  let searchCommand: (EditorCommandPalette.KeyboardCommand) -> Void
  let toggleBottomBar: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      EditorSidebarToggle(isVisible: $showsSidebar)

      if mode == .regular {
        EditorLanguageServerStatusIndicator(
          languageID: activeLanguageID,
          workspacePhase: workspacePhase,
          report: serviceReport
        )
        Spacer(minLength: 0)
        EditorTopSearchField(
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
        EditorCompactSearchButton(query: searchQuery, action: showPalette)
        Spacer(minLength: 0)
      }

      EditorBuildRunControls(
        isRunning: isBuildRunning,
        canBuild: canBuild,
        canRun: canRun,
        build: build,
        run: run,
        stop: stop
      )

      if mode == .regular, activeTabIsMarkdown {
        MarkdownEditorControls(
          usesLiveEditor: $usesLiveMarkdownEditor,
          showsSyntax: $showsMarkdownSyntax,
          wrapsLines: $wrapsMarkdownLines
        )
      }

      EditorBottomPanelToggle(isVisible: bottomPanel != nil, action: toggleBottomBar)
    }
  }
}

private struct EditorTopSearchField: View {
  let profile: EditorCustomProfile
  @Binding var query: String
  @Binding var showsResults: Bool
  let focus: FocusState<Bool>.Binding
  let showPalette: () -> Void
  let sendCommand: (EditorCommandPalette.KeyboardCommand) -> Void

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

private struct EditorCompactSearchButton: View {
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

private struct EditorSidebarToggle: View {
  @Binding var isVisible: Bool

  var body: some View {
    Button {
      isVisible.toggle()
    } label: {
      Image(systemName: "sidebar.left").foregroundStyle(isVisible ? .primary : .secondary)
    }
    .buttonStyle(.plain)
    .keyboardShortcut("b", modifiers: [.command, .shift])
    .accessibilityLabel(isVisible ? "Hide sidebar" : "Show sidebar")
    .help(isVisible ? "Hide sidebar (Command-Shift-B)" : "Show sidebar (Command-Shift-B)")
  }
}

private struct EditorBuildRunControls: View {
  let isRunning: Bool
  let canBuild: Bool
  let canRun: Bool
  let build: () -> Void
  let run: () -> Void
  let stop: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      if isRunning {
        Button(action: stop) {
          Image(systemName: "stop.fill")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Stop build or run")
        .help("Stop (Command-Period)")
      } else {
        Button(action: build) {
          Image(systemName: "hammer")
        }
        .buttonStyle(.borderless)
        .disabled(!canBuild)
        .accessibilityLabel("Build")
        .help("Build (Command-B)")

        Button(action: run) {
          Image(systemName: "play.fill")
        }
        .buttonStyle(.borderless)
        .disabled(!canRun)
        .accessibilityLabel("Run")
        .help("Run (Command-R)")
      }
    }
    .padding(.trailing, 4)
  }
}

private struct MarkdownEditorControls: View {
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
        .accessibilityLabel(showsSyntax ? "Hide Markdown syntax" : "Show Markdown syntax")
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
        .accessibilityLabel(
          wrapsLines ? "Disable Markdown line wrapping" : "Enable Markdown line wrapping"
        )
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
      .accessibilityLabel(
        usesLiveEditor
          ? "Using Live Markdown Editor. Switch to Plain Editor"
          : "Using Plain Editor. Switch to Live Markdown Editor"
      )
      .help(
        usesLiveEditor
          ? "Live Markdown Editor — click for Plain Editor"
          : "Plain Editor — click for Live Markdown Editor"
      )
      .padding(.trailing, 8)
    }
  }
}

private struct EditorBottomPanelToggle: View {
  let isVisible: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "inset.filled.bottomthird.rectangle")
        .foregroundStyle(isVisible ? Color.accentColor : .primary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isVisible ? "Hide bottom bar" : "Show bottom bar")
    .help(isVisible ? "Hide bottom bar" : "Show bottom bar")
    .padding(.trailing, 10)
  }
}
