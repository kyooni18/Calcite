import AppKit
import EditorServices
@_spi(Calcite) import EditorVim
import SwiftUI
import UniformTypeIdentifiers

struct ServiceSettingsView: View {
  enum Page: String, CaseIterable, Identifiable {
    case services = "Services"
    case editor = "Editor"
    case build = "Build"
    case debug = "Debug"

    var id: String { rawValue }
  }

  @ObservedObject var controller: EditorWorkspaceController
  let openFile: (URL) -> Void
  @State private var page: Page = .services
  @State private var searchQuery = ""

  var body: some View {
    VStack(spacing: 0) {
      TextField("Search settings", text: $searchQuery)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal)
        .padding(.top)

      if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        settingsSearchResults
          .padding(.horizontal)
          .padding(.top, 6)
      }

      Picker("Settings Page", selection: $page) {
        ForEach(Page.allCases) { page in
          Text(page.rawValue).tag(page)
        }
      }
      .pickerStyle(.segmented)
      .padding()

      Divider()

      switch page {
      case .services:
        EditorServicesSettingsView(
          model: controller.serviceSettingsModel,
          onApply: controller.applyServicesConfiguration
        )
      case .editor:
        EditorProfileSettingsView(controller: controller)
      case .build:
        EditorBuildSettingsView(
          controller: controller,
          buildController: controller.buildController,
          openFile: openFile
        )
      case .debug:
        EditorDebugSettingsView(controller: controller)
      }
    }
    .navigationTitle("Advanced Settings")
  }

  private var settingsSearchResults: some View {
    let results = Page.allCases.filter {
      $0.rawValue.localizedCaseInsensitiveContains(searchQuery)
        || keywords(for: $0).localizedCaseInsensitiveContains(searchQuery)
    }
    return Group {
      if results.isEmpty {
        Text("No settings match \"\(searchQuery)\".")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(spacing: 6) {
          Text("Matches:").font(.caption).foregroundStyle(.secondary)
          ForEach(results) { result in
            Button(result.rawValue) { page = result }
              .controlSize(.small)
          }
          Spacer()
        }
      }
    }
  }

  private func keywords(for page: Page) -> String {
    switch page {
    case .services: return "language server completion syntax diagnostics formatter"
    case .editor:
      return
        "theme font color typing vim neovim terminal editor keybindings snippets search replace"
    case .build: return "build run test check task command"
    case .debug: return "debug executable arguments working directory"
    }
  }
}

struct EditorProfileSettingsView: View {
  @ObservedObject var controller: EditorWorkspaceController
  @Binding private var profile: EditorCustomProfile
  @State private var selectedThemeSlot: EditorThemeSlot
  @State private var importMessage: String?
  @State private var pendingThemeCandidates: [EditorThemeImportCandidate] = []
  @State private var pendingThemeSourceURL: URL?
  @State private var pendingThemeTemporaryURL: URL?
  @AppStorage("editorAppearanceMode") private var appearanceModeRaw =
    EditorInterfaceAppearance.system.rawValue
  @AppStorage(EditorExternalTerminalPreferences.applicationKey)
  private var externalTerminalRaw = EditorExternalTerminalApplication.automatic.rawValue
  @AppStorage(EditorExternalTerminalPreferences.customCommandKey)
  private var externalTerminalCommand = ""
  @AppStorage(EditorInterfacePreferences.interfaceKey)
  private var editorInterfaceRaw = EditorInterface.builtIn.rawValue
  @AppStorage(EditorInterfacePreferences.neovimLaunchCommandKey)
  private var neovimLaunchCommand = ""
  @AppStorage(EditorInterfacePreferences.vimLaunchCommandKey)
  private var vimLaunchCommand = ""
  @AppStorage(EditorInterfacePreferences.terminalLeaderKey)
  private var terminalEditorLeader = "\\"
  @AppStorage(EditorInterfacePreferences.showsEditorTabBarKey)
  private var showsEditorTabBar = true

  init(controller: EditorWorkspaceController) {
    self.controller = controller
    _profile = Binding(
      get: { controller.profile },
      set: { controller.setProfile($0, for: controller.activeThemeSlot) }
    )
    _selectedThemeSlot = State(initialValue: controller.activeThemeSlot)
  }

  var body: some View {
    HSplitView {
      ScrollView {
        Form {
          themeImport
          appearanceAndTerminal
          typography
          surface
          workbench
          terminalColors
          highlights
          syntax
          behavior
          vim
          snippets
          Section {
            Button("Restore Default Editor Profile", role: .destructive) {
              profile = selectedThemeSlot == .light ? .light : .standard
              importMessage = nil
            }
          }
        }
        .formStyle(.grouped)
      }
      .frame(minWidth: 360, idealWidth: 440)

      ThemeEditorPreview(profile: profile)
        .frame(minWidth: 430)
    }
    .confirmationDialog(
      "Choose Theme Variant",
      isPresented: pendingThemeCandidatesBinding,
      titleVisibility: .visible
    ) {
      ForEach(pendingThemeCandidates) { candidate in
        Button(candidate.name) { importPendingThemeCandidate(candidate) }
      }
      Button("Cancel", role: .cancel) { clearPendingThemeImport() }
    } message: {
      Text("This source contains multiple themes. Choose the variant to import.")
    }
  }

