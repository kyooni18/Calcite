import SwiftUI

/// Search and command entry point backed by the active backend window session.
@MainActor
struct CalciteCommandPalette: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession
  var showsSearchHeader = false

  var body: some View {
    CalciteCommandPaletteSurface(
      workspaceURL: backend.workspaceURL,
      mode: windowSession.palette.mode,
      actions: actions,
      openFile: { url in
        Task { @MainActor in
          _ = await windowSession.openDocument(at: url)
        }
      },
      dismiss: { windowSession.closeCommandPalette() },
      query: binding(
        get: { windowSession.palette.query },
        set: { windowSession.palette.query = $0 }
      ),
      includeIgnoredFiles: binding(
        get: { backend.fileVisibility.showsIgnoredFiles },
        set: { backend.fileVisibility.showsIgnoredFiles = $0 }
      ),
      includeBuildArtifacts: binding(
        get: { backend.fileVisibility.showsBuildArtifacts },
        set: { backend.fileVisibility.showsBuildArtifacts = $0 }
      ),
      includeHiddenFiles: binding(
        get: { backend.fileVisibility.showsHiddenFiles },
        set: { backend.fileVisibility.showsHiddenFiles = $0 }
      ),
      includeDSStore: binding(
        get: { backend.fileVisibility.showsDSStore },
        set: { backend.fileVisibility.showsDSStore = $0 }
      ),
      showsSearchHeader: showsSearchHeader,
      keyboardEvent: windowSession.palette.keyboardEvent
    )
  }

  private var actions: [CalciteCommandPaletteSurface.Action] {
    [
      command(
        "save",
        "Save",
        "square.and.arrow.down",
        category: "File",
        keywords: ["write", "document"],
        .save
      ),
      command(
        "save-all",
        "Save All",
        "square.and.arrow.down.on.square",
        category: "File",
        keywords: ["write", "documents"],
        .saveAll
      ),
      command(
        "open-item",
        "Open File or Folder",
        "folder",
        category: "File",
        keywords: ["project", "workspace"],
        .openFileOrFolder
      ),

      command(
        "find",
        "Find in Document",
        "magnifyingglass",
        category: "Editing",
        keywords: ["search", "text"],
        .find
      ),
      command(
        "replace",
        "Find and Replace",
        "arrow.left.arrow.right",
        category: "Editing",
        keywords: ["search", "text"],
        .replace
      ),
      command(
        "format",
        "Format Document",
        "text.alignleft",
        category: "Editing",
        keywords: ["code", "prettify"],
        .format
      ),
      command(
        "completion",
        "Show Completions",
        "text.badge.plus",
        category: "Editing",
        keywords: ["autocomplete", "suggestions"],
        .requestCompletion
      ),
      command(
        "input-mode",
        backend.controller.profile.vim.enabled ? "Use GUI Editing" : "Use Vim Editing",
        "keyboard",
        category: "Editing",
        keywords: ["mode", "vim", "gui"],
        .toggleInputMode
      ),
      command(
        "zoom-in",
        "Zoom In",
        "plus.magnifyingglass",
        category: "Editing",
        keywords: ["font", "scale"],
        .zoomIn
      ),
      command(
        "zoom-out",
        "Zoom Out",
        "minus.magnifyingglass",
        category: "Editing",
        keywords: ["font", "scale"],
        .zoomOut
      ),
      command(
        "zoom-reset",
        "Reset Zoom",
        "1.magnifyingglass",
        category: "Editing",
        keywords: ["font", "scale"],
        .resetZoom
      ),

      command(
        "definition",
        "Go to Definition",
        "arrow.turn.down.right",
        category: "Navigation",
        keywords: ["symbol", "declaration"],
        .goToDefinition
      ),
      command(
        "references",
        "Find References",
        "list.bullet.rectangle",
        category: "Navigation",
        keywords: ["symbol", "usages"],
        .findReferences
      ),
      command(
        "quick-help",
        "Show Quick Help",
        "questionmark.circle",
        category: "Navigation",
        keywords: ["documentation", "symbol"],
        .showQuickHelp
      ),

      command(
        "next-tab",
        "Next Tab",
        "arrow.right.to.line.compact",
        category: "Navigation",
        keywords: ["control tab", "document", "section tab"],
        .nextTab
      ),
      command(
        "previous-tab",
        "Previous Tab",
        "arrow.left.to.line.compact",
        category: "Navigation",
        keywords: ["control shift tab", "document", "section tab"],
        .previousTab
      ),
      command(
        "next-section",
        "Next Section",
        "rectangle.righthalf.inset.filled",
        category: "Navigation",
        keywords: ["control option right", "pane", "focus"],
        .nextSection
      ),
      command(
        "previous-section",
        "Previous Section",
        "rectangle.lefthalf.inset.filled",
        category: "Navigation",
        keywords: ["control option left", "pane", "focus"],
        .previousSection
      ),

      command("build", "Build Project", "hammer", category: "Build", .build),
      command("run", "Run Project", "play", category: "Build", .run),
      command("test", "Test Project", "checkmark.seal", category: "Build", .test),
      command("check", "Check Project", "checkmark.circle", category: "Build", .check),
      command("clean", "Clean Project", "trash", category: "Build", .clean),
      command("stop-build", "Stop Build or Run", "stop.fill", category: "Build", .stopBuild),

      command("debug-start", "Start Debugging", "ladybug", category: "Debug", .startDebug),
      command("debug-stop", "Stop Debugging", "stop.circle", category: "Debug", .stopDebug),
      command(
        "debug-continue", "Continue Debugging", "play.circle", category: "Debug", .continueDebug),
      command("debug-pause", "Pause Debugging", "pause.circle", category: "Debug", .pauseDebug),
      command("debug-step-over", "Step Over", "arrow.right.to.line", category: "Debug", .stepOver),
      command("debug-step-into", "Step Into", "arrow.down.to.line", category: "Debug", .stepInto),
      command("debug-step-out", "Step Out", "arrow.up.to.line", category: "Debug", .stepOut),
      command(
        "debug-breakpoint",
        "Toggle Breakpoint",
        "circle.fill",
        category: "Debug",
        .toggleBreakpoint
      ),
      action(
        "debug-panel",
        "Show Debug Panel",
        "ladybug",
        category: "Panels",
        keywords: ["bottom", "view"]
      ) {
        windowSession.sectionalLayout.presentTab(.debug)
      },
      action(
        "symbols",
        "Show Symbols",
        "list.bullet.indent",
        category: "Panels",
        keywords: ["outline", "table of contents", "document"]
      ) {
        windowSession.sectionalLayout.presentTab(.symbols)
      },

      command(
        "fast-panel",
        "Toggle Fast Panel",
        "rectangle.on.rectangle",
        category: "Panels",
        keywords: ["quick", "sections", "panels", "bolt"],
        .toggleFastPanel
      ),
      action(
        "fast-panel-active-section",
        "Toggle Active Section as Fast Panel",
        "bolt",
        category: "Panels",
        keywords: ["quick", "current pane", "section header"]
      ) {
        guard let sectionID = windowSession.sectionalLayout.activeSectionID else { return }
        windowSession.sectionalLayout.toggleFastPanelMembership(for: sectionID)
      },
      action(
        "fast-panel-file-tree",
        "Use File Tree as Fast Panel",
        "sidebar.left",
        category: "Panels",
        keywords: ["quick toggle", "customize", "multiple"]
      ) {
        windowSession.setFastPanelTarget(.fileTree, enabled: true)
      },
      action(
        "fast-panel-bottom-view",
        "Use Bottom View as Fast Panel",
        "rectangle.bottomhalf.inset.filled",
        category: "Panels",
        keywords: ["quick toggle", "customize", "multiple"]
      ) {
        windowSession.setFastPanelTarget(.bottomView, enabled: true)
      },
      command(
        "file-tree",
        "Toggle File Tree",
        "sidebar.left",
        category: "Panels",
        keywords: ["sidebar", "files"],
        .toggleSidebar
      ),
      command(
        "bottom-view",
        "Toggle Bottom View",
        "rectangle.bottomhalf.inset.filled",
        category: "Panels",
        keywords: ["terminal", "problems", "build output"],
        .toggleBottomPanel
      ),
      command("terminal", "Show Terminal", "terminal", category: "Panels", .showTerminal),
      command(
        "problems",
        "Show Problems",
        "exclamationmark.triangle",
        category: "Panels",
        .showProblems
      ),
      action(
        "build-output",
        "Show Build Output",
        "hammer",
        category: "Panels",
        keywords: ["logs", "bottom view"]
      ) {
        windowSession.sectionalLayout.presentTab(.buildOutput)
      },
      command("settings", "Open Settings", "gearshape", category: "Panels", .openSettings),
      command(
        "theme-builder",
        "Open Theme Builder",
        "paintpalette",
        category: "Panels",
        .openThemeBuilder
      ),

      command(
        "layout-customize",
        windowSession.sectionalLayout.isCustomizing
          ? "Finish Layout Customization" : "Customize Layout",
        "slider.horizontal.3",
        category: "Layout",
        keywords: ["sections", "arrange"],
        .toggleLayoutCustomization
      ),
      action(
        "layout-standard",
        "Apply Standard Layout",
        "rectangle.3.group",
        category: "Layout",
        keywords: ["sidebar", "editor", "bottom view"]
      ) {
        windowSession.sectionalLayout.applyPreset(.standard)
      },
      action(
        "layout-editor-focus",
        "Apply Editor Focus Layout",
        "rectangle",
        category: "Layout"
      ) {
        windowSession.sectionalLayout.applyPreset(.editorFocus)
      },
      action(
        "layout-side-by-side",
        "Apply Side by Side Layout",
        "rectangle.split.2x1",
        category: "Layout"
      ) {
        windowSession.sectionalLayout.applyPreset(.sideBySide)
      },
      action(
        "layout-debugging",
        "Apply Debugging Layout",
        "ladybug",
        category: "Layout"
      ) {
        windowSession.sectionalLayout.applyPreset(.debugging)
      },

      command(
        "terminal-restart",
        "Restart Terminal",
        "arrow.clockwise",
        category: "Terminal",
        .restartTerminal
      ),
      command(
        "terminal-clear",
        "Clear Terminal",
        "clear",
        category: "Terminal",
        .clearTerminal
      ),
      command(
        "terminal-external",
        "Open External Terminal",
        "macwindow",
        category: "Terminal",
        .openExternalTerminal
      ),

      command(
        "filter-hidden",
        backend.fileVisibility.showsHiddenFiles ? "Exclude Hidden Files" : "Include Hidden Files",
        "eye",
        category: "Search Filters",
        keywords: ["dotfiles"],
        .toggleHiddenFiles
      ),
      command(
        "filter-ignored",
        backend.fileVisibility.showsIgnoredFiles
          ? "Exclude Ignored Files" : "Include Ignored Files",
        "eye.slash",
        category: "Search Filters",
        keywords: ["gitignore"],
        .toggleIgnoredFiles
      ),
      command(
        "filter-build",
        backend.fileVisibility.showsBuildArtifacts
          ? "Exclude Build Artifacts" : "Include Build Artifacts",
        "shippingbox",
        category: "Search Filters",
        keywords: ["derived data", "target", "dist"],
        .toggleBuildArtifacts
      ),
      command(
        "filter-dsstore",
        backend.fileVisibility.showsDSStore ? "Exclude .DS_Store" : "Include .DS_Store",
        "internaldrive",
        category: "Search Filters",
        .toggleDSStore
      ),
    ]
  }

  private func command(
    _ id: String,
    _ title: String,
    _ systemImage: String,
    category: String,
    keywords: [String] = [],
    _ command: EditorCommand
  ) -> CalciteCommandPaletteSurface.Action {
    action(id, title, systemImage, category: category, keywords: keywords) {
      windowSession.perform(command)
    }
  }

  private func action(
    _ id: String,
    _ title: String,
    _ systemImage: String,
    category: String,
    keywords: [String] = [],
    perform: @escaping () -> Void
  ) -> CalciteCommandPaletteSurface.Action {
    CalciteCommandPaletteSurface.Action(
      id: id,
      title: title,
      systemImage: systemImage,
      category: category,
      keywords: keywords,
      perform: perform
    )
  }

  private func binding<Value>(
    get: @escaping @MainActor @Sendable () -> Value,
    set: @escaping @MainActor @Sendable (Value) -> Void
  ) -> Binding<Value> {
    Binding(get: get, set: set)
  }
}
