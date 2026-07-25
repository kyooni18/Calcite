import EditorCore
import Foundation

struct CompletionScopedCandidate: Sendable {
  var name: String
  var insertion: String
  var kind: CompletionKind
  var detail: String
}

struct CompletionMemberAccessContext: Sendable {
  var receiver: String
  var ownerTypes: Set<String>
  var staticAccess: Bool?
  var tupleMembers: [CompletionScopedCandidate]

  func accepts(_ symbol: ProjectCompletionSymbol) -> Bool {
    guard let owner = symbol.ownerType?.lowercased(),
      ownerTypes.contains(where: { $0.lowercased() == owner })
    else { return false }
    if staticAccess == true {
      return symbol.isStatic || symbol.kind == .enumMember || symbol.kind == .constructor
    }
    if staticAccess == false {
      return !symbol.isStatic && symbol.kind != .enumMember && symbol.kind != .constructor
    }
    return true
  }
}

enum CompletionScopedSymbolAnalysis {
  static func memberAccess(
    in text: String,
    languageID: String,
    caretUTF16Offset: Int,
    prefix: String,
    lexicalContext: CompletionLexicalContext
  ) -> CompletionMemberAccessContext? {
    let source = text as NSString
    let prefixStart = max(0, caretUTF16Offset - prefix.utf16.count)
    guard
      let operatorRange = memberOperator(
        before: prefixStart,
        in: source,
        languageID: CompletionStructuralAnalysis.normalizedLanguage(languageID)
      )
    else { return nil }
    guard let receiver = receiverIdentifier(before: operatorRange.location, in: source) else {
      return nil
    }

    let lower = receiver.lowercased()
    var ownerTypes = Set<String>()
    let staticAccess: Bool?
    if ["self", "this"].contains(lower) {
      if let currentType = lexicalContext.currentType { ownerTypes.insert(currentType) }
      ownerTypes.formUnion(lexicalContext.baseTypes)
      staticAccess = false
    } else if receiver == "Self" {
      if let currentType = lexicalContext.currentType { ownerTypes.insert(currentType) }
      ownerTypes.formUnion(lexicalContext.baseTypes)
      staticAccess = true
    } else if let type = lexicalContext.variableTypes[lower],
      let owner = nominalTypeName(from: type)
    {
      ownerTypes.insert(owner)
      staticAccess = false
    } else if receiver.first?.isUppercase == true {
      ownerTypes.insert(receiver)
      staticAccess = true
    } else {
      staticAccess = nil
    }

    var pendingOwners = Array(ownerTypes)
    var visitedOwners = Set(ownerTypes.map { $0.lowercased() })
    while let owner = pendingOwners.popLast() {
      for scope in lexicalContext.typeScopes
      where scope.name.caseInsensitiveCompare(owner) == .orderedSame {
        for inherited in scope.inheritedTypes
        where visitedOwners.insert(inherited.lowercased()).inserted {
          ownerTypes.insert(inherited)
          pendingOwners.append(inherited)
        }
      }
    }

    let tupleMembers = tupleMembers(
      in: text,
      languageID: languageID,
      caretUTF16Offset: caretUTF16Offset,
      receiver: receiver,
      declaredType: lexicalContext.variableTypes[lower]
    )
    return CompletionMemberAccessContext(
      receiver: receiver,
      ownerTypes: ownerTypes,
      staticAccess: staticAccess,
      tupleMembers: tupleMembers
    )
  }

  private static func memberOperator(
    before prefixStart: Int,
    in source: NSString,
    languageID: String
  ) -> NSRange? {
    var index = min(prefixStart, source.length)
    while index > 0, isWhitespace(source.character(at: index - 1)) { index -= 1 }
    guard index > 0 else { return nil }

    let previous = source.character(at: index - 1)
    if previous == 46 { return NSRange(location: index - 1, length: 1) }
    if previous == 58, index > 1, source.character(at: index - 2) == 58 {
      return NSRange(location: index - 2, length: 2)
    }
    if previous == 58, languageID == "lua" {
      return NSRange(location: index - 1, length: 1)
    }
    if previous == 62, index > 1, source.character(at: index - 2) == 45 {
      return NSRange(location: index - 2, length: 2)
    }
    return nil
  }

  private static func receiverIdentifier(before location: Int, in source: NSString) -> String? {
    var end = location
    while end > 0, isWhitespace(source.character(at: end - 1)) { end -= 1 }
    var start = end
    while start > 0, isIdentifierUnit(source.character(at: start - 1)) { start -= 1 }
    guard start < end else { return nil }
    return source.substring(with: NSRange(location: start, length: end - start))
  }

