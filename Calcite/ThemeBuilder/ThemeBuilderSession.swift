import Combine

@MainActor
final class ThemeBuilderSession: ObservableObject {
  @Published private(set) var isDirty = false

  private unowned let controller: EditorWorkspaceController
  private var baselineProfiles: [EditorThemeSlot: EditorCustomProfile]
  private var baselineSlot: EditorThemeSlot
  private var baselineUsesWorkspaceOverrides: Bool
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

  func beginEditing() {
    guard !isActive else { return }
    captureBaseline()
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

  func save() {
    captureBaseline()
    isDirty = false
  }

  func discard() {
    isApplyingSnapshot = true

    if controller.usesWorkspaceThemeOverrides != baselineUsesWorkspaceOverrides {
      controller.setUsesWorkspaceThemeOverrides(baselineUsesWorkspaceOverrides)
    }
    if let light = baselineProfiles[.light] {
      controller.setProfile(light, for: .light)
    }
    if let dark = baselineProfiles[.dark] {
      controller.setProfile(dark, for: .dark)
    }
    controller.activateThemeSlot(baselineSlot)

    isApplyingSnapshot = false
    isDirty = false
  }

  func endEditing() {
    isActive = false
    isDirty = false
  }

  private func captureBaseline() {
    baselineProfiles = [
      .light: controller.profile(for: .light),
      .dark: controller.profile(for: .dark),
    ]
    baselineSlot = controller.activeThemeSlot
    baselineUsesWorkspaceOverrides = controller.usesWorkspaceThemeOverrides
  }
}
