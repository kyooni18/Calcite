import Foundation

public struct Highlight: Hashable, Sendable {
  public var range: EditorTextRange
  public var capture: String
  public init(range: EditorTextRange, capture: String) {
    self.range = range
    self.capture = capture
  }
}

public enum FoldingRangeKind: String, Hashable, Sendable {
  case comment
  case imports
  case region
}

public struct FoldingRange: Hashable, Sendable {
  public var range: EditorTextRange
  public var kind: FoldingRangeKind?
  public init(range: EditorTextRange, kind: FoldingRangeKind? = nil) {
    self.range = range
    self.kind = kind
  }
}

public struct SemanticHighlight: Hashable, Sendable {
  public var range: EditorTextRange
  public var tokenType: String
  public var modifiers: [String]
  public init(range: EditorTextRange, tokenType: String, modifiers: [String] = []) {
    self.range = range
    self.tokenType = tokenType
    self.modifiers = modifiers
  }
}

public enum CompletionKind: Int, Hashable, Sendable {
  case text = 1
  case method, function, constructor, field, variable, `class`, interface
  case module, property, unit, value, `enum`, keyword, snippet, color, file
  case reference, folder, enumMember, constant, `struct`, event, `operator`, typeParameter
}

public enum EditorCompletionInvocation: Hashable, Sendable {
  /// Lightweight project and document context only. No language-server request is made.
  case automatic
  /// A language-defined trigger such as `.`, `::`, or `->` requested richer completion.
  case triggerCharacter(String)
  /// The user explicitly requested completion, for example with Control-Space.
  case explicit

  public var triggerCharacter: String? {
    if case .triggerCharacter(let value) = self { return value }
    return nil
  }

  public var usesLanguageServices: Bool {
    switch self {
    case .automatic: return false
    case .triggerCharacter, .explicit: return true
    }
  }
}

public enum InsertTextFormat: Int, Hashable, Sendable {
  case plainText = 1
  case snippet = 2
}

public struct Completion: Hashable, Sendable {
  public var label: String
  public var kind: CompletionKind?
  public var detail: String?
  public var documentation: String?
  public var sortText: String?
  public var filterText: String?
  public var insertText: String?
  public var insertTextFormat: InsertTextFormat
  public var primaryEdit: TextEdit?
  public var additionalEdits: [TextEdit]
  public var commitCharacters: [String]
  public var command: EditorCommand?
  /// Opaque identity for deferred completion resolution.
  public var resolutionID: UUID?
  /// Optional identifier of the language service that produced this completion.
  public var serviceIdentifier: String?

  public init(
    label: String,
    kind: CompletionKind? = nil,
    detail: String? = nil,
    documentation: String? = nil,
    sortText: String? = nil,
    filterText: String? = nil,
    insertText: String? = nil,
    insertTextFormat: InsertTextFormat = .plainText,
    primaryEdit: TextEdit? = nil,
    additionalEdits: [TextEdit] = [],
    commitCharacters: [String] = [],
    command: EditorCommand? = nil,
    resolutionID: UUID? = nil,
    serviceIdentifier: String? = nil
  ) {
    self.label = label
    self.kind = kind
    self.detail = detail
    self.documentation = documentation
    self.sortText = sortText
    self.filterText = filterText
    self.insertText = insertText
    self.insertTextFormat = insertTextFormat
    self.primaryEdit = primaryEdit
    self.additionalEdits = additionalEdits
    self.commitCharacters = commitCharacters
    self.command = command
    self.resolutionID = resolutionID
    self.serviceIdentifier = serviceIdentifier
  }
}

public struct HoverResult: Hashable, Sendable {
  public var markdown: String
  public var range: EditorTextRange?
  public init(markdown: String, range: EditorTextRange? = nil) {
    self.markdown = markdown
    self.range = range
  }
}

public struct SourceLocation: Hashable, Sendable {
  public var uri: URL
  public var range: EditorTextRange
  public init(uri: URL, range: EditorTextRange) {
    self.uri = uri
    self.range = range
  }
}

