# Backend Construction

Create the complete local Swift backend with one public class.

## Minimal construction

On macOS or Linux, ``SwiftEditorBackend/makeSwift(workspaceURL:)`` starts the standard stack:

```swift
let backend = try await SwiftEditorBackend.makeSwift(workspaceURL: workspaceURL)
```

This creates a SourceKit-LSP service registered inside a ``LanguageServiceRouter``, an independent Tree-sitter parser for every open document, keyword completion fallback, diagnostic streams, complete source-workspace storage, and optional DAP hosting. Disabling the local language server still leaves an empty router available for later plug-ins.

## Configure the local stack

Use ``SwiftEditorBackendConfiguration`` when you need explicit tool paths or disabled services:

```swift
var configuration = SwiftEditorBackendConfiguration(workspaceURL: workspaceURL)
configuration.sourceKitLSPExecutablePath = "/custom/toolchain/usr/bin/sourcekit-lsp"
configuration.completionStrategy = .mergeKeywordsAndFallbackOnError
configuration.completionLimit = 150

let backend = try await SwiftEditorBackend.makeSwift(configuration: configuration)
```

An explicit executable path is authoritative. Invalid explicit paths fail instead of silently falling back to another toolchain.

## Inject a remote service

Platforms that cannot spawn a language-server process can inject a type conforming to ``LanguageIntelligenceProviding``:

```swift
let backend = SwiftEditorBackend(
    workspaceURL: workspaceURL,
    languageService: remoteLSPService,
    syntaxFactory: { try TreeSitterSyntaxService.swift() }
)
```

The application still uses the same ``SwiftEditorBackend`` document and language-feature methods.

## Compose independent services

Use ``EditorBackendBuilder`` to configure multiple services without coupling application code to their transports:

```swift
let backend = try await EditorBackendBuilder(
    workspaceURL: workspaceURL,
    syntaxFactory: { try TreeSitterSyntaxService.swift() }
)
.addingLanguageService(
    .init(
        id: "swift",
        service: sourceKitService,
        role: .primary,
        priority: 100,
        selector: .init(languageIDs: ["swift"]),
        shutdown: { try await sourceKitService.shutdown() }
    )
)
.addingLanguageService(
    .init(
        id: "linter",
        service: linterService,
        role: .supplemental,
        selector: .init(fileExtensions: ["swift"])
    )
)
.build()
```

The builder always supplies a ``LanguageServiceRouter``. Access it through ``SwiftEditorBackend/languageServiceRouter`` to register or unregister plug-ins while the workspace is running.
