import AppKit
import EditorServices
import SwiftUI

struct EditorRGBAColor: Codable, Equatable, Hashable, Sendable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double

  init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }
}

enum EditorFontWeight: String, CaseIterable, Codable, Identifiable, Sendable {
  case light, regular, medium, semibold, bold

  var id: String { rawValue }
}

struct EditorFontProfile: Codable, Equatable, Sendable {
  var family: String
  var size: Double
  var weight: EditorFontWeight
  var lineSpacing: Double
}

enum EditorCursorStyle: String, CaseIterable, Codable, Identifiable, Sendable {
  case line
  case block
  case underline

  var id: String { rawValue }

  var title: String {
    switch self {
    case .line: "Line"
    case .block: "Block"
    case .underline: "Underline"
    }
  }
}

/// Vim modes can inherit the editor-wide cursor shape or opt into an explicit
/// shape for that mode.
enum EditorVimCursorStyle: String, CaseIterable, Codable, Identifiable, Sendable {
  case `default`
  case line
  case block
  case underline

  var id: String { rawValue }

  var title: String {
    switch self {
    case .default: "Default"
    case .line: "Line"
    case .block: "Block"
    case .underline: "Underline"
    }
  }

  /// `nil` deliberately leaves the editor-wide cursor untouched; non-nil values
  /// are the Vim-only override.
  var overrideStyle: EditorCursorStyle? {
    switch self {
    case .default: nil
    case .line: .line
    case .block: .block
    case .underline: .underline
    }
  }
}

struct EditorSurfaceProfile: Codable, Equatable, Sendable {
  var foreground: EditorRGBAColor
  var background: EditorRGBAColor
  var backgroundOpacity: Double
  var cursor: EditorRGBAColor
  var cursorStyle: EditorCursorStyle
  var selection: EditorRGBAColor

  init(
    foreground: EditorRGBAColor,
    background: EditorRGBAColor,
    backgroundOpacity: Double,
    cursor: EditorRGBAColor,
    cursorStyle: EditorCursorStyle = .line,
    selection: EditorRGBAColor
  ) {
    self.foreground = foreground
    self.background = background
    self.backgroundOpacity = backgroundOpacity
    self.cursor = cursor
    self.cursorStyle = cursorStyle
    self.selection = selection
  }

  private enum CodingKeys: String, CodingKey {
    case foreground
    case background
    case backgroundOpacity
    case cursor
    case cursorStyle
    case selection
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    foreground = try container.decode(EditorRGBAColor.self, forKey: .foreground)
    background = try container.decode(EditorRGBAColor.self, forKey: .background)
    backgroundOpacity = try container.decode(Double.self, forKey: .backgroundOpacity)
    cursor = try container.decode(EditorRGBAColor.self, forKey: .cursor)
    cursorStyle =
      try container.decodeIfPresent(EditorCursorStyle.self, forKey: .cursorStyle) ?? .line
    selection = try container.decode(EditorRGBAColor.self, forKey: .selection)
  }
}

struct EditorHighlightProfile: Codable, Equatable, Sendable {
  var currentLine: EditorRGBAColor
  var searchResult: EditorRGBAColor
  var error: EditorRGBAColor
  var warning: EditorRGBAColor
  var information: EditorRGBAColor
  var hint: EditorRGBAColor
}

struct EditorLiteralPalette: Codable, Equatable, Sendable {
  var keyword: EditorRGBAColor
  var string: EditorRGBAColor
  var number: EditorRGBAColor
  var comment: EditorRGBAColor
  var directive: EditorRGBAColor
}

struct EditorSymbolPalette: Codable, Equatable, Sendable {
  var type: EditorRGBAColor
  var function: EditorRGBAColor
  var variable: EditorRGBAColor
  var property: EditorRGBAColor
  var `operator`: EditorRGBAColor
  var punctuation: EditorRGBAColor
}

struct EditorSyntaxPalette: Codable, Equatable, Sendable {
  var literals: EditorLiteralPalette
  var symbols: EditorSymbolPalette
}

struct EditorWorkbenchProfile: Codable, Equatable, Sendable {
  var foreground: EditorRGBAColor
  var mutedForeground: EditorRGBAColor
  var windowBackground: EditorRGBAColor
  var sidebarBackground: EditorRGBAColor
  var panelBackground: EditorRGBAColor
  var toolbarBackground: EditorRGBAColor
  var activeTabBackground: EditorRGBAColor
  var inactiveTabBackground: EditorRGBAColor
  var inputBackground: EditorRGBAColor
  var border: EditorRGBAColor
  var accent: EditorRGBAColor
}

