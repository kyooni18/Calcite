# Automatic Project Service Discovery

Inspect an opened project and construct only the language services it needs.

## Overview

``EditorServicesBootstrap/make(workspaceURL:policy:)`` is the recommended mixed-language entry point. It scans the workspace for supported source files and project markers, resolves the corresponding LSP, Tree-sitter, and DAP integrations, and delegates construction to the existing multi-language backend.

```swift
let services = try await EditorServicesBootstrap.make(
    workspaceURL: workspaceURL
)

let backend = services.backend
let selectedLanguages = services.selectedLanguages
```

The default ``EditorServiceRequirementPolicy/bestEffort`` policy starts valid installed services and records unavailable integrations in ``EditorServiceBootstrapResult/report``.

## Inspect before construction

Use ``EditorServicesBootstrap/inspect(workspaceURL:languageSelection:policy:overrides:)`` to scan the project and resolve availability without starting external processes:

```swift
let inspection = try await EditorServicesBootstrap.inspect(
    workspaceURL: workspaceURL
)

for evidence in inspection.projectInspection?.evidence ?? [] {
    print(evidence.language.displayName)
    print(evidence.sourceFileCount)
    print(evidence.projectMarkers)
}
```

``EditorProjectInspectionReport`` records the detected languages, evidence, number of files inspected, skipped directories, and whether the configured limit truncated the scan.

## Control language selection

Automatic detection can be adjusted without replacing it:

```swift
let selection = EditorLanguageSelection.automatic(
    including: [.graphql],
    excluding: [.json]
)

let configuration = EditorServicesConfiguration(
    workspaceURL: workspaceURL,
    languageSelection: selection
)
```

Use the compatibility initializer for a completely manual set:

```swift
let configuration = EditorServicesConfiguration(
    workspaceURL: workspaceURL,
    languages: [.swift, .rust, .typescript]
)
```

## Bound project inspection

``EditorProjectInspectionConfiguration`` controls excluded directory names and relative paths, hidden items, project-marker matching, symbolic-link traversal, fallback languages, and file/evidence limits. Followed links are constrained to the opened workspace and resolved-directory tracking terminates cycles.

Project-local executable folders such as `node_modules/.bin`, `.venv/bin`, `venv/bin`, `.tools/bin`, and `bin` are searched before global `PATH` locations.

## Override installations

``EditorServiceOverrides`` provides authoritative language-server, debug-adapter, argument, and syntax-library values.

```swift
let overrides = EditorServiceOverrides(
    languageServerExecutables: [.rust: rustAnalyzerPath],
    debugAdapterExecutables: [.go: delvePath],
    debugAdapterArguments: [.go: ["dap"]],
    syntaxLibraries: [
        .rust: EditorSyntaxLibraryConfiguration(
            libraryURL: rustGrammarURL,
            symbol: "tree_sitter_rust",
            highlightsQueryURL: rustHighlightsURL
        )
    ]
)
```

Invalid explicit paths are reported as invalid and never replaced silently. Shared servers resolve once for JavaScript/TypeScript and the C-family.

## Debug adapter profiles

``EditorServiceInspectionResult/debugAdapter(for:)`` and ``EditorServiceBootstrapResult/debugAdapter(for:)`` select the resolved adapter for a language. Built-in discovery distinguishes LLDB, Delve, debugpy, netcoredbg, and Dart adapters instead of treating every language as LLDB-compatible.

## Failure behavior

``EditorServiceAvailabilityReport`` distinguishes available, missing, disabled, unsupported, and invalid integrations. Required failures throw ``EditorServiceBootstrapError/requiredServicesUnavailable(_:)`` with the report intact. Startup failures preserve the exact server and ``ExternalLanguageServerStartupStage``.

LSP initialization and shutdown use bounded timeouts in both the automatic bootstrap and the direct Swift factory, and DAP requests use bounded client timeouts. Closed child-process pipes propagate transport errors rather than terminating the host process.

## Topics

- ``EditorProjectInspector``
- ``EditorProjectInspectionConfiguration``
- ``EditorProjectInspectionReport``
- ``EditorProjectLanguageEvidence``
- ``EditorLanguageSelection``
- ``EditorServiceBootstrap``
- ``EditorServicesBootstrap``
- ``EditorServicesConfiguration``
- ``EditorLanguage``
- ``EditorFeatureSelection``
- ``EditorServiceRequirementPolicy``
- ``EditorServiceOverrides``
- ``EditorDebugAdapterConfiguration``
- ``EditorSyntaxLibraryConfiguration``
- ``EditorServiceInspectionResult``
- ``EditorServiceBootstrapResult``
- ``EditorServiceAvailabilityReport``
- ``EditorServiceDiagnostic``
- ``EditorServiceBootstrapError``
