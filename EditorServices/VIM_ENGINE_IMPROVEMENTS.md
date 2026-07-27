# VimEngine Stage 4 Improvements

This revision implements the Stage 4 semantic-history, search/Ex, visual-mode, and Calcite-integration milestone while preserving the existing ordinary public `EditorVim` API. Swift API-digester validation reports no source-breaking differences and the generated symbol graph remains at exactly 223 public symbols.

## Branch-preserving undo history

Linear undo and redo stacks are now backed by an internal undo tree. Editing after undo creates an alternate branch instead of discarding later history. Undo walks to the parent transaction, redo follows the preferred child, and the newest visited or created branch becomes the preferred redo path. Retention is bounded by an estimated UTF-16 edit-storage budget.

Existing public `.undo` and `.redo` actions are unchanged. Compatibility accessors retained for the test target expose the current active path without changing the public module surface.

## Semantic repeat and macro storage

Dot-repeat and macro recording now use normalized internal commands instead of depending only on public action invocations. Paste commands capture the resolved typed register value, including linewise metadata, at recording time. Later register changes therefore do not alter dot-repeat or recorded macro playback.

Macro append, counts, register prefixes, `@@`, recursion limits, mapped commands, insert sessions, and prompt/Ex actions continue through the common execution pipeline.

## Exact execution edit batches

Every engine-originated text mutation is retained as an ordered edit batch. History replay records exact inverse edits, and recursively expanded mappings are wrapped in one controller-level batch. The most recent top-level batch replaces the previous unconsumed batch, preventing edit accumulation in clients that do not use Calcite's incremental-edit SPI.

Calcite consumes the exact edits and applies them sequentially to `NSTextStorage`. It falls back to a broad diff only if the batch cannot reproduce the engine's final text. Presentation invalidation, geometry updates, selection publication, and text revisions are coalesced around the completed execution.

## Vim regex compatibility layer

Search, substitution, and Ex search addresses now share one Vim-pattern compiler. The Stage 4 layer supports:

- `\\<` and `\\>` word boundaries
- `\\c` and `\\C` case overrides
- `\\v`, `\\m`, `\\M`, and `\\V` magic modes
- Vim grouping, alternation, optional, one-or-more, and counted repetition forms
- Character classes, anchors, and escaped delimiters
- Replacement `&`, `\\0` through `\\9`, `\\r`, `\\n`, slash, and backslash handling
- Previous search and substitution pattern reuse

Invalid patterns now fail deterministically instead of silently changing to literal search.

## Expanded Ex parser and executor

The Ex parser now recognizes unescaped command chaining, search addresses, marks, relative addresses, `%`, `.`, `$`, comma and semicolon ranges, bang modifiers, counts, registers, escaped arguments, and repeat-substitution commands.

Stage 4 execution includes:

- Chained commands using `|`, grouped into one undo transaction
- `:normal` and `:normal!` over ranges
- `:global` and `:vglobal`
- `:sort` with case-insensitive, numeric, and unique flags
- Ranged `:delete`, `:yank`, and `:put` with registers and counts
- `:copy`, `:move`, and ranged `:join`
- `:substitute` with discrete per-match edits and common Vim flags
- `:&` and `:~` repeat substitution
- Search-pattern Ex addresses
- Existing Calcite host-command fallback through `.custom(...)`

Nested Ex execution participates in the owning top-level transaction instead of creating accidental nested undo nodes.

## Visual character and line behavior

Visual selections retain a private directional anchor/caret state while continuing to expose the existing sorted public `VimSelection`. Stage 4 adds endpoint swapping with `o`, directional `gv` restoration, visual replacement paste, visual-range Ex prompts, inclusive character selections, and additional visual delete/change/insert variants that can be represented by the existing API.

True visual-block mode remains intentionally deferred because the frozen public mode and single-range selection model cannot represent it accurately.

## Viewport-aware movement

Calcite supplies the visible UTF-16 range through a Calcite-only SPI. Page and half-page motions use the actual visible line count instead of fixed 20/10-line constants. `H`, `M`, and `L` move relative to the visible top, middle, and bottom lines. Standalone `EditorVim` use retains conservative defaults when no viewport has been supplied.

## Compatibility and stress coverage

The deterministic system-Vim fixture corpus has grown from 50 to 500 cases. It covers the same command families across ten structurally equivalent text variants and is generated with Vim in a controlled non-interactive configuration.

The incremental UTF-16 line-index test now performs 10,000 deterministic randomized replacements containing LF, CR, CRLF, Korean text, emoji, and mixed terminator boundaries. Every incremental state is compared with a fresh full rebuild.

Additional Stage 4 tests cover:

- Undo branching and preferred redo paths
- Resolved-register dot-repeat and macro playback
- Vim regex modes and boundaries
- Discrete substitution edit batches
- Chained Ex history grouping
- Global/vglobal, ranged normal, sort, and search addresses
- Visual endpoint swapping, replacement paste, and visual Ex ranges
- Mapping-wide bounded exact edit batches
- Viewport-relative movement and page counts

## Verification

Run:

```sh
cd EditorServices
swift build --target EditorVim
swift test
swift-format lint --recursive --strict Sources/EditorVim Tests/EditorVimTests
./Scripts/check-vim-api.sh
```

Final validation in the supplied Linux environment:

- 87 package tests passed.
- All 500 committed Vim 9.1 differential fixtures passed.
- The 10,000-edit randomized line-index comparison passed.
- `swift build --target EditorVim` passed.
- Strict `swift-format` lint passed.
- `CalciteEditorSurface.swift` passed Swift parser validation.
- Swift API digester reported no source-breaking changes.
- The generated `EditorVim` symbol graph contains exactly 223 public symbols.

Full AppKit type-checking, IME automation, and Xcode UI tests require macOS with Xcode and are not executable in the supplied Linux environment. The AppKit integration has therefore been parser-validated here and should receive a clean macOS Xcode build before release.
