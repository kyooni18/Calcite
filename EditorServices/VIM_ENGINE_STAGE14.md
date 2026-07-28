# Vim Engine Stage 14 — Surface Lifecycle and Pointer Synchronization

Stage 14 makes the cached `(window, buffer)` Vim controller authoritative across document handoffs and separates native cursor movement from document synchronization. Native AppKit editor surfaces now remain stable for the lifetime of an editor session instead of being recreated for every tab.

## Implemented behavior

- Reattaching an AppKit editor surface restores the cached Vim cursor, mode, Visual selection, and transient interaction state instead of importing the new `NSTextView` selection.
- Reapplying an unchanged Vim profile is idempotent. Pending operators, counts, mapping prefixes, registers, and command/search prompts are not cleared merely because SwiftUI recreated its coordinator.
- Native pointer selection is reported after `NSTextView.mouseDown(with:)` completes. Plain clicks also retain the physical hit-tested insertion offset from `characterIndexForInsertion(at:)`, so a synchronous selection-presentation echo cannot replace the click with the previous Vim cursor.
- The AppKit coordinator preserves the explicit pointer range through selection-origin routing and passes that range directly to the Vim controller. It no longer accepts a click range and then discards it by rereading `NSTextView.selectedRange()`.
- Host cursor movement uses `acceptHostCursorMove(toUTF16Offset:source:)` and no longer routes through full text synchronization.
- Pointer movement preserves Insert and Replace modes, leaves Visual mode predictably, cancels pending parser/prompt state, and keeps undo history untouched.
- UTF-16 cursor positions are normalized for grapheme boundaries, empty lines, line endings, and EOF.
- `EditorTab.selectedRange` no longer overwrites a Calcite Vim editor session during tab restoration.
- Document switching is now a single window-session transaction: the outgoing selection is captured from the live Vim controller, the document changes, and the incoming selection is restored from the cached controller before activation.
- Re-activating the same editor session no longer reads the new document as though it were the outgoing editor, which was the remaining state-loss path after the initial Stage 14 surface fix.
- Native `NSTextView` identity is stable across built-in/Calcite Vim document switches. Only terminal-backed editor surfaces remain document-bound.
- A document/controller binding transition suppresses selection delegates until the incoming cached Vim state has been restored.
- Deferred SwiftUI publications are generation-scoped and cancelled at a document boundary, so an outgoing tab cannot publish its selection into the incoming tab.
- The tab-boundary handoff reconciles a collapsed AppKit selection into Normal/Insert/Replace controllers before detaching. This closes the exact case where the status bar moved but a coalesced native callback left the cached Vim cursor behind.

## Main integration points

- `VimHostCursorMovement.swift`: platform-neutral host cursor movement policy.
- `VimKeymapController.applyConfiguration(...)`: controller-owned configuration signature and idempotent application.
- `CodeEditorTextView.nativePointerSelectionHandler`: post-hit-test pointer callback.
- `CodeTextEditor.Coordinator`: explicit document/controller binding lifecycle, selection-origin routing, and generation-scoped deferred publications.
- `VimSessionCoordinator.existingController(...)`: non-mutating access to cached window-buffer state during a document handoff.
- `CalciteBackendWindowSession.switchDocument(in:to:)`: authoritative outgoing capture, tab-boundary native-cursor reconciliation, and incoming restoration across every tab-selection route.
- `VimStage14SurfaceLifecycleTests.swift`: tab restoration, mapping/operator persistence, click behavior, mode policy, Unicode boundaries, and independent-window regression coverage.
- `CalciteVimStateRestorationTests.swift`: macOS integration regressions for A → B → A restoration, coalesced AppKit cursor publication, and the first Vim command after restoration.
- `CodeEditorTextViewPointerSelectionTests.swift`: macOS regression coverage for stale native-selection echoes during plain clicks.

## Validation

- All EditorServices tests pass: 193 tests, 0 failures.
- Stage 14 lifecycle tests pass: 10 tests, 0 failures.
- `EditorVim` production target builds successfully.
- Modified Swift sources pass strict `swift-format` lint.
- macOS integration sources pass Swift parser validation in the available environment.
