# VimEngine Stage 11

Stage 11 replaces the notation executor's independent pending flags and command-specific operator branches with one pure parser state machine and one semantic command representation.

## Parser architecture

- `VimCommandParser` owns one `VimParserState` value.
- Token consumption returns either a new incomplete state, cancellation, or a complete `VimSemanticCommand`.
- Parsing does not read or mutate document text.
- Escape atomically cancels incomplete register, operator, `g`, find, search, mark, text-object, replace, and macro sequences.
- Counts use saturating arithmetic and operator/motion counts are multiplied once.
- Insert-mode `<C-O>` waits for one complete semantic command rather than one token.

## Unified semantic execution

The same `VimSemanticCommand` values are used for immediate execution, macro recording, dot repeat, and undo grouping. Normal, Visual, and operator-pending commands share `VimMotionExpression` and `VimMotionResult`.

Text objects are motion expressions with explicit ranges. Linewise repeated operators such as `dd`, `cc`, `gUU`, and `g??` also use the common operator path.

The public `VimAction` and `VimMotion` API remains unchanged and adapts into the internal semantic evaluator.

## Motion and operator additions

- Viewport motions `H`, `M`, and `L`, including operator combinations.
- Last non-blank motion `g_`.
- Word searches `*`, `#`, `g*`, and `g#`, including operators.
- Search-match selections `gn` and `gN`, including `dgn` and Visual use.
- `%` scans the current line for the first delimiter before matching.
- Counted `%` performs percentage line jumps.
- Visual and operator text objects use the same parser and evaluator.

## Fidelity corrections discovered by differential testing

- Backward `F` and reverse-repeat `,` operator ranges now preserve Vim's deleted register contents and cursor position.
- Forced characterwise multiline deletion applies Vim's column-zero cursor placement rule.
- Failed or cancelled motions do not alter text, registers, undo history, jump history, macro contents, or dot repeat.
- Normal `/` and `?` still open Calcite's command-line prompt, while operator search and `g?` remain inside the semantic parser.

## Validation

- 173 complete Swift package tests pass.
- 166 EditorVim tests pass.
- 720 deterministic fixtures generated from system Vim pass.
- Debug and release builds of the EditorVim target pass.
- Strict `swift-format` lint passes for all changed Swift files.
- The public EditorVim API compatibility report is empty.

A final macOS Xcode/AppKit runtime check is still required for native event routing and visual presentation because the package validation environment is Linux.
