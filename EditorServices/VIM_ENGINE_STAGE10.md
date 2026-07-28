# EditorVim Stage 10

Stage 10 consolidates motion parsing and operator semantics around an internal parsed-motion model while preserving the public EditorVim API.

## Implemented

- Operator-compatible `W`, `B`, `E`, `ge`, and `gE` motions.
- Operator-compatible `f`, `t`, `F`, `T`, `;`, and `,` motions.
- Sentence and paragraph motions with operators: `(`, `)`, `{`, and `}`.
- Characterwise and linewise mark motions through backtick and apostrophe.
- Search motions in operator-pending mode, including `n` and `N`.
- Forced characterwise, linewise, and blockwise operator forms through `v`, `V`, and `<C-V>`.
- Real pending operators for `gU`, `gu`, `g~`, `g?`, and `gq`.
- Text reflow for `gq`, including `textwidth`/`tw` handling and line-terminator preservation.
- Centralized operator-range resolution, including exclusive column-zero conversion and failed-motion no-ops.
- Count multiplication with saturating arithmetic.
- Configurable minimal `iskeyword` support for word motions and text objects.
- Counted and nested text objects, including Visual text-object direction preservation.
- Semantic dot-repeat and macro playback for the new parsed commands.
- Single motion evaluation per operator command.

## Validation

- `swift test`: 162 tests passed.
- EditorVim-specific tests: 155 tests passed.
- `swift-format lint --strict`: passed for all Stage 10 files.
- `Scripts/check-vim-api.sh`: no public API changes.

The macOS Calcite application still requires a final Xcode runtime smoke test for AppKit event routing and editor presentation because the package validation was performed in a Linux Swift environment.
