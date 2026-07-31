import Foundation

public enum EditorThemeFormat: String, Hashable, Codable, Sendable, CaseIterable {
  case automatic
  case editorServicesJSON
  case vsCodeJSON
  case textMateJSON
  case textMatePropertyList
  case sublimeColorScheme
  case xcodeColorTheme
  case neovimJSON
  case vimColorScheme
  case neovimLua
}

public enum EditorThemeImportDiagnosticSeverity: String, Hashable, Codable, Sendable {
  case warning
  case information
}

public struct EditorThemeImportDiagnostic: Hashable, Codable, Sendable {
  public var severity: EditorThemeImportDiagnosticSeverity
  public var message: String
  public var source: String?

  public init(
    severity: EditorThemeImportDiagnosticSeverity,
    message: String,
    source: String? = nil
  ) {
    self.severity = severity
    self.message = message
    self.source = source
  }
}

public struct EditorThemeImportResult: Hashable, Codable, Sendable {
  public var theme: EditorTheme
  public var diagnostics: [EditorThemeImportDiagnostic]

  public init(theme: EditorTheme, diagnostics: [EditorThemeImportDiagnostic] = []) {
    self.theme = theme
    self.diagnostics = diagnostics
  }
}

public struct EditorThemeImportCandidate: Hashable, Codable, Sendable, Identifiable {
  public var name: String
  public var url: URL
  public var containerURL: URL?

  public init(name: String, url: URL, containerURL: URL? = nil) {
    self.name = name
    self.url = url.standardizedFileURL
    self.containerURL = containerURL?.standardizedFileURL
  }

  public var id: String { url.standardizedFileURL.path }

  public var relativePath: String? {
    guard let containerURL else { return nil }
    let root = containerURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(root + "/") else { return nil }
    return String(path.dropFirst(root.count + 1))
  }
}

public enum EditorThemeImportError: Error, Equatable, Sendable {
  case emptyInput
  case invalidUTF8
  case invalidJSON(String)
  case invalidPropertyList(String)
  case invalidRoot(String)
  case unsupportedFormat
  case includeCycle(URL)
  case includeDepthExceeded
}

extension EditorThemeImportError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .emptyInput:
      return "The theme input is empty."
    case .invalidUTF8:
      return "The theme is not valid UTF-8 text."
    case .invalidJSON(let message):
      return "The theme JSON is invalid: \(message)"
    case .invalidPropertyList(let message):
      return "The TextMate property list is invalid: \(message)"
    case .invalidRoot(let message):
      return "The theme root is invalid: \(message)"
    case .unsupportedFormat:
      return "The theme format could not be detected or is unsupported."
    case .includeCycle(let url):
      return "The VS Code theme include chain contains a cycle at \(url.path)."
    case .includeDepthExceeded:
      return "The VS Code theme include chain is too deep."
    }
  }
}

/// Imports VS Code, TextMate, Sublime Text, Xcode, Vim, and Neovim themes into ``EditorTheme``.
///
/// Lua files are parsed as data and are never executed. Literal
/// `nvim_set_hl` calls and literal `vim.cmd` highlight blocks are supported;
/// dynamically generated Lua themes should be exported with
/// `nvim_get_hl(0, {})` and imported as Neovim JSON.
public enum EditorThemeImporter {
  public static func decode(
    _ data: Data,
    format: EditorThemeFormat = .automatic,
    sourceURL: URL? = nil
  ) throws -> EditorTheme {
    try importTheme(from: data, format: format, sourceURL: sourceURL).theme
  }

  public static func decode(
    _ text: String,
    format: EditorThemeFormat = .automatic,
    sourceURL: URL? = nil
  ) throws -> EditorTheme {
    try decode(Data(text.utf8), format: format, sourceURL: sourceURL)
  }

  public static func importTheme(
    from data: Data,
    format: EditorThemeFormat = .automatic,
    sourceURL: URL? = nil
  ) throws -> EditorThemeImportResult {
    guard !data.isEmpty else { throw EditorThemeImportError.emptyInput }
    let resolved = try resolveFormat(format, data: data, sourceURL: sourceURL)
    return try parse(
      data,
      format: resolved,
      sourceURL: sourceURL,
      externalReferencesResolved: false
    )
  }

  /// Loads a theme from disk and resolves relative VS Code `include` and
  /// external `tokenColors` references without changing the process working directory.
  public static func load(
    from url: URL,
    format: EditorThemeFormat = .automatic
  ) throws -> EditorThemeImportResult {
    let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let values = try? canonicalURL.resourceValues(forKeys: [.isDirectoryKey])
    if values?.isDirectory == true {
      return try loadDirectory(from: canonicalURL)
    }
    var activeURLs = Set<URL>()
    return try load(from: canonicalURL, format: format, depth: 0, activeURLs: &activeURLs)
  }

  public static func discoverThemes(in url: URL) throws -> [EditorThemeImportCandidate] {
    let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let values = try canonicalURL.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else {
      return [
        EditorThemeImportCandidate(
          name: canonicalURL.deletingPathExtension().lastPathComponent,
          url: canonicalURL
        )
      ]
    }
    return directoryThemeInventory(in: canonicalURL).candidates
  }

  public static func load(_ candidate: EditorThemeImportCandidate) throws -> EditorThemeImportResult {
    if let containerURL = candidate.containerURL {
      return try loadDirectory(from: containerURL, preferredThemeURL: candidate.url)
    }
    return try load(from: candidate.url)
  }

  private struct DirectoryThemeInventory {
    var candidates: [EditorThemeImportCandidate]
    var importableFiles: [URL]
  }

  private static func loadDirectory(
    from directoryURL: URL,
    preferredThemeURL: URL? = nil
  ) throws -> EditorThemeImportResult {
    let inventory = directoryThemeInventory(in: directoryURL)
    let preferred = preferredThemeURL?.standardizedFileURL
    let candidate = preferred.flatMap { url in
      inventory.candidates.first { $0.url.standardizedFileURL == url }
        ?? EditorThemeImportCandidate(
          name: url.deletingPathExtension().lastPathComponent,
          url: url,
          containerURL: directoryURL
        )
    } ?? inventory.candidates.first

    guard let candidate else {
      let luaFiles = inventory.importableFiles.filter { $0.pathExtension.lowercased() == "lua" }
      guard !luaFiles.isEmpty else {
        throw EditorThemeImportError.invalidRoot(
          "No importable VS Code, TextMate, Vim, or Neovim theme was found in the folder"
        )
      }
      return try loadNeovimLuaFolder(
        directoryURL: directoryURL,
        files: luaFiles,
        preferredThemeURL: nil,
        candidateCount: 1,
        displayName: directoryURL.lastPathComponent
      )
    }

    var result: EditorThemeImportResult
    if candidate.url.pathExtension.lowercased() == "lua" {
      let candidateURLs = Set(inventory.candidates.map { $0.url.standardizedFileURL })
      let supportFiles = inventory.importableFiles.filter { url in
        guard url.pathExtension.lowercased() == "lua" else { return false }
        return url.standardizedFileURL == candidate.url.standardizedFileURL
          || !candidateURLs.contains(url.standardizedFileURL)
      }
      result = try loadNeovimLuaFolder(
        directoryURL: directoryURL,
        files: supportFiles,
        preferredThemeURL: candidate.url,
        candidateCount: inventory.candidates.count,
        displayName: candidate.name
      )
    } else {
      result = try load(from: candidate.url)
      result.theme.name = result.theme.name.isEmpty ? candidate.name : result.theme.name
    }

    result.theme.metadata["import.directory"] = directoryURL.path
    result.theme.metadata["import.candidateCount"] = String(inventory.candidates.count)
    result.theme.metadata["import.selectedCandidate"] = candidate.relativePath ?? candidate.url.path
    if preferredThemeURL == nil, inventory.candidates.count > 1 {
      result.diagnostics.append(
        .information(
          "The folder contains \(inventory.candidates.count) theme variants; selected \(candidate.name).",
          source: directoryURL
        )
      )
    }
    return result
  }

