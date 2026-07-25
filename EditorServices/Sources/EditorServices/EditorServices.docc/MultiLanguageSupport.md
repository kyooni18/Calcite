# Multi-language LSP and Tree-sitter support

Run independent language servers and syntax parsers for different documents in one workspace.

## Overview

``MultiLanguageEditorBackend`` is a generic name for the same unified backend used by the Swift convenience factory. ``SwiftEditorBackend/makeMultiLanguage(configuration:)`` creates a ``LanguageServiceRouter`` and routes each document by its canonical language ID. Each configured server is an independent standard-input/standard-output Language Server Protocol process.

```swift
let backend = try await MultiLanguageEditorBackend.makeMultiLanguage(
    configuration: .init(
        workspaceURL: workspaceURL,
        languageServers: [
            ExternalLanguageServerPresets.swift(),
            ExternalLanguageServerPresets.pyright(),
            ExternalLanguageServerPresets.clangd(arguments: ["--background-index"]),
            ExternalLanguageServerPresets.rustAnalyzer(),
            ExternalLanguageServerPresets.gopls(),
            ExternalLanguageServerPresets.typescript(),
            ExternalLanguageServerPresets.eslint()
        ],
        treeSitterRegistry: grammarRegistry
    )
)
```

Only include servers installed on the current machine. A construction error is returned if an executable cannot be resolved through `PATH` or an explicit path.

## Connect any stdio language server

Use ``ExternalLanguageServerPresets/custom(id:executable:arguments:languageIDs:fileExtensions:initializationOptions:priority:)`` for a server that does not have a convenience preset.

```swift
let server = ExternalLanguageServerPresets.custom(
    id: "my-language-server",
    executable: "/opt/tools/my-language-server",
    arguments: ["--stdio"],
    languageIDs: ["my-language"],
    fileExtensions: ["my"]
)
```

For advanced configuration, construct ``ExternalLanguageServerConfiguration`` directly. It supports initialization options, `workspace/configuration` responses, primary or supplemental routing roles, priorities, eager initialization, and automatic workspace-edit application.

The generic process transport is ``LSPProcessConnection``. Remote or socket-based servers can implement ``LSPServerTransport`` and be registered through ``EditorBackendBuilder`` without using a child process.

## Register Tree-sitter grammars

``TreeSitterLanguageRegistry`` accepts any ``SwiftTreeSitter/Language`` value. The grammar does not need to be known by EditorServices.

```swift
import SwiftTreeSitter
import TreeSitterPython

let python = TreeSitterLanguageRegistration(
    id: "tree-sitter-python",
    languageIDs: ["python"],
    fileExtensions: ["py", "pyi"],
    language: Language(language: tree_sitter_python()),
    queries: try .load(
        highlightsURL: pythonHighlightsURL,
        foldsURL: pythonFoldsURL
    )
)

let grammars = try TreeSitterLanguageRegistry(registrations: [
    TreeSitterLanguageRegistry.swiftRegistration(),
    python
])
```

Highlight and fold queries are optional. A grammar without queries still provides incremental parsing and a syntax tree.

On macOS and Linux, ``DynamicTreeSitterLanguage`` can load a grammar dynamic library by its standard `tree_sitter_<language>` symbol. The loader retains the library for the lifetime of every parser that uses it.

```swift
let library = try DynamicTreeSitterLanguage(
    libraryURL: grammarLibraryURL,
    symbol: "tree_sitter_python"
)
try grammars.register(
    library.registration(
        id: "tree-sitter-python",
        languageIDs: ["python"],
        fileExtensions: ["py"]
    )
)
```

Mobile applications should statically link grammar packages instead of loading external dynamic libraries.

## Language detection

``EditorLanguageCatalog/standard`` recognizes common LSP language IDs for Swift, C, C++, Objective-C, Python, Rust, Go, Java, Kotlin, JavaScript, TypeScript, C#, F#, Ruby, PHP, Lua, shell, web formats, configuration formats, and many additional languages. Supply a custom ``EditorLanguageCatalog`` when a project uses different IDs or extensions.

The catalog is used by both the source workspace and direct document opening, so a `.py` document can route to Pyright and a Python grammar while a `.cpp` document routes to clangd and a C++ grammar in the same backend.

## Platform behavior

Local language-server processes are available on macOS and Linux. On iOS and Mac Catalyst, use ``EditorBackendBuilder`` with a remote or application-provided ``LanguageIntelligenceProviding`` implementation. Statically linked Tree-sitter grammars remain available on every package platform.
