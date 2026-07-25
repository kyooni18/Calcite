import EditorCore
import Foundation

/// A dependency-free syntax provider used when a structural grammar is unavailable or fails.
///
/// The scanner deliberately focuses on stable lexical categories—comments, strings, numbers,
/// keywords, declarations, operators, and punctuation. It is not intended to replace Tree-sitter;
/// it guarantees that an editor remains readable while a richer grammar is missing or recovering.
package actor LexicalSyntaxService: SyntaxProviding {
  private let languageID: String
  private var snapshot = TextSnapshot(text: "")

  package init(languageID: String) {
    self.languageID = languageID.lowercased()
  }

  package func open(snapshot: TextSnapshot) {
    self.snapshot = snapshot
  }

  package func apply(change: AppliedTextEdit) {
    snapshot = change.newSnapshot
  }

  package func highlights(in range: EditorTextRange?) throws -> [Highlight] {
    try LexicalSyntaxScanner(
      snapshot: snapshot,
      rules: LexicalLanguageRules.make(for: languageID),
      requestedRange: range
    ).scan()
  }

  package func foldingRanges() -> [FoldingRange] { [] }

  package func close() {
    snapshot = TextSnapshot(text: "")
  }
}

/// Keeps syntax highlighting available even when an optional structural parser throws or produces
/// no captures. Parser failures never roll back a user's text edit.
package actor ResilientSyntaxService: SyntaxProviding {
  private let primary: (any SyntaxProviding)?
  private let fallback: LexicalSyntaxService
  private let languageID: String
  private var primaryIsUsable: Bool

  package init(primary: (any SyntaxProviding)?, languageID: String) {
    self.primary = primary
    self.fallback = LexicalSyntaxService(languageID: languageID)
    self.languageID = languageID.lowercased()
    self.primaryIsUsable = primary != nil
  }

  package func open(snapshot: TextSnapshot) async throws {
    await fallback.open(snapshot: snapshot)
    guard let primary, primaryIsUsable else { return }
    do {
      try await primary.open(snapshot: snapshot)
    } catch {
      primaryIsUsable = false
    }
  }

  package func apply(change: AppliedTextEdit) async throws {
    await fallback.apply(change: change)
    guard let primary, primaryIsUsable else { return }
    do {
      try await primary.apply(change: change)
    } catch {
      primaryIsUsable = false
    }
  }

  package func highlights(in range: EditorTextRange?) async throws -> [Highlight] {
    let lexical = try await fallback.highlights(in: range)
    if let primary, primaryIsUsable {
      do {
        let structural = try await primary.highlights(in: range)
        guard !structural.isEmpty else { return lexical }
        guard languageID == "rust" else { return structural }
        return correctedRustHighlights(structural: structural, lexical: lexical)
      } catch {
        primaryIsUsable = false
      }
    }
    return lexical
  }

  private func correctedRustHighlights(
    structural: [Highlight],
    lexical: [Highlight]
  ) -> [Highlight] {
    let lifetimes = lexical.filter { $0.capture == "type.parameter" }
    guard !lifetimes.isEmpty else { return structural }
    let filtered = structural.filter { highlight in
      let capture = highlight.capture.lowercased()
      guard capture.contains("comment") || capture.contains("string") else { return true }
      return !lifetimes.contains { rangesOverlap($0.range, highlight.range) }
    }
    return Array(Set(filtered + lifetimes)).sorted {
      ($0.range.start, $0.range.end, $0.capture) < ($1.range.start, $1.range.end, $1.capture)
    }
  }

  private func rangesOverlap(_ lhs: EditorTextRange, _ rhs: EditorTextRange) -> Bool {
    lhs.start < rhs.end && rhs.start < lhs.end
  }

  package func foldingRanges() async throws -> [FoldingRange] {
    guard let primary, primaryIsUsable else { return [] }
    do {
      return try await primary.foldingRanges()
    } catch {
      primaryIsUsable = false
      return []
    }
  }

  package func close() async throws {
    try? await fallback.close()
    if let primary, primaryIsUsable {
      try? await primary.close()
    }
    primaryIsUsable = false
  }
}

