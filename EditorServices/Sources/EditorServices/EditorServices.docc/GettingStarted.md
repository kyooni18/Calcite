# Getting Started

Create, edit, query, save, and close a Swift document through one backend.

## Create the backend

For an opened mixed-language project on macOS or Linux, let the package inspect the workspace and select its services:

```swift
let workspace = URL(fileURLWithPath: "/path/to/project", isDirectory: true)
let services = try await EditorServicesBootstrap.make(workspaceURL: workspace)
let backend = services.backend
```

For a Swift-only package, the direct factory remains available:

```swift
let backend = try await SwiftEditorBackend.makeSwift(workspaceURL: workspace)
```

Disable individual services when needed:

```swift
var configuration = SwiftEditorBackendConfiguration(workspaceURL: workspace)
configuration.enableLanguageServer = false
configuration.enableTreeSitter = true
let syntaxOnly = try await SwiftEditorBackend.makeSwift(configuration: configuration)
```

## Open and edit

```swift
let file = workspace.appendingPathComponent("Sources/App/App.swift")
try await backend.openFile(at: file)

// For an unsaved or non-Swift document, supply its language explicitly.
try await backend.openDocument(at: draftURL, text: draftText, languageID: "markdown")

let edit = TextEdit(
    range: EditorTextRange(
        start: TextPosition(line: 4, utf16Column: 8),
        end: TextPosition(line: 4, utf16Column: 11)
    ),
    replacement: "result"
)
try await backend.apply(edit, to: file)
```

Positions are zero-based and columns are measured in UTF-16 code units.

## Request editor features

```swift
let completions = try await backend.completions(
    in: file,
    at: TextPosition(line: 4, utf16Column: 14)
)
let highlights = try await backend.highlights(in: file)
let hover = try await backend.hover(in: file, at: .zero)
let definitions = try await backend.definitions(in: file, at: .zero)
let signature = try await backend.signatureHelp(in: file, at: .zero)
let symbols = try await backend.documentSymbols(in: file)
```

## Save and shut down

```swift
try await backend.persistDocument(at: file)
try await backend.closeDocument(at: file)
try await backend.shutdown()
```