struct EditorTerminalProfile: Codable, Equatable, Sendable {
  var foreground: EditorRGBAColor
  var background: EditorRGBAColor
  var ansi: [EditorRGBAColor]

  func ansiColor(at index: Int) -> EditorRGBAColor? {
    ansi.indices.contains(index) ? ansi[index] : nil
  }
}

struct EditorThemeVisualSnapshot: Codable, Equatable, Sendable {
  var surface: EditorSurfaceProfile
  var highlights: EditorHighlightProfile
  var syntax: EditorSyntaxPalette
  var workbench: EditorWorkbenchProfile
  var terminal: EditorTerminalProfile
}

enum EditorImportedThemeAppearance: String, CaseIterable, Codable, Identifiable, Sendable {
  case automatic
  case light
  case dark
  case fixed

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: "Automatic"
    case .light: "Treat as Light"
    case .dark: "Treat as Dark"
    case .fixed: "Keep Regardless of System Appearance"
    }
  }
}

struct EditorThemeMetadataProfile: Codable, Equatable, Sendable {
  var importedName: String?
  var sourcePath: String?
  var sourceVariantPath: String?
  var sourceModificationTime: TimeInterval?
  var importedAppearance: EditorImportedThemeAppearance
  var importerDiagnostics: [String]
  var importedBaseline: EditorThemeVisualSnapshot?

  var monitoredSourceURL: URL? {
    guard let sourcePath else { return nil }
    let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
      return sourceURL
    }
    guard isDirectory.boolValue,
      let sourceVariantPath,
      !sourceVariantPath.isEmpty
    else { return sourceURL }
    return sourceURL.appendingPathComponent(sourceVariantPath).standardizedFileURL
  }

  static let custom = EditorThemeMetadataProfile(
    importedName: nil,
    sourcePath: nil,
    sourceVariantPath: nil,
    sourceModificationTime: nil,
    importedAppearance: .automatic,
    importerDiagnostics: [],
    importedBaseline: nil
  )
}

enum EditorThemeSlot: String, CaseIterable, Identifiable, Codable, Sendable {
  case light
  case dark

  var id: String { rawValue }
  var title: String { rawValue.capitalized }
}

struct EditorBehaviorProfile: Codable, Equatable, Sendable {
  var tabWidth: Int
  var insertSpaces: Bool
  var suggestionDelay: Double
  var showLineNumbers: Bool
  var showDiagnostics: Bool
  var showInlineDiagnosticMessages: Bool

  private enum CodingKeys: String, CodingKey {
    case tabWidth, insertSpaces, suggestionDelay, showLineNumbers, showDiagnostics
    case showInlineDiagnosticMessages
  }

  init(
    tabWidth: Int,
    insertSpaces: Bool,
    suggestionDelay: Double,
    showLineNumbers: Bool,
    showDiagnostics: Bool,
    showInlineDiagnosticMessages: Bool = true
  ) {
    self.tabWidth = tabWidth
    self.insertSpaces = insertSpaces
    self.suggestionDelay = suggestionDelay
    self.showLineNumbers = showLineNumbers
    self.showDiagnostics = showDiagnostics
    self.showInlineDiagnosticMessages = showInlineDiagnosticMessages
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tabWidth = try container.decode(Int.self, forKey: .tabWidth)
    insertSpaces = try container.decode(Bool.self, forKey: .insertSpaces)
    suggestionDelay = try container.decode(Double.self, forKey: .suggestionDelay)
    showLineNumbers = try container.decode(Bool.self, forKey: .showLineNumbers)
    showDiagnostics = try container.decode(Bool.self, forKey: .showDiagnostics)
    showInlineDiagnosticMessages =
      try container.decodeIfPresent(
        Bool.self,
        forKey: .showInlineDiagnosticMessages
      ) ?? true
  }
}

struct EditorTypingProfile: Codable, Equatable, Sendable {
  var closePairs: Bool
  var surroundSelection: Bool
  var smartNewlines: Bool
  var deleteBalancedPairs: Bool

  static let standard = EditorTypingProfile(
    closePairs: true,
    surroundSelection: true,
    smartNewlines: true,
    deleteBalancedPairs: true
  )
}

struct EditorUserSnippet: Codable, Equatable, Hashable, Identifiable, Sendable {
  var id: UUID
  var languageID: String
  var trigger: String
  var body: String
  var summary: String

  init(
    id: UUID = UUID(),
    languageID: String,
    trigger: String,
    body: String,
    summary: String = "User snippet"
  ) {
    self.id = id
    self.languageID = languageID
    self.trigger = trigger
    self.body = body
    self.summary = summary
  }
}