private struct LexicalCommentRules: Sendable {
  var line: [String]
  var block: [(open: String, close: String)]
}

private struct LexicalLanguageRules: Sendable {
  var keywords: Set<String>
  var builtInTypes: Set<String>
  var declarations: [String: String]
  var comments: LexicalCommentRules
  var strings: [String]
  var isCaseSensitive: Bool
  var supportsRustLifetimes = false

  static func make(for languageID: String) -> Self {
    let id = normalized(languageID)
    switch id {
    case "swift":
      return cFamily(
        keywords: swiftKeywords,
        builtInTypes: swiftTypes,
        declarations: [
          "actor": "type", "class": "type", "enum": "type", "extension": "type",
          "func": "function", "let": "variable", "protocol": "type", "struct": "type",
          "typealias": "type", "var": "variable",
        ]
      )
    case "rust":
      return cFamily(
        keywords: rustKeywords,
        builtInTypes: rustTypes,
        declarations: [
          "const": "variable", "enum": "type", "fn": "function", "let": "variable",
          "mod": "namespace", "static": "variable", "struct": "type", "trait": "type",
          "type": "type",
        ],
        // Rust apostrophes introduce lifetimes and labels. Character literals are handled by
        // scanRustCharacterOrLifetime instead of treating every apostrophe as a string opener.
        strings: ["\""],
        supportsRustLifetimes: true
      )
    case "go":
      return cFamily(
        keywords: goKeywords,
        builtInTypes: goTypes,
        declarations: [
          "const": "variable", "func": "function", "type": "type", "var": "variable",
        ]
      )
    case "zig":
      return cFamily(
        keywords: zigKeywords,
        builtInTypes: zigTypes,
        declarations: ["const": "variable", "fn": "function", "var": "variable"]
      )
    case "c", "cpp", "objective-c", "objective-cpp":
      return cFamily(
        keywords: cFamilyKeywords,
        builtInTypes: cFamilyTypes,
        declarations: [
          "class": "type", "enum": "type", "struct": "type", "typedef": "type",
          "union": "type",
        ]
      )
    case "java":
      return cFamily(
        keywords: javaKeywords,
        builtInTypes: javaTypes,
        declarations: [
          "class": "type", "enum": "type", "interface": "type", "record": "type",
        ]
      )
    case "kotlin":
      return cFamily(
        keywords: kotlinKeywords,
        builtInTypes: kotlinTypes,
        declarations: [
          "class": "type", "data": "type", "enum": "type", "fun": "function",
          "interface": "type", "object": "type", "typealias": "type", "val": "variable",
          "var": "variable",
        ]
      )
    case "javascript", "javascriptreact", "typescript", "typescriptreact":
      return cFamily(
        keywords: webScriptKeywords,
        builtInTypes: webScriptTypes,
        declarations: [
          "class": "type", "const": "variable", "enum": "type", "function": "function",
          "interface": "type", "let": "variable", "type": "type", "var": "variable",
        ],
        strings: ["\"\"\"", "'''", "\"", "'", "`"]
      )
    case "python":
      return .init(
        keywords: pythonKeywords,
        builtInTypes: pythonTypes,
        declarations: ["class": "type", "def": "function"],
        comments: .init(line: ["#"], block: []),
        strings: ["\"\"\"", "'''", "\"", "'"],
        isCaseSensitive: true
      )
    case "ruby":
      return .init(
        keywords: rubyKeywords,
        builtInTypes: rubyTypes,
        declarations: ["class": "type", "def": "function", "module": "namespace"],
        comments: .init(line: ["#"], block: [("=begin", "=end")]),
        strings: ["\"", "'", "`"],
        isCaseSensitive: true
      )
    case "php":
      return cFamily(
        keywords: phpKeywords,
        builtInTypes: phpTypes,
        declarations: [
          "class": "type", "enum": "type", "function": "function", "interface": "type",
          "trait": "type",
        ]
      )
    case "csharp", "fsharp":
      return cFamily(
        keywords: dotnetKeywords,
        builtInTypes: dotnetTypes,
        declarations: [
          "class": "type", "delegate": "type", "enum": "type", "interface": "type",
          "namespace": "namespace", "record": "type", "struct": "type",
        ]
      )
    case "dart":
      return cFamily(
        keywords: dartKeywords,
        builtInTypes: dartTypes,
        declarations: [
          "class": "type", "enum": "type", "extension": "type", "mixin": "type",
          "typedef": "type", "var": "variable",
        ]
      )
    case "scala":
      return cFamily(
        keywords: scalaKeywords,
        builtInTypes: scalaTypes,
        declarations: [
          "class": "type", "def": "function", "enum": "type", "object": "type",
          "trait": "type", "type": "type", "val": "variable", "var": "variable",
        ]
      )
    case "lua":
      return .init(
        keywords: luaKeywords,
        builtInTypes: [],
        declarations: ["function": "function", "local": "variable"],
        comments: .init(line: ["--"], block: [("--[[", "]]")]),
        strings: ["\"", "'", "[["],
        isCaseSensitive: true
      )
    case "shellscript", "bash", "sh", "zsh":
      return .init(
        keywords: shellKeywords,
        builtInTypes: [],
        declarations: ["function": "function"],
        comments: .init(line: ["#"], block: []),
        strings: ["\"", "'", "`"],
        isCaseSensitive: true
      )
    case "sql":
      return .init(
        keywords: sqlKeywords,
        builtInTypes: sqlTypes,
        declarations: [
          "database": "namespace", "function": "function", "procedure": "function",
          "table": "type", "view": "type",
        ],
        comments: .init(line: ["--", "#"], block: [("/*", "*/")]),
        strings: ["\"", "'", "`"],
        isCaseSensitive: false
      )
    case "html", "xml", "vue", "svelte":
      return .init(
        keywords: htmlKeywords,
        builtInTypes: [],
        declarations: [:],
        comments: .init(line: [], block: [("<!--", "-->")]),
        strings: ["\"", "'"],
        isCaseSensitive: false
      )
    case "css", "scss", "less":
      return .init(
        keywords: cssKeywords,
        builtInTypes: [],
        declarations: [:],
        comments: .init(line: id == "scss" || id == "less" ? ["//"] : [], block: [("/*", "*/")]),
        strings: ["\"", "'"],
        isCaseSensitive: false
      )
    case "json", "jsonc":
      return .init(
        keywords: ["true", "false", "null"],
        builtInTypes: [],
        declarations: [:],
        comments: .init(
          line: id == "jsonc" ? ["//"] : [],
          block: id == "jsonc" ? [("/*", "*/")] : []
        ),
        strings: ["\""],
        isCaseSensitive: true
      )
    case "yaml", "toml", "dockerfile", "makefile":
      return .init(
        keywords: dataKeywords,
        builtInTypes: [],
        declarations: [:],
        comments: .init(line: ["#"], block: []),
        strings: ["\"", "'"],
        isCaseSensitive: false
      )
    case "markdown":
      return .init(
        keywords: [],
        builtInTypes: [],
        declarations: [:],
        comments: .init(line: [], block: [("<!--", "-->")]),
        strings: ["```", "`"],
        isCaseSensitive: true
      )
    default:
      return cFamily(
        keywords: genericKeywords,
        builtInTypes: genericTypes,
        declarations: [
          "class": "type", "enum": "type", "fn": "function", "func": "function",
          "function": "function", "interface": "type", "let": "variable",
          "struct": "type", "type": "type", "var": "variable",
        ]
      )
    }
  }

