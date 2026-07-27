# VimEngine Stage 6 — Adaptive Status and Trustworthy Input UX

Stage 6 makes Calcite's status surface respond to the active editor interaction instead of treating Vim as a fixed badge added to the standard IDE status bar. It also exposes enough structured Vim state for Calcite to explain pending commands, command-line editing, mappings, composition, and failures without relying on a beep or debug log.

## Implemented

### Adaptive editor status

`CalciteEditorStatusCoordinator` selects one of these presentations:

- Standard Calcite editor status when Calcite Vim is disabled
- Normal status with pending notation, register/count/operator prefixes, macro recording, and temporary Normal state
- Insert status with input source, IME composition, snippet progress, and completion progress
- Replace status with input source, composition, and overwrite feedback
- Visual Character and Visual Line status with selection size
- Command/Search status with a visible caret and marked IME text
- Transient Vim messages with severity and Vim-style error codes

The presentation priority is command line, visible error/message, mode-specific state, then standard editor state.

### Structured Vim interaction state

`VimKeymapController` now publishes an SPI-only `VimInteractionSnapshot` containing:

- Current mode
- Pending notation and expected input type
- Count, register, operator, prefix, and mapping-prefix state
- Command/search text, caret offset, marked text, marked selection, and history position
- Macro recording and last-played register
- Temporary Normal and composition state
- Command/search history
- Current visible message

The existing public VimEngine API remains unchanged.

### Command and search editing

The command/search session now supports:

- Visible caret at the actual internal cursor position
- Native IME marked text and committed text
- Left, Right, Home, End
- Option-Left and Option-Right word movement
- Backspace, Delete, Control-W, and Control-U
- Prefix-aware Up/Down history navigation
- Separate command and search history
- Escape cancellation and Enter execution

History is persisted per document and limited to the latest 200 commands and 200 searches.

### User-visible messages

The engine/controller reports structured messages instead of silently failing. Implemented cases include:

- `E492` unknown Ex command
- `E486` pattern not found
- `E54` invalid search pattern
- `E20` mark not set
- Invalid count/register/notation errors from the Calcite adapter
- Mapping timeout
- Mapping or macro recursion limit

Unknown Ex commands are no longer forwarded automatically as unrestricted custom host actions. Explicit `<host:...>` mappings remain supported.

### Mapping v2 foundation

Stage 6 adds an SPI-only mapping model with:

- Normal, Insert, Replace, Visual, Operator-pending, and Command-line modes
- Recursive and non-recursive mappings
- `nowait`
- Configurable mapping timeout from 0 to 5,000 ms
- Conflict diagnostics scoped by mode and input domain
- Separate physical/command-key and committed/logical-text mapping domains
- Insert and command-line mappings driven by committed multilingual text

The legacy `VimKeyMapping(sequence:command:)` API is preserved and adapted internally.

### Calcite integration extraction

The following responsibilities were moved out of the main editor surface:

- `CalciteVimInputAdapter`: AppKit key events and physical US-QWERTY positions
- `CalciteVimConfigurationAdapter`: mapping, keyboard policy, language map, and configuration signatures
- `CalciteVimMessagePresenter`: user-facing error conversion
- `CalciteEditorStatusBar`: adaptive status coordination and rendering

The remaining editor coordinator continues to own AppKit lifecycle and document presentation synchronization.

## Validation

- 105 EditorVim tests pass
- 14 Stage 6 focused UX tests pass
- Existing deterministic Vim differential fixtures pass
- Existing Stage 3, Stage 4, and Stage 5 regression tests pass
- EditorVim builds successfully with Swift 6.2.1 on Linux
- Strict `swift-format` validation passes for every modified Swift source
- Public EditorVim API compatibility check passes against `API/EditorVim.api.json`
- Modified Calcite/AppKit sources pass Swift parser validation

A full Xcode/AppKit type-check and installed-input-method UI run requires macOS and is not available in the Linux validation environment.

## Deliberately deferred

The following changes remain separate because they require larger API or editor-model work:

- Visual Block mode and multiple-selection rendering
- Full command-line completion popup and command-line window
- Live search cursor preview and match highlighting while typing
- Full parser-state replacement of the legacy pending flags
- Host capability/result negotiation for split, tab, LSP, and build actions
- Persisted registers, marks, and last-search state
- `:registers`, `:marks`, `:jumps`, `:changes`, and mapping-list output panels
- Full extraction of document synchronization, cursor presentation, and host routing from the AppKit coordinator
- Expression and buffer-local mappings

These are suitable for Stage 7 after the adaptive status and interaction snapshot have been exercised in the macOS app.