  private static func loadNeovimLuaFolder(
    directoryURL: URL,
    files: [URL],
    preferredThemeURL: URL?,
    candidateCount: Int,
    displayName: String
  ) throws -> EditorThemeImportResult {
    let preferred = preferredThemeURL?.standardizedFileURL
    let ordered = files.sorted { lhs, rhs in
      if lhs.standardizedFileURL == preferred { return false }
      if rhs.standardizedFileURL == preferred { return true }
      let lhsSupport = isLuaSupportFile(lhs)
      let rhsSupport = isLuaSupportFile(rhs)
      if lhsSupport != rhsSupport { return lhsSupport }
      return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
    let combined = try ordered.map { url in
      "-- Calcite source: \(url.path)\n" + (try String(contentsOf: url, encoding: .utf8))
    }.joined(separator: "\n\n-- Calcite module boundary --\n\n")
    var result = try importTheme(
      from: Data(combined.utf8),
      format: .neovimLua,
      sourceURL: preferredThemeURL ?? directoryURL
    )
    result.theme.name = displayName
    result.theme.metadata["import.directory"] = directoryURL.path
    result.theme.metadata["import.candidateCount"] = String(candidateCount)
    return result
  }

  private static func directoryThemeInventory(in directoryURL: URL) -> DirectoryThemeInventory {
    let fileManager = FileManager.default
    var importableFiles: [URL] = []
    var manifestCandidates: [EditorThemeImportCandidate] = []
    let skippedNames: Set<String> = [
      ".git", ".build", "build", "dist", "node_modules", "vendor", ".cache",
    ]

    if let enumerator = fileManager.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
      options: [.skipsPackageDescendants],
      errorHandler: { _, _ in true }
    ) {
      while let item = enumerator.nextObject() as? URL {
        let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values?.isDirectory == true, skippedNames.contains(item.lastPathComponent) {
          enumerator.skipDescendants()
          continue
        }
        guard values?.isRegularFile == true else { continue }
        if item.lastPathComponent == "package.json" {
          manifestCandidates.append(
            contentsOf: themeCandidatesFromVSCodeManifest(item, containerURL: directoryURL)
          )
          continue
        }
        let ext = item.pathExtension.lowercased()
        guard [
          "json", "jsonc", "vim", "lua", "tmtheme", "plist",
          "sublime-color-scheme", "sublime-theme", "xccolortheme"
        ].contains(ext) else {
          continue
        }
        let lowerPath = item.path.lowercased()
        let lowerName = item.deletingPathExtension().lastPathComponent.lowercased()
        let isLikelyTheme = lowerPath.contains("/colors/")
          || lowerPath.contains("/themes/")
          || lowerName.contains("theme")
          || lowerName.contains("color")
          || lowerName.contains("highlight")
          || lowerName.contains("palette")
        if isLikelyTheme { importableFiles.append(item.standardizedFileURL) }
      }
    }

    var candidates = manifestCandidates
    let manifestURLs = Set(manifestCandidates.map { $0.url.standardizedFileURL })
    for file in importableFiles where !manifestURLs.contains(file.standardizedFileURL) {
      let lowerPath = file.path.lowercased()
      let lowerName = file.deletingPathExtension().lastPathComponent.lowercased()
      let ext = file.pathExtension.lowercased()
      let isEntrypoint = lowerPath.contains("/colors/")
        || lowerPath.contains("/themes/")
        || (lowerName.contains("theme") && !isLuaSupportFile(file))
        || (ext == "vim" && !lowerName.contains("palette"))
      if isEntrypoint {
        candidates.append(
          EditorThemeImportCandidate(
            name: file.deletingPathExtension().lastPathComponent,
            url: file,
            containerURL: directoryURL
          )
        )
      }
    }

    if candidates.isEmpty, let best = importableFiles.max(by: {
      themeCandidateScore($0) < themeCandidateScore($1)
    }) {
      candidates = [
        EditorThemeImportCandidate(
          name: best.deletingPathExtension().lastPathComponent,
          url: best,
          containerURL: directoryURL
        )
      ]
    }

    var seen = Set<String>()
    candidates = candidates.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
      .sorted {
        let left = themeCandidateScore($0.url)
        let right = themeCandidateScore($1.url)
        if left != right { return left > right }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
    importableFiles = Array(Set(importableFiles.map(\.standardizedFileURL))).sorted {
      $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
    return DirectoryThemeInventory(candidates: candidates, importableFiles: importableFiles)
  }

  private static func themeCandidatesFromVSCodeManifest(
    _ url: URL,
    containerURL: URL
  ) -> [EditorThemeImportCandidate] {
    guard let data = try? Data(contentsOf: url),
      let normalized = try? normalizedJSONData(data),
      let root = try? JSONSerialization.jsonObject(with: normalized) as? [String: Any],
      let contributes = root["contributes"] as? [String: Any],
      let themes = contributes["themes"] as? [[String: Any]]
    else { return [] }
    return themes.compactMap { theme in
      guard let path = theme["path"] as? String else { return nil }
      let target = resolve(path, relativeTo: url)
      let name = (theme["label"] as? String)
        ?? (theme["id"] as? String)
        ?? target.deletingPathExtension().lastPathComponent
      return EditorThemeImportCandidate(name: name, url: target, containerURL: containerURL)
    }
  }

  private static func isLuaSupportFile(_ url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "lua" else { return false }
    let lower = url.deletingPathExtension().lastPathComponent.lowercased()
    return lower.contains("palette")
      || lower.contains("highlight")
      || lower.contains("color") && !url.path.lowercased().contains("/colors/")
  }

  private static func themeCandidateScore(_ url: URL) -> Int {
    let lower = url.path.lowercased()
    var score = 0
    if lower.contains("/colors/") { score += 80 }
    if lower.contains("/themes/") { score += 70 }
    if lower.contains("highlight") { score += 35 }
    if lower.contains("theme") { score += 25 }
    if lower.contains("palette") { score += 10 }
    switch url.pathExtension.lowercased() {
    case "json", "jsonc", "tmtheme", "sublime-color-scheme", "xccolortheme": score += 20
    case "vim": score += 15
    case "lua": score += 10
    default: break
    }
    return score
  }

  private static func load(
    from url: URL,
    format: EditorThemeFormat,
    depth: Int,
    activeURLs: inout Set<URL>
  ) throws -> EditorThemeImportResult {
    guard depth <= 16 else { throw EditorThemeImportError.includeDepthExceeded }
    let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
    guard activeURLs.insert(canonicalURL).inserted else {
      throw EditorThemeImportError.includeCycle(canonicalURL)
    }
    defer { activeURLs.remove(canonicalURL) }

    let data = try Data(contentsOf: canonicalURL)
    let resolved = try resolveFormat(format, data: data, sourceURL: canonicalURL)
    guard resolved == .vsCodeJSON else {
      return try parse(
        data,
        format: resolved,
        sourceURL: canonicalURL,
        externalReferencesResolved: true
      )
    }

    let root = try jsonObject(from: data)
    guard let object = root as? [String: Any] else {
      throw EditorThemeImportError.invalidRoot("VS Code themes require a JSON object")
    }

    var accumulated: EditorThemeImportResult?
    var referenceDiagnostics: [EditorThemeImportDiagnostic] = []
    if let includePath = object["include"] as? String, !includePath.isEmpty {
      let includeURL = resolve(includePath, relativeTo: canonicalURL)
      do {
        accumulated = try load(
          from: includeURL,
          format: .automatic,
          depth: depth + 1,
          activeURLs: &activeURLs
        )
      } catch {
        referenceDiagnostics.append(
          .warning(
            "Could not load included theme \(includePath): \(error.localizedDescription). Imported the current file without it.",
            source: canonicalURL
          )
        )
      }
    }

    if let tokenPath = object["tokenColors"] as? String, !tokenPath.isEmpty {
      let tokenURL = resolve(tokenPath, relativeTo: canonicalURL)
      do {
        let tokenResult = try load(
          from: tokenURL,
          format: .automatic,
          depth: depth + 1,
          activeURLs: &activeURLs
        )
        if let current = accumulated {
          accumulated = EditorThemeImportResult(
            theme: current.theme.overlaying(tokenResult.theme),
            diagnostics: current.diagnostics + tokenResult.diagnostics
          )
        } else {
          accumulated = tokenResult
        }
      } catch {
        referenceDiagnostics.append(
          .warning(
            "Could not load external token colors \(tokenPath): \(error.localizedDescription). Imported the remaining theme colors.",
            source: canonicalURL
          )
        )
      }
    }

    var current = try parse(
      data,
      format: .vsCodeJSON,
      sourceURL: canonicalURL,
      externalReferencesResolved: true
    )
    current.diagnostics.insert(contentsOf: referenceDiagnostics, at: 0)
    guard let accumulated else { return current }
    return EditorThemeImportResult(
      theme: accumulated.theme.overlaying(current.theme),
      diagnostics: accumulated.diagnostics + current.diagnostics
    )
  }

  private static func parse(
    _ data: Data,
    format: EditorThemeFormat,
    sourceURL: URL?,
    externalReferencesResolved: Bool
  ) throws -> EditorThemeImportResult {
    switch format {
    case .automatic:
      preconditionFailure("Automatic format must be resolved before parsing")
    case .editorServicesJSON:
      return try parseNativeJSON(data)
    case .vsCodeJSON:
      return try parseVSCodeJSON(
        data,
        sourceURL: sourceURL,
        externalReferencesResolved: externalReferencesResolved
      )
    case .textMateJSON:
      return try parseTextMateJSON(data, sourceURL: sourceURL)
    case .textMatePropertyList:
      return try parseTextMatePropertyList(data, sourceURL: sourceURL)
    case .sublimeColorScheme:
      return try parseSublimeColorScheme(data, sourceURL: sourceURL)
    case .xcodeColorTheme:
      return try parseXcodeColorTheme(data, sourceURL: sourceURL)
    case .neovimJSON:
      return try parseNeovimJSON(data, sourceURL: sourceURL)
    case .vimColorScheme:
      return try parseVimColorScheme(data, sourceURL: sourceURL)
    case .neovimLua:
      return try parseNeovimLua(data, sourceURL: sourceURL)
    }
  }

  private static func resolveFormat(
    _ requested: EditorThemeFormat,
    data: Data,
    sourceURL: URL?
  ) throws -> EditorThemeFormat {
    guard requested == .automatic else { return requested }

    switch sourceURL?.pathExtension.lowercased() {
    case "vim": return .vimColorScheme
    case "lua": return .neovimLua
    case "tmtheme", "plist": return .textMatePropertyList
    case "sublime-color-scheme", "sublime-theme": return .sublimeColorScheme
    case "xccolortheme": return .xcodeColorTheme
    default: break
    }

    guard let text = String(data: data, encoding: .utf8) else {
      // Binary property lists are valid TextMate themes.
      if (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil {
        return .textMatePropertyList
      }
      throw EditorThemeImportError.invalidUTF8
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw EditorThemeImportError.emptyInput }

    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") {
      let root = try jsonObject(from: data)
      if let object = root as? [String: Any] {
        if object["rules"] != nil,
           object["colors"] != nil,
           object["source"] != nil || object["appearance"] != nil {
          return .editorServicesJSON
        }
        if object["variables"] != nil,
           object["globals"] != nil || object["rules"] is [Any] {
          return .sublimeColorScheme
        }
        if object["settings"] is [Any] {
          return .textMateJSON
        }
        if object["tokenColors"] != nil || object["semanticTokenColors"] != nil || object["include"] != nil {
          return .vsCodeJSON
        }
        if let schema = object["$schema"] as? String,
           schema.lowercased().contains("color-theme") {
          return .vsCodeJSON
        }
        if object["highlights"] != nil || object["groups"] != nil || object["highlightGroups"] != nil {
          return .neovimJSON
        }
        if let colors = object["colors"] as? [String: Any], !colors.isEmpty {
          return .vsCodeJSON
        }
        if looksLikeNeovimGroupObject(object) { return .neovimJSON }
      } else if let array = root as? [Any] {
        if array.contains(where: { item in
          guard let object = item as? [String: Any] else { return false }
          return object["scope"] != nil || object["settings"] != nil
        }) {
          return .textMateJSON
        }
        if array.contains(where: { item in
          guard let object = item as? [String: Any] else { return false }
          return object["name"] != nil || object["group"] != nil
        }) {
          return .neovimJSON
        }
      }
      throw EditorThemeImportError.unsupportedFormat
    }

    let lower = trimmed.lowercased()
    if lower.contains("nvim_set_hl") || lower.contains("vim.api.nvim_set_hl") || lower.contains("vim.cmd") {
      return .neovimLua
    }
    if lower.contains("highlight ") || lower.contains("hi ") || lower.contains("colors_name") {
      return .vimColorScheme
    }
    throw EditorThemeImportError.unsupportedFormat
  }

  // MARK: Native JSON

  private static func parseNativeJSON(_ data: Data) throws -> EditorThemeImportResult {
    do {
      let normalized = try normalizedJSONData(data)
      return EditorThemeImportResult(theme: try JSONDecoder().decode(EditorTheme.self, from: normalized))
    } catch let error as EditorThemeImportError {
      throw error
    } catch {
      throw EditorThemeImportError.invalidJSON(error.localizedDescription)
    }
  }

  // MARK: VS Code and TextMate

  private static func parseVSCodeJSON(
    _ data: Data,
    sourceURL: URL?,
    externalReferencesResolved: Bool
  ) throws -> EditorThemeImportResult {
    let root = try jsonObject(from: data)
    guard let object = root as? [String: Any] else {
      throw EditorThemeImportError.invalidRoot("VS Code themes require a JSON object")
    }

    var diagnostics: [EditorThemeImportDiagnostic] = []
    var colors: [String: EditorColor] = [:]
    if let sourceColors = object["colors"] as? [String: Any] {
      for (key, value) in sourceColors {
        if value is NSNull { continue }
        if let color = parseColor(value) {
          colors[key] = color
        } else {
          diagnostics.append(.warning("Ignored invalid VS Code color for \(key)", source: sourceURL))
        }
      }
    }

    var rules: [EditorThemeRule] = []
    if let tokenRules = object["tokenColors"] as? [Any] {
      for (index, rawRule) in tokenRules.enumerated() {
        guard let rule = rawRule as? [String: Any],
              let settings = rule["settings"] as? [String: Any] else {
          diagnostics.append(.warning("Ignored malformed tokenColors rule at index \(index)", source: sourceURL))
          continue
        }
        let scopes = parseScopes(rule["scope"])
        guard !scopes.isEmpty else { continue }
        let style = parseVSCodeStyle(settings, diagnostics: &diagnostics, sourceURL: sourceURL)
        guard !style.isEmpty else { continue }
        var selectors: [EditorThemeSelector] = []
        for scope in scopes {
          appendUnique(.textMate(scope), to: &selectors)
          for capture in EditorThemeScopeMapping.syntaxCaptures(forTextMateScope: scope) {
            appendUnique(.syntax(capture), to: &selectors)
          }
        }
        rules.append(EditorThemeRule(
          name: rule["name"] as? String,
          selectors: selectors,
          style: style
        ))
      }
    } else if object["tokenColors"] is String, !externalReferencesResolved {
      diagnostics.append(.warning(
        "External tokenColors require load(from:) so the relative file can be resolved",
        source: sourceURL
      ))
    }

    if let semanticRules = object["semanticTokenColors"] as? [String: Any] {
      for (selectorText, rawStyle) in semanticRules {
        guard let selector = parseSemanticSelector(selectorText) else {
          diagnostics.append(.warning("Ignored invalid semantic token selector \(selectorText)", source: sourceURL))
          continue
        }
        let style: EditorTextStyle
        if let value = rawStyle as? String {
          guard let foreground = parseColor(value) else {
            diagnostics.append(.warning("Ignored invalid semantic color for \(selectorText)", source: sourceURL))
            continue
          }
          style = EditorTextStyle(foreground: foreground)
        } else if let value = rawStyle as? [String: Any] {
          style = parseVSCodeStyle(value, diagnostics: &diagnostics, sourceURL: sourceURL)
        } else {
          diagnostics.append(.warning("Ignored malformed semantic token rule \(selectorText)", source: sourceURL))
          continue
        }
        guard !style.isEmpty else { continue }
        rules.append(EditorThemeRule(selectors: [selector], style: style))
      }
    }

    let name = nonEmptyString(object["name"])
      ?? sourceURL?.deletingPathExtension().lastPathComponent
      ?? "Imported VS Code Theme"
    var metadata: [String: String] = [:]
    if let include = object["include"] as? String { metadata["vscode.include"] = include }
    if let semantic = object["semanticHighlighting"] as? Bool {
      metadata["vscode.semanticHighlighting"] = String(semantic)
    }
    let type = (object["type"] as? String)?.lowercased()
    var appearance: EditorThemeAppearance
    switch type {
    case "dark": appearance = .dark
    case "light": appearance = .light
    case "hc", "highcontrast", "high-contrast": appearance = .highContrastDark
    case "hc-light", "highcontrastlight", "high-contrast-light": appearance = .highContrastLight
    default: appearance = inferAppearance(from: colors["editor.background"])
    }

    return EditorThemeImportResult(
      theme: EditorTheme(
        name: name,
        appearance: appearance,
        source: .vsCode,
        colors: colors,
        rules: rules,
        metadata: metadata
      ),
      diagnostics: diagnostics
    )
  }

  private static func parseTextMateJSON(
    _ data: Data,
    sourceURL: URL?
  ) throws -> EditorThemeImportResult {
    let root = try jsonObject(from: data)
    let object: [String: Any]
    if let value = root as? [String: Any] {
      object = value
    } else if let settings = root as? [Any] {
      object = ["settings": settings]
    } else {
      throw EditorThemeImportError.invalidRoot("TextMate JSON themes require an object or a settings array")
    }
    guard let settingsArray = object["settings"] as? [Any] else {
      throw EditorThemeImportError.invalidRoot("TextMate JSON themes require a settings array")
    }
    return parseTextMateSettings(
      object: object,
      settingsArray: settingsArray,
      sourceURL: sourceURL,
      formatName: "textmate-json"
    )
  }

  private static func parseSublimeColorScheme(
    _ data: Data,
    sourceURL: URL?
  ) throws -> EditorThemeImportResult {
    let root = try jsonObject(from: data)
    guard let object = root as? [String: Any] else {
      throw EditorThemeImportError.invalidRoot("Sublime color schemes require a JSON object")
    }

    let variables = (object["variables"] as? [String: Any]) ?? [:]
    var diagnostics: [EditorThemeImportDiagnostic] = []

    func resolved(_ value: Any?) -> Any? {
      guard let value else { return nil }
      guard let string = value as? String else { return value }
      var current = string.trimmingCharacters(in: .whitespacesAndNewlines)
      var visited = Set<String>()
      for _ in 0..<16 {
        guard current.hasPrefix("var("), current.hasSuffix(")") else { return current }
        let name = String(current.dropFirst(4).dropLast())
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard visited.insert(name).inserted, let next = variables[name] else { return nil }
        if let nextString = next as? String { current = nextString }
        else { return next }
      }
      return nil
    }

    func color(_ value: Any?) -> EditorColor? {
      guard let value = resolved(value) else { return nil }
      return parseColor(value)
    }

    var colors: [String: EditorColor] = [:]
    if let globals = object["globals"] as? [String: Any] {
      let mappings: [(String, String)] = [
        ("foreground", "editor.foreground"),
        ("background", "editor.background"),
        ("caret", "editorCursor.foreground"),
        ("line_highlight", "editor.lineHighlightBackground"),
        ("selection", "editor.selectionBackground"),
        ("selection_border", "editor.selectionHighlightBorder"),
        ("inactive_selection", "editor.inactiveSelectionBackground"),
        ("find_highlight", "editor.findMatchBackground"),
        ("find_highlight_foreground", "editor.findMatchForeground"),
        ("gutter", "editorGutter.background"),
        ("gutter_foreground", "editorLineNumber.foreground"),
        ("guide", "editorIndentGuide.background1"),
        ("active_guide", "editorIndentGuide.activeBackground1"),
        ("stack_guide", "editorBracketPairGuide.background1"),
      ]
      for (sourceKey, targetKey) in mappings {
        if let parsed = color(globals[sourceKey]) { colors[targetKey] = parsed }
      }
    }

    var rules: [EditorThemeRule] = []
    if let rawRules = object["rules"] as? [Any] {
      for (index, rawRule) in rawRules.enumerated() {
        guard let rule = rawRule as? [String: Any] else {
          diagnostics.append(.warning("Ignored malformed Sublime rule at index \(index)", source: sourceURL))
          continue
        }
        let scopes = parseScopes(rule["scope"])
        guard !scopes.isEmpty else { continue }
        var style = EditorTextStyle()
        if let parsed = color(rule["foreground"]) { style.foreground = parsed }
        if let parsed = color(rule["background"]) { style.background = parsed }
        if let fontStyle = rule["font_style"] as? String {
          style.fontStyles = parseFontStyles(fontStyle)
        }
        guard !style.isEmpty else { continue }
        var selectors: [EditorThemeSelector] = []
        for scope in scopes {
          appendUnique(.textMate(scope), to: &selectors)
          for capture in EditorThemeScopeMapping.syntaxCaptures(forTextMateScope: scope) {
            appendUnique(.syntax(capture), to: &selectors)
          }
        }
        rules.append(
          EditorThemeRule(
            name: nonEmptyString(rule["name"]),
            selectors: selectors,
            style: style
          )
        )
      }
    }

    let name = nonEmptyString(object["name"])
      ?? sourceURL?.deletingPathExtension().lastPathComponent
      ?? "Imported Sublime Theme"
    return EditorThemeImportResult(
      theme: EditorTheme(
        name: name,
        appearance: inferAppearance(from: colors["editor.background"]),
        source: .vsCode,
        colors: colors,
        rules: rules,
        metadata: ["format": "sublime-color-scheme"]
      ),
      diagnostics: diagnostics
    )
  }

  private static func parseXcodeColorTheme(
    _ data: Data,
    sourceURL: URL?
  ) throws -> EditorThemeImportResult {
    let root: Any
    do {
      root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    } catch {
      throw EditorThemeImportError.invalidPropertyList(error.localizedDescription)
    }
    guard let object = root as? [String: Any] else {
      throw EditorThemeImportError.invalidRoot("Xcode color themes require a property-list object")
    }

    func xcodeColor(_ value: Any?) -> EditorColor? {
      guard let value else { return nil }
      if let parsed = parseColor(value) { return parsed }
      guard let string = value as? String else { return nil }
      let components = string
        .split(whereSeparator: { $0.isWhitespace || $0 == "," })
        .compactMap { Double($0) }
      guard components.count >= 3 else { return nil }
      let scale = components.prefix(3).contains(where: { $0 > 1 }) ? 255.0 : 1.0
      func channel(_ index: Int) -> UInt8 {
        UInt8(max(0, min(255, (components[index] / scale * 255).rounded())))
      }
      let alpha: UInt8
      if components.count > 3 {
        let value = components[3] > 1 ? components[3] : components[3] * 255
        alpha = UInt8(max(0, min(255, value.rounded())))
      } else {
        alpha = 255
      }
      return EditorColor(red: channel(0), green: channel(1), blue: channel(2), alpha: alpha)
    }

    var colors: [String: EditorColor] = [:]
    let uiMappings: [(String, String)] = [
      ("DVTSourceTextPlainTextColor", "editor.foreground"),
      ("DVTSourceTextBackground", "editor.background"),
      ("DVTSourceTextInsertionPointColor", "editorCursor.foreground"),
      ("DVTSourceTextSelectionColor", "editor.selectionBackground"),
      ("DVTSourceTextCurrentLineHighlightColor", "editor.lineHighlightBackground"),
      ("DVTSourceTextInvisibleCharactersColor", "editorWhitespace.foreground"),
    ]
    for (sourceKey, targetKey) in uiMappings {
      if let parsed = xcodeColor(object[sourceKey]) { colors[targetKey] = parsed }
    }

    var rules: [EditorThemeRule] = []
    if let syntax = object["DVTSourceTextSyntaxColors"] as? [String: Any] {
      let mappings: [(String, [String])] = [
        ("xcode.syntax.comment", ["comment"]),
        ("xcode.syntax.comment.doc", ["comment.documentation", "comment"]),
        ("xcode.syntax.string", ["string"]),
        ("xcode.syntax.character", ["character", "string.special"]),
        ("xcode.syntax.number", ["number"]),
        ("xcode.syntax.keyword", ["keyword"]),
        ("xcode.syntax.identifier.function", ["function"]),
        ("xcode.syntax.identifier.type", ["type"]),
        ("xcode.syntax.identifier.variable", ["variable"]),
        ("xcode.syntax.attribute", ["attribute"]),
        ("xcode.syntax.preprocessor", ["keyword.directive"]),
        ("xcode.syntax.url", ["markup.link"]),
      ]
      for (key, captures) in mappings {
        guard let parsed = xcodeColor(syntax[key]) else { continue }
        rules.append(
          EditorThemeRule(
            name: key,
            selectors: captures.map { .syntax($0) },
            style: EditorTextStyle(foreground: parsed)
          )
        )
      }
    }

    let name = sourceURL?.deletingPathExtension().lastPathComponent ?? "Imported Xcode Theme"
    return EditorThemeImportResult(
      theme: EditorTheme(
        name: name,
        appearance: inferAppearance(from: colors["editor.background"]),
        source: .editorServices,
        colors: colors,
        rules: rules,
        metadata: ["format": "xcode-color-theme"]
      )
    )
  }

  private static func parseTextMateSettings(
    object: [String: Any],
    settingsArray: [Any],
    sourceURL: URL?,
    formatName: String
  ) -> EditorThemeImportResult {
    var diagnostics: [EditorThemeImportDiagnostic] = []
    var colors: [String: EditorColor] = [:]
    var rules: [EditorThemeRule] = []
    for (index, rawRule) in settingsArray.enumerated() {
      guard let rule = rawRule as? [String: Any],
            let settings = rule["settings"] as? [String: Any] else {
        diagnostics.append(.warning("Ignored malformed TextMate rule at index \(index)", source: sourceURL))
        continue
      }
      let scopes = parseScopes(rule["scope"])
      let style = parseVSCodeStyle(settings, diagnostics: &diagnostics, sourceURL: sourceURL)
      if scopes.isEmpty {
        if let foreground = style.foreground { colors["editor.foreground"] = foreground }
        if let background = style.background { colors["editor.background"] = background }
        continue
      }
      guard !style.isEmpty else { continue }
      var selectors: [EditorThemeSelector] = []
      for scope in scopes {
        appendUnique(.textMate(scope), to: &selectors)
        for capture in EditorThemeScopeMapping.syntaxCaptures(forTextMateScope: scope) {
          appendUnique(.syntax(capture), to: &selectors)
        }
      }
      rules.append(
        EditorThemeRule(
          name: rule["name"] as? String,
          selectors: selectors,
          style: style
        )
      )
    }

    let name = nonEmptyString(object["name"])
      ?? sourceURL?.deletingPathExtension().lastPathComponent
      ?? "Imported TextMate Theme"
    return EditorThemeImportResult(
      theme: EditorTheme(
        name: name,
        appearance: inferAppearance(from: colors["editor.background"]),
        source: .vsCode,
        colors: colors,
        rules: rules,
        metadata: ["format": formatName]
      ),
      diagnostics: diagnostics
    )
  }

  private static func parseTextMatePropertyList(
    _ data: Data,
    sourceURL: URL?
  ) throws -> EditorThemeImportResult {
    let root: Any
    do {
      root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    } catch {
      throw EditorThemeImportError.invalidPropertyList(error.localizedDescription)
    }
    guard let object = root as? [String: Any],
          let settingsArray = object["settings"] as? [Any] else {
      throw EditorThemeImportError.invalidRoot("TextMate themes require a settings array")
    }

    var diagnostics: [EditorThemeImportDiagnostic] = []
    var colors: [String: EditorColor] = [:]
    var rules: [EditorThemeRule] = []
    for (index, rawRule) in settingsArray.enumerated() {
      guard let rule = rawRule as? [String: Any],
            let settings = rule["settings"] as? [String: Any] else {
        diagnostics.append(.warning("Ignored malformed TextMate rule at index \(index)", source: sourceURL))
        continue
      }
      let scopes = parseScopes(rule["scope"])
      let style = parseVSCodeStyle(settings, diagnostics: &diagnostics, sourceURL: sourceURL)
      if scopes.isEmpty {
        if let foreground = style.foreground { colors["editor.foreground"] = foreground }
        if let background = style.background { colors["editor.background"] = background }
        continue
      }
      guard !style.isEmpty else { continue }
      var selectors: [EditorThemeSelector] = []
      for scope in scopes {
        appendUnique(.textMate(scope), to: &selectors)
        for capture in EditorThemeScopeMapping.syntaxCaptures(forTextMateScope: scope) {
          appendUnique(.syntax(capture), to: &selectors)
        }
      }
      rules.append(EditorThemeRule(
        name: rule["name"] as? String,
        selectors: selectors,
        style: style
      ))
    }

    let name = nonEmptyString(object["name"])
      ?? sourceURL?.deletingPathExtension().lastPathComponent
      ?? "Imported TextMate Theme"
    return EditorThemeImportResult(
      theme: EditorTheme(
        name: name,
        appearance: inferAppearance(from: colors["editor.background"]),
        source: .vsCode,
        colors: colors,
        rules: rules,
        metadata: ["format": "textmate"]
      ),
      diagnostics: diagnostics
    )
  }

  private static func parseScopes(_ value: Any?) -> [String] {
    let rawValues: [String]
    if let string = value as? String {
      rawValues = [string]
    } else if let values = value as? [String] {
      rawValues = values
    } else if let values = value as? [Any] {
      rawValues = values.compactMap { $0 as? String }
    } else {
      return []
    }

    var result: [String] = []
    func append(_ value: String) {
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty, !result.contains(normalized) else { return }
      result.append(normalized)
    }

    for raw in rawValues {
      for selector in raw.split(separator: ",") {
        var value = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("L:") || value.hasPrefix("R:") || value.hasPrefix("B:") {
          value = String(value.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let positiveComponents = value
          .split(whereSeparator: { $0.isWhitespace })
          .map(String.init)
          .prefix { !$0.hasPrefix("-") }
        guard !positiveComponents.isEmpty else { continue }
        append(value)
        if positiveComponents.count > 1, let mostSpecific = positiveComponents.last {
          append(mostSpecific)
        }
      }
    }
    return result
  }

  private static func parseVSCodeStyle(
    _ object: [String: Any],
    diagnostics: inout [EditorThemeImportDiagnostic],
    sourceURL: URL?
  ) -> EditorTextStyle {
    var style = EditorTextStyle()
    if let value = object["foreground"], !(value is NSNull) {
      if let color = parseColor(value) { style.foreground = color }
      else { diagnostics.append(.warning("Ignored invalid foreground color", source: sourceURL)) }
    }
    if let value = object["background"], !(value is NSNull) {
      if let color = parseColor(value) { style.background = color }
      else { diagnostics.append(.warning("Ignored invalid background color", source: sourceURL)) }
    }
    if let fontStyle = object["fontStyle"] as? String {
      style.fontStyles = parseFontStyles(fontStyle)
    }
    let semanticBooleanStyles: [(String, EditorFontStyle)] = [
      ("bold", .bold), ("italic", .italic), ("underline", .underline),
      ("strikethrough", .strikethrough)
    ]
    if semanticBooleanStyles.contains(where: { object[$0.0] != nil }) {
      var styles = style.fontStyles ?? []
      for (key, fontStyle) in semanticBooleanStyles {
        guard let enabled = parseBool(object[key]) else { continue }
        if enabled { styles.insert(fontStyle) } else { styles.remove(fontStyle) }
      }
      style.fontStyles = styles
    }
    return style
  }

  // MARK: Neovim JSON, Vim, and Lua

  private struct NeovimGroup {
    var name: String
    var style: EditorTextStyle
    var link: String?
  }

  private struct ParsedVim {
    var name: String?
    var appearance: EditorThemeAppearance = .unspecified
    var groups: [String: NeovimGroup] = [:]
    var diagnostics: [EditorThemeImportDiagnostic] = []
  }

  private static func parseNeovimJSON(
    _ data: Data,
    sourceURL: URL?
  ) throws -> EditorThemeImportResult {
    let root = try jsonObject(from: data)
    guard let object = root as? [String: Any] else {
      throw EditorThemeImportError.invalidRoot("Neovim JSON themes require an object")
    }

    var diagnostics: [EditorThemeImportDiagnostic] = []
    let name = nonEmptyString(object["name"])
      ?? sourceURL?.deletingPathExtension().lastPathComponent
      ?? "Imported Neovim Theme"
    let appearance = parseAppearance(object["background"] ?? object["appearance"])
    let rawGroups: Any
    if let value = object["highlights"] { rawGroups = value }
    else if let value = object["groups"] { rawGroups = value }
    else if let value = object["highlightGroups"] { rawGroups = value }
    else { rawGroups = object }

    let groups = parseNeovimGroups(rawGroups, diagnostics: &diagnostics, sourceURL: sourceURL)
    guard !groups.isEmpty else {
      throw EditorThemeImportError.invalidRoot("No Neovim highlight groups were found")
    }
    var result = makeNeovimTheme(
      name: name,
      appearance: appearance,
      groups: groups,
      source: .neovim,
      sourceURL: sourceURL,
      diagnostics: diagnostics
    )
    if let terminalColors = object["terminal_colors"] as? [Any] {
      let keys = [
        "terminal.ansiBlack", "terminal.ansiRed", "terminal.ansiGreen", "terminal.ansiYellow",
        "terminal.ansiBlue", "terminal.ansiMagenta", "terminal.ansiCyan", "terminal.ansiWhite",
        "terminal.ansiBrightBlack", "terminal.ansiBrightRed", "terminal.ansiBrightGreen",
        "terminal.ansiBrightYellow", "terminal.ansiBrightBlue", "terminal.ansiBrightMagenta",
        "terminal.ansiBrightCyan", "terminal.ansiBrightWhite",
      ]
      for (index, value) in terminalColors.prefix(keys.count).enumerated() {
        if let color = parseColor(value) { result.theme.colors[keys[index]] = color }
      }
    }
    return result
  }

  private static func parseVimColorScheme(
    _ data: Data,
    sourceURL: URL?
  ) throws -> EditorThemeImportResult {
    guard let text = String(data: data, encoding: .utf8) else {
      throw EditorThemeImportError.invalidUTF8
    }
    let parsed = parseVimText(text, sourceURL: sourceURL)
    guard !parsed.groups.isEmpty else {
      throw EditorThemeImportError.invalidRoot("No literal Vim highlight commands were found")
    }
    let name = parsed.name
      ?? sourceURL?.deletingPathExtension().lastPathComponent
      ?? "Imported Vim Theme"
    return makeNeovimTheme(
      name: name,
      appearance: parsed.appearance,
      groups: parsed.groups,
      source: .vim,
      sourceURL: sourceURL,
      diagnostics: parsed.diagnostics
    )
  }

  private static func parseNeovimLua(
    _ data: Data,
    sourceURL: URL?
  ) throws -> EditorThemeImportResult {
    guard let text = String(data: data, encoding: .utf8) else {
      throw EditorThemeImportError.invalidUTF8
    }
    var diagnostics: [EditorThemeImportDiagnostic] = []
    var groups: [String: NeovimGroup] = [:]
    let palettes = parseLuaPalettes(text)

    let callPattern = #"(?:vim\.api\.)?nvim_set_hl\s*\(\s*0\s*,\s*[\"']([^\"']+)[\"']\s*,\s*\{([^}]*)\}\s*\)"#
    for match in regexMatches(callPattern, in: text, options: [.dotMatchesLineSeparators]) {
      guard match.count >= 3 else { continue }
      let groupName = match[1]
      let table = parseLuaTable(match[2], palettes: palettes)
      let group = parseNeovimGroup(
        name: groupName,
        value: table,
        diagnostics: &diagnostics,
        sourceURL: sourceURL
      )
      groups[groupName] = group
    }

    let groupTablePattern = #"(?:[\"']?)(@?[A-Za-z_][A-Za-z0-9_@.]*)(?:[\"']?)\s*=\s*\{([^{}]*)\}"#
    for match in regexMatches(groupTablePattern, in: text, options: [.dotMatchesLineSeparators]) {
      guard match.count >= 3 else { continue }
      let name = match[1]
      guard !["colors", "palette", "opts", "options", "config"].contains(name.lowercased()) else {
        continue
      }
      let table = parseLuaTable(match[2], palettes: palettes)
      let parsed = parseNeovimGroup(
        name: name,
        value: table,
        diagnostics: &diagnostics,
        sourceURL: sourceURL
      )
      if !parsed.style.isEmpty || parsed.link != nil {
        groups[name] = parsed
      }
    }

    let bracketedGroupPattern = #"\[\s*[\"']([^\"']+)[\"']\s*\]\s*=\s*\{([^{}]*)\}"#
    for match in regexMatches(bracketedGroupPattern, in: text, options: [.dotMatchesLineSeparators]) {
      guard match.count >= 3 else { continue }
      let name = match[1]
      let table = parseLuaTable(match[2], palettes: palettes)
      let parsed = parseNeovimGroup(
        name: name,
        value: table,
        diagnostics: &diagnostics,
        sourceURL: sourceURL
      )
      if !parsed.style.isEmpty || parsed.link != nil {
        groups[name] = parsed
      }
    }

    let commandBlockPattern = #"vim\.cmd\s*\(?\s*\[\[(.*?)\]\]\s*\)?"#
    for match in regexMatches(commandBlockPattern, in: text, options: [.dotMatchesLineSeparators]) where match.count >= 2 {
      let parsed = parseVimText(match[1], sourceURL: sourceURL)
      groups.merge(parsed.groups) { _, new in new }
      diagnostics.append(contentsOf: parsed.diagnostics)
    }

    let commandStringPattern = #"vim\.cmd\s*\(\s*[\"'](hi(?:ghlight)?[^\"']*)[\"']\s*\)"#
    for match in regexMatches(commandStringPattern, in: text, options: [.caseInsensitive]) where match.count >= 2 {
      let command = match[1]
        .replacingOccurrences(of: #"\n"#, with: "\n")
        .replacingOccurrences(of: #"\""#, with: "\"")
      let parsed = parseVimText(command, sourceURL: sourceURL)
      groups.merge(parsed.groups) { _, new in new }
      diagnostics.append(contentsOf: parsed.diagnostics)
    }

    if text.contains("require("), palettes.isEmpty {
      diagnostics.append(.information(
        "The Lua theme imports modules dynamically; only literal highlight definitions were imported.",
        source: sourceURL
      ))
    }
    guard !groups.isEmpty else {
      throw EditorThemeImportError.invalidRoot(
        "No static nvim_set_hl calls, highlight tables, or vim.cmd highlight commands were found; export fully dynamic themes as nvim_get_hl JSON"
      )
    }
    let name = sourceURL?.deletingPathExtension().lastPathComponent ?? "Imported Neovim Lua Theme"
    return makeNeovimTheme(
      name: name,
      appearance: .unspecified,
      groups: groups,
      source: .neovim,
      sourceURL: sourceURL,
      diagnostics: diagnostics
    )
  }

  private static func parseNeovimGroups(
    _ rawGroups: Any,
    diagnostics: inout [EditorThemeImportDiagnostic],
    sourceURL: URL?
  ) -> [String: NeovimGroup] {
    var groups: [String: NeovimGroup] = [:]
    if let object = rawGroups as? [String: Any] {
      let metadataKeys: Set<String> = [
        "name", "background", "appearance", "type", "colors", "palette", "terminal_colors",
        "$schema", "metadata", "version", "author", "highlights", "groups", "highlightGroups"
      ]
      for (name, value) in object where !metadataKeys.contains(name) {
        guard value is [String: Any] || value is String else { continue }
        groups[name] = parseNeovimGroup(
          name: name,
          value: value,
          diagnostics: &diagnostics,
          sourceURL: sourceURL
        )
      }
    } else if let array = rawGroups as? [Any] {
      for (index, value) in array.enumerated() {
        guard let object = value as? [String: Any],
              let name = nonEmptyString(object["name"] ?? object["group"]) else {
          diagnostics.append(.warning("Ignored malformed Neovim group at index \(index)", source: sourceURL))
          continue
        }
        groups[name] = parseNeovimGroup(
          name: name,
          value: object,
          diagnostics: &diagnostics,
          sourceURL: sourceURL
        )
      }
    }
    return groups
  }

  private static func parseNeovimGroup(
    name: String,
    value: Any,
    diagnostics: inout [EditorThemeImportDiagnostic],
    sourceURL: URL?
  ) -> NeovimGroup {
    if let link = value as? String {
      return NeovimGroup(name: name, style: EditorTextStyle(), link: link)
    }
    guard let object = value as? [String: Any] else {
      return NeovimGroup(name: name, style: EditorTextStyle(), link: nil)
    }

    var style = EditorTextStyle()
    if let value = firstValue(in: object, keys: ["fg", "foreground", "guifg"]) {
      if let color = parseColor(value) { style.foreground = color }
      else if !isNone(value) { diagnostics.append(.warning("Ignored invalid foreground for \(name)", source: sourceURL)) }
    } else if let value = firstValue(in: object, keys: ["ctermfg"]) {
      style.foreground = parseTerminalColor(value)
    }
    if let value = firstValue(in: object, keys: ["bg", "background", "guibg"]) {
      if let color = parseColor(value) { style.background = color }
      else if !isNone(value) { diagnostics.append(.warning("Ignored invalid background for \(name)", source: sourceURL)) }
    } else if let value = firstValue(in: object, keys: ["ctermbg"]) {
      style.background = parseTerminalColor(value)
    }
    if let value = firstValue(in: object, keys: ["sp", "special", "guisp"]) {
      style.specialColor = parseColor(value)
    }

    var styles = Set<EditorFontStyle>()
    var hasStyleValue = false
    let booleanStyles: [(String, EditorFontStyle)] = [
      ("bold", .bold), ("italic", .italic), ("underline", .underline),
      ("undercurl", .undercurl), ("strikethrough", .strikethrough),
      ("standout", .reverse), ("reverse", .reverse), ("dim", .dim)
    ]
    for (key, fontStyle) in booleanStyles where object[key] != nil {
      hasStyleValue = true
      if parseBool(object[key]) == true { styles.insert(fontStyle) }
    }
    if let raw = firstValue(in: object, keys: ["gui", "cterm"]), let text = raw as? String {
      hasStyleValue = true
      styles.formUnion(parseFontStyles(text))
    }
    if hasStyleValue { style.fontStyles = styles }

    return NeovimGroup(
      name: name,
      style: style,
      link: nonEmptyString(object["link"])
    )
  }

  private static func parseVimText(_ text: String, sourceURL: URL?) -> ParsedVim {
    var parsed = ParsedVim()
    var logicalLines: [String] = []
    for rawLine in text.components(separatedBy: .newlines) {
      let line = stripVimComment(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if trimmed.hasPrefix("\\"), !logicalLines.isEmpty {
        logicalLines[logicalLines.count - 1] += " " + trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
      } else {
        logicalLines.append(trimmed)
      }
    }

    let colorsNamePattern = #"(?i)let\s+g:colors_name\s*=\s*[\"']([^\"']+)[\"']"#
    for line in logicalLines {
      if let match = regexMatches(colorsNamePattern, in: line).first, match.count >= 2 {
        parsed.name = match[1]
      }
      let lower = line.lowercased()
      if lower.contains("background=dark") || lower == "set bg=dark" { parsed.appearance = .dark }
      if lower.contains("background=light") || lower == "set bg=light" { parsed.appearance = .light }

      guard let command = parseHighlightCommand(line) else { continue }
      switch command {
      case .link(let from, let to):
        parsed.groups[from] = NeovimGroup(name: from, style: EditorTextStyle(), link: to)
      case .definition(let name, let attributes):
        parsed.groups[name] = parseNeovimGroup(
          name: name,
          value: attributes,
          diagnostics: &parsed.diagnostics,
          sourceURL: sourceURL
        )
      }
    }
    return parsed
  }

  private enum HighlightCommand {
    case link(String, String)
    case definition(String, [String: Any])
  }

  private static func parseHighlightCommand(_ line: String) -> HighlightCommand? {
    let pattern = #"(?i)^\s*(?:hi(?:ghlight)?)(?:!)?\s+(?:default\s+)?(.+)$"#
    guard let match = regexMatches(pattern, in: line).first, match.count >= 2 else { return nil }
    let body = match[1].trimmingCharacters(in: .whitespacesAndNewlines)
    let pieces = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !pieces.isEmpty else { return nil }
    if pieces[0].caseInsensitiveCompare("clear") == .orderedSame { return nil }
    if pieces[0].caseInsensitiveCompare("link") == .orderedSame, pieces.count >= 3 {
      return .link(pieces[1], pieces[2])
    }
    guard pieces.count >= 2 else { return nil }
    let name = pieces[0]
    var attributes: [String: Any] = [:]
    for item in pieces.dropFirst() {
      guard let equals = item.firstIndex(of: "=") else { continue }
      let key = String(item[..<equals]).lowercased()
      let value = String(item[item.index(after: equals)...])
      attributes[key] = value
    }
    return .definition(name, attributes)
  }

  private static func makeNeovimTheme(
    name: String,
    appearance: EditorThemeAppearance,
    groups: [String: NeovimGroup],
    source: EditorThemeSource,
    sourceURL: URL?,
    diagnostics initialDiagnostics: [EditorThemeImportDiagnostic]
  ) -> EditorThemeImportResult {
    var diagnostics = initialDiagnostics
    var resolved: [String: EditorTextStyle] = [:]
    var resolving = Set<String>()

    func resolveGroup(_ name: String) -> EditorTextStyle {
      if let cached = resolved[name] { return cached }
      guard let group = groups[name] else { return EditorTextStyle() }
      guard resolving.insert(name).inserted else {
        diagnostics.append(.warning("Ignored cyclic highlight link involving \(name)", source: sourceURL))
        return group.style
      }
      defer { resolving.remove(name) }
      var style = EditorTextStyle()
      if let link = group.link {
        if groups[link] != nil {
          style = resolveGroup(link)
        } else {
          diagnostics.append(.warning("Highlight group \(name) links to missing group \(link)", source: sourceURL))
        }
      }
      style.merge(group.style)
      resolved[name] = style
      return style
    }

    var rules: [EditorThemeRule] = []
    for name in groups.keys.sorted() {
      let style = resolveGroup(name)
      guard !style.isEmpty else { continue }
      var selectors: [EditorThemeSelector] = [.vim(name)]
      for selector in selectorsForNeovimGroup(name) { appendUnique(selector, to: &selectors) }
      rules.append(EditorThemeRule(name: name, selectors: selectors, style: style))
    }

    var colors: [String: EditorColor] = [:]
    for mapping in neovimUIMappings {
      guard let style = resolved[mapping.group] ?? groups[mapping.group].map({ _ in resolveGroup(mapping.group) }) else {
        continue
      }
      let displayed = displayStyle(style)
      if let key = mapping.foregroundKey, let color = displayed.foreground { colors[key] = color }
      if let key = mapping.backgroundKey, let color = displayed.background { colors[key] = color }
    }

    var resolvedAppearance = appearance
    if resolvedAppearance == .unspecified {
      resolvedAppearance = inferAppearance(from: colors["editor.background"])
    }
    return EditorThemeImportResult(
      theme: EditorTheme(
        name: name,
        appearance: resolvedAppearance,
        source: source,
        colors: colors,
        rules: rules,
        metadata: ["neovim.groupCount": String(groups.count)]
      ),
      diagnostics: diagnostics
    )
  }

  private static func selectorsForNeovimGroup(_ name: String) -> [EditorThemeSelector] {
    if name.hasPrefix("@lsp.type.") {
      let values = String(name.dropFirst("@lsp.type.".count)).split(separator: ".").map(String.init)
      guard let type = values.first else { return [] }
      let language = values.count > 1 ? values.last : nil
      return [.semantic(type, languageID: language)]
    }
    if name.hasPrefix("@lsp.mod.") {
      let values = String(name.dropFirst("@lsp.mod.".count)).split(separator: ".").map(String.init)
      guard let modifier = values.first else { return [] }
      let language = values.count > 1 ? values.last : nil
      return [.semantic("*", modifiers: [modifier], languageID: language)]
    }
    if name.hasPrefix("@lsp.typemod.") {
      let values = String(name.dropFirst("@lsp.typemod.".count)).split(separator: ".").map(String.init)
      guard values.count >= 2 else { return [] }
      let language = values.count > 2 ? values.last : nil
      return [.semantic(values[0], modifiers: [values[1]], languageID: language)]
    }
    if name.first == "@" {
      let capture = String(name.dropFirst())
      let parts = capture.split(separator: ".").map(String.init)
      if parts.count > 1, let last = parts.last, knownLanguageIDs.contains(last.lowercased()) {
        return [.syntax(parts.dropLast().joined(separator: "."), languageID: last)]
      }
      return [.syntax(capture)]
    }
    return EditorThemeScopeMapping.syntaxCaptures(forVimGroup: name).map { .syntax($0) }
  }

  private struct UIGroupMapping {
    var group: String
    var foregroundKey: String?
    var backgroundKey: String?
  }

  private static let neovimUIMappings: [UIGroupMapping] = [
    .init(group: "Normal", foregroundKey: "editor.foreground", backgroundKey: "editor.background"),
    .init(group: "NormalFloat", foregroundKey: "editorWidget.foreground", backgroundKey: "editorWidget.background"),
    .init(group: "CursorLine", foregroundKey: nil, backgroundKey: "editor.lineHighlightBackground"),
    .init(group: "CursorColumn", foregroundKey: nil, backgroundKey: "editor.lineHighlightBackground"),
    .init(group: "ColorColumn", foregroundKey: nil, backgroundKey: "editor.rulerBackground"),
    .init(group: "Visual", foregroundKey: "editor.selectionForeground", backgroundKey: "editor.selectionBackground"),
    .init(group: "Search", foregroundKey: "editor.findMatchForeground", backgroundKey: "editor.findMatchBackground"),
    .init(group: "IncSearch", foregroundKey: "editor.findMatchHighlightForeground", backgroundKey: "editor.findMatchHighlightBackground"),
    .init(group: "CurSearch", foregroundKey: "editor.findMatchHighlightForeground", backgroundKey: "editor.findMatchHighlightBackground"),
    .init(group: "LineNr", foregroundKey: "editorLineNumber.foreground", backgroundKey: nil),
    .init(group: "CursorLineNr", foregroundKey: "editorLineNumber.activeForeground", backgroundKey: nil),
    .init(group: "SignColumn", foregroundKey: "editorGutter.foreground", backgroundKey: "editorGutter.background"),
    .init(group: "Pmenu", foregroundKey: "editorSuggestWidget.foreground", backgroundKey: "editorSuggestWidget.background"),
    .init(group: "PmenuSel", foregroundKey: "editorSuggestWidget.selectedForeground", backgroundKey: "editorSuggestWidget.selectedBackground"),
    .init(group: "StatusLine", foregroundKey: "statusBar.foreground", backgroundKey: "statusBar.background"),
    .init(group: "StatusLineNC", foregroundKey: "statusBar.noFolderForeground", backgroundKey: "statusBar.noFolderBackground"),
    .init(group: "TabLine", foregroundKey: "tab.inactiveForeground", backgroundKey: "tab.inactiveBackground"),
    .init(group: "TabLineSel", foregroundKey: "tab.activeForeground", backgroundKey: "tab.activeBackground"),
    .init(group: "WinSeparator", foregroundKey: "editorGroup.border", backgroundKey: nil),
    .init(group: "VertSplit", foregroundKey: "editorGroup.border", backgroundKey: nil),
    .init(group: "ErrorMsg", foregroundKey: "errorForeground", backgroundKey: nil),
    .init(group: "WarningMsg", foregroundKey: "editorWarning.foreground", backgroundKey: nil),
    .init(group: "DiagnosticError", foregroundKey: "editorError.foreground", backgroundKey: nil),
    .init(group: "DiagnosticWarn", foregroundKey: "editorWarning.foreground", backgroundKey: nil),
    .init(group: "DiagnosticInfo", foregroundKey: "editorInfo.foreground", backgroundKey: nil),
    .init(group: "DiagnosticHint", foregroundKey: "editorHint.foreground", backgroundKey: nil),
    .init(group: "DiffAdd", foregroundKey: nil, backgroundKey: "diffEditor.insertedTextBackground"),
    .init(group: "DiffDelete", foregroundKey: nil, backgroundKey: "diffEditor.removedTextBackground"),
  ]

  // MARK: Parsing utilities

  private static func jsonObject(from data: Data) throws -> Any {
    do {
      return try JSONSerialization.jsonObject(with: normalizedJSONData(data), options: [.fragmentsAllowed])
    } catch let error as EditorThemeImportError {
      throw error
    } catch {
      throw EditorThemeImportError.invalidJSON(error.localizedDescription)
    }
  }

  /// Removes JSONC comments and trailing commas without changing string contents.
  private static func normalizedJSONData(_ data: Data) throws -> Data {
    guard var text = String(data: data, encoding: .utf8) else {
      throw EditorThemeImportError.invalidUTF8
    }
    if text.first == "\u{FEFF}" { text.removeFirst() }
    let characters = Array(text)
    var withoutComments: [Character] = []
    withoutComments.reserveCapacity(characters.count)
    var index = 0
    var inString = false
    var escaped = false

    while index < characters.count {
      let character = characters[index]
      if inString {
        withoutComments.append(character)
        if escaped { escaped = false }
        else if character == "\\" { escaped = true }
        else if character == "\"" { inString = false }
        index += 1
        continue
      }
      if character == "\"" {
        inString = true
        withoutComments.append(character)
        index += 1
        continue
      }
      if character == "/", index + 1 < characters.count {
        let next = characters[index + 1]
        if next == "/" {
          withoutComments.append(" ")
          withoutComments.append(" ")
          index += 2
          while index < characters.count, characters[index] != "\n", characters[index] != "\r" {
            withoutComments.append(" ")
            index += 1
          }
          continue
        }
        if next == "*" {
          withoutComments.append(" ")
          withoutComments.append(" ")
          index += 2
          while index < characters.count {
            if index + 1 < characters.count, characters[index] == "*", characters[index + 1] == "/" {
              withoutComments.append(" ")
              withoutComments.append(" ")
              index += 2
              break
            }
            let current = characters[index]
            withoutComments.append(current == "\n" || current == "\r" ? current : " ")
            index += 1
          }
          continue
        }
      }
      withoutComments.append(character)
      index += 1
    }

    var normalized: [Character] = []
    normalized.reserveCapacity(withoutComments.count)
    index = 0
    inString = false
    escaped = false
    while index < withoutComments.count {
      let character = withoutComments[index]
      if inString {
        normalized.append(character)
        if escaped { escaped = false }
        else if character == "\\" { escaped = true }
        else if character == "\"" { inString = false }
        index += 1
        continue
      }
      if character == "\"" {
        inString = true
        normalized.append(character)
        index += 1
        continue
      }
      if character == "," {
        var lookahead = index + 1
        while lookahead < withoutComments.count, withoutComments[lookahead].isWhitespace { lookahead += 1 }
        if lookahead < withoutComments.count,
           withoutComments[lookahead] == "}" || withoutComments[lookahead] == "]" {
          index += 1
          continue
        }
      }
      normalized.append(character)
      index += 1
    }
    return Data(String(normalized).utf8)
  }

  private static func parseSemanticSelector(_ raw: String) -> EditorThemeSelector? {
    let languageSplit = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let tokenPart = String(languageSplit[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    let language = languageSplit.count == 2
      ? String(languageSplit[1]).trimmingCharacters(in: .whitespacesAndNewlines)
      : nil
    let components = tokenPart.split(separator: ".").map(String.init)
    guard let tokenType = components.first, !tokenType.isEmpty else { return nil }
    return .semantic(
      tokenType,
      modifiers: Set(components.dropFirst()),
      languageID: language?.isEmpty == false ? language : nil
    )
  }

  private static func parseFontStyles(_ value: String) -> Set<EditorFontStyle> {
    var styles = Set<EditorFontStyle>()
    let tokens = value
      .replacingOccurrences(of: ",", with: " ")
      .split(whereSeparator: { $0.isWhitespace })
      .map { $0.lowercased() }
    for token in tokens {
      switch token {
      case "bold": styles.insert(.bold)
      case "italic": styles.insert(.italic)
      case "underline", "underdouble", "underdotted", "underdashed": styles.insert(.underline)
      case "undercurl": styles.insert(.undercurl)
      case "strikethrough", "strike": styles.insert(.strikethrough)
      case "dim": styles.insert(.dim)
      case "reverse", "standout": styles.insert(.reverse)
      default: break
      }
    }
    return styles
  }

  private static func parseColor(_ value: Any) -> EditorColor? {
    if let string = value as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      if isNone(trimmed) { return nil }
      if let direct = EditorColor(hex: trimmed) ?? namedColor(trimmed) { return direct }
      if trimmed.lowercased().hasPrefix("0x"),
        let integer = UInt32(trimmed.dropFirst(2), radix: 16), integer <= 0xFF_FF_FF
      {
        return EditorColor(rgb: integer)
      }
      return parseCSSColor(trimmed)
    }
    if let number = value as? NSNumber, !(value is Bool) {
      let integer = number.int64Value
      guard integer >= 0, integer <= 0xFF_FF_FF else { return nil }
      return EditorColor(rgb: UInt32(integer))
    }
    return nil
  }

  private static func parseCSSColor(_ value: String) -> EditorColor? {
    let lower = value.lowercased()
    guard let open = lower.firstIndex(of: "("), lower.last == ")" else { return nil }
    let function = lower[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
    let body = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
    let components = body
      .split(separator: ",", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    func rgbChannel(_ component: String) -> UInt8? {
      if component.hasSuffix("%") {
        guard let value = Double(component.dropLast()) else { return nil }
        return UInt8(max(0, min(255, (value / 100 * 255).rounded())))
      }
      guard let value = Double(component) else { return nil }
      return UInt8(max(0, min(255, value.rounded())))
    }

    func alphaChannel(_ component: String) -> UInt8? {
      if component.hasSuffix("%") {
        guard let value = Double(component.dropLast()) else { return nil }
        return UInt8(max(0, min(255, (value / 100 * 255).rounded())))
      }
      guard let value = Double(component) else { return nil }
      return UInt8(max(0, min(255, (value <= 1 ? value * 255 : value).rounded())))
    }

    if function == "rgb" || function == "rgba" {
      guard components.count == (function == "rgb" ? 3 : 4),
        let red = rgbChannel(components[0]),
        let green = rgbChannel(components[1]),
        let blue = rgbChannel(components[2])
      else { return nil }
      let alpha = components.count == 4 ? alphaChannel(components[3]) : 255
      guard let alpha else { return nil }
      return EditorColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    return nil
  }

  private static func parseTerminalColor(_ value: Any) -> EditorColor? {
    if let string = value as? String {
      if let integer = Int(string), (0...255).contains(integer) { return xtermColor(integer) }
      return parseColor(string)
    }
    if let number = value as? NSNumber, !(value is Bool) {
      let integer = number.intValue
      if (0...255).contains(integer) { return xtermColor(integer) }
    }
    return nil
  }

  private static func xtermColor(_ index: Int) -> EditorColor? {
    guard (0...255).contains(index) else { return nil }
    let base: [EditorColor] = [
      .init(rgb: 0x000000), .init(rgb: 0x800000), .init(rgb: 0x008000), .init(rgb: 0x808000),
      .init(rgb: 0x000080), .init(rgb: 0x800080), .init(rgb: 0x008080), .init(rgb: 0xC0C0C0),
      .init(rgb: 0x808080), .init(rgb: 0xFF0000), .init(rgb: 0x00FF00), .init(rgb: 0xFFFF00),
      .init(rgb: 0x0000FF), .init(rgb: 0xFF00FF), .init(rgb: 0x00FFFF), .init(rgb: 0xFFFFFF),
    ]
    if index < 16 { return base[index] }
    if index < 232 {
      let offset = index - 16
      let red = offset / 36
      let green = (offset % 36) / 6
      let blue = offset % 6
      let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
      return EditorColor(red: levels[red], green: levels[green], blue: levels[blue])
    }
    let level = UInt8(8 + (index - 232) * 10)
    return EditorColor(red: level, green: level, blue: level)
  }

  private static func namedColor(_ value: String) -> EditorColor? {
    let colors: [String: UInt32] = [
      "black": 0x000000, "darkblue": 0x00008B, "darkgreen": 0x006400,
      "darkcyan": 0x008B8B, "darkred": 0x8B0000, "darkmagenta": 0x8B008B,
      "brown": 0xA52A2A, "darkyellow": 0x808000, "gray": 0x808080,
      "grey": 0x808080, "lightgray": 0xD3D3D3, "lightgrey": 0xD3D3D3,
      "darkgray": 0xA9A9A9, "darkgrey": 0xA9A9A9, "blue": 0x0000FF,
      "lightblue": 0xADD8E6, "green": 0x00FF00, "lightgreen": 0x90EE90,
      "cyan": 0x00FFFF, "lightcyan": 0xE0FFFF, "red": 0xFF0000,
      "lightred": 0xFF7F7F, "magenta": 0xFF00FF, "lightmagenta": 0xFF77FF,
      "yellow": 0xFFFF00, "lightyellow": 0xFFFFE0, "white": 0xFFFFFF,
      "orange": 0xFFA500, "purple": 0x800080, "violet": 0xEE82EE,
    ]
    guard let rgb = colors[value.lowercased()] else { return nil }
    return EditorColor(rgb: rgb)
  }

  private static func parseLuaPalettes(_ text: String) -> [String: [String: String]] {
    func entries(in body: String) -> [String: String] {
      let entryPattern = #"(?:\[\s*[\"']([^\"']+)[\"']\s*\]|([A-Za-z_][A-Za-z0-9_]*))\s*=\s*[\"'](#[0-9A-Fa-f]{3,8}|[A-Za-z]+|rgba?\([^\"']+\))[\"']"#
      var values: [String: String] = [:]
      for entry in regexMatches(entryPattern, in: body) where entry.count >= 4 {
        let key = entry[1].isEmpty ? entry[2] : entry[1]
        values[key] = entry[3]
      }
      return values
    }

    let tablePattern = #"(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{([^{}]*)\}"#
    var palettes: [String: [String: String]] = [:]
    for match in regexMatches(tablePattern, in: text, options: [.dotMatchesLineSeparators]) where match.count >= 3 {
      let values = entries(in: match[2])
      if !values.isEmpty { palettes[match[1]] = values }
    }

    var locals: [String: String] = [:]
    let localPattern = #"(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*[\"'](#[0-9A-Fa-f]{3,8}|[A-Za-z]+|rgba?\([^\"']+\))[\"']"#
    for match in regexMatches(localPattern, in: text) where match.count >= 3 {
      locals[match[1]] = match[2]
    }
    if !locals.isEmpty { palettes["__locals"] = locals }

    var returned: [String: String] = [:]
    let returnPattern = #"return\s*\{([^{}]*)\}"#
    for match in regexMatches(returnPattern, in: text, options: [.dotMatchesLineSeparators]) where match.count >= 2 {
      returned.merge(entries(in: match[1])) { _, new in new }
    }
    if !returned.isEmpty {
      palettes["__return"] = returned
      let requirePattern = #"(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*require\s*\("#
      for match in regexMatches(requirePattern, in: text) where match.count >= 2 {
        if palettes[match[1]] == nil { palettes[match[1]] = returned }
      }
      for alias in ["colors", "colours", "palette", "c"] where palettes[alias] == nil {
        palettes[alias] = returned
      }
    }
    return palettes
  }

  private static func parseLuaTable(
    _ body: String,
    palettes: [String: [String: String]] = [:]
  ) -> [String: Any] {
    let pattern = #"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:[\"']([^\"']*)[\"']|(true|false)|(0x[0-9A-Fa-f]+|-?\d+)|([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*))"#
    var result: [String: Any] = [:]
    for match in regexMatches(pattern, in: body, options: [.caseInsensitive]) where match.count >= 6 {
      let key = match[1]
      if !match[2].isEmpty { result[key] = match[2] }
      else if !match[3].isEmpty { result[key] = match[3].lowercased() == "true" }
      else if match[4].lowercased().hasPrefix("0x"), let integer = Int(match[4].dropFirst(2), radix: 16) {
        result[key] = integer
      } else if let integer = Int(match[4]) { result[key] = integer }
      else if !match[5].isEmpty {
        let parts = match[5].split(separator: ".", maxSplits: 1).map(String.init)
        if parts.count == 2, let value = palettes[parts[0]]?[parts[1]] {
          result[key] = value
        }
      }
    }

    let barePattern = #"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:,|$)"#
    for match in regexMatches(barePattern, in: body) where match.count >= 3 {
      guard result[match[1]] == nil else { continue }
      if let value = palettes["__locals"]?[match[2]] ?? palettes["__return"]?[match[2]] {
        result[match[1]] = value
      }
    }
    return result
  }

  private static func regexMatches(
    _ pattern: String,
    in text: String,
    options: NSRegularExpression.Options = []
  ) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).map { match in
      (0..<match.numberOfRanges).map { index in
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
      }
    }
  }

  private static func stripVimComment(_ line: String) -> String {
    var inSingle = false
    var inDouble = false
    var escaped = false
    let characters = Array(line)
    for index in characters.indices {
      let character = characters[index]
      if escaped { escaped = false; continue }
      if character == "\\" { escaped = true; continue }
      if character == "'", !inDouble { inSingle.toggle(); continue }
      if character == "\"", !inSingle {
        if !inDouble {
          let prefix = characters[..<index]
          if prefix.allSatisfy({ $0.isWhitespace }) || (prefix.last?.isWhitespace == true) {
            return String(prefix)
          }
        }
        inDouble.toggle()
      }
    }
    return line
  }

  private static func firstValue(in object: [String: Any], keys: [String]) -> Any? {
    for key in keys where object[key] != nil { return object[key] }
    return nil
  }

  private static func parseBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
      switch value.lowercased() {
      case "true", "yes", "on", "1": return true
      case "false", "no", "off", "0", "none": return false
      default: return nil
      }
    }
    return nil
  }

  private static func isNone(_ value: Any) -> Bool {
    guard let string = value as? String else { return false }
    return string.caseInsensitiveCompare("none") == .orderedSame
      || string.caseInsensitiveCompare("nil") == .orderedSame
  }

  private static func nonEmptyString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func parseAppearance(_ value: Any?) -> EditorThemeAppearance {
    guard let text = value as? String else { return .unspecified }
    switch text.lowercased() {
    case "dark": return .dark
    case "light": return .light
    case "hc", "highcontrast", "high-contrast", "highcontrastdark": return .highContrastDark
    case "hc-light", "highcontrastlight", "high-contrast-light": return .highContrastLight
    default: return .unspecified
    }
  }

  private static func inferAppearance(from background: EditorColor?) -> EditorThemeAppearance {
    guard let background else { return .unspecified }
    func channel(_ value: UInt8) -> Double {
      let normalized = Double(value) / 255
      return normalized <= 0.04045
        ? normalized / 12.92
        : pow((normalized + 0.055) / 1.055, 2.4)
    }
    let luminance = 0.2126 * channel(background.red)
      + 0.7152 * channel(background.green)
      + 0.0722 * channel(background.blue)
    return luminance < 0.35 ? .dark : .light
  }

  private static func displayStyle(_ style: EditorTextStyle) -> EditorTextStyle {
    guard style.fontStyles?.contains(.reverse) == true else { return style }
    var result = style
    swap(&result.foreground, &result.background)
    return result
  }

  private static func resolve(_ path: String, relativeTo sourceURL: URL) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
    return sourceURL.deletingLastPathComponent().appendingPathComponent(expanded)
  }

  private static func appendUnique(_ selector: EditorThemeSelector, to selectors: inout [EditorThemeSelector]) {
    if !selectors.contains(selector) { selectors.append(selector) }
  }

  private static func looksLikeNeovimGroupObject(_ object: [String: Any]) -> Bool {
    var matching = 0
    for value in object.values {
      guard let group = value as? [String: Any] else { continue }
      if group.keys.contains(where: {
        ["fg", "bg", "sp", "foreground", "background", "guifg", "guibg", "bold", "italic", "link"].contains($0)
      }) {
        matching += 1
        if matching >= 1 { return true }
      }
    }
    return false
  }

  private static func warning(_ message: String, source sourceURL: URL?) -> EditorThemeImportDiagnostic {
    EditorThemeImportDiagnostic(
      severity: .warning,
      message: message,
      source: sourceURL?.path
    )
  }

  private static let knownLanguageIDs: Set<String> = [
    "bash", "c", "cpp", "css", "dart", "dockerfile", "elixir", "go", "gomod",
    "html", "java", "javascript", "javascriptreact", "json", "jsonc", "kotlin",
    "lua", "markdown", "objc", "php", "python", "r", "ruby", "rust", "scss",
    "sh", "sql", "swift", "toml", "tsx", "typescript", "typescriptreact", "vim",
    "vue", "xml", "yaml", "zig"
  ]
}

public extension EditorThemeImportDiagnostic {
  static func warning(_ message: String, source sourceURL: URL? = nil) -> Self {
    .init(severity: .warning, message: message, source: sourceURL?.path)
  }

  static func information(_ message: String, source sourceURL: URL? = nil) -> Self {
    .init(severity: .information, message: message, source: sourceURL?.path)
  }
}

public extension EditorTheme {
  init(
    data: Data,
    format: EditorThemeFormat = .automatic,
    sourceURL: URL? = nil
  ) throws {
    self = try EditorThemeImporter.decode(data, format: format, sourceURL: sourceURL)
  }

  init(
    text: String,
    format: EditorThemeFormat = .automatic,
    sourceURL: URL? = nil
  ) throws {
    self = try EditorThemeImporter.decode(text, format: format, sourceURL: sourceURL)
  }

  static func load(
    from url: URL,
    format: EditorThemeFormat = .automatic
  ) throws -> EditorTheme {
    try EditorThemeImporter.load(from: url, format: format).theme
  }
}