  private static func normalized(_ languageID: String) -> String {
    switch languageID.lowercased() {
    case "js", "jsx": return languageID.lowercased() == "jsx" ? "javascriptreact" : "javascript"
    case "ts", "tsx": return languageID.lowercased() == "tsx" ? "typescriptreact" : "typescript"
    case "objc": return "objective-c"
    case "objcpp": return "objective-cpp"
    case "py": return "python"
    case "rb": return "ruby"
    default: return languageID.lowercased()
    }
  }

  private static func cFamily(
    keywords: Set<String>,
    builtInTypes: Set<String>,
    declarations: [String: String],
    strings: [String] = ["\"", "'", "`"],
    supportsRustLifetimes: Bool = false
  ) -> Self {
    .init(
      keywords: keywords,
      builtInTypes: builtInTypes,
      declarations: declarations,
      comments: .init(line: ["//"], block: [("/*", "*/")]),
      strings: strings,
      isCaseSensitive: true,
      supportsRustLifetimes: supportsRustLifetimes
    )
  }
}

private final class LexicalSyntaxScanner {
  private let snapshot: TextSnapshot
  private let source: NSString
  private let rules: LexicalLanguageRules
  private let requestedRange: NSRange?
  private var values: [Highlight] = []
  private var index = 0
  private var pendingDeclarationCapture: String?

