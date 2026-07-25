import JSONRPC
import LanguageServerProtocol
import XCTest

@testable import EditorCore
@testable import EditorLSP

private enum MockLSPError: Error { case failure }
private actor MockLSPTransport: LSPServerTransport {
  nonisolated let events: AsyncStream<ServerEvent>
  nonisolated let prehandlesCapabilityRegistrationRequests: Bool
  private let continuation: AsyncStream<ServerEvent>.Continuation
  var response: InitializationResponse
  var initializeCount = 0
  var opens: [DidOpenTextDocumentParams] = []
  var changes: [DidChangeTextDocumentParams] = []
  var saves: [DidSaveTextDocumentParams] = []
  var closes: [DidCloseTextDocumentParams] = []
  var failOpen = false, failChange = false, failClose = false
  var openDelay: Duration = .zero
  var completionResponse: CompletionResponse = nil
  var hoverResponse: HoverResponse = nil
  var definitionResponse: DefinitionResponse = nil
  var referenceResponse: ReferenceResponse = nil
  var formattingResponse: FormattingResult = nil
  var prepareRenameResponse: PrepareRenameResponse = nil
  var renameResponse: RenameResponse = nil
  var semanticResponse: SemanticTokensResponse = nil
  var signatureResponse: SignatureHelpResponse = nil
  var symbolResponse: DocumentSymbolResponse = nil
  var codeActionResponse: CodeActionResponse = nil
  var inlayHintResponse: InlayHintResponse = nil
  var resolvedCompletionDetail: String?
  var resolvedCompletionCount = 0
  var executedCommands: [ExecuteCommandParams] = []

  init(
    capabilities: ServerCapabilities,
    prehandlesCapabilityRegistrationRequests: Bool = false
  ) {
    self.prehandlesCapabilityRegistrationRequests = prehandlesCapabilityRegistrationRequests
    self.response = InitializationResponse(
      capabilities: capabilities, serverInfo: ServerInfo(name: "mock", version: "1"))
    (events, continuation) = AsyncStream.makeStream(of: ServerEvent.self)
  }
  func initialize() async throws -> InitializationResponse {
    initializeCount += 1
    try await Task.sleep(for: .milliseconds(2))
    return response
  }
  func shutdown() { continuation.finish() }
  func didOpen(_ params: DidOpenTextDocumentParams) async throws {
    if openDelay > .zero { try await Task.sleep(for: openDelay) }
    if failOpen { throw MockLSPError.failure }
    opens.append(params)
  }
  func didChange(_ params: DidChangeTextDocumentParams) throws {
    if failChange { throw MockLSPError.failure }
    changes.append(params)
  }
  func didSave(_ params: DidSaveTextDocumentParams) { saves.append(params) }
  func didClose(_ params: DidCloseTextDocumentParams) throws {
    if failClose { throw MockLSPError.failure }
    closes.append(params)
  }
  func completion(_ params: CompletionParams) -> CompletionResponse { completionResponse }
  func resolveCompletionItem(_ item: LanguageServerProtocol.CompletionItem)
    -> LanguageServerProtocol.CompletionItem
  {
    resolvedCompletionCount += 1
    return LanguageServerProtocol.CompletionItem(
      label: item.label,
      kind: item.kind,
      detail: resolvedCompletionDetail ?? item.detail,
      documentation: item.documentation,
      deprecated: item.deprecated,
      preselect: item.preselect,
      sortText: item.sortText,
      filterText: item.filterText,
      insertText: item.insertText,
      insertTextFormat: item.insertTextFormat,
      textEdit: item.textEdit,
      additionalTextEdits: item.additionalTextEdits,
      commitCharacters: item.commitCharacters,
      command: item.command,
      data: item.data
    )
  }
  func executeCommand(_ params: ExecuteCommandParams) -> LSPAny {
    executedCommands.append(params)
    return .hash(["ok": .bool(true)])
  }
  func hover(_ params: TextDocumentPositionParams) -> HoverResponse { hoverResponse }
  func definition(_ params: TextDocumentPositionParams) -> DefinitionResponse { definitionResponse }
  func references(_ params: ReferenceParams) -> ReferenceResponse { referenceResponse }
  func formatting(_ params: DocumentFormattingParams) -> FormattingResult { formattingResponse }
  func rangeFormatting(_ params: DocumentRangeFormattingParams) -> FormattingResult {
    formattingResponse
  }
  func prepareRename(_ params: PrepareRenameParams) -> PrepareRenameResponse {
    prepareRenameResponse
  }
  func rename(_ params: RenameParams) -> RenameResponse { renameResponse }
  func semanticTokensFull(_ params: SemanticTokensParams) -> SemanticTokensResponse {
    semanticResponse
  }
  func signatureHelp(_ params: TextDocumentPositionParams) -> SignatureHelpResponse {
    signatureResponse
  }
  func documentSymbols(_ params: DocumentSymbolParams) -> DocumentSymbolResponse { symbolResponse }
  func codeActions(_ params: CodeActionParams) -> CodeActionResponse { codeActionResponse }
  func inlayHints(_ params: InlayHintParams) -> InlayHintResponse { inlayHintResponse }
  func emit(_ event: ServerEvent) { continuation.yield(event) }
  func setFailOpen(_ value: Bool) { failOpen = value }
  func setOpenDelay(_ value: Duration) { openDelay = value }
  func setFailChange(_ value: Bool) { failChange = value }
  func setFailClose(_ value: Bool) { failClose = value }
  func configureCompletion(_ value: CompletionResponse) { completionResponse = value }
  func configureResolvedCompletionDetail(_ value: String?) { resolvedCompletionDetail = value }
  func configureHover(_ value: HoverResponse) { hoverResponse = value }
  func configureDefinition(_ value: DefinitionResponse) { definitionResponse = value }
  func configureReferences(_ value: ReferenceResponse) { referenceResponse = value }
  func configureFormatting(_ value: FormattingResult) { formattingResponse = value }
  func configureRename(prepare: PrepareRenameResponse, edit: RenameResponse) {
    prepareRenameResponse = prepare
    renameResponse = edit
  }
  func configureSemantic(_ value: SemanticTokensResponse) { semanticResponse = value }
  func configureAdvanced(
    signature: SignatureHelpResponse,
    symbols: DocumentSymbolResponse,
    actions: CodeActionResponse,
    hints: InlayHintResponse
  ) {
    signatureResponse = signature
    symbolResponse = symbols
    codeActionResponse = actions
    inlayHintResponse = hints
  }
}