public struct Diagnostic: Hashable, Sendable {
  public enum Severity: Int, Sendable {
    case error = 1
    case warning, information, hint
  }
  public var range: EditorTextRange
  public var message: String
  public var severity: Severity
  public var code: String?
  public var source: String?
  public init(
    range: EditorTextRange, message: String, severity: Severity, code: String? = nil,
    source: String? = nil
  ) {
    self.range = range
    self.message = message
    self.severity = severity
    self.code = code
    self.source = source
  }
}

public enum LanguageServerMessageKind: Int, Hashable, Sendable {
  case error = 1
  case warning = 2
  case information = 3
  case log = 4
}

public struct LanguageServerMessage: Hashable, Sendable {
  public var kind: LanguageServerMessageKind
  public var message: String
  /// Optional identifier of the service that emitted this message.
  public var serviceIdentifier: String?

  public init(
    kind: LanguageServerMessageKind,
    message: String,
    serviceIdentifier: String? = nil
  ) {
    self.kind = kind
    self.message = message
    self.serviceIdentifier = serviceIdentifier
  }
}

public struct DiagnosticBatch: Hashable, Sendable {
  public var uri: URL
  public var version: Int?
  public var diagnostics: [Diagnostic]
  /// Optional identifier of the service that emitted these diagnostics.
  public var serviceIdentifier: String?

  public init(
    uri: URL,
    version: Int?,
    diagnostics: [Diagnostic],
    serviceIdentifier: String? = nil
  ) {
    self.uri = uri
    self.version = version
    self.diagnostics = diagnostics
    self.serviceIdentifier = serviceIdentifier
  }
}

public struct EditorFormattingOptions: Hashable, Sendable {
  public var tabSize: Int
  public var insertSpaces: Bool
  public init(tabSize: Int = 4, insertSpaces: Bool = true) {
    self.tabSize = max(1, tabSize)
    self.insertSpaces = insertSpaces
  }
}

public enum RenamePreparation: Hashable, Sendable {
  case range(EditorTextRange, placeholder: String?)
  case defaultBehavior
}

public struct WorkspaceDocumentEdit: Hashable, Sendable {
  public var uri: URL
  public var version: Int?
  public var edits: [TextEdit]
  public init(uri: URL, version: Int? = nil, edits: [TextEdit]) {
    self.uri = uri
    self.version = version
    self.edits = edits
  }
}

public enum WorkspaceFileOperation: Hashable, Sendable {
  case create(uri: URL, overwrite: Bool?, ignoreIfExists: Bool?)
  case rename(oldURI: URL, newURI: URL, overwrite: Bool?, ignoreIfExists: Bool?)
  case delete(uri: URL, recursive: Bool?, ignoreIfNotExists: Bool?)
}

public struct EditorWorkspaceEdit: Hashable, Sendable {
  public var documentEdits: [WorkspaceDocumentEdit]
  public var fileOperations: [WorkspaceFileOperation]
  public init(
    documentEdits: [WorkspaceDocumentEdit] = [], fileOperations: [WorkspaceFileOperation] = []
  ) {
    self.documentEdits = documentEdits
    self.fileOperations = fileOperations
  }
}

/// A configuration item requested by an LSP server through `workspace/configuration`.
public struct LanguageServerConfigurationItem: Hashable, Sendable {
  public var scopeURI: URL?
  public var section: String?

  public init(scopeURI: URL? = nil, section: String? = nil) {
    self.scopeURI = scopeURI
    self.section = section
  }
}

