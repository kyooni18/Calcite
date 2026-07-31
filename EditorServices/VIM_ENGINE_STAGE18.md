# VimEngine Stage 18

Stage 18 removes nondeterministic window-buffer fallback and begins replacing stringly typed Vim topology commands with typed host requests.

## Implemented

- Added typed window topology requests:
  - `focusWindow(direction:count:)`
  - `cycleWindow(direction:count:)`
  - `focusPreviousWindow`
  - `closeOtherWindows`
  - `newWindow(horizontal:)`
- Updated `Ctrl-W` parsing and `:only` / `:new` / `:vnew` execution to emit typed requests.
- Preserved Calcite compatibility by translating typed requests at the host boundary into the existing sectional-layout routing commands.
- Added per-window buffer MRU state.
- Buffer detachment now chooses a deterministic replacement in this order:
  1. valid alternate buffer
  2. most-recently-used attached buffer
  3. first attached buffer in canonical session buffer order
  4. no current buffer
- Removed detached buffers from alternate and MRU state.
- Removed AppleDouble and Finder metadata from the delivered archive.

## Verification

`swift test --package-path EditorServices`

- 213 tests executed
- 0 failures
