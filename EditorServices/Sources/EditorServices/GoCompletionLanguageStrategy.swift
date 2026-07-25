import EditorCore
import Foundation

/// Go-specific completion semantics. The generic completion engine remains language-neutral;
/// this strategy only owns Go composite literals, zero values, bindings, and ranking rules.
struct GoCompletionLanguageStrategy: CompletionLanguageStrategy {
  let languageIDs: Set<String> = ["go"]

  func initializerContext(in text: String, caretUTF16Offset: Int) -> CompletionInitializerContext? {
    let source = text as NSString
    let caret = CompletionSyntaxUtilities.clampedCaret(caretUTF16Offset, in: source)
    guard
      let opening = CompletionSyntaxUtilities.unmatchedOpening(
        open: 123,
        close: 125,
        before: caret,
        in: source
      )
    else { return nil }

    let headerStart = max(0, opening - 240)
    let header = source.substring(
      with: NSRange(location: headerStart, length: opening - headerStart)
    )
    guard let typeName = compositeLiteralType(in: header) else { return nil }

    let body = source.substring(
      with: NSRange(location: opening + 1, length: max(0, caret - opening - 1))
    )
    let segments = CompletionSyntaxUtilities.topLevelComponents(in: body, separatedBy: ",")
    var used = Set<String>()
    for segment in segments.dropLast() {
      if let member = fieldName(in: segment) { used.insert(member.lowercased()) }
    }

    let current = segments.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let colon = CompletionSyntaxUtilities.firstTopLevelIndex(of: ":", in: current),
      let member = CompletionSyntaxUtilities.identifierWords(in: String(current[..<colon])).last
    {
      used.insert(member.lowercased())
      return CompletionInitializerContext(
        typeName: typeName,
        usedMembers: used,
        position: .memberValue(memberName: member)
      )
    }
    return CompletionInitializerContext(
      typeName: typeName, usedMembers: used, position: .memberName)
  }

  func visibleBindings(
    in text: String,
    caretUTF16Offset: Int,
    lexicalTypes: [String: String]
  ) -> [CompletionVisibleBinding] {
    let source = text as NSString
    let caret = CompletionSyntaxUtilities.clampedCaret(caretUTF16Offset, in: source)
    let prefix = source.substring(to: caret)
    var values = lexicalTypes.reduce(into: [String: CompletionVisibleBinding]()) { result, item in
      result[item.key.lowercased()] = CompletionVisibleBinding(
        name: item.key,
        typeName: canonicalType(item.value)
      )
    }

    let patterns = [
      #"(?m)\bvar\s+([\p{L}_][\p{L}\p{N}_]*)\s+([^=\n]+)(?:=|$)"#,
      #"(?m)\b([\p{L}_][\p{L}\p{N}_]*)\s*:=\s*&?([\p{L}_][\p{L}\p{N}_.]*)\s*(?:\{|\()"#,
      #"(?m)\b([\p{L}_][\p{L}\p{N}_]*)\s*=\s*&?([\p{L}_][\p{L}\p{N}_.]*)\s*(?:\{|\()"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(
        in: prefix,
        range: NSRange(location: 0, length: (prefix as NSString).length)
      ) {
        guard match.numberOfRanges > 2,
          match.range(at: 1).location != NSNotFound,
          match.range(at: 2).location != NSNotFound
        else { continue }
        let name = (prefix as NSString).substring(with: match.range(at: 1))
        let type = canonicalType((prefix as NSString).substring(with: match.range(at: 2)))
        values[name.lowercased()] = CompletionVisibleBinding(name: name, typeName: type)
      }
    }
    return CompletionSyntaxUtilities.sortedBindings(values)
  }

  func canonicalType(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    while value.hasPrefix("*") { value.removeFirst() }
    if value.hasPrefix("[]") { value.removeFirst(2) }
    if value.hasPrefix("...") { value.removeFirst(3) }
    return CompletionSyntaxUtilities.canonicalNominalType(value)
  }

  func typesAreCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs, let rhs else { return false }
    let left = normalizedType(lhs)
    let right = normalizedType(rhs)
    return !left.isEmpty && left == right
  }

  func defaultExpression(for rawType: String?) -> String {
    guard let rawType else { return "${1:nil}" }
    let compact = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = compact.lowercased()
    let canonical = canonicalType(compact)?.lowercased() ?? ""

    if compact.hasPrefix("*") || compact.hasPrefix("[]") || lower.hasPrefix("map[")
      || lower.hasPrefix("chan ") || lower.hasPrefix("<-chan ") || lower.hasPrefix("func(")
      || lower.hasPrefix("interface{") || canonical == "error" || canonical == "any"
    {
      return "nil"
    }
    if canonical == "bool" { return "false" }
    if canonical == "string" { return "\"\"" }
    if [
      "byte", "rune", "int", "int8", "int16", "int32", "int64", "uint", "uint8",
      "uint16", "uint32", "uint64", "uintptr", "float32", "float64", "complex64",
      "complex128",
    ].contains(canonical) {
      return "0"
    }
    if compact.hasPrefix("[") { return "\(compact){}" }
    if let type = canonicalType(compact), !type.isEmpty { return "\(type){}" }
    return "${1:nil}"
  }

  func initializerInsertion(memberName: String, defaultExpression: String?) -> String {
    "\(memberName): \(defaultExpression ?? "${1:nil}")"
  }

  func rankingAdjustment(_ input: CompletionLanguageRankingInput) -> Int {
    var score = CompletionLanguageRankingDefaults.adjustment(input)
    if input.isMemberAccess {
      switch input.kind {
      case .method: score += 380
      case .field, .property: score += 120
      case .function: score -= 50
      default: break
      }
    }
    return score
  }

  private func compositeLiteralType(in header: String) -> String? {
    let pattern =
      #"(?:^|[^\p{L}\p{N}_])&?([\p{L}_][\p{L}\p{N}_]*(?:\.[\p{L}_][\p{L}\p{N}_]*)?(?:\[[^\]]*\])?)\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: header,
        range: NSRange(location: 0, length: (header as NSString).length)
      ),
      match.range(at: 1).location != NSNotFound
    else { return nil }
    let raw = (header as NSString).substring(with: match.range(at: 1))
    let candidate = canonicalType(raw)
    guard let candidate,
      !["if", "for", "switch", "select", "func", "map", "struct", "interface"].contains(
        candidate.lowercased()
      )
    else { return nil }
    return candidate
  }

  private func fieldName(in segment: String) -> String? {
    guard let colon = CompletionSyntaxUtilities.firstTopLevelIndex(of: ":", in: segment) else {
      return nil
    }
    return CompletionSyntaxUtilities.identifierWords(in: String(segment[..<colon])).last
  }

  private func normalizedType(_ raw: String) -> String {
    var value = raw.replacingOccurrences(of: " ", with: "")
    while value.hasPrefix("*") { value.removeFirst() }
    return value.lowercased()
  }
}
