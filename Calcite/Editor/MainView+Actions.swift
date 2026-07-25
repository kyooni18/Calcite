import AppKit
import SwiftUI

extension MainView {
  func requestClose(_ tab: EditorTab) {
    if tab.isDirty {
      pendingClose = tab
    } else {
      controller.closeTab(tab)
    }
  }

  func requestCloseUtility(_ tab: WorkspaceTabID) {
    switch tab {
    case .themeBuilder where themeBuilderSession.isDirty:
      pendingUtilityClose = tab
    case .themeBuilder:
      themeBuilderSession.endEditing()
      workspaceTabs.closeUtility(tab, fallbackDocumentID: controller.selectedTabID)
    case .settings:
      workspaceTabs.closeUtility(tab, fallbackDocumentID: controller.selectedTabID)
    case .document:
      break
    }
  }

  func closePendingUtilityTab() {
    guard let tab = pendingUtilityClose else { return }
    if tab == .themeBuilder {
      themeBuilderSession.endEditing()
    }
    workspaceTabs.closeUtility(tab, fallbackDocumentID: controller.selectedTabID)
    pendingUtilityClose = nil
  }

  func configureControllerCallbacks() {
    controller.onVimSplit = { [weak commandExecutor = self.commandExecutor] horizontal in
      commandExecutor?.sendLayoutCommand(horizontal ? .splitBelow : .splitRight)
    }
    controller.onVimCloseWindow = {
      NSApp.keyWindow?.performClose(nil)
    }
    controller.onVimNewTab = onOpenItem
    controller.onVimCommand = { [weak commandExecutor = self.commandExecutor] command in
      commandExecutor?.perform(command)
    }
  }

  func clearControllerCallbacks() {
    controller.onVimSplit = nil
    controller.onVimCloseWindow = nil
    controller.onVimNewTab = nil
    controller.onVimCommand = nil
  }

  func showUnifiedPalette() {
    palette.present(mode: .all)
    Task { @MainActor in
      topSearchIsFocused = true
    }
  }

  func sendPaletteKeyboardCommand(_ command: EditorCommandPalette.KeyboardCommand) {
    palette.send(command)
    if command == .dismiss {
      topSearchIsFocused = false
    }
  }

  func closeCommandPalette() {
    withAnimation(.easeOut(duration: 0.12)) {
      palette.dismiss()
    }
    topSearchIsFocused = false
  }
}
