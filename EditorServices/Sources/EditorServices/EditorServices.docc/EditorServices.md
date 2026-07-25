# ``EditorServices``

Build a multi-language code-editor backend with LSP, Tree-sitter, Vim actions, and DAP.

## Overview

Use ``SwiftEditorBackend`` for the standard integrated workflow. It owns open documents, creates an independent Tree-sitter parser for each document, stores the complete source tree, merges keyword and language-service completions, and hosts one optional debug session. ``EditorBackendBuilder`` and ``LanguageServiceRouter`` compose multiple local, remote, or supplemental language services with deterministic per-document routing.

```swift
let backend = try await SwiftEditorBackend.makeSwift(
    configuration: .init(workspaceURL: workspaceURL)
)
try await backend.openFile(at: sourceFileURL)
```

## Topics

### Start Here

- <doc:BackendConstruction>
- <doc:GettingStarted>
- <doc:LanguageIntelligence>
- <doc:ModularLanguageServices>
- <doc:MultiLanguageSupport>
- <doc:ServiceDiscovery>
- <doc:SourceWorkspace>
- <doc:WorkspaceEdits>
- <doc:SwiftUIIntegration>
- <doc:Debugging>

### Unified Backend

- ``SwiftEditorBackend``
- ``EditorBackendBuilder``
- ``SwiftEditorBackendConfiguration``
- ``MultiLanguageEditorBackendConfiguration``
- ``ExternalLanguageServerConfiguration``
- ``SwiftEditorCompletionStrategy``
- ``SwiftEditorBackendError``
- ``DebugAdapterProcessConfiguration``

### Source Workspace

- ``SourceWorkspace``
- ``SourceCodeFile``
- ``SourceFileID``
- ``SourceWorkspaceSnapshot``
- ``SourceWorkspaceArchive``
- ``SwiftSourceFileSession``

### Documents

- ``EditorDocument``
- ``TextSnapshot``
- ``TextPosition``
- ``EditorTextRange``
- ``TextEdit``
- ``AppliedTextEdit``

### Automatic Discovery

- ``EditorServiceBootstrap``
- ``EditorServicesConfiguration``
- ``EditorLanguage``
- ``EditorServiceAvailabilityReport``
- ``EditorServiceBootstrapError``

### Multi-language Configuration

- ``EditorLanguageCatalog``
- ``TreeSitterLanguageRegistry``
- ``TreeSitterLanguageRegistration``
- ``LSPProcessConnection``
- ``LSPProcessConfiguration``
- ``ExternalLanguageServerPresets``

### Service Composition

- ``LanguageServiceRouter``
- ``LanguageServiceRegistration``
- ``LanguageServiceSelector``
- ``LanguageServiceRole``
- ``LanguageServiceID``
- ``LanguageServiceDescriptor``
- ``LanguageServiceRouterError``

### Language Features

- ``Completion``
- ``Highlight``
- ``SemanticHighlight``
- ``Diagnostic``
- ``HoverResult``
- ``SourceLocation``
- ``EditorWorkspaceEdit``
- ``WorkspaceEditApplicationResult``
- ``EditorSignatureHelp``
- ``EditorDocumentSymbol``
- ``EditorCodeAction``
- ``EditorInlayHint``

### Debugging

- ``DAPClient``
- ``DAPSession``
- ``DAPEvent``
- ``DebugSessionState``
- ``LLDBDAPResolver``