  private var themeImport: some View {
    Section("Theme") {
      Toggle(
        "Use Theme Overrides for This Workspace",
        isOn: Binding(
          get: { controller.usesWorkspaceThemeOverrides },
          set: { controller.setUsesWorkspaceThemeOverrides($0) }
        )
      )
      Text("Workspace overrides take priority over the app-wide light and dark themes.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("Theme for Appearance", selection: $selectedThemeSlot) {
        ForEach(EditorThemeSlot.allCases) { slot in
          Text(slot.title).tag(slot)
        }
      }
      .pickerStyle(.segmented)
      .onChange(of: selectedThemeSlot) { _, slot in
        controller.activateThemeSlot(slot)
      }

      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(profile.themeMetadata.importedName ?? "Custom")
            .font(.headline)
          Text("Import VS Code, TextMate, Vim, Neovim JSON/Lua, theme folders, or VSIX archives")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Import Theme…", systemImage: "square.and.arrow.down") {
          importTheme()
        }
        Button("Reimport", systemImage: "arrow.clockwise") {
          reimportTheme()
        }
        .disabled(profile.themeMetadata.sourcePath == nil)
      }

      Picker("Imported Theme Appearance", selection: $profile.themeMetadata.importedAppearance) {
        ForEach(EditorImportedThemeAppearance.allCases) { appearance in
          Text(appearance.title).tag(appearance)
        }
      }
      if profile.themeMetadata.sourcePath != nil {
        LabeledContent("Detected Appearance") {
          Text(profile.detectedThemeSlot.title)
        }
        if profile.themeMetadata.importedAppearance == .automatic,
          profile.detectedThemeSlot != selectedThemeSlot
        {
          Label(
            "This theme looks \(profile.detectedThemeSlot.title.lowercased()), but it is stored in the \(selectedThemeSlot.title.lowercased()) slot.",
            systemImage: "circle.lefthalf.filled"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }
      }

      if let sourcePath = profile.themeMetadata.sourcePath {
        LabeledContent("Source") {
          Text(sourcePath)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
        }
        if let variant = profile.themeMetadata.sourceVariantPath {
          LabeledContent("Variant") {
            Text(variant)
              .font(.caption.monospaced())
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        if importedThemeSourceChanged {
          Label(
            "The source changed on disk. Reimport to update this theme.",
            systemImage: "arrow.triangle.2.circlepath"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }
      }
      ForEach(themeWarnings, id: \.self) { warning in
        Label(warning, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      if let importMessage {
        Text(importMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      } else if !profile.themeMetadata.importerDiagnostics.isEmpty {
        Text(profile.themeMetadata.importerDiagnostics.joined(separator: "\n"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  private var importedThemeSourceChanged: Bool {
    guard let url = profile.themeMetadata.monitoredSourceURL,
      let importedTime = profile.themeMetadata.sourceModificationTime
    else { return false }
    let currentTime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate?.timeIntervalSince1970
    guard let currentTime else { return !FileManager.default.fileExists(atPath: url.path) }
    return abs(currentTime - importedTime) > 0.001
  }

  private var themeWarnings: [String] {
    var warnings: [String] = []
    let editorContrast = profile.surface.foreground.contrastRatio(
      against: profile.surface.background)
    if editorContrast < 4.5 {
      warnings.append("Editor text contrast is low (\(editorContrast, default: "%.2f"):1).")
    }
    let windowContrast = profile.workbench.foreground.contrastRatio(
      against: profile.workbench.windowBackground
    )
    if windowContrast < 4.5 {
      warnings.append("Window text contrast is low (\(windowContrast, default: "%.2f"):1).")
    }
    if profile.surface.backgroundOpacity < 0.75 || profile.surface.background.alpha < 0.75 {
      warnings.append("The editor background is highly transparent and may reduce readability.")
    }
    if profile.workbench.windowBackground.alpha < 0.9 {
      warnings.append(
        "The window background is translucent; menus and panels may not match the theme exactly.")
    }
    return warnings
  }

  private var appearanceAndTerminal: some View {
    Section("Window and Terminal Editors") {
      Picker("App Appearance", selection: $appearanceModeRaw) {
        ForEach(EditorInterfaceAppearance.allCases) { appearance in
          Text(appearance.title).tag(appearance.rawValue)
        }
      }
      Picker("External Terminal", selection: $externalTerminalRaw) {
        ForEach(EditorExternalTerminalApplication.allCases) { application in
          Text(application.title).tag(application.rawValue)
        }
      }
      if externalTerminalRaw == EditorExternalTerminalApplication.custom.rawValue {
        TextField("Command; use {path} for the workspace", text: $externalTerminalCommand)
          .font(.system(.body, design: .monospaced))
      }
      Picker("Editor Mode", selection: $editorInterfaceRaw) {
        ForEach(EditorInterface.allCases) { interface in
          Text(interface.title).tag(interface.rawValue)
        }
      }
      Toggle("Show Editor Tab Bar", isOn: $showsEditorTabBar)
      Text(
        "Default and Calcite Vim use the native editor. Vim and Neovim replace only its editing surface and keep Calcite's tabs, sections, and commands."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var pendingThemeCandidatesBinding: Binding<Bool> {
    Binding(
      get: { !pendingThemeCandidates.isEmpty },
      set: { if !$0 { clearPendingThemeImport() } }
    )
  }

  private func importTheme() {
    let panel = NSOpenPanel()
    panel.title = "Import Editor Theme, Theme Folder, or VSIX"
    panel.prompt = "Import"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.json, .xmlPropertyList, .plainText, .data, .directory]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    loadTheme(from: url, preferredVariantPath: nil)
  }

  private func reimportTheme() {
    guard let path = profile.themeMetadata.sourcePath else { return }
    loadTheme(
      from: URL(fileURLWithPath: path),
      preferredVariantPath: profile.themeMetadata.sourceVariantPath
    )
  }

  private func loadTheme(from sourceURL: URL, preferredVariantPath: String?) {
    var temporaryURL: URL?
    do {
      let importURL: URL
      if sourceURL.pathExtension.lowercased() == "vsix" {
        let extracted = try extractVSIX(sourceURL)
        temporaryURL = extracted
        let extensionRoot = extracted.appendingPathComponent("extension", isDirectory: true)
        var isDirectory: ObjCBool = false
        importURL =
          FileManager.default.fileExists(
            atPath: extensionRoot.path, isDirectory: &isDirectory) && isDirectory.boolValue
          ? extensionRoot : extracted
      } else {
        importURL = sourceURL
      }

      let candidates = try EditorThemeImporter.discoverThemes(in: importURL)
      if let preferredVariantPath {
        guard let candidate = candidates.first(where: { $0.relativePath == preferredVariantPath })
        else {
          throw EditorThemeImportError.invalidRoot(
            "The previously selected theme variant no longer exists: \(preferredVariantPath)"
          )
        }
        let result = try EditorThemeImporter.load(candidate)
        applyImportedThemeResult(
          result,
          sourceURL: sourceURL,
          sourceVariantPath: preferredVariantPath
        )
      } else if candidates.count > 1 {
        clearPendingThemeImport()
        pendingThemeCandidates = candidates
        pendingThemeSourceURL = sourceURL
        pendingThemeTemporaryURL = temporaryURL
        temporaryURL = nil
        return
      } else if let candidate = candidates.first {
        let result = try EditorThemeImporter.load(candidate)
        applyImportedThemeResult(
          result,
          sourceURL: sourceURL,
          sourceVariantPath: candidate.relativePath
        )
      } else {
        let result = try EditorThemeImporter.load(from: importURL)
        applyImportedThemeResult(
          result,
          sourceURL: sourceURL,
          sourceVariantPath: nil
        )
      }
      if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    } catch {
      if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
      importMessage =
        "Could not import \(sourceURL.lastPathComponent): \(error.localizedDescription)"
    }
  }

  private func importPendingThemeCandidate(_ candidate: EditorThemeImportCandidate) {
    guard let sourceURL = pendingThemeSourceURL else {
      clearPendingThemeImport()
      return
    }
    do {
      let result = try EditorThemeImporter.load(candidate)
      applyImportedThemeResult(
        result,
        sourceURL: sourceURL,
        sourceVariantPath: candidate.relativePath
      )
    } catch {
      importMessage = "Could not import \(candidate.name): \(error.localizedDescription)"
    }
    clearPendingThemeImport()
  }

  private func applyImportedThemeResult(
    _ result: EditorThemeImportResult,
    sourceURL: URL,
    sourceVariantPath: String?
  ) {
    var updated = profile
    updated.applyImportedTheme(
      result.theme,
      sourceURL: sourceURL,
      sourceVariantPath: sourceVariantPath,
      diagnostics: result.diagnostics
    )
    profile = updated
    if result.diagnostics.isEmpty {
      importMessage = "Imported \(result.theme.name) from \(sourceURL.lastPathComponent)."
    } else {
      importMessage = result.diagnostics.map(\.message).joined(separator: "\n")
    }
  }

  private func clearPendingThemeImport() {
    if let pendingThemeTemporaryURL {
      try? FileManager.default.removeItem(at: pendingThemeTemporaryURL)
    }
    pendingThemeCandidates = []
    pendingThemeSourceURL = nil
    pendingThemeTemporaryURL = nil
  }

  private func extractVSIX(_ url: URL) throws -> URL {
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteTheme-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", url.path, destination.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      try? FileManager.default.removeItem(at: destination)
      throw CocoaError(.fileReadCorruptFile)
    }
    return destination
  }

  private var typography: some View {
    Section("Typography") {
      TextField("Font Family", text: $profile.font.family)
      Picker("Weight", selection: $profile.font.weight) {
        ForEach(EditorFontWeight.allCases) { weight in
          Text(weight.rawValue.capitalized).tag(weight)
        }
      }
      LabeledContent("Size") {
        TextField("Size", value: $profile.font.size, format: .number)
          .frame(width: 90)
      }
      LabeledContent("Line Spacing") {
        TextField("Line Spacing", value: $profile.font.lineSpacing, format: .number)
          .frame(width: 90)
      }
    }
  }

  private var surface: some View {
    Section("Surface") {
      ProfileColorRow(title: "Text", value: $profile.surface.foreground)
      ProfileColorRow(title: "Background", value: $profile.surface.background)
      ProfileColorRow(title: "Insertion Cursor", value: $profile.surface.cursor)
      Picker("Cursor Shape", selection: $profile.surface.cursorStyle) {
        ForEach(EditorCursorStyle.allCases) { style in
          Text(style.title).tag(style)
        }
      }
      ProfileColorRow(title: "Selection", value: $profile.surface.selection)
      VStack(alignment: .leading) {
        LabeledContent(
          "Background Opacity",
          value: profile.surface.backgroundOpacity.formatted(.percent.precision(.fractionLength(0)))
        )
        Slider(value: $profile.surface.backgroundOpacity, in: 0.05...1)
      }
    }
  }

  private var workbench: some View {
    Section("Window Colors") {
      ProfileColorRow(title: "Window Text", value: $profile.workbench.foreground)
      ProfileColorRow(title: "Muted Text", value: $profile.workbench.mutedForeground)
      ProfileColorRow(title: "Window Background", value: $profile.workbench.windowBackground)
      ProfileColorRow(title: "Sidebar", value: $profile.workbench.sidebarBackground)
      ProfileColorRow(title: "Panel", value: $profile.workbench.panelBackground)
      ProfileColorRow(title: "Toolbar", value: $profile.workbench.toolbarBackground)
      ProfileColorRow(title: "Active Tab", value: $profile.workbench.activeTabBackground)
      ProfileColorRow(title: "Inactive Tab", value: $profile.workbench.inactiveTabBackground)
      ProfileColorRow(title: "Input", value: $profile.workbench.inputBackground)
      ProfileColorRow(title: "Border", value: $profile.workbench.border)
      ProfileColorRow(title: "Accent", value: $profile.workbench.accent)
    }
  }

  private var terminalColors: some View {
    Section("Terminal Colors") {
      ProfileColorRow(title: "Foreground", value: $profile.terminal.foreground)
      ProfileColorRow(title: "Background", value: $profile.terminal.background)
      DisclosureGroup("ANSI Palette") {
        ForEach(profile.terminal.ansi.indices, id: \.self) { index in
          ProfileColorRow(
            title: "ANSI \(index)",
            value: Binding(
              get: { profile.terminal.ansi[index] },
              set: { profile.terminal.ansi[index] = $0 }
            )
          )
        }
      }
    }
  }

  private var highlights: some View {
    Section("Highlights and Diagnostics") {
      ProfileColorRow(title: "Current Line", value: $profile.highlights.currentLine)
      ProfileColorRow(title: "Search Result", value: $profile.highlights.searchResult)
      ProfileColorRow(title: "Error", value: $profile.highlights.error)
      ProfileColorRow(title: "Warning", value: $profile.highlights.warning)
      ProfileColorRow(title: "Information", value: $profile.highlights.information)
      ProfileColorRow(title: "Hint", value: $profile.highlights.hint)
    }
  }

  private var syntax: some View {
    Section("Syntax Colors") {
      DisclosureGroup("Literals") {
        ProfileColorRow(title: "Keyword", value: $profile.syntax.literals.keyword)
        ProfileColorRow(title: "String", value: $profile.syntax.literals.string)
        ProfileColorRow(title: "Number", value: $profile.syntax.literals.number)
        ProfileColorRow(title: "Comment", value: $profile.syntax.literals.comment)
        ProfileColorRow(title: "Directive", value: $profile.syntax.literals.directive)
      }
      DisclosureGroup("Symbols") {
        ProfileColorRow(title: "Type", value: $profile.syntax.symbols.type)
        ProfileColorRow(title: "Function", value: $profile.syntax.symbols.function)
        ProfileColorRow(title: "Variable", value: $profile.syntax.symbols.variable)
        ProfileColorRow(title: "Property", value: $profile.syntax.symbols.property)
        ProfileColorRow(title: "Operator", value: $profile.syntax.symbols.operator)
        ProfileColorRow(title: "Punctuation", value: $profile.syntax.symbols.punctuation)
      }
    }
  }

  private var behavior: some View {
    Section("Editor Behavior") {
      Stepper(
        "Tab Width: \(profile.behavior.tabWidth)",
        value: $profile.behavior.tabWidth,
        in: 1...16
      )
      Toggle("Insert Spaces", isOn: $profile.behavior.insertSpaces)
      Toggle("Show Line Numbers", isOn: $profile.behavior.showLineNumbers)
      Toggle("Show Diagnostics", isOn: $profile.behavior.showDiagnostics)
      Toggle(
        "Show Inline Diagnostic Messages", isOn: $profile.behavior.showInlineDiagnosticMessages
      )
      .disabled(!profile.behavior.showDiagnostics)
      Divider()
      Toggle("Auto-close Brackets and Quotes", isOn: $profile.typing.closePairs)
      Toggle("Surround Selected Text", isOn: $profile.typing.surroundSelection)
      Toggle("Smart Newline Indentation", isOn: $profile.typing.smartNewlines)
      Toggle("Delete Empty Pairs Together", isOn: $profile.typing.deleteBalancedPairs)
      VStack(alignment: .leading) {
        LabeledContent(
          "Suggestion Delay",
          value: "\(profile.behavior.suggestionDelay, default: "%.2f") s"
        )
        Slider(value: $profile.behavior.suggestionDelay, in: 0...1, step: 0.01)
      }
    }
  }

  private var vim: some View {
    Section("Vim Keybindings") {
      Picker("Editor Mode", selection: $editorInterfaceRaw) {
        ForEach(EditorInterface.allCases) { interface in
          Text(interface.title).tag(interface.rawValue)
        }
      }
      Toggle("Start in Insert Mode", isOn: $profile.vim.startInInsertMode)
        .disabled(editorMode != .calciteVim)
      Toggle("Relative Line Numbers", isOn: $profile.vim.relativeLineNumbers)
        .disabled(editorMode != .calciteVim)
      Picker("Command Keyboard", selection: $profile.vim.keyboardPolicy) {
        ForEach(EditorVimKeyboardPolicy.allCases) { policy in
          Text(policy.title).tag(policy)
        }
      }
      .disabled(editorMode != .calciteVim)
      Text(
        "Automatic keeps Normal-mode commands on their US-QWERTY key positions while Insert, Replace, search, command, and character arguments use the active input method."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      if profile.vim.keyboardPolicy == .languageMap {
        TextField("Language map, for example ㅗ=h,ㅓ=j,ㅏ=k,ㅣ=l", text: $profile.vim.languageMap)
          .font(.system(.body, design: .monospaced))
          .disabled(editorMode != .calciteVim)
        Text("Use comma- or whitespace-separated source=Vim-key pairs.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Stepper(
        "Mapping Timeout: \(profile.vim.mappingTimeoutMilliseconds) ms",
        value: $profile.vim.mappingTimeoutMilliseconds,
        in: 0...5_000,
        step: 50
      )
      .disabled(editorMode != .calciteVim)
      Text(
        "Set this to 0 for immediate resolution; longer values make ambiguous mappings easier to enter."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Picker("Normal Cursor Shape", selection: $profile.vim.normalCursorStyle) {
        ForEach(EditorVimCursorStyle.allCases) { style in
          Text(style.title).tag(style)
        }
      }
      .disabled(editorMode != .calciteVim)
      Picker("Insert Cursor Shape", selection: $profile.vim.insertCursorStyle) {
        ForEach(EditorVimCursorStyle.allCases) { style in
          Text(style.title).tag(style)
        }
      }
      .disabled(editorMode != .calciteVim)
      Picker("Replace Cursor Shape", selection: $profile.vim.replaceCursorStyle) {
        ForEach(EditorVimCursorStyle.allCases) { style in
          Text(style.title).tag(style)
        }
      }
      .disabled(editorMode != .calciteVim)
      HStack {
        Text("Calcite Vim Leader")
        Spacer()
        Text("Space")
          .frame(width: 90, alignment: .leading)
          .accessibilityIdentifier("calcite.vim.leader-key")
      }
      Text("Current leader: \(leaderKeyDescription)")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(
        "Calcite uses Space as its leader throughout the IDE; text fields and terminals keep their normal input behavior."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Text(
        "Terminal Vim/Neovim uses \\ as a secondary Calcite leader: it supports the same build, run, sidebar, section, and tab mappings as Calcite Vim. Space text input is never held while Calcite waits for a leader key."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack {
        Text("Vim/Neovim Leader")
        Spacer()
        TextField("\\", text: terminalEditorLeaderKey)
          .textFieldStyle(.roundedBorder)
          .frame(width: 90)
          .accessibilityIdentifier("calcite.terminal-vim.leader-key")
      }
      Text("This leader is passed only to the real Vim or Neovim process.")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField(
        "Neovim launch shell command (empty uses default)",
        text: $neovimLaunchCommand
      )
      .font(.system(.body, design: .monospaced))
      TextField(
        "Vim launch shell command (empty uses default)",
        text: $vimLaunchCommand
      )
      .font(.system(.body, design: .monospaced))
      Text(
        "A custom command may be an alias or function: Calcite appends the leader setup and file path. Use {executable}, {file}, {workspace}, {leader}, or {leaderCommand} to place those arguments yourself; values are shell-quoted."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      ForEach($profile.vim.mappings) { $mapping in
        VStack(alignment: .leading, spacing: 7) {
          HStack {
            TextField("Keys", text: $mapping.sequence)
              .font(.system(.body, design: .monospaced))
            TextField("Command", text: $mapping.command)
              .font(.system(.body, design: .monospaced))
            Button("Remove", systemImage: "minus.circle", role: .destructive) {
              profile.vim.mappings.removeAll { $0.id == mapping.id }
            }
            .labelStyle(.iconOnly)
          }
          HStack(spacing: 12) {
            Menu {
              ForEach(EditorVimMappingMode.allCases) { mode in
                Button {
                  if mapping.modes.contains(mode) {
                    if mapping.modes.count > 1 { mapping.modes.remove(mode) }
                  } else {
                    mapping.modes.insert(mode)
                  }
                } label: {
                  Label(
                    mode.title,
                    systemImage: mapping.modes.contains(mode) ? "checkmark" : "circle"
                  )
                }
              }
            } label: {
              Text(
                mapping.modes.sorted { $0.rawValue < $1.rawValue }.map(\.title)
                  .joined(separator: ", ")
              )
              .lineLimit(1)
            }
            .frame(maxWidth: 180, alignment: .leading)

            Toggle("Recursive", isOn: $mapping.recursive)
              .toggleStyle(.checkbox)
            Toggle("No wait", isOn: $mapping.nowait)
              .toggleStyle(.checkbox)
            Picker("Input", selection: $mapping.inputDomain) {
              ForEach(EditorVimMappingInputDomain.allCases) { domain in
                Text(domain.title).tag(domain)
              }
            }
            .labelsHidden()
            .frame(maxWidth: 130)
          }
          .font(.caption)
          if hasMappingConflict(mapping) {
            Label(
              "Another mapping uses the same keys in an overlapping mode.",
              systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
          }
        }
        .padding(.vertical, 3)
      }
      Button("Add Key Mapping", systemImage: "plus") {
        profile.vim.mappings.append(.init(sequence: "<leader>", command: ""))
      }
      Text(
        "Commands may be Vim notation, Ex commands such as :w, or host actions such as <host:find>, <host:replace>, <host:build>, <host:run>, <host:test>, and <host:terminal>. Default mappings: <leader>s opens Find; <leader>h/j/k/l navigate sections; <leader>,/. and <leader>1–9 navigate tabs."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func hasMappingConflict(_ mapping: EditorVimMappingProfile) -> Bool {
    profile.vim.mappings.contains { other in
      other.id != mapping.id && other.sequence == mapping.sequence
        && other.inputDomain == mapping.inputDomain
        && !other.modes.isDisjoint(with: mapping.modes)
    }
  }

  private var leaderKeyDescription: String {
    "Space"
  }

  private var editorMode: EditorInterface {
    EditorInterface(rawValue: editorInterfaceRaw) ?? .builtIn
  }

  private var terminalEditorLeaderKey: Binding<String> {
    Binding(
      get: {
        EditorInterfacePreferences.normalizedTerminalLeader()
      },
      set: { input in
        terminalEditorLeader = input.first.flatMap { $0.isWhitespace ? nil : String($0) } ?? "\\"
      }
    )
  }

  private var snippets: some View {
    Section("Snippets") {
      Toggle("Built-in Language Snippets", isOn: $profile.snippets.includeBuiltins)
      Toggle("Load Project and VS Code Snippets", isOn: $profile.snippets.includeProjectFiles)
      ForEach($profile.snippets.custom) { $snippet in
        DisclosureGroup(snippet.trigger.isEmpty ? "New Snippet" : snippet.trigger) {
          TextField("Language ID", text: $snippet.languageID)
          TextField("Trigger", text: $snippet.trigger)
          TextField("Summary", text: $snippet.summary)
          TextEditor(text: $snippet.body)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 90)
          Button("Remove Snippet", role: .destructive) {
            profile.snippets.custom.removeAll { $0.id == snippet.id }
          }
        }
      }
      Button("Add Snippet", systemImage: "plus") {
        profile.snippets.custom.append(
          .init(languageID: "*", trigger: "", body: "${1:value}${0}")
        )
      }
      Text(
        "Project snippets are loaded from .calcite/snippets.json and .vscode/*.code-snippets. VS Code placeholder syntax is supported."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

}

private struct ThemeEditorPreview: View {
  let profile: EditorCustomProfile
  @State private var text = Self.sample
  @State private var revision: UInt64 = 0
  @State private var selection = NSRange(location: 0, length: 0)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("Live Preview", systemImage: "paintpalette")
          .font(.headline)
        Spacer()
        Text("Swift")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 14)
      .frame(height: 44)
      Divider()
      CodeTextEditor(
        text: text,
        textRevision: revision,
        presentationRevision: revision,
        languageID: "swift",
        profile: profile,
        syntaxHighlights: Self.highlights,
        semanticHighlights: [],
        diagnostics: [],
        showsInlineDiagnosticMessages: profile.behavior.showInlineDiagnosticMessages,
        breakpoints: [],
        selectedRange: selection,
        hasCompletions: false,
        vimHistory: VimHistorySnapshot(),
        documentURL: nil,
        documentID: nil,
        editorSessionID: nil,
        tabPageID: nil,
        sharedVimController: nil,
        onWillEdit: {},
        onEdit: { _, _, resultingText, selectionAfter in
          text = resultingText
          selection = selectionAfter
          revision &+= 1
        },
        onVimEdit: { transaction, selectionAfter in
          text = transaction.afterState.text
          selection = selectionAfter
          revision &+= 1
        },
        onSelectionChange: { selection = $0 },
        onToggleBreakpoint: { _ in },
        onAcceptCompletion: {},
        onMoveCompletionDown: {},
        onMoveCompletionUp: {},
        onDismissCompletions: {},
        onRequestCompletions: {},
        onMoveToNextSnippetStop: { false },
        onMoveToPreviousSnippetStop: { false },
        onVimHostInvocation: { invocation in
          .rejected(
            .unsupportedCapability(
              VimHostCapabilities.capability(for: invocation.request)
            )
          )
        },
        onGoToDefinition: {},
        onFindReferences: {},
        onShowQuickHelp: {},
        onShowFind: { _ in },
        zoomScale: 1,
        onZoomChange: { _ in },
        onVimModeChange: { _ in },
        onVimPromptChange: { _ in },
        onVimInteractionChange: { _ in },
        onVimInputSourceChange: { _ in },
        onCaretRectChange: { _ in }
      )
    }
    .background(profile.surface.background.color)
  }

  private static let sample = """
    import SwiftUI

    // Themes update this real editor preview immediately.
    struct WelcomeView: View {
      let greeting = "Hello, Calcite!"
      @State private var count = 42

      var body: some View {
        Button(greeting) {
          count += 1
        }
        .tint(.blue)
      }
    }
    """

  private static let highlights: [Highlight] = {
    let tokens: [(String, String)] = [
      ("import", "keyword"), ("SwiftUI", "type"),
      ("// Themes update this real editor preview immediately.", "comment"),
      ("struct", "keyword"), ("WelcomeView", "type"), ("View", "type"),
      ("let", "keyword"), ("greeting", "variable"), ("\"Hello, Calcite!\"", "string"),
      ("@State", "attribute"), ("private", "keyword"), ("var", "keyword"),
      ("count", "variable"), ("42", "number"), ("body", "property"),
      ("some", "keyword"), ("Button", "function.call"), ("+=", "operator"),
      (".tint", "function.call"), (".blue", "property"),
    ]
    let source = sample as NSString
    var searchLocation = 0
    return tokens.compactMap { token, capture in
      let range = source.range(
        of: token, options: [],
        range: NSRange(location: searchLocation, length: source.length - searchLocation))
      guard range.location != NSNotFound else { return nil }
      searchLocation = NSMaxRange(range)
      let prefix = source.substring(to: range.location)
      let line = prefix.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
      let lineStart = source.lineRange(for: NSRange(location: range.location, length: 0)).location
      return Highlight(
        range: EditorTextRange(
          start: TextPosition(line: line, utf16Column: range.location - lineStart),
          end: TextPosition(line: line, utf16Column: range.location - lineStart + range.length)
        ),
        capture: capture
      )
    }
  }()
}

private struct ProfileColorRow: View {
  let title: String
  @Binding var value: EditorRGBAColor

  var body: some View {
    ColorPicker(title, selection: colorBinding, supportsOpacity: true)
  }

  private var colorBinding: Binding<Color> {
    Binding(
      get: { value.color },
      set: { color in
        // ColorPicker can return a dynamic AppKit color. It is not always
        // convertible through `usingColorSpace`, but its resolved components
        // remain usable and should still be written back to the profile.
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        value = EditorRGBAColor(
          Double(converted.redComponent),
          Double(converted.greenComponent),
          Double(converted.blueComponent),
          Double(converted.alphaComponent)
        )
      }
    )
  }
}

private struct EditorBuildSettingsView: View {
  @ObservedObject var controller: EditorWorkspaceController
  @ObservedObject var buildController: EditorBuildController
  let openFile: (URL) -> Void

  var body: some View {
    Form {
      Section("Detected Project") {
        LabeledContent("Build Folder") {
          Text(buildController.buildProjectURL.path)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
        }
        HStack {
          Button("Choose Build Folder…") { chooseBuildProjectFolder() }
            .disabled(buildController.phase.isRunning)
          Button("Use Workspace Folder") { controller.useWorkspaceAsBuildProject() }
            .disabled(
              buildController.phase.isRunning
                || buildController.buildProjectURL == controller.workspaceURL
            )
        }
        LabeledContent("Build System", value: buildController.plan.projectKind.rawValue)
        if buildController.plan.commands.isEmpty {
          Text("No supported build manifest was detected in the build folder.")
            .foregroundStyle(.secondary)
        } else {
          Picker("Default Task", selection: $buildController.selectedCommandID) {
            ForEach(buildController.plan.commands) { command in
              Text(command.title).tag(Optional(command.id))
            }
          }
          HStack {
            Button("Run Selected Task") { controller.runSelectedBuildTask() }
              .disabled(buildController.phase.isRunning)
            Button("Cancel") { controller.cancelBuildTask() }
              .disabled(!buildController.phase.isRunning)
            Button("Rediscover") { controller.refreshProjectContext() }
          }
        }
        if !buildController.discoveryWarnings.isEmpty {
          ForEach(buildController.discoveryWarnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
      }
      if !buildController.availableXcodeSchemes.isEmpty {
        Section("Xcode Scheme") {
          Picker(
            "Scheme",
            selection: Binding<String?>(
              get: { buildController.selectedXcodeScheme },
              set: { buildController.selectXcodeScheme($0) }
            )
          ) {
            Text("Automatic").tag(Optional<String>.none)
            ForEach(buildController.availableXcodeSchemes, id: \.self) { scheme in
              Text(scheme).tag(Optional(scheme))
            }
          }
          Text("The selected scheme is stored for this build folder.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("Python Environment") {
        if let environment = buildController.detectedPythonEnvironment {
          LabeledContent("Environment", value: environment.name)
          LabeledContent("Interpreter") {
            Text(environment.executableURL.path)
              .font(.caption.monospaced())
              .lineLimit(1)
              .truncationMode(.middle)
          }
          LabeledContent("Kind", value: environment.kind.rawValue.capitalized)
        } else {
          Text("No Python virtual environment was detected.")
            .foregroundStyle(.secondary)
        }
        HStack {
          Button("Choose Interpreter…") { choosePythonInterpreter() }
            .disabled(buildController.phase.isRunning)
          Button("Use Automatic Detection") { controller.selectPythonInterpreter(nil) }
            .disabled(
              buildController.phase.isRunning
                || buildController.selectedPythonInterpreterURL == nil
            )
        }
        Text(
          "Build, Run, Test, lint tools, language servers, and the integrated terminal share this interpreter and its PATH."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Custom Tasks") {
        Button("Create or Open .calcite/tasks.json", systemImage: "doc.badge.gearshape") {
          do {
            let url = try buildController.createCustomTaskFileIfNeeded()
            openFile(url)
          } catch {
            controller.fileOperationError = error.localizedDescription
          }
        }
        Text(
          "Custom tasks use an executable plus an argument array, avoiding shell-quoting ambiguity. Save the file, then choose Rediscover."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("Build Status") {
        Text(buildPhaseText)
        if !buildController.diagnostics.isEmpty {
          Text("\(buildController.diagnostics.count) build diagnostics")
            .foregroundStyle(.secondary)
        }
        Text(
          "Xcode, SwiftPM, Cargo, Go, Python, npm/pnpm/yarn/bun, Gradle, Maven, Zig, CMake, and Make projects are detected automatically."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func chooseBuildProjectFolder() {
    let panel = NSOpenPanel()
    panel.title = "Choose Build Project Folder"
    panel.message = "Calcite will detect and run build tasks from this folder."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = buildController.buildProjectURL
    guard panel.runModal() == .OK, let url = panel.url else { return }
    controller.selectBuildProjectFolder(url)
  }

  private func choosePythonInterpreter() {
    let panel = NSOpenPanel()
    panel.title = "Choose Python Interpreter"
    panel.message = "Choose the python executable inside the environment to use for this project."
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL =
      buildController.detectedPythonEnvironment?.binURL
      ?? buildController.buildProjectURL
    guard panel.runModal() == .OK, let url = panel.url else { return }
    controller.selectPythonInterpreter(url)
  }

  private var buildPhaseText: String {
    switch buildController.phase {
    case .idle: return "Idle"
    case .running(let task): return "Running \(task)…"
    case .cancelling(let task): return "Cancelling \(task)…"
    case .cancelled(let message): return message
    case .succeeded(let message): return message
    case .failed(let message): return message
    }
  }
}

private struct EditorDebugSettingsView: View {
  @ObservedObject var controller: EditorWorkspaceController
  @State private var didCopyDebugLog = false

  var body: some View {
    Form {
      launchSection
      controlsSection
      consoleSection
    }
    .formStyle(.grouped)
  }

  private var launchSection: some View {
    Section("Launch Configuration") {
      TextField("Executable or Script", text: $controller.debugConfiguration.programPath)
      TextField("Arguments", text: $controller.debugConfiguration.arguments)
      TextField("Working Directory", text: $controller.debugConfiguration.workingDirectory)
      Toggle("Stop on Entry", isOn: $controller.debugConfiguration.stopOnEntry)
      Toggle("Build Before Launch", isOn: $controller.debugConfiguration.buildBeforeLaunch)
      Text(
        "The adapter is selected from the active tab's detected language. Manual adapter paths remain available under Services."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var controlsSection: some View {
    Section("Session") {
      HStack {
        DebugPhaseLabel(phase: controller.debugPhase)
        Spacer()
        Button("Start") { controller.startDebugging() }
          .disabled(controller.activeTab == nil || isActive)
        Button("Stop") { controller.stopDebugging() }
          .disabled(!isActive)
      }
      HStack {
        Button("Continue") { controller.continueDebugging() }
          .disabled(!isStopped)
        Button("Pause") { controller.pauseDebugging() }
          .disabled(!isRunning)
        Button("Step Over") { controller.stepOver() }
          .disabled(!isStopped)
        Button("Step Into") { controller.stepInto() }
          .disabled(!isStopped)
        Button("Step Out") { controller.stepOut() }
          .disabled(!isStopped)
      }
    }
  }

  private var consoleSection: some View {
    Section("Service and Debug Log") {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 3) {
          ForEach(Array(controller.debugConsole.enumerated()), id: \.offset) { _, line in
            Text(line)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .frame(minHeight: 180)
      HStack {
        Spacer()
        Button {
          let log = controller.debugConsole.joined(separator: "\n")
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(log, forType: .string)
          didCopyDebugLog = true
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopyDebugLog = false
          }
        } label: {
          Label(
            didCopyDebugLog ? "Copied" : "Copy Log",
            systemImage: didCopyDebugLog ? "checkmark" : "doc.on.doc")
        }
        .disabled(controller.debugConsole.isEmpty)
        Button("Clear Log") { controller.clearDebugConsole() }
      }
    }
  }

  private var isRunning: Bool {
    if case .running = controller.debugPhase { return true }
    return false
  }

  private var isStopped: Bool {
    if case .stopped = controller.debugPhase { return true }
    return false
  }

  private var isActive: Bool {
    switch controller.debugPhase {
    case .starting, .running, .stopped: return true
    case .idle, .failed: return false
    }
  }
}

private struct DebugPhaseLabel: View {
  let phase: EditorDebugPhase

  var body: some View {
    switch phase {
    case .idle:
      Label("Idle", systemImage: "circle")
    case .starting:
      HStack {
        ProgressView().controlSize(.small)
        Text("Starting")
      }
    case .running:
      Label("Running", systemImage: "play.circle.fill")
    case .stopped:
      Label("Paused", systemImage: "pause.circle.fill")
    case .failed(let message):
      Label("Failed", systemImage: "exclamationmark.triangle.fill")
        .help(message)
    }
  }
}
