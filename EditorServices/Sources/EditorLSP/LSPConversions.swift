import EditorCore
import Foundation
import LanguageServerProtocol

public enum LSPConversion {
  public static func position(_ value: TextPosition) -> Position {
    Position(line: value.line, character: value.utf16Column)
  }
  public static func position(_ value: Position) -> TextPosition {
    TextPosition(line: value.line, utf16Column: value.character)
  }
  public static func range(_ value: EditorTextRange) -> LSPRange {
    LSPRange(start: position(value.start), end: position(value.end))
  }
  public static func range(_ value: LSPRange) -> EditorTextRange {
    EditorTextRange(start: position(value.start), end: position(value.end))
  }
  public static func edit(_ value: LanguageServerProtocol.TextEdit) -> EditorCore.TextEdit {
    EditorCore.TextEdit(range: range(value.range), replacement: value.newText)
  }

  public static func completion(
    _ item: LanguageServerProtocol.CompletionItem,
    resolutionID: UUID? = nil
  ) -> Completion {
    let documentation: String?
    switch item.documentation {
    case .none: documentation = nil
    case .some(.optionA(let string)): documentation = string
    case .some(.optionB(let markup)): documentation = markup.value
    }
    let primary: EditorCore.TextEdit?
    switch item.textEdit {
    case .none: primary = nil
    case .some(.optionA(let edit)): primary = self.edit(edit)
    case .some(.optionB(let edit)):
      primary = EditorCore.TextEdit(range: range(edit.replace), replacement: edit.newText)
    }
    return Completion(
      label: item.label,
      kind: item.kind.flatMap { CompletionKind(rawValue: $0.rawValue) },
      detail: item.detail,
      documentation: documentation,
      sortText: item.sortText,
      filterText: item.filterText,
      insertText: item.insertText,
      insertTextFormat: item.insertTextFormat?.rawValue == 2 ? .snippet : .plainText,
      primaryEdit: primary,
      additionalEdits: (item.additionalTextEdits ?? []).map(edit),
      commitCharacters: item.commitCharacters ?? [],
      command: item.command.map(command),
      resolutionID: resolutionID
    )
  }

  public static func hover(_ value: Hover) -> HoverResult {
    let text: String
    switch value.contents {
    case .optionA(let marked): text = marked.value
    case .optionB(let marked): text = marked.map(\.value).joined(separator: "\n\n")
    case .optionC(let markup): text = markup.value
    }
    return HoverResult(markdown: text, range: value.range.map(range))
  }

  public static func locations(_ response: DefinitionResponse) -> [SourceLocation] {
    guard let response else { return [] }
    switch response {
    case .optionA(let value): return [location(value)]
    case .optionB(let locations): return locations.map(location)
    case .optionC(let links):
      return links.compactMap { link in
        guard let url = URL(string: link.targetUri) else { return nil }
        return SourceLocation(uri: url, range: range(link.targetSelectionRange))
      }
    }
  }

  public static func location(_ value: Location) -> SourceLocation {
    SourceLocation(
      uri: URL(string: value.uri) ?? URL(fileURLWithPath: value.uri), range: range(value.range))
  }

  public static func diagnostic(_ value: LanguageServerProtocol.Diagnostic) -> EditorCore.Diagnostic
  {
    let code: String?
    switch value.code {
    case .none: code = nil
    case .some(.optionA(let integer)): code = String(integer)
    case .some(.optionB(let string)): code = string
    }
    return EditorCore.Diagnostic(
      range: range(value.range), message: value.message,
      severity: EditorCore.Diagnostic.Severity(rawValue: value.severity?.rawValue ?? 3)
        ?? .information,
      code: code, source: value.source
    )
  }

  public static func renamePreparation(_ response: PrepareRenameResponse) -> RenamePreparation? {
    guard let response else { return nil }
    switch response {
    case .optionA(let value): return .range(range(value), placeholder: nil)
    case .optionB(let value): return .range(range(value.range), placeholder: value.placeholder)
    case .optionC: return .defaultBehavior
    }
  }