private actor ErrorOnlyReplyRecorder {
  private var values: [Bool] = []
  private var waiters: [CheckedContinuation<Bool, Never>] = []

  func record(_ success: Bool) {
    if let waiter = waiters.first {
      waiters.removeFirst()
      waiter.resume(returning: success)
    } else {
      values.append(success)
    }
  }

  func next() async -> Bool {
    if !values.isEmpty { return values.removeFirst() }
    return await withCheckedContinuation { waiters.append($0) }
  }
}

private actor WorkspaceFolderReplyRecorder {
  private var value: WorkspaceFoldersResponse?
  private var received = false
  private var waiter: CheckedContinuation<WorkspaceFoldersResponse?, Never>?

  func record(_ result: Result<WorkspaceFoldersResponse, AnyJSONRPCResponseError>) {
    let response = try? result.get()
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: response)
    } else {
      value = response
      received = true
    }
  }

  func next() async -> WorkspaceFoldersResponse? {
    if received {
      received = false
      return value
    }
    return await withCheckedContinuation { waiter = $0 }
  }
}

private actor ConfigurationReplyRecorder {
  private var value: [LSPAny]?
  private var waiter: CheckedContinuation<[LSPAny]?, Never>?

  func record(_ result: Result<[LSPAny], AnyJSONRPCResponseError>) {
    let response = try? result.get()
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: response)
    } else {
      value = response
    }
  }

  func next() async -> [LSPAny]? {
    if let value {
      self.value = nil
      return value
    }
    return await withCheckedContinuation { waiter = $0 }
  }
}

private actor WorkspaceEditReplyRecorder {
  private var value: ApplyWorkspaceEditResult?
  private var waiter: CheckedContinuation<ApplyWorkspaceEditResult?, Never>?

  func record(_ result: Result<ApplyWorkspaceEditResult, AnyJSONRPCResponseError>) {
    let response = try? result.get()
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: response)
    } else {
      value = response
    }
  }

  func next() async -> ApplyWorkspaceEditResult? {
    if let value {
      self.value = nil
      return value
    }
    return await withCheckedContinuation { waiter = $0 }
  }
}

private actor ConfigurationInvocationRecorder {
  private(set) var items: [LanguageServerConfigurationItem] = []

  func record(_ items: [LanguageServerConfigurationItem]) {
    self.items = items
  }
}

private actor WorkspaceEditInvocationRecorder {
  private(set) var edits: [EditorWorkspaceEdit] = []
  private(set) var labels: [String?] = []

  func apply(_ edit: EditorWorkspaceEdit, label: String?) -> Bool {
    edits.append(edit)
    labels.append(label)
    return true
  }
}

