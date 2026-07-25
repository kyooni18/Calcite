import Foundation

/// A platform-independent sRGB color used by editor themes.
///
/// The Codable representation is a CSS-style hexadecimal string. Six-digit
/// values are opaque (`#RRGGBB`) and eight-digit values include alpha
/// (`#RRGGBBAA`). Decoding also accepts three- and four-digit shorthand.
public struct EditorColor: Hashable, Sendable, Codable, CustomStringConvertible {
  public var red: UInt8
  public var green: UInt8
  public var blue: UInt8
  public var alpha: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public init(rgb: UInt32, alpha: UInt8 = 255) {
    self.init(
      red: UInt8((rgb >> 16) & 0xFF),
      green: UInt8((rgb >> 8) & 0xFF),
      blue: UInt8(rgb & 0xFF),
      alpha: alpha
    )
  }

  public init?(hex: String) {
    let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.caseInsensitiveCompare("transparent") == .orderedSame {
      self.init(red: 0, green: 0, blue: 0, alpha: 0)
      return
    }

    guard value.first == "#" else { return nil }
    let digits = String(value.dropFirst())
    guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }

    func nibble(_ character: Character) -> UInt8? {
      UInt8(String(character), radix: 16)
    }

    switch digits.count {
    case 3:
      let values = digits.compactMap(nibble)
      guard values.count == 3 else { return nil }
      self.init(red: values[0] * 17, green: values[1] * 17, blue: values[2] * 17)
    case 4:
      let values = digits.compactMap(nibble)
      guard values.count == 4 else { return nil }
      self.init(
        red: values[0] * 17,
        green: values[1] * 17,
        blue: values[2] * 17,
        alpha: values[3] * 17
      )
    case 6:
      guard let packed = UInt32(digits, radix: 16) else { return nil }
      self.init(rgb: packed)
    case 8:
      guard let packed = UInt32(digits, radix: 16) else { return nil }
      self.init(
        red: UInt8((packed >> 24) & 0xFF),
        green: UInt8((packed >> 16) & 0xFF),
        blue: UInt8((packed >> 8) & 0xFF),
        alpha: UInt8(packed & 0xFF)
      )
    default:
      return nil
    }
  }

  public var rgbValue: UInt32 {
    (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
  }

  public var hexRGB: String {
    String(format: "#%02X%02X%02X", red, green, blue)
  }

  public var hexRGBA: String {
    String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
  }

  public var description: String { alpha == 255 ? hexRGB : hexRGBA }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let string = try? container.decode(String.self), let color = EditorColor(hex: string) {
      self = color
      return
    }
    if let integer = try? container.decode(UInt32.self), integer <= 0xFF_FF_FF {
      self.init(rgb: integer)
      return
    }
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Expected #RGB, #RGBA, #RRGGBB, #RRGGBBAA, transparent, or a 24-bit integer"
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }

  public static let clear = EditorColor(red: 0, green: 0, blue: 0, alpha: 0)
  public static let black = EditorColor(red: 0, green: 0, blue: 0)
  public static let white = EditorColor(red: 255, green: 255, blue: 255)
}

public enum EditorFontStyle: String, Hashable, Codable, Sendable, CaseIterable {
  case bold
  case italic
  case underline
  case undercurl
  case strikethrough
  case dim
  case reverse
}

/// Visual attributes for a syntax or semantic token.
///
/// `fontStyles == nil` means that the rule does not change font styles, while
/// an empty set explicitly clears inherited styles.
public struct EditorTextStyle: Hashable, Codable, Sendable {
  public var foreground: EditorColor?
  public var background: EditorColor?
  public var specialColor: EditorColor?
  public var fontStyles: Set<EditorFontStyle>?

  public init(
    foreground: EditorColor? = nil,
    background: EditorColor? = nil,
    specialColor: EditorColor? = nil,
    fontStyles: Set<EditorFontStyle>? = nil
  ) {
    self.foreground = foreground
    self.background = background
    self.specialColor = specialColor
    self.fontStyles = fontStyles
  }

  public var isEmpty: Bool {
    foreground == nil && background == nil && specialColor == nil && fontStyles == nil
  }

  /// Applies all explicitly specified attributes from `overlay`.
  public mutating func merge(_ overlay: EditorTextStyle) {
    if let foreground = overlay.foreground { self.foreground = foreground }
    if let background = overlay.background { self.background = background }
    if let specialColor = overlay.specialColor { self.specialColor = specialColor }
    if let fontStyles = overlay.fontStyles { self.fontStyles = fontStyles }
  }

