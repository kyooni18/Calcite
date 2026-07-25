import Foundation

public enum SnippetExpansionError: Error, Equatable, Sendable {
  case malformed(String)
  case unsupportedTransform
}

public struct SnippetTabStop: Hashable, Sendable {
  public var index: Int
  public var ranges: [NSRange]
  public var choices: [String]

  public init(index: Int, ranges: [NSRange], choices: [String] = []) {
    self.index = index
    self.ranges = ranges
    self.choices = choices
  }
}

/// Result of expanding a common Language Server Protocol snippet.
/// Ranges are UTF-16 ranges relative to ``text``.
public struct SnippetExpansion: Hashable, Sendable {
  public var text: String
  public var tabStops: [SnippetTabStop]
  public var finalCursorUTF16Offset: Int

  public init(text: String, tabStops: [SnippetTabStop], finalCursorUTF16Offset: Int) {
    self.text = text
    self.tabStops = tabStops
    self.finalCursorUTF16Offset = finalCursorUTF16Offset
  }

  public static func expand(
    _ snippet: String,
    variables: [String: String] = [:]
  ) throws -> SnippetExpansion {
    var parser = SnippetParser(source: snippet, variables: variables)
    return try parser.parse()
  }
}

public struct CompletionApplicationPlan: Hashable, Sendable {
  public var edits: [TextEdit]
  public var primaryRange: EditorTextRange
  public var expansion: SnippetExpansion

  public init(edits: [TextEdit], primaryRange: EditorTextRange, expansion: SnippetExpansion) {
    self.edits = edits
    self.primaryRange = primaryRange
    self.expansion = expansion
  }
}

public struct CompletionTabStop: Hashable, Sendable {
  public var index: Int
  public var ranges: [EditorTextRange]
  public var choices: [String]

  public init(index: Int, ranges: [EditorTextRange], choices: [String] = []) {
    self.index = index
    self.ranges = ranges
    self.choices = choices
  }
}

public struct CompletionApplicationResult: Hashable, Sendable {
  public var appliedEdits: [AppliedTextEdit]
  public var snapshot: TextSnapshot
  public var insertedRange: EditorTextRange
  public var tabStops: [CompletionTabStop]
  public var initialSelection: EditorTextRange
  public var finalCursor: TextPosition
  /// An optional command requested by the server after insertion.
  public var command: EditorCommand?

  public init(
    appliedEdits: [AppliedTextEdit],
    snapshot: TextSnapshot,
    insertedRange: EditorTextRange,
    tabStops: [CompletionTabStop],
    initialSelection: EditorTextRange,
    finalCursor: TextPosition,
    command: EditorCommand? = nil
  ) {
    self.appliedEdits = appliedEdits
    self.snapshot = snapshot
    self.insertedRange = insertedRange
    self.tabStops = tabStops
    self.initialSelection = initialSelection
    self.finalCursor = finalCursor
    self.command = command
  }
}

extension CompletionUtilities {
  public static func applicationPlan(
    for completion: Completion,
    in snapshot: TextSnapshot,
    at position: TextPosition,
    replacing replacementRange: EditorTextRange? = nil,
    snippetVariables: [String: String] = [:]
  ) throws -> CompletionApplicationPlan {
    _ = try snapshot.utf16Offset(of: position)
    let primaryRange: EditorTextRange
    if let explicit = completion.primaryEdit?.range ?? replacementRange {
      primaryRange = explicit
    } else {
      primaryRange = try inferredIdentifierRange(in: snapshot, endingAt: position)
    }
    let sourceReplacement =
      completion.primaryEdit?.replacement
      ?? completion.insertText
      ?? completion.label

    let expansion: SnippetExpansion
    switch completion.insertTextFormat {
    case .plainText:
      expansion = .init(
        text: sourceReplacement,
        tabStops: [],
        finalCursorUTF16Offset: sourceReplacement.utf16.count
      )
    case .snippet:
      expansion = try .expand(sourceReplacement, variables: snippetVariables)
    }

    let edits =
      [TextEdit(range: primaryRange, replacement: expansion.text)]
      + completion.additionalEdits
    for edit in edits { _ = try snapshot.nsRange(for: edit.range) }
    var validation = TextBuffer(text: snapshot.text, version: snapshot.version)
    _ = try validation.apply(edits)
    return .init(edits: edits, primaryRange: primaryRange, expansion: expansion)
  }

  public static func inferredIdentifierRange(
    in snapshot: TextSnapshot,
    endingAt position: TextPosition
  ) throws -> EditorTextRange {
    let endOffset = try snapshot.utf16Offset(of: position)
    let nsText = snapshot.text as NSString
    var startOffset = endOffset
    while startOffset > 0 {
      let candidate = nsText.rangeOfComposedCharacterSequence(at: startOffset - 1)
      let character = nsText.substring(with: candidate)
      guard
        character.unicodeScalars.allSatisfy({
          $0 == "_" || $0.properties.isXIDContinue
        })
      else { break }
      startOffset = candidate.location
    }
    return EditorTextRange(
      start: try snapshot.position(atUTF16Offset: startOffset),
      end: position
    )
  }
}

private struct SnippetParser {
  let source: String
  let variables: [String: String]
  var index: String.Index
  var output = ""
  var ranges: [Int: [NSRange]] = [:]
  var choices: [Int: [String]] = [:]
  var values: [Int: String] = [:]
  var finalCursor: Int?

  init(source: String, variables: [String: String]) {
    self.source = source
    self.variables = variables
    self.index = source.startIndex
  }

