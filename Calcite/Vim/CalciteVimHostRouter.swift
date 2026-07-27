@_spi(Calcite) import EditorVim
import Foundation

@MainActor
struct CalciteVimHostRouter {
  var documentURL: URL?
  var editorSessionID: UUID?
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
            selection: VimSelection(selection.location, NSMaxRange(selection)),
            revision: VimDocumentRevision(revision)
          )
        )
      )
      engine.publishHostResponse(response)
    }
  }
}