  public func merging(_ overlay: EditorTextStyle) -> EditorTextStyle {
    var result = self
    result.merge(overlay)
    return result
  }
}

public enum EditorThemeAppearance: String, Hashable, Codable, Sendable {
  case unspecified
  case light
  case dark
  case highContrastLight
  case highContrastDark
}

public enum EditorThemeSource: String, Hashable, Codable, Sendable {
  case editorServices
  case vsCode
  case neovim
  case vim
}

public enum EditorThemeSelectorKind: String, Hashable, Codable, Sendable {
  /// EditorServices and Tree-sitter capture names, such as `keyword` or `function.call`.
  case syntax
  /// LSP semantic-token selectors.
  case semantic
  /// Original TextMate scopes retained from a VS Code theme.
  case textMate
  /// Original Vim/Neovim highlight groups.
  case vim
}

/// Selects tokens to which a theme rule applies.
public struct EditorThemeSelector: Hashable, Codable, Sendable {
  public var kind: EditorThemeSelectorKind
  public var value: String
  public var modifiers: Set<String>
  public var languageID: String?

  public init(
    kind: EditorThemeSelectorKind,
    value: String,
    modifiers: Set<String> = [],
    languageID: String? = nil
  ) {
    self.kind = kind
    self.value = value
    self.modifiers = modifiers
    self.languageID = languageID
  }

  public static func syntax(_ capture: String, languageID: String? = nil) -> Self {
    .init(kind: .syntax, value: capture, languageID: languageID)
  }

  public static func semantic(
    _ tokenType: String,
    modifiers: Set<String> = [],
    languageID: String? = nil
  ) -> Self {
    .init(kind: .semantic, value: tokenType, modifiers: modifiers, languageID: languageID)
  }

  public static func textMate(_ scope: String) -> Self {
    .init(kind: .textMate, value: scope)
  }

  public static func vim(_ group: String) -> Self {
    .init(kind: .vim, value: group)
  }
}

public struct EditorThemeRule: Hashable, Codable, Sendable {
  public var name: String?
  public var selectors: [EditorThemeSelector]
  public var style: EditorTextStyle

  public init(
    name: String? = nil,
    selectors: [EditorThemeSelector],
    style: EditorTextStyle
  ) {
    self.name = name
    self.selectors = selectors
    self.style = style
  }
}

/// A normalized, UI-framework-independent editor theme.
///
/// `colors` preserves external UI color keys (for example
/// `editor.background`) so applications can decide which surfaces they use.
/// `rules` contains normalized syntax/semantic selectors and also retains the
/// original TextMate or Vim selectors for custom resolution.
public struct EditorTheme: Hashable, Codable, Sendable {
  public var name: String
  public var appearance: EditorThemeAppearance
  public var source: EditorThemeSource
  public var colors: [String: EditorColor]
  public var rules: [EditorThemeRule]
  public var metadata: [String: String]

  public init(
    name: String,
    appearance: EditorThemeAppearance = .unspecified,
    source: EditorThemeSource = .editorServices,
    colors: [String: EditorColor] = [:],
    rules: [EditorThemeRule] = [],
    metadata: [String: String] = [:]
  ) {
    self.name = name
    self.appearance = appearance
    self.source = source
    self.colors = colors
    self.rules = rules
    self.metadata = metadata
  }

  public subscript(color key: String) -> EditorColor? {
    get { colors[key] }
    set { colors[key] = newValue }
  }

  public var editorForeground: EditorColor? { colors["editor.foreground"] }
  public var editorBackground: EditorColor? { colors["editor.background"] }

  public func style(for highlight: Highlight, languageID: String? = nil) -> EditorTextStyle? {
    style(forSyntaxCapture: highlight.capture, languageID: languageID)
  }

  public func style(
    for semanticHighlight: SemanticHighlight,
    languageID: String? = nil
  ) -> EditorTextStyle? {
    style(
      forSemanticTokenType: semanticHighlight.tokenType,
      modifiers: Set(semanticHighlight.modifiers),
      languageID: languageID
    )
  }

