# VimEngine Stage 7 — Visual Block and Selection Architecture

Stage 7 adds a versioned, Calcite-facing selection model and a first complete Visual Block editing path without adding a source-breaking case to the public `VimMode` enum. Calcite projects block selections into multiple AppKit ranges and adapts the status bar to block selection and block insertion.

## Implemented

### Extended selection model

The SPI-only selection model exposes:

- Characterwise, linewise, and blockwise selection shapes
- Anchor and active endpoints with UTF-16 offsets, one-based lines, and virtual columns
- Per-line projected UTF-16 ranges for native multiple-selection rendering
- Visual snapshots with width, height, character count, line count, and virtual-column range
- Block insertion and append state during Insert mode

The existing public `VimState.selection` and `VimMode` API remain source-compatible. Visual Block continues to use the existing visual mode internally while the extended shape is exposed through `VimSelectionSet` and `VimInteractionSnapshot`.

### Visual Block entry and movement

`Ctrl-V` enters Visual Block mode. Existing Normal/Visual motions update the rectangular selection, including:

- `h`, `j`, `k`, `l` and arrow-key equivalents
- Counts
- `0`, `^`, `$`, `gg`, and `G` through the existing motion evaluator
- Reversed anchor/caret direction
- `o`/`O` endpoint swapping
- Switching between `v`, `V`, and `Ctrl-V`

Block projection uses virtual display columns and keeps every projected range on a grapheme boundary.

### Block operations

Implemented blockwise operations include:

- Delete: `d`, `x`, `D`, `X`
- Change/substitute: `c`, `C`, `S`, `s`
- Yank: `y`
- Replace: `r{character}`
- Insert before: `I`
- Append after: `A`
- Paste: `p`, `P`
- Indent/outdent: `>`, `<`
- Uppercase/lowercase/swap case: `U`, `u`, `~`

Blockwise registers preserve row boundaries and the selected virtual width. Normal-mode block paste creates missing lines when required and pads short lines to the target virtual column.

### IME-safe block insertion

`I`, `A`, and block change edit the primary line through the normal Calcite/AppKit text-input path. Marked Korean, Japanese, or Chinese pre-edit text is not replicated. Only the final committed insertion is copied to the remaining block lines when Insert mode ends.

The complete replicated edit is one Vim undo transaction.

### Repeat, macros, and undo

Stage 7 records block edits semantically rather than storing absolute ranges.

- `.` repeats block delete, insert, append, replace, and supported block operators relative to the new cursor position.
- Macro recording and playback retain Visual Block entry, movement, and operations.
- Every multi-line block mutation is committed as one undo entry.
- Blockwise register content survives yanking and later paste operations.

### Calcite multiple-selection presentation

`CalciteVimSelectionPresenter` converts projected Vim ranges into native AppKit `selectedRanges` values. The active line is chosen as the primary selection even when the block is reversed or contains zero-length ranges on ragged lines.

The legacy single-range selection projection remains as a fallback for non-block selections.

### Adaptive status bar

The Stage 6 status system now displays:

- `V-BLOCK | height × width | Col start–end`
- `V-BLOCK INSERT | N lines`
- `V-BLOCK APPEND | N lines`
- Native input-source and IME composition state during block insertion

### Unicode and ragged-line behavior

The deterministic core projection covers:

- Tabs using the configured tab width
- Hangul and CJK wide characters
- Combining sequences
- Emoji and extended grapheme clusters
- Empty and short lines
- Blocks extending beyond a line's content
- Block paste with virtual-column padding

## Validation

- 122 EditorVim tests pass
- 129 total EditorServices package tests pass
- 17 Stage 7 Visual Block tests pass
- Existing Stage 3–6 regression tests pass
- Deterministic Vim differential fixtures pass
- Public EditorVim API compatibility check passes against `API/EditorVim.api.json`
- Strict `swift-format` validation passes for modified Swift sources
- Modified Calcite/AppKit sources pass Swift parser validation

The Stage 7 tests cover block projection, ragged lines, tabs/CJK columns, Hangul IME commit replication, emoji replacement, blockwise registers and paste, missing-line creation, undo, dot-repeat, macro playback, substitute, and status snapshots.

## Environment limitation

The validation environment is Linux. A full Xcode/AppKit type-check, TextKit multiple-selection rendering test, accessibility test, and installed Korean/Japanese/Chinese IME UI run require macOS and were not available here. The modified AppKit sources were syntax-parsed, but final macOS integration validation remains necessary.

## Deliberately deferred

The following parts of the broader Stage 7 design remain for a macOS integration follow-up or Stage 8:

- Full extraction of the Vim coordinator, cursor presenter, document synchronizer, and host router from `CalciteEditorSurface`
- Revision-tagged exact external-edit reconciliation for formatter, LSP, file reload, and collaboration edits
- Host capability/result negotiation for split, tab, build, and LSP requests
- TextKit-backed proportional-font and soft-wrap visual geometry provider
- Virtual-space insertion matching every Vim edge case for tabs and short lines
- Block formatting (`gq`) and full Vim-compatible block put corner cases
- Native accessibility descriptions for every secondary selection range
- Command-line completion, command-line window, live search preview, and broader Ex compatibility

The current deterministic virtual-column fallback is suitable for Calcite's monospaced editor path. Host-provided visual geometry should be implemented before proportional-font or soft-wrapped Visual Block behavior is considered complete.
