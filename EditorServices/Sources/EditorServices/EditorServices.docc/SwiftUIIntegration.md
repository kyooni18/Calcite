# SwiftUI Integration

Embed service settings in a split view and connect a native text surface to ``SwiftEditorBackend``.

## Add the project-aware settings detail

``EditorServicesSettingsView`` is designed to occupy a `NavigationSplitView` detail column. Its simplest initializer owns the settings model and automatically performs process-free project inspection:

```swift
NavigationSplitView {
    WorkspaceSidebar(selection: $selection)
} detail: {
    EditorServicesSettingsView(workspaceURL: workspaceURL) { configuration in
        persist(configuration)
    }
}
```

The screen exposes:

- automatic or manual language selection;
- per-language detection evidence;
- LSP, Tree-sitter, and DAP feature toggles;
- best-effort, required-LSP, and strict policies;
- project-inspection options and limits;
- authoritative per-language executable/library overrides;
- process-free availability diagnostics and recovery suggestions.

## Own the settings state

Retain ``EditorServicesSettingsModel`` when another view needs to observe or modify the settings:

```swift
@StateObject private var settings: EditorServicesSettingsModel

init(workspaceURL: URL) {
    _settings = StateObject(
        wrappedValue: EditorServicesSettingsModel(workspaceURL: workspaceURL)
    )
}

var body: some View {
    EditorServicesSettingsView(model: settings)
}
```

Call `await settings.refreshInspection()` after changing project or path settings when an immediate refresh is desired. On macOS, apply the current selection explicitly with `try await settings.makeBackend()`.

## Keep one document source of truth

Treat the backend snapshot as the authoritative synchronized document state. Native `NSTextView` and `UITextView` edit ranges can be applied directly because they use UTF-16 units:

```swift
try await backend.applyUTF16Edit(
    editedRange,
    replacement: replacementString,
    to: fileURL
)
```

For non-native editor surfaces, construct a ``TextEdit`` with zero-based ``TextPosition`` values instead.

When an edit fails, restore the native text storage from `backend.snapshot(of:)`. The document coordinator rolls back its local buffer and attempts to resynchronize Tree-sitter and LSP before returning the error.

## Render highlighting

Request Tree-sitter captures after edits and map capture names to text attributes. Apply semantic tokens afterward so semantic classifications override lexical ones.

```swift
async let syntax = backend.highlights(in: fileURL)
async let semantic = backend.semanticHighlights(in: fileURL)
let (syntaxValues, semanticValues) = try await (syntax, semantic)
```

## Observe diagnostics

Start one task for the lifetime of the editor workspace:

```swift
for await batch in backend.diagnostics {
    await MainActor.run {
        diagnosticsStore[batch.uri] = batch.diagnostics
    }
}
```

## Avoid full-text replacement for every key press

Use `NSTextViewDelegate` or `UITextViewDelegate` edit ranges to create incremental ``TextEdit`` values. Reserve `replaceText(in:with:)` for reloads, external file changes, or recovery.
