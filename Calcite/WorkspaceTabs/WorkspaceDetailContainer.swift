import SwiftUI

struct WorkspaceDetailContainer: View {
  @ObservedObject var controller: EditorWorkspaceController
  @ObservedObject var terminal: EditorTerminalSession
  @ObservedObject var executor: EditorCommandExecutor
  @ObservedObject var workspaceTabs: WorkspaceTabController
  @ObservedObject var themeBuilderSession: ThemeBuilderSession

  @Binding var sideOpenRequest: EditorSideOpenRequest?
  @Binding var bottomPanelHeight: Double
  let usesLiveMarkdownEditor: Bool
  let showsMarkdownSyntax: Bool
  let wrapsMarkdownLines: Bool
  let requestCloseDocument: (EditorTab) -> Void
  let requestCloseUtility: (WorkspaceTabID) -> Void

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceTabBar(
        controller: controller,
        workspaceTabs: workspaceTabs,
        closeDocument: requestCloseDocument,
        closeUtility: requestCloseUtility,
        openDocumentToSide: { tab in
          workspaceTabs.selectDocument(tab.id)
          sideOpenRequest = .init(url: tab.url)
        },
        splitRight: { executor.sendLayoutCommand(.splitRight) },
        splitBelow: { executor.sendLayoutCommand(.splitBelow) },
        closeSplit: { executor.sendLayoutCommand(.closeSplit) }
      )
      Divider()
      selectedContent
    }
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    .onChange(of: workspaceTabs.selection) { _, selection in
      guard case .document(let id) = selection else { return }
      if controller.selectedTabID != id {
        controller.selectedTabID = id
      }
    }
  }

  @ViewBuilder
  private var selectedContent: some View {
    switch workspaceTabs.selection {
    case .document:
      EditorWorkspaceDetail(
        controller: controller,
        terminal: terminal,
        bottomPanel: $executor.bottomPanel,
        bottomPanelHeight: $bottomPanelHeight,
        sideOpenRequest: $sideOpenRequest,
        usesLiveMarkdownEditor: usesLiveMarkdownEditor,
        showsMarkdownSyntax: showsMarkdownSyntax,
        wrapsMarkdownLines: wrapsMarkdownLines,
        requestClose: requestCloseDocument,
        showsTabsBar: false,
        tabCommandEvent: executor.tabCommandEvent,
        layoutCommandEvent: executor.layoutCommandEvent
      )
    case .settings:
      ServiceSettingsView(
        controller: controller,
        openFile: executor.openDocument
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .themeBuilder:
      ThemeBuilderView(
        controller: controller,
        session: themeBuilderSession
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case nil:
      EditorEmptyState(phase: controller.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
