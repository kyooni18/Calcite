@_spi(Calcite) import EditorVim
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
  @AppStorage(EditorInterfacePreferences.neovimLaunchCommandKey)
  private var neovimLaunchCommand = ""
  @AppStorage(EditorInterfacePreferences.vimLaunchCommandKey)
  private var vimLaunchCommand = ""
  @AppStorage(EditorInterfacePreferences.terminalLeaderKey)
  private var terminalLeader = "\\"

  var body: some View {
    Group {
      if editorInterface.usesTerminalEditor {
        ActualVimEditorSurface(
          workspaceURL: backend.workspaceURL,
          windowSession: windowSession,
          tab: tab,
          interface: editorInterface,
          profile: backend.controller.profile,
          navigateSection: { direction in
            activate()
            windowSession.commandNavigateSection(direction: direction)
          },
          navigateTab: windowSession.commandNavigateTab(forward:),
          selectTab: windowSession.commandSelectTab(number:),
          handleHostCommand: { backend.handleVimHostRequest(.custom($0)) }
        )
      } else {
        builtInEditor
      }
    }
    .id(
      [
        editorSession.id.uuidString,
        editorInterface.rawValue,
        neovimLaunchCommand,
        vimLaunchCommand,
        terminalLeader,
      ].joined(separator: "|")
    )
    .onChange(of: tab.selectedRange) { _, range in
      guard windowSession.activeEditorSessionID == editorSession.id else { return }
      editorSession.updateSelection(range)
    }
    .onAppear(perform: preloadTerminalEditors)
    .onChange(of: editorInterfaceRaw) { _, _ in preloadTerminalEditors() }
    .onChange(of: documentIDs) { _, _ in preloadTerminalEditors() }
  }

  private var editorInterface: EditorInterface {
    EditorInterface(rawValue: editorInterfaceRaw) ?? .builtIn
  }

  private var documentIDs: [UUID] {
    backend.documents.map(\.id)
  }

  private func preloadTerminalEditors() {
    windowSession.preloadTerminalEditors(interface: editorInterface)
  }

  private var builtInEditor: some View {
    var profile = backend.controller.profile
    if editorInterface.usesCalciteVim {
      // Space is Calcite Vim's fixed leader. Profiles are persisted across
      // launches, so setting only the default would leave older profiles on
      // their previous leader and make Space appear unresponsive.
      profile.vim.enabled = true
      profile.vim.leader = " "
    } else {
      profile.vim.enabled = false
    }
    profile.vim.ensureNavigationMappings()
    let vimController: VimKeymapController?
    if editorInterface.usesCalciteVim {
      vimController = windowSession.vimSessionCoordinator.controller(
        for: VimWindowID(editorSession.id),
        displaying: VimBufferID(tab.id),
        text: tab.text,
        cursor: editorSession.selectedRange.location,
        name: tab.url.path,
        leader: profile.vim.normalizedLeader,
        localLeader: profile.vim.normalizedLeader,
        tabWidth: profile.behavior.tabWidth,
        history: tab.vimHistory
      )
    } else {
      vimController = nil
    }
    return CalciteEditorSurface(
      tab: tab,
      editorSession: editorSession,
      onActivate: activate,
      liveMarkdownStyling: windowSession.usesLiveMarkdownEditor,
      showsMarkdownSyntax: windowSession.showsMarkdownSyntax,
      wrapsMarkdownLines: windowSession.markdownWrapsLines,
      profile: profile,
      editorMode: editorInterface,
      vimController: vimController,
      onVimHistoryChange: windowSession.persistVimHistory,
      onVimHostInvocation: { invocation in
        activate()
        return windowSession.handleVimHostInvocation(invocation)
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
      onSelectInputMode: { mode in
        activate()
        editorInterfaceRaw = mode.rawValue
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
      id: event.id,
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
    let navigateSection: (MainSectionDirection) -> Void
    let navigateTab: (Bool) -> Void
    let selectTab: (Int) -> Void
    let handleHostCommand: (String) -> Void
    @ObservedObject private var session: EditorTerminalSession
    @StateObject private var appearanceStore = EditorTerminalPreferencesStore()
    @AppStorage(EditorInterfacePreferences.interfaceKey)
    private var editorInterfaceRaw = EditorInterface.builtIn.rawValue

    private let launchCommand: String?

    init(
      workspaceURL: URL,
      windowSession: CalciteBackendWindowSession,
      tab: EditorTab,
      interface: EditorInterface,
      profile: EditorCustomProfile,
      navigateSection: @escaping (MainSectionDirection) -> Void,
      navigateTab: @escaping (Bool) -> Void,
      selectTab: @escaping (Int) -> Void,
      handleHostCommand: @escaping (String) -> Void
    ) {
      self.tab = tab
      self.interface = interface
      self.profile = profile
      self.navigateSection = navigateSection
      self.navigateTab = navigateTab
      self.selectTab = selectTab
      self.handleHostCommand = handleHostCommand
      let command = EditorInterfacePreferences.launchCommand(
        interface: interface,
        fileURL: tab.url,
        workspaceURL: workspaceURL
      )
      self.launchCommand = command
      _session = ObservedObject(
        wrappedValue: windowSession.terminalEditorSession(interface: interface, fileURL: tab.url)
      )
    }

    var body: some View {
      VStack(spacing: 0) {
        if launchCommand != nil {
          TerminalTextView(
            snapshot: session.renderedSnapshot,
            outputEpoch: session.outputEpoch,
            preferences: appearanceStore.preferences,
            appearanceRevision: appearanceStore.revision,
            send: session.send,
            sendMouse: session.sendMouse,
            clear: session.clear,
            resize: session.resize,
            save: {
              session.send("\u{1b}:write\r")
            },
            navigateSection: { forward in
              navigateSection(forward ? .right : .left)
            },
            navigateSectionDirection: navigateSection,
            navigateTab: navigateTab,
            selectTab: selectTab,
            handleHostCommand: handleHostCommand,
            allowsScrolling: false,
            routesPointerEventsToTerminal: true
          )
        } else {
          unavailableView
        }
        terminalEditorStatusBar
      }
      .background(profile.surface.background.color)
      .onAppear {
        appearanceStore.apply(theme: profile.terminal)
        // Neovim draws its own context and completion menus with styled blank
        // terminal cells. Those cells are part of the menu rectangle, not
        // trailing document whitespace, so keep them in this embedded editor.
        session.setPreservesEraseCellBackgrounds(true)
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

    private var terminalEditorStatusBar: some View {
      HStack(spacing: 10) {
        Text(tab.languageID)
        Spacer()
        Menu {
          ForEach(EditorInterface.allCases) { mode in
            Button {
              editorInterfaceRaw = mode.rawValue
            } label: {
              if mode == interface {
                Label(mode.title, systemImage: "checkmark")
              } else {
                Text(mode.title)
              }
            }
          }
        } label: {
          Text(interface.title.uppercased())
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch editor mode (Command-Control-V cycles modes)")
        Text(tab.title)
          .foregroundStyle(.secondary)
      }
      .font(.caption)
      .padding(.horizontal, 10)
      .frame(height: 24)
      .background(.bar)
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