private func capabilities(
  sync: TextDocumentSyncKind = .incremental,
  includeTextOnSave: Bool = false,
  semantic: Bool = false,
  advanced: Bool = false
) -> ServerCapabilities {
  var value = ServerCapabilities()
  value.completionProvider = CompletionOptions(
    workDoneProgress: false,
    triggerCharacters: ["."],
    allCommitCharacters: nil,
    resolveProvider: false,
    completionItem: nil
  )
  value.hoverProvider = .optionA(true)
  value.definitionProvider = .optionA(true)
  value.referencesProvider = .optionA(true)
  value.documentFormattingProvider = .optionA(true)
  value.documentRangeFormattingProvider = .optionA(true)
  value.renameProvider = .optionB(RenameOptions(prepareProvider: true))
  value.textDocumentSync = .optionA(
    TextDocumentSyncOptions(
      openClose: true, change: sync, save: .optionB(SaveOptions(includeText: includeTextOnSave))
    ))
  if semantic {
    value.semanticTokensProvider = .optionA(
      SemanticTokensOptions(
        legend: SemanticTokensLegend(
          tokenTypes: ["type", "variable"], tokenModifiers: ["declaration"]), full: .optionA(true)
      ))
  }
  if advanced {
    value.signatureHelpProvider = SignatureHelpOptions(triggerCharacters: ["(", ","])
    value.documentSymbolProvider = .optionA(true)
    value.codeActionProvider = .optionA(true)
    value.inlayHintProvider = .optionA(true)
  }
  return value
}

private actor ReplyCountRecorder {
  private var count = 0

  func record() { count += 1 }
  func value() -> Int { count }
}

final class LSPDocumentServiceTests: XCTestCase {
  let uri = URL(fileURLWithPath: "/tmp/Test.swift")

