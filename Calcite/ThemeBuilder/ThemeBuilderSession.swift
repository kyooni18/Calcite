import Combine

@MainActor
final class ThemeBuilderSession: ObservableObject {
  @Published private(set) var isDirty = false
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published var selectedTokenID: String? = ThemeColorToken.all.first?.id

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