  init(
    snapshot: TextSnapshot,
    rules: LexicalLanguageRules,
    requestedRange: EditorTextRange?
  ) throws {
    self.snapshot = snapshot
    self.source = snapshot.text as NSString
    self.rules = rules
    self.requestedRange = try requestedRange.map(snapshot.nsRange(for:))
  }

  func scan() throws -> [Highlight] {
    while index < source.length {
      if try scanComment() || scanRustCharacterOrLifetime() || scanString()
        || scanDirectiveOrAnnotation() || scanNumber() || scanIdentifier()
        || scanOperatorOrPunctuation()
      {
        continue
      }
      index += utf16CharacterLength(at: index)
    }
    return values.sorted {
      ($0.range.start, $0.range.end, $0.capture) < ($1.range.start, $1.range.end, $1.capture)
    }
  }

  private func scanComment() throws -> Bool {
    for delimiter in rules.comments.block where hasPrefix(delimiter.open, at: index) {
      let start = index
      index += delimiter.open.utf16.count
      if let found = range(of: delimiter.close, from: index) {
        index = NSMaxRange(found)
      } else {
        index = source.length
      }
      try append(capture: "comment", range: NSRange(location: start, length: index - start))
      return true
    }
    for delimiter in rules.comments.line where hasPrefix(delimiter, at: index) {
      let start = index
      index = lineEnd(from: index)
      try append(capture: "comment", range: NSRange(location: start, length: index - start))
      return true
    }
    return false
  }

  private func scanRustCharacterOrLifetime() -> Bool {
    guard rules.supportsRustLifetimes, source.character(at: index) == 0x27 else { return false }
    let start = index
    let next = index + 1
    guard next < source.length else { return false }

    // A valid character literal closes after one scalar (or one escape sequence). Lifetimes and
    // loop labels do not, so they are highlighted as type parameters rather than consuming the
    // remainder of the file as a string.
    var characterEnd = next
    if source.character(at: characterEnd) == 0x5C {
      characterEnd += min(2, source.length - characterEnd)
    } else {
      characterEnd += utf16CharacterLength(at: characterEnd)
    }
    if characterEnd < source.length, source.character(at: characterEnd) == 0x27 {
      index = characterEnd + 1
      try? append(capture: "string", range: NSRange(location: start, length: index - start))
      return true
    }

    guard isIdentifierStart(source.character(at: next)) else { return false }
    index = next + utf16CharacterLength(at: next)
    while index < source.length, isIdentifierContinuation(source.character(at: index)) {
      index += utf16CharacterLength(at: index)
    }
    try? append(capture: "type.parameter", range: NSRange(location: start, length: index - start))
    return true
  }

