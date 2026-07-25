# Calcite focused-command and workspace-tab refactor

## Completed scope

### Phase 1 — Startup and lifecycle stability
- Removed the catch-all `NotificationCenter.default.publisher(for: nil)` subscription.
- Unified workspace startup into one ordered lifecycle coordinator.
- Controller startup completes before the initial document is opened.
- Startup and shutdown are serialized so they cannot run over each other.
- Added idempotent terminal startup through `startIfNeeded()`.

### Phase 2 — Typed command layer
- Added `EditorCommand` and `AppCommand`.
- Added focused handlers for the active window using SwiftUI `FocusedValues`.
- Routed menu bar, toolbar, command palette, sidebar, and Vim commands through the same executor.
- Removed the user-command `Notification.Name` constants, window-number filtering, and tab notification router.
- Retained `NotificationCenter` only for genuine AppKit/text-system and window-layout notifications.

### Phase 3 — Unified workspace tabs
- Added `WorkspaceTabController` and `WorkspaceTabID`.
- Documents, Settings, and Theme Builder are handled as tabs in one detail area.
- Settings and Theme Builder are singleton tabs.
- Utility-tab state is restored per workspace without persisting stale document UUIDs.
- Document selection remains synchronized with `EditorWorkspaceController`.

### Phase 4 — Detail-area reconstruction
- Moved the tab bar above the selected detail content.
- Reduced `EditorWorkspaceDetail` to document editing and split-pane responsibilities.
- Replaced the Settings sheet with a Settings tab.
- Added a Theme Builder tab with dirty-state, keep, revert, and close confirmation behavior.

### Phase 5 — State and responsibility cleanup
- Reduced `MainView.swift` to dependency construction and root composition.
- Split layout, presentation, actions, command availability, and palette construction into focused files.
- Added `EditorCommandExecutor`, `CommandPaletteState`, and `FileVisibilitySettings`.
- Consolidated bottom-panel behavior and typed editor-tab/layout events.
- Made `Command-S` context-aware for document and Theme Builder tabs.
- Removed duplicate and unused MainView notification/view code.

### Phase 6 — Regression coverage and audit
- Added tests for singleton utility tabs, per-workspace persistence, selection reconciliation, independent file-visibility settings, and typed focused handlers.
- Re-ran all EditorServices tests: 318 XCTest tests passed.
- Re-ran Python environment tests: 6 tests passed.
- Parsed every Calcite and CalciteTests Swift source file successfully.
- Type-checked the new Foundation/Combine state and lifecycle components under Swift 6 MainActor default isolation using isolated stubs.
- `swift-format lint` passed for all new and fully rewritten files.
- `git diff --check` passed.
- `Calcite.xcodeproj/project.pbxproj` passed `plutil -lint`.
- Verified no user-command NotificationCenter routers or catch-all subscriptions remain.

## Platform validation note

The current execution environment is Linux and does not contain AppKit, SwiftUI for macOS, the macOS SDK, or Xcode. The macOS application target and CalciteTests target therefore cannot be linked or executed here. The source tree was audited for cross-file access, Swift 6 MainActor isolation, syntax, project inclusion, and command-route completeness; the platform-independent EditorServices package was fully built and tested.
