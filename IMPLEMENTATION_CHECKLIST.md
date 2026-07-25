# Calcite 43-item improvement checklist

This revision implements the requested work as one coordinated editor/workspace system rather than as isolated UI patches.

## Safety, focus, and workspace lifecycle

1. **Startup search focus** — Added a one-shot window focus guard. Search and command fields only take focus after an explicit command or click.
2. **Save before project close/switch** — Project transitions wait for save/shutdown, offer save/discard/cancel, and keep the current workspace open if saving fails.
3. **Multi-window command isolation** — Menu notifications carry the key-window identifier; editor-only commands are routed again to the selected tab.
4. **Recovery durability and visibility** — Recovery entries store byte count and content fingerprints, larger bounded recovery capacity is used, and omitted dirty files are reported in the UI/log.

## Build and run

5. **Single-file output interpolation** — Corrected literal `(stem)`/filename output labels and generated collision-resistant per-file executable paths.
6. **Build before run** — Compiled languages now build first and only run after a successful build; stale or absent executables are not launched.
7. **Language-aware single-file plans** — Added or corrected Swift, Rust, C, C++, Objective-C, Objective-C++, Go, Java, Kotlin, Zig, Python, JavaScript, TypeScript, Lua, Ruby, and PHP handling; headers are not treated as runnable files.
8. **Project build discovery** — Xcode scheme selection is persisted, executable Gradle wrappers and actual Gradle/Make tasks are inspected, and unsupported actions are disabled instead of being advertised.

## Python environments

9. **Real Python build environment** — Detects `.venv`, `venv`, `env`, Poetry/Pipenv-style external environments, Conda, active environments, and a manually selected interpreter.
10. **One Python environment across subsystems** — Build, run, tests, tools, LSP configuration, and the integrated terminal share the selected environment.
11. **Process environment activation** — Sets `PATH`, `VIRTUAL_ENV` or `CONDA_PREFIX`, `CALCITE_PYTHON_INTERPRETER`, `PYTHONNOUSERSITE`, and removes conflicting `PYTHONHOME`.
12. **Environment change handling** — Creating, deleting, changing, or manually selecting an environment reconfigures services and restarts the terminal when its effective environment changes.

## Diagnostics

13. **Language/compiler parser coverage** — Extended parsing for Swift/Clang/GCC, Cargo text and JSON, Java/Kotlin/Gradle/Maven, TypeScript, Go, and Python traceback forms.
14. **Severity accuracy** — Distinguishes fatal error, error, warning, remark, note, and hint without retaining the severity prefix in the displayed message.
15. **Stale LSP diagnostics** — Uses document generations/versions to reject diagnostics that no longer match the edited document.
16. **LSP/build de-duplication** — Merges diagnostics by normalized file, range, message, and severity before publishing Problems counts.
17. **Build diagnostic lifetime** — Editing remaps existing build diagnostics instead of clearing them on every keystroke; they are replaced by the next build result.
18. **Diagnostic ranges** — Uses supplied ranges when available and safely falls back to token/line locations for bad columns, line ends, and Unicode text.

## Files and project monitoring

19. **`.DS_Store` isolation** — `.DS_Store` is hidden by default and has its own display/search setting.
20. **Shared visibility policy** — File tree, quick open, and project search use the same hidden/ignored/build-artifact/`.DS_Store` settings.
21. **Independent file filters** — Hidden files, Git-ignored files, build artifacts, and `.DS_Store` can each be toggled independently.
22. **Efficient file monitoring** — Replaced the constant short-interval full refresh with filesystem events, debounce, and a slow safety refresh; source-content changes no longer invalidate build configuration.

## Editor and Vim state

23. **Breakpoint persistence/remapping** — Breakpoints persist per file, move with edits and renamed files/directories, and are removed with deleted paths.
24. **Vim host command completion** — Connected buffer switching, splits, close/new tab, scrolling, definition, rename, and code actions to real editor operations with failure feedback.
25. **Standalone-file session persistence** — Opening a file stores its parent workspace so relaunch restores the correct context.

## Terminal and appearance

26. **External terminal launch** — Replaced the `ssh://localhost` guess with explicit supported terminal applications and a user-defined command.
27. **Appearance control** — Removed forced dark appearance and added System, Light, and Dark policies across SwiftUI and AppKit window appearance.
28. **App-level regression tests** — Added a `CalciteTests` target with tests for theme separation/precedence, visibility policies, project fingerprints, hidden venv changes, and breakpoint persistence.

## Menus and compact build controls

29. **macOS menu commands** — Added/expanded File, Edit, View, Navigate, Build, Debug, Terminal, Window, and settings commands.
30. **Context-sensitive menu availability** — Focused-scene command state enables actions only for the active window and valid build/debug state.
31. **Compact Build/Run toolbar** — Added small Build, Run, and Stop controls with task selection and current build-state feedback without replacing the existing layout.
32. **Shared command implementation** — Menus, toolbar buttons, Command Palette, shortcuts, and Vim routes call the same command/build controller paths.

## Theme import

33. **VS Code themes** — Supports JSON/JSONC, `include`, TextMate token colors, semantic tokens, workbench/editor/panel/sidebar/terminal colors, extension folders, and VSIX archives.
34. **Vim colorschemes** — Handles `highlight`/`hi`, bang forms, links, GUI/cterm foreground/background/special colors, and style flags.
35. **Neovim Lua themes** — Statically extracts `nvim_set_hl`, `vim.cmd` highlight blocks, links, literal palettes, and nearby required palette/highlight modules without executing Lua.
36. **Theme folder variants** — Discovers VS Code manifests plus Vim/Neovim color and palette/highlight files as separate selectable candidates rather than merging unrelated variants.

## Whole-window themes and light/dark separation

37. **Workbench-wide theme application** — Imported themes can style window, editor, sidebar, tabs, toolbar, panels, inputs, borders, selections, diagnostics, terminal foreground/background, and ANSI colors.
38. **Structured theme model** — Separates syntax, editor surface, workbench, terminal, diagnostics, Git/ANSI-derived values, and source metadata with deterministic fallback colors.
39. **System/light/dark policy** — The app follows the system or stays explicitly light/dark and updates the matching theme slot.
40. **Separate light and dark themes** — Stores independent light/dark profiles and switches between them without overwriting the opposite slot.
41. **Theme appearance hint/override** — Imported themes retain automatic lightness detection plus an editable light/dark classification and can be kept under a fixed app appearance.
42. **Preview, editing, and safe customization** — Theme settings preview editor/workbench colors, expose contrast information and editable profile values, and separate imported baseline metadata from user changes.
43. **Source tracking and safe re-import** — Stores source, selected folder/VSIX variant, and modification time; monitors the selected file, preserves user-modified values during re-import, and keeps the last valid theme on parse failure.

## Validation performed in this environment

- `swift test --package-path EditorServices`: **318 XCTest tests passed**.
- Swift Testing Python environment suite: **6 tests passed**.
- Every Swift source under `Calcite` and `CalciteTests` passed `swiftc -frontend -parse`.
- `Calcite.xcodeproj/project.pbxproj` passed `plutil -lint`.
- `git diff --check` passed.

The current runner is Linux and does not provide AppKit or Xcode, so the macOS application target and `CalciteTests` target could not be linked or launched here. They were source-parsed and the project structure was validated; the package-level backend was fully built and tested.