  public static func workspaceEdit(_ value: WorkspaceEdit?) -> EditorWorkspaceEdit? {
    guard let value else { return nil }
    var documents: [WorkspaceDocumentEdit] = []
    var operations: [WorkspaceFileOperation] = []
    if let changes = value.changes {
      for uri in changes.keys.sorted() {
        guard let edits = changes[uri], let url = URL(string: uri) else { continue }
        documents.append(WorkspaceDocumentEdit(uri: url, edits: edits.map(edit)))
      }
    }
    for change in value.documentChanges ?? [] {
      switch change {
      case .textDocumentEdit(let value):
        guard let url = URL(string: value.textDocument.uri) else { continue }
        documents.append(
          WorkspaceDocumentEdit(
            uri: url, version: value.textDocument.version, edits: value.edits.map(edit)))
      case .createFile(let value):
        guard let url = URL(string: value.uri) else { continue }
        operations.append(
          .create(
            uri: url, overwrite: value.options?.overwrite,
            ignoreIfExists: value.options?.ignoreIfExists))
      case .renameFile(let value):
        guard let old = URL(string: value.oldUri), let new = URL(string: value.newUri) else {
          continue
        }
        operations.append(
          .rename(
            oldURI: old, newURI: new, overwrite: value.options.overwrite,
            ignoreIfExists: value.options.ignoreIfExists))
      case .deleteFile(let value):
        guard let url = URL(string: value.uri) else { continue }
        operations.append(
          .delete(
            uri: url, recursive: value.options.recursive,
            ignoreIfNotExists: value.options.ignoreIfNotExists))
      }
    }
    return EditorWorkspaceEdit(documentEdits: documents, fileOperations: operations)
  }

  public static func semanticHighlights(_ value: SemanticTokens?, legend: SemanticTokensLegend)
    throws -> [SemanticHighlight]
  {
    guard let value else { return [] }
    guard value.data.count.isMultiple(of: 5) else {
      throw LanguageFeatureError.malformedResponse("semantic token data count")
    }
    var line = 0
    var column = 0
    var result: [SemanticHighlight] = []
    for index in stride(from: 0, to: value.data.count, by: 5) {
      let deltaLine = Int(value.data[index])
      let deltaColumn = Int(value.data[index + 1])
      if deltaLine > 0 {
        line += deltaLine
        column = deltaColumn
      } else {
        column += deltaColumn
      }
      let length = Int(value.data[index + 2])
      let typeIndex = Int(value.data[index + 3])
      let bits = value.data[index + 4]
      guard typeIndex < legend.tokenTypes.count else {
        throw LanguageFeatureError.malformedResponse("semantic token type index")
      }
      var modifiers: [String] = []
      for modifierIndex in legend.tokenModifiers.indices where modifierIndex < 32 {
        if bits & (1 << UInt32(modifierIndex)) != 0 {
          modifiers.append(legend.tokenModifiers[modifierIndex])
        }
      }
      result.append(
        SemanticHighlight(
          range: EditorTextRange(
            start: TextPosition(line: line, utf16Column: column),
            end: TextPosition(line: line, utf16Column: column + length)),
          tokenType: legend.tokenTypes[typeIndex], modifiers: modifiers
        ))
    }
    return result
  }

  public static func json(_ value: LSPAny) -> EditorJSONValue {
    switch value {
    case .null: return .null
    case .bool(let value): return .bool(value)
    case .number(let value): return .number(value)
    case .string(let value): return .string(value)
    case .array(let values): return .array(values.map(json))
    case .hash(let values): return .object(values.mapValues(json))
    }
  }

  public static func lspJSON(_ value: EditorJSONValue) -> LSPAny {
    switch value {
    case .null: return .null
    case .bool(let value): return .bool(value)
    case .number(let value): return .number(value)
    case .string(let value): return .string(value)
    case .array(let values): return .array(values.map(lspJSON))
    case .object(let values): return .hash(values.mapValues(lspJSON))
    }
  }

  public static func command(_ value: LanguageServerProtocol.Command) -> EditorCommand {
    EditorCommand(
      title: value.title, command: value.command, arguments: (value.arguments ?? []).map(json))
  }

  public static func signatureHelp(_ value: SignatureHelpResponse) -> EditorSignatureHelp? {
    guard let value else { return nil }
    return EditorSignatureHelp(
      signatures: value.signatures.map { signature in
        EditorSignatureInformation(
          label: signature.label,
          documentation: markup(signature.documentation),
          parameters: (signature.parameters ?? []).map { parameter in
            SignatureParameter(
              label: parameterLabel(parameter.label, in: signature.label),
              documentation: markup(parameter.documentation)
            )
          },
          activeParameter: signature.activeParameter.map { Int($0) }
        )
      },
      activeSignature: value.activeSignature,
      activeParameter: value.activeParameter
    )
  }

