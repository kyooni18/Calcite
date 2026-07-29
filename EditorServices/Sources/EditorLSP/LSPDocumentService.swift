import EditorCore
import Foundation
import LanguageServerProtocol

public enum LSPDocumentServiceError: Error, Equatable, Sendable {
  case documentNotOpen(URL)
  case documentAlreadyOpen(URL)
  case staleVersion(expected: Int, received: Int)
  case shutdown
  case initializationTimedOut(Duration)
  case shutdownTimedOut(Duration)
  case semanticTokensUnsupported
  case completionResolutionExpired(UUID)
}

private actor LSPAsyncRace<Value: Sendable> {
  private var storedResult: Result<Value, any Error>?
  private var continuation: CheckedContinuation<Value, any Error>?

  func value() async throws -> Value {
    if let storedResult { return try storedResult.get() }
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func resolve(_ result: Result<Value, any Error>) {
    guard storedResult == nil else { return }
    storedResult = result
    if let continuation {
      self.continuation = nil
      continuation.resume(with: result)
    }
  }
}

public actor LSPDocumentService: LanguageIntelligenceProviding {
  public typealias ConfigurationProvider =
    @Sendable (
      [LanguageServerConfigurationItem]
    ) async -> [EditorJSONValue]
  public typealias WorkspaceEditHandler =
    @Sendable (
      EditorWorkspaceEdit, String?
    ) async throws -> Bool

  private struct OpenDocument: Sendable {
    var languageID: String
    var snapshot: TextSnapshot
  }
  private struct CachedCompletion: Sendable {
    var uri: URL
    var item: LanguageServerProtocol.CompletionItem
  }

  private let transport: any LSPServerTransport
  private let workspaceFolders: [WorkspaceFolder]
  private var configurationProvider: ConfigurationProvider
  private var workspaceEditHandler: WorkspaceEditHandler?
  private var documents: [URL: OpenDocument] = [:]
  private var openingDocuments: [URL: LSPAsyncRace<Void>] = [:]
  private var initialization: InitializationResponse?
  private var initializationTask: Task<InitializationResponse, Error>?
  private var eventTask: Task<Void, Never>?
  private var isShutdown = false
  private var completionCache: [UUID: CachedCompletion] = [:]
  private var completionCacheOrder: [UUID] = []
  private var dynamicRegistrations: [String: Registration] = [:]
  private let completionCacheLimit = 2_048
  private let diagnosticContinuation: AsyncStream<DiagnosticBatch>.Continuation
  private let errorContinuation: AsyncStream<String>.Continuation
  private let messageContinuation: AsyncStream<LanguageServerMessage>.Continuation
  public nonisolated let diagnostics: AsyncStream<DiagnosticBatch>
  public nonisolated let messages: AsyncStream<LanguageServerMessage>
  public nonisolated let serverErrors: AsyncStream<String>

  public init(
    transport: any LSPServerTransport,
    workspaceFolders: [WorkspaceFolder] = [],
    configurationProvider: @escaping ConfigurationProvider = { items in
      Array(repeating: .null, count: items.count)
    },
    workspaceEditHandler: WorkspaceEditHandler? = nil
  ) {
    self.transport = transport
    self.workspaceFolders = workspaceFolders
    self.configurationProvider = configurationProvider
    self.workspaceEditHandler = workspaceEditHandler
    (diagnostics, diagnosticContinuation) = AsyncStream.makeStream(of: DiagnosticBatch.self)
    (messages, messageContinuation) = AsyncStream.makeStream(of: LanguageServerMessage.self)
    (serverErrors, errorContinuation) = AsyncStream.makeStream(of: String.self)
  }

  deinit {
    eventTask?.cancel()
    diagnosticContinuation.finish()
    messageContinuation.finish()
    errorContinuation.finish()
  }

  public func initialize() async throws -> InitializationResponse {
    try await initialize(timeout: nil)
  }

  /// Initializes the language server and optionally bounds the handshake duration.
  ///
  /// A timeout is particularly important for third-party servers that launch successfully but
  /// never answer the LSP `initialize` request. The underlying process connection can then be
  /// terminated by its owner without leaving the editor bootstrap suspended indefinitely.
  public func initialize(timeout: Duration?) async throws -> InitializationResponse {
    if let initialization { return initialization }
    if let task = initializationTask {
      return try await awaitInitialization(task, timeout: timeout)
    }
    guard !isShutdown else { throw LSPDocumentServiceError.shutdown }
    let task = Task { try await transport.initialize() }
    initializationTask = task
    do {
      let response = try await awaitInitialization(task, timeout: timeout)
      initialization = response
      initializationTask = nil
      startEventMonitoring()
      return response
    } catch {
      task.cancel()
      initializationTask = nil
      throw error
    }
  }

  public func open(uri: URL, languageID: String, snapshot: TextSnapshot) async throws {
    let key = documentKey(uri)
    if let opening = openingDocuments[key] {
      try await opening.value()
      return
    }
    guard documents[key] == nil else { throw LSPDocumentServiceError.documentAlreadyOpen(key) }

    let opening = LSPAsyncRace<Void>()
    openingDocuments[key] = opening
    // Register the local document before the first suspension point. This prevents diagnostics
    // emitted synchronously from didOpen from being dropped and lets concurrent operations wait
    // for the matching didOpen instead of observing a transient "document not open" state.
    documents[key] = OpenDocument(languageID: languageID, snapshot: snapshot)

    do {
      _ = try await initialize()
      if supportsOpenClose() {
        try await transport.didOpen(
          DidOpenTextDocumentParams(
            textDocument: TextDocumentItem(
              uri: key.absoluteString, languageId: languageID, version: snapshot.version,
              text: snapshot.text
            )))
      }
      openingDocuments.removeValue(forKey: key)
      await opening.resolve(.success(()))
    } catch {
      documents.removeValue(forKey: key)
      openingDocuments.removeValue(forKey: key)
      await opening.resolve(.failure(error))
      throw error
    }
  }

  public func change(uri: URL, change: AppliedTextEdit) async throws {
    let key = documentKey(uri)
    try await awaitOpeningDocumentIfNeeded(key)
    guard var document = documents[key] else { throw LSPDocumentServiceError.documentNotOpen(key) }
    guard document.snapshot.version == change.oldSnapshot.version else {
      throw LSPDocumentServiceError.staleVersion(
        expected: document.snapshot.version, received: change.oldSnapshot.version)
    }
    let sync = try await synchronizationKind()
    let content: [TextDocumentContentChangeEvent]
    switch sync {
    case .none: content = []
    case .full:
      content = [
        TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: change.newSnapshot.text)
      ]
    case .incremental:
      content = [
        TextDocumentContentChangeEvent(
          range: LSPConversion.range(change.edit.range), rangeLength: change.oldUTF16Range.length,
          text: change.edit.replacement
        )
      ]
    }
    if !content.isEmpty {
      try await transport.didChange(
        DidChangeTextDocumentParams(
          uri: key.absoluteString, version: change.newSnapshot.version, contentChanges: content
        ))
    }
    document.snapshot = change.newSnapshot
    documents[key] = document
    removeCachedCompletions(for: key)
  }

  public func save(uri: URL, snapshot: TextSnapshot) async throws {
    let key = documentKey(uri)
    try await awaitOpeningDocumentIfNeeded(key)
    guard documents[key] != nil else { throw LSPDocumentServiceError.documentNotOpen(key) }
    _ = try await initialize()
    guard saveSupported() else { return }
    let includeText = saveIncludeText()
    try await transport.didSave(
      DidSaveTextDocumentParams(uri: key.absoluteString, text: includeText ? snapshot.text : nil))
  }

  public func completions(uri: URL, at position: TextPosition, triggerCharacter: String? = nil)
    async throws -> [Completion]
  {
    let document = try requireDocument(uri)
    _ = try document.snapshot.utf16Offset(of: position)
    _ = try await initialize()
    guard completionSupported() else {
      throw LanguageFeatureError.unsupported("textDocument/completion")
    }
    removeCachedCompletions(for: uri)
    let trigger: CompletionTriggerKind = triggerCharacter == nil ? .invoked : .triggerCharacter
    let response = try await transport.completion(
      CompletionParams(
        uri: uri.absoluteString, position: LSPConversion.position(position), triggerKind: trigger,
        triggerCharacter: triggerCharacter
      ))
    let canResolve = completionResolutionSupported()
    return try (response?.items ?? []).map { item in
      let id = canResolve ? cacheCompletion(item, for: uri) : nil
      let value = LSPConversion.completion(item, resolutionID: id)
      try validateCompletion(value, in: document.snapshot)
      return value
    }
  }

  public func resolveCompletion(_ completion: Completion) async throws -> Completion {
    guard let id = completion.resolutionID else { return completion }
    guard var cached = completionCache[id] else {
      throw LSPDocumentServiceError.completionResolutionExpired(id)
    }
    let document = try requireDocument(cached.uri)
    _ = try await initialize()
    guard completionResolutionSupported() else {
      throw LanguageFeatureError.unsupported("completionItem/resolve")
    }
    cached.item = try await transport.resolveCompletionItem(cached.item)
    completionCache[id] = cached
    let value = LSPConversion.completion(cached.item, resolutionID: id)
    try validateCompletion(value, in: document.snapshot)
    return value
  }

  public func hover(uri: URL, at position: TextPosition) async throws -> HoverResult? {
    let document = try requireDocument(uri)
    _ = try document.snapshot.utf16Offset(of: position)
    _ = try await initialize()
    guard
      twoTypeProviderEnabled(initialization?.capabilities.hoverProvider)
        || isDynamicallyRegistered("textDocument/hover")
    else { throw LanguageFeatureError.unsupported("textDocument/hover") }
    let result = try await transport.hover(
      TextDocumentPositionParams(
        uri: uri.absoluteString, position: LSPConversion.position(position))
    ).map(LSPConversion.hover)
    if let range = result?.range { _ = try document.snapshot.nsRange(for: range) }
    return result
  }

  public func definitions(uri: URL, at position: TextPosition) async throws -> [SourceLocation] {
    let document = try requireDocument(uri)
    _ = try document.snapshot.utf16Offset(of: position)
    _ = try await initialize()
    guard
      twoTypeProviderEnabled(initialization?.capabilities.definitionProvider)
        || isDynamicallyRegistered("textDocument/definition")
    else { throw LanguageFeatureError.unsupported("textDocument/definition") }
    let result = LSPConversion.locations(
      try await transport.definition(
        TextDocumentPositionParams(
          uri: uri.absoluteString, position: LSPConversion.position(position))))
    try validateLocations(result)
    return result
  }

  public func references(uri: URL, at position: TextPosition, includeDeclaration: Bool = true)
    async throws -> [SourceLocation]
  {
    let document = try requireDocument(uri)
    _ = try document.snapshot.utf16Offset(of: position)
    _ = try await initialize()
    guard
      twoTypeProviderEnabled(initialization?.capabilities.referencesProvider)
        || isDynamicallyRegistered("textDocument/references")
    else { throw LanguageFeatureError.unsupported("textDocument/references") }
    let response = try await transport.references(
      ReferenceParams(
        textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
        position: LSPConversion.position(position), includeDeclaration: includeDeclaration
      ))
    let result = (response ?? []).map(LSPConversion.location)
    try validateLocations(result)
    return result
  }

  public func formatting(uri: URL, options: EditorFormattingOptions) async throws -> [EditorCore
    .TextEdit]
  {
    let document = try requireDocument(uri)
    _ = try await initialize()
    guard
      twoTypeProviderEnabled(initialization?.capabilities.documentFormattingProvider)
        || isDynamicallyRegistered("textDocument/formatting")
    else { throw LanguageFeatureError.unsupported("textDocument/formatting") }
    let result =
      (try await transport.formatting(
        DocumentFormattingParams(
          textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
          options: FormattingOptions(tabSize: options.tabSize, insertSpaces: options.insertSpaces)
        )) ?? []).map(LSPConversion.edit)
    try validateEdits(result, in: document.snapshot)
    return result
  }

  public func rangeFormatting(uri: URL, range: EditorTextRange, options: EditorFormattingOptions)
    async throws -> [EditorCore.TextEdit]
  {
    let document = try requireDocument(uri)
    _ = try document.snapshot.nsRange(for: range)
    _ = try await initialize()
    guard
      twoTypeProviderEnabled(initialization?.capabilities.documentRangeFormattingProvider)
        || isDynamicallyRegistered("textDocument/rangeFormatting")
    else { throw LanguageFeatureError.unsupported("textDocument/rangeFormatting") }
    let result =
      (try await transport.rangeFormatting(
        DocumentRangeFormattingParams(
          textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
          range: LSPConversion.range(range),
          options: FormattingOptions(tabSize: options.tabSize, insertSpaces: options.insertSpaces)
        )) ?? []).map(LSPConversion.edit)
    try validateEdits(result, in: document.snapshot)
    return result
  }

  public func prepareRename(uri: URL, at position: TextPosition) async throws -> RenamePreparation?
  {
    let document = try requireDocument(uri)
    _ = try document.snapshot.utf16Offset(of: position)
    _ = try await initialize()
    guard
      twoTypeProviderEnabled(initialization?.capabilities.renameProvider)
        || isDynamicallyRegistered("textDocument/rename")
    else { throw LanguageFeatureError.unsupported("textDocument/prepareRename") }
    let result = LSPConversion.renamePreparation(
      try await transport.prepareRename(
        TextDocumentPositionParams(
          uri: uri.absoluteString, position: LSPConversion.position(position)
        )))
    if case .range(let range, _) = result { _ = try document.snapshot.nsRange(for: range) }
    return result
  }

  public func rename(uri: URL, at position: TextPosition, newName: String) async throws
    -> EditorWorkspaceEdit?
  {
    let document = try requireDocument(uri)
    _ = try document.snapshot.utf16Offset(of: position)
    _ = try await initialize()
    guard
      twoTypeProviderEnabled(initialization?.capabilities.renameProvider)
        || isDynamicallyRegistered("textDocument/rename")
    else { throw LanguageFeatureError.unsupported("textDocument/rename") }
    let result = LSPConversion.workspaceEdit(
      try await transport.rename(
        RenameParams(
          textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
          position: LSPConversion.position(position), newName: newName
        )))
    try validateWorkspaceEdit(result)
    return result
  }

  public func semanticHighlights(uri: URL) async throws -> [SemanticHighlight] {
    let document = try requireDocument(uri)
    _ = try await initialize()
    guard let legend = semanticLegend() else {
      throw LSPDocumentServiceError.semanticTokensUnsupported
    }
    let result = try LSPConversion.semanticHighlights(
      try await transport.semanticTokensFull(
        SemanticTokensParams(
          textDocument: TextDocumentIdentifier(uri: uri.absoluteString)
        )), legend: legend)
    for value in result { _ = try document.snapshot.nsRange(for: value.range) }
    return result
  }

  public func signatureHelp(uri: URL, at position: TextPosition) async throws
    -> EditorSignatureHelp?
  {
    let document = try requireDocument(uri)
    _ = try document.snapshot.utf16Offset(of: position)
    _ = try await initialize()
    guard
      initialization?.capabilities.signatureHelpProvider != nil
        || isDynamicallyRegistered("textDocument/signatureHelp")
    else { throw LanguageFeatureError.unsupported("textDocument/signatureHelp") }
    return LSPConversion.signatureHelp(
      try await transport.signatureHelp(
        TextDocumentPositionParams(
          uri: uri.absoluteString, position: LSPConversion.position(position)
        )))
  }

  public func documentSymbols(uri: URL) async throws -> [EditorDocumentSymbol] {
    let document = try requireDocument(uri)
    _ = try await initialize()
    guard
      twoTypeProviderEnabled(initialization?.capabilities.documentSymbolProvider)
        || isDynamicallyRegistered("textDocument/documentSymbol")
    else { throw LanguageFeatureError.unsupported("textDocument/documentSymbol") }
    let result = LSPConversion.documentSymbols(
      try await transport.documentSymbols(
        DocumentSymbolParams(textDocument: TextDocumentIdentifier(uri: uri.absoluteString))
      ))
    try validateDocumentSymbols(result, in: document.snapshot)
    return result
  }

  public func workspaceSymbols(query: String) async throws -> [EditorWorkspaceSymbol] {
    _ = try await initialize()
    guard
      twoTypeProviderEnabled(initialization?.capabilities.workspaceSymbolProvider)
        || isDynamicallyRegistered("workspace/symbol")
    else { throw LanguageFeatureError.unsupported("workspace/symbol") }
    return LSPConversion.workspaceSymbols(
      try await transport.workspaceSymbols(WorkspaceSymbolParams(query: query))
    )
  }

  public func notifyWorkspaceFileChanges(_ changes: [EditorWorkspaceFileChange]) async throws {
    guard !changes.isEmpty else { return }
    _ = try await initialize()
    let events = changes.map { change in
      FileEvent(
        uri: change.uri.absoluteString,
        type: FileChangeType(rawValue: change.kind.rawValue) ?? .changed
      )
    }
    try await transport.didChangeWatchedFiles(DidChangeWatchedFilesParams(changes: events))
  }

  public func pullDiagnostics(uri: URL, previousResultID: String? = nil) async throws
    -> DiagnosticBatch
  {
    _ = try await initialize()
    guard initialization?.capabilities.diagnosticProvider != nil
      || isDynamicallyRegistered("textDocument/diagnostic")
    else { throw LanguageFeatureError.unsupported("textDocument/diagnostic") }
    let key = documentKey(uri)
    let report = try await transport.diagnostics(
      DocumentDiagnosticParams(
        textDocument: TextDocumentIdentifier(uri: key.absoluteString),
        previousResultId: previousResultID
      )
    )
    let batch = DiagnosticBatch(
      uri: key,
      version: documents[key]?.snapshot.version,
      diagnostics: (report.items ?? []).map(LSPConversion.diagnostic)
    )
    diagnosticContinuation.yield(batch)
    return batch
  }

  public func codeActions(
    uri: URL,
    range: EditorTextRange,
    diagnostics: [EditorCore.Diagnostic] = [],
    only: [String]? = nil
  ) async throws -> [EditorCodeAction] {
    let document = try requireDocument(uri)
    _ = try document.snapshot.nsRange(for: range)
    _ = try await initialize()
    guard
      twoTypeProviderEnabled(initialization?.capabilities.codeActionProvider)
        || isDynamicallyRegistered("textDocument/codeAction")
    else { throw LanguageFeatureError.unsupported("textDocument/codeAction") }
    let params = CodeActionParams(
      textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
      range: LSPConversion.range(range),
      context: CodeActionContext(
        diagnostics: diagnostics.map(LSPConversion.lspDiagnostic),
        only: only,
        triggerKind: .invoked
      )
    )
    let result = LSPConversion.codeActions(try await transport.codeActions(params))
    for action in result { try validateWorkspaceEdit(action.edit) }
    return result
  }

  public func inlayHints(uri: URL, range: EditorTextRange) async throws -> [EditorInlayHint] {
    let document = try requireDocument(uri)
    _ = try document.snapshot.nsRange(for: range)
    _ = try await initialize()
    guard
      threeTypeProviderEnabled(initialization?.capabilities.inlayHintProvider)
        || isDynamicallyRegistered("textDocument/inlayHint")
    else { throw LanguageFeatureError.unsupported("textDocument/inlayHint") }
    let values = LSPConversion.inlayHints(
      try await transport.inlayHints(
        InlayHintParams(
          textDocument: TextDocumentIdentifier(uri: uri.absoluteString),
          range: LSPConversion.range(range)
        )))
    for value in values {
      _ = try document.snapshot.utf16Offset(of: value.position)
      for edit in value.edits { _ = try document.snapshot.nsRange(for: edit.range) }
    }
    return values
  }

  public func executeCommand(_ command: EditorCommand) async throws -> EditorJSONValue? {
    _ = try await initialize()
    let staticCommands = initialization?.capabilities.executeCommandProvider?.commands ?? []
    let dynamicCommands = dynamicOptions(
      for: "workspace/executeCommand", as: ExecuteCommandRegistrationOptions.self
    ).flatMap(\.commands)
    guard staticCommands.contains(command.command) || dynamicCommands.contains(command.command)
    else {
      throw LanguageFeatureError.unsupported("workspace/executeCommand")
    }
    let result = try await transport.executeCommand(
      ExecuteCommandParams(
        command: command.command,
        arguments: command.arguments.map(LSPConversion.lspJSON)
      )
    )
    return LSPConversion.json(result)
  }

  public func close(uri: URL) async throws {
    let key = documentKey(uri)
    try await awaitOpeningDocumentIfNeeded(key)
    guard documents[key] != nil else { throw LSPDocumentServiceError.documentNotOpen(key) }
    if supportsOpenClose() {
      try await transport.didClose(DidCloseTextDocumentParams(uri: key.absoluteString))
    }
    documents.removeValue(forKey: key)
    removeCachedCompletions(for: key)
  }

  public func shutdown() async throws {
    try await shutdown(timeout: .seconds(5))
  }

  /// Shuts the server down with a bounded wait.
  ///
  /// The service becomes terminal even when the server ignores the shutdown request. Process
  /// owners should terminate the associated process after receiving ``LSPDocumentServiceError/shutdownTimedOut(_:)``.
  public func shutdown(timeout: Duration) async throws {
    guard !isShutdown else { return }
    isShutdown = true
    defer { finishShutdown() }

    let race = LSPAsyncRace<Void>()
    let operation = Task { [transport] in
      do {
        try await transport.shutdown()
        await race.resolve(.success(()))
      } catch {
        await race.resolve(.failure(error))
      }
    }
    let timer = Task {
      do {
        try await Task.sleep(for: timeout)
        await race.resolve(.failure(LSPDocumentServiceError.shutdownTimedOut(timeout)))
      } catch {
        // The operation completed before the timer.
      }
    }
    defer {
      operation.cancel()
      timer.cancel()
    }
    try await race.value()
  }

  private func awaitInitialization(
    _ task: Task<InitializationResponse, Error>,
    timeout: Duration?
  ) async throws -> InitializationResponse {
    guard let timeout else { return try await task.value }
    let race = LSPAsyncRace<InitializationResponse>()
    let operation = Task {
      do {
        await race.resolve(.success(try await task.value))
      } catch {
        await race.resolve(.failure(error))
      }
    }
    let timer = Task {
      do {
        try await Task.sleep(for: timeout)
        await race.resolve(.failure(LSPDocumentServiceError.initializationTimedOut(timeout)))
      } catch {
        // The operation completed before the timer.
      }
    }
    defer {
      operation.cancel()
      timer.cancel()
    }
    return try await race.value()
  }

  private func finishShutdown() {
    documents.removeAll()
    completionCache.removeAll()
    completionCacheOrder.removeAll()
    dynamicRegistrations.removeAll()
    initializationTask?.cancel()
    initializationTask = nil
    eventTask?.cancel()
    eventTask = nil
    diagnosticContinuation.finish()
    messageContinuation.finish()
    errorContinuation.finish()
  }

  public var openedDocumentURIs: [URL] {
    documents.keys.sorted { $0.absoluteString < $1.absoluteString }
  }
  public var serverCapabilities: ServerCapabilities? { initialization?.capabilities }

  /// Replaces the provider used to answer `workspace/configuration` requests.
  public func setConfigurationProvider(_ provider: @escaping ConfigurationProvider) {
    configurationProvider = provider
  }

  /// Installs or removes the handler for server-initiated `workspace/applyEdit` requests.
  public func setWorkspaceEditHandler(_ handler: WorkspaceEditHandler?) {
    workspaceEditHandler = handler
  }

  private func requireOpen(_ uri: URL) throws { _ = try requireDocument(uri) }
  private func requireDocument(_ uri: URL) throws -> OpenDocument {
    let key = documentKey(uri)
    guard let document = documents[key] else { throw LSPDocumentServiceError.documentNotOpen(key) }
    return document
  }

  private func awaitOpeningDocumentIfNeeded(_ uri: URL) async throws {
    if let opening = openingDocuments[documentKey(uri)] {
      try await opening.value()
    }
  }

  private func documentKey(_ uri: URL) -> URL {
    uri.isFileURL ? uri.standardizedFileURL : uri
  }

  private func twoTypeProviderEnabled<Options>(_ provider: TwoTypeOption<Bool, Options>?) -> Bool {
    guard let provider else { return false }
    switch provider {
    case .optionA(let enabled): return enabled
    case .optionB: return true
    }
  }

  private func threeTypeProviderEnabled<A, B>(_ provider: ThreeTypeOption<Bool, A, B>?) -> Bool {
    guard let provider else { return false }
    switch provider {
    case .optionA(let enabled): return enabled
    case .optionB, .optionC: return true
    }
  }
  private func startEventMonitoring() {
    guard eventTask == nil else { return }
    let transport = self.transport
    eventTask = Task { for await event in transport.events { await self.handle(event) } }
  }
  private func handle(_ event: ServerEvent) async {
    switch event {
    case .notification(.textDocumentPublishDiagnostics(let params)):
      guard let rawURI = URL(string: params.uri) else { return }
      let uri = documentKey(rawURI)
      if let document = documents[uri],
        let version = params.version,
        version < document.snapshot.version
      {
        return
      }
      diagnosticContinuation.yield(
        DiagnosticBatch(
          uri: uri, version: params.version,
          diagnostics: params.diagnostics.map(LSPConversion.diagnostic)))
    case .notification(.windowShowMessage(let params)),
      .notification(.windowLogMessage(let params)):
      messageContinuation.yield(
        LanguageServerMessage(kind: messageKind(params.type), message: params.message))
    case .error(let error): errorContinuation.yield(String(describing: error))
    case .request(_, let request): await handle(request)
    default: break
    }
  }
  private func handle(_ request: ServerRequest) async {
    switch request {
    case .workspaceFolders(let handler):
      await handler(.success(workspaceFolders.isEmpty ? nil : workspaceFolders))
    case .workspaceConfiguration(let params, let handler):
      let items = params.items.map { item in
        LanguageServerConfigurationItem(
          scopeURI: item.scopeUri.flatMap(URL.init(string:)),
          section: item.section
        )
      }
      var values = await configurationProvider(items)
      if values.count > items.count {
        values = Array(values.prefix(items.count))
      } else if values.count < items.count {
        values.append(contentsOf: repeatElement(.null, count: items.count - values.count))
      }
      await handler(.success(values.map(LSPConversion.lspJSON)))
    case .workspaceApplyEdit(let params, let handler):
      guard let workspaceEditHandler else {
        await handler(
          .success(
            ApplyWorkspaceEditResult(
              applied: false,
              failureReason: "No workspace edit handler is configured."
            )))
        return
      }
      guard let edit = LSPConversion.workspaceEdit(params.edit) else {
        await handler(
          .success(
            ApplyWorkspaceEditResult(
              applied: false,
              failureReason: "The server returned a malformed workspace edit."
            )))
        return
      }
      do {
        try validateWorkspaceEdit(edit)
        let applied = try await workspaceEditHandler(edit, params.label)
        await handler(
          .success(
            ApplyWorkspaceEditResult(
              applied: applied,
              failureReason: applied ? nil : "The editor declined the workspace edit."
            )))
      } catch {
        await handler(
          .success(
            ApplyWorkspaceEditResult(
              applied: false,
              failureReason: String(describing: error)
            )))
      }
    case .clientRegisterCapability(let params, let handler):
      for registration in params.registrations {
        dynamicRegistrations[registration.id] = registration
      }
      // InitializingServer already replies to these requests for the real process transport.
      // Sending a second response makes rust-analyzer panic with "response for unknown request".
      if !transport.prehandlesCapabilityRegistrationRequests { await handler(nil) }
    case .clientUnregisterCapability(let params, let handler):
      for registration in params.unregistrations {
        dynamicRegistrations.removeValue(forKey: registration.id)
      }
      if !transport.prehandlesCapabilityRegistrationRequests { await handler(nil) }
    case .workspaceCodeLensRefresh(let handler), .workspaceSemanticTokenRefresh(let handler),
      .windowWorkDoneProgressCreate(_, let handler):
      await handler(nil)
    default: await request.relyWithError(LanguageFeatureError.unsupported(request.method.rawValue))
    }
  }
  private func messageKind(_ type: MessageType) -> LanguageServerMessageKind {
    switch type {
    case .error: return .error
    case .warning: return .warning
    case .info: return .information
    case .log: return .log
    }
  }

  private func isDynamicallyRegistered(_ method: String) -> Bool {
    dynamicRegistrations.values.contains { $0.method == method }
  }

  private func dynamicOptions<T: Decodable>(for method: String, as type: T.Type) -> [T] {
    dynamicRegistrations.values.compactMap { registration in
      guard registration.method == method, let options = registration.registerOptions,
        let data = try? JSONEncoder().encode(options)
      else { return nil }
      return try? JSONDecoder().decode(type, from: data)
    }
  }

  private func completionSupported() -> Bool {
    initialization?.capabilities.completionProvider != nil
      || isDynamicallyRegistered("textDocument/completion")
  }

  private func completionResolutionSupported() -> Bool {
    if initialization?.capabilities.completionProvider?.resolveProvider ?? false { return true }
    return dynamicOptions(
      for: "textDocument/completion", as: CompletionRegistrationOptions.self
    ).contains { $0.resolveProvider ?? false }
  }

  private func validateEdits(_ edits: [EditorCore.TextEdit], in snapshot: TextSnapshot) throws {
    for edit in edits { _ = try snapshot.nsRange(for: edit.range) }
  }

  private func validateLocations(_ locations: [SourceLocation]) throws {
    for location in locations {
      if let document = documents[location.uri] {
        _ = try document.snapshot.nsRange(for: location.range)
      }
    }
  }

  private func validateWorkspaceEdit(_ edit: EditorWorkspaceEdit?) throws {
    guard let edit else { return }
    for documentEdit in edit.documentEdits {
      if let document = documents[documentEdit.uri] {
        try validateEdits(documentEdit.edits, in: document.snapshot)
      }
    }
  }

  private func validateDocumentSymbols(
    _ symbols: [EditorDocumentSymbol], in snapshot: TextSnapshot
  ) throws {
    for symbol in symbols {
      _ = try snapshot.nsRange(for: symbol.range)
      _ = try snapshot.nsRange(for: symbol.selectionRange)
      try validateDocumentSymbols(symbol.children, in: snapshot)
    }
  }

  private func synchronizationKind() async throws -> TextDocumentSyncKind {
    let response = try await initialize()
    switch response.capabilities.textDocumentSync {
    case .none: return .none
    case .some(.optionA(let options)): return options.change ?? .none
    case .some(.optionB(let kind)): return kind
    }
  }
  private func supportsOpenClose() -> Bool {
    guard let sync = initialization?.capabilities.textDocumentSync else { return false }
    switch sync {
    case .optionA(let options): return options.openClose ?? false
    case .optionB: return false
    }
  }

  private func saveSupported() -> Bool {
    guard let sync = initialization?.capabilities.textDocumentSync else { return false }
    switch sync {
    case .optionA(let options): return options.effectiveSave != nil
    case .optionB: return false
    }
  }

  private func saveIncludeText() -> Bool {
    guard let sync = initialization?.capabilities.textDocumentSync else { return false }
    switch sync {
    case .optionA(let options): return options.effectiveSave?.includeText ?? false
    case .optionB: return false
    }
  }
  private func cacheCompletion(_ item: LanguageServerProtocol.CompletionItem, for uri: URL) -> UUID
  {
    let id = UUID()
    completionCache[id] = CachedCompletion(uri: uri, item: item)
    completionCacheOrder.append(id)
    while completionCacheOrder.count > completionCacheLimit {
      completionCache.removeValue(forKey: completionCacheOrder.removeFirst())
    }
    return id
  }

  private func removeCachedCompletions(for uri: URL) {
    let removed = Set(completionCache.compactMap { $0.value.uri == uri ? $0.key : nil })
    for id in removed { completionCache.removeValue(forKey: id) }
    completionCacheOrder.removeAll { removed.contains($0) }
  }

  private func validateCompletion(_ completion: Completion, in snapshot: TextSnapshot) throws {
    if let edit = completion.primaryEdit { _ = try snapshot.nsRange(for: edit.range) }
    for edit in completion.additionalEdits { _ = try snapshot.nsRange(for: edit.range) }
  }

  private func semanticLegend() -> SemanticTokensLegend? {
    if let provider = initialization?.capabilities.semanticTokensProvider {
      switch provider {
      case .optionA(let options): return options.legend
      case .optionB(let registration): return registration.legend
      }
    }
    return dynamicOptions(
      for: "textDocument/semanticTokens", as: SemanticTokensRegistrationOptions.self
    ).last?.legend
  }
}
