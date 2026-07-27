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

## Verification

Run:

```sh
cd EditorServices
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
