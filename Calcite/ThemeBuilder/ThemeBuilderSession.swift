import Combine
import EditorServices
import Foundation

@MainActor
final class ThemeBuilderSession: ObservableObject {
  @Published private(set) var isDirty = false
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published var selectedTokenID: String? = ThemeColorToken.all.first?.id
  @Published private(set) var importMessage: String?
  @Published private(set) var pendingThemeCandidates: [EditorThemeImportCandidate] = []

  private struct Snapshot {
    var profiles: [EditorThemeSlot: EditorCustomProfile]
    var selectedSlot: EditorThemeSlot
    var usesWorkspaceOverrides: Bool
  }

  private unowned let controller: EditorWorkspaceController
  private var baselineProfiles: [EditorThemeSlot: EditorCustomProfile]
  private var baselineSlot: EditorThemeSlot
  private var baselineUsesWorkspaceOverrides: Bool
  private var undoStack: [Snapshot] = []
  private var redoStack: [Snapshot] = []
  private var isActive = false
  private var isApplyingSnapshot = false
  private var pendingThemeSourceURL: URL?
  private var pendingThemeTemporaryURL: URL?

  init(controller: EditorWorkspaceController) {
    self.controller = controller
    baselineProfiles = [
      .light: controller.profile(for: .light),
      .dark: controller.profile(for: .dark),
    ]
    baselineSlot = controller.activeThemeSlot
    baselineUsesWorkspaceOverrides = controller.usesWorkspaceThemeOverrides
  }

  var selectedToken: ThemeColorToken? {
    selectedTokenID.flatMap(ThemeColorToken.token(id:))
  }

  func beginEditing() {
    guard !isActive else { return }
    captureBaseline()
    undoStack.removeAll(keepingCapacity: true)
    redoStack.removeAll(keepingCapacity: true)
    refreshHistoryAvailability()
    isDirty = false
    isActive = true
  }

  func noteProfileChanged() {
    guard isActive, !isApplyingSnapshot else { return }
    isDirty =
      controller.profile(for: .light) != baselineProfiles[.light]
      || controller.profile(for: .dark) != baselineProfiles[.dark]
      || controller.activeThemeSlot != baselineSlot
      || controller.usesWorkspaceThemeOverrides != baselineUsesWorkspaceOverrides
  }

  func color(for token: ThemeColorToken, slot: EditorThemeSlot? = nil) -> EditorRGBAColor {
    token.color(in: controller.profile(for: slot ?? controller.activeThemeSlot))
  }

  func baselineColor(for token: ThemeColorToken, slot: EditorThemeSlot? = nil)
    -> EditorRGBAColor?
  {
    baselineProfiles[slot ?? controller.activeThemeSlot].map { token.color(in: $0) }
  }

  func activateThemeSlot(_ slot: EditorThemeSlot) {
    guard controller.activeThemeSlot != slot else { return }
    pushUndoSnapshot()
    redoStack.removeAll(keepingCapacity: true)
    controller.activateThemeSlot(slot)
    noteProfileChanged()
    refreshHistoryAvailability()
  }

  func setUsesWorkspaceOverrides(_ enabled: Bool) {
    guard controller.usesWorkspaceThemeOverrides != enabled else { return }
    pushUndoSnapshot()
    redoStack.removeAll(keepingCapacity: true)
    controller.setUsesWorkspaceThemeOverrides(enabled)
    noteProfileChanged()
    refreshHistoryAvailability()
  }

  func setColor(_ color: EditorRGBAColor, for token: ThemeColorToken) {
    let slot = controller.activeThemeSlot
    var profile = controller.profile(for: slot)
    guard token.color(in: profile) != color else { return }
    pushUndoSnapshot()
    redoStack.removeAll(keepingCapacity: true)
    token.setColor(color, in: &profile)
    controller.setProfile(profile, for: slot)
    noteProfileChanged()
    refreshHistoryAvailability()
  }

  func resetSelectedToken() {
    guard let token = selectedToken,
      let baseline = baselineColor(for: token)
    else { return }
    setColor(baseline, for: token)
  }

  func copyToken(
    _ token: ThemeColorToken,
    from source: EditorThemeSlot,
    to destination: EditorThemeSlot
  ) {
    guard source != destination else { return }
    let sourceColor = token.color(in: controller.profile(for: source))
    var destinationProfile = controller.profile(for: destination)
    guard token.color(in: destinationProfile) != sourceColor else { return }
    pushUndoSnapshot()
    redoStack.removeAll(keepingCapacity: true)
    token.setColor(sourceColor, in: &destinationProfile)
    controller.setProfile(destinationProfile, for: destination)
    noteProfileChanged()
    refreshHistoryAvailability()
  }

