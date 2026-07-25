# Debugging

Run an LLDB-compatible Debug Adapter Protocol session through ``SwiftEditorBackend``.

## Start LLDB-DAP

```swift
try await backend.startLLDBDebugger()
try await backend.launchDebugger(arguments: [
    "program": .string(executable.path),
    "cwd": .string(workspace.path)
])
```

## Configure breakpoints

```swift
try await backend.setBreakpoints(
    in: sourceFile,
    breakpoints: [
        SourceBreakpoint(line: 18),
        SourceBreakpoint(line: 27, condition: "value > 10")
    ]
)
try await backend.finishDebuggerConfiguration()
```

DAP line numbers are one-based by default, unlike ``TextPosition`` lines, which are zero-based.

## Observe events

```swift
for await event in backend.debugEvents {
    if event.event == "stopped" {
        let threads = try await backend.debugThreads()
        let trace = try await backend.stackTrace(threadID: threads[0].id)
        let scopes = try await backend.scopes(frameID: trace.stackFrames[0].id)
        _ = scopes
    }
}
```

Use `debugAdapterStandardError` for adapter logs and `debugTransportErrors` for framing or pipe errors.

## End the session

```swift
try await backend.disconnectDebugger()
```
