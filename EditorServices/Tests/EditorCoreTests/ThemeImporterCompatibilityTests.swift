import EditorCore
import Foundation
import XCTest

final class ThemeImporterCompatibilityTests: XCTestCase {
  func testTextMateJSONRootArrayImportsTokenRules() throws {
    let source = #"""
      [
        {
          "scope": "source.swift meta.function entity.name.function",
          "settings": { "foreground": "#44AAFF", "fontStyle": "bold" }
        }
      ]
      """#

    let result = try EditorThemeImporter.importTheme(from: Data(source.utf8))
    XCTAssertEqual(result.theme.metadata["format"], "textmate-json")
    XCTAssertEqual(
      result.theme.style(forSyntaxCapture: "function", languageID: "swift")?.foreground,
      EditorColor(hex: "#44AAFF")
    )
  }

  func testVSCodeExternalTextMateJSONAndMissingIncludeRemainImportable() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let tokens = directory.appendingPathComponent("tokens.json")
    try #"""
    {
      "settings": [
        { "settings": { "foreground": "#D0D0D0", "background": "#101010" } },
        { "scope": "keyword", "settings": { "foreground": "rgb(255, 80, 120)" } }
      ]
    }
    """#.write(to: tokens, atomically: true, encoding: .utf8)

    let theme = directory.appendingPathComponent("theme.json")
    try #"""
    {
      "name": "External Tokens",
      "include": "missing-base.json",
      "tokenColors": "./tokens.json",
      "colors": { "editorCursor.foreground": "rgba(10, 20, 30, 0.5)" }
    }
    """#.write(to: theme, atomically: true, encoding: .utf8)

    let result = try EditorThemeImporter.load(from: theme)
    XCTAssertEqual(result.theme.editorBackground, EditorColor(hex: "#101010"))
    XCTAssertEqual(
      result.theme.style(forSyntaxCapture: "keyword")?.foreground,
      EditorColor(red: 255, green: 80, blue: 120)
    )
    XCTAssertEqual(result.theme[color: "editorCursor.foreground"]?.alpha, 128)
    XCTAssertTrue(result.diagnostics.contains { $0.message.contains("missing-base.json") })
  }

  func testJSONCVSCodeManifestDiscoversThemeVariant() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let themes = directory.appendingPathComponent("themes", isDirectory: true)
    try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    try #"""
    {
      // VS Code extension manifests are frequently JSONC in unpacked sources.
      "contributes": {
        "themes": [
          { "label": "Night", "uiTheme": "vs-dark", "path": "./themes/night.json", },
        ],
      },
    }
    """#.write(
      to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "{\"name\":\"Night\",\"colors\":{\"editor.background\":\"#111111\"}}"
      .write(to: themes.appendingPathComponent("night.json"), atomically: true, encoding: .utf8)

    let candidates = try EditorThemeImporter.discoverThemes(in: directory)
    XCTAssertEqual(candidates.map(\.name), ["Night"])
    XCTAssertEqual(candidates.first?.relativePath, "themes/night.json")
  }

  func testSublimeColorSchemeVariablesAndRulesImport() throws {
    let source = #"""
      {
        "name": "Sublime Sample",
        "variables": {
          "bg": "#20242A",
          "fg": "#D8DEE9",
          "accent": "#88C0D0"
        },
        "globals": {
          "background": "var(bg)",
          "foreground": "var(fg)",
          "caret": "var(accent)"
        },
        "rules": [
          { "name": "Functions", "scope": "entity.name.function", "foreground": "var(accent)", "font_style": "italic" }
        ]
      }
      """#

    let result = try EditorThemeImporter.importTheme(
      from: Data(source.utf8),
      sourceURL: URL(fileURLWithPath: "/tmp/sample.sublime-color-scheme")
    )
    XCTAssertEqual(result.theme.editorBackground, EditorColor(hex: "#20242A"))
    XCTAssertEqual(result.theme[color: "editorCursor.foreground"], EditorColor(hex: "#88C0D0"))
    XCTAssertEqual(
      result.theme.style(forSyntaxCapture: "function")?.foreground,
      EditorColor(hex: "#88C0D0")
    )
  }

  func testXcodeColorThemeImportsCoreSurfaceAndSyntaxColors() throws {
    let propertyList: [String: Any] = [
      "DVTSourceTextBackground": "0.1 0.2 0.3 1",
      "DVTSourceTextPlainTextColor": "0.9 0.8 0.7 1",
      "DVTSourceTextInsertionPointColor": "1 0 0 1",
      "DVTSourceTextSyntaxColors": [
        "xcode.syntax.keyword": "0.8 0.3 0.9 1",
        "xcode.syntax.comment": "0.4 0.5 0.6 1",
      ],
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: propertyList,
      format: .xml,
      options: 0
    )

    let result = try EditorThemeImporter.importTheme(
      from: data,
      sourceURL: URL(fileURLWithPath: "/tmp/Test.xccolortheme")
    )
    XCTAssertEqual(result.theme.editorBackground, EditorColor(red: 26, green: 51, blue: 77))
    XCTAssertEqual(
      result.theme.style(forSyntaxCapture: "keyword")?.foreground,
      EditorColor(red: 204, green: 77, blue: 230)
    )
  }

  func testNeovimLuaResolvesPaletteAliasesAndLocalColors() throws {
    let source = #"""
      local colors = {
        bg = "#101820",
        fg = "#E8EEF2",
        accent = "#55CCFF",
      }
      local warning = "#FFAA44"
      vim.api.nvim_set_hl(0, "Normal", { fg = colors.fg, bg = colors.bg })
      vim.api.nvim_set_hl(0, "Function", { fg = colors.accent, bold = true })
      vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = warning })
      """#

    let result = try EditorThemeImporter.importTheme(
      from: Data(source.utf8),
      sourceURL: URL(fileURLWithPath: "/tmp/sample.lua")
    )
    XCTAssertEqual(result.theme.editorBackground, EditorColor(hex: "#101820"))
    XCTAssertEqual(
      result.theme.style(forSyntaxCapture: "function")?.foreground,
      EditorColor(hex: "#55CCFF")
    )
    XCTAssertEqual(result.theme[color: "editorWarning.foreground"], EditorColor(hex: "#FFAA44"))
  }

  func testNeovimJSONImportsTerminalPalette() throws {
    let source = #"""
      {
        "name": "Terminal Sample",
        "highlights": {
          "Normal": { "fg": "#EEEEEE", "bg": "#111111" }
        },
        "terminal_colors": [
          "#000000", "#AA0000", "#00AA00", "#AA5500",
          "#0000AA", "#AA00AA", "#00AAAA", "#AAAAAA",
          "#555555", "#FF5555", "#55FF55", "#FFFF55",
          "#5555FF", "#FF55FF", "#55FFFF", "#FFFFFF"
        ]
      }
      """#

    let result = try EditorThemeImporter.importTheme(from: Data(source.utf8), format: .neovimJSON)
    XCTAssertEqual(result.theme[color: "terminal.ansiRed"], EditorColor(hex: "#AA0000"))
    XCTAssertEqual(result.theme[color: "terminal.ansiBrightWhite"], EditorColor(hex: "#FFFFFF"))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteThemeImporterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
