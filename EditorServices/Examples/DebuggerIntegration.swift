import EditorServices
import Foundation

func launchExample(
    backend: SwiftEditorBackend,
    executable: URL,
    sourceFile: URL
) async throws {
    try await backend.startLLDBDebugger()
    try await backend.launchDebugger(arguments: [
        "program": .string(executable.path),
        "cwd": .string(backend.workspaceURL.path)
    ])
    try await backend.setBreakpoints(
        in: sourceFile,
        breakpoints: [SourceBreakpoint(line: 12)]
    )
    try await backend.finishDebuggerConfiguration()
}
