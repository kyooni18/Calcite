import EditorDAP
import Foundation
import Testing

@testable import EditorServices

@Suite("Public API compatibility")
struct PublicAPICompatibilityTests {
  @Test("legacy build-command initializers remain available")
  func legacyBuildCommandInitializers() {
    let root = URL(fileURLWithPath: "/tmp/calcite-api")
    let executableForm = EditorBuildCommand(
      id: "build", title: "Build", kind: .build, executable: "swift",
      arguments: ["build"], workingDirectory: root
    )
    let argvForm = EditorBuildCommand(
      id: "run", title: "Run", kind: .run,
      arguments: ["swift", "run"], workingDirectory: root
    )
    #expect(executableForm.executable == "swift")
    #expect(executableForm.artifactPath == nil)
    #expect(argvForm.executable == "swift")
    #expect(argvForm.arguments == ["run"])
  }

  @Test("legacy build-command JSON decodes without artifactPath")
  func legacyBuildCommandJSON() throws {
    let json =
      #"{"id":"build","title":"Build","kind":"build","executable":"swift","arguments":["build"],"workingDirectory":"file:///tmp/calcite-api","environment":{}}"#
    let command = try JSONDecoder().decode(EditorBuildCommand.self, from: Data(json.utf8))
    #expect(command.artifactPath == nil)
    #expect(command.executable == "swift")
  }

  private func compileLegacyDebuggerCalls(
    backend: SwiftEditorBackend,
    bootstrap: EditorServiceBootstrapResult,
    session: DAPSession,
    process: DebugAdapterProcessConfiguration
  ) async throws {
    _ = DAPClient(session: session)
    _ = try await backend.startDebugger(session: session)
    _ = try await backend.startDebugger(process: process)
    _ = try await backend.startLLDBDebugger()
    _ = try await bootstrap.startDebugger(for: .swift)
  }
}
