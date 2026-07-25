# Modular Language Services

Compose, select, and replace language-intelligence providers without rebuilding editor state.

## Register services declaratively

A ``LanguageServiceRegistration`` combines a stable ``LanguageServiceID``, a service conforming to ``LanguageIntelligenceProviding``, a ``LanguageServiceRole``, priority, ``LanguageServiceSelector``, and shutdown hook.

```swift
let registration = LanguageServiceRegistration(
    id: "sourcekit",
    service: sourceKitService,
    role: .primary,
    priority: 100,
    selector: .init(
        languageIDs: ["swift"],
        fileExtensions: ["swift"],
        urlSchemes: ["file"]
    ),
    shutdown: { try await sourceKitService.shutdown() }
)
```

A selector may also include a `@Sendable` predicate for workspace-specific matching. Empty selector sets behave as wildcards. Matching is case-insensitive and file extensions may be supplied with or without a leading period.

## Build the backend

```swift
let backend = try await EditorBackendBuilder(
    workspaceURL: workspaceURL,
    syntaxFactory: { try TreeSitterSyntaxService.swift() }
)
.addingLanguageService(registration)
.build()
```

``EditorBackendBuilder`` keeps syntax, language services, source-workspace scanning, monitoring, and completion policy independently configurable. It creates an empty router when there are no initial registrations, allowing plug-ins to be attached later. ``SwiftEditorBackend/makeSwift(workspaceURL:)`` also exposes a router, with SourceKit-LSP registered as the initial primary service.

## Change services at runtime

```swift
guard let router = backend.languageServiceRouter else { return }

try await router.register(markdownRegistration)
let selected = try await router.boundServiceIDs(for: documentURL)
try await router.rebindDocument(at: documentURL)
try await router.unregister("markdown")
```

Registering a service automatically opens every currently open matching document in that service. Unregistering closes bound documents before the optional shutdown hook. Rebinding recalculates selection against the current registrations and document language.

## Selection and failures

The router orders primary services before supplemental services, then by descending priority, then by registration order. Lifecycle operations fan out to every selected service. Additive feature output is merged and deduplicated; exclusive requests use the first supporting service.

A primary feature failure propagates to the caller. A supplemental feature failure is published as a warning message so primary results remain usable. Failed changes recover selected services to the previous document snapshot rather than leaving a partially synchronized set.

## Route per document

```swift
try await backend.openDocument(
    at: readmeURL,
    text: readmeText,
    languageID: "markdown"
)

let languageID = try await backend.documentLanguageID(at: readmeURL)
```

Files loaded from ``SourceWorkspace`` use the language identifier stored in their ``SourceCodeFile`` metadata. That identifier survives moves, transactional rollback, scanning, and archive restoration.
