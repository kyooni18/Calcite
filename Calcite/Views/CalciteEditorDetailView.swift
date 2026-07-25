import SwiftUI

/// Displays one backend-owned editor session inside a sectional editor tab.
///
/// Section splitting is handled exclusively by `MainSectionalView`; this view never creates an
/// additional internal editor split or a bottom panel.
@MainActor
struct CalciteEditorDetailView: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession
  var followsActiveEditorSession = true
  var preferredEditorSessionID: UUID?
  var editorSessionDidChange: ((UUID?) -> Void)?

  @State private var editorSessionID: UUID?

  init(
    backend: CalciteBackend,
    windowSession: CalciteBackendWindowSession,
    followsActiveEditorSession: Bool = true,
    preferredEditorSessionID: UUID? = nil,
    editorSessionDidChange: ((UUID?) -> Void)? = nil
  ) {
    self.backend = backend
    self.windowSession = windowSession
    self.followsActiveEditorSession = followsActiveEditorSession
    self.preferredEditorSessionID = preferredEditorSessionID
    self.editorSessionDidChange = editorSessionDidChange
    _editorSessionID = State(initialValue: preferredEditorSessionID)
  }

  var body: some View {
    Group {
      if let editor = resolvedEditorSession, let document = editor.document {
        CalciteEditorView(
          backend: backend,
          windowSession: windowSession,
          editorSession: editor,
          tab: document,
          activate: { windowSession.activateEditorSession(editor.id) }
        )
      } else {
        CalciteEditorEmptyState(backend: backend)
      }
    }
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    .background(backend.controller.profile.workbench.windowBackground.color)
    .clipShape(Rectangle())
    .onAppear(perform: reconcileEditorSession)
    .onChange(of: preferredEditorSessionID) { _, _ in reconcileEditorSession() }
    .onChange(of: editorSessionIDs) { _, _ in reconcileEditorSession() }
    .onChange(of: windowSession.activeEditorSessionID) { _, activeID in
      guard followsActiveEditorSession, let activeID else { return }
      updateEditorSession(activeID)
    }
  }

  private var editorSessionIDs: [UUID] {
    windowSession.editorSessions.map(\.id)
  }

  private var resolvedEditorSession: CalciteBackendWindowSession.EditorSession? {
    guard let editorSessionID else { return nil }
    return windowSession.editorSessions.first { $0.id == editorSessionID }
  }

  private func reconcileEditorSession() {
    windowSession.markActive()

    if let preferredEditorSessionID,
      windowSession.editorSessions.contains(where: { $0.id == preferredEditorSessionID })
    {
      updateEditorSession(preferredEditorSessionID)
      return
    }

    if let editorSessionID,
      windowSession.editorSessions.contains(where: { $0.id == editorSessionID })
    {
      editorSessionDidChange?(editorSessionID)
      return
    }

    updateEditorSession(
      windowSession.activeEditorSessionID
        ?? windowSession.editorSessions.first?.id
    )
  }

  private func updateEditorSession(_ id: UUID?) {
    guard editorSessionID != id else {
      editorSessionDidChange?(id)
      return
    }
    editorSessionID = id
    editorSessionDidChange?(id)
  }
}
