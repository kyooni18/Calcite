import Combine
import SwiftUI

/// Owns the project backend and one window session for the sectional workbench entry point.
@MainActor
struct CalciteWorkspaceHostView: View {
  @StateObject private var context: CalciteWorkspaceHostContext

  let initialFileURL: URL?
  let documentOpenRequestID: UUID?
  let onControllerReady: (EditorWorkspaceController?) -> Void

  init(
    workspaceURL: URL,
    initialFileURL: URL? = nil,
    documentOpenRequestID: UUID? = nil,
    recentItems: EditorRecentItemsStore,
    onOpenItem: @escaping () -> Void = {},
    onRequestCloseWindow: @escaping () -> Void = {},
    onControllerReady: @escaping (EditorWorkspaceController?) -> Void = { _ in }
  ) {
    _context = StateObject(
      wrappedValue: CalciteWorkspaceHostContext(
        workspaceURL: workspaceURL,
        recentItems: recentItems,
        onOpenItem: onOpenItem,
        onRequestCloseWindow: onRequestCloseWindow
      )
    )
    self.initialFileURL = initialFileURL
    self.documentOpenRequestID = documentOpenRequestID
    self.onControllerReady = onControllerReady
  }

  var body: some View {
    CalciteWorkspaceView(
      backend: context.backend,
      windowSession: context.windowSession,
      initialFileURL: initialFileURL,
      documentOpenRequestID: documentOpenRequestID,
      onControllerReady: onControllerReady
    )
  }
}

@MainActor
private final class CalciteWorkspaceHostContext: ObservableObject {
  let objectWillChange = ObservableObjectPublisher()

  let backend: CalciteBackend
  let windowSession: CalciteBackendWindowSession

  init(
    workspaceURL: URL,
    recentItems: EditorRecentItemsStore,
    onOpenItem: @escaping () -> Void,
    onRequestCloseWindow: @escaping () -> Void
  ) {
    let backend = CalciteBackend.shared(
      for: workspaceURL,
      recentItems: recentItems
    )
    self.backend = backend
    self.windowSession = backend.makeWindowSession(
      onOpenItem: onOpenItem,
      onRequestCloseWindow: onRequestCloseWindow
    )
  }
}
