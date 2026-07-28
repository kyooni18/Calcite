@_spi(Calcite) import EditorVim
import Foundation

@MainActor
struct CalciteVimHostRouter {
  var documentURL: URL?
  var documentID: UUID?
  var editorSessionID: UUID?
  var tabPageID: UUID?
  var revision: UInt64
  var handler: (VimHostInvocation) -> VimHostResponse

  func route(
    _ requests: [VimHostRequest],
    selection: NSRange,
    to engine: VimEngine
  ) {
    for request in requests {
      let response = handler(
        VimHostInvocation(
          request: request,
          context: VimHostInvocationContext(
            documentURL: documentURL,
            editorSessionID: editorSessionID,
            bufferID: documentID.map(VimBufferID.init),
            windowID: editorSessionID.map(VimWindowID.init),
            tabPageID: tabPageID.map(VimTabPageID.init),
            selection: VimSelection(selection.location, NSMaxRange(selection)),
            revision: VimDocumentRevision(revision)
          )
        )
      )
      engine.publishHostResponse(response)
    }
  }
}
