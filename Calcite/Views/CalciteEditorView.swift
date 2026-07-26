import SwiftUI

/// Backend-driven editor entry point for one concrete window editor session.
/// Commands and selection remain targeted when a document is displayed in multiple sections.
@MainActor
struct CalciteEditorView: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession
  @ObservedObject var editorSession: CalciteBackendWindowSession.EditorSession
  @ObservedObject var tab: EditorTab
  let activate: () -> Void
  @AppStorage(EditorInterfacePreferences.interfaceKey)
  private var editorInterfaceRaw = EditorInterface.builtIn.rawValue

  var body: some View {
    Group {
      if editorInterface.usesTerminalEditor {
        ActualVimEditorSurface(
          workspaceURL: backend.workspaceURL,
          tab: tab,
          interface: editorInterface,
          profile: backend.controller.profile
        )
      } else {
        builtInEditor
      }
    }
    .id("\(editorSession.id.uuidString)-\(editorInterface.rawValue)")
    .onChange(of: tab.selectedRange) { _, range in
      guard windowSession.activeEditorSessionID == editorSession.id else { return }
      editorSession.updateSelection(range)
    }
  }

  private var editorInterface: EditorInterface {
    EditorInterface(rawValue: editorInterfaceRaw) ?? .builtIn
  }

  private var builtInEditor: some View {
    CalciteEditorSurface(
      tab: tab,
      liveMarkdownStyling: windowSession.usesLiveMarkdownEditor,
      showsMarkdownSyntax: windowSession.showsMarkdownSyntax,
      wrapsMarkdownLines: windowSession.markdownWrapsLines,
      profile: backend.controller.profile,
      onVimHostRequest: { request in
        activate()
        backend.handleVimHostRequest(request)
      },
      onGoToDefinition: {
        activate()
        backend.goToDefinition()
      },
      onFindReferences: {
        activate()
        backend.findReferences()
      },
      onShowQuickHelp: {
        activate()
        backend.showQuickHelp()
      },
      onShowQuickFixes: { diagnostic in
        activate()
        backend.controller.showQuickFixes(for: diagnostic, in: tab)
      },
      onToggleInputMode: {
        activate()
        backend.toggleEditorInputMode()
      },
      commandEvent: previousCommandEvent
    )
  }

  private var previousCommandEvent: EditorTabCommandEvent? {
    guard let event = windowSession.editorCommandEvent,
      event.editorSessionID == editorSession.id
    else {
      return nil
    }

    return EditorTabCommandEvent(
      targetTabID: event.documentID,
      command: event.command
    )
  }
}

#if os(macOS)
  @MainActor
  private struct ActualVimEditorSurface: View {
    @ObservedObject var tab: EditorTab
    let interface: EditorInterface
    let profile: EditorCustomProfile
    @StateObject private var session: EditorTerminalSession
    @StateObject private var appearanceStore = EditorTerminalPreferencesStore()
    @AppStorage(EditorInterfacePreferences.interfaceKey)
    private var editorInterfaceRaw = EditorInterface.builtIn.rawValue

    private let launchCommand: String?

    init(
      workspaceURL: URL,
      tab: EditorTab,
      interface: EditorInterface,
      profile: EditorCustomProfile
    ) {
      self.tab = tab
      self.interface = interface
      self.profile = profile
      let command = EditorInterfacePreferences.launchCommand(
        interface: interface,
        fileURL: tab.url
      )
      self.launchCommand = command
      _session = StateObject(
        wrappedValue: EditorTerminalSession(
          workspaceURL: workspaceURL,
          initialCommand: command,
          monitorsPythonEnvironment: false
        )
      )
    }

    var body: some View {
      Group {
        if launchCommand != nil {
          TerminalTextView(
            snapshot: session.renderedSnapshot,
            outputEpoch: session.outputEpoch,
            preferences: appearanceStore.preferences,
            appearanceRevision: appearanceStore.revision,
            send: session.send,
            clear: session.clear,
            resize: session.resize,
            save: {
              session.send("\u{1b}:write\r")
            }
          )
        } else {
          unavailableView
        }
      }
      .background(profile.surface.background.color)
      .onAppear {
        appearanceStore.apply(theme: profile.terminal)
        if launchCommand != nil {
          session.reattachView()
        }
      }
      .onDisappear {
        if launchCommand != nil {
          session.detachView()
        }
      }
      .onChange(of: profile.terminal) { _, value in
        appearanceStore.apply(theme: value)
      }
    }

    private var unavailableView: some View {
      ContentUnavailableView {
        Label(
          "\(interface.title) Not Found",
          systemImage: "terminal"
        )
      } description: {
        Text(
          "Install \(interface.executableName ?? "the editor") in PATH, /opt/homebrew/bin, or /usr/local/bin."
        )
      } actions: {
        Button("Use Built-in Editor") {
          editorInterfaceRaw = EditorInterface.builtIn.rawValue
        }
      }
    }
  }
#endif