  /// Resolves a Tree-sitter/EditorServices capture by applying matching rules in declaration order.
  public func style(
    forSyntaxCapture capture: String,
    languageID: String? = nil
  ) -> EditorTextStyle? {
    let normalizedCapture = Self.normalizeCapture(capture)
    let textMateCandidates = EditorThemeScopeMapping.textMateScopes(forSyntaxCapture: normalizedCapture)
    let vimCandidates = EditorThemeScopeMapping.vimGroups(forSyntaxCapture: normalizedCapture)
    let matchingRules = rules.enumerated().compactMap { index, rule -> (Int, Int, EditorTextStyle)? in
      let score = rule.selectors.compactMap { selector in
        Self.syntaxMatchScore(
          selector,
          capture: normalizedCapture,
          languageID: languageID,
          textMateCandidates: textMateCandidates,
          vimCandidates: vimCandidates
        )
      }.max()
      guard let score else { return nil }
      return (score, index, rule.style)
    }.sorted { lhs, rhs in
      lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
    }

    guard !matchingRules.isEmpty else { return nil }
    var result = EditorTextStyle()
    for (_, _, style) in matchingRules { result.merge(style) }
    return result
  }

  /// Resolves an LSP semantic token by applying matching rules in declaration order.
  public func style(
    forSemanticTokenType tokenType: String,
    modifiers: Set<String> = [],
    languageID: String? = nil
  ) -> EditorTextStyle? {
    let type = tokenType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedModifiers = Set(modifiers.map { $0.lowercased() })
    let matchingRules = rules.enumerated().compactMap { index, rule -> (Int, Int, EditorTextStyle)? in
      let score = rule.selectors.compactMap { selector in
        Self.semanticMatchScore(
          selector,
          tokenType: type,
          modifiers: normalizedModifiers,
          languageID: languageID
        )
      }.max()
      guard let score else { return nil }
      return (score, index, rule.style)
    }.sorted { lhs, rhs in
      lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
    }

    guard !matchingRules.isEmpty else { return nil }
    var result = EditorTextStyle()
    for (_, _, style) in matchingRules { result.merge(style) }
    return result
  }

  /// Returns a base theme overlaid by this theme. Rules from the overlay remain later in order.
  public func overlaying(_ overlay: EditorTheme) -> EditorTheme {
    var mergedColors = colors
    mergedColors.merge(overlay.colors) { _, new in new }
    var mergedMetadata = metadata
    mergedMetadata.merge(overlay.metadata) { _, new in new }
    return EditorTheme(
      name: overlay.name.isEmpty ? name : overlay.name,
      appearance: overlay.appearance == .unspecified ? appearance : overlay.appearance,
      source: overlay.source,
      colors: mergedColors,
      rules: rules + overlay.rules,
      metadata: mergedMetadata
    )
  }

  public func encodedJSON(prettyPrinted: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
    return try encoder.encode(self)
  }

  private static func syntaxMatchScore(
    _ selector: EditorThemeSelector,
    capture: String,
    languageID: String?,
    textMateCandidates: [String],
    vimCandidates: [String]
  ) -> Int? {
    guard languageMatches(selector.languageID, requested: languageID) else { return nil }
    let languageScore = selector.languageID == nil ? 0 : 10_000
    switch selector.kind {
    case .syntax:
      let pattern = normalizeCapture(selector.value)
      guard hierarchicalMatch(pattern: pattern, value: capture) else { return nil }
      return languageScore + 3_000 + selectorSpecificity(pattern, exactValue: capture)
    case .textMate:
      let pattern = selector.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let scores = textMateCandidates.compactMap { candidate -> Int? in
        guard hierarchicalMatch(pattern: pattern, value: candidate) else { return nil }
        return selectorSpecificity(pattern, exactValue: candidate)
      }
      guard let score = scores.max() else { return nil }
      return languageScore + 2_000 + score
    case .vim:
      let pattern = selector.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard vimCandidates.contains(where: { $0.lowercased() == pattern }) else { return nil }
      return languageScore + 1_000 + selectorSpecificity(pattern, exactValue: pattern)
    case .semantic:
      return nil
    }
  }

  private static func semanticMatchScore(
    _ selector: EditorThemeSelector,
    tokenType: String,
    modifiers: Set<String>,
    languageID: String?
  ) -> Int? {
    guard selector.kind == .semantic else { return nil }
    guard languageMatches(selector.languageID, requested: languageID) else { return nil }
    let selectedType = selector.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard selectedType == "*" || selectedType == tokenType else { return nil }
    let selectedModifiers = Set(selector.modifiers.map { $0.lowercased() })
    guard selectedModifiers.isSubset(of: modifiers) else { return nil }
    let languageScore = selector.languageID == nil ? 0 : 10_000
    let typeScore = selectedType == "*" ? 0 : 1_000
    return languageScore + typeScore + selectedModifiers.count * 100
  }

