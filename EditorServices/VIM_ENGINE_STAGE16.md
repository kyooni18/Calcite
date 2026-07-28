# VimEngine Stage 16 — Engine-Owned State

Stage 16 makes `VimEngine` the authoritative owner of every state that can affect Vim behavior or restoration. AppKit views, Calcite tabs, editor sessions, and `VimKeymapController` are projections and adapters only.

## Ownership model

- Global Vim state remains in the shared engine global storage: registers, histories, mappings, and related process-wide data.
- Buffer state remains associated with the Vim buffer: text, revisions, marks, undo history, and buffer-local behavior.
- Window state is stored by the engine and survives controller or native-surface recreation. It includes mode, cursor/selection, pending notation and operators, prompt state, composition state, mapping queues and timeout work, messages, input source, viewport, and zoom.
- Calcite UI state may mirror an engine snapshot for rendering, but it must never overwrite the engine during tab or surface activation.

## Surface contract

A native editor surface may be created, retained, deactivated, evicted, and recreated without changing Vim semantics. The surface:

1. forwards input and host events to its controller;
2. renders engine snapshots and selections;
3. reports native viewport and input-source changes back to the engine;
4. never owns mapping timeout, prompt, composition, mode, cursor, or pending-command state.

## Coordinator lifecycle

`VimSessionCoordinator` now distinguishes `.activate` from `.retain`. Retaining a controller does not implicitly seed or switch a window's current buffer. Buffer detachment repairs current and alternate buffer relationships explicitly.

## Compatibility

The older `makeCurrent:` controller API remains as a deprecated forwarding overload for source compatibility. New code should use `attachment:`.

## Validation

Stage 16 adds tests covering:

- controller recreation with pending mappings and configuration;
- prompt, composition, message, viewport, and zoom persistence;
- inactive-first retained controller creation;
- buffer detachment and current/alternate repair;
- mapping timeout completion without a native surface owner.
