import Foundation

enum CompletionSourceFileRole: String, Sendable {
  case header
  case implementation
  case interface
  case test
  case generated
  case other

  static func classify(url: URL, languageID: String) -> Self {
    let name = url.lastPathComponent.lowercased()
    let ext = url.pathExtension.lowercased()
    if name.contains("generated") || name.hasSuffix(".g.swift") || name.hasSuffix(".designer.cs") {
      return .generated
    }
    if name.contains("test") || name.contains("spec")
      || url.pathComponents.contains(where: {
        ["tests", "test", "specs", "spec"].contains($0.lowercased())
      })
    {
      return .test
    }
    if ["h", "hh", "hpp", "hxx", "inc", "inl", "ipp", "tpp"].contains(ext) {
      return .header
    }
    if ["swiftinterface", "swiftmodule", "modulemap", "d.ts", "pyi"].contains(ext)
      || name.hasSuffix(".d.ts")
    {
      return .interface
    }
    if ["c", "cc", "cpp", "cxx", "m", "mm", "swift", "rs", "go", "java", "kt", "kts", "cs", "zig"]
      .contains(ext)
    {
      return .implementation
    }
    return .other
  }
}

struct CompletionTypeScope: Sendable {
  var name: String
  var range: NSRange
  var isExtensionLike: Bool
  var inheritedTypes: Set<String>
}

struct CompletionFunctionScope: Sendable {
  var name: String
  var range: NSRange
  var signature: String
  var parameters: Set<String>
  var parameterSpellings: [String]
  var parameterTypes: [String: String]
  var isStatic: Bool
}

struct CompletionLexicalContext: Sendable {
  var currentType: String?
  var baseTypes: Set<String>
  var currentFunction: String?
  var currentFunctionReturnType: String?
  var isStaticContext: Bool
  var localNames: Set<String>
  var parameterNames: Set<String>
  var parameterSpellings: [String]
  var variableTypes: [String: String]
  var typeScopes: [CompletionTypeScope]
}

enum CompletionStructuralAnalysis {
  static func lexicalContext(in text: String, languageID: String, caret: Int)
    -> CompletionLexicalContext
  {
    let language = normalizedLanguage(languageID)
    let masked = CompletionStructuralCodeMask.maskedCode(text, languageID: language)
    let source = masked as NSString
    let safeCaret = min(max(0, caret), source.length)
    let typeScopes = typeScopes(inMaskedText: masked, languageID: language)
    let currentTypeScope =
      typeScopes
      .filter { NSLocationInRange(safeCaret, $0.range) || safeCaret == NSMaxRange($0.range) }
      .min { $0.range.length < $1.range.length }
    let currentType = currentTypeScope?.name
    let functionScopes = functionScopes(inMaskedText: masked, languageID: language)
    let currentFunctionScope =
      functionScopes
      .filter { NSLocationInRange(safeCaret, $0.range) || safeCaret == NSMaxRange($0.range) }
      .min { $0.range.length < $1.range.length }

    let visibleStart = currentFunctionScope?.range.location ?? 0
    let visibleRange = NSRange(location: visibleStart, length: max(0, safeCaret - visibleStart))
    let visibleText = source.substring(with: visibleRange)
    let locals = localNames(in: visibleText, languageID: language)
    var variableTypes = variableTypes(in: source.substring(to: safeCaret), languageID: language)
    for (name, type) in currentFunctionScope?.parameterTypes ?? [:] {
      variableTypes[name] = type
    }

    return CompletionLexicalContext(
      currentType: currentType,
      baseTypes: currentTypeScope?.inheritedTypes ?? [],
      currentFunction: currentFunctionScope?.name,
      currentFunctionReturnType: returnType(
        in: currentFunctionScope?.signature,
        functionName: currentFunctionScope?.name,
        languageID: language
      ),
      isStaticContext: currentFunctionScope?.isStatic ?? false,
      localNames: locals,
      parameterNames: currentFunctionScope?.parameters ?? [],
      parameterSpellings: currentFunctionScope?.parameterSpellings ?? [],
      variableTypes: variableTypes,
      typeScopes: typeScopes
    )
  }

  static func typeScopes(in text: String, languageID: String) -> [CompletionTypeScope] {
    let language = normalizedLanguage(languageID)
    let masked = CompletionStructuralCodeMask.maskedCode(text, languageID: language)
    return typeScopes(inMaskedText: masked, languageID: language)
  }

