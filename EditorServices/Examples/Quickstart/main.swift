import EditorServices
import Foundation

@main
struct EditorServicesQuickstart {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: swift run EditorServicesQuickstart <workspace-directory> <swift-file>")
            return
        }

        let workspace = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        ).standardizedFileURL
        let file = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let backend = try await SwiftEditorBackend.makeSwift(workspaceURL: workspace)

        do {
            let scan = try await backend.scanSourceWorkspace()
            let metrics = await backend.sourceWorkspaceMetrics()
            try await backend.openFile(at: file)
            let snapshot = try await backend.snapshot(of: file)
            let end = try snapshot.position(atUTF16Offset: snapshot.utf16Count)
            async let highlights = backend.highlights(in: file)
            async let completions = backend.completions(in: file, at: end)
            let (highlightValues, completionValues) = try await (highlights, completions)

            print("Opened: \(file.path)")
            print("Indexed source files: \(metrics.fileCount)")
            print("Indexed source lines: \(metrics.totalLines)")
            print("Newly discovered IDs: \(scan.added.count)")
            print("Document version: \(snapshot.version)")
            print("Tree-sitter captures: \(highlightValues.count)")
            print("Completions at end of file: \(completionValues.count)")
        } catch {
            try? await backend.shutdown()
            throw error
        }

        try await backend.shutdown()
    }
}