  private func scanString() -> Bool {
    guard let delimiter = rules.strings.first(where: { hasPrefix($0, at: index) }) else {
      return false
    }
    let start = index
    index += delimiter.utf16.count
    let allowsEscapes = delimiter != "'''" && delimiter != "\"\"\"" && delimiter != "```"
    while index < source.length {
      if allowsEscapes, source.character(at: index) == 0x5C {
        index += min(2, source.length - index)
        continue
      }
      if hasPrefix(delimiter, at: index) {
        index += delimiter.utf16.count
        break
      }
      index += utf16CharacterLength(at: index)
    }
    try? append(capture: "string", range: NSRange(location: start, length: index - start))
    return true
  }

  private func scanDirectiveOrAnnotation() -> Bool {
    let unit = source.character(at: index)
    guard unit == 0x23 || unit == 0x40 else { return false }
    if unit == 0x23, rules.comments.line.contains("#") { return false }
    let start = index
    index += 1
    while index < source.length, isIdentifierContinuation(source.character(at: index)) {
      index += utf16CharacterLength(at: index)
    }
    guard index > start + 1 else {
      index = start
      return false
    }
    try? append(
      capture: unit == 0x40 ? "attribute" : "directive",
      range: NSRange(location: start, length: index - start))
    return true
  }

  private func scanNumber() -> Bool {
    guard isASCIIDigit(source.character(at: index)) else { return false }
    let start = index
    index += 1
    while index < source.length {
      let unit = source.character(at: index)
      guard isASCIIDigit(unit) || isASCIIHexLetter(unit) || unit == 0x2E || unit == 0x5F else {
        break
      }
      index += 1
    }
    try? append(capture: "number", range: NSRange(location: start, length: index - start))
    return true
  }

  private func scanIdentifier() -> Bool {
    guard isIdentifierStart(source.character(at: index)) else { return false }
    let start = index
    index += utf16CharacterLength(at: index)
    while index < source.length, isIdentifierContinuation(source.character(at: index)) {
      index += utf16CharacterLength(at: index)
    }

    let range = NSRange(location: start, length: index - start)
    let raw = source.substring(with: range)
    let word = rules.isCaseSensitive ? raw : raw.lowercased()
    let capture: String?

    if let pendingDeclarationCapture {
      capture = pendingDeclarationCapture
      self.pendingDeclarationCapture = nil
    } else if let declarationCapture = rules.declarations[word] {
      capture = "keyword"
      pendingDeclarationCapture = declarationCapture
    } else if rules.keywords.contains(word) {
      capture = keywordCapture(for: word)
    } else if rules.builtInTypes.contains(word) || beginsWithUppercase(raw) {
      capture = "type"
    } else if previousNonWhitespace(before: start) == 0x2E {
      capture = "property"
    } else if nextNonWhitespace(after: index) == 0x28 {
      capture = "function.call"
    } else {
      capture = nil
    }

    if let capture { try? append(capture: capture, range: range) }
    return true
  }

  private func scanOperatorOrPunctuation() -> Bool {
    let unit = source.character(at: index)
    if Self.punctuation.contains(unit) {
      try? append(capture: "punctuation", range: NSRange(location: index, length: 1))
      index += 1
      return true
    }
    guard Self.operatorCharacters.contains(unit) else { return false }
    let start = index
    index += 1
    while index < source.length, Self.operatorCharacters.contains(source.character(at: index)) {
      index += 1
    }
    try? append(capture: "operator", range: NSRange(location: start, length: index - start))
    return true
  }

  private func append(capture: String, range: NSRange) throws {
    guard range.length > 0, NSMaxRange(range) <= snapshot.utf16Count else { return }
    if let requestedRange, requestedRange.length > 0,
      NSIntersectionRange(requestedRange, range).length == 0
    {
      return
    }
    values.append(
      Highlight(
        range: .init(
          start: try snapshot.position(atUTF16Offset: range.location),
          end: try snapshot.position(atUTF16Offset: NSMaxRange(range))
        ),
        capture: capture
      ))
  }

  private func hasPrefix(_ value: String, at location: Int) -> Bool {
    let length = value.utf16.count
    guard length > 0, location >= 0, location + length <= source.length else { return false }
    return source.compare(
      value,
      options: rules.isCaseSensitive ? [] : [.caseInsensitive],
      range: NSRange(location: location, length: length)
    ) == .orderedSame
  }

