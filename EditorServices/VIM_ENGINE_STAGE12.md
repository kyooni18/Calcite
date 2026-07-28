# Vim Engine Stage 12

Stage 12 separates Vim state ownership from Calcite's document-tab presentation model.

## State ownership

- Window-session global state now owns registers, macros, mappings, command/search history, search state, and repeat state.
- Buffer state now owns undo history, lowercase marks, the change list, last inserted text, keyword options, text width, tab width, and authoritative text.
- Each editor window keeps its own cursor, Visual selection, parser interaction, desired column, jump list, and controller instance.
- `VimSessionCoordinator` caches one controller for each `(window, buffer)` pair and assigns stable, non-reused buffer numbers.

## Calcite integration

- A `CalciteBackendWindowSession` owns one Vim coordinator.
- Recreating a SwiftUI editor surface reuses the existing controller.
- Switching a buffer changes the document displayed by the originating editor session without changing that editor window's identity.
- Vim host invocations carry separate buffer, window, tab-page, document URL, selection, and revision identities.
- Host routing validates the actual originating editor and document instead of comparing editor-session and document UUIDs.
- Scrolling, splitting, buffer switching, and close requests are routed to the originating editor window.

## Commands

Stage 12 distinguishes buffer, window, and tab navigation:

- `:ls`, `:buffers`, `:files`
- `:buffer`, `:bnext`, `:bprevious`, `:bfirst`, `:blast`, `:badd`
- `:bdelete`, `:bunload`, `:bwipeout`
- `<C-^>` and `<C-6>` for the alternate buffer
- `<C-W>s`, `<C-W>v`, `<C-W>h/j/k/l`, `<C-W>w/W/p`, `<C-W>q/c/o`
- `:split`, `:vsplit`, `:new`, `:vnew`, `:close`, `:only`, and `:wincmd`
- `:bnext` is no longer routed as tab navigation; `:tabnext`, `gt`, and `gT` remain tab-page requests.

## Persistence

Command and search history is merged from legacy document snapshots into one bounded workspace history. The versioned workspace snapshot is written atomically to:

`Application Support/Calcite/Workspaces/<workspace-id>/vim-state.json`

Document-level history remains readable for migration compatibility.

## Validation

- 179 Swift package tests pass.
- 172 EditorVim tests pass, including six new Stage 12 ownership tests.
- The 720-case system Vim differential corpus continues to pass.
- Strict Swift formatting passes for EditorVim sources and tests.
- The ordinary public EditorVim API remains unchanged.

A native macOS Xcode run is still required to validate AppKit focus, scrolling, and sectional-layout presentation at runtime.