  func copyTheme(from source: EditorThemeSlot, to destination: EditorThemeSlot) {
    guard source != destination else { return }
    pushUndoSnapshot()
    redoStack.removeAll(keepingCapacity: true)
    var destinationProfile = controller.profile(for: destination)
    let sourceProfile = controller.profile(for: source)
    destinationProfile.surface = sourceProfile.surface
    destinationProfile.highlights = sourceProfile.highlights
    destinationProfile.syntax = sourceProfile.syntax
    destinationProfile.workbench = sourceProfile.workbench
    destinationProfile.terminal = sourceProfile.terminal
    controller.setProfile(destinationProfile, for: destination)
    noteProfileChanged()
    refreshHistoryAvailability()
  }


  var canReimportTheme: Bool {
    controller.profile(for: controller.activeThemeSlot).themeMetadata.sourcePath != nil
  }

  func updateActiveProfile(_ mutation: (inout EditorCustomProfile) -> Void) {
    let slot = controller.activeThemeSlot
    var profile = controller.profile(for: slot)
    let original = profile
    mutation(&profile)
    guard profile != original else { return }
    pushUndoSnapshot()
    redoStack.removeAll(keepingCapacity: true)
    controller.setProfile(profile, for: slot)
    noteProfileChanged()
    refreshHistoryAvailability()
  }

  func deriveWorkbenchPalette() {
    updateActiveProfile { profile in
      let background = profile.surface.background
      let foreground = profile.surface.foreground
      let accent = profile.surface.cursor
      let isLight = background.relativeLuminance >= 0.45
      let shade = EditorRGBAColor(isLight ? 0 : 1, isLight ? 0 : 1, isLight ? 0 : 1)

      profile.workbench.foreground = foreground
      profile.workbench.mutedForeground = foreground.blended(with: background, amount: 0.38)
      profile.workbench.windowBackground = background
      profile.workbench.sidebarBackground = background.blended(with: shade, amount: isLight ? 0.035 : 0.045)
      profile.workbench.panelBackground = background.blended(with: shade, amount: isLight ? 0.025 : 0.035)
      profile.workbench.toolbarBackground = background.blended(with: shade, amount: isLight ? 0.055 : 0.065)
      profile.workbench.activeTabBackground = background
      profile.workbench.inactiveTabBackground = background.blended(with: shade, amount: isLight ? 0.05 : 0.07)
      profile.workbench.inputBackground = background.blended(with: foreground, amount: isLight ? 0.035 : 0.07)
      profile.workbench.border = background.blended(with: foreground, amount: isLight ? 0.22 : 0.20)
      profile.workbench.accent = accent
      profile.highlights.currentLine = background.blended(with: foreground, amount: isLight ? 0.055 : 0.075)
      profile.surface.selection = EditorRGBAColor(accent.red, accent.green, accent.blue, isLight ? 0.28 : 0.42)
      profile.terminal.foreground = foreground
      profile.terminal.background = background
    }
  }

  func repairReadableContrast() {
    updateActiveProfile { profile in
      profile.surface.foreground = profile.surface.foreground.repairedTextColor(
        against: profile.surface.background,
        minimumRatio: 4.5
      )
      profile.workbench.foreground = profile.workbench.foreground.repairedTextColor(
        against: profile.workbench.windowBackground,
        minimumRatio: 4.5
      )
      profile.workbench.mutedForeground = profile.workbench.mutedForeground.repairedTextColor(
        against: profile.workbench.windowBackground,
        minimumRatio: 3.0
      )
      profile.terminal.foreground = profile.terminal.foreground.repairedTextColor(
        against: profile.terminal.background,
        minimumRatio: 4.5
      )

      let background = profile.surface.background
      let syntaxKeyPaths: [WritableKeyPath<EditorCustomProfile, EditorRGBAColor>] = [
        \.syntax.literals.keyword, \.syntax.literals.string, \.syntax.literals.number,
        \.syntax.literals.comment, \.syntax.literals.directive, \.syntax.symbols.type,
        \.syntax.symbols.function, \.syntax.symbols.variable, \.syntax.symbols.property,
        \.syntax.symbols.operator, \.syntax.symbols.punctuation,
      ]
      for keyPath in syntaxKeyPaths {
        profile[keyPath: keyPath] = profile[keyPath: keyPath].repairedTextColor(
          against: background,
          minimumRatio: 3.0
        )
      }
    }
  }