  func testConcurrentInitializationIsShared() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let service = LSPDocumentService(transport: transport)
    async let a = service.initialize()
    async let b = service.initialize()
    _ = try await (a, b)
    let count = await transport.initializeCount
    XCTAssertEqual(count, 1)
  }

  func testOpenIsTransactional() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    await transport.setFailOpen(true)
    let service = LSPDocumentService(transport: transport)
    do {
      try await service.open(
        uri: uri, languageID: "swift", snapshot: TextSnapshot(text: "let x = 1"))
      XCTFail()
    } catch {}
    let opened = await service.openedDocumentURIs
    XCTAssertTrue(opened.isEmpty)
  }

  func testIncrementalChangeUsesRangeAndVersion() async throws {
    let transport = MockLSPTransport(capabilities: capabilities(sync: .incremental))
    let service = LSPDocumentService(transport: transport)
    var buffer = TextBuffer(text: "let x = 1")
    try await service.open(uri: uri, languageID: "swift", snapshot: buffer.snapshot)
    let change = try buffer.apply(
      .init(
        range: .init(start: .init(line: 0, utf16Column: 4), end: .init(line: 0, utf16Column: 5)),
        replacement: "value"))
    try await service.change(uri: uri, change: change)
    let firstChange = await transport.changes.first
    let sent = try XCTUnwrap(firstChange)
    XCTAssertEqual(sent.textDocument.version, 1)
    XCTAssertEqual(sent.contentChanges.first?.range?.start.character, 4)
    XCTAssertEqual(sent.contentChanges.first?.rangeLength, 1)
  }

  func testFullSyncSendsWholeDocument() async throws {
    let transport = MockLSPTransport(capabilities: capabilities(sync: .full))
    let service = LSPDocumentService(transport: transport)
    var buffer = TextBuffer(text: "a")
    try await service.open(uri: uri, languageID: "swift", snapshot: buffer.snapshot)
    let change = try buffer.apply(.init(range: .init(start: .zero, end: .zero), replacement: "b"))
    try await service.change(uri: uri, change: change)
    let firstContent = await transport.changes.first?.contentChanges.first
    let content = try XCTUnwrap(firstContent)
    XCTAssertNil(content.range)
    XCTAssertEqual(content.text, "ba")
  }

  func testNoneSyncTracksLocallyWithoutNotification() async throws {
    let transport = MockLSPTransport(capabilities: capabilities(sync: .none))
    let service = LSPDocumentService(transport: transport)
    var buffer = TextBuffer(text: "a")
    try await service.open(uri: uri, languageID: "swift", snapshot: buffer.snapshot)
    try await service.change(
      uri: uri,
      change: buffer.apply(.init(range: .init(start: .zero, end: .zero), replacement: "b")))
    let changes = await transport.changes
    XCTAssertTrue(changes.isEmpty)
  }

  func testStaleChangeRejectedBeforeTransport() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let service = LSPDocumentService(transport: transport)
    try await service.open(
      uri: uri, languageID: "swift", snapshot: TextSnapshot(text: "a", version: 2))
    var buffer = TextBuffer(text: "a", version: 1)
    let change = try buffer.apply(.init(range: .init(start: .zero, end: .zero), replacement: "b"))
    do {
      try await service.change(uri: uri, change: change)
      XCTFail()
    } catch {
      XCTAssertEqual(error as? LSPDocumentServiceError, .staleVersion(expected: 2, received: 1))
    }
  }

  func testFailedChangeDoesNotAdvanceSnapshot() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let service = LSPDocumentService(transport: transport)
    var buffer = TextBuffer(text: "a")
    try await service.open(uri: uri, languageID: "swift", snapshot: buffer.snapshot)
    await transport.setFailChange(true)
    let first = try buffer.apply(.init(range: .init(start: .zero, end: .zero), replacement: "b"))
    do {
      try await service.change(uri: uri, change: first)
      XCTFail()
    } catch {}
    await transport.setFailChange(false)
    var original = TextBuffer(text: "a")
    let retry = try original.apply(.init(range: .init(start: .zero, end: .zero), replacement: "c"))
    try await service.change(uri: uri, change: retry)
    let changeCount = await transport.changes.count
    XCTAssertEqual(changeCount, 1)
  }

  func testSaveHonorsIncludeText() async throws {
    let transport = MockLSPTransport(capabilities: capabilities(includeTextOnSave: true))
    let service = LSPDocumentService(transport: transport)
    let snapshot = TextSnapshot(text: "let x = 1")
    try await service.open(uri: uri, languageID: "swift", snapshot: snapshot)
    try await service.save(uri: uri, snapshot: snapshot)
    let savedText = await transport.saves.first?.text
    XCTAssertEqual(savedText, snapshot.text)
  }

  func testCloseFailureRetainsOpenDocument() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let service = LSPDocumentService(transport: transport)
    try await service.open(uri: uri, languageID: "swift", snapshot: TextSnapshot(text: ""))
    await transport.setFailClose(true)
    do {
      try await service.close(uri: uri)
      XCTFail()
    } catch {}
    let opened = await service.openedDocumentURIs
    XCTAssertEqual(opened, [uri])
  }

  func testCompletionHoverAndDefinitionConversion() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    await transport.configureCompletion(
      .optionA([
        LanguageServerProtocol.CompletionItem(
          label: "print", kind: .function,
          documentation: .optionB(.init(kind: .markdown, value: "**print**")),
          insertText: "print(${1:value})", insertTextFormat: .snippet,
          textEdit: .optionA(
            .init(range: .init(startPair: (0, 0), endPair: (0, 1)), newText: "print"))
        )
      ]))
    await transport.configureHover(
      Hover(contents: "hover", range: .init(startPair: (0, 0), endPair: (0, 1))))
    await transport.configureDefinition(
      .optionA(Location(uri: uri.absoluteString, range: .init(startPair: (0, 0), endPair: (0, 1)))))
    let service = LSPDocumentService(transport: transport)
    try await service.open(uri: uri, languageID: "swift", snapshot: TextSnapshot(text: "p"))
    let completions = try await service.completions(uri: uri, at: .init(line: 0, utf16Column: 1))
    XCTAssertEqual(completions.first?.kind, .function)
    XCTAssertEqual(completions.first?.insertTextFormat, .snippet)
    let hover = try await service.hover(uri: uri, at: .zero)
    XCTAssertEqual(hover?.markdown, "hover")
    let definitions = try await service.definitions(uri: uri, at: .zero)
    XCTAssertEqual(definitions.first?.range.start.line, 0)
  }

  func testReferencesAndFormatting() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    await transport.configureReferences([
      Location(uri: uri.absoluteString, range: .init(startPair: (0, 0), endPair: (0, 1)))
    ])
    await transport.configureFormatting([
      LanguageServerProtocol.TextEdit(
        range: .init(startPair: (0, 0), endPair: (0, 1)), newText: "x")
    ])
    let service = LSPDocumentService(transport: transport)
    try await service.open(uri: uri, languageID: "swift", snapshot: TextSnapshot(text: "a"))
    let references = try await service.references(uri: uri, at: .zero, includeDeclaration: true)
    XCTAssertEqual(references.count, 1)
    let formatting = try await service.formatting(uri: uri, options: .init())
    XCTAssertEqual(formatting.first?.replacement, "x")
  }

  func testRenameAndWorkspaceOperations() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let range = LSPRange(startPair: (0, 0), endPair: (0, 1))
    await transport.configureRename(
      prepare: .optionB(.init(range: range, placeholder: "x")),
      edit: WorkspaceEdit(
        changes: [uri.absoluteString: [.init(range: range, newText: "y")]], documentChanges: nil)
    )
    let service = LSPDocumentService(transport: transport)
    try await service.open(uri: uri, languageID: "swift", snapshot: TextSnapshot(text: "x"))
    let preparation = try await service.prepareRename(uri: uri, at: .zero)
    XCTAssertEqual(
      preparation,
      .range(.init(start: .zero, end: .init(line: 0, utf16Column: 1)), placeholder: "x"))
    let rename = try await service.rename(uri: uri, at: .zero, newName: "y")
    XCTAssertEqual(rename?.documentEdits.first?.edits.first?.replacement, "y")
  }

  func testSemanticTokenDecoding() async throws {
    let transport = MockLSPTransport(capabilities: capabilities(semantic: true))
    await transport.configureSemantic(SemanticTokens(data: [0, 2, 3, 1, 1, 1, 1, 2, 0, 0]))
    let service = LSPDocumentService(transport: transport)
    try await service.open(
      uri: uri, languageID: "swift", snapshot: TextSnapshot(text: "  abc\n xy"))
    let tokens = try await service.semanticHighlights(uri: uri)
    XCTAssertEqual(tokens.count, 2)
    XCTAssertEqual(tokens[0].tokenType, "variable")
    XCTAssertEqual(tokens[0].modifiers, ["declaration"])
    XCTAssertEqual(tokens[1].range.start, .init(line: 1, utf16Column: 1))
  }

  func testSignatureSymbolsCodeActionsAndInlayHints() async throws {
    let transport = MockLSPTransport(capabilities: capabilities(advanced: true))
    let symbolRange = LSPRange(startPair: (0, 0), endPair: (0, 10))
    await transport.configureAdvanced(
      signature: SignatureHelp(
        signatures: [
          SignatureInformation(
            label: "sum(_:_:) → Int",
            documentation: .optionB(.init(kind: .markdown, value: "Adds values")),
            parameters: [
              ParameterInformation(label: .optionB([0, 3])),
              ParameterInformation(label: .optionA("rhs")),
            ],
            activeParameter: 1
          )
        ],
        activeSignature: 0,
        activeParameter: 1
      ),
      symbols: .optionA([
        LanguageServerProtocol.DocumentSymbol(
          name: "Thing",
          detail: "struct",
          kind: .struct,
          range: symbolRange,
          selectionRange: .init(startPair: (0, 7), endPair: (0, 10))
        )
      ]),
      actions: [
        .optionA(
          Command(
            title: "Organize", command: "source.organizeImports", arguments: [.string("swift")])),
        .optionB(
          CodeAction(
            title: "Fix",
            kind: "quickfix",
            isPreferred: true,
            edit: WorkspaceEdit(
              changes: [
                uri.absoluteString: [
                  .init(
                    range: .init(startPair: (0, 0), endPair: (0, 0)),
                    newText: "import Foundation\\n")
                ]
              ],
              documentChanges: nil
            )
          )),
      ],
      hints: [
        InlayHint(
          position: .init(line: 0, character: 3),
          label: .optionB([.init(value: ": Int")]),
          kind: .type,
          textEdits: [.init(range: .init(startPair: (0, 3), endPair: (0, 3)), newText: ": Int")],
          tooltip: .optionB(.init(kind: .markdown, value: "Inferred type")),
          paddingLeft: true
        )
      ]
    )
    let service = LSPDocumentService(transport: transport)
    let text = "sum value "
    try await service.open(uri: uri, languageID: "swift", snapshot: TextSnapshot(text: text))

    let signature = try await service.signatureHelp(uri: uri, at: .init(line: 0, utf16Column: 3))
    let symbols = try await service.documentSymbols(uri: uri)
    let actions = try await service.codeActions(
      uri: uri,
      range: .init(start: .zero, end: .init(line: 0, utf16Column: 3))
    )
    let hints = try await service.inlayHints(
      uri: uri,
      range: .init(start: .zero, end: .init(line: 0, utf16Column: text.utf16.count))
    )

    XCTAssertEqual(signature?.signatures.first?.documentation, "Adds values")
    XCTAssertEqual(signature?.signatures.first?.parameters.first?.label, "sum")
    XCTAssertEqual(symbols.first?.name, "Thing")
    XCTAssertEqual(symbols.first?.kind, .struct)
    XCTAssertEqual(actions.first?.command?.arguments, [.string("swift")])
    XCTAssertEqual(
      actions.last?.edit?.documentEdits.first?.edits.first?.replacement, "import Foundation\\n")
    XCTAssertEqual(hints.first?.label, ": Int")
    XCTAssertEqual(hints.first?.tooltip, "Inferred type")
  }

  func testAdvancedFeatureCapabilityGating() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let service = LSPDocumentService(transport: transport)
    try await service.open(uri: uri, languageID: "swift", snapshot: TextSnapshot(text: "x"))
    do {
      _ = try await service.documentSymbols(uri: uri)
      XCTFail("Expected unsupported feature")
    } catch {
      XCTAssertEqual(error as? LanguageFeatureError, .unsupported("textDocument/documentSymbol"))
    }
  }

  func testCompletionResolutionCachesAreIndependentAcrossDocuments() async throws {
    var advertised = capabilities()
    advertised.completionProvider = CompletionOptions(
      workDoneProgress: false,
      triggerCharacters: nil,
      allCommitCharacters: nil,
      resolveProvider: true,
      completionItem: nil
    )
    let transport = MockLSPTransport(capabilities: advertised)
    await transport.configureCompletion(
      .optionA([
        LanguageServerProtocol.CompletionItem(label: "value")
      ]))
    await transport.configureResolvedCompletionDetail("resolved")
    let service = LSPDocumentService(transport: transport)
    let otherURI = URL(fileURLWithPath: "/tmp/Other.swift")
    try await service.open(uri: uri, languageID: "swift", snapshot: TextSnapshot(text: "v"))
    try await service.open(uri: otherURI, languageID: "swift", snapshot: TextSnapshot(text: "v"))

    let firstBatch = try await service.completions(
      uri: uri, at: .init(line: 0, utf16Column: 1)
    )
    let first = try XCTUnwrap(firstBatch.first)
    _ = try await service.completions(
      uri: otherURI, at: .init(line: 0, utf16Column: 1)
    )
    let resolved = try await service.resolveCompletion(first)

    XCTAssertEqual(resolved.detail, "resolved")
    let resolveCount = await transport.resolvedCompletionCount
    XCTAssertEqual(resolveCount, 1)
  }

  func testExecuteCommandRoundTripsEditorJSON() async throws {
    var advertised = capabilities()
    advertised.executeCommandProvider = ExecuteCommandOptions(commands: ["source.fix"])
    let transport = MockLSPTransport(capabilities: advertised)
    let service = LSPDocumentService(transport: transport)
    _ = try await service.initialize()

    let result = try await service.executeCommand(
      EditorCommand(
        title: "Fix",
        command: "source.fix",
        arguments: [.string("swift"), .object(["enabled": .bool(true)])]
      )
    )

    XCTAssertEqual(result, .object(["ok": .bool(true)]))
    let executedCommands = await transport.executedCommands
    let command = try XCTUnwrap(executedCommands.first)
    XCTAssertEqual(command.command, "source.fix")
    XCTAssertEqual(command.arguments, [.string("swift"), .hash(["enabled": .bool(true)])])
  }

  func testDynamicRegistrationAndUnregistrationControlCapabilities() async throws {
    var advertised = capabilities()
    advertised.hoverProvider = nil
    let transport = MockLSPTransport(capabilities: advertised)
    await transport.configureHover(
      Hover(contents: "dynamic hover", range: .init(startPair: (0, 0), endPair: (0, 1)))
    )
    let service = LSPDocumentService(transport: transport)
    try await service.open(uri: uri, languageID: "swift", snapshot: TextSnapshot(text: "x"))

    do {
      _ = try await service.hover(uri: uri, at: .zero)
      XCTFail("Expected hover to be unavailable before registration")
    } catch {
      XCTAssertEqual(error as? LanguageFeatureError, .unsupported("textDocument/hover"))
    }

    let registrationReply = ErrorOnlyReplyRecorder()
    await transport.emit(
      .request(
        id: 1,
        request: .clientRegisterCapability(
          RegistrationParams(registrations: [
            Registration(id: "hover", method: "textDocument/hover")
          ]),
          { error in await registrationReply.record(error == nil) }
        )
      ))
    let registrationSucceeded = await registrationReply.next()
    XCTAssertTrue(registrationSucceeded)
    let dynamicHover = try await service.hover(uri: uri, at: .zero)
    XCTAssertEqual(dynamicHover?.markdown, "dynamic hover")

    let unregisterData = Data(
      #"{"unregistrations":[{"id":"hover","method":"textDocument/hover"}]}"#.utf8
    )
    let unregistration = try JSONDecoder().decode(UnregistrationParams.self, from: unregisterData)
    let unregistrationReply = ErrorOnlyReplyRecorder()
    await transport.emit(
      .request(
        id: 2,
        request: .clientUnregisterCapability(
          unregistration,
          { error in await unregistrationReply.record(error == nil) }
        )
      ))
    let unregistrationSucceeded = await unregistrationReply.next()
    XCTAssertTrue(unregistrationSucceeded)
    do {
      _ = try await service.hover(uri: uri, at: .zero)
      XCTFail("Expected hover to be unavailable after unregistration")
    } catch {
      XCTAssertEqual(error as? LanguageFeatureError, .unsupported("textDocument/hover"))
    }
  }

  func testPrehandledCapabilityRegistrationIsNotRepliedToTwice() async throws {
    var advertised = capabilities()
    advertised.hoverProvider = nil
    let transport = MockLSPTransport(
      capabilities: advertised,
      prehandlesCapabilityRegistrationRequests: true
    )
    await transport.configureHover(
      Hover(contents: "dynamic hover", range: .init(startPair: (0, 0), endPair: (0, 1)))
    )
    let service = LSPDocumentService(transport: transport)
    try await service.open(uri: uri, languageID: "rust", snapshot: TextSnapshot(text: "x"))
    let replies = ReplyCountRecorder()

    await transport.emit(
      .request(
        id: 7,
        request: .clientRegisterCapability(
          RegistrationParams(registrations: [
            Registration(id: "hover", method: "textDocument/hover")
          ]),
          { _ in await replies.record() }
        )
      ))
    try await Task.sleep(for: .milliseconds(20))

    let replyCount = await replies.value()
    XCTAssertEqual(replyCount, 0)
    let hover = try await service.hover(uri: uri, at: .zero)
    XCTAssertEqual(hover?.markdown, "dynamic hover")
  }

  func testChangeWaitsForConcurrentDocumentOpen() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    await transport.setOpenDelay(.milliseconds(40))
    let service = LSPDocumentService(transport: transport)
    var buffer = TextBuffer(text: "fn main() {}")
    let oldSnapshot = buffer.snapshot
    let change = try buffer.apply(
      TextEdit(
        range: EditorTextRange(start: .zero, end: .zero),
        replacement: "pub "
      ))

    let documentURI = uri
    let openTask = Task {
      try await service.open(uri: documentURI, languageID: "rust", snapshot: oldSnapshot)
    }
    try await Task.sleep(for: .milliseconds(5))
    try await service.change(uri: documentURI, change: change)
    try await openTask.value

    let openCount = await transport.opens.count
    let changeCount = await transport.changes.count
    XCTAssertEqual(openCount, 1)
    XCTAssertEqual(changeCount, 1)
  }

  func testMalformedRangeResponsesAreRejected() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    await transport.configureHover(
      Hover(contents: "invalid", range: .init(startPair: (9, 0), endPair: (9, 1)))
    )
    await transport.configureFormatting([
      LanguageServerProtocol.TextEdit(
        range: .init(startPair: (0, 0), endPair: (0, 99)), newText: "bad"
      )
    ])
    let service = LSPDocumentService(transport: transport)
    try await service.open(uri: uri, languageID: "swift", snapshot: TextSnapshot(text: "x"))

    do {
      _ = try await service.hover(uri: uri, at: .zero)
      XCTFail("Expected invalid hover range")
    } catch {
      XCTAssertTrue(error is TextBufferError)
    }
    do {
      _ = try await service.formatting(uri: uri, options: .init())
      XCTFail("Expected invalid formatting edit")
    } catch {
      XCTAssertTrue(error is TextBufferError)
    }
  }

  func testWorkspaceFoldersRequestReturnsConfiguredFolders() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let folder = WorkspaceFolder(uri: "file:///tmp/Workspace", name: "Workspace")
    let service = LSPDocumentService(transport: transport, workspaceFolders: [folder])
    _ = try await service.initialize()
    let reply = WorkspaceFolderReplyRecorder()

    await transport.emit(
      .request(
        id: 3,
        request: .workspaceFolders { result in await reply.record(result) }
      ))

    let folders = await reply.next()
    XCTAssertEqual(folders, [folder])
  }

  func testWindowMessagesArePublishedAsEditorNativeEvents() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let service = LSPDocumentService(transport: transport)
    _ = try await service.initialize()
    let stream = service.messages
    let messageTask = Task<LanguageServerMessage?, Never> {
      for await message in stream { return message }
      return nil
    }

    await transport.emit(
      .notification(
        .windowLogMessage(
          LogMessageParams(type: .warning, message: "Indexing delayed")
        )))

    let message = await messageTask.value
    XCTAssertEqual(
      message,
      LanguageServerMessage(kind: .warning, message: "Indexing delayed")
    )
  }

  func testWorkspaceConfigurationUsesEditorNativeProviderAndNormalizesCount() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let observed = ConfigurationInvocationRecorder()
    let service = LSPDocumentService(
      transport: transport,
      configurationProvider: { items in
        await observed.record(items)
        return [.object(["enabled": .bool(true)])]
      }
    )
    _ = try await service.initialize()
    let reply = ConfigurationReplyRecorder()
    let items = [
      ConfigurationItem(scopeUri: "file:///tmp/Workspace", section: "swift"),
      ConfigurationItem(scopeUri: nil, section: "editor"),
    ]

    await transport.emit(
      .request(
        id: 4,
        request: .workspaceConfiguration(
          ConfigurationParams(items: items),
          { result in await reply.record(result) }
        )
      ))

    let values = await reply.next()
    XCTAssertEqual(values, [.hash(["enabled": .bool(true)]), .null])
    let received = await observed.items
    XCTAssertEqual(received.count, 2)
    XCTAssertEqual(received[0].scopeURI?.absoluteString, "file:///tmp/Workspace")
    XCTAssertEqual(received[0].section, "swift")
  }

  func testServerInitiatedWorkspaceEditIsValidatedAndHandled() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let invocation = WorkspaceEditInvocationRecorder()
    let service = LSPDocumentService(
      transport: transport,
      workspaceEditHandler: { edit, label in
        await invocation.apply(edit, label: label)
      }
    )
    try await service.open(uri: uri, languageID: "swift", snapshot: TextSnapshot(text: "let x = 1"))
    let reply = WorkspaceEditReplyRecorder()
    let edit = WorkspaceEdit(
      changes: [
        uri.absoluteString: [
          LanguageServerProtocol.TextEdit(
            range: .init(startPair: (0, 4), endPair: (0, 5)),
            newText: "value"
          )
        ]
      ],
      documentChanges: nil
    )

    await transport.emit(
      .request(
        id: 5,
        request: .workspaceApplyEdit(
          ApplyWorkspaceEditParams(label: "Rename", edit: edit),
          { result in await reply.record(result) }
        )
      ))

    let result = await reply.next()
    XCTAssertEqual(result?.applied, true)
    XCTAssertNil(result?.failureReason)
    let edits = await invocation.edits
    let labels = await invocation.labels
    XCTAssertEqual(labels, ["Rename"])
    XCTAssertEqual(edits.first?.documentEdits.first?.edits.first?.replacement, "value")
  }

  func testServerInitiatedWorkspaceEditDeclinesWhenNoHandlerIsConfigured() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let service = LSPDocumentService(transport: transport)
    _ = try await service.initialize()
    let reply = WorkspaceEditReplyRecorder()
    let edit = WorkspaceEdit(changes: [:], documentChanges: nil)

    await transport.emit(
      .request(
        id: 6,
        request: .workspaceApplyEdit(
          ApplyWorkspaceEditParams(edit: edit),
          { result in await reply.record(result) }
        )
      ))

    let result = await reply.next()
    XCTAssertEqual(result?.applied, false)
    XCTAssertNotNil(result?.failureReason)
  }

  func testStaleAndClosedDiagnosticsAreIgnored() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let service = LSPDocumentService(transport: transport)
    try await service.open(
      uri: uri, languageID: "swift", snapshot: TextSnapshot(text: "x", version: 2))
    let stream = service.diagnostics
    let task = Task<DiagnosticBatch?, Never> {
      for await value in stream { return value }
      return nil
    }
    await transport.emit(
      .notification(
        .textDocumentPublishDiagnostics(
          .init(
            uri: uri.absoluteString, version: 1,
            diagnostics: [.init(range: .zero, severity: .error, message: "old")]
          ))))
    await transport.emit(
      .notification(
        .textDocumentPublishDiagnostics(
          .init(
            uri: uri.absoluteString, version: 2,
            diagnostics: [.init(range: .zero, severity: .warning, message: "new")]
          ))))
    let batch = await task.value
    XCTAssertEqual(batch?.diagnostics.first?.message, "new")
  }
}

