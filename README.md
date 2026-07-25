# Calcite

A native macOS code editor built with SwiftUI, AppKit, and the local `EditorServices` package.

## Included

- Multi-language editing, syntax highlighting, completion, diagnostics, formatting, and navigation
- SourceKit-LSP and configurable external language servers
- LLDB Debug Adapter Protocol integration
- Vim and GUI editing modes
- Project search, file management, build/run tasks, and a PTY-backed terminal
- VS Code and Neovim theme import
- Read-only indexing of project dependencies and external libraries, including nested package workspaces

## Build

Open `Calcite.xcodeproj` in Xcode on macOS 15.6 or newer. The project uses the vendored local package at `EditorServices/`, so package resolution does not require network access.

Cargo, Rustup, Homebrew, mise, asdf, Swiftly, and user-local executables are resolved even when Calcite is launched from Finder with a minimal `PATH`. Terminal sessions also preserve their last PTY dimensions across panel detach, restart, and re-entry.

## EditorServices

Public integration notes and configuration are in [`EditorServices/README.md`](EditorServices/README.md). Third-party credits and licenses are listed in [`EditorServices/THIRD_PARTY_NOTICES.md`](EditorServices/THIRD_PARTY_NOTICES.md).
