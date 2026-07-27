# VimEngine Stage 5 Improvements

This revision adds a typed multilingual keyboard and input-method pipeline to the Stage 4 VimEngine while preserving the ordinary public `EditorVim` API. The new host-facing input types are exposed only through Calcite SPI, and Swift API-digester validation reports no source-breaking differences.

## Typed keyboard and text input

`VimKeymapController` no longer relies on notation strings as its runtime input representation. A typed event layer now distinguishes:

- Physical key strokes and canonical US-QWERTY key positions
- Logical text produced by the active keyboard layout
- Committed text from an input method
- Composition start, update, commit, and cancellation
- Mapping timeouts

The existing `handle(token:)` API remains available as a compatibility boundary. Internally, mappings and pending commands use typed tokens, with Vim notation generated only when input reaches the existing parser.

The controller also reports what kind of input the parser expects: a command, literal character, replacement character, register name, mark name, or prompt text. Calcite can therefore send command keys directly to Vim while leaving native text entry and IME candidate handling to AppKit.

## Multilingual command keyboard policies

Calcite now exposes four command-key policies in the editor profile:

- **Automatic:** Normal and Visual commands use canonical physical US-QWERTY positions; Insert, Replace, prompts, and literal arguments use the active input method.
- **Active Keyboard Layout:** Commands use logical characters from the selected layout.
- **Physical US-QWERTY:** Commands always use canonical physical key positions.
- **Language Map:** Logical command characters are translated through a configurable `source=target` map.

The default Automatic policy allows commands such as `h`, `j`, `k`, `l`, `d`, and `x` to continue working while Korean, Japanese, Chinese, Dvorak, Colemak, AZERTY, or another layout is selected. Character arguments for `f`, `F`, `t`, `T`, and `r` remain native Unicode text rather than being converted back to physical command identities.

## AppKit IME composition lifecycle

`CodeEditorTextView` and `CalciteEditorSurface` now coordinate marked text explicitly.

During Insert and Replace composition:

- Native marked text remains a visual pre-edit state.
- Pre-edit mutations are not published to the Calcite document model.
- VimEngine history, macros, registers, and repeat state are not updated until commit.
- The original document and selection are restored before the final composed string is applied through VimEngine.
- A completed composition is inserted as one payload and one undo transaction.
- Replace mode replaces by grapheme count rather than UTF-16 code-unit count.

Search and command prompts, as well as Unicode character arguments, use a virtual composition path so marked text does not leak into the editor document. Escape explicitly discards the active AppKit marked-text session first; a subsequent Escape performs the ordinary Vim prompt or mode transition.

Candidate navigation, conversion, deletion, and other composition keys remain under the native input method while marked text is active.

## Unicode display-column movement

Vertical movement now retains a deterministic display column rather than a Swift `Character` count. The fallback display-width model handles:

- Configurable tab stops
- Zero-width combining and formatting scalars
- Double-width Hangul, CJK, full-width characters, and emoji
- Extended grapheme cluster boundaries

The core engine continues to use UTF-16 offsets at its host boundary but normalizes operations to valid grapheme boundaries. Calcite can still use AppKit geometry for proportional rendering; the new model provides stable platform-independent Vim movement and tests.

## Stage 4 capabilities retained

The Stage 4 undo tree, semantic dot-repeat and macro storage, exact edit batches, Vim regex compatibility, expanded Ex execution, directional Visual behavior, viewport-aware movement, 500 differential fixtures, and 10,000-edit randomized line-index stress test remain intact.

True Visual Block mode and public mapping-option types remain deferred because adding them to the frozen public mode and mapping models would be source-breaking. Recursive/non-recursive mapping metadata and `nowait` can be added later through a separately versioned API without weakening the Stage 5 input architecture.

## Stage 5 coverage

The focused multilingual suite covers:

- Physical commands with Korean logical key output
- Logical-layout command policy
- User language-map translation
- Physical multi-key mappings under non-Latin layouts
- Korean composition for Insert and Replace modes
- Unicode `f` and `r` arguments
- Two-step Escape behavior during prompt composition
- One-transaction composed insertion and undo
- CJK display columns and tab-stop preservation

## Verification

Run:

```sh
cd EditorServices
swift build --target EditorVim
swift test
swift-format lint --recursive --strict Sources/EditorVim Tests/EditorVimTests
./Scripts/check-vim-api.sh
```

Final validation in the supplied Linux environment:

- 98 package tests passed with no failures.
- All 500 committed Vim 9.1 differential fixtures passed.
- The 10,000-edit randomized line-index comparison passed.
- `swift build --target EditorVim` passed.
- Strict `swift-format` lint passed for the complete VimEngine source and test trees.
- The modified Calcite AppKit and settings sources passed Swift parser validation.
- Swift API digester reported no ordinary public API changes.
- The generated ordinary `EditorVim` API remains at the Stage 4 baseline.

Full AppKit type-checking, installed-input-source automation, and Xcode UI tests require macOS with Xcode and cannot run in the supplied Linux environment. The Calcite integration should receive a clean macOS Xcode build and manual Korean, Japanese, Simplified Chinese, Traditional Chinese, and alternate-Latin-layout smoke test before release.