extension LSPDocumentServiceTests {
  func testMissingSynchronizationCapabilitySendsNoLifecycleNotifications() async throws {
    let transport = MockLSPTransport(capabilities: ServerCapabilities())
    let service = LSPDocumentService(transport: transport)
    var buffer = TextBuffer(text: "a")
    try await service.open(uri: uri, languageID: "swift", snapshot: buffer.snapshot)
    let change = try buffer.apply(
      .init(
        range: .init(start: .zero, end: .zero),
        replacement: "b"
      ))
    try await service.change(uri: uri, change: change)
    try await service.save(uri: uri, snapshot: buffer.snapshot)
    try await service.close(uri: uri)

    let opens = await transport.opens
    let changes = await transport.changes
    let saves = await transport.saves
    let closes = await transport.closes
    XCTAssertTrue(opens.isEmpty)
    XCTAssertTrue(changes.isEmpty)
    XCTAssertTrue(saves.isEmpty)
    XCTAssertTrue(closes.isEmpty)
  }

  func testDuplicateOpenIsRejectedBeforeTransport() async throws {
    let transport = MockLSPTransport(capabilities: capabilities())
    let service = LSPDocumentService(transport: transport)
    let snapshot = TextSnapshot(text: "")
    try await service.open(uri: uri, languageID: "swift", snapshot: snapshot)
    do {
      try await service.open(uri: uri, languageID: "swift", snapshot: snapshot)
      XCTFail("Expected duplicate open to fail")
    } catch {
      XCTAssertEqual(error as? LSPDocumentServiceError, .documentAlreadyOpen(uri))
    }
    let opens = await transport.opens
    XCTAssertEqual(opens.count, 1)
  }
}
