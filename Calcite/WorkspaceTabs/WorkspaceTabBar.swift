import AppKit
import SwiftUI

struct WorkspaceTabBar: View {
  @ObservedObject var controller: EditorWorkspaceController
  @ObservedObject var workspaceTabs: WorkspaceTabController
  let closeDocument: (EditorTab) -> Void
  let closeUtility: (WorkspaceTabID) -> Void
  let openDocumentToSide: (EditorTab) -> Void
  let splitRight: () -> Void
  let splitBelow: () -> Void
  let closeSplit: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal) {
        HStack(spacing: 0) {
          ForEach(controller.tabs) { tab in
            documentTab(tab)
            Divider()
          }
          ForEach(workspaceTabs.utilityTabs, id: \.id) { tab in
            utilityTab(tab)
            Divider()
          }
        }
      }
      .scrollIndicators(.hidden)
      .frame(maxWidth: .infinity)

      Menu {
        Button("Split Right", systemImage: "rectangle.split.2x1", action: splitRight)
          .disabled(!hasSelectedDocument)
        Button("Split Below", systemImage: "rectangle.split.1x2", action: splitBelow)
          .disabled(!hasSelectedDocument)
        Divider()
        Button("Close Split", systemImage: "rectangle", action: closeSplit)
          .disabled(!hasSelectedDocument)
      } label: {
        Image(systemName: "rectangle.split.2x1")
          .font(.system(size: 11, weight: .medium))
          .frame(width: 26, height: 26)
      }
      .menuStyle(.borderlessButton)
      .help("Editor layout")
      .padding(.trailing, 4)
    }
    .frame(height: 30)
    .background(controller.profile.workbench.toolbarBackground.color)
    .animation(.snappy(duration: 0.22, extraBounce: 0.08), value: controller.tabs.map(\.id))
    .animation(.easeInOut(duration: 0.16), value: workspaceTabs.selection)
  }

  private var hasSelectedDocument: Bool {
    guard case .document(let id) = workspaceTabs.selection else { return false }
    return controller.activeTab?.id == id
  }

  private func documentTab(_ tab: EditorTab) -> some View {
    let id = WorkspaceTabID.document(tab.id)
    return HStack(spacing: 0) {
      Button {
        controller.selectedTabID = tab.id
        workspaceTabs.selectDocument(tab.id)
      } label: {
        EditorTabLabel(tab: tab, isSelected: workspaceTabs.selection == id)
      }
      .buttonStyle(.plain)

      Button {
        closeDocument(tab)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
          .padding(6)
      }
      .buttonStyle(.plain)
      .help("Close \(tab.title)")
    }
    .background(tabBackground(isSelected: workspaceTabs.selection == id))
    .contentShape(Rectangle())
    .contextMenu {
      Button("Save", systemImage: "square.and.arrow.down") {
        controller.selectedTabID = tab.id
        workspaceTabs.selectDocument(tab.id)
        Task { await tab.save() }
      }
      .disabled(!tab.isDirty)

      Button("Open to Side", systemImage: "rectangle.split.2x1") {
        openDocumentToSide(tab)
      }

      Divider()

      Button("Reveal in Finder", systemImage: "folder") {
        NSWorkspace.shared.activateFileViewerSelecting([tab.url])
      }
      Button("Copy Path", systemImage: "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tab.url.path, forType: .string)
      }

      Divider()
      Button(role: .destructive) {
        closeDocument(tab)
      } label: {
        Label("Close Tab", systemImage: "xmark")
      }
    }
  }

  private func utilityTab(_ tab: WorkspaceTabID) -> some View {
    HStack(spacing: 0) {
      Button {
        workspaceTabs.selectUtility(tab)
      } label: {
        HStack(spacing: 5) {
          Image(systemName: utilitySymbol(tab))
          Text(utilityTitle(tab))
            .lineLimit(1)
        }
        .font(.system(size: 11))
        .padding(.leading, 9)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Button {
        closeUtility(tab)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
          .padding(6)
      }
      .buttonStyle(.plain)
      .help("Close \(utilityTitle(tab))")
    }
    .background(tabBackground(isSelected: workspaceTabs.selection == tab))
    .contentShape(Rectangle())
    .contextMenu {
      Button(role: .destructive) {
        closeUtility(tab)
      } label: {
        Label("Close Tab", systemImage: "xmark")
      }
    }
  }

  private func tabBackground(isSelected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
      .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
      .padding(.vertical, 2)
      .padding(.horizontal, 2)
  }

  private func utilityTitle(_ tab: WorkspaceTabID) -> String {
    switch tab {
    case .settings: "Settings"
    case .themeBuilder: "Theme Builder"
    case .document: "Editor"
    }
  }

  private func utilitySymbol(_ tab: WorkspaceTabID) -> String {
    switch tab {
    case .settings: "gearshape"
    case .themeBuilder: "paintpalette"
    case .document: "doc.text"
    }
  }
}
