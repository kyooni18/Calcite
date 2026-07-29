import Foundation

nonisolated enum ThemeTokenCategory: String, CaseIterable, Identifiable, Sendable {
  case editor = "Editor"
  case syntax = "Syntax"
  case diagnostics = "Diagnostics"
  case workbench = "Workbench"
  case terminal = "Terminal"

  var id: String { rawValue }

  var systemImage: String {
    switch self {
    case .editor: "text.cursor"
    case .syntax: "chevron.left.forwardslash.chevron.right"
    case .diagnostics: "exclamationmark.triangle"
    case .workbench: "rectangle.3.group"
    case .terminal: "terminal"
    }
  }
}

@MainActor struct ThemeColorToken: Identifiable {
  enum Storage {
    case keyPath(WritableKeyPath<EditorCustomProfile, EditorRGBAColor>)
    case terminalANSI(Int)
  }

  var id: String
  var title: String
  var category: ThemeTokenCategory
  var searchAliases: [String]
  var storage: Storage

  init(
    _ id: String,
    _ title: String,
    category: ThemeTokenCategory,
    aliases: [String] = [],
    keyPath: WritableKeyPath<EditorCustomProfile, EditorRGBAColor>
  ) {
    self.id = id
    self.title = title
    self.category = category
    self.searchAliases = aliases
    self.storage = .keyPath(keyPath)
  }

  init(ansi index: Int, title: String) {
    id = "terminal.ansi.\(index)"
    self.title = title
    category = .terminal
    searchAliases = ["ansi", "terminal", "palette", "\(index)"]
    storage = .terminalANSI(index)
  }

  func color(in profile: EditorCustomProfile) -> EditorRGBAColor {
    switch storage {
    case .keyPath(let keyPath):
      profile[keyPath: keyPath]
    case .terminalANSI(let index):
      profile.terminal.ansi.indices.contains(index)
        ? profile.terminal.ansi[index]
        : EditorRGBAColor(0, 0, 0)
    }
  }

  func setColor(_ color: EditorRGBAColor, in profile: inout EditorCustomProfile) {
    switch storage {
    case .keyPath(let keyPath):
      profile[keyPath: keyPath] = color
    case .terminalANSI(let index):
      guard profile.terminal.ansi.indices.contains(index) else { return }
      profile.terminal.ansi[index] = color
    }
  }

  func matches(_ query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return true }
    return ([id, title] + searchAliases).contains { $0.lowercased().contains(query) }
  }

  static let all: [ThemeColorToken] = {
    var values: [ThemeColorToken] = [
      .init("editor.foreground", "Text", category: .editor, aliases: ["foreground"], keyPath: \.surface.foreground),
      .init("editor.background", "Background", category: .editor, keyPath: \.surface.background),
      .init("editor.cursor", "Insertion Cursor", category: .editor, keyPath: \.surface.cursor),
      .init("editor.selection", "Selection", category: .editor, keyPath: \.surface.selection),
      .init("editor.currentLine", "Current Line", category: .editor, keyPath: \.highlights.currentLine),
      .init("editor.searchResult", "Search Result", category: .editor, aliases: ["find"], keyPath: \.highlights.searchResult),

      .init("syntax.keyword", "Keyword", category: .syntax, keyPath: \.syntax.literals.keyword),
      .init("syntax.string", "String", category: .syntax, keyPath: \.syntax.literals.string),
      .init("syntax.number", "Number", category: .syntax, keyPath: \.syntax.literals.number),
      .init("syntax.comment", "Comment", category: .syntax, keyPath: \.syntax.literals.comment),
      .init("syntax.directive", "Directive", category: .syntax, aliases: ["preprocessor"], keyPath: \.syntax.literals.directive),
      .init("syntax.type", "Type", category: .syntax, aliases: ["class", "struct", "enum"], keyPath: \.syntax.symbols.type),
      .init("syntax.function", "Function", category: .syntax, aliases: ["method"], keyPath: \.syntax.symbols.function),
      .init("syntax.variable", "Variable", category: .syntax, keyPath: \.syntax.symbols.variable),
      .init("syntax.property", "Property", category: .syntax, aliases: ["field"], keyPath: \.syntax.symbols.property),
      .init("syntax.operator", "Operator", category: .syntax, keyPath: \.syntax.symbols.operator),
      .init("syntax.punctuation", "Punctuation", category: .syntax, keyPath: \.syntax.symbols.punctuation),

      .init("diagnostic.error", "Error", category: .diagnostics, keyPath: \.highlights.error),
      .init("diagnostic.warning", "Warning", category: .diagnostics, keyPath: \.highlights.warning),
      .init("diagnostic.information", "Information", category: .diagnostics, aliases: ["info"], keyPath: \.highlights.information),
      .init("diagnostic.hint", "Hint", category: .diagnostics, keyPath: \.highlights.hint),

      .init("workbench.foreground", "Window Text", category: .workbench, keyPath: \.workbench.foreground),
      .init("workbench.mutedForeground", "Muted Text", category: .workbench, keyPath: \.workbench.mutedForeground),
      .init("workbench.windowBackground", "Window Background", category: .workbench, keyPath: \.workbench.windowBackground),
      .init("workbench.sidebarBackground", "Sidebar", category: .workbench, keyPath: \.workbench.sidebarBackground),
      .init("workbench.panelBackground", "Panel", category: .workbench, keyPath: \.workbench.panelBackground),
      .init("workbench.toolbarBackground", "Toolbar", category: .workbench, keyPath: \.workbench.toolbarBackground),
      .init("workbench.activeTabBackground", "Active Tab", category: .workbench, keyPath: \.workbench.activeTabBackground),
      .init("workbench.inactiveTabBackground", "Inactive Tab", category: .workbench, keyPath: \.workbench.inactiveTabBackground),
      .init("workbench.inputBackground", "Input", category: .workbench, keyPath: \.workbench.inputBackground),
      .init("workbench.border", "Border", category: .workbench, keyPath: \.workbench.border),
      .init("workbench.accent", "Accent", category: .workbench, keyPath: \.workbench.accent),

      .init("terminal.foreground", "Terminal Text", category: .terminal, keyPath: \.terminal.foreground),
      .init("terminal.background", "Terminal Background", category: .terminal, keyPath: \.terminal.background),
    ]
    let ansiNames = [
      "ANSI Black", "ANSI Red", "ANSI Green", "ANSI Yellow",
      "ANSI Blue", "ANSI Magenta", "ANSI Cyan", "ANSI White",
      "Bright Black", "Bright Red", "Bright Green", "Bright Yellow",
      "Bright Blue", "Bright Magenta", "Bright Cyan", "Bright White",
    ]
    values.append(contentsOf: ansiNames.enumerated().map { ThemeColorToken(ansi: $0.offset, title: $0.element) })
    return values
  }()

  static func token(id: String) -> ThemeColorToken? {
    all.first { $0.id == id }
  }
}