struct EditorSnippetProfile: Codable, Equatable, Sendable {
  var includeBuiltins: Bool
  var includeProjectFiles: Bool
  var custom: [EditorUserSnippet]

  static let standard = EditorSnippetProfile(
    includeBuiltins: true,
    includeProjectFiles: true,
    custom: []
  )
}

struct EditorVimMappingProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
  var id: UUID
  var sequence: String
  var command: String

  init(id: UUID = UUID(), sequence: String, command: String) {
    self.id = id
    self.sequence = sequence
    self.command = command
  }
}

struct EditorVimProfile: Codable, Equatable, Sendable {
  var enabled: Bool
  var startInInsertMode: Bool
  var leader: String
  var relativeLineNumbers: Bool
  var normalCursorStyle: EditorVimCursorStyle
  var insertCursorStyle: EditorVimCursorStyle
  var replaceCursorStyle: EditorVimCursorStyle
  var mappings: [EditorVimMappingProfile]

  init(
    enabled: Bool,
    startInInsertMode: Bool,
    leader: String,
    relativeLineNumbers: Bool,
    normalCursorStyle: EditorVimCursorStyle = .default,
    insertCursorStyle: EditorVimCursorStyle = .default,
    replaceCursorStyle: EditorVimCursorStyle = .default,
    mappings: [EditorVimMappingProfile]
  ) {
    self.enabled = enabled
    self.startInInsertMode = startInInsertMode
    self.leader = leader
    self.relativeLineNumbers = relativeLineNumbers
    self.normalCursorStyle = normalCursorStyle
    self.insertCursorStyle = insertCursorStyle
    self.replaceCursorStyle = replaceCursorStyle
    self.mappings = mappings
  }

  private enum CodingKeys: String, CodingKey {
    case enabled, startInInsertMode, leader, relativeLineNumbers
    case normalCursorStyle, insertCursorStyle, replaceCursorStyle, mappings
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decode(Bool.self, forKey: .enabled)
    startInInsertMode = try container.decode(Bool.self, forKey: .startInInsertMode)
    leader = try container.decode(String.self, forKey: .leader)
    relativeLineNumbers = try container.decode(Bool.self, forKey: .relativeLineNumbers)
    normalCursorStyle = try Self.decodeCursorStyle(
      from: container,
      key: .normalCursorStyle,
      legacyDefault: .block
    )
    insertCursorStyle = try Self.decodeCursorStyle(
      from: container,
      key: .insertCursorStyle,
      legacyDefault: .line
    )
    replaceCursorStyle = try Self.decodeCursorStyle(
      from: container,
      key: .replaceCursorStyle,
      legacyDefault: .underline
    )
    mappings = Self.mergingNavigationMappings(
      into: try container.decode([EditorVimMappingProfile].self, forKey: .mappings)
    )
  }

  private static func decodeCursorStyle(
    from container: KeyedDecodingContainer<CodingKeys>,
    key: CodingKeys,
    legacyDefault: EditorVimCursorStyle
  ) throws -> EditorVimCursorStyle {
    if let style = try container.decodeIfPresent(EditorVimCursorStyle.self, forKey: key) {
      return style
    }
    return legacyDefault
  }

  /// A native key event produces one character token. Older saved profiles may
  /// contain an empty or multi-character leader, so normalize at the boundary
  /// before handing it to the Vim engine. This applies only to Calcite's native
  /// Vim mode; terminal Vim/Neovim use direct Command-Option host shortcuts.
  var normalizedLeader: String {
    leader.first.map(String.init) ?? " "
  }

  /// Profiles are persisted per appearance slot. These reserved navigation
  /// mappings must be restored when loading older profiles: previous builds
  /// assigned `<leader>h` to Replace, which otherwise survives indefinitely.
  private static func mergingNavigationMappings(
    into existing: [EditorVimMappingProfile]
  ) -> [EditorVimMappingProfile] {
    let required = [
      ("<leader>h", "<host:section-left>"),
      ("<leader>j", "<host:section-down>"),
      ("<leader>k", "<host:section-up>"),
      ("<leader>l", "<host:section-right>"),
      ("<leader>,", ":tabprevious"),
      ("<leader>.", ":tabnext"),
    ] + (1...9).map { ("<leader>\($0)", "<host:tab-\($0)>") }

    // `n`/`p` were the previous tab bindings. Remove them during migration so
    // persisted profiles follow the new comma/period navigation convention.
    var merged = existing.filter {
      let sequence = $0.sequence.lowercased()
      return sequence != "<leader>n" && sequence != "<leader>p"
    }
    for (sequence, command) in required {
      if let index = merged.firstIndex(where: { $0.sequence.caseInsensitiveCompare(sequence) == .orderedSame }) {
        merged[index].command = command
      } else {
        merged.append(.init(sequence: sequence, command: command))
      }
    }
    return merged
  }

