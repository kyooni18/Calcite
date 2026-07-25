# Workspace Edits

Apply multi-document rename and code-action text edits as one recoverable operation.

## Apply an edit

```swift
if let edit = try await backend.rename(in: file, at: cursor, to: "renamed") {
    let result = try await backend.applyWorkspaceEdit(
        edit,
        openMissingFiles: true
    )
    print(result.appliedDocuments)
}
```

``SwiftEditorBackend/applyWorkspaceEdit(_:openMissingFiles:)`` performs a complete preflight against virtual buffers before changing any live document. It checks document versions and ranges, preserves the supplied edit order, and supports multiple sequential entries for the same URI.

If a later document fails, already-applied documents are restored to their exact original text and version and their syntax and language services are reopened.

## File operations

``WorkspaceEditApplicationResult/pendingFileOperations`` contains requested create, rename, or delete operations. The backend does not execute these operations because applications commonly need confirmation, conflict UI, sandbox coordination, or source-control integration.

Apply file operations through your own file layer, then reopen or close affected backend documents as appropriate.
