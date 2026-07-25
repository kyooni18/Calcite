import XCTest

@testable import Calcite

@MainActor
final class CalciteCoreBehaviorTests: XCTestCase {
  func testLightAndDarkProfilesPersistIndependently() throws {
    let suiteName = "CalciteCoreBehaviorTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("Could not create isolated UserDefaults suite")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var light = EditorCustomProfile.light
    light.font.size = 17
    var dark = EditorCustomProfile.standard
    dark.font.size = 13

    EditorProfileStore.save(light, slot: .light, defaults: defaults)
    EditorProfileStore.save(dark, slot: .dark, defaults: defaults)

    XCTAssertEqual(EditorProfileStore.load(slot: .light, defaults: defaults).font.size, 17)
    XCTAssertEqual(EditorProfileStore.load(slot: .dark, defaults: defaults).font.size, 13)
  }

  func testWorkspaceThemeOverrideHasExplicitPrecedence() {
    let suiteName = "CalciteWorkspaceThemeTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("Could not create isolated UserDefaults suite")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let workspace = URL(fileURLWithPath: "/tmp/workspace-\(UUID().uuidString)")

    var global = EditorCustomProfile.standard
    global.font.size = 12
    EditorProfileStore.save(global, slot: .dark, defaults: defaults)

    var local = global
    local.font.size = 18
    EditorWorkspaceThemeProfileStore.setEnabled(
      true,
      workspaceURL: workspace,
      dark: local,
      defaults: defaults
    )

    let override = EditorWorkspaceThemeProfileStore.load(
      workspaceURL: workspace,
      defaults: defaults
    )
    XCTAssertTrue(override.isEnabled)
    XCTAssertEqual(override.profile(for: .dark)?.font.size, 18)
    XCTAssertEqual(EditorProfileStore.load(slot: .dark, defaults: defaults).font.size, 12)
  }

  func testThemeContrastCalculationMatchesBlackAndWhite() {
    let black = EditorRGBAColor(0, 0, 0)
    let white = EditorRGBAColor(1, 1, 1)
    XCTAssertEqual(black.contrastRatio(against: white), 21, accuracy: 0.001)
  }

  func testFileVisibilityPoliciesAreIndependent() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteVisibility-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    try "print(1)".write(
      to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    try "metadata".write(
      to: root.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
    try "secret".write(
      to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

    let ignored = root.appendingPathComponent("node_modules", isDirectory: true)
    try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
    try "module".write(
      to: ignored.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

    let build = root.appendingPathComponent(".build", isDirectory: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try "object".write(
      to: build.appendingPathComponent("output.o"), atomically: true, encoding: .utf8)

    let defaultPaths = Set(
      try ProjectFileScanner.scan(rootURL: root).files.map(\.lastPathComponent))
    XCTAssertTrue(defaultPaths.contains("main.swift"))
    XCTAssertFalse(defaultPaths.contains(".DS_Store"))
    XCTAssertFalse(defaultPaths.contains(".hidden"))
    XCTAssertFalse(defaultPaths.contains("index.js"))
    XCTAssertFalse(defaultPaths.contains("output.o"))

    let buildPaths = Set(
      try ProjectFileScanner.scan(rootURL: root, includeBuildArtifacts: true)
        .files.map(\.lastPathComponent)
    )
    XCTAssertTrue(buildPaths.contains("output.o"))
    XCTAssertFalse(buildPaths.contains("index.js"))

    let ignoredPaths = Set(
      try ProjectFileScanner.scan(rootURL: root, includeIgnoredFiles: true)
        .files.map(\.lastPathComponent)
    )
    XCTAssertTrue(ignoredPaths.contains("index.js"))
    XCTAssertFalse(ignoredPaths.contains("output.o"))

    let hiddenPaths = Set(
      try ProjectFileScanner.scan(
        rootURL: root,
        includeHiddenFiles: true,
        includeDSStore: true
      ).files.map(\.lastPathComponent)
    )
    XCTAssertTrue(hiddenPaths.contains(".hidden"))
    XCTAssertTrue(hiddenPaths.contains(".DS_Store"))
    XCTAssertFalse(hiddenPaths.contains("output.o"))
  }

  func testSourceContentChangesDoNotInvalidateProjectConfiguration() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteFingerprint-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("main.swift")
    try "print(1)".write(to: source, atomically: true, encoding: .utf8)

    let before = try ProjectFileScanner.scan(rootURL: root)
    try "print(123456789)".write(to: source, atomically: true, encoding: .utf8)
    let after = try ProjectFileScanner.scan(rootURL: root)

    XCTAssertEqual(before.structureFingerprint, after.structureFingerprint)
    XCTAssertEqual(before.projectContextFingerprint, after.projectContextFingerprint)
  }

  func testBuildManifestChangesInvalidateProjectConfiguration() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteManifest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manifest = root.appendingPathComponent("Package.swift")
    try "// one".write(to: manifest, atomically: true, encoding: .utf8)
    let before = try ProjectFileScanner.scan(rootURL: root)

    try "// manifest changed substantially".write(
      to: manifest, atomically: true, encoding: .utf8)
    let after = try ProjectFileScanner.scan(rootURL: root)
    XCTAssertNotEqual(before.projectContextFingerprint, after.projectContextFingerprint)
  }

  func testHiddenVirtualEnvironmentChangesProjectConfigurationWithoutBecomingVisible() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteVenvFingerprint-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let before = try ProjectFileScanner.scan(rootURL: root)

    let environment = root.appendingPathComponent(".venv", isDirectory: true)
    try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)
    try "home = /usr/bin".write(
      to: environment.appendingPathComponent("pyvenv.cfg"),
      atomically: true,
      encoding: .utf8
    )
    let after = try ProjectFileScanner.scan(rootURL: root)

    XCTAssertNotEqual(before.projectContextFingerprint, after.projectContextFingerprint)
    XCTAssertFalse(after.nodes.contains { $0.url.lastPathComponent == ".venv" })
  }