  mutating func ensureNavigationMappings() {
    mappings = Self.mergingNavigationMappings(into: mappings)
  }

  static let standard = EditorVimProfile(
    enabled: false,
    startInInsertMode: false,
    leader: " ",
    relativeLineNumbers: false,
    mappings: [
      .init(sequence: "<leader>w", command: ":w"),
      .init(sequence: "<leader>b", command: "<host:build>"),
      .init(sequence: "<leader>r", command: "<host:run>"),
      .init(sequence: "<leader>t", command: "<host:terminal>"),
      .init(sequence: "<leader>e", command: "<host:sidebar>"),
      .init(sequence: "<leader>f", command: ":format"),
      .init(sequence: "<leader>s", command: "<host:find>"),
      .init(sequence: "<leader>h", command: "<host:section-left>"),
      .init(sequence: "<leader>j", command: "<host:section-down>"),
      .init(sequence: "<leader>k", command: "<host:section-up>"),
      .init(sequence: "<leader>l", command: "<host:section-right>"),
      .init(sequence: "<leader>,", command: ":tabprevious"),
      .init(sequence: "<leader>.", command: ":tabnext"),
      .init(sequence: "<leader>1", command: "<host:tab-1>"),
      .init(sequence: "<leader>2", command: "<host:tab-2>"),
      .init(sequence: "<leader>3", command: "<host:tab-3>"),
      .init(sequence: "<leader>4", command: "<host:tab-4>"),
      .init(sequence: "<leader>5", command: "<host:tab-5>"),
      .init(sequence: "<leader>6", command: "<host:tab-6>"),
      .init(sequence: "<leader>7", command: "<host:tab-7>"),
      .init(sequence: "<leader>8", command: "<host:tab-8>"),
      .init(sequence: "<leader>9", command: "<host:tab-9>"),
    ]
  )
}

/// Composed editor appearance and interaction configuration.
///
/// Details are delegated to small value types so future theme areas can evolve independently.
struct EditorCustomProfile: Codable, Equatable, Sendable {
  var font: EditorFontProfile
  var surface: EditorSurfaceProfile
  var highlights: EditorHighlightProfile
  var syntax: EditorSyntaxPalette
  var workbench: EditorWorkbenchProfile
  var terminal: EditorTerminalProfile
  var themeMetadata: EditorThemeMetadataProfile
  var behavior: EditorBehaviorProfile
  var typing: EditorTypingProfile
  var snippets: EditorSnippetProfile
  var vim: EditorVimProfile

  init(
    font: EditorFontProfile,
    surface: EditorSurfaceProfile,
    highlights: EditorHighlightProfile,
    syntax: EditorSyntaxPalette,
    workbench: EditorWorkbenchProfile? = nil,
    terminal: EditorTerminalProfile? = nil,
    themeMetadata: EditorThemeMetadataProfile = .custom,
    behavior: EditorBehaviorProfile,
    typing: EditorTypingProfile = .standard,
    snippets: EditorSnippetProfile = .standard,
    vim: EditorVimProfile = .standard
  ) {
    self.font = font
    self.surface = surface
    self.highlights = highlights
    self.syntax = syntax
    self.workbench = workbench ?? Self.defaultWorkbench(surface: surface)
    self.terminal = terminal ?? Self.defaultTerminal(surface: surface)
    self.themeMetadata = themeMetadata
    self.behavior = behavior
    self.typing = typing
    self.snippets = snippets
    self.vim = vim
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    font = try container.decode(EditorFontProfile.self, forKey: .font)
    surface = try container.decode(EditorSurfaceProfile.self, forKey: .surface)
    highlights = try container.decode(EditorHighlightProfile.self, forKey: .highlights)
    syntax = try container.decode(EditorSyntaxPalette.self, forKey: .syntax)
    workbench =
      try container.decodeIfPresent(EditorWorkbenchProfile.self, forKey: .workbench)
      ?? Self.defaultWorkbench(surface: surface)
    terminal =
      try container.decodeIfPresent(EditorTerminalProfile.self, forKey: .terminal)
      ?? Self.defaultTerminal(surface: surface)
    themeMetadata =
      try container.decodeIfPresent(EditorThemeMetadataProfile.self, forKey: .themeMetadata)
      ?? .custom
    behavior = try container.decode(EditorBehaviorProfile.self, forKey: .behavior)
    typing = try container.decodeIfPresent(EditorTypingProfile.self, forKey: .typing) ?? .standard
    snippets =
      try container.decodeIfPresent(EditorSnippetProfile.self, forKey: .snippets) ?? .standard
    vim = try container.decodeIfPresent(EditorVimProfile.self, forKey: .vim) ?? .standard
  }

