# Vim Engine Stage 13

Stage 13 routes Vim window semantics through Calcite's persisted Section Layout instead of
creating a second Vim-owned split tree.

## Section Layout ownership

- `:split`, `:vsplit`, `<C-W>s`, and `<C-W>v` split the originating Calcite editor section.
- The originating editor tab is resolved back to its Section Layout leaf before mutation, so stale
  global focus cannot split a different section.
- The new Section Layout leaf and editor-host tab are created in one transaction.
- A duplicated `EditorSession` is bound to the new editor-host tab immediately instead of waiting
  for SwiftUI reconciliation.
- Split direction, divider geometry, layout undo/redo, and persistence remain owned by
  `MainSectionalLayoutController`.

## Window navigation

- `<C-W>h/j/k/l` follows the recursive Section Layout topology.
- `<C-W>w/W` cycles only through visible editor-host sections.
- Terminal, Problems, Symbols, Build Output, Settings, and other utility-only sections do not count
  as Vim windows.
- Entering a section through Vim navigation selects its editor-host tab before activating its
  editor session.
- `<C-W>p` returns to the previously active editor session rather than approximating it with reverse
  section traversal.
- `:wincmd s`, `:wincmd v`, and `:wincmd n` use the same Section Layout routing.

## Split targets and lifecycle

- `:split file`, `:vsplit file`, `:new file`, and `:vnew file` open the requested file in the newly
  created editor section while leaving the originating editor on its previous buffer.
- `:close` removes only the originating editor presentation. The document buffer remains open.
- If an editor host shares a section with utility tabs, closing the Vim window removes only the
  editor-host tab and preserves the utility tabs.
- `:only` removes other editor presentations while preserving utility-only sections.
- Closing the final Vim editor window follows Calcite's normal window-close path and retains dirty
  buffer protection.
- `:tabclose` follows Calcite's integrated document-tab model and no longer removes an entire
  Section Layout leaf.

## Validation

- 182 Swift package tests pass, including three new Stage 13 routing tests.
- The existing 720-case Vim differential fixture suite continues to pass as part of the package
  test run.
- Strict Swift formatting passes for all EditorVim sources and tests.
- The Section Layout source type-checks independently, and nested directional topology was exercised
  with a standalone runtime harness.
- Four native Calcite unit tests were added for editor-window filtering, nested direction routing,
  split identity creation, and utility-section exclusion. They require Xcode/macOS to run.

## Remaining platform work

Calcite still has a file-backed `EditorTab` model, so empty `:new` and `:vnew` currently duplicate the
current buffer rather than creating a true unnamed Vim buffer. A native macOS Xcode run is also still
required to validate AppKit focus transfer and divider presentation.