  private static func selectorSpecificity(_ pattern: String, exactValue: String) -> Int {
    if pattern == "*" { return 0 }
    let componentScore = pattern.split(separator: ".").count * 10
    return componentScore + (pattern == exactValue ? 5 : 0)
  }

  private static func languageMatches(_ selector: String?, requested: String?) -> Bool {
    guard let selector, !selector.isEmpty else { return true }
    guard let requested else { return false }
    return selector.caseInsensitiveCompare(requested) == .orderedSame
  }

  private static func hierarchicalMatch(pattern: String, value: String) -> Bool {
    guard !pattern.isEmpty else { return false }
    if pattern == "*" { return true }
    return value == pattern || value.hasPrefix(pattern + ".")
  }

  private static func normalizeCapture(_ value: String) -> String {
    var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while result.first == "@" { result.removeFirst() }
    return result
  }
}

/// Mappings used when external themes do not directly name EditorServices captures.
public enum EditorThemeScopeMapping {
  /// Converts a TextMate scope to common Tree-sitter/EditorServices captures.
  public static func syntaxCaptures(forTextMateScope scope: String) -> [String] {
    let value = scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !value.isEmpty else { return [] }

    let mappings: [(String, [String])] = [
      ("comment", ["comment"]),
      ("string.regexp", ["string.regexp"]),
      ("string", ["string"]),
      ("constant.numeric", ["number", "constant.numeric"]),
      ("constant.language.boolean", ["boolean", "constant.builtin"]),
      ("constant.language", ["constant.builtin"]),
      ("constant.character", ["character", "string.special"]),
      ("constant", ["constant"]),
      ("keyword.operator", ["operator"]),
      ("keyword", ["keyword"]),
      ("storage.type", ["keyword", "type.qualifier"]),
      ("storage.modifier", ["keyword.modifier"]),
      ("entity.name.function", ["function"]),
      ("entity.name.type", ["type"]),
      ("entity.name.class", ["type", "type.class"]),
      ("entity.name.struct", ["type", "type.struct"]),
      ("entity.name.enum", ["type", "type.enum"]),
      ("entity.name.interface", ["type", "type.interface"]),
      ("entity.name.namespace", ["namespace", "module"]),
      ("entity.name.tag", ["tag"]),
      ("entity.other.attribute-name", ["attribute"]),
      ("variable.parameter", ["variable.parameter"]),
      ("variable.language", ["variable.builtin"]),
      ("variable.other.member", ["variable.member", "property"]),
      ("variable.other.property", ["property"]),
      ("variable", ["variable"]),
      ("support.function", ["function.builtin"]),
      ("support.type", ["type.builtin"]),
      ("support.class", ["type.builtin"]),
      ("support.constant", ["constant.builtin"]),
      ("punctuation.bracket", ["punctuation.bracket"]),
      ("punctuation.delimiter", ["punctuation.delimiter"]),
      ("punctuation", ["punctuation"]),
      ("markup.heading", ["markup.heading"]),
      ("markup.bold", ["markup.strong"]),
      ("markup.italic", ["markup.italic"]),
      ("markup.underline.link", ["markup.link"]),
      ("markup.quote", ["markup.quote"]),
      ("markup.raw", ["markup.raw"]),
      ("markup.inserted", ["diff.plus"]),
      ("markup.deleted", ["diff.minus"]),
      ("markup.changed", ["diff.delta"]),
      ("invalid", ["error"]),
      ("meta.preprocessor", ["keyword.directive"]),
    ]

    var captures: [String] = []
    for (prefix, mapped) in mappings where value == prefix || value.hasPrefix(prefix + ".") {
      captures.append(contentsOf: mapped)
    }
    return unique(captures)
  }