  private static func defaultWorkbench(surface: EditorSurfaceProfile) -> EditorWorkbenchProfile {
    EditorWorkbenchProfile(
      foreground: surface.foreground,
      mutedForeground: .init(0.52, 0.56, 0.64),
      windowBackground: surface.background,
      sidebarBackground: .init(0.09, 0.10, 0.12),
      panelBackground: .init(0.08, 0.09, 0.11),
      toolbarBackground: .init(0.10, 0.11, 0.13),
      activeTabBackground: surface.background,
      inactiveTabBackground: .init(0.10, 0.11, 0.13),
      inputBackground: .init(0.13, 0.14, 0.17),
      border: .init(0.25, 0.27, 0.31),
      accent: .init(0.42, 0.66, 1)
    )
  }

  private static func defaultTerminal(surface: EditorSurfaceProfile) -> EditorTerminalProfile {
    EditorTerminalProfile(
      foreground: surface.foreground,
      background: surface.background,
      ansi: [
        .init(0.15, 0.16, 0.19), .init(0.88, 0.32, 0.36),
        .init(0.48, 0.76, 0.48), .init(0.90, 0.70, 0.35),
        .init(0.38, 0.62, 0.92), .init(0.72, 0.48, 0.88),
        .init(0.40, 0.75, 0.78), .init(0.82, 0.84, 0.88),
        .init(0.35, 0.37, 0.43), .init(0.98, 0.43, 0.47),
        .init(0.62, 0.88, 0.58), .init(1.00, 0.82, 0.48),
        .init(0.52, 0.72, 1.00), .init(0.86, 0.62, 1.00),
        .init(0.55, 0.90, 0.92), .init(0.96, 0.97, 0.98),
      ]
    )
  }

  static let standard = EditorCustomProfile(
    font: .init(
      family: "SF Mono",
      size: 14,
      weight: .regular,
      lineSpacing: 4
    ),
    surface: .init(
      foreground: .init(0.86, 0.88, 0.91),
      background: .init(0.075, 0.085, 0.105),
      backgroundOpacity: 1,
      cursor: .init(0.42, 0.66, 1),
      selection: .init(0.20, 0.38, 0.62, 0.72)
    ),
    highlights: .init(
      currentLine: .init(0.15, 0.17, 0.21, 0.72),
      searchResult: .init(0.69, 0.52, 0.16, 0.65),
      error: .init(0.95, 0.30, 0.34),
      warning: .init(0.95, 0.68, 0.24),
      information: .init(0.35, 0.64, 0.95),
      hint: .init(0.48, 0.72, 0.63)
    ),
    syntax: .init(
      literals: .init(
        keyword: .init(0.78, 0.52, 0.94),
        string: .init(0.70, 0.84, 0.52),
        number: .init(0.92, 0.64, 0.43),
        comment: .init(0.47, 0.52, 0.60),
        directive: .init(0.48, 0.75, 0.93)
      ),
      symbols: .init(
        type: .init(0.45, 0.81, 0.78),
        function: .init(0.48, 0.69, 0.96),
        variable: .init(0.86, 0.88, 0.91),
        property: .init(0.68, 0.78, 0.94),
        operator: .init(0.79, 0.82, 0.88),
        punctuation: .init(0.68, 0.71, 0.78)
      )
    ),
    behavior: .init(
      tabWidth: 4,
      insertSpaces: true,
      suggestionDelay: 0.16,
      showLineNumbers: true,
      showDiagnostics: true,
      showInlineDiagnosticMessages: true
    ),
    typing: .standard,
    snippets: .standard,
    vim: .standard
  )

