import Foundation
import XCTest
@testable import EditorCore

final class EditorThemeTests: XCTestCase {
  func testEditorColorParsesCSSHexAndRoundTripsAsString() throws {
    XCTAssertEqual(EditorColor(hex: "#abc"), EditorColor(red: 0xAA, green: 0xBB, blue: 0xCC))
    XCTAssertEqual(EditorColor(hex: "#abcd"), EditorColor(red: 0xAA, green: 0xBB, blue: 0xCC, alpha: 0xDD))
    XCTAssertEqual(EditorColor(hex: "#12345678")?.hexRGBA, "#12345678")
    XCTAssertEqual(EditorColor(hex: "transparent"), .clear)
    XCTAssertNil(EditorColor(hex: "not-a-color"))

    let color = EditorColor(red: 1, green: 2, blue: 3, alpha: 4)
    let data = try JSONEncoder().encode(color)
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"#01020304\"")
    XCTAssertEqual(try JSONDecoder().decode(EditorColor.self, from: data), color)
  }

  func testNativeThemeCodableAndStyleResolution() throws {
    let theme = EditorTheme(
      name: "Native",
      appearance: .dark,
      colors: ["editor.background": EditorColor(rgb: 0x101010)],
      rules: [
        EditorThemeRule(
          selectors: [.syntax("keyword")],
          style: EditorTextStyle(foreground: EditorColor(rgb: 0xFF0000), fontStyles: [.bold])
        ),
        EditorThemeRule(
          selectors: [.syntax("keyword.function")],
          style: EditorTextStyle(foreground: EditorColor(rgb: 0x00FF00))
        ),
      ]
    )
    let decoded = try EditorTheme(data: theme.encodedJSON())
    XCTAssertEqual(decoded, theme)
    XCTAssertEqual(decoded.style(forSyntaxCapture: "@keyword.function")?.foreground, EditorColor(rgb: 0x00FF00))
    XCTAssertEqual(decoded.style(forSyntaxCapture: "keyword.function")?.fontStyles, [.bold])
  }

  func testVSCodeJSONCImportsUITextMateAndSemanticRules() throws {
    let json = #"""
    {
      // JSONC comments and trailing commas are accepted.
      "name": "VS Test",
      "type": "dark",
      "colors": {
        "editor.background": "#112233",
        "editor.foreground": "#DDEEFF",
      },
      "tokenColors": [
        {
          "name": "Control",
          "scope": ["keyword.control", "entity.name.function"],
          "settings": {
            "foreground": "#FF0000",
            "fontStyle": "bold italic",
          },
        },
      ],
      "semanticTokenColors": {
        "variable.readonly:swift": {
          "foreground": "#00FF00",
          "bold": true,
          "underline": true,
        },
      },
    }
    """#

    let result = try EditorThemeImporter.importTheme(from: Data(json.utf8))
    let theme = result.theme
    XCTAssertEqual(theme.name, "VS Test")
    XCTAssertEqual(theme.source, .vsCode)
    XCTAssertEqual(theme.appearance, .dark)
    XCTAssertEqual(theme.editorBackground, EditorColor(rgb: 0x112233))
    XCTAssertEqual(theme.editorForeground, EditorColor(rgb: 0xDDEEFF))

    let keyword = theme.style(forSyntaxCapture: "keyword.control")
    XCTAssertEqual(keyword?.foreground, EditorColor(rgb: 0xFF0000))
    XCTAssertEqual(keyword?.fontStyles, [.bold, .italic])
    XCTAssertEqual(theme.style(forSyntaxCapture: "function.call")?.foreground, EditorColor(rgb: 0xFF0000))

    let semantic = theme.style(
      forSemanticTokenType: "variable",
      modifiers: ["readonly", "declaration"],
      languageID: "swift"
    )
    XCTAssertEqual(semantic?.foreground, EditorColor(rgb: 0x00FF00))
    XCTAssertEqual(semantic?.fontStyles, [.bold, .underline])
    XCTAssertNil(theme.style(
      forSemanticTokenType: "variable",
      modifiers: ["readonly"],
      languageID: "rust"
    ))
    XCTAssertTrue(result.diagnostics.isEmpty)
  }

  func testVSCodeIncludeAndExternalTextMateTokenFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let baseURL = directory.appendingPathComponent("base.json")
    let tokensURL = directory.appendingPathComponent("tokens.tmTheme")
    let childURL = directory.appendingPathComponent("child.json")

    let base = #"""
    {
      "name": "Base",
      "type": "dark",
      "colors": { "editor.background": "#101010" },
      "tokenColors": [
        { "scope": "keyword", "settings": { "foreground": "#FF0000" } }
      ]
    }
    """#
    try Data(base.utf8).write(to: baseURL)

    let textMate: [String: Any] = [
      "name": "Tokens",
      "settings": [
        ["scope": "entity.name.function", "settings": ["foreground": "#00FF00"]]
      ]
    ]
    let plist = try PropertyListSerialization.data(
      fromPropertyList: textMate,
      format: .xml,
      options: 0
    )
    try plist.write(to: tokensURL)

    let child = #"""
    {
      "name": "Child",
      "include": "./base.json",
      "tokenColors": "./tokens.tmTheme",
      "colors": { "editor.foreground": "#EEEEEE" },
      "semanticTokenColors": { "type": "#0000FF" }
    }
    """#
    try Data(child.utf8).write(to: childURL)

    let result = try EditorThemeImporter.load(from: childURL)
    XCTAssertEqual(result.theme.name, "Child")
    XCTAssertEqual(result.theme.editorBackground, EditorColor(rgb: 0x101010))
    XCTAssertEqual(result.theme.editorForeground, EditorColor(rgb: 0xEEEEEE))
    XCTAssertEqual(result.theme.style(forSyntaxCapture: "keyword")?.foreground, EditorColor(rgb: 0xFF0000))
    XCTAssertEqual(result.theme.style(forSyntaxCapture: "function")?.foreground, EditorColor(rgb: 0x00FF00))
    XCTAssertEqual(result.theme.style(forSemanticTokenType: "type")?.foreground, EditorColor(rgb: 0x0000FF))
  }

  func testNeovimJSONImportsGroupsLinksTreeSitterSemanticAndUIColors() throws {
    let json = #"""
    {
      "name": "Nvim Test",
      "background": "dark",
      "highlights": {
        "Normal": { "fg": 15790320, "bg": 1052688 },
        "Visual": { "bg": "#334455" },
        "Function": { "fg": "#44AAFF", "bold": true },
        "MyFunction": { "link": "Function" },
        "@function.call": { "fg": "#CC3355" },
        "@keyword.swift": { "fg": "#FF44AA", "italic": true },
        "@lsp.typemod.variable.readonly": { "fg": "#55CC66", "underline": true }
      }
    }
    """#

    let result = try EditorThemeImporter.importTheme(from: Data(json.utf8))
    let theme = result.theme
    XCTAssertEqual(theme.source, .neovim)
    XCTAssertEqual(theme.appearance, .dark)
    XCTAssertEqual(theme.editorForeground, EditorColor(rgb: 0xF0F0F0))
    XCTAssertEqual(theme.editorBackground, EditorColor(rgb: 0x101010))
    XCTAssertEqual(theme.colors["editor.selectionBackground"], EditorColor(rgb: 0x334455))

    let function = theme.style(forSyntaxCapture: "function.call")
    XCTAssertEqual(function?.foreground, EditorColor(rgb: 0xCC3355))
    XCTAssertEqual(function?.fontStyles, [.bold])

    let keyword = theme.style(forSyntaxCapture: "keyword", languageID: "swift")
    XCTAssertEqual(keyword?.foreground, EditorColor(rgb: 0xFF44AA))
    XCTAssertEqual(keyword?.fontStyles, [.italic])
    XCTAssertNil(theme.style(forSyntaxCapture: "keyword", languageID: "rust"))

    let semantic = theme.style(
      forSemanticTokenType: "variable",
      modifiers: ["readonly"]
    )
    XCTAssertEqual(semantic?.foreground, EditorColor(rgb: 0x55CC66))
    XCTAssertEqual(semantic?.fontStyles, [.underline])
  }

  func testVimColorSchemeImportsLiteralHighlightCommandsAndLinks() throws {
    let vim = #"""
    set background=dark
    let g:colors_name = 'vim-test'
    highlight Normal guifg=#E0E0E0 guibg=#101010
    hi Keyword guifg=#FF8800 gui=bold
    hi Comment guifg=#778899 gui=italic
    hi link MyKeyword Keyword
    " ignored comment
    """#

    let theme = try EditorTheme(text: vim, format: .vimColorScheme)
    XCTAssertEqual(theme.name, "vim-test")
    XCTAssertEqual(theme.appearance, .dark)
    XCTAssertEqual(theme.editorBackground, EditorColor(rgb: 0x101010))
    XCTAssertEqual(theme.style(forSyntaxCapture: "keyword")?.foreground, EditorColor(rgb: 0xFF8800))
    XCTAssertEqual(theme.style(forSyntaxCapture: "keyword")?.fontStyles, [.bold])
    XCTAssertEqual(theme.style(forSyntaxCapture: "comment.documentation")?.foreground, EditorColor(rgb: 0x778899))
  }

  func testNeovimLuaParsesLiteralCallsWithoutExecution() throws {
    let lua = #"""
    vim.api.nvim_set_hl(0, "Normal", { fg = "#EEEEEE", bg = "#111111" })
    vim.api.nvim_set_hl(0, "@function.call", { fg = "#66AAFF", bold = true })
    vim.api.nvim_set_hl(0, "LinkedFunction", { link = "@function.call" })
    vim.cmd([[
      highlight Comment guifg=#778899 gui=italic
    ]])
    """#

    let result = try EditorThemeImporter.importTheme(
      from: Data(lua.utf8),
      format: .neovimLua
    )
    XCTAssertEqual(result.theme.editorBackground, EditorColor(rgb: 0x111111))
    XCTAssertEqual(result.theme.style(forSyntaxCapture: "function.call")?.foreground, EditorColor(rgb: 0x66AAFF))
    XCTAssertEqual(result.theme.style(forSyntaxCapture: "function.call")?.fontStyles, [.bold])
    XCTAssertEqual(result.theme.style(forSyntaxCapture: "comment")?.fontStyles, [.italic])
  }

  func testNeovimLinkCycleProducesDiagnosticInsteadOfRecursingForever() throws {
    let json = #"""
    {
      "groups": {
        "A": { "link": "B", "fg": "#FF0000" },
        "B": { "link": "A", "bg": "#000000" }
      }
    }
    """#
    let result = try EditorThemeImporter.importTheme(
      from: Data(json.utf8),
      format: .neovimJSON
    )
    XCTAssertFalse(result.diagnostics.isEmpty)
  }

  func testNeovimLuaResolvesPaletteReferencesAndDeclarativeGroupTables() throws {
    let lua = #"""
    local colors = {
      fg = "#EAEAEA",
      bg = "#121212",
      blue = "#55AAFF",
    }
    local groups = {
      Normal = { fg = colors.fg, bg = colors.bg },
      ["@function.call"] = { fg = colors.blue, bold = true },
    }
    return groups
    """#

    let result = try EditorThemeImporter.importTheme(
      from: Data(lua.utf8),
      format: .neovimLua
    )
    XCTAssertEqual(result.theme.editorBackground, EditorColor(rgb: 0x121212))
    XCTAssertEqual(result.theme.editorForeground, EditorColor(rgb: 0xEAEAEA))
    XCTAssertEqual(
      result.theme.style(forSyntaxCapture: "function.call")?.foreground,
      EditorColor(rgb: 0x55AAFF)
    )
  }

  func testThemeDirectoryDiscoversAndLoadsSelectedVariant() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let themes = directory.appendingPathComponent("themes", isDirectory: true)
    try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let manifest = #"""
    {
      "contributes": {
        "themes": [
          { "label": "Variant Dark", "uiTheme": "vs-dark", "path": "./themes/dark.json" },
          { "label": "Variant Light", "uiTheme": "vs", "path": "./themes/light.json" }
        ]
      }
    }
    """#
    try Data(manifest.utf8).write(to: directory.appendingPathComponent("package.json"))
    try Data(##"{"name":"Dark","colors":{"editor.background":"#111111"},"tokenColors":[]}"##.utf8)
      .write(to: themes.appendingPathComponent("dark.json"))
    try Data(##"{"name":"Light","colors":{"editor.background":"#FAFAFA"},"tokenColors":[]}"##.utf8)
      .write(to: themes.appendingPathComponent("light.json"))

    let candidates = try EditorThemeImporter.discoverThemes(in: directory)
    XCTAssertEqual(candidates.map(\.name), ["Variant Dark", "Variant Light"])
    let light = try XCTUnwrap(candidates.first { $0.name == "Variant Light" })
    let result = try EditorThemeImporter.load(light)
    XCTAssertEqual(result.theme.editorBackground, EditorColor(rgb: 0xFAFAFA))
    XCTAssertEqual(result.theme.metadata["import.selectedCandidate"], "themes/light.json")
  }

  func testThemeDirectoryLoadsVSCodeManifestTheme() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let themes = directory.appendingPathComponent("themes", isDirectory: true)
    try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let manifest = #"""
    {
      "contributes": {
        "themes": [
          { "label": "Folder Test", "uiTheme": "vs-dark", "path": "./themes/folder.json" }
        ]
      }
    }
    """#
    try Data(manifest.utf8).write(to: directory.appendingPathComponent("package.json"))
    let theme = #"""
    {
      "name": "Folder Test",
      "type": "dark",
      "colors": { "editor.background": "#102030" },
      "tokenColors": []
    }
    """#
    try Data(theme.utf8).write(to: themes.appendingPathComponent("folder.json"))

    let result = try EditorThemeImporter.load(from: directory)
    XCTAssertEqual(result.theme.editorBackground, EditorColor(rgb: 0x102030))
    XCTAssertEqual(result.theme.metadata["import.directory"], directory.path)
  }

}
