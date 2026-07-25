import EditorCore
import EditorWorkspace
import Foundation

/// A stable-ID handle for one source file in ``SwiftEditorBackend``.
///
/// Unlike a URL-bound editor session, this object remains valid after the file is
/// renamed or moved. Query ``file()`` whenever current path metadata is needed.
public final class SwiftSourceFileSession: @unchecked Sendable {
  public let id: SourceFileID
  private let backend: SwiftEditorBackend

  init(backend: SwiftEditorBackend, id: SourceFileID) {
    self.backend = backend
    self.id = id
  }

  public func file() async throws -> SourceCodeFile {
    try await backend.sourceFile(id: id)
  }

  public func isOpen() async throws -> Bool {
    let current = try await file()
    return await backend.isDocumentOpen(at: current.url)
  }

  public func openEditor() async throws -> SwiftEditorDocumentSession {
    try await backend.openSourceFile(id)
  }

  public func editorSessionIfOpen() async throws -> SwiftEditorDocumentSession? {
    let current = try await file()
    guard await backend.isDocumentOpen(at: current.url) else { return nil }
    return try await backend.documentSession(at: current.url)
  }

  @discardableResult
  public func setContent(_ content: String, expectedVersion: Int? = nil) async throws
    -> SourceCodeFile
  {
    try await backend.setSourceFileContent(content, for: id, expectedVersion: expectedVersion)
  }

  @discardableResult
  public func apply(_ edit: TextEdit, expectedVersion: Int? = nil) async throws -> SourceCodeFile {
    try await backend.applySourceFileEdits([edit], to: id, expectedVersion: expectedVersion)
  }

  @discardableResult
  public func apply(_ edits: [TextEdit], expectedVersion: Int? = nil) async throws
    -> SourceCodeFile
  {
    try await backend.applySourceFileEdits(edits, to: id, expectedVersion: expectedVersion)
  }

  @discardableResult
  public func setEncoding(_ encoding: SourceTextEncoding) async throws -> SourceCodeFile {
    try await backend.setSourceFileEncoding(encoding, for: id)
  }

  @discardableResult
  public func convertLineEndings(_ ending: SourceLineEnding) async throws -> SourceCodeFile {
    try await backend.convertSourceFileLineEndings(ending, for: id)
  }

  @discardableResult
  public func save(overwriteExternalChanges: Bool = false) async throws -> SourceCodeFile {
    try await backend.saveSourceFile(id, overwriteExternalChanges: overwriteExternalChanges)
  }

  @discardableResult
  public func reload() async throws -> SourceCodeFile {
    try await backend.reloadSourceFile(id)
  }

  @discardableResult
  public func resolveConflict(using resolution: SourceWorkspaceConflictResolution) async throws
    -> SourceCodeFile
  {
    try await backend.resolveSourceFileConflict(id, using: resolution)
  }

  @discardableResult
  public func move(to relativePath: String) async throws -> SourceCodeFile {
    try await backend.moveSourceFile(id, to: relativePath)
  }

  public func remove(deleteFromDisk: Bool = true) async throws {
    try await backend.removeSourceFile(id, deleteFromDisk: deleteFromDisk)
  }
}