  static let light: EditorCustomProfile = {
    var value = EditorCustomProfile.standard
    value.surface = .init(
      foreground: .init(0.12, 0.14, 0.18),
      background: .init(0.97, 0.975, 0.985),
      backgroundOpacity: 1,
      cursor: .init(0.10, 0.38, 0.82),
      selection: .init(0.55, 0.72, 0.96, 0.55)
    )
    value.highlights.currentLine = .init(0.91, 0.93, 0.96)
    value.highlights.searchResult = .init(0.95, 0.78, 0.30, 0.60)
    value.syntax.literals.comment = .init(0.38, 0.44, 0.50)
    value.syntax.symbols.variable = value.surface.foreground
    value.workbench = EditorWorkbenchProfile(
      foreground: value.surface.foreground,
      mutedForeground: .init(0.38, 0.42, 0.48),
      windowBackground: .init(0.95, 0.96, 0.975),
      sidebarBackground: .init(0.925, 0.94, 0.96),
      panelBackground: .init(0.94, 0.95, 0.97),
      toolbarBackground: .init(0.91, 0.925, 0.95),
      activeTabBackground: value.surface.background,
      inactiveTabBackground: .init(0.90, 0.92, 0.945),
      inputBackground: .init(1, 1, 1),
      border: .init(0.72, 0.75, 0.80),
      accent: .init(0.10, 0.38, 0.82)
    )
    value.terminal.foreground = value.surface.foreground
    value.terminal.background = value.surface.background
    return value
  }()
}

extension EditorCustomProfile {
  var detectedThemeSlot: EditorThemeSlot {
    surface.background.relativeLuminance >= 0.45 ? .light : .dark
  }

  var forcedInterfaceAppearance: EditorInterfaceAppearance? {
    guard themeMetadata.sourcePath != nil else { return nil }
    switch themeMetadata.importedAppearance {
    case .automatic:
      return nil
    case .light:
      return .light
    case .dark:
      return .dark
    case .fixed:
      return detectedThemeSlot == .light ? .light : .dark
    }
  }

  var visualSnapshot: EditorThemeVisualSnapshot {
    EditorThemeVisualSnapshot(
      surface: surface,
      highlights: highlights,
      syntax: syntax,
      workbench: workbench,
      terminal: terminal
    )
  }

  mutating func applyImportedTheme(
    _ theme: EditorTheme,
    sourceURL: URL,
    sourceVariantPath: String? = nil,
    diagnostics: [EditorThemeImportDiagnostic]
  ) {
    let current = visualSnapshot
    let previousBaseline = themeMetadata.importedBaseline
    var imported = self
    imported.apply(theme: theme)
    let newBaseline = imported.visualSnapshot

    if let previousBaseline {
      if current.surface != previousBaseline.surface { imported.surface = current.surface }
      if current.highlights != previousBaseline.highlights {
        imported.highlights = current.highlights
      }
      if current.syntax != previousBaseline.syntax { imported.syntax = current.syntax }
      if current.workbench != previousBaseline.workbench { imported.workbench = current.workbench }
      if current.terminal != previousBaseline.terminal { imported.terminal = current.terminal }
    }

    var metadata = EditorThemeMetadataProfile(
      importedName: theme.name.isEmpty
        ? sourceURL.deletingPathExtension().lastPathComponent : theme.name,
      sourcePath: sourceURL.standardizedFileURL.path,
      sourceVariantPath: sourceVariantPath,
      sourceModificationTime: nil,
      importedAppearance: imported.themeMetadata.importedAppearance,
      importerDiagnostics: diagnostics.map(\.message),
      importedBaseline: newBaseline
    )
    let values = try? metadata.monitoredSourceURL?.resourceValues(
      forKeys: [.contentModificationDateKey]
    )
    metadata.sourceModificationTime = values?.contentModificationDate?.timeIntervalSince1970
    imported.themeMetadata = metadata
    self = imported
  }