  func testBreakpointStoreMovesAndRemovesDirectoryEntries() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteBreakpoints-\(UUID().uuidString)", isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("Old", isDirectory: true)
    let destinationDirectory = root.appendingPathComponent("New", isDirectory: true)
    let source = sourceDirectory.appendingPathComponent("main.swift")
    let destination = destinationDirectory.appendingPathComponent("main.swift")
    defer {
      EditorBreakpointStore.remove(under: root)
    }

    EditorBreakpointStore.save([2, 7], for: source)
    EditorBreakpointStore.move(from: sourceDirectory, to: destinationDirectory)
    XCTAssertTrue(EditorBreakpointStore.load(for: source).isEmpty)
    XCTAssertEqual(EditorBreakpointStore.load(for: destination), Set([2, 7]))

    EditorBreakpointStore.remove(under: destinationDirectory)
    XCTAssertTrue(EditorBreakpointStore.load(for: destination).isEmpty)
  }

  func testWorkspaceUtilityTabsAreSingletonsAndPersist() {
    let suiteName = "CalciteWorkspaceTabs.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("Could not create isolated UserDefaults suite")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let workspace = URL(fileURLWithPath: "/tmp/workspace-tabs-\(UUID().uuidString)")

    let tabs = WorkspaceTabController(workspaceURL: workspace, defaults: defaults)
    tabs.openSettings()
    tabs.openSettings()
    tabs.openThemeBuilder()
    tabs.openThemeBuilder()

    XCTAssertEqual(tabs.utilityTabs, [.settings, .themeBuilder])
    XCTAssertEqual(tabs.selection, .themeBuilder)

    let restored = WorkspaceTabController(workspaceURL: workspace, defaults: defaults)
    XCTAssertEqual(restored.utilityTabs, [.settings, .themeBuilder])
    XCTAssertEqual(restored.selection, .themeBuilder)
  }

  func testWorkspaceTabReconciliationPreservesUtilitySelection() {
    let suiteName = "CalciteWorkspaceTabs.Reconcile.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("Could not create isolated UserDefaults suite")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let workspace = URL(fileURLWithPath: "/tmp/workspace-tabs-\(UUID().uuidString)")
    let tabs = WorkspaceTabController(workspaceURL: workspace, defaults: defaults)
    let documentID = UUID()

    tabs.openSettings()
    tabs.reconcile(documentIDs: [documentID], selectedDocumentID: documentID)
    tabs.synchronizeSelectedDocument(documentID)

    XCTAssertEqual(tabs.selection, .settings)

    tabs.closeUtility(.settings, fallbackDocumentID: documentID)
    XCTAssertEqual(tabs.selection, .document(documentID))
  }

  func testWorkspaceTabPersistenceDoesNotRestoreStaleDocumentIdentity() {
    let suiteName = "CalciteWorkspaceTabs.DocumentIdentity.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("Could not create isolated UserDefaults suite")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let workspace = URL(fileURLWithPath: "/tmp/workspace-tabs-\(UUID().uuidString)")
    let documentID = UUID()

    let tabs = WorkspaceTabController(workspaceURL: workspace, defaults: defaults)
    tabs.openSettings()
    tabs.selectDocument(documentID)

    let restored = WorkspaceTabController(workspaceURL: workspace, defaults: defaults)
    XCTAssertEqual(restored.utilityTabs, [.settings])
    XCTAssertNil(restored.selection)
  }

  func testFileVisibilitySettingsPersistIndependently() {
    let suiteName = "CalciteFileVisibility.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("Could not create isolated UserDefaults suite")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = FileVisibilitySettings(defaults: defaults)
    settings.showsHiddenFiles = true
    settings.showsBuildArtifacts = true

    let restored = FileVisibilitySettings(defaults: defaults)
    XCTAssertTrue(restored.showsHiddenFiles)
    XCTAssertTrue(restored.showsBuildArtifacts)
    XCTAssertFalse(restored.showsIgnoredFiles)
    XCTAssertFalse(restored.showsDSStore)
  }

  func testFocusedCommandHandlersDispatchTypedCommands() {
    var editorCommands: [EditorCommand] = []
    var appCommands: [AppCommand] = []
    let recent = URL(fileURLWithPath: "/tmp/recent")

    let editorHandler = EditorCommandHandler { editorCommands.append($0) }
    let appHandler = AppCommandHandler { appCommands.append($0) }

    editorHandler.perform(.build)
    editorHandler.perform(.runTerminalCommand("pwd"))
    appHandler.perform(.openRecent(recent))

    XCTAssertEqual(editorCommands, [.build, .runTerminalCommand("pwd")])
    XCTAssertEqual(appCommands, [.openRecent(recent)])
  }

  func testWorkspaceLayoutPersistsVisibilityPanelAndExactDimensions() {
    let suiteName = "CalciteWorkspaceLayoutTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("Could not create isolated UserDefaults suite")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let workspace = URL(fileURLWithPath: "/tmp/layout-\(UUID().uuidString)")

    EditorWorkspaceLayoutStore.saveSidebarVisibility(false, for: workspace, defaults: defaults)
    EditorWorkspaceLayoutStore.saveSidebarWidth(317, for: workspace, defaults: defaults)
    EditorWorkspaceLayoutStore.saveBottomPanel(.problems, for: workspace, defaults: defaults)
    EditorWorkspaceLayoutStore.saveBottomPanelHeight(349, for: workspace, defaults: defaults)

    XCTAssertFalse(
      EditorWorkspaceLayoutStore.loadSidebarVisibility(for: workspace, defaults: defaults))
    XCTAssertEqual(
      EditorWorkspaceLayoutStore.loadSidebarWidth(for: workspace, defaults: defaults), 317)
    XCTAssertEqual(
      EditorWorkspaceLayoutStore.loadBottomPanel(for: workspace, defaults: defaults), .problems)
    XCTAssertEqual(
      EditorWorkspaceLayoutStore.loadBottomPanelHeight(for: workspace, defaults: defaults), 349)
  }

  func testLineIndexTracksIncrementalMultilineEdits() {
    var text = "alpha\nbeta\ngamma\n"
    var index = EditorLineIndex(text: text)
    let source = text as NSString
    let range = source.range(of: "beta\n")
    let replacement = "one\ntwo\n"
    text = source.replacingCharacters(in: range, with: replacement)

    index.replace(range: range, replacement: replacement, resultingText: text)
    let rebuilt = EditorLineIndex(text: text)

    XCTAssertEqual(index.lineCount, rebuilt.lineCount)
    for offset in 0...(text as NSString).length {
      XCTAssertEqual(
        index.lineNumber(atUTF16Offset: offset),
        rebuilt.lineNumber(atUTF16Offset: offset)
      )
    }
  }

  func testLineIndexPreservesTerminalCRLFBoundaryAfterUnicodeDeletion() {
    var text = "🙂\r\n🙂"
    var index = EditorLineIndex(text: text)
    let range = NSRange(location: 4, length: 2)
    text = (text as NSString).replacingCharacters(in: range, with: "")

    index.replace(range: range, replacement: "", resultingText: text)

    XCTAssertEqual(index.lineCount, 2)
    XCTAssertEqual(index.lineNumber(atUTF16Offset: (text as NSString).length), 2)
  }

  func testLineIndexRebuildsWhenFoundationNormalizesAnInvalidUTF16Insertion() {
    var text = "\r🙂🙂"
    var index = EditorLineIndex(text: text)
    let range = NSRange(location: 2, length: 0)
    text = (text as NSString).replacingCharacters(in: range, with: "\n")

    index.replace(range: range, replacement: "\n", resultingText: text)

    XCTAssertEqual(index.lineStarts, EditorLineIndex(text: text).lineStarts)
  }

  func testProjectTemplatesRejectUnsafeNames() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteTemplateSafety-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    for name in ["../escape", "nested/path", "nested\\path", ".hidden", "bad\nname", "bad:name"] {
      XCTAssertThrowsError(try ProjectTemplate.create(named: name, language: .swift, in: parent))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: parent.deletingLastPathComponent().appendingPathComponent("escape").path))
  }

  func testProjectTemplatesUsePortableManifestIdentifiers() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteTemplateIdentity-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    let root = try ProjectTemplate.create(named: "My Test Project", language: .swift, in: parent)
    let manifest = try String(
      contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
    XCTAssertTrue(manifest.contains("name: \"my-test-project\""))
    XCTAssertTrue(manifest.contains("name: \"MyTestProject\""))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Sources/MyTestProject/main.swift").path
      )
    )
  }

  func testLogRedactorRemovesSecretsAndShortensHomePath() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let message = "Authorization: Bearer abcdefghijklmnop token=top-secret path=\(home)/Code"
    let safe = CalciteLogRedactor.sanitize(message: message)
    let metadata = CalciteLogRedactor.sanitize(metadata: [
      "api_key": "sk-abcdefghijklmnop",
      "workspace": "\(home)/Project",
    ])

    XCTAssertFalse(safe.contains("abcdefghijklmnop"))
    XCTAssertFalse(safe.contains("top-secret"))
    XCTAssertFalse(safe.contains(home))
    XCTAssertEqual(metadata["api_key"], "<redacted>")
    XCTAssertEqual(metadata["workspace"], "~/Project")
  }

}