public enum EditorJSONValue: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([EditorJSONValue])
  case object([String: EditorJSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([EditorJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: EditorJSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

public struct EditorCommand: Hashable, Sendable {
  public var title: String
  public var command: String
  public var arguments: [EditorJSONValue]
  /// Optional identifier of the service that should execute this command.
  public var serviceIdentifier: String?

  public init(
    title: String,
    command: String,
    arguments: [EditorJSONValue] = [],
    serviceIdentifier: String? = nil
  ) {
    self.title = title
    self.command = command
    self.arguments = arguments
    self.serviceIdentifier = serviceIdentifier
  }
}

public struct SignatureParameter: Hashable, Sendable {
  public var label: String
  public var documentation: String?
  public init(label: String, documentation: String? = nil) {
    self.label = label
    self.documentation = documentation
  }
}

public struct EditorSignatureInformation: Hashable, Sendable {
  public var label: String
  public var documentation: String?
  public var parameters: [SignatureParameter]
  public var activeParameter: Int?
  public init(
    label: String, documentation: String? = nil, parameters: [SignatureParameter] = [],
    activeParameter: Int? = nil
  ) {
    self.label = label
    self.documentation = documentation
    self.parameters = parameters
    self.activeParameter = activeParameter
  }
}

public struct EditorSignatureHelp: Hashable, Sendable {
  public var signatures: [EditorSignatureInformation]
  public var activeSignature: Int?
  public var activeParameter: Int?
  public init(
    signatures: [EditorSignatureInformation], activeSignature: Int? = nil,
    activeParameter: Int? = nil
  ) {
    self.signatures = signatures
    self.activeSignature = activeSignature
    self.activeParameter = activeParameter
  }
}

public enum EditorSymbolKind: Int, Hashable, Sendable {
  case file = 1
  case module, namespace, package, `class`, method, property, field, constructor
  case `enum`, interface, function, variable, constant, string, number, boolean, array
  case object, key, null, enumMember, `struct`, event, `operator`, typeParameter
}

public struct EditorDocumentSymbol: Hashable, Sendable {
  public var name: String
  public var detail: String?
  public var kind: EditorSymbolKind
  public var range: EditorTextRange
  public var selectionRange: EditorTextRange
  public var children: [EditorDocumentSymbol]
  public var containerName: String?
  public init(
    name: String,
    detail: String? = nil,
    kind: EditorSymbolKind,
    range: EditorTextRange,
    selectionRange: EditorTextRange,
    children: [EditorDocumentSymbol] = [],
    containerName: String? = nil
  ) {
    self.name = name
    self.detail = detail
    self.kind = kind
    self.range = range
    self.selectionRange = selectionRange
    self.children = children
    self.containerName = containerName
  }
}

public struct EditorCodeAction: Hashable, Sendable {
  public var title: String
  public var kind: String?
  public var isPreferred: Bool
  public var isDisabled: Bool
  public var edit: EditorWorkspaceEdit?
  public var command: EditorCommand?
  public init(
    title: String,
    kind: String? = nil,
    isPreferred: Bool = false,
    isDisabled: Bool = false,
    edit: EditorWorkspaceEdit? = nil,
    command: EditorCommand? = nil
  ) {
    self.title = title
    self.kind = kind
    self.isPreferred = isPreferred
    self.isDisabled = isDisabled
    self.edit = edit
    self.command = command
  }
}

public enum EditorInlayHintKind: Int, Hashable, Sendable {
  case type = 1
  case parameter = 2
}

public struct EditorInlayHint: Hashable, Sendable {
  public var position: TextPosition
  public var label: String
  public var kind: EditorInlayHintKind?
  public var tooltip: String?
  public var edits: [TextEdit]
  public var paddingLeft: Bool
  public var paddingRight: Bool
  public init(
    position: TextPosition,
    label: String,
    kind: EditorInlayHintKind? = nil,
    tooltip: String? = nil,
    edits: [TextEdit] = [],
    paddingLeft: Bool = false,
    paddingRight: Bool = false
  ) {
    self.position = position
    self.label = label
    self.kind = kind
    self.tooltip = tooltip
    self.edits = edits
    self.paddingLeft = paddingLeft
    self.paddingRight = paddingRight
  }
}

public enum LanguageFeatureError: Error, Equatable, Sendable {
  case unsupported(String)
  case malformedResponse(String)
}

public protocol SyntaxProviding: Sendable {
  func open(snapshot: TextSnapshot) async throws
  func apply(change: AppliedTextEdit) async throws
  func highlights(in range: EditorTextRange?) async throws -> [Highlight]
  func foldingRanges() async throws -> [FoldingRange]
  func close() async throws
}
extension SyntaxProviding {
  public func foldingRanges() async throws -> [FoldingRange] { [] }
  public func close() async throws {}
}

public protocol LanguageIntelligenceProviding: Sendable {
  var diagnostics: AsyncStream<DiagnosticBatch> { get }
  var messages: AsyncStream<LanguageServerMessage> { get }
  func open(uri: URL, languageID: String, snapshot: TextSnapshot) async throws
  func change(uri: URL, change: AppliedTextEdit) async throws
  func save(uri: URL, snapshot: TextSnapshot) async throws
  func completions(uri: URL, at position: TextPosition, triggerCharacter: String?) async throws
    -> [Completion]
  func resolveCompletion(_ completion: Completion) async throws -> Completion
  func hover(uri: URL, at position: TextPosition) async throws -> HoverResult?
  func definitions(uri: URL, at position: TextPosition) async throws -> [SourceLocation]
  func references(uri: URL, at position: TextPosition, includeDeclaration: Bool) async throws
    -> [SourceLocation]
  func formatting(uri: URL, options: EditorFormattingOptions) async throws -> [TextEdit]
  func rangeFormatting(uri: URL, range: EditorTextRange, options: EditorFormattingOptions)
    async throws
    -> [TextEdit]
  func prepareRename(uri: URL, at position: TextPosition) async throws -> RenamePreparation?
  func rename(uri: URL, at position: TextPosition, newName: String) async throws
    -> EditorWorkspaceEdit?
  func semanticHighlights(uri: URL) async throws -> [SemanticHighlight]
  func signatureHelp(uri: URL, at position: TextPosition) async throws -> EditorSignatureHelp?
  func documentSymbols(uri: URL) async throws -> [EditorDocumentSymbol]
  func codeActions(uri: URL, range: EditorTextRange, diagnostics: [Diagnostic], only: [String]?)
    async throws -> [EditorCodeAction]
  func inlayHints(uri: URL, range: EditorTextRange) async throws -> [EditorInlayHint]
  func executeCommand(_ command: EditorCommand) async throws -> EditorJSONValue?
  func close(uri: URL) async throws
}

extension LanguageIntelligenceProviding {
  public var messages: AsyncStream<LanguageServerMessage> {
    AsyncStream { $0.finish() }
  }
  public func resolveCompletion(_ completion: Completion) async throws -> Completion { completion }
  public func save(uri: URL, snapshot: TextSnapshot) async throws {}
  public func references(uri: URL, at position: TextPosition, includeDeclaration: Bool = true)
    async throws -> [SourceLocation]
  {
    throw LanguageFeatureError.unsupported("textDocument/references")
  }
  public func formatting(uri: URL, options: EditorFormattingOptions) async throws -> [TextEdit] {
    throw LanguageFeatureError.unsupported("textDocument/formatting")
  }
  public func rangeFormatting(uri: URL, range: EditorTextRange, options: EditorFormattingOptions)
    async throws -> [TextEdit]
  {
    throw LanguageFeatureError.unsupported("textDocument/rangeFormatting")
  }
  public func prepareRename(uri: URL, at position: TextPosition) async throws -> RenamePreparation?
  {
    throw LanguageFeatureError.unsupported("textDocument/prepareRename")
  }
  public func rename(uri: URL, at position: TextPosition, newName: String) async throws
    -> EditorWorkspaceEdit?
  {
    throw LanguageFeatureError.unsupported("textDocument/rename")
  }
  public func semanticHighlights(uri: URL) async throws -> [SemanticHighlight] {
    throw LanguageFeatureError.unsupported("textDocument/semanticTokens/full")
  }
  public func signatureHelp(uri: URL, at position: TextPosition) async throws
    -> EditorSignatureHelp?
  {
    throw LanguageFeatureError.unsupported("textDocument/signatureHelp")
  }
  public func documentSymbols(uri: URL) async throws -> [EditorDocumentSymbol] {
    throw LanguageFeatureError.unsupported("textDocument/documentSymbol")
  }
  public func codeActions(
    uri: URL, range: EditorTextRange, diagnostics: [Diagnostic] = [], only: [String]? = nil
  ) async throws -> [EditorCodeAction] {
    throw LanguageFeatureError.unsupported("textDocument/codeAction")
  }
  public func inlayHints(uri: URL, range: EditorTextRange) async throws -> [EditorInlayHint] {
    throw LanguageFeatureError.unsupported("textDocument/inlayHint")
  }
  public func executeCommand(_ command: EditorCommand) async throws -> EditorJSONValue? {
    throw LanguageFeatureError.unsupported("workspace/executeCommand")
  }
}