  static func enclosingType(
    at location: Int,
    in scopes: [CompletionTypeScope]
  ) -> CompletionTypeScope? {
    scopes.filter { NSLocationInRange(location, $0.range) }
      .min { $0.range.length < $1.range.length }
  }

  static func normalizedLanguage(_ languageID: String) -> String {
    switch languageID.lowercased() {
    case "typescriptreact": return "typescript"
    case "javascriptreact": return "javascript"
    case "shellscript", "bash", "zsh": return "shell"
    case "c++": return "cpp"
    case "objective-c": return "c"
    case "objective-cpp": return "cpp"
    default: return languageID.lowercased()
    }
  }

  private static func typeScopes(inMaskedText text: String, languageID: String)
    -> [CompletionTypeScope]
  {
    if languageID == "python" { return pythonTypeScopes(in: text) }
    let patterns: [(String, Bool)]
    switch languageID {
    case "swift":
      patterns = [
        (#"\b(?:actor|class|enum|protocol|struct)\s+([\p{L}_][\p{L}\p{N}_]*)"#, false),
        (#"\bextension\s+([\p{L}_][\p{L}\p{N}_]*)"#, true),
      ]
    case "rust":
      patterns = [
        (#"\b(?:enum|struct|trait)\s+([\p{L}_][\p{L}\p{N}_]*)"#, false),
        (
          #"\bimpl(?:\s*<[^>{}]*>)?\s+(?:(?:[\p{L}_][\p{L}\p{N}_]*(?:<[^>{}]*>)?)\s+for\s+)?([\p{L}_][\p{L}\p{N}_]*)"#,
          true
        ),
      ]
    case "go":
      patterns = [(#"\btype\s+([\p{L}_][\p{L}\p{N}_]*)\s+(?:struct|interface)"#, false)]
    case "kotlin":
      patterns = [(#"\b(?:class|enum\s+class|interface|object)\s+([\p{L}_][\p{L}\p{N}_]*)"#, false)]
    case "javascript", "typescript":
      patterns = [(#"\b(?:class|interface|namespace)\s+([\p{L}_$][\p{L}\p{N}_$]*)"#, false)]
    default:
      patterns = [
        (
          #"\b(?:class|enum|interface|namespace|record|struct|trait|union)\s+([\p{L}_][\p{L}\p{N}_]*)"#,
          false
        )
      ]
    }

    let source = text as NSString
    var scopes: [CompletionTypeScope] = []
    for (pattern, extensionLike) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound,
          let open = firstOpeningBrace(
            in: source, after: NSMaxRange(match.range), searchLimit: 480),
          let close = matchingBrace(in: source, openingAt: open)
        else { continue }
        let declarationHeader = source.substring(
          with: NSRange(location: match.range.location, length: open - match.range.location)
        )
        scopes.append(
          CompletionTypeScope(
            name: source.substring(with: match.range(at: 1)),
            range: NSRange(
              location: match.range.location, length: close - match.range.location + 1),
            isExtensionLike: extensionLike,
            inheritedTypes: inheritedTypeNames(in: declarationHeader, languageID: languageID)
          )
        )
      }
    }
    return scopes
  }

  private static func inheritedTypeNames(
    in declaration: String,
    languageID: String
  ) -> Set<String> {
    let patterns: [String]
    switch languageID {
    case "java", "javascript", "typescript", "csharp":
      patterns = [
        #"\bextends\s+([^\{]+?)(?=\bimplements\b|$)"#,
        #"\bimplements\s+([^\{]+)$"#,
        #":\s*([^\{]+)$"#,
      ]
    case "kotlin":
      patterns = [#":\s*([^\{]+)$"#]
    case "rust":
      patterns = [#"\bimpl(?:\s*<[^>]*>)?\s+([^\{]+?)\s+for\s+"#]
    default:
      patterns = [#":\s*([^\{]+)$"#]
    }
    let source = declaration as NSString
    var result = Set<String>()
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      else { continue }
      for match in regex.matches(
        in: declaration,
        range: NSRange(location: 0, length: source.length)
      ) {
        guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else {
          continue
        }
        let clause = source.substring(with: match.range(at: 1))
        for raw in clause.split(separator: ",") {
          let identifiers = raw.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map(String.init)
            .filter { !inheritanceNoise.contains($0.lowercased()) }
          if let name = identifiers.last { result.insert(name) }
        }
      }
    }
    return result
  }

  private static func functionScopes(inMaskedText text: String, languageID: String)
    -> [CompletionFunctionScope]
  {
    if languageID == "python" { return pythonFunctionScopes(in: text) }
    let patterns: [(String, Int, Int)]
    switch languageID {
    case "swift":
      patterns = [
        (#"\b(?:(?:class|static)\s+)?func\s+([\p{L}_][\p{L}\p{N}_]*)\s*\(([^)]*)\)[^{;]*\{"#, 1, 2)
      ]
    case "rust":
      patterns = [
        (
          #"\b(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+([\p{L}_][\p{L}\p{N}_]*)\s*\(([^)]*)\)[^{;]*\{"#,
          1, 2
        )
      ]
    case "go":
      patterns = [
        (#"\bfunc\s+(?:\([^)]*\)\s*)?([\p{L}_][\p{L}\p{N}_]*)\s*\(([^)]*)\)[^{;]*\{"#, 1, 2)
      ]
    case "kotlin":
      patterns = [(#"\bfun\s+([\p{L}_][\p{L}\p{N}_]*)\s*\(([^)]*)\)[^{;=]*\{"#, 1, 2)]
    case "javascript", "typescript":
      patterns = [
        (#"\b(?:async\s+)?function\s+([\p{L}_$][\p{L}\p{N}_$]*)\s*\(([^)]*)\)[^{;]*\{"#, 1, 2),
        (#"\b(?:async\s+)?([\p{L}_$][\p{L}\p{N}_$]*)\s*\(([^)]*)\)[^{;=]*\{"#, 1, 2),
      ]
    default:
      patterns = [
        (
          #"\b(?:[\p{L}_][\p{L}\p{N}_:<>,*&?\[\]\s]+\s+)?([~\p{L}_][\p{L}\p{N}_]*)\s*\(([^;{}()]*)\)\s*(?:const\s*)?(?:noexcept\s*)?\{"#,
          1, 2
        )
      ]
    }

    let source = text as NSString
    var scopes: [CompletionFunctionScope] = []
    for (pattern, nameGroup, parameterGroup) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        guard match.numberOfRanges > max(nameGroup, parameterGroup),
          match.range(at: nameGroup).location != NSNotFound,
          !isControlWord(source.substring(with: match.range(at: nameGroup))),
          let open = firstOpeningBrace(
            in: source, after: match.range.location, searchLimit: match.range.length + 8),
          let close = matchingBrace(in: source, openingAt: open)
        else { continue }
        let signature = source.substring(
          with: NSRange(location: match.range.location, length: open - match.range.location))
        let capturedParameterRange = match.range(at: parameterGroup)
        let parameterOpening = max(0, capturedParameterRange.location - 1)
        let parameterText: String
        if source.character(at: parameterOpening) == 40,
          let parameterClosing = matchingParenthesis(in: source, openingAt: parameterOpening)
        {
          parameterText = source.substring(
            with: NSRange(
              location: parameterOpening + 1,
              length: parameterClosing - parameterOpening - 1
            )
          )
        } else {
          parameterText = source.substring(with: capturedParameterRange)
        }
        let metadata = parameterMetadata(parameterText, languageID: languageID)
        let parameters = Set(metadata.map { $0.name.lowercased() })
        var parameterTypes: [String: String] = [:]
        for parameter in metadata {
          if let type = parameter.type { parameterTypes[parameter.name.lowercased()] = type }
        }
        scopes.append(
          CompletionFunctionScope(
            name: source.substring(with: match.range(at: nameGroup)),
            range: NSRange(
              location: match.range.location, length: close - match.range.location + 1),
            signature: signature,
            parameters: parameters,
            parameterSpellings: metadata.map(\.name),
            parameterTypes: parameterTypes,
            isStatic: isStaticSignature(signature, languageID: languageID, parameters: parameters)
          )
        )
      }
    }
    return scopes
  }

  private static func pythonTypeScopes(in text: String) -> [CompletionTypeScope] {
    indentationScopes(
      in: text, pattern: #"(?m)^(\s*)class\s+([\p{L}_][\p{L}\p{N}_]*)[^\n]*:"#, nameGroup: 2
    )
    .map {
      CompletionTypeScope(
        name: $0.name,
        range: $0.range,
        isExtensionLike: false,
        inheritedTypes: []
      )
    }
  }

  private static func pythonFunctionScopes(in text: String) -> [CompletionFunctionScope] {
    let scopes = indentationScopes(
      in: text,
      pattern: #"(?m)^(\s*)(?:async\s+)?def\s+([\p{L}_][\p{L}\p{N}_]*)\s*\(([^)]*)\)[^\n]*:"#,
      nameGroup: 2,
      parameterGroup: 3
    )
    return scopes.map {
      let metadata = parameterMetadata($0.parameters ?? "", languageID: "python")
      let parameters = Set(metadata.map { $0.name.lowercased() })
      var parameterTypes: [String: String] = [:]
      for parameter in metadata {
        if let type = parameter.type { parameterTypes[parameter.name.lowercased()] = type }
      }
      return CompletionFunctionScope(
        name: $0.name,
        range: $0.range,
        signature: $0.signature,
        parameters: parameters,
        parameterSpellings: metadata.map(\.name),
        parameterTypes: parameterTypes,
        isStatic: $0.signature.contains("@staticmethod") || $0.signature.contains("@classmethod")
      )
    }
  }

  private struct IndentationScope {
    var name: String
    var range: NSRange
    var signature: String
    var parameters: String?
  }

  private static func indentationScopes(
    in text: String,
    pattern: String,
    nameGroup: Int,
    parameterGroup: Int? = nil
  ) -> [IndentationScope] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let source = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
    return matches.compactMap { match in
      guard match.numberOfRanges > nameGroup, match.range(at: nameGroup).location != NSNotFound
      else {
        return nil
      }
      let indent = match.range(at: 1).length
      var end = source.length
      let declarationLine = source.lineRange(for: match.range)
      var lineStart = NSMaxRange(declarationLine)
      while lineStart < source.length {
        let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
        let line = source.substring(with: lineRange)
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          let leading = line.prefix { $0 == " " || $0 == "\t" }.count
          if leading <= indent {
            end = lineRange.location
            break
          }
        }
        lineStart = NSMaxRange(lineRange)
      }
      let parameters: String?
      if let parameterGroup, match.numberOfRanges > parameterGroup,
        match.range(at: parameterGroup).location != NSNotFound
      {
        parameters = source.substring(with: match.range(at: parameterGroup))
      } else {
        parameters = nil
      }
      return IndentationScope(
        name: source.substring(with: match.range(at: nameGroup)),
        range: NSRange(location: match.range.location, length: max(1, end - match.range.location)),
        signature: source.substring(with: match.range),
        parameters: parameters
      )
    }
  }

  private static func localNames(in text: String, languageID: String) -> Set<String> {
    let patterns: [String]
    switch languageID {
    case "swift": patterns = [#"\b(?:let|var)\s+([\p{L}_][\p{L}\p{N}_]*)"#]
    case "rust": patterns = [#"\blet\s+(?:mut\s+)?([\p{L}_][\p{L}\p{N}_]*)"#]
    case "kotlin": patterns = [#"\b(?:val|var)\s+([\p{L}_][\p{L}\p{N}_]*)"#]
    case "javascript", "typescript":
      patterns = [#"\b(?:const|let|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)"#]
    case "python": patterns = [#"(?m)^\s*([\p{L}_][\p{L}\p{N}_]*)\s*(?::[^=\n]+)?="#]
    case "go":
      patterns = [
        #"\bvar\s+([\p{L}_][\p{L}\p{N}_]*)"#,
        #"\b([\p{L}_][\p{L}\p{N}_]*)\s*:="#,
      ]
    case "lua": patterns = [#"\blocal\s+([\p{L}_][\p{L}\p{N}_]*)"#]
    default:
      patterns = [
        #"(?:^|[;{}])\s*(?:const\s+|static\s+|final\s+|volatile\s+)*[\p{L}_][\p{L}\p{N}_:<>,*&?\[\]]*\s+([\p{L}_][\p{L}\p{N}_]*)\s*(?:[=;,)]|$)"#
      ]
    }
    return captureNames(patterns: patterns, in: text)
  }

  private static func variableTypes(in text: String, languageID: String) -> [String: String] {
    let patterns: [(String, Int, Int)]
    switch languageID {
    case "swift":
      patterns = [
        (
          #"\b(?:let|var)\s+([\p{L}_][\p{L}\p{N}_]*)\s*:\s*([\p{L}_][\p{L}\p{N}_.<>?&\[\]]*)"#, 1, 2
        ),
        (#"\b(?:let|var)\s+([\p{L}_][\p{L}\p{N}_]*)\s*=\s*([\p{L}_][\p{L}\p{N}_.]*)\s*\("#, 1, 2),
      ]
    case "rust":
      patterns = [
        (
          #"\blet\s+(?:mut\s+)?([\p{L}_][\p{L}\p{N}_]*)\s*:\s*([\p{L}_][\p{L}\p{N}_:<>,&\[\]]*)"#,
          1, 2
        ),
        (
          #"\blet\s+(?:mut\s+)?([\p{L}_][\p{L}\p{N}_]*)\s*=\s*((?:[\p{L}_][\p{L}\p{N}_]*::)*[\p{L}_][\p{L}\p{N}_]*)\s*(?:::|\{|\()"#,
          1, 2
        ),
      ]
    case "kotlin", "typescript":
      patterns = [
        (
          #"\b(?:val|var|let|const)\s+([\p{L}_$][\p{L}\p{N}_$]*)\s*:\s*([\p{L}_$][\p{L}\p{N}_$<>,.?\[\]]*)"#,
          1, 2
        ),
        (
          #"\b(?:val|var|let|const)\s+([\p{L}_$][\p{L}\p{N}_$]*)\s*=\s*(?:new\s+)?([\p{L}_$][\p{L}\p{N}_$.]*)\s*\("#,
          1, 2
        ),
      ]
    case "javascript":
      patterns = [
        (
          #"\b(?:let|const|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)\s*=\s*new\s+([\p{L}_$][\p{L}\p{N}_$.]*)\s*\("#,
          1, 2
        )
      ]
    case "python":
      patterns = [
        (#"(?m)^\s*([\p{L}_][\p{L}\p{N}_]*)\s*:\s*([\p{L}_][\p{L}\p{N}_.\[\]]*)"#, 1, 2),
        (#"(?m)^\s*([\p{L}_][\p{L}\p{N}_]*)\s*=\s*([\p{L}_][\p{L}\p{N}_.]*)\s*\("#, 1, 2),
      ]
    case "go":
      patterns = [
        (#"(?m)\bvar\s+([\p{L}_][\p{L}\p{N}_]*)\s+([^=\n]+)(?:=|$)"#, 1, 2),
        (#"(?m)\b([\p{L}_][\p{L}\p{N}_]*)\s*:=\s*&?([\p{L}_][\p{L}\p{N}_.]*)\s*(?:\{|\()"#, 1, 2),
      ]
    case "lua":
      patterns = [
        (#"(?m)\blocal\s+([\p{L}_][\p{L}\p{N}_]*)\s*:\s*([\p{L}_][\p{L}\p{N}_.?\[\]]*)"#, 1, 2),
        (
          #"(?m)---@type\s+([\p{L}_][\p{L}\p{N}_.?\[\]]*)\s*\n\s*local\s+([\p{L}_][\p{L}\p{N}_]*)"#,
          2, 1
        ),
        (
          #"(?m)\blocal\s+([\p{L}_][\p{L}\p{N}_]*)\s*=\s*([\p{Lu}][\p{L}\p{N}_.]*)\s*(?:\.|:)?(?:new|create)?\s*\("#,
          1, 2
        ),
      ]
    default:
      patterns = [
        (#"\b([\p{L}_][\p{L}\p{N}_:<>,*&?\[\]]*)\s+([\p{L}_][\p{L}\p{N}_]*)\s*(?:[=;,)])"#, 2, 1)
      ]
    }

    var result: [String: String] = [:]
    let source = text as NSString
    for (pattern, nameGroup, typeGroup) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        guard match.numberOfRanges > max(nameGroup, typeGroup),
          match.range(at: nameGroup).location != NSNotFound,
          match.range(at: typeGroup).location != NSNotFound
        else { continue }
        let name = source.substring(with: match.range(at: nameGroup)).lowercased()
        let type = source.substring(with: match.range(at: typeGroup))
          .trimmingCharacters(in: CharacterSet(charactersIn: "&*?! "))
        if !name.isEmpty, !type.isEmpty { result[name] = type }
      }
    }
    return result
  }

  private struct CompletionParameterMetadata {
    var name: String
    var type: String?
  }

  private static func parameterMetadata(
    _ parameters: String,
    languageID: String
  ) -> [CompletionParameterMetadata] {
    topLevelComponents(in: parameters, separatedBy: ",").compactMap { raw in
      let part =
        topLevelComponents(in: raw, separatedBy: "=").first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !part.isEmpty else { return nil }

      let identifiers = identifierWords(in: part)
      guard !identifiers.isEmpty else { return nil }
      let colonParts = topLevelComponents(in: part, separatedBy: ":")
      let name: String
      let type: String?

      switch languageID {
      case "swift", "rust", "kotlin", "typescript", "python":
        let left = colonParts.first ?? part
        guard let candidate = identifierWords(in: left).last else { return nil }
        name = candidate
        type =
          colonParts.count > 1
          ? canonicalParameterType(colonParts.dropFirst().joined(separator: ":")) : nil
      case "go":
        guard let candidate = identifiers.first else { return nil }
        name = candidate
        type =
          identifiers.count > 1
          ? canonicalParameterType(identifiers.dropFirst().joined(separator: " ")) : nil
      case "javascript":
        guard let candidate = identifiers.last else { return nil }
        name = candidate
        type = nil
      default:
        guard let candidate = identifiers.last else { return nil }
        name = candidate
        let nameRange = part.range(of: candidate, options: .backwards)
        type = nameRange.map { canonicalParameterType(String(part[..<$0.lowerBound])) } ?? nil
      }

      guard !parameterNoise.contains(name.lowercased()) else { return nil }
      return CompletionParameterMetadata(name: name, type: type)
    }
  }

  private static func identifierWords(in value: String) -> [String] {
    value.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "$" }
      .map(String.init)
  }

  private static func canonicalParameterType(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(
        of: #"^(?:inout|borrowing|consuming|isolated|sending|mut|ref|const|final|readonly)\s+"#,
        with: "",
        options: .regularExpression
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: "&*?! "))
    guard !trimmed.isEmpty else { return nil }
    return trimmed
  }

  private static func topLevelComponents(
    in value: String,
    separatedBy separator: Character
  ) -> [String] {
    var components: [String] = []
    var current = ""
    var roundDepth = 0
    var squareDepth = 0
    var angleDepth = 0
    var braceDepth = 0
    var quote: Character?
    var escaped = false

    for character in value {
      if let activeQuote = quote {
        current.append(character)
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == activeQuote {
          quote = nil
        }
        continue
      }
      if character == "\"" || character == "'" || character == "`" {
        quote = character
        current.append(character)
        continue
      }
      switch character {
      case "(": roundDepth += 1
      case ")": roundDepth = max(0, roundDepth - 1)
      case "[": squareDepth += 1
      case "]": squareDepth = max(0, squareDepth - 1)
      case "<": angleDepth += 1
      case ">": angleDepth = max(0, angleDepth - 1)
      case "{": braceDepth += 1
      case "}": braceDepth = max(0, braceDepth - 1)
      default: break
      }
      if character == separator, roundDepth == 0, squareDepth == 0, angleDepth == 0,
        braceDepth == 0
      {
        components.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    components.append(current)
    return components
  }

  private static func captureNames(patterns: [String], in text: String) -> Set<String> {
    let source = text as NSString
    var result = Set<String>()
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { continue }
        let name = source.substring(with: match.range(at: 1)).lowercased()
        if !isControlWord(name) { result.insert(name) }
      }
    }
    return result
  }

  private static func returnType(
    in signature: String?,
    functionName: String?,
    languageID: String
  ) -> String? {
    guard let signature, let functionName else { return nil }
    let pattern: String
    switch languageID {
    case "swift":
      pattern =
        #"\)\s*(?:async\s*)?(?:throws?\s*)?->\s*(?:(?:some|any)\s+)?([\p{L}_][\p{L}\p{N}_.<>?&\[\]]*)"#
    case "rust", "python":
      pattern = #"\)\s*->\s*(?:(?:impl|dyn)\s+)?([\p{L}_][\p{L}\p{N}_.:<>,?&\[\]]*)"#
    case "kotlin", "typescript":
      pattern = #"\)\s*:\s*([\p{L}_$][\p{L}\p{N}_$.<>,?\[\]]*)"#
    case "go":
      pattern = #"\)\s*([\p{L}_][\p{L}\p{N}_.\[\]*]*)\s*$"#
    default:
      let escapedName = NSRegularExpression.escapedPattern(for: functionName)
      pattern =
        #"^\s*(?:(?:public|private|protected|internal|static|final|virtual|override|inline|constexpr|consteval|extern|async|synchronized)\s+)*([\p{L}_][\p{L}\p{N}_:<>,*&?\[\]]*)\s+"#
        + escapedName + #"\s*\("#
    }

    let source = signature as NSString
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: signature,
        range: NSRange(location: 0, length: source.length)
      ),
      match.numberOfRanges > 1,
      match.range(at: 1).location != NSNotFound
    else { return nil }
    let value = source.substring(with: match.range(at: 1))
      .trimmingCharacters(in: CharacterSet(charactersIn: "&*?! "))
    return value.isEmpty ? nil : value
  }

  private static func isStaticSignature(
    _ signature: String,
    languageID: String,
    parameters: Set<String>
  ) -> Bool {
    let lower = signature.lowercased()
    if lower.range(of: #"\b(?:class|static)\b"#, options: .regularExpression) != nil { return true }
    if languageID == "rust" { return !parameters.contains("self") }
    return false
  }

  private static func firstOpeningBrace(
    in source: NSString,
    after offset: Int,
    searchLimit: Int
  ) -> Int? {
    let end = min(source.length, offset + max(0, searchLimit))
    var index = max(0, offset)
    while index < end {
      let value = source.character(at: index)
      if value == 123 { return index }
      if value == 59 { return nil }
      index += 1
    }
    return nil
  }

  private static func matchingParenthesis(in source: NSString, openingAt open: Int) -> Int? {
    var depth = 0
    var index = open
    while index < source.length {
      switch source.character(at: index) {
      case 40: depth += 1
      case 41:
        depth -= 1
        if depth == 0 { return index }
      default: break
      }
      index += 1
    }
    return nil
  }

  private static func matchingBrace(in source: NSString, openingAt open: Int) -> Int? {
    var depth = 0
    var index = open
    while index < source.length {
      switch source.character(at: index) {
      case 123: depth += 1
      case 125:
        depth -= 1
        if depth == 0 { return index }
      default: break
      }
      index += 1
    }
    return nil
  }

  private static func isControlWord(_ value: String) -> Bool {
    controlWords.contains(value.lowercased())
  }

  private static let controlWords: Set<String> = [
    "if", "else", "for", "while", "switch", "catch", "return", "sizeof", "typeof",
    "alignof", "decltype", "new", "delete", "throw", "case", "do", "guard", "when",
  ]
  private static let inheritanceNoise: Set<String> = [
    "public", "private", "protected", "internal", "virtual", "final", "open", "sealed",
    "class", "struct", "interface", "protocol", "trait", "where",
  ]
  private static let parameterNoise: Set<String> = [
    "_", "self", "this", "mut", "inout", "ref", "out", "const", "final", "var", "let", "val",
  ]
}

private enum CompletionStructuralCodeMask {
  private enum State {
    case code
    case lineComment
    case blockComment
    case string(UInt16)
  }

  static func maskedCode(_ text: String, languageID: String) -> String {
    let source = text as NSString
    var output = [UInt16](repeating: 32, count: source.length)
    var state = State.code
    var index = 0
    let language = languageID.lowercased()
    let hashComments = ["python", "ruby", "shell", "yaml", "toml"].contains(language)
    let dashComments = ["sql", "lua", "haskell"].contains(language)
    let slashComments = !hashComments && !dashComments && language != "markdown"

    while index < source.length {
      let current = source.character(at: index)
      let next = index + 1 < source.length ? source.character(at: index + 1) : 0
      switch state {
      case .code:
        if current == 10 || current == 13 {
          output[index] = current
        } else if hashComments && current == 35 {
          state = .lineComment
        } else if dashComments && current == 45 && next == 45 {
          state = .lineComment
          index += 1
        } else if slashComments && current == 47 && next == 47 {
          state = .lineComment
          index += 1
        } else if slashComments && current == 47 && next == 42 {
          state = .blockComment
          index += 1
        } else if current == 34 || current == 39 || current == 96 {
          state = .string(current)
        } else {
          output[index] = current
        }
      case .lineComment:
        if current == 10 || current == 13 {
          output[index] = current
          state = .code
        }
      case .blockComment:
        if current == 10 || current == 13 { output[index] = current }
        if current == 42 && next == 47 {
          state = .code
          index += 1
        }
      case .string(let quote):
        if current == 10 || current == 13 { output[index] = current }
        if current == 92 { index += 1 } else if current == quote { state = .code }
      }
      index += 1
    }
    return String(decoding: output, as: UTF16.self)
  }
}
