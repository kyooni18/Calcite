# VimEngine Stage 19: Authoritative Editing Pipeline

Stage 19 consolidates Vim transaction validation and improves Calcite's theme workflow.

## Vim editing changes

- Added `VimTransactionCoordinator` as the shared validation and rebase policy.
- Added `VimTextChangeSet` to preserve separated external edits instead of collapsing them into one broad delta.
- `VimDocumentSession` now uses the shared coordinator and rejects missing or invalid transactions.
- `EditorTab.submitVimTransaction` uses the same coordinator, including safe non-overlapping rebases.
- `CalciteEditorSurface` no longer hides malformed Vim transactions behind a synthesized full-text edit.
- IME composition state is bound to the active document, controller, binding generation, and rendered revision so stale callbacks are discarded during tab handoff.
- Stage 18 buffer fallback now uses alternate buffer, MRU, then canonical buffer order and removes unloaded or wiped references.

## Theme importing

Supported automatic imports now include:

- VS Code JSON and JSONC extension manifests
- VSIX and ZIP theme packages
- TextMate plist and JSON themes
- Sublime Text `.sublime-color-scheme` and `.sublime-theme`
- Xcode `.xccolortheme`
- Vim color schemes
- Neovim JSON and statically analyzable Lua themes

Missing VS Code `include` or external `tokenColors` files produce diagnostics while retaining usable colors. CSS `rgb()` and `rgba()` values, `0xRRGGBB`, compound TextMate selectors, Neovim palette aliases, and terminal ANSI palettes are supported.

## Theme Builder

- Import and reimport from inside Theme Builder
- Variant selection for theme packs
- Import diagnostics shown inline
- Undoable workbench palette derivation
- Undoable contrast repair
- Font family, font size, line spacing, and editor opacity controls
- Field-level preservation of user customizations during reimport

## Verification

`swift test` executes 228 EditorServices tests with zero failures on Linux. Calcite AppKit and SwiftUI files were syntax-checked, but the full macOS Xcode build must still be run on macOS.
