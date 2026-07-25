import EditorServices
import Foundation

func manageCompleteSourceProject(at root: URL) async throws {
    var configuration = SwiftEditorBackendConfiguration(workspaceURL: root)
    configuration.sourceWorkspaceMonitoringInterval = .seconds(1)
    let backend = try await SwiftEditorBackend.makeSwift(configuration: configuration)
    defer { Task { try? await backend.shutdown() } }

    let snapshot = await backend.sourceWorkspaceSnapshot()
    print("Indexed \(snapshot.files.count) files")

    let created = try await backend.createSourceFile(
        at: "Sources/App/GeneratedFeature.swift",
        content: "struct GeneratedFeature {}\n",
        openInEditor: true
    )

    let fileSession = try await backend.sourceFileSession(id: created.id)
    _ = try await fileSession.setContent(
        "struct GeneratedFeature { let enabled = true }\n",
        expectedVersion: created.version
    )
    _ = try await fileSession.save()

    let matches = try await backend.searchSource(
        .literal("GeneratedFeature"),
        options: .init(wholeWord: true, includedFileExtensions: ["swift"])
    )
    print("Matches:", matches.count)

    let archive = try await backend.encodedSourceWorkspaceArchive()
    try archive.write(
        to: root.appendingPathComponent("SourceWorkspace.backup.json"),
        options: .atomic
    )
}