  private func range(of value: String, from location: Int) -> NSRange? {
    guard location <= source.length else { return nil }
    let result = source.range(
      of: value,
      options: rules.isCaseSensitive ? [] : [.caseInsensitive],
      range: NSRange(location: location, length: source.length - location)
    )
    return result.location == NSNotFound ? nil : result
  }

  private func lineEnd(from location: Int) -> Int {
    NSMaxRange(source.lineRange(for: NSRange(location: location, length: 0)))
  }

  private func previousNonWhitespace(before location: Int) -> unichar? {
    var value = location - 1
    while value >= 0 {
      let unit = source.character(at: value)
      if !isWhitespace(unit) { return unit }
      value -= 1
    }
    return nil
  }

  private func nextNonWhitespace(after location: Int) -> unichar? {
    var value = location
    while value < source.length {
      let unit = source.character(at: value)
      if !isWhitespace(unit) { return unit }
      value += 1
    }
    return nil
  }

  private func keywordCapture(for word: String) -> String {
    switch word {
    case "if", "else", "guard", "switch", "case", "when", "match": return "conditional"
    case "for", "while", "repeat", "loop", "continue", "break": return "repeat"
    case "return", "yield", "throw": return "keyword.return"
    default: return "keyword"
    }
  }

  private func beginsWithUppercase(_ value: String) -> Bool {
    guard let scalar = value.unicodeScalars.first else { return false }
    return CharacterSet.uppercaseLetters.contains(scalar)
  }

  private func utf16CharacterLength(at location: Int) -> Int {
    let unit = source.character(at: location)
    guard unit >= 0xD800, unit <= 0xDBFF, location + 1 < source.length else { return 1 }
    let next = source.character(at: location + 1)
    return next >= 0xDC00 && next <= 0xDFFF ? 2 : 1
  }

  private func isIdentifierStart(_ unit: unichar) -> Bool {
    isASCIILetter(unit) || unit == 0x5F || unit == 0x24 || unit >= 0x80
  }

  private func isIdentifierContinuation(_ unit: unichar) -> Bool {
    isIdentifierStart(unit) || isASCIIDigit(unit)
  }