  func importTheme(from sourceURL: URL, preferredVariantPath: String? = nil) {
    var temporaryURL: URL?
    do {
      let importURL: URL
      if Self.isThemeArchive(sourceURL) {
        let extracted = try Self.extractThemeArchive(sourceURL)
        temporaryURL = extracted
        let extensionRoot = extracted.appendingPathComponent("extension", isDirectory: true)
        var isDirectory: ObjCBool = false
        importURL = FileManager.default.fileExists(
          atPath: extensionRoot.path,
          isDirectory: &isDirectory
        ) && isDirectory.boolValue ? extensionRoot : extracted
      } else {
        importURL = sourceURL
      }

      let candidates = try EditorThemeImporter.discoverThemes(in: importURL)
      if let preferredVariantPath {
        guard let candidate = candidates.first(where: { $0.relativePath == preferredVariantPath }) else {
          throw EditorThemeImportError.invalidRoot(
            "The previously selected theme variant no longer exists: \(preferredVariantPath)"
          )
        }
        applyImportedThemeResult(
          try EditorThemeImporter.load(candidate),
          sourceURL: sourceURL,
          sourceVariantPath: preferredVariantPath
        )
      } else if candidates.count > 1 {
        cancelPendingThemeImport()
        pendingThemeCandidates = candidates
        pendingThemeSourceURL = sourceURL
        pendingThemeTemporaryURL = temporaryURL
        temporaryURL = nil
        return
      } else if let candidate = candidates.first {
        applyImportedThemeResult(
          try EditorThemeImporter.load(candidate),
          sourceURL: sourceURL,
          sourceVariantPath: candidate.relativePath
        )
      } else {
        applyImportedThemeResult(
          try EditorThemeImporter.load(from: importURL),
          sourceURL: sourceURL,
          sourceVariantPath: nil
        )
      }
      if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    } catch {
      if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
      importMessage = "Could not import \(sourceURL.lastPathComponent): \(error.localizedDescription)"
    }
  }

  func reimportTheme() {
    let profile = controller.profile(for: controller.activeThemeSlot)
    guard let path = profile.themeMetadata.sourcePath else { return }
    importTheme(
      from: URL(fileURLWithPath: path),
      preferredVariantPath: profile.themeMetadata.sourceVariantPath
    )
  }

  func importPendingThemeCandidate(_ candidate: EditorThemeImportCandidate) {
    guard let sourceURL = pendingThemeSourceURL else {
      cancelPendingThemeImport()
      return
    }
    do {
      applyImportedThemeResult(
        try EditorThemeImporter.load(candidate),
        sourceURL: sourceURL,
        sourceVariantPath: candidate.relativePath
      )
    } catch {
      importMessage = "Could not import \(candidate.name): \(error.localizedDescription)"
    }
    cancelPendingThemeImport()
  }

  func cancelPendingThemeImport() {
    if let pendingThemeTemporaryURL {
      try? FileManager.default.removeItem(at: pendingThemeTemporaryURL)
    }
    pendingThemeCandidates = []
    pendingThemeSourceURL = nil
    pendingThemeTemporaryURL = nil
  }

  private func applyImportedThemeResult(
    _ result: EditorThemeImportResult,
    sourceURL: URL,
    sourceVariantPath: String?
  ) {
    let slot = controller.activeThemeSlot
    var updated = controller.profile(for: slot)
    pushUndoSnapshot()
    redoStack.removeAll(keepingCapacity: true)
    updated.applyImportedTheme(
      result.theme,
      sourceURL: sourceURL,
      sourceVariantPath: sourceVariantPath,
      diagnostics: result.diagnostics
    )
    controller.setProfile(updated, for: slot)
    importMessage = result.diagnostics.isEmpty
      ? "Imported \(result.theme.name) from \(sourceURL.lastPathComponent)."
      : result.diagnostics.map(\.message).joined(separator: "\n")
    noteProfileChanged()
    refreshHistoryAvailability()
  }

  private static func isThemeArchive(_ url: URL) -> Bool {
    ["vsix", "zip"].contains(url.pathExtension.lowercased())
  }

