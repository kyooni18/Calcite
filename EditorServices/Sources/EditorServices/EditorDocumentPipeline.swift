import Foundation

/// Controls how aggressively an editor document refreshes derived language-service state.
public struct EditorDocumentPipelineConfiguration: Sendable {
  public var analysisDebounce: Duration
  public var semanticAnalysisDebounce: Duration
  public var includeSemanticHighlights: Bool

  public init(
    analysisDebounce: Duration = .milliseconds(80),
    semanticAnalysisDebounce: Duration = .milliseconds(450),
    includeSemanticHighlights: Bool = true
  ) {
    self.analysisDebounce = analysisDebounce
    self.semanticAnalysisDebounce = semanticAnalysisDebounce
    self.includeSemanticHighlights = includeSemanticHighlights
  }
}

/// A versioned, UI-ready view of a document's derived editor-service state.
public struct EditorDocumentAnalysis: Hashable, Sendable {
  public var snapshot: TextSnapshot
  public var syntaxHighlights: [Highlight]
  public var semanticHighlights: [SemanticHighlight]
  public var diagnostics: [Diagnostic]

  public init(
    snapshot: TextSnapshot,
    syntaxHighlights: [Highlight] = [],
    semanticHighlights: [SemanticHighlight] = [],
    diagnostics: [Diagnostic] = []
  ) {
    self.snapshot = snapshot
    self.syntaxHighlights = syntaxHighlights
    self.semanticHighlights = semanticHighlights
    self.diagnostics = diagnostics
  }
}

public enum EditorDocumentPipelineOperation: String, Hashable, Sendable {
  case open
  case edit
  case analysis
  case completion
  case save
  case close
}

public enum EditorDocumentPipelineUpdate: Hashable, Sendable {
  case analysis(EditorDocumentAnalysis)
  case diagnostics([Diagnostic])
  case failure(EditorDocumentPipelineOperation, String)
  case closed
}

