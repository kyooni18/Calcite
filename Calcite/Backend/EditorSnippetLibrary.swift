import EditorServices
import Foundation

struct EditorSnippetLibrary: Sendable {
  private var snippets: [EditorUserSnippet]

  init(workspaceURL: URL, profile: EditorSnippetProfile) {
    var values = profile.custom
    if profile.includeBuiltins {
      values.append(contentsOf: Self.builtinSnippets)
    }
    if profile.includeProjectFiles {
      values.append(contentsOf: Self.loadCalciteSnippets(workspaceURL: workspaceURL))
      values.append(contentsOf: Self.loadVSCodeSnippets(workspaceURL: workspaceURL))
    }
    snippets = Self.deduplicated(values)
  }

  func completions(languageID: String, prefix: String) -> [Completion] {
    let language = Self.normalizedLanguage(languageID)
    return
      snippets
      .filter {
        let scope = Self.normalizedLanguage($0.languageID)
        return scope.isEmpty || scope == "*" || scope == language
      }
      .compactMap { snippet in
        guard snippet.trigger != prefix,
          Self.matchScore(snippet.trigger, prefix: prefix) != nil
        else { return nil }
        return Completion(
          label: snippet.trigger,
          kind: .snippet,
          detail: snippet.summary,
          sortText: "00000-\(snippet.trigger)",
          filterText: snippet.trigger,
          insertText: snippet.body,
          insertTextFormat: .snippet,
          serviceIdentifier: "calcite-snippets"
        )
      }
      .sorted {
        let lhs = Self.matchScore($0.label, prefix: prefix) ?? 0
        let rhs = Self.matchScore($1.label, prefix: prefix) ?? 0
        if lhs != rhs { return lhs > rhs }
        return $0.label.localizedStandardCompare($1.label) == .orderedAscending
      }
  }

  private static let builtinSnippets: [EditorUserSnippet] = [
    .init(
      languageID: "swift", trigger: "func",
      body: "func ${1:name}(${2:parameters})${3: -> ReturnType} {\n\t${0}\n}",
      summary: "Function declaration"),
    .init(
      languageID: "swift", trigger: "struct", body: "struct ${1:Name} {\n\t${0}\n}",
      summary: "Structure declaration"),
    .init(
      languageID: "swift", trigger: "class", body: "final class ${1:Name} {\n\t${0}\n}",
      summary: "Final class declaration"),
    .init(
      languageID: "swift", trigger: "guard",
      body: "guard ${1:condition} else {\n\t${2:return}\n}\n${0}", summary: "Guard statement"),
    .init(
      languageID: "swift", trigger: "do", body: "do {\n\t${1}\n} catch {\n\t${0}\n}",
      summary: "Do/catch block"),
    .init(
      languageID: "rust", trigger: "fn",
      body: "fn ${1:name}(${2:arguments})${3: -> ReturnType} {\n\t${0}\n}",
      summary: "Function declaration"),
    .init(
      languageID: "rust", trigger: "impl", body: "impl ${1:Type} {\n\t${0}\n}",
      summary: "Implementation block"),
    .init(
      languageID: "rust", trigger: "match",
      body: "match ${1:value} {\n\t${2:pattern} => ${3:expression},\n\t${0}\n}",
      summary: "Match expression"),
    .init(
      languageID: "rust", trigger: "test", body: "#[test]\nfn ${1:test_name}() {\n\t${0}\n}",
      summary: "Rust test"),
    .init(
      languageID: "go", trigger: "func",
      body: "func ${1:name}(${2:args}) ${3:returnType} {\n\t${0}\n}",
      summary: "Function declaration"),
    .init(
      languageID: "go", trigger: "iferr", body: "if err != nil {\n\t${1:return err}\n}\n${0}",
      summary: "Error check"),
    .init(
      languageID: "python", trigger: "def", body: "def ${1:name}(${2:args}):\n\t${0}",
      summary: "Function declaration"),
    .init(
      languageID: "python", trigger: "class",
      body: "class ${1:Name}:\n\tdef __init__(self, ${2:args}):\n\t\t${0}",
      summary: "Class declaration"),
    .init(
      languageID: "javascript", trigger: "func", body: "function ${1:name}(${2:args}) {\n\t${0}\n}",
      summary: "Function declaration"),
    .init(
      languageID: "typescript", trigger: "func",
      body: "function ${1:name}(${2:args}): ${3:void} {\n\t${0}\n}",
      summary: "Typed function declaration"),
    .init(
      languageID: "typescript", trigger: "interface", body: "interface ${1:Name} {\n\t${0}\n}",
      summary: "Interface declaration"),
    .init(
      languageID: "kotlin", trigger: "fun",
      body: "fun ${1:name}(${2:args})${3: ReturnType} {\n\t${0}\n}", summary: "Function declaration"
    ),
    .init(
      languageID: "java", trigger: "method",
      body: "${1:public} ${2:void} ${3:name}(${4:args}) {\n\t${0}\n}", summary: "Method declaration"
    ),
    .init(
      languageID: "html", trigger: "html5",
      body:
        "<!doctype html>\n<html lang=\"${1:en}\">\n<head>\n\t<meta charset=\"utf-8\">\n\t<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\t<title>${2:Document}</title>\n</head>\n<body>\n\t${0}\n</body>\n</html>",
      summary: "HTML document"),
    .init(
      languageID: "css", trigger: "media", body: "@media (${1:min-width}: ${2:768px}) {\n\t${0}\n}",
      summary: "Media query"),
    .init(
      languageID: "zig", trigger: "fn", body: "fn ${1:name}(${2:args}) ${3:void} {\n\t${0}\n}",
      summary: "Function declaration"),
    .init(
      languageID: "shell", trigger: "script",
      body: "#!/usr/bin/env ${1:bash}\nset -euo pipefail\n\n${0}", summary: "Strict shell script"),
  ]