  /// Applies the portions of a normalized EditorServices theme that Calcite renders today.
  /// Missing colors intentionally preserve the user's current customization.
  mutating func apply(theme: EditorTheme) {
    func rgba(_ color: EditorColor?) -> EditorRGBAColor? {
      guard let color else { return nil }
      return EditorRGBAColor(
        Double(color.red) / 255,
        Double(color.green) / 255,
        Double(color.blue) / 255,
        Double(color.alpha) / 255
      )
    }

    func syntaxColor(_ capture: String) -> EditorRGBAColor? {
      rgba(theme.style(forSyntaxCapture: capture, languageID: "swift")?.foreground)
        ?? rgba(theme.style(forSyntaxCapture: capture)?.foreground)
    }

    surface.foreground = rgba(theme.editorForeground) ?? surface.foreground
    surface.background = rgba(theme.editorBackground) ?? surface.background
    surface.backgroundOpacity = 1
    let cursor = rgba(theme[color: "editorCursor.foreground"])
    let selection = rgba(theme[color: "editor.selectionBackground"])
    let currentLine = rgba(theme[color: "editor.lineHighlightBackground"])

    syntax.literals.keyword = syntaxColor("keyword") ?? syntax.literals.keyword
    syntax.literals.string = syntaxColor("string") ?? syntax.literals.string
    syntax.literals.number = syntaxColor("number") ?? syntax.literals.number
    syntax.literals.comment = syntaxColor("comment") ?? syntax.literals.comment
    syntax.literals.directive =
      syntaxColor("attribute") ?? syntaxColor("preproc") ?? syntax.literals.directive
    syntax.symbols.type = syntaxColor("type") ?? syntaxColor("type.builtin") ?? syntax.symbols.type
    syntax.symbols.function =
      syntaxColor("function.call") ?? syntaxColor("function") ?? syntax.symbols.function
    syntax.symbols.variable = syntaxColor("variable") ?? syntax.symbols.variable
    syntax.symbols.property = syntaxColor("property") ?? syntax.symbols.property
    syntax.symbols.operator = syntaxColor("operator") ?? syntax.symbols.operator
    syntax.symbols.punctuation = syntaxColor("punctuation.delimiter") ?? syntax.symbols.punctuation

    func assign(
      _ value: EditorRGBAColor?, to keyPath: WritableKeyPath<EditorCustomProfile, EditorRGBAColor>
    ) {
      if let value { self[keyPath: keyPath] = value }
    }
    assign(cursor, to: \.surface.cursor)
    assign(selection, to: \.surface.selection)
    assign(currentLine, to: \.highlights.currentLine)

    func firstColor(_ keys: [String]) -> EditorRGBAColor? {
      for key in keys {
        if let color = rgba(theme[color: key]) { return color }
      }
      return nil
    }
    workbench.foreground =
      firstColor(["foreground", "editor.foreground"])
      ?? surface.foreground
    workbench.mutedForeground =
      firstColor([
        "descriptionForeground", "sideBar.foreground", "activityBar.inactiveForeground",
      ]) ?? workbench.mutedForeground
    workbench.windowBackground =
      firstColor([
        "window.background", "editorGroup.emptyBackground", "editor.background",
      ]) ?? surface.background
    workbench.sidebarBackground =
      firstColor([
        "sideBar.background", "activityBar.background", "editor.background",
      ]) ?? workbench.sidebarBackground
    workbench.panelBackground =
      firstColor([
        "panel.background", "terminal.background", "editor.background",
      ]) ?? workbench.panelBackground
    workbench.toolbarBackground =
      firstColor([
        "titleBar.activeBackground", "activityBar.background", "sideBar.background",
      ]) ?? workbench.toolbarBackground
    workbench.activeTabBackground =
      firstColor([
        "tab.activeBackground", "editor.background",
      ]) ?? workbench.activeTabBackground
    workbench.inactiveTabBackground =
      firstColor([
        "tab.inactiveBackground", "titleBar.activeBackground", "sideBar.background",
      ]) ?? workbench.inactiveTabBackground
    workbench.inputBackground =
      firstColor([
        "input.background", "editorWidget.background", "editorSuggestWidget.background",
      ]) ?? workbench.inputBackground
    workbench.border =
      firstColor([
        "editorGroup.border", "panel.border", "sideBar.border", "contrastBorder",
      ]) ?? workbench.border
    workbench.accent =
      firstColor([
        "focusBorder", "button.background", "textLink.foreground", "editorCursor.foreground",
      ]) ?? surface.cursor

    terminal.foreground =
      firstColor(["terminal.foreground", "editor.foreground"])
      ?? terminal.foreground
    terminal.background =
      firstColor(["terminal.background", "panel.background", "editor.background"])
      ?? terminal.background
    let ansiKeys = [
      "terminal.ansiBlack", "terminal.ansiRed", "terminal.ansiGreen", "terminal.ansiYellow",
      "terminal.ansiBlue", "terminal.ansiMagenta", "terminal.ansiCyan", "terminal.ansiWhite",
      "terminal.ansiBrightBlack", "terminal.ansiBrightRed", "terminal.ansiBrightGreen",
      "terminal.ansiBrightYellow", "terminal.ansiBrightBlue", "terminal.ansiBrightMagenta",
      "terminal.ansiBrightCyan", "terminal.ansiBrightWhite",
    ]
    for (index, key) in ansiKeys.enumerated() {
      if let color = rgba(theme[color: key]), terminal.ansi.indices.contains(index) {
        terminal.ansi[index] = color
      }
    }
  }
}

extension EditorRGBAColor {
  private var linearRed: Double { Self.linearized(red.clampedColorComponent) }
  private var linearGreen: Double { Self.linearized(green.clampedColorComponent) }
  private var linearBlue: Double { Self.linearized(blue.clampedColorComponent) }

  var relativeLuminance: Double {
    0.2126 * linearRed + 0.7152 * linearGreen + 0.0722 * linearBlue
  }