  private func isASCIILetter(_ unit: unichar) -> Bool {
    (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
  }

  private func isASCIIDigit(_ unit: unichar) -> Bool {
    unit >= 0x30 && unit <= 0x39
  }

  private func isASCIIHexLetter(_ unit: unichar) -> Bool {
    (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66)
  }

  private func isWhitespace(_ unit: unichar) -> Bool {
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
  }

  private static let punctuation = Set<unichar>([
    0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x2C, 0x3B, 0x3A,
  ])
  private static let operatorCharacters = Set<unichar>(
    [0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x3D, 0x21, 0x3C, 0x3E, 0x26, 0x7C, 0x5E, 0x7E, 0x3F]
  )
}

private let genericKeywords: Set<String> = [
  "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
  "default", "defer", "do", "else", "enum", "false", "for", "from", "func", "function",
  "if", "import", "in", "interface", "let", "module", "namespace", "new", "nil", "null",
  "private", "protected", "public", "return", "static", "struct", "switch", "throw", "throws",
  "true", "try", "type", "var", "while", "yield",
]
private let genericTypes: Set<String> = [
  "Any", "Bool", "Boolean", "Byte", "Character", "Double", "Float", "Int", "Integer",
  "Long", "Number", "Object", "Short", "String", "UInt", "Void", "any", "bool", "char",
  "double", "float", "int", "long", "string", "void",
]
private let swiftKeywords = genericKeywords.union([
  "actor", "associatedtype", "convenience", "didSet", "distributed", "dynamic", "extension",
  "fallthrough", "fileprivate", "final", "get", "indirect", "infix", "init", "inout",
  "internal", "isolated", "lazy", "mutating", "nonisolated", "nonmutating", "open", "operator",
  "optional", "override", "package", "postfix", "precedencegroup", "prefix", "protocol", "required",
  "rethrows", "self", "set", "some", "subscript", "super", "typealias", "unowned", "weak", "where",
  "willSet",
])
private let swiftTypes = genericTypes.union([
  "Array", "Character", "Data", "Dictionary", "Error", "Never", "Optional", "Result", "Set",
  "Substring", "URL",
])
private let rustKeywords: Set<String> = [
  "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
  "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
  "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "union",
  "unsafe", "use", "where", "while",
]
private let rustTypes: Set<String> = [
  "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str", "u8", "u16",
  "u32", "u64", "u128", "usize", "Box", "Option", "Result", "String", "Vec",
]
private let goKeywords: Set<String> = [
  "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
  "func",
  "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select",
  "struct",
  "switch", "type", "var",
]
private let goTypes: Set<String> = [
  "any", "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8",
  "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64",
  "uintptr",
]
private let zigKeywords = genericKeywords.union([
  "align", "allowzero", "and", "anyframe", "anytype", "asm", "comptime", "errdefer", "error",
  "export",
  "extern", "noalias", "noinline", "nosuspend", "opaque", "or", "orelse", "packed", "resume",
  "suspend",
  "test", "threadlocal", "unreachable", "usingnamespace", "volatile",
])
private let zigTypes: Set<String> = [
  "anyerror", "anyopaque", "bool", "comptime_float", "comptime_int", "f16", "f32", "f64", "f80",
  "f128",
  "i8", "i16", "i32", "i64", "i128", "isize", "noreturn", "type", "u8", "u16", "u32", "u64", "u128",
  "usize", "void",
]
private let cFamilyKeywords = genericKeywords.union([
  "auto", "constexpr", "decltype", "delete", "explicit", "extern", "friend", "inline", "mutable",
  "noexcept",
  "register", "sizeof", "template", "this", "thread_local", "typedef", "typename", "union", "using",
  "virtual",
  "volatile",
])
private let cFamilyTypes = genericTypes.union([
  "int8_t", "int16_t", "int32_t", "int64_t", "size_t", "uint8_t", "uint16_t", "uint32_t",
  "uint64_t",
  "wchar_t",
])
private let javaKeywords = genericKeywords.union([
  "abstract", "assert", "extends", "final", "finally", "implements", "instanceof", "native",
  "record", "strictfp",
  "synchronized", "this", "transient", "volatile",
])
private let javaTypes = genericTypes.union([
  "BigDecimal", "BigInteger", "List", "Map", "Optional", "Set",
])
private let kotlinKeywords = genericKeywords.union([
  "actual", "annotation", "companion", "crossinline", "data", "expect", "external", "field", "fun",
  "inner",
  "inline", "lateinit", "noinline", "object", "out", "reified", "sealed", "suspend", "tailrec",
  "typealias",
  "val", "when",
])
private let kotlinTypes = genericTypes.union([
  "Any", "Byte", "Char", "Int", "Long", "Nothing", "Short", "Unit",
])
private let webScriptKeywords = genericKeywords.union([
  "debugger", "delete", "export", "extends", "finally", "implements", "instanceof", "keyof", "of",
  "readonly",
  "satisfies", "typeof", "undefined", "unknown",
])
private let webScriptTypes = genericTypes.union([
  "Array", "Promise", "Record", "RegExp", "Symbol", "bigint", "never", "number", "object", "symbol",
  "unknown",
])
private let pythonKeywords: Set<String> = [
  "False", "None", "True", "and", "as", "assert", "async", "await", "break", "case", "class",
  "continue", "def",
  "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is",
  "lambda",
  "match", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
]
private let pythonTypes: Set<String> = [
  "bool", "bytes", "complex", "dict", "float", "frozenset", "int", "list", "object", "set", "str",
  "tuple", "type",
]
private let rubyKeywords: Set<String> = [
  "BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else",
  "elsif",
  "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
  "rescue", "retry",
  "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield",
]
private let rubyTypes: Set<String> = [
  "Array", "Class", "FalseClass", "Float", "Hash", "Integer", "Module", "NilClass", "Object",
  "String", "Symbol",
  "TrueClass",
]
private let phpKeywords = genericKeywords.union([
  "abstract", "callable", "clone", "declare", "echo", "enddeclare", "endfor", "endforeach", "endif",
  "endswitch",
  "endwhile", "extends", "final", "finally", "global", "implements", "include", "include_once",
  "instanceof", "insteadof",
  "new", "print", "require", "require_once", "trait", "unset",
])
private let phpTypes = genericTypes.union(["array", "callable", "iterable", "mixed", "never"])
private let dotnetKeywords = genericKeywords.union([
  "abstract", "add", "alias", "ascending", "base", "checked", "delegate", "descending", "event",
  "explicit", "extern",
  "fixed", "foreach", "implicit", "is", "lock", "nameof", "out", "readonly", "record", "ref",
  "sealed", "stackalloc",
  "this", "unchecked", "unsafe", "using", "virtual",
])
private let dotnetTypes = genericTypes.union([
  "decimal", "dynamic", "nint", "nuint", "sbyte", "uint", "ulong", "ushort",
])
private let dartKeywords = genericKeywords.union([
  "abstract", "covariant", "deferred", "external", "extension", "factory", "final", "get",
  "implements", "late",
  "mixin", "on", "part", "required", "set", "show", "sync", "typedef", "with",
])
private let dartTypes = genericTypes.union([
  "Future", "List", "Map", "Never", "Set", "dynamic", "num",
])
private let scalaKeywords = genericKeywords.union([
  "abstract", "case", "derives", "end", "export", "extends", "given", "implicit", "inline", "lazy",
  "match", "object",
  "opaque", "sealed", "trait", "transparent", "using", "val", "with",
])
private let scalaTypes = genericTypes.union([
  "AnyVal", "BigDecimal", "BigInt", "List", "Map", "Nothing", "Option", "Seq",
])
private let luaKeywords: Set<String> = [
  "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
  "local", "nil",
  "not", "or", "repeat", "return", "then", "true", "until", "while",
]
private let shellKeywords: Set<String> = [
  "case", "coproc", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if",
  "in", "local",
  "readonly", "return", "select", "then", "time", "typeset", "until", "while",
]
private let sqlKeywords: Set<String> = [
  "add", "all", "alter", "and", "as", "asc", "between", "by", "case", "check", "column",
  "constraint", "create",
  "database", "default", "delete", "desc", "distinct", "drop", "else", "end", "exists", "foreign",
  "from", "full",
  "group", "having", "in", "index", "inner", "insert", "into", "is", "join", "key", "left", "like",
  "limit", "not",
  "null", "on", "or", "order", "outer", "primary", "references", "right", "select", "set", "table",
  "then", "union",
  "unique", "update", "values", "view", "when", "where", "with",
]
private let sqlTypes: Set<String> = [
  "bigint", "binary", "bit", "blob", "boolean", "char", "date", "datetime", "decimal", "double",
  "float", "int", "integer",
  "json", "numeric", "real", "smallint", "text", "time", "timestamp", "varchar",
]
private let htmlKeywords: Set<String> = [
  "DOCTYPE", "html", "head", "body", "script", "style", "template", "div", "span", "main",
  "section", "article", "nav",
  "header", "footer", "button", "input", "form", "label", "a", "img", "link", "meta",
]
private let cssKeywords: Set<String> = [
  "important", "inherit", "initial", "unset", "revert", "none", "auto", "block", "inline", "flex",
  "grid", "absolute",
  "relative", "fixed", "sticky", "hidden", "visible", "transparent",
]
private let dataKeywords: Set<String> = [
  "true", "false", "null", "yes", "no", "on", "off", "from", "run", "cmd", "entrypoint", "copy",
  "add", "env", "arg",
  "workdir", "expose", "volume", "user", "label",
]