  public static func workspaceSymbols(_ value: WorkspaceSymbolResponse) -> [EditorWorkspaceSymbol] {
    guard let value else { return [] }
    switch value {
    case .optionA(let symbols):
      return symbols.map { symbol in
        EditorWorkspaceSymbol(
          name: symbol.name,
          kind: EditorSymbolKind(rawValue: symbol.kind.rawValue) ?? .variable,
          location: location(symbol.location),
          containerName: symbol.containerName
        )
      }
    case .optionB(let symbols):
      return symbols.map { symbol in
        let resolvedLocation: SourceLocation?
        switch symbol.location {
        case .some(.optionA(let value)):
          resolvedLocation = location(value)
        case .some(.optionB), .none:
          resolvedLocation = nil
        }
        return EditorWorkspaceSymbol(
          name: symbol.name,
          kind: EditorSymbolKind(rawValue: symbol.kind.rawValue) ?? .variable,
          location: resolvedLocation,
          containerName: symbol.containerName
        )
      }
    }
  }

  public static func documentSymbols(_ value: DocumentSymbolResponse) -> [EditorDocumentSymbol] {
    guard let value else { return [] }
    switch value {
    case .optionA(let symbols): return symbols.map(documentSymbol)
    case .optionB(let symbols):
      return symbols.map { symbol in
        EditorDocumentSymbol(
          name: symbol.name,
          kind: EditorSymbolKind(rawValue: symbol.kind.rawValue) ?? .variable,
          range: range(symbol.location.range),
          selectionRange: range(symbol.location.range),
          containerName: symbol.containerName
        )
      }
    }
  }

  public static func codeActions(_ value: CodeActionResponse) -> [EditorCodeAction] {
    (value ?? []).map { item in
      switch item {
      case .optionA(let value):
        return EditorCodeAction(title: value.title, command: command(value))
      case .optionB(let value):
        return EditorCodeAction(
          title: value.title,
          kind: value.kind,
          isPreferred: value.isPreferred ?? false,
          isDisabled: value.disabled?.disabled ?? false,
          edit: workspaceEdit(value.edit),
          command: value.command.map(command)
        )
      }
    }
  }

  public static func inlayHints(_ value: InlayHintResponse) -> [EditorInlayHint] {
    (value ?? []).map { hint in
      let label: String
      switch hint.label {
      case .optionA(let value): label = value
      case .optionB(let parts): label = parts.map(\.value).joined()
      }
      return EditorInlayHint(
        position: position(hint.position),
        label: label,
        kind: hint.kind.flatMap { EditorInlayHintKind(rawValue: $0.rawValue) },
        tooltip: markup(hint.tooltip),
        edits: (hint.textEdits ?? []).map(edit),
        paddingLeft: hint.paddingLeft ?? false,
        paddingRight: hint.paddingRight ?? false
      )
    }
  }

  public static func lspDiagnostic(_ value: EditorCore.Diagnostic)
    -> LanguageServerProtocol.Diagnostic
  {
    LanguageServerProtocol.Diagnostic(
      range: range(value.range),
      severity: DiagnosticSeverity(rawValue: value.severity.rawValue),
      code: value.code.map { .optionB($0) },
      source: value.source,
      message: value.message
    )
  }

  private static func documentSymbol(_ value: LanguageServerProtocol.DocumentSymbol)
    -> EditorDocumentSymbol
  {
    EditorDocumentSymbol(
      name: value.name,
      detail: value.detail,
      kind: EditorSymbolKind(rawValue: value.kind.rawValue) ?? .variable,
      range: range(value.range),
      selectionRange: range(value.selectionRange),
      children: (value.children ?? []).map(documentSymbol)
    )
  }

  private static func parameterLabel(_ value: TwoTypeOption<String, [UInt]>, in signature: String)
    -> String
  {
    switch value {
    case .optionA(let label): return label
    case .optionB(let offsets):
      guard offsets.count == 2,
        offsets[0] <= UInt(Int.max), offsets[1] <= UInt(Int.max),
        let startUTF16 = signature.utf16.index(
          signature.utf16.startIndex, offsetBy: Int(offsets[0]), limitedBy: signature.utf16.endIndex
        ),
        let endUTF16 = signature.utf16.index(
          signature.utf16.startIndex, offsetBy: Int(offsets[1]), limitedBy: signature.utf16.endIndex
        ),
        let start = String.Index(startUTF16, within: signature),
        let end = String.Index(endUTF16, within: signature),
        start <= end
      else { return signature }
      return String(signature[start..<end])
    }
  }

  private static func markup(_ value: TwoTypeOption<String, MarkupContent>?) -> String? {
    guard let value else { return nil }
    switch value {
    case .optionA(let text): return text
    case .optionB(let markup): return markup.value
    }
  }

}
