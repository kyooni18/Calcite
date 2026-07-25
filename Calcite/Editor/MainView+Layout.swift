import EditorServices
import SwiftUI

extension MainView {
  var configuredRootView: some View {
    lifecycleConfiguredRootView
      .preferredColorScheme(effectiveAppearanceMode.colorScheme)
      .foregroundStyle(controller.profile.workbench.foreground.color)
      .tint(controller.profile.workbench.accent.color)
  }

  var lifecycleConfiguredRootView: some View {
    rootView
      .background(controller.profile.workbench.windowBackground.color)
      .background(
        EditorWindowAppearanceApplier(
          mode: effectiveAppearanceMode,
          backgroundColor: controller.profile.workbench.windowBackground.nsColor
        )
      )
      .background(EditorWindowLayoutPersistence(workspaceURL: controller.workspaceURL))
      .background(EditorInitialFocusGuard())
      .focusedSceneValue(
        \.editorCommandHandler,
        EditorCommandHandler(perform: commandExecutor.perform)
      )
      .focusedSceneValue(\.editorCommandAvailability, commandAvailability)
      .task {
        configureControllerCallbacks()
        controller.activateTheme(for: colorScheme)
        await lifecycle.start(
          initialFileURL: initialFileURL,
          shouldStartTerminal: commandExecutor.bottomPanel == .terminal,
          onReady: onControllerReady
        )
        if lifecycle.state == .running, let pendingDocumentOpenURL {
          _ = await commandExecutor.openAndSelectDocument(pendingDocumentOpenURL)
          self.pendingDocumentOpenURL = nil
        }
        reconcileWorkspaceTabs()
      }
      .onDisappear {
        clearControllerCallbacks()
        Task {
          await lifecycle.stop(onReady: onControllerReady)
        }
      }
      .onChange(of: commandExecutor.showsSidebar) { _, isVisible in
        EditorWorkspaceLayoutStore.saveSidebarVisibility(
          isVisible, for: controller.workspaceURL)
      }
      .onChange(of: commandExecutor.bottomPanel) { _, panel in
        EditorWorkspaceLayoutStore.saveBottomPanel(panel, for: controller.workspaceURL)
        if panel == .terminal {
          terminal.startIfNeeded()
        }
      }
      .onChange(of: sidebarWidth) { _, width in
        EditorWorkspaceLayoutStore.saveSidebarWidth(width, for: controller.workspaceURL)
      }
      .onChange(of: bottomPanelHeight) { _, height in
        EditorWorkspaceLayoutStore.saveBottomPanelHeight(height, for: controller.workspaceURL)
      }
      .onChange(of: themeActivationKey) { _, _ in
        controller.activateTheme(for: colorScheme)
      }
      .onChange(of: controller.profile) { _, _ in
        themeBuilderSession.noteProfileChanged()
      }
      .onChange(of: controller.activeThemeSlot) { _, _ in
        themeBuilderSession.noteProfileChanged()
      }
      .onChange(of: controller.usesWorkspaceThemeOverrides) { _, _ in
        themeBuilderSession.noteProfileChanged()
      }
      .onChange(of: palette.focusRequestID) { _, _ in
        topSearchIsFocused = true
      }
      .onChange(of: controller.tabs.map(\.id)) { _, _ in
        reconcileWorkspaceTabs()
      }
      .onChange(of: controller.selectedTabID) { _, selectedID in
        workspaceTabs.synchronizeSelectedDocument(selectedID)
      }
      .onChange(of: documentOpenRequestID) { _, requestID in
        guard requestID != nil, let initialFileURL else { return }
        if lifecycle.state == .running {
          commandExecutor.openDocument(initialFileURL)
        } else {
          pendingDocumentOpenURL = initialFileURL
        }
      }
  }

  var themeActivationKey: ThemeActivationKey {
    ThemeActivationKey(
      systemScheme: colorScheme,
      appearanceModeRaw: appearanceModeRaw,
      forcedAppearanceRaw: controller.profile.forcedInterfaceAppearance?.rawValue
    )
  }