  func contrastRatio(against other: EditorRGBAColor) -> Double {
    let lighter = max(relativeLuminance, other.relativeLuminance)
    let darker = min(relativeLuminance, other.relativeLuminance)
    return (lighter + 0.05) / (darker + 0.05)
  }

  private static func linearized(_ component: Double) -> Double {
    component <= 0.04045
      ? component / 12.92
      : pow((component + 0.055) / 1.055, 2.4)
  }

  var nsColor: NSColor {
    NSColor(
      srgbRed: red.clampedColorComponent,
      green: green.clampedColorComponent,
      blue: blue.clampedColorComponent,
      alpha: alpha.clampedColorComponent
    )
  }

  var color: Color { Color(nsColor: nsColor) }
}

extension EditorFontWeight {
  var nsWeight: NSFont.Weight {
    switch self {
    case .light: return .light
    case .regular: return .regular
    case .medium: return .medium
    case .semibold: return .semibold
    case .bold: return .bold
    }
  }
}

extension Double {
  fileprivate var clampedColorComponent: CGFloat { CGFloat(min(max(self, 0), 1)) }
}

enum EditorProfileStore {
  private static let legacyKey = "editor.customProfile.v1"
  private static let lightKey = "editor.customProfile.light.v2"
  private static let darkKey = "editor.customProfile.dark.v2"

  static func load(
    slot: EditorThemeSlot,
    defaults: UserDefaults = .standard
  ) -> EditorCustomProfile {
    let key = slot == .light ? lightKey : darkKey
    if let data = defaults.data(forKey: key),
      let value = try? JSONDecoder().decode(EditorCustomProfile.self, from: data)
    {
      return value
    }
    if slot == .dark,
      let data = defaults.data(forKey: legacyKey),
      let value = try? JSONDecoder().decode(EditorCustomProfile.self, from: data)
    {
      return value
    }
    return slot == .light ? .light : .standard
  }

  static func load(defaults: UserDefaults = .standard) -> EditorCustomProfile {
    load(slot: .dark, defaults: defaults)
  }

  static func save(
    _ profile: EditorCustomProfile,
    slot: EditorThemeSlot,
    defaults: UserDefaults = .standard
  ) {
    guard let data = try? JSONEncoder().encode(profile) else { return }
    defaults.set(data, forKey: slot == .light ? lightKey : darkKey)
  }

  static func save(_ profile: EditorCustomProfile, defaults: UserDefaults = .standard) {
    save(profile, slot: .dark, defaults: defaults)
  }
}

struct EditorWorkspaceThemeOverride: Codable, Equatable, Sendable {
  var isEnabled: Bool
  var light: EditorCustomProfile?
  var dark: EditorCustomProfile?

  static let disabled = EditorWorkspaceThemeOverride(
    isEnabled: false,
    light: nil,
    dark: nil
  )

  func profile(for slot: EditorThemeSlot) -> EditorCustomProfile? {
    slot == .light ? light : dark
  }
}

enum EditorWorkspaceThemeProfileStore {
  private static let prefix = "editor.workspaceTheme.v1."

  static func load(
    workspaceURL: URL,
    defaults: UserDefaults = .standard
  ) -> EditorWorkspaceThemeOverride {
    guard let data = defaults.data(forKey: key(for: workspaceURL)),
      let value = try? JSONDecoder().decode(EditorWorkspaceThemeOverride.self, from: data)
    else { return .disabled }
    return value
  }

  static func save(
    _ value: EditorWorkspaceThemeOverride,
    workspaceURL: URL,
    defaults: UserDefaults = .standard
  ) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key(for: workspaceURL))
  }

  static func save(
    _ profile: EditorCustomProfile,
    slot: EditorThemeSlot,
    workspaceURL: URL,
    defaults: UserDefaults = .standard
  ) {
    var value = load(workspaceURL: workspaceURL, defaults: defaults)
    value.isEnabled = true
    if slot == .light { value.light = profile } else { value.dark = profile }
    save(value, workspaceURL: workspaceURL, defaults: defaults)
  }

  static func setEnabled(
    _ enabled: Bool,
    workspaceURL: URL,
    light: EditorCustomProfile? = nil,
    dark: EditorCustomProfile? = nil,
    defaults: UserDefaults = .standard
  ) {
    var value = load(workspaceURL: workspaceURL, defaults: defaults)
    value.isEnabled = enabled
    if let light { value.light = light }
    if let dark { value.dark = dark }
    save(value, workspaceURL: workspaceURL, defaults: defaults)
  }

  private static func key(for workspaceURL: URL) -> String {
    let bytes = workspaceURL.standardizedFileURL.path.utf8
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return prefix + String(hash, radix: 16)
  }
}
