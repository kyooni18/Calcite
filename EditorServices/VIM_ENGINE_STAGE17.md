# VimEngine Stage 17 — Single Session Core

Stage 17 replaces the coordinator-owned collection of per-buffer engines with one canonical `VimEngine` for each Calcite window session. The coordinator and keymap controller are adapters only; mutable Vim state lives in the engine session graph.

## State graph

The session engine separates state by semantic scope:

- **Global** — registers, macros, mappings, repeat/search state, and command/search history.
- **Buffer** — authoritative text, revision, undo tree, line index, marks, change positions, and buffer-local options.
- **Window** — current buffer, alternate buffer, tab-page identity, and the set of views attached to the window.
- **View (`window × buffer`)** — cursor, mode, selection, pending operator and count, command parser, mapping queue and timeout, command-line/search prompt, IME composition, messages, viewport, zoom, and other restoration state.

A `VimEngineView` contains only a root-engine reference and `VimViewID`. It is a projection, not another state owner.

## Canonical buffer transactions

Every text-changing engine transaction commits to the buffer's authoritative snapshot and increments its revision. The engine then reconciles every sibling view of that buffer in the same locked transaction.

Consequences:

- two windows displaying one buffer receive edits and undo/redo immediately;
- sibling synchronization no longer requires manual `reconcileExternalText` calls;
- marks and change positions are adjusted once at buffer scope;
- external snapshots must provide the current base revision and stale updates are rejected with the canonical snapshot.

## Controller and coordinator roles

`VimSessionCoordinator` owns one root engine and caches one `VimKeymapController` per Vim window. It does not own buffer, window, view, history, cursor, mode, prompt, mapping, or composition state.

`VimKeymapController` translates host input for its `VimWindowID`. Mapping and message timeout work is stored in the originating engine view, so changing buffers or evicting a native surface cannot redirect delayed work to another buffer.

## Lifecycle

All close paths now repair the engine graph before Calcite removes a document:

- ordinary tab close and dirty-close resolution;
- `:bdelete`, `:bunload`, and `:bwipeout`;
- editor-window removal;
- backend-window shutdown;
- documents removed by workspace reconciliation.

Closing a displayed document switches affected windows to a valid fallback when available, detaches retained views in every other window, and then unloads or wipes the buffer according to the command.

## Native surface residency

Calcite Vim keeps only the active native editor surface and two recent inactive surfaces per editor session. Evicted AppKit surfaces are reconstructed from the engine-owned view state. The default non-Vim editor keeps its prior surface-retention behavior because AppKit still owns its undo state.

Inactive Calcite Vim surfaces cannot install handlers, synchronize text, request focus, or publish selection and presentation state through the shared window controller.

## Validation

Stage 17 adds tests covering:

- one session engine and one controller per window;
- independent view state for multiple buffers in one window;
- automatic same-buffer edit and undo propagation across windows;
- revision-checked external snapshots and stale-update rejection;
- detach and window-removal lifecycle repair;
- delayed mapping timeout binding across a buffer switch.

Calcite also includes MRU residency policy tests for a 100-document workload and closed-document pruning.

The complete EditorServices test suite contains 205 tests and passes without failures on Linux. macOS application files are syntax-checked separately because AppKit and Xcode are unavailable in the validation environment.