  var effectiveAppearanceMode: EditorInterfaceAppearance {
    controller.profile.forcedInterfaceAppearance
      ?? EditorInterfaceAppearance(rawValue: appearanceModeRaw)
      ?? .system
  }

  var rootView: some View {
    EditorWorkbenchRootView {
      EditorWorkspaceHeader(
        showsSidebar: $commandExecutor.showsSidebar,
        bottomPanel: $commandExecutor.bottomPanel,
        usesLiveMarkdownEditor: $usesLiveMarkdownEditor,
        showsMarkdownSyntax: $showsMarkdownSyntax,
        wrapsMarkdownLines: $markdownWrapsLines,
        searchQuery: $palette.query,
        showsSearchResults: $palette.isPresented,
        searchFocus: $topSearchIsFocused,
        profile: controller.profile,
        activeTabIsMarkdown: activeTabIsMarkdown,
        activeLanguageID: selectedDocumentTab?.languageID,
        workspacePhase: controller.phase,
        serviceReport: controller.serviceReport,
        isBuildRunning: commandAvailability.isBuilding,
        canBuild: commandAvailability.canBuild,
        canRun: commandAvailability.canRun,
        build: { commandExecutor.perform(.build) },
        run: { commandExecutor.perform(.run) },
        stop: { commandExecutor.perform(.stopBuild) },
        showPalette: showUnifiedPalette,
        searchCommand: sendPaletteKeyboardCommand,
        toggleBottomBar: { commandExecutor.perform(.toggleBottomPanel) }
      )
    } content: {
      EditorWorkspaceContentView(
        sidebarWidth: $sidebarWidth,
        showsSidebar: commandExecutor.showsSidebar
      ) {
        EditorWorkspaceSidebar(
          controller: controller,
          terminal: terminal,
          selectedFileURL: $selectedFileURL,
          showsBuildProjectControl: $showsBuildProjectControl,
          showsNowPlaying: $showsNowPlaying,
          nowPlaying: nowPlaying,
          openFile: commandExecutor.openDocument,
          openFileToSide: { url in
            if workspaceTabs.selection?.isUtility != false {
              Task {
                guard await commandExecutor.openAndSelectDocument(url) != nil else { return }
                sideOpenRequest = .init(url: url)
              }
            } else {
              sideOpenRequest = .init(url: url)
            }
          },
          fileVisibility: fileVisibility,
          openSettings: { commandExecutor.perform(.openSettings) },
          openThemeBuilder: { commandExecutor.perform(.openThemeBuilder) }
        )
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(controller.profile.workbench.sidebarBackground.color)
      } detail: {
        WorkspaceDetailContainer(
          controller: controller,
          terminal: terminal,
          executor: commandExecutor,
          workspaceTabs: workspaceTabs,
          themeBuilderSession: themeBuilderSession,
          sideOpenRequest: $sideOpenRequest,
          bottomPanelHeight: $bottomPanelHeight,
          usesLiveMarkdownEditor: usesLiveMarkdownEditor,
          showsMarkdownSyntax: showsMarkdownSyntax,
          wrapsMarkdownLines: markdownWrapsLines,
          requestCloseDocument: requestClose,
          requestCloseUtility: requestCloseUtility
        )
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
      }
    }
  }

  var activeTabIsMarkdown: Bool {
    guard let tab = selectedDocumentTab else { return false }
    return tab.languageID.lowercased() == "markdown"
      || ["md", "markdown", "mdown", "mkd"].contains(tab.url.pathExtension.lowercased())
  }

  var selectedDocumentTab: EditorTab? {
    guard case .document(let id) = workspaceTabs.selection else { return nil }
    return controller.tabs.first(where: { $0.id == id })
  }

  func reconcileWorkspaceTabs() {
    workspaceTabs.reconcile(
      documentIDs: controller.tabs.map(\.id),
      selectedDocumentID: controller.selectedTabID
    )
  }
}

nonisolated struct ThemeActivationKey: Equatable {
  let systemScheme: ColorScheme
  let appearanceModeRaw: String
  let forcedAppearanceRaw: String?
}