  private static func nominalTypeName(from rawType: String) -> String? {
    var value = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
    while let first = value.first, ["&", "*", "?", "!"].contains(first) {
      value.removeFirst()
    }
    while let last = value.last, ["&", "*", "?", "!"].contains(last) {
      value.removeLast()
    }
    guard !value.hasPrefix("("), !value.hasPrefix("[") else { return nil }
    if let generic = value.firstIndex(of: "<") { value = String(value[..<generic]) }
    value = value.split(separator: ".").last.map(String.init) ?? value
    value = value.split(separator: ":").last.map(String.init) ?? value
    let identifiers = value.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "$" }
    return identifiers.last.map(String.init)
  }

  private static func tupleMembers(
    in text: String,
    languageID: String,
    caretUTF16Offset: Int,
    receiver: String,
    declaredType: String?
  ) -> [CompletionScopedCandidate] {
    let language = CompletionStructuralAnalysis.normalizedLanguage(languageID)
    guard language == "swift" || language == "rust" else { return [] }

    if let declaredType, let content = parenthesizedContent(in: declaredType) {
      let members = parsedTupleMembers(
        content,
        languageID: language,
        receiver: receiver,
        allowSingleElement: language == "rust" && hasTopLevelSeparator(in: content, separator: ",")
      )
      if !members.isEmpty { return members }
    }

    let source = text as NSString
    let searchableLength = min(max(0, caretUTF16Offset), source.length)
    let searchable = source.substring(to: searchableLength)
    let escaped = NSRegularExpression.escapedPattern(for: receiver)
    let patterns: [String]
    if language == "swift" {
      patterns = [
        #"\b(?:let|var)\s+"# + escaped + #"\s*:\s*\("#,
        #"\b(?:let|var)\s+"# + escaped + #"\s*=\s*\("#,
        #"\b"# + escaped + #"\s*:\s*\("#,
      ]
    } else {
      patterns = [
        #"\blet\s+(?:mut\s+)?"# + escaped + #"\s*:\s*\("#,
        #"\blet\s+(?:mut\s+)?"# + escaped + #"\s*=\s*\("#,
        #"\b"# + escaped + #"\s*:\s*\("#,
      ]
    }

    var latestOpening: Int?
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(
        in: searchable,
        range: NSRange(location: 0, length: (searchable as NSString).length)
      ) {
        let opening = NSMaxRange(match.range) - 1
        if latestOpening == nil || opening > latestOpening! { latestOpening = opening }
      }
    }

    if let opening = latestOpening,
      let closing = matchingParenthesis(in: source, openingAt: opening),
      closing < searchableLength
    {
      let content = source.substring(
        with: NSRange(location: opening + 1, length: closing - opening - 1)
      )
      let members = parsedTupleMembers(
        content,
        languageID: language,
        receiver: receiver,
        allowSingleElement: language == "rust" && hasTopLevelSeparator(in: content, separator: ",")
      )
      if !members.isEmpty { return members }
    }

    if language == "rust", let owner = declaredType.flatMap(nominalTypeName(from:)) {
      let pattern = #"\bstruct\s+"# + NSRegularExpression.escapedPattern(for: owner) + #"\s*\("#
      if let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(
          in: text,
          range: NSRange(location: 0, length: source.length)
        )
      {
        let opening = NSMaxRange(match.range) - 1
        if let closing = matchingParenthesis(in: source, openingAt: opening) {
          let content = source.substring(
            with: NSRange(location: opening + 1, length: closing - opening - 1)
          )
          return parsedTupleMembers(
            content,
            languageID: language,
            receiver: receiver,
            allowSingleElement: true
          )
        }
      }
    }
    return []
  }

  private static func parenthesizedContent(in value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.first == "(", trimmed.last == ")", trimmed.count >= 2 else { return nil }
    return String(trimmed.dropFirst().dropLast())
  }

  private static func parsedTupleMembers(
    _ content: String,
    languageID: String,
    receiver: String,
    allowSingleElement: Bool = false
  ) -> [CompletionScopedCandidate] {
    let elements = topLevelComponents(in: content, separatedBy: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard elements.count > 1 || allowSingleElement && elements.count == 1 else { return [] }

    var candidates: [CompletionScopedCandidate] = []
    var seen = Set<String>()
    for (index, element) in elements.enumerated() {
      let indexName = String(index)
      if seen.insert(indexName).inserted {
        candidates.append(
          CompletionScopedCandidate(
            name: indexName,
            insertion: indexName,
            kind: .field,
            detail: "Tuple element • \(receiver)"
          )
        )
      }
      guard languageID == "swift" else { continue }
      let pieces = topLevelComponents(in: element, separatedBy: ":")
      guard pieces.count > 1,
        let label = identifierWords(in: pieces[0]).last,
        label != "_",
        seen.insert(label.lowercased()).inserted
      else { continue }
      candidates.append(
        CompletionScopedCandidate(
          name: label,
          insertion: label,
          kind: .property,
          detail: "Tuple element • \(receiver)"
        )
      )
    }
    return candidates
  }

  private static func matchingParenthesis(in source: NSString, openingAt opening: Int) -> Int? {
    guard opening >= 0, opening < source.length, source.character(at: opening) == 40 else {
      return nil
    }
    var depth = 0
    var quote: UInt16?
    var escaped = false
    var index = opening
    while index < source.length {
      let character = source.character(at: index)
      if let activeQuote = quote {
        if escaped {
          escaped = false
        } else if character == 92 {
          escaped = true
        } else if character == activeQuote {
          quote = nil
        }
      } else if character == 34 || character == 39 || character == 96 {
        quote = character
      } else if character == 40 {
        depth += 1
      } else if character == 41 {
        depth -= 1
        if depth == 0 { return index }
      }
      index += 1
    }
    return nil
  }

  private static func hasTopLevelSeparator(
    in value: String,
    separator: Character
  ) -> Bool {
    topLevelComponents(in: value, separatedBy: separator).count > 1
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

  private static func identifierWords(in value: String) -> [String] {
    value.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "$" }
      .map(String.init)
  }

  private static func isWhitespace(_ value: UInt16) -> Bool {
    value == 9 || value == 10 || value == 13 || value == 32
  }

  private static func isIdentifierUnit(_ value: UInt16) -> Bool {
    value == 36 || value == 95 || (48...57).contains(value) || (65...90).contains(value)
      || (97...122).contains(value) || value >= 128
  }
}
