import EditorCore
import Foundation

/// A lightweight document-bound view of ``SwiftEditorBackend``.
public final class SwiftEditorDocumentSession: @unchecked Sendable {
  public let uri: URL
  public let languageID: String
  private let backend: SwiftEditorBackend

  init(backend: SwiftEditorBackend, uri: URL, languageID: String) {
    self.backend = backend
    self.uri = uri
    self.languageID = languageID
  }

  public func isOpen() async -> Bool { await backend.isDocumentOpen(at: uri) }
  public func snapshot() async throws -> TextSnapshot { try await backend.snapshot(of: uri) }
  public func text() async throws -> String { try await backend.text(of: uri) }
  public func state() async throws -> EditorDocument.State { try await backend.state(of: uri) }
  public func diagnostics(replayLatest: Bool = true) async -> AsyncStream<DiagnosticBatch> {
    await backend.diagnostics(for: uri, replayLatest: replayLatest)
  }

  @discardableResult public func apply(_ edit: TextEdit) async throws -> AppliedTextEdit {
    try await backend.apply(edit, to: uri)
  }
  @discardableResult public func apply(_ edits: [TextEdit]) async throws -> [AppliedTextEdit] {
    try await backend.apply(edits, to: uri)
  }
  @discardableResult public func applyUTF16Edit(_ range: NSRange, replacement: String) async throws
    -> AppliedTextEdit
  {
    try await backend.applyUTF16Edit(range, replacement: replacement, to: uri)
  }
  @discardableResult public func replaceText(with text: String) async throws -> AppliedTextEdit {
    try await backend.replaceText(in: uri, with: text)
  }

  public func resynchronize() async throws { try await backend.resynchronizeDocument(at: uri) }
  public func highlights(in range: EditorTextRange? = nil) async throws -> [Highlight] {
    try await backend.highlights(in: uri, range: range)
  }
  public func foldingRanges() async throws -> [FoldingRange] {
    try await backend.foldingRanges(in: uri)
  }
  public func completions(at position: TextPosition, triggerCharacter: String? = nil) async throws
    -> [Completion]
  {
    try await backend.completions(in: uri, at: position, triggerCharacter: triggerCharacter)
  }
  public func completions(
    at position: TextPosition,
    invocation: EditorCompletionInvocation
  ) async throws -> [Completion] {
    try await backend.completions(in: uri, at: position, invocation: invocation)
  }
  public func resolveCompletion(_ completion: Completion) async throws -> Completion {
    try await backend.resolveCompletion(completion, in: uri)
  }
  @discardableResult
  public func applyCompletion(
    _ completion: Completion,
    at position: TextPosition,
    replacing replacementRange: EditorTextRange? = nil,
    snippetVariables: [String: String] = [:]
  ) async throws -> CompletionApplicationResult {
    try await backend.applyCompletion(
      completion, in: uri, at: position,
      replacing: replacementRange, snippetVariables: snippetVariables
    )
  }
  public func hover(at position: TextPosition) async throws -> HoverResult? {
    try await backend.hover(in: uri, at: position)
  }
  public func definitions(at position: TextPosition) async throws -> [SourceLocation] {
    try await backend.definitions(in: uri, at: position)
  }
  public func references(at position: TextPosition, includeDeclaration: Bool = true) async throws
    -> [SourceLocation]
  {
    try await backend.references(in: uri, at: position, includeDeclaration: includeDeclaration)
  }
  public func formattingEdits(options: EditorFormattingOptions = .init()) async throws -> [TextEdit]
  {
    try await backend.formattingEdits(in: uri, options: options)
  }
  public func rangeFormattingEdits(
    in range: EditorTextRange, options: EditorFormattingOptions = .init()
  )
    async throws -> [TextEdit]
  {
    try await backend.rangeFormattingEdits(in: uri, range: range, options: options)
  }
  @discardableResult public func format(options: EditorFormattingOptions = .init()) async throws
    -> [AppliedTextEdit]
  {
    try await backend.formatDocument(in: uri, options: options)
  }
  @discardableResult public func format(
    range: EditorTextRange, options: EditorFormattingOptions = .init()
  ) async throws -> [AppliedTextEdit] {
    try await backend.formatRange(in: uri, range: range, options: options)
  }
  public func prepareRename(at position: TextPosition) async throws -> RenamePreparation? {
    try await backend.prepareRename(in: uri, at: position)
  }
  public func rename(at position: TextPosition, to newName: String) async throws
    -> EditorWorkspaceEdit?
  {
    try await backend.rename(in: uri, at: position, to: newName)
  }
  public func semanticHighlights() async throws -> [SemanticHighlight] {
    try await backend.semanticHighlights(in: uri)
  }
  public func signatureHelp(at position: TextPosition) async throws -> EditorSignatureHelp? {
    try await backend.signatureHelp(in: uri, at: position)
  }
  public func documentSymbols() async throws -> [EditorDocumentSymbol] {
    try await backend.documentSymbols(in: uri)
  }
  public func codeActions(
    in range: EditorTextRange, diagnostics: [Diagnostic] = [], only: [String]? = nil
  ) async throws -> [EditorCodeAction] {
    try await backend.codeActions(in: uri, range: range, diagnostics: diagnostics, only: only)
  }
  public func inlayHints(in range: EditorTextRange) async throws -> [EditorInlayHint] {
    try await backend.inlayHints(in: uri, range: range)
  }
  public func executeLanguageCommand(_ command: EditorCommand) async throws -> EditorJSONValue? {
    try await backend.executeLanguageCommand(command)
  }
  public func save() async throws { try await backend.saveDocument(at: uri) }
  public func persist() async throws { try await backend.persistDocument(at: uri) }
  public func close() async throws { try await backend.closeDocument(at: uri) }
}