  private static func loadCalciteSnippets(workspaceURL: URL) -> [EditorUserSnippet] {
    let url = workspaceURL.appendingPathComponent(".calcite/snippets.json")
    guard let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([EditorUserSnippet].self, from: data)) ?? []
  }

  private static func loadVSCodeSnippets(workspaceURL: URL) -> [EditorUserSnippet] {
    let directory = workspaceURL.appendingPathComponent(".vscode", isDirectory: true)
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    return
      files
      .filter { $0.pathExtension == "json" || $0.pathExtension == "code-snippets" }
      .flatMap { parseVSCodeSnippetFile($0) }
  }

  private static func parseVSCodeSnippetFile(_ url: URL) -> [EditorUserSnippet] {
    guard let data = try? Data(contentsOf: url),
      let source = String(data: data, encoding: .utf8),
      let sanitized = sanitizeJSONC(source).data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
    else { return [] }

    let fallbackLanguage =
      url.pathExtension == "json"
      ? normalizedLanguage(url.deletingPathExtension().lastPathComponent)
      : "*"
    var values: [EditorUserSnippet] = []
    for (name, rawValue) in object {
      guard let value = rawValue as? [String: Any] else { continue }
      let prefixes: [String]
      if let prefix = value["prefix"] as? String {
        prefixes = [prefix]
      } else {
        prefixes = value["prefix"] as? [String] ?? []
      }
      let body: String
      if let text = value["body"] as? String {
        body = text
      } else if let lines = value["body"] as? [String] {
        body = lines.joined(separator: "\n")
      } else {
        continue
      }
      let description = value["description"] as? String ?? name
      let scopes =
        (value["scope"] as? String)?
        .split(separator: ",")
        .map { normalizedLanguage(String($0).trimmingCharacters(in: .whitespaces)) }
        ?? [fallbackLanguage]
      for scope in scopes {
        for prefix in prefixes where !prefix.isEmpty {
          values.append(
            EditorUserSnippet(
              languageID: scope,
              trigger: prefix,
              body: body,
              summary: "Project snippet • \(description)"
            ))
        }
      }
    }
    return values
  }

  private static func sanitizeJSONC(_ source: String) -> String {
    let characters = Array(source)
    var output: [Character] = []
    output.reserveCapacity(characters.count)
    var index = 0
    var inString = false
    var escaped = false
    var lineComment = false
    var blockComment = false

    while index < characters.count {
      let character = characters[index]
      let next = index + 1 < characters.count ? characters[index + 1] : nil

      if lineComment {
        if character == "\n" || character == "\r" {
          lineComment = false
          output.append(character)
        }
        index += 1
        continue
      }

      if blockComment {
        if character == "*", next == "/" {
          blockComment = false
          index += 2
        } else {
          if character == "\n" || character == "\r" { output.append(character) }
          index += 1
        }
        continue
      }

      if inString {
        output.append(character)
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
        index += 1
        continue
      }

      if character == "\"" {
        inString = true
        output.append(character)
        index += 1
      } else if character == "/", next == "/" {
        lineComment = true
        index += 2
      } else if character == "/", next == "*" {
        blockComment = true
        index += 2
      } else {
        output.append(character)
        index += 1
      }
    }

    return removingTrailingCommas(String(output))
  }

  private static func removingTrailingCommas(_ source: String) -> String {
    let characters = Array(source)
    var output: [Character] = []
    output.reserveCapacity(characters.count)
    var index = 0
    var inString = false
    var escaped = false

    while index < characters.count {
      let character = characters[index]
      if inString {
        output.append(character)
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
        index += 1
        continue
      }
      if character == "\"" {
        inString = true
        output.append(character)
        index += 1
        continue
      }
      if character == "," {
        var lookahead = index + 1
        while lookahead < characters.count, characters[lookahead].isWhitespace {
          lookahead += 1
        }
        if lookahead < characters.count,
          characters[lookahead] == "}" || characters[lookahead] == "]"
        {
          index += 1
          continue
        }
      }
      output.append(character)
      index += 1
    }
    return String(output)
  }

  private static func deduplicated(_ values: [EditorUserSnippet]) -> [EditorUserSnippet] {
    var result: [String: EditorUserSnippet] = [:]
    for value in values {
      let key = "\(normalizedLanguage(value.languageID))|\(value.trigger.lowercased())"
      result[key] = value
    }
    return result.values.sorted {
      $0.trigger.localizedStandardCompare($1.trigger) == .orderedAscending
    }
  }

  private static func normalizedLanguage(_ value: String) -> String {
    switch value.lowercased() {
    case "js", "javascriptreact": return "javascript"
    case "ts", "typescriptreact": return "typescript"
    case "rs": return "rust"
    case "py": return "python"
    case "sh", "bash", "zsh", "shellscript": return "shell"
    default: return value.lowercased()
    }
  }

  private static func matchScore(_ candidate: String, prefix: String) -> Int? {
    guard !prefix.isEmpty else { return 1 }
    if candidate.hasPrefix(prefix) { return 400 - candidate.count }
    if candidate.lowercased().hasPrefix(prefix.lowercased()) { return 330 - candidate.count }
    var index = prefix.startIndex
    for character in candidate where index < prefix.endIndex {
      if character.lowercased() == prefix[index].lowercased() {
        index = prefix.index(after: index)
      }
    }
    return index == prefix.endIndex ? 120 - candidate.count : nil
  }
}