/// Coordinates one document's incremental edits, language features, diagnostics, and analysis.
///
/// UI layers should send native UTF-16 edits to this actor instead of independently calling the
/// document session. Analysis requests are coalesced and stale responses are discarded.
public actor EditorDocumentPipeline {
  public nonisolated let uri: URL
  public nonisolated let languageID: String
  public nonisolated let updates: AsyncStream<EditorDocumentPipelineUpdate>

  private let session: SwiftEditorDocumentSession
  private let configuration: EditorDocumentPipelineConfiguration
  private let updateContinuation: AsyncStream<EditorDocumentPipelineUpdate>.Continuation

  private var analysisTask: Task<Void, Never>?
  private var semanticTask: Task<Void, Never>?
  private var diagnosticsTask: Task<Void, Never>?
  private var diagnosticBatches: [String: DiagnosticBatch] = [:]
  private var analysisGeneration = 0
  private var latestAnalysis: EditorDocumentAnalysis
  private var isClosed = false

  private init(
    session: SwiftEditorDocumentSession,
    snapshot: TextSnapshot,
    configuration: EditorDocumentPipelineConfiguration
  ) {
    self.session = session
    self.uri = session.uri
    self.languageID = session.languageID
    self.configuration = configuration
    self.latestAnalysis = EditorDocumentAnalysis(snapshot: snapshot)
    (updates, updateContinuation) = AsyncStream.makeStream(of: EditorDocumentPipelineUpdate.self)
  }

  deinit {
    analysisTask?.cancel()
    semanticTask?.cancel()
    diagnosticsTask?.cancel()
    updateContinuation.finish()
  }

  public static func open(
    backend: MultiLanguageEditorBackend,
    at url: URL,
    configuration: EditorDocumentPipelineConfiguration = .init()
  ) async throws -> EditorDocumentPipeline {
    let session = try await backend.openFileSession(at: url)
    let snapshot = try await session.snapshot()
    let pipeline = EditorDocumentPipeline(
      session: session,
      snapshot: snapshot,
      configuration: configuration
    )
    await pipeline.start()
    return pipeline
  }

  public static func open(
    backend: MultiLanguageEditorBackend,
    at url: URL,
    languageID: String,
    configuration: EditorDocumentPipelineConfiguration = .init()
  ) async throws -> EditorDocumentPipeline {
    let session = try await backend.openFileSession(at: url, languageID: languageID)
    let snapshot = try await session.snapshot()
    let pipeline = EditorDocumentPipeline(
      session: session,
      snapshot: snapshot,
      configuration: configuration
    )
    await pipeline.start()
    return pipeline
  }

  public static func open(
    backend: MultiLanguageEditorBackend,
    at url: URL,
    text: String,
    languageID: String? = nil,
    configuration: EditorDocumentPipelineConfiguration = .init()
  ) async throws -> EditorDocumentPipeline {
    let session: SwiftEditorDocumentSession
    if let languageID {
      session = try await backend.openDocumentSession(at: url, text: text, languageID: languageID)
    } else {
      session = try await backend.openDocumentSession(at: url, text: text)
    }
    let snapshot = try await session.snapshot()
    let pipeline = EditorDocumentPipeline(
      session: session,
      snapshot: snapshot,
      configuration: configuration
    )
    await pipeline.start()
    return pipeline
  }

  public func analysis() -> EditorDocumentAnalysis { latestAnalysis }
  public func snapshot() async throws -> TextSnapshot { try await session.snapshot() }
  public func text() async throws -> String { try await session.text() }

  @discardableResult
  public func applyUTF16Edit(_ range: NSRange, replacement: String) async throws -> AppliedTextEdit
  {
    try ensureOpen(operation: .edit)
    do {
      let edit = try await session.applyUTF16Edit(range, replacement: replacement)
      updateSnapshot(edit.newSnapshot, remapping: edit)
      scheduleAnalysis()
      return edit
    } catch {
      publishFailure(.edit, error)
      throw error
    }
  }

  @discardableResult
  public func replaceText(with text: String) async throws -> AppliedTextEdit {
    try ensureOpen(operation: .edit)
    do {
      let edit = try await session.replaceText(with: text)
      updateSnapshot(edit.newSnapshot)
      scheduleAnalysis()
      return edit
    } catch {
      publishFailure(.edit, error)
      throw error
    }
  }

  public func completions(
    atUTF16Offset offset: Int,
    triggerCharacter: String? = nil
  ) async throws -> [Completion] {
    let invocation = triggerCharacter.map(EditorCompletionInvocation.triggerCharacter) ?? .explicit
    return try await completions(atUTF16Offset: offset, invocation: invocation)
  }

  public func completions(
    atUTF16Offset offset: Int,
    invocation: EditorCompletionInvocation
  ) async throws -> [Completion] {
    try ensureOpen(operation: .completion)
    do {
      let current = try await session.snapshot()
      let position = try current.position(atUTF16Offset: offset)
      return try await session.completions(at: position, invocation: invocation)
    } catch {
      publishFailure(.completion, error)
      throw error
    }
  }

  public func resolveCompletion(_ completion: Completion) async throws -> Completion {
    try ensureOpen(operation: .completion)
    return try await session.resolveCompletion(completion)
  }

  @discardableResult
  public func applyCompletion(
    _ completion: Completion,
    atUTF16Offset offset: Int,
    replacing replacementRange: EditorTextRange? = nil,
    snippetVariables: [String: String] = [:]
  ) async throws -> CompletionApplicationResult {
    try ensureOpen(operation: .completion)
    do {
      let current = try await session.snapshot()
      let position = try current.position(atUTF16Offset: offset)
      let result = try await session.applyCompletion(
        completion,
        at: position,
        replacing: replacementRange,
        snippetVariables: snippetVariables
      )
      updateSnapshot(result.snapshot)
      scheduleAnalysis()
      return result
    } catch {
      publishFailure(.completion, error)
      throw error
    }
  }

  @discardableResult
  public func refreshAnalysis() async throws -> EditorDocumentAnalysis {
    try ensureOpen(operation: .analysis)
    analysisGeneration &+= 1
    analysisTask?.cancel()
    semanticTask?.cancel()
    let generation = analysisGeneration
    _ = try await performSyntaxAnalysis(generation: generation)
    if configuration.includeSemanticHighlights {
      return try await performSemanticAnalysis(generation: generation)
    }
    return latestAnalysis
  }

  public func hover(atUTF16Offset offset: Int) async throws -> HoverResult? {
    try ensureOpen(operation: .analysis)
    let current = try await session.snapshot()
    return try await session.hover(at: current.position(atUTF16Offset: offset))
  }

  public func definitions(atUTF16Offset offset: Int) async throws -> [SourceLocation] {
    try ensureOpen(operation: .analysis)
    let current = try await session.snapshot()
    return try await session.definitions(at: current.position(atUTF16Offset: offset))
  }

  public func references(
    atUTF16Offset offset: Int,
    includeDeclaration: Bool = true
  ) async throws -> [SourceLocation] {
    try ensureOpen(operation: .analysis)
    let current = try await session.snapshot()
    return try await session.references(
      at: current.position(atUTF16Offset: offset),
      includeDeclaration: includeDeclaration
    )
  }

  public func signatureHelp(atUTF16Offset offset: Int) async throws -> EditorSignatureHelp? {
    try ensureOpen(operation: .analysis)
    let current = try await session.snapshot()
    return try await session.signatureHelp(at: current.position(atUTF16Offset: offset))
  }

  public func foldingRanges() async throws -> [FoldingRange] {
    try ensureOpen(operation: .analysis)
    return try await session.foldingRanges()
  }

  public func documentSymbols() async throws -> [EditorDocumentSymbol] {
    try ensureOpen(operation: .analysis)
    return try await session.documentSymbols()
  }

  public func codeActions(
    inUTF16Range range: NSRange,
    diagnostics: [Diagnostic] = [],
    only: [String]? = nil
  ) async throws -> [EditorCodeAction] {
    try ensureOpen(operation: .analysis)
    let current = try await session.snapshot()
    return try await session.codeActions(
      in: try textRange(for: range, snapshot: current),
      diagnostics: diagnostics,
      only: only
    )
  }

  public func inlayHints(inUTF16Range range: NSRange) async throws -> [EditorInlayHint] {
    try ensureOpen(operation: .analysis)
    let current = try await session.snapshot()
    return try await session.inlayHints(in: try textRange(for: range, snapshot: current))
  }

  public func prepareRename(atUTF16Offset offset: Int) async throws -> RenamePreparation? {
    try ensureOpen(operation: .analysis)
    let current = try await session.snapshot()
    return try await session.prepareRename(at: current.position(atUTF16Offset: offset))
  }

  public func rename(
    atUTF16Offset offset: Int,
    to newName: String
  ) async throws -> EditorWorkspaceEdit? {
    try ensureOpen(operation: .edit)
    let current = try await session.snapshot()
    return try await session.rename(
      at: current.position(atUTF16Offset: offset),
      to: newName
    )
  }

  @discardableResult
  public func format(options: EditorFormattingOptions = .init()) async throws -> TextSnapshot {
    try ensureOpen(operation: .edit)
    do {
      _ = try await session.format(options: options)
      let current = try await session.snapshot()
      updateSnapshot(current)
      scheduleAnalysis(delay: .zero, semanticDelay: .zero)
      return current
    } catch {
      publishFailure(.edit, error)
      throw error
    }
  }

  public func resynchronize() async throws {
    try ensureOpen(operation: .open)
    try await session.resynchronize()
    let current = try await session.snapshot()
    updateSnapshot(current)
    scheduleAnalysis(delay: .zero)
  }

  public func persist() async throws {
    try ensureOpen(operation: .save)
    do {
      try await session.persist()
    } catch {
      publishFailure(.save, error)
      throw error
    }
  }

  public func close() async throws {
    guard !isClosed else { return }
    isClosed = true
    analysisTask?.cancel()
    semanticTask?.cancel()
    diagnosticsTask?.cancel()
    do {
      try await session.close()
      updateContinuation.yield(.closed)
      updateContinuation.finish()
    } catch {
      publishFailure(.close, error)
      updateContinuation.finish()
      throw error
    }
  }

  private func start() {
    guard diagnosticsTask == nil else { return }
    diagnosticsTask = Task { [session] in
      let stream = await session.diagnostics()
      for await batch in stream {
        guard !Task.isCancelled else { return }
        self.receive(batch)
      }
    }
    scheduleAnalysis(delay: .zero)
  }

  private func scheduleAnalysis(
    delay: Duration? = nil,
    semanticDelay: Duration? = nil
  ) {
    guard !isClosed else { return }
    analysisGeneration &+= 1
    let generation = analysisGeneration
    analysisTask?.cancel()
    semanticTask?.cancel()

    let syntaxWait = delay ?? configuration.analysisDebounce
    analysisTask = Task {
      do {
        if syntaxWait > .zero { try await Task.sleep(for: syntaxWait) }
        _ = try await self.performSyntaxAnalysis(generation: generation)
      } catch is CancellationError {
        return
      } catch {
        self.publishFailure(.analysis, error)
      }
    }

    guard configuration.includeSemanticHighlights else { return }
    let semanticWait = semanticDelay ?? configuration.semanticAnalysisDebounce
    semanticTask = Task {
      do {
        if semanticWait > .zero { try await Task.sleep(for: semanticWait) }
        _ = try await self.performSemanticAnalysis(generation: generation)
      } catch is CancellationError {
        return
      } catch {
        self.publishFailure(.analysis, error)
      }
    }
  }

  private func performSyntaxAnalysis(generation: Int) async throws -> EditorDocumentAnalysis {
    let snapshot = try await session.snapshot()
    let syntax = (try? await session.highlights()) ?? []

    guard generation == analysisGeneration, !isClosed else { throw CancellationError() }
    let current = try await session.snapshot()
    guard current.version == snapshot.version else { throw CancellationError() }

    let preservedSemantic =
      latestAnalysis.snapshot.version == current.version
      ? latestAnalysis.semanticHighlights
      : []
    let value = EditorDocumentAnalysis(
      snapshot: current,
      syntaxHighlights: syntax,
      semanticHighlights: preservedSemantic,
      diagnostics: combinedDiagnostics(for: current.version)
    )
    latestAnalysis = value
    updateContinuation.yield(.analysis(value))
    return value
  }

  private func performSemanticAnalysis(generation: Int) async throws -> EditorDocumentAnalysis {
    let snapshot = try await session.snapshot()
    let semantic = (try? await session.semanticHighlights()) ?? []

    guard generation == analysisGeneration, !isClosed else { throw CancellationError() }
    let current = try await session.snapshot()
    guard current.version == snapshot.version else { throw CancellationError() }

    let preservedSyntax =
      latestAnalysis.snapshot.version == current.version
      ? latestAnalysis.syntaxHighlights
      : []
    let value = EditorDocumentAnalysis(
      snapshot: current,
      syntaxHighlights: preservedSyntax,
      semanticHighlights: semantic,
      diagnostics: combinedDiagnostics(for: current.version)
    )
    latestAnalysis = value
    updateContinuation.yield(.analysis(value))
    return value
  }

  private func receive(_ batch: DiagnosticBatch) {
    guard !isClosed, batch.uri.standardizedFileURL == uri.standardizedFileURL else { return }
    if let version = batch.version, version < latestAnalysis.snapshot.version { return }
    diagnosticBatches[batch.serviceIdentifier ?? "default"] = batch
    let diagnostics = combinedDiagnostics(for: latestAnalysis.snapshot.version)
    latestAnalysis.diagnostics = diagnostics
    updateContinuation.yield(.diagnostics(diagnostics))
  }

  private func combinedDiagnostics(for version: Int) -> [Diagnostic] {
    diagnosticBatches.values
      .filter { $0.version == nil || $0.version == version }
      .flatMap(\.diagnostics)
      .sorted { lhs, rhs in
        if lhs.severity.rawValue != rhs.severity.rawValue {
          return lhs.severity.rawValue < rhs.severity.rawValue
        }
        if lhs.range.start != rhs.range.start { return lhs.range.start < rhs.range.start }
        return lhs.message < rhs.message
      }
  }

  private func updateSnapshot(
    _ snapshot: TextSnapshot,
    remapping edit: AppliedTextEdit? = nil
  ) {
    diagnosticBatches.removeAll(keepingCapacity: true)
    let semantic: [SemanticHighlight]
    if let edit, latestAnalysis.snapshot.version == edit.oldSnapshot.version {
      semantic = remapSemanticHighlights(latestAnalysis.semanticHighlights, through: edit)
    } else {
      semantic = []
    }
    latestAnalysis = EditorDocumentAnalysis(
      snapshot: snapshot,
      semanticHighlights: semantic
    )
  }

  private func remapSemanticHighlights(
    _ highlights: [SemanticHighlight],
    through edit: AppliedTextEdit
  ) -> [SemanticHighlight] {
    let replacementLength = edit.edit.replacement.utf16.count
    let delta = replacementLength - edit.oldUTF16Range.length
    let editEnd = NSMaxRange(edit.oldUTF16Range)

    return highlights.compactMap { highlight in
      guard let oldRange = try? edit.oldSnapshot.nsRange(for: highlight.range) else { return nil }
      let mapped: NSRange
      if NSMaxRange(oldRange) <= edit.oldUTF16Range.location {
        mapped = oldRange
      } else if oldRange.location >= editEnd {
        mapped = NSRange(location: max(0, oldRange.location + delta), length: oldRange.length)
      } else if oldRange.location <= edit.oldUTF16Range.location
        && NSMaxRange(oldRange) >= editEnd
      {
        mapped = NSRange(location: oldRange.location, length: max(0, oldRange.length + delta))
      } else {
        return nil
      }
      guard let range = try? textRange(for: mapped, snapshot: edit.newSnapshot) else { return nil }
      return SemanticHighlight(
        range: range,
        tokenType: highlight.tokenType,
        modifiers: highlight.modifiers
      )
    }
  }

  private func textRange(for range: NSRange, snapshot: TextSnapshot) throws -> EditorTextRange {
    guard range.location >= 0, range.length >= 0 else {
      throw TextBufferError.invalidUTF16Offset(range.location)
    }
    let end = range.location.addingReportingOverflow(range.length)
    guard !end.overflow else { throw TextBufferError.invalidUTF16Offset(Int.max) }
    return EditorTextRange(
      start: try snapshot.position(atUTF16Offset: range.location),
      end: try snapshot.position(atUTF16Offset: end.partialValue)
    )
  }

  private func ensureOpen(operation: EditorDocumentPipelineOperation) throws {
    guard !isClosed else {
      let error = SwiftEditorBackendError.documentNotOpen(uri)
      publishFailure(operation, error)
      throw error
    }
  }

  private func publishFailure(_ operation: EditorDocumentPipelineOperation, _ error: Error) {
    updateContinuation.yield(.failure(operation, error.localizedDescription))
  }
}

