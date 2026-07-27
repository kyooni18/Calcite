<<<<<<< HEAD
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
=======
# VimEngine Stage 3 Improvements

This revision completes the first Stage 3 milestone while preserving the existing public `EditorVim` API. The API digester baseline remains unchanged and the generated module symbol graph still contains 223 public symbols.

## Internal architecture

`VimEngine.swift` is now a 443-line public facade. Editing behavior is separated into focused internal modules for actions, notation parsing, motions, mutations, Ex commands, text objects, buffer utilities, mappings, history, and line indexing.

The split is implementation-only. Existing public types, enum cases, initializers, properties, methods, conformances, and default arguments remain source-compatible.

## Persistent command parser

Direct notation and interactive key handling now share one persistent parser state. It retains counts, register prefixes, pending operators, text objects, `g` prefixes, find/till commands, marks, jumps, macros, replace commands, and temporary insert-mode normal commands.

This removes the former duplicate incomplete-command logic and prevents controllers from reparsing the complete pending notation string after every key.

## Ordered edit transactions

Undo records now contain ordered `VimEditDelta` values rather than reducing every command to one broad text replacement. Multi-line indentation and Ex move operations retain their discrete edits while remaining one Vim undo unit.

All text mutations pass through one replacement path that records the edit, updates stored positions, and incrementally updates the line index. Forward and reverse transaction application validate the expected removed text before changing the document.

## Incremental line index

The UTF-16 line index updates only the affected line region and shifts the untouched suffix. It handles LF, CR, CRLF, trailing logical lines, Unicode replacement boundaries, and terminator edits at scan edges.

A deterministic randomized test performs 500 replacements containing LF, CR, CRLF, Korean text, and emoji, comparing the incremental index with a fresh full rebuild after every edit.

## Structured motion evaluation

Motions now produce an internal `VimMotionResult` containing the destination, motion kind, inclusivity, line-crossing state, and desired column. Normal movement and operator-range evaluation share this pure evaluator, so calculating an operator range no longer moves and restores the live cursor.

Compatibility corrections made while validating the evaluator include:

- Counted `e` movement
- `G` on files ending with a line terminator
- `dgg`
- Linewise-delete cursor placement
- Counted `J`
- `~` cursor advancement
- Indent and outdent cursor placement

## Differential compatibility suite

`Scripts/generate-vim-differential-fixtures.py` generates committed fixtures with system Vim using deterministic non-interactive commands. The current fixture set contains 50 cases covering motions, counts, operators, indentation, joins, find/till repetition, and visual deletion.

The normal test run reads the committed fixtures and does not require Vim to be installed. Vim is needed only when regenerating them.
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883

## Verification

Run:

```sh
cd EditorServices
<<<<<<< HEAD
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
=======
swift test
swift-format lint --recursive --strict Sources/EditorVim Tests/EditorVimTests Package.swift
./Scripts/check-vim-api.sh
```

Final validation in the supplied environment:

- 74 package tests passed.
- 67 tests cover `EditorVim`, its controller/session integration, Stage 3 architecture, and differential fixtures.
- All 50 generated Vim 9.1 compatibility fixtures passed.
- `swift build --target EditorVim` passed.
- Strict Swift formatting lint passed.
- Swift API digester reported no source-breaking changes.
- The generated `EditorVim` symbol graph contains exactly 223 public symbols.
- `VimEngine.swift` was reduced from approximately 3,391 lines to 443 lines.

The API baseline in `API/EditorVim.api.json` was generated before Stage 2 and remains the compatibility guard for this revision.
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
