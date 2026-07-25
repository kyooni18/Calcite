import EditorServices
import Foundation

func loadAdvancedEditorFeatures(
    backend: SwiftEditorBackend,
    file: URL,
    visibleRange: TextRange,
    cursor: TextPosition,
    diagnostics: [Diagnostic]
) async throws {
    async let signature = backend.signatureHelp(in: file, at: cursor)
    async let symbols = backend.documentSymbols(in: file)
    async let actions = backend.codeActions(
        in: file,
        range: visibleRange,
        diagnostics: diagnostics,
        only: ["quickfix"]
    )
    async let hints = backend.inlayHints(in: file, range: visibleRange)

    let values = try await (signature, symbols, actions, hints)
    _ = values
}