/// Owns one project backend and its open document pipelines.
public actor EditorIDEWorkspace {
  public nonisolated let serviceResult: EditorServiceBootstrapResult
  public nonisolated let backend: MultiLanguageEditorBackend

  private let documentConfiguration: EditorDocumentPipelineConfiguration
  private var documents: [URL: EditorDocumentPipeline] = [:]
  private var openingDocuments: [URL: Task<EditorDocumentPipeline, Error>] = [:]
  private var isShutdown = false

  public init(
    serviceResult: EditorServiceBootstrapResult,
    documentConfiguration: EditorDocumentPipelineConfiguration = .init()
  ) {
    self.serviceResult = serviceResult
    self.backend = serviceResult.backend
    self.documentConfiguration = documentConfiguration
  }

  #if os(macOS) || os(Linux)
    public static func open(
      configuration: EditorServicesConfiguration,
      documentConfiguration: EditorDocumentPipelineConfiguration = .init()
    ) async throws -> EditorIDEWorkspace {
      let result = try await EditorServiceBootstrap.initialize(configuration: configuration)
      return EditorIDEWorkspace(
        serviceResult: result,
        documentConfiguration: documentConfiguration
      )
    }
  #endif

  public func openDocument(at url: URL) async throws -> EditorDocumentPipeline {
    try await openDocument(at: url, languageID: nil)
  }

  public func openDocument(
    at url: URL,
    languageID: String
  ) async throws -> EditorDocumentPipeline {
    try await openDocument(at: url, languageID: Optional(languageID))
  }

  private func openDocument(
    at url: URL,
    languageID: String?
  ) async throws -> EditorDocumentPipeline {
    try ensureRunning()
    let key = url.standardizedFileURL
    if let existing = documents[key] { return existing }
    if let opening = openingDocuments[key] { return try await opening.value }

    let backend = self.backend
    let configuration = documentConfiguration
    let opening = Task<EditorDocumentPipeline, Error> {
      if let languageID {
        return try await EditorDocumentPipeline.open(
          backend: backend,
          at: key,
          languageID: languageID,
          configuration: configuration
        )
      }
      return try await EditorDocumentPipeline.open(
        backend: backend,
        at: key,
        configuration: configuration
      )
    }
    openingDocuments[key] = opening
    do {
      let document = try await opening.value
      openingDocuments.removeValue(forKey: key)
      documents[key] = document
      return document
    } catch {
      openingDocuments.removeValue(forKey: key)
      throw error
    }
  }

  public func document(at url: URL) -> EditorDocumentPipeline? {
    documents[url.standardizedFileURL]
  }

  public func openDocumentURLs() -> [URL] {
    documents.keys.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  public func closeDocument(at url: URL) async throws {
    let key = url.standardizedFileURL
    if let opening = openingDocuments.removeValue(forKey: key) {
      opening.cancel()
      _ = try? await opening.value
    }
    guard let document = documents.removeValue(forKey: key) else { return }
    try await document.close()
  }

  public func persistAll() async throws {
    try ensureRunning()
    for document in documents.values { try await document.persist() }
  }

  public func shutdown() async throws {
    guard !isShutdown else { return }
    isShutdown = true
    let pendingOpenings = openingDocuments.values
    openingDocuments.removeAll()
    for opening in pendingOpenings { opening.cancel() }
    let openDocuments = documents.values
    documents.removeAll()
    for document in openDocuments { try? await document.close() }
    try await backend.shutdown()
  }

  private func ensureRunning() throws {
    guard !isShutdown else { throw SwiftEditorBackendError.shutdown }
  }
}
