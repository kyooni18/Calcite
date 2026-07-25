# Source Workspace

Store and manage the complete source tree, including files that are not currently open in an editor.

## Overview

``SwiftEditorBackend`` owns a ``SourceWorkspace`` actor for the same root used by Tree-sitter, SourceKit-LSP, and DAP. The workspace stores immutable ``SourceCodeFile`` snapshots containing complete content, stable identity, file name, relative and absolute path, language, version, UTF-8 BOM policy, line ending, disk fingerprint, and synchronization state.

Construction scans by default:

```swift
let backend = try await SwiftEditorBackend.makeSwift(workspaceURL: workspaceURL)
let snapshot = await backend.sourceWorkspaceSnapshot()
```

Use `snapshot.tree` to populate a navigator and `snapshot.files` for complete file data.

## Stable file handles

A ``SwiftSourceFileSession`` follows a ``SourceFileID`` across file moves:

```swift
let source = try await backend.sourceFileSession(at: "Sources/App.swift")
let before = try await source.file()
_ = try await source.move(to: "Sources/Application.swift")
let after = try await source.file()
precondition(before.id == after.id)
```

## Atomic source changes

Open and closed files use the same transaction engine:

```swift
try await backend.setSourceFileContentsAtomically([
    SourceFileContentUpdate(
        fileID: first.id,
        content: firstText,
        expectedVersion: first.version
    ),
    SourceFileContentUpdate(
        fileID: second.id,
        content: secondText,
        expectedVersion: second.version
    ),
])
```

The complete operation is validated before mutation. Any stale version, invalid range, unknown ID, or size violation prevents all files from changing.

## Search and replace

```swift
let preview = try await backend.previewSourceReplacement(
    .literal("OldName"),
    with: "NewName",
    options: .init(wholeWord: true, includedFileExtensions: ["swift"])
)
let changed = try await backend.applySourceReplacement(preview)
```

The preview retains each source version. A later edit makes the preview stale and rejects the entire replacement.

## Disk conflicts

Scanning or monitoring compares memory with the last disk fingerprint:

- ``SourceFileState/clean``: memory and disk match.
- ``SourceFileState/modified``: memory changed.
- ``SourceFileState/created``: memory-only file.
- ``SourceFileState/conflicted``: memory and disk both changed.
- ``SourceFileState/missing``: disk file disappeared while memory is retained.

Resolve conflicts explicitly with ``SourceWorkspaceConflictResolution/useMemory`` or ``SourceWorkspaceConflictResolution/useDisk``.

## Portable archives

``SourceWorkspaceArchive`` stores every complete source and relative path without retaining the original absolute root or disk fingerprint:

```swift
let data = try await backend.encodedSourceWorkspaceArchive()
let report = try await backend.restoreSourceWorkspace(
    from: data,
    policy: .replace,
    mode: .reconcileWithDisk,
    closeOpenDocuments: true
)
```

Restore validates the complete archive before committing in-memory state and never writes imported files implicitly.

## Topics

### Files and Navigation

- ``SourceWorkspace``
- ``SourceCodeFile``
- ``SourceFileID``
- ``SourceCodeFileSummary``
- ``SourceWorkspaceSnapshot``
- ``SourceWorkspaceNode``
- ``SwiftSourceFileSession``

### State and Persistence

- ``SourceFileState``
- ``SourceTextEncoding``
- ``SourceLineEnding``
- ``SourceDiskFingerprint``
- ``SourceWorkspaceConflictResolution``
- ``SourceWorkspaceEvent``

### Project Operations

- ``SourceFileContentUpdate``
- ``SourceFileEditBatch``
- ``SourceSearchPattern``
- ``SourceSearchOptions``
- ``SourceSearchMatch``
- ``SourceReplacementPreview``
- ``SourceWorkspaceMetrics``

### Backup and Restore

- ``SourceWorkspaceArchive``
- ``SourceWorkspaceArchiveFile``
- ``SourceWorkspaceRestorePolicy``
- ``SourceWorkspaceRestoreMode``
- ``SourceWorkspaceRestoreReport``
