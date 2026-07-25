import EditorCore
import Foundation
import LanguageClient
import LanguageServerProtocol

public protocol LSPServerTransport: Sendable {
  var events: AsyncStream<ServerEvent> { get }
  /// True when the underlying transport has already replied to capability registration requests.
  var prehandlesCapabilityRegistrationRequests: Bool { get }
  func initialize() async throws -> InitializationResponse
  func shutdown() async throws
  func didOpen(_ params: DidOpenTextDocumentParams) async throws
  func didChange(_ params: DidChangeTextDocumentParams) async throws
  func didSave(_ params: DidSaveTextDocumentParams) async throws
  func didClose(_ params: DidCloseTextDocumentParams) async throws
  func completion(_ params: CompletionParams) async throws -> CompletionResponse
  func resolveCompletionItem(_ item: LanguageServerProtocol.CompletionItem) async throws
    -> LanguageServerProtocol.CompletionItem
  func hover(_ params: TextDocumentPositionParams) async throws -> HoverResponse
  func definition(_ params: TextDocumentPositionParams) async throws -> DefinitionResponse
  func references(_ params: ReferenceParams) async throws -> ReferenceResponse
  func formatting(_ params: DocumentFormattingParams) async throws -> FormattingResult
  func rangeFormatting(_ params: DocumentRangeFormattingParams) async throws -> FormattingResult
  func prepareRename(_ params: PrepareRenameParams) async throws -> PrepareRenameResponse
  func rename(_ params: RenameParams) async throws -> RenameResponse
  func semanticTokensFull(_ params: SemanticTokensParams) async throws -> SemanticTokensResponse
  func signatureHelp(_ params: TextDocumentPositionParams) async throws -> SignatureHelpResponse
  func documentSymbols(_ params: DocumentSymbolParams) async throws -> DocumentSymbolResponse
  func codeActions(_ params: CodeActionParams) async throws -> CodeActionResponse
  func inlayHints(_ params: InlayHintParams) async throws -> InlayHintResponse
  func executeCommand(_ params: ExecuteCommandParams) async throws -> ExecuteCommandResponse
}

extension LSPServerTransport {
  public var prehandlesCapabilityRegistrationRequests: Bool { false }

  public func resolveCompletionItem(_ item: LanguageServerProtocol.CompletionItem) async throws
    -> LanguageServerProtocol.CompletionItem
  {
    throw LanguageFeatureError.unsupported("completionItem/resolve")
  }
  public func references(_ params: ReferenceParams) async throws -> ReferenceResponse {
    throw LanguageFeatureError.unsupported("textDocument/references")
  }
  public func formatting(_ params: DocumentFormattingParams) async throws -> FormattingResult {
    throw LanguageFeatureError.unsupported("textDocument/formatting")
  }
  public func rangeFormatting(_ params: DocumentRangeFormattingParams) async throws
    -> FormattingResult
  { throw LanguageFeatureError.unsupported("textDocument/rangeFormatting") }
  public func prepareRename(_ params: PrepareRenameParams) async throws -> PrepareRenameResponse {
    throw LanguageFeatureError.unsupported("textDocument/prepareRename")
  }
  public func rename(_ params: RenameParams) async throws -> RenameResponse {
    throw LanguageFeatureError.unsupported("textDocument/rename")
  }
  public func semanticTokensFull(_ params: SemanticTokensParams) async throws
    -> SemanticTokensResponse
  { throw LanguageFeatureError.unsupported("textDocument/semanticTokens/full") }
  public func signatureHelp(_ params: TextDocumentPositionParams) async throws
    -> SignatureHelpResponse
  { throw LanguageFeatureError.unsupported("textDocument/signatureHelp") }
  public func documentSymbols(_ params: DocumentSymbolParams) async throws -> DocumentSymbolResponse
  { throw LanguageFeatureError.unsupported("textDocument/documentSymbol") }
  public func codeActions(_ params: CodeActionParams) async throws -> CodeActionResponse {
    throw LanguageFeatureError.unsupported("textDocument/codeAction")
  }
  public func inlayHints(_ params: InlayHintParams) async throws -> InlayHintResponse {
    throw LanguageFeatureError.unsupported("textDocument/inlayHint")
  }
  public func executeCommand(_ params: ExecuteCommandParams) async throws -> ExecuteCommandResponse
  {
    throw LanguageFeatureError.unsupported("workspace/executeCommand")
  }
}

public final class LanguageClientServer: LSPServerTransport, @unchecked Sendable {
  public let server: InitializingServer
  public init(server: InitializingServer) { self.server = server }
  public var events: AsyncStream<ServerEvent> { server.eventSequence }
  public var prehandlesCapabilityRegistrationRequests: Bool { true }
  public func initialize() async throws -> InitializationResponse {
    try await server.initializeIfNeeded()
  }
  public func shutdown() async throws { try await server.shutdownAndExit() }
  public func didOpen(_ params: DidOpenTextDocumentParams) async throws {
    try await server.textDocumentDidOpen(params)
  }
  public func didChange(_ params: DidChangeTextDocumentParams) async throws {
    try await server.textDocumentDidChange(params)
  }
  public func didSave(_ params: DidSaveTextDocumentParams) async throws {
    try await server.textDocumentDidSave(params)
  }
  public func didClose(_ params: DidCloseTextDocumentParams) async throws {
    try await server.textDocumentDidClose(params)
  }
  public func completion(_ params: CompletionParams) async throws -> CompletionResponse {
    try await server.completion(params)
  }
  public func resolveCompletionItem(_ item: LanguageServerProtocol.CompletionItem) async throws
    -> LanguageServerProtocol.CompletionItem
  {
    try await server.completeItemResolve(item)
  }
  public func hover(_ params: TextDocumentPositionParams) async throws -> HoverResponse {
    try await server.hover(params)
  }
  public func definition(_ params: TextDocumentPositionParams) async throws -> DefinitionResponse {
    try await server.definition(params)
  }
  public func references(_ params: ReferenceParams) async throws -> ReferenceResponse {
    try await server.references(params)
  }
  public func formatting(_ params: DocumentFormattingParams) async throws -> FormattingResult {
    try await server.formatting(params)
  }
  public func rangeFormatting(_ params: DocumentRangeFormattingParams) async throws
    -> FormattingResult
  { try await server.rangeFormatting(params) }
  public func prepareRename(_ params: PrepareRenameParams) async throws -> PrepareRenameResponse {
    try await server.prepareRename(params)
  }
  public func rename(_ params: RenameParams) async throws -> RenameResponse {
    try await server.rename(params)
  }
  public func semanticTokensFull(_ params: SemanticTokensParams) async throws
    -> SemanticTokensResponse
  { try await server.semanticTokensFull(params) }
  public func signatureHelp(_ params: TextDocumentPositionParams) async throws
    -> SignatureHelpResponse
  { try await server.signatureHelp(params) }
  public func documentSymbols(_ params: DocumentSymbolParams) async throws -> DocumentSymbolResponse
  { try await server.documentSymbol(params) }
  public func codeActions(_ params: CodeActionParams) async throws -> CodeActionResponse {
    try await server.codeAction(params)
  }
  public func inlayHints(_ params: InlayHintParams) async throws -> InlayHintResponse {
    try await server.inlayHint(params)
  }
  public func executeCommand(_ params: ExecuteCommandParams) async throws -> ExecuteCommandResponse
  {
    try await server.executeCommand(params)
  }
}
