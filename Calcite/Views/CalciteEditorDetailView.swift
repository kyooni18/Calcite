import SwiftUI


nonisolated enum CalciteVimSurfaceResidencyPolicy {
  static func updatedDocumentIDs(
    current: [UUID],
    active: UUID,
    available: Set<UUID>,
    limit: Int
  ) -> [UUID] {
    guard limit > 0, available.contains(active) else { return [] }
    var updated = current.filter { available.contains($0) && $0 != active }
    updated.insert(active, at: 0)
    if updated.count > limit {
      updated.removeLast(updated.count - limit)
    }
    return updated
  }
}

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
      if let editor = resolvedEditorSession {
        CalciteEditorSessionContent(
          backend: backend,
          windowSession: windowSession,
          editorSession: editor
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

/// Keeps a bounded MRU set of native AppKit surfaces in Calcite Vim mode. Vim
/// state is restored from the session engine, so evicting a surface no longer
/// discards cursor, mode, pending input, selection, viewport, or undo state. The
/// default editor retains its surfaces because AppKit still owns its undo state.
@MainActor
private struct CalciteEditorSessionContent: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession
  @ObservedObject var editorSession: CalciteBackendWindowSession.EditorSession
  @AppStorage(EditorInterfacePreferences.interfaceKey)
  private var editorInterfaceRaw = EditorInterface.builtIn.rawValue
  @State private var residentDocumentIDs: [UUID] = []

  private let nativeSurfaceResidencyLimit = 3

  @ViewBuilder
  var body: some View {
    if editorInterface.usesTerminalEditor {
      currentDocumentSurface
    } else if backend.documents.isEmpty {
      CalciteEditorEmptyState(backend: backend)
    } else {
      ZStack {
        ForEach(surfaceDocuments) { document in
          let isActiveDocument = document.id == editorSession.documentID
          CalciteEditorView(
            backend: backend,
            windowSession: windowSession,
            editorSession: editorSession,
            tab: document,
            isActiveDocument: isActiveDocument,
            activate: { windowSession.activateEditorSession(editorSession.id) }
          )
          .id("\(editorSession.id.uuidString)|\(document.id.uuidString)|native-surface")
          .opacity(isActiveDocument ? 1 : 0)
          .allowsHitTesting(isActiveDocument)
          .accessibilityHidden(!isActiveDocument)
          .zIndex(isActiveDocument ? 1 : 0)
        }
      }
      .clipped()
      .onAppear(perform: updateNativeSurfaceResidency)
      .onChange(of: editorInterfaceRaw) { _, _ in updateNativeSurfaceResidency() }
      .onChange(of: editorSession.documentID) { _, _ in updateNativeSurfaceResidency() }
      .onChange(of: documentIDs) { _, _ in updateNativeSurfaceResidency() }
    }
  }

  @ViewBuilder
  private var currentDocumentSurface: some View {
    if let document = editorSession.document {
      CalciteEditorView(
        backend: backend,
        windowSession: windowSession,
        editorSession: editorSession,
        tab: document,
        isActiveDocument: true,
        activate: { windowSession.activateEditorSession(editorSession.id) }
      )
    } else {
      CalciteEditorEmptyState(backend: backend)
    }
  }

  private var documentIDs: [UUID] { backend.documents.map(\.id) }

  private var surfaceDocuments: [EditorTab] {
    guard editorInterface.usesCalciteVim else { return backend.documents }
    let byID = Dictionary(uniqueKeysWithValues: backend.documents.map { ($0.id, $0) })
    return residentDocumentIDs.compactMap { byID[$0] }
  }

  private func updateNativeSurfaceResidency() {
    guard editorInterface.usesCalciteVim else {
      residentDocumentIDs.removeAll(keepingCapacity: true)
      return
    }
    residentDocumentIDs = CalciteVimSurfaceResidencyPolicy.updatedDocumentIDs(
      current: residentDocumentIDs,
      active: editorSession.documentID,
      available: Set(documentIDs),
      limit: nativeSurfaceResidencyLimit
    )
  }

  private var editorInterface: EditorInterface {
    EditorInterface(rawValue: editorInterfaceRaw) ?? .builtIn
  }
}
