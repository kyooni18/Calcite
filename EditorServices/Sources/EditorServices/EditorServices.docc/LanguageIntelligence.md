# Language Intelligence

Use editor-native models for SourceKit-LSP features.

## Completion and navigation

```swift
let completions = try await backend.completions(in: file, at: cursor)
let hover = try await backend.hover(in: file, at: cursor)
let definitions = try await backend.definitions(in: file, at: cursor)
let references = try await backend.references(in: file, at: cursor)
```

Completion items may include snippet syntax, a primary edit, and additional edits. Apply those edits instead of inserting only the displayed label.

## Signatures, symbols, actions, and hints

```swift
let signature = try await backend.signatureHelp(in: file, at: cursor)
let symbols = try await backend.documentSymbols(in: file)
let actions = try await backend.codeActions(
    in: file,
    range: visibleRange,
    diagnostics: currentDiagnostics,
    only: ["quickfix"]
)
let hints = try await backend.inlayHints(in: file, range: visibleRange)
```

The returned values use ``EditorSignatureHelp``, ``EditorDocumentSymbol``, ``EditorCodeAction``, and ``EditorInlayHint`` rather than vendor protocol types.

## Formatting and semantic highlighting

```swift
let formatting = try await backend.formattingEdits(in: file)
let semantic = try await backend.semanticHighlights(in: file)
```

Validate UI state against the current ``TextSnapshot`` before rendering asynchronous results. The backend validates server-provided ranges against the synchronized snapshot before returning them.

## Attribute routed results

When multiple services are registered, completion items, commands, diagnostic batches, and server messages may include `serviceIdentifier`. The router uses this metadata internally to resolve completion items and execute commands through the service that created them; applications may also display it for diagnostics or debugging.

Supplemental service failures do not hide successful primary results. They are emitted through the message stream. Primary failures continue to throw from the requested feature.

See <doc:ModularLanguageServices> for registration, selection, and runtime rebinding.
