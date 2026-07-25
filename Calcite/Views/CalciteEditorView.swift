import SwiftUI

/// Backend-driven editor entry point for one concrete window editor session.
/// Commands and selection remain targeted when a document is displayed in multiple sections.
@MainActor
struct CalciteEditorView: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession
  @ObservedObject var editorSession: CalciteBackendWindowSession.EditorSession
  @ObservedObject var tab: EditorTab
  let activate: () -> Void

  var body: some View {
    CalciteEditorSurface(
      tab: tab,
      liveMarkdownStyling: windowSession.usesLiveMarkdownEditor,
      showsMarkdownSyntax: windowSession.showsMarkdownSyntax,
      wrapsMarkdownLines: windowSession.markdownWrapsLines,
      profile: backend.controller.profile,
      onVimHostRequest: { request in
        activate()
        backend.handleVimHostRequest(request)
      },
      onGoToDefinition: {
        activate()
        backend.goToDefinition()
      },
      onFindReferences: {
        activate()
        backend.findReferences()
      },
      onShowQuickHelp: {
        activate()
        backend.showQuickHelp()
      },
      onShowQuickFixes: { diagnostic in
        activate()
        backend.controller.showQuickFixes(for: diagnostic, in: tab)
      },
      onToggleInputMode: {
        activate()
        backend.toggleEditorInputMode()
      },
      commandEvent: previousCommandEvent
    )
    .id(editorSession.id)
    .onChange(of: tab.selectedRange) { _, range in
      guard windowSession.activeEditorSessionID == editorSession.id else { return }
      editorSession.updateSelection(range)
    }
  }

  private var previousCommandEvent: EditorTabCommandEvent? {
    guard let event = windowSession.editorCommandEvent,
      event.editorSessionID == editorSession.id
    else {
      return nil
    }

    return EditorTabCommandEvent(
      targetTabID: event.documentID,
      command: event.command
    )
  }
}
