import EditorServices
import Foundation

func renameAndApply(
    backend: SwiftEditorBackend,
    file: URL,
    position: TextPosition,
    newName: String
) async throws -> [WorkspaceFileOperation] {
    guard let edit = try await backend.rename(in: file, at: position, to: newName) else {
        return []
    }

    let result = try await backend.applyWorkspaceEdit(
        edit,
        openMissingFiles: true
    )

    // File create/rename/delete operations are deliberately not executed by
    // the backend. Present them to the user or apply them with your file layer.
    return result.pendingFileOperations
}
