#if os(macOS)
import AppKit
import EditorServices

final class EditorTextViewCoordinator: NSObject, NSTextViewDelegate {
    let backend: SwiftEditorBackend
    let fileURL: URL

    init(backend: SwiftEditorBackend, fileURL: URL) {
        self.backend = backend
        self.fileURL = fileURL
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        let currentText = textView.string
        let replacement = replacementString ?? ""
        Task {
            do {
                let snapshot = TextSnapshot(text: currentText)
                let start = try snapshot.position(atUTF16Offset: affectedCharRange.location)
                let end = try snapshot.position(atUTF16Offset: NSMaxRange(affectedCharRange))
                try await backend.apply(
                    TextEdit(
                        range: TextRange(start: start, end: end),
                        replacement: replacement
                    ),
                    to: fileURL
                )
            } catch {
                let authoritative = try? await backend.snapshot(of: fileURL)
                await MainActor.run {
                    if let authoritative { textView.string = authoritative.text }
                }
            }
        }
        return true
    }
}
#endif