  mutating func parse() throws -> SnippetExpansion {
    try parseSequence(untilClosingBrace: false)
    let stops = ranges.keys
      .filter { $0 > 0 }
      .sorted()
      .map { SnippetTabStop(index: $0, ranges: ranges[$0] ?? [], choices: choices[$0] ?? []) }
    return .init(
      text: output,
      tabStops: stops,
      finalCursorUTF16Offset: finalCursor ?? output.utf16.count
    )
  }

  private mutating func parseSequence(untilClosingBrace: Bool) throws {
    while index < source.endIndex {
      let character = source[index]
      if untilClosingBrace, character == "}" {
        source.formIndex(after: &index)
        return
      }
      switch character {
      case "\\":
        source.formIndex(after: &index)
        guard index < source.endIndex else {
          output.append("\\")
          return
        }
        output.append(source[index])
        source.formIndex(after: &index)
      case "$":
        try parseDollar()
      default:
        output.append(character)
        source.formIndex(after: &index)
      }
    }
    if untilClosingBrace { throw SnippetExpansionError.malformed("Unclosed snippet expression") }
  }

  private mutating func parseDollar() throws {
    let dollar = index
    source.formIndex(after: &index)
    guard index < source.endIndex else {
      output.append("$")
      return
    }
    if source[index] == "{" {
      source.formIndex(after: &index)
      try parseBracedExpression()
    } else if source[index].isNumber {
      appendTabStop(try parseNumber())
    } else if isVariableStart(source[index]) {
      let name = parseVariableName()
      output += variables[name] ?? name
    } else {
      output.append(contentsOf: source[dollar..<index])
    }
  }

  private mutating func parseBracedExpression() throws {
    guard index < source.endIndex else {
      throw SnippetExpansionError.malformed("Empty snippet expression")
    }
    if source[index].isNumber {
      let number = try parseNumber()
      guard index < source.endIndex else {
        throw SnippetExpansionError.malformed("Unclosed tab stop")
      }
      switch source[index] {
      case "}":
        source.formIndex(after: &index)
        appendTabStop(number)
      case ":":
        source.formIndex(after: &index)
        let start = output.utf16.count
        try parseSequence(untilClosingBrace: true)
        let range = NSRange(location: start, length: output.utf16.count - start)
        values[number] = (output as NSString).substring(with: range)
        record(number, range: range)
        if number == 0 { finalCursor = start }
      case "|":
        source.formIndex(after: &index)
        let options = try parseChoices()
        let value = options.first ?? ""
        let start = output.utf16.count
        output += value
        let range = NSRange(location: start, length: value.utf16.count)
        values[number] = value
        choices[number] = options
        record(number, range: range)
        if number == 0 { finalCursor = start }
      case "/":
        throw SnippetExpansionError.unsupportedTransform
      default:
        throw SnippetExpansionError.malformed("Unsupported tab-stop expression")
      }
      return
    }

    guard isVariableStart(source[index]) else {
      throw SnippetExpansionError.malformed("Invalid snippet expression")
    }
    let name = parseVariableName()
    guard index < source.endIndex else {
      throw SnippetExpansionError.malformed("Unclosed variable")
    }
    switch source[index] {
    case "}":
      source.formIndex(after: &index)
      output += variables[name] ?? name
    case ":":
      source.formIndex(after: &index)
      let defaultValue = try parseVariableDefault()
      output += variables[name] ?? defaultValue
    case "/":
      throw SnippetExpansionError.unsupportedTransform
    default:
      throw SnippetExpansionError.malformed("Unsupported variable expression")
    }
  }

  private mutating func parseVariableDefault() throws -> String {
    var value = ""
    while index < source.endIndex {
      let character = source[index]
      if character == "}" {
        source.formIndex(after: &index)
        return value
      }
      if character == "\\" {
        source.formIndex(after: &index)
        guard index < source.endIndex else { break }
        value.append(source[index])
        source.formIndex(after: &index)
      } else {
        value.append(character)
        source.formIndex(after: &index)
      }
    }
    throw SnippetExpansionError.malformed("Unclosed variable default")
  }

  private mutating func parseChoices() throws -> [String] {
    var options: [String] = []
    var current = ""
    while index < source.endIndex {
      let character = source[index]
      if character == "\\" {
        source.formIndex(after: &index)
        guard index < source.endIndex else { break }
        current.append(source[index])
        source.formIndex(after: &index)
      } else if character == "," {
        options.append(current)
        current = ""
        source.formIndex(after: &index)
      } else if character == "|" {
        source.formIndex(after: &index)
        guard index < source.endIndex, source[index] == "}" else {
          throw SnippetExpansionError.malformed("Choice list must end with |}")
        }
        source.formIndex(after: &index)
        options.append(current)
        return options
      } else {
        current.append(character)
        source.formIndex(after: &index)
      }
    }
    throw SnippetExpansionError.malformed("Unclosed choice list")
  }

  private mutating func parseNumber() throws -> Int {
    let start = index
    while index < source.endIndex, source[index].isNumber {
      source.formIndex(after: &index)
    }
    guard let value = Int(source[start..<index]) else {
      throw SnippetExpansionError.malformed("Invalid tab-stop number")
    }
    return value
  }

  private mutating func appendTabStop(_ number: Int) {
    let value = values[number] ?? ""
    let start = output.utf16.count
    output += value
    record(number, range: NSRange(location: start, length: value.utf16.count))
    if number == 0 { finalCursor = start }
  }

  private mutating func record(_ number: Int, range: NSRange) {
    ranges[number, default: []].append(range)
  }

  private func isVariableStart(_ character: Character) -> Bool {
    character == "_" || character.isLetter
  }

  private mutating func parseVariableName() -> String {
    let start = index
    while index < source.endIndex {
      let character = source[index]
      guard character == "_" || character.isLetter || character.isNumber else { break }
      source.formIndex(after: &index)
    }
    return String(source[start..<index])
  }
}
