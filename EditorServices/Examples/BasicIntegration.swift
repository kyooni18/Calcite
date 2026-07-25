import EditorServices
import Foundation

func runBackendExample(workspaceURL: URL, fileURL: URL) async throws {
    let backend = try await SwiftEditorBackend.makeSwift(
        configuration: .init(workspaceURL: workspaceURL)
    )
    defer { Task { try? await backend.shutdown() } }

    try await backend.openFile(at: fileURL)
    let snapshot = try await backend.snapshot(of: fileURL)
    let end = try snapshot.position(atUTF16Offset: snapshot.utf16Count)

    let completions = try await backend.completions(in: fileURL, at: end)
    print(completions.map(\.label))
}