  /// Converts a Vim/Neovim highlight group to common captures.
  public static func syntaxCaptures(forVimGroup group: String) -> [String] {
    let original = group.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !original.isEmpty else { return [] }
    if original.first == "@" {
      return [String(original.dropFirst()).lowercased()]
    }

    switch original.lowercased() {
    case "comment", "specialcomment": return ["comment"]
    case "constant": return ["constant"]
    case "string": return ["string"]
    case "character": return ["character", "string.special"]
    case "number", "float": return ["number"]
    case "boolean": return ["boolean", "constant.builtin"]
    case "identifier": return ["variable"]
    case "function": return ["function"]
    case "statement", "conditional", "repeat", "label", "keyword", "exception": return ["keyword"]
    case "operator": return ["operator"]
    case "preproc", "include", "define", "macro", "precondit": return ["keyword.directive"]
    case "type": return ["type"]
    case "storageclass": return ["keyword.modifier", "type.qualifier"]
    case "structure", "typedef": return ["type"]
    case "special", "specialchar", "debug": return ["string.special"]
    case "tag": return ["tag"]
    case "delimiter": return ["punctuation.delimiter"]
    case "error", "errormsg": return ["error"]
    case "todo": return ["comment.todo"]
    default: return []
    }
  }

  public static func textMateScopes(forSyntaxCapture capture: String) -> [String] {
    let value = capture.lowercased()
    var scopes: [String] = []
    for candidate in textMateReverseMappings where value == candidate.capture || value.hasPrefix(candidate.capture + ".") {
      scopes.append(contentsOf: candidate.scopes)
    }
    return unique(scopes)
  }

  public static func vimGroups(forSyntaxCapture capture: String) -> [String] {
    let value = capture.lowercased()
    var groups = ["@" + value]
    let mappings: [(String, [String])] = [
      ("comment", ["Comment"]),
      ("string", ["String"]),
      ("character", ["Character"]),
      ("number", ["Number", "Float"]),
      ("boolean", ["Boolean"]),
      ("constant", ["Constant"]),
      ("variable", ["Identifier"]),
      ("property", ["Identifier"]),
      ("function", ["Function"]),
      ("keyword.directive", ["PreProc"]),
      ("keyword", ["Keyword", "Statement"]),
      ("operator", ["Operator"]),
      ("type", ["Type"]),
      ("tag", ["Tag"]),
      ("punctuation", ["Delimiter"]),
      ("error", ["Error"]),
    ]
    for (prefix, mapped) in mappings where value == prefix || value.hasPrefix(prefix + ".") {
      groups.append(contentsOf: mapped)
    }
    return unique(groups)
  }

  private static let textMateReverseMappings: [(capture: String, scopes: [String])] = [
    ("comment", ["comment"]),
    ("string.regexp", ["string.regexp"]),
    ("string", ["string"]),
    ("character", ["constant.character", "string"]),
    ("number", ["constant.numeric"]),
    ("boolean", ["constant.language.boolean", "constant.language"]),
    ("constant.builtin", ["constant.language", "support.constant"]),
    ("constant", ["constant"]),
    ("operator", ["keyword.operator"]),
    ("keyword.modifier", ["storage.modifier", "keyword"]),
    ("keyword.directive", ["meta.preprocessor", "keyword"]),
    ("keyword", ["keyword", "storage.type"]),
    ("function.builtin", ["support.function", "entity.name.function"]),
    ("function", ["entity.name.function"]),
    ("type.builtin", ["support.type", "support.class", "entity.name.type"]),
    ("type", ["entity.name.type", "storage.type"]),
    ("namespace", ["entity.name.namespace"]),
    ("module", ["entity.name.namespace"]),
    ("variable.parameter", ["variable.parameter"]),
    ("variable.builtin", ["variable.language", "variable"]),
    ("variable.member", ["variable.other.member", "variable"]),
    ("property", ["variable.other.property", "variable.other.member"]),
    ("variable", ["variable"]),
    ("attribute", ["entity.other.attribute-name"]),
    ("tag", ["entity.name.tag"]),
    ("punctuation.bracket", ["punctuation.bracket"]),
    ("punctuation.delimiter", ["punctuation.delimiter"]),
    ("punctuation", ["punctuation"]),
    ("markup.heading", ["markup.heading"]),
    ("markup.strong", ["markup.bold"]),
    ("markup.italic", ["markup.italic"]),
    ("markup.link", ["markup.underline.link"]),
    ("markup.quote", ["markup.quote"]),
    ("markup.raw", ["markup.raw"]),
    ("diff.plus", ["markup.inserted"]),
    ("diff.minus", ["markup.deleted"]),
    ("diff.delta", ["markup.changed"]),
    ("error", ["invalid"]),
  ]

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }
}
