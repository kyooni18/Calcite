import Foundation

public enum EditorDocumentError: Error, Equatable, Sendable { case notOpen, desynchronized }

public actor EditorDocument {
  public enum State: Hashable, Sendable {
    case closed
    case synchronized(version: Int)
    case desynchronized(localVersion: Int)
  }

  public let uri: URL
  public let languageID: String
  public nonisolated let diagnostics: AsyncStream<DiagnosticBatch>
  private var buffer: TextBuffer
  private let syntax: (any SyntaxProviding)?
  private let language: (any LanguageIntelligenceProviding)?
  public private(set) var state: State = .closed

  public init(
    uri: URL,
    languageID: String,
    text: String = "",
    syntax: (any SyntaxProviding)? = nil,
    language: (any LanguageIntelligenceProviding)? = nil
  ) {
    self.uri = uri
    self.languageID = languageID
    self.buffer = TextBuffer(text: text)
    self.syntax = syntax
    self.language = language
    self.diagnostics = language?.diagnostics ?? AsyncStream { $0.finish() }
  }

  public var snapshot: TextSnapshot { buffer.snapshot }

  public func open() async throws {
    switch state {
    case .synchronized: return
    case .closed, .desynchronized: try await synchronize(snapshot: buffer.snapshot)
    }
  }

  @discardableResult
  public func apply(_ edit: TextEdit) async throws -> AppliedTextEdit {
    guard case .synchronized = state else { throw currentStateError }
    let oldBuffer = buffer
    let change = try buffer.apply(edit)
    do {
      try await syntax?.apply(change: change)
      try await language?.change(uri: uri, change: change)
      state = .synchronized(version: change.newSnapshot.version)
      return change
    } catch {
      buffer = oldBuffer
      do { try await synchronize(snapshot: oldBuffer.snapshot) } catch {
        state = .desynchronized(localVersion: oldBuffer.version)
      }
      throw error
    }
  }

  @discardableResult
  public func apply(_ edits: [TextEdit]) async throws -> [AppliedTextEdit] {
    guard case .synchronized = state else { throw currentStateError }
    guard !edits.isEmpty else { return [] }
    let oldBuffer = buffer
    let changes = try buffer.apply(edits)
    do {
      for change in changes {
        try await syntax?.apply(change: change)
        try await language?.change(uri: uri, change: change)
      }
      state = .synchronized(version: buffer.version)
      return changes
    } catch {
      buffer = oldBuffer
      do { try await synchronize(snapshot: oldBuffer.snapshot) } catch {
        state = .desynchronized(localVersion: oldBuffer.version)
      }
      throw error
    }
  }

  public func resynchronize() async throws { try await synchronize(snapshot: buffer.snapshot) }

  /// Restores an exact snapshot, including its version, and reopens parser and language services.
  ///
  /// This is package-internal recovery machinery used to make multi-document
  /// workspace edits transactional. A failed restore leaves the requested
  /// snapshot as the authoritative local buffer and marks the document
  /// desynchronized.
  package func restore(snapshot: TextSnapshot) async throws {
    buffer = TextBuffer(text: snapshot.text, version: snapshot.version)
    do {
      try await synchronize(snapshot: snapshot)
    } catch {
      state = .desynchronized(localVersion: snapshot.version)
      throw error
    }
  }

  public func highlights(in range: EditorTextRange? = nil) async throws -> [Highlight] {
    guard case .synchronized = state else { throw currentStateError }
    return try await syntax?.highlights(in: range) ?? []
  }

  public func foldingRanges() async throws -> [FoldingRange] {
    guard case .synchronized = state else { throw currentStateError }
    return try await syntax?.foldingRanges() ?? []
  }

  public func completions(at position: TextPosition, triggerCharacter: String? = nil) async throws
    -> [Completion]
  {
    guard case .synchronized = state else { throw currentStateError }
    return try await language?.completions(
      uri: uri, at: position, triggerCharacter: triggerCharacter) ?? []
  }

  public func resolveCompletion(_ completion: Completion) async throws -> Completion {
    guard case .synchronized = state else { throw currentStateError }
    return try await language?.resolveCompletion(completion) ?? completion
  }

  public func hover(at position: TextPosition) async throws -> HoverResult? {
    guard case .synchronized = state else { throw currentStateError }
    return try await language?.hover(uri: uri, at: position)
  }

  public func definitions(at position: TextPosition) async throws -> [SourceLocation] {
    guard case .synchronized = state else { throw currentStateError }
    return try await language?.definitions(uri: uri, at: position) ?? []
  }

  public func references(at position: TextPosition, includeDeclaration: Bool = true) async throws
    -> [SourceLocation]
  {
    guard case .synchronized = state else { throw currentStateError }
    guard let language else { return [] }
    return try await language.references(
      uri: uri, at: position, includeDeclaration: includeDeclaration)
  }

  public func formatting(options: EditorFormattingOptions = .init()) async throws -> [TextEdit] {
    guard case .synchronized = state else { throw currentStateError }
    guard let language else { return [] }
    return try await language.formatting(uri: uri, options: options)
  }

  public func rangeFormatting(_ range: EditorTextRange, options: EditorFormattingOptions = .init())
    async throws -> [TextEdit]
  {
    guard case .synchronized = state else { throw currentStateError }
    guard let language else { return [] }
    return try await language.rangeFormatting(uri: uri, range: range, options: options)
  }

  public func prepareRename(at position: TextPosition) async throws -> RenamePreparation? {
    guard case .synchronized = state else { throw currentStateError }
    return try await language?.prepareRename(uri: uri, at: position)
  }

  public func rename(at position: TextPosition, newName: String) async throws
    -> EditorWorkspaceEdit?
  {
    guard case .synchronized = state else { throw currentStateError }
    return try await language?.rename(uri: uri, at: position, newName: newName)
  }

  public func semanticHighlights() async throws -> [SemanticHighlight] {
    guard case .synchronized = state else { throw currentStateError }
    guard let language else { return [] }
    return try await language.semanticHighlights(uri: uri)
  }

  public func signatureHelp(at position: TextPosition) async throws -> EditorSignatureHelp? {
    guard case .synchronized = state else { throw currentStateError }
    return try await language?.signatureHelp(uri: uri, at: position)
  }

  public func documentSymbols() async throws -> [EditorDocumentSymbol] {
    guard case .synchronized = state else { throw currentStateError }
    guard let language else { return [] }
    return try await language.documentSymbols(uri: uri)
  }

  public func codeActions(
    in range: EditorTextRange,
    diagnostics: [Diagnostic] = [],
    only: [String]? = nil
  ) async throws -> [EditorCodeAction] {
    guard case .synchronized = state else { throw currentStateError }
    guard let language else { return [] }
    return try await language.codeActions(
      uri: uri, range: range, diagnostics: diagnostics, only: only)
  }

  public func inlayHints(in range: EditorTextRange) async throws -> [EditorInlayHint] {
    guard case .synchronized = state else { throw currentStateError }
    guard let language else { return [] }
    return try await language.inlayHints(uri: uri, range: range)
  }

  public func save() async throws {
    try await save(snapshot: buffer.snapshot)
  }

  package func save(snapshot: TextSnapshot) async throws {
    guard case .synchronized = state else { throw currentStateError }
    try await language?.save(uri: uri, snapshot: snapshot)
  }

  public func close() async throws {
    guard state != .closed else { return }
    var firstFailure: Error?
    do { try await language?.close(uri: uri) } catch { firstFailure = error }
    do { try await syntax?.close() } catch { if firstFailure == nil { firstFailure = error } }
    if let firstFailure {
      state = .desynchronized(localVersion: buffer.version)
      throw firstFailure
    }
    state = .closed
  }

  private var currentStateError: EditorDocumentError {
    if case .desynchronized = state { return .desynchronized }
    return .notOpen
  }

  private func synchronize(snapshot: TextSnapshot) async throws {
    if state != .closed { try? await language?.close(uri: uri) }
    try await syntax?.open(snapshot: snapshot)
    do {
      try await language?.open(uri: uri, languageID: languageID, snapshot: snapshot)
      state = .synchronized(version: snapshot.version)
    } catch {
      try? await syntax?.close()
      state = .desynchronized(localVersion: snapshot.version)
      throw error
    }
  }
}