  private static func extractThemeArchive(_ url: URL) throws -> URL {
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteTheme-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    let tools: [(String, [String])] = [
      ("/usr/bin/ditto", ["-x", "-k", url.path, destination.path]),
      ("/usr/bin/unzip", ["-q", url.path, "-d", destination.path]),
    ]
    for (tool, arguments) in tools where FileManager.default.isExecutableFile(atPath: tool) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: tool)
      process.arguments = arguments
      do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return destination }
      } catch {
        continue
      }
    }
    try? FileManager.default.removeItem(at: destination)
    throw CocoaError(.fileReadCorruptFile)
  }

  func undo() {
    guard let snapshot = undoStack.popLast() else { return }
    redoStack.append(currentSnapshot())
    apply(snapshot)
    refreshHistoryAvailability()
  }

  func redo() {
    guard let snapshot = redoStack.popLast() else { return }
    undoStack.append(currentSnapshot())
    apply(snapshot)
    refreshHistoryAvailability()
  }

  func save() {
    captureBaseline()
    undoStack.removeAll(keepingCapacity: true)
    redoStack.removeAll(keepingCapacity: true)
    refreshHistoryAvailability()
    isDirty = false
  }

  func discard() {
    apply(
      Snapshot(
        profiles: baselineProfiles,
        selectedSlot: baselineSlot,
        usesWorkspaceOverrides: baselineUsesWorkspaceOverrides
      )
    )
    undoStack.removeAll(keepingCapacity: true)
    redoStack.removeAll(keepingCapacity: true)
    refreshHistoryAvailability()
    isDirty = false
  }

  func endEditing() {
    cancelPendingThemeImport()
    isActive = false
    isDirty = false
    undoStack.removeAll()
    redoStack.removeAll()
    refreshHistoryAvailability()
  }

  private func currentSnapshot() -> Snapshot {
    Snapshot(
      profiles: [
        .light: controller.profile(for: .light),
        .dark: controller.profile(for: .dark),
      ],
      selectedSlot: controller.activeThemeSlot,
      usesWorkspaceOverrides: controller.usesWorkspaceThemeOverrides
    )
  }

  private func pushUndoSnapshot() {
    undoStack.append(currentSnapshot())
    if undoStack.count > 100 { undoStack.removeFirst(undoStack.count - 100) }
  }

  private func apply(_ snapshot: Snapshot) {
    isApplyingSnapshot = true
    if controller.usesWorkspaceThemeOverrides != snapshot.usesWorkspaceOverrides {
      controller.setUsesWorkspaceThemeOverrides(snapshot.usesWorkspaceOverrides)
    }
    if let light = snapshot.profiles[.light] { controller.setProfile(light, for: .light) }
    if let dark = snapshot.profiles[.dark] { controller.setProfile(dark, for: .dark) }
    controller.activateThemeSlot(snapshot.selectedSlot)
    isApplyingSnapshot = false
    noteProfileChanged()
  }

  private func captureBaseline() {
    baselineProfiles = [
      .light: controller.profile(for: .light),
      .dark: controller.profile(for: .dark),
    ]
    baselineSlot = controller.activeThemeSlot
    baselineUsesWorkspaceOverrides = controller.usesWorkspaceThemeOverrides
  }

  private func refreshHistoryAvailability() {
    canUndo = !undoStack.isEmpty
    canRedo = !redoStack.isEmpty
  }
}


private extension EditorRGBAColor {
  func blended(with other: EditorRGBAColor, amount: Double) -> EditorRGBAColor {
    let amount = min(max(amount, 0), 1)
    return EditorRGBAColor(
      red + (other.red - red) * amount,
      green + (other.green - green) * amount,
      blue + (other.blue - blue) * amount,
      alpha + (other.alpha - alpha) * amount
    )
  }

  func repairedTextColor(
    against background: EditorRGBAColor,
    minimumRatio: Double
  ) -> EditorRGBAColor {
    guard contrastRatio(against: background) < minimumRatio else { return self }
    let black = EditorRGBAColor(0, 0, 0, alpha)
    let white = EditorRGBAColor(1, 1, 1, alpha)
    let target = black.contrastRatio(against: background) > white.contrastRatio(against: background)
      ? black : white
    var lower = 0.0
    var upper = 1.0
    var candidate = target
    for _ in 0..<18 {
      let amount = (lower + upper) / 2
      let mixed = blended(with: target, amount: amount)
      if mixed.contrastRatio(against: background) >= minimumRatio {
        candidate = mixed
        upper = amount
      } else {
        lower = amount
      }
    }
    return candidate
  }
}
