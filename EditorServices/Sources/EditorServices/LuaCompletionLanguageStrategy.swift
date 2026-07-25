import EditorCore
import Foundation

/// Lua/LuaLS-aware completion behavior. It understands typed table literals and EmmyLua/LuaLS
/// annotations without executing project Lua code.
struct LuaCompletionLanguageStrategy: CompletionLanguageStrategy {
  let languageIDs: Set<String> = ["lua"]

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

    let headerStart = max(0, opening - 360)
    let header = source.substring(
      with: NSRange(location: headerStart, length: opening - headerStart)
    )
    guard let typeName = annotatedTableType(in: header) else { return nil }

    let body = source.substring(
      with: NSRange(location: opening + 1, length: max(0, caret - opening - 1))
    )
    let segments = CompletionSyntaxUtilities.topLevelComponents(in: body, separatedBy: ",")
    var used = Set<String>()
    for segment in segments.dropLast() {
      if let member = tableMemberName(in: segment) { used.insert(member.lowercased()) }
    }

    let current = segments.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let equal = CompletionSyntaxUtilities.firstTopLevelIndex(of: "=", in: current),
      let member = CompletionSyntaxUtilities.identifierWords(in: String(current[..<equal])).last
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
      #"(?m)\blocal\s+([\p{L}_][\p{L}\p{N}_]*)\s*:\s*([\p{L}_][\p{L}\p{N}_.?\[\]]*)"#,
      #"(?m)---@type\s+([\p{L}_][\p{L}\p{N}_.?\[\]]*)\s*\n\s*local\s+([\p{L}_][\p{L}\p{N}_]*)"#,
      #"(?m)\blocal\s+([\p{L}_][\p{L}\p{N}_]*)\s*=\s*([\p{Lu}][\p{L}\p{N}_.]*)\s*(?:\.|:)?(?:new|create)?\s*\("#,
    ]
    for (index, pattern) in patterns.enumerated() {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(
        in: prefix,
        range: NSRange(location: 0, length: (prefix as NSString).length)
      ) {
        guard match.numberOfRanges > 2 else { continue }
        let nameGroup = index == 1 ? 2 : 1
        let typeGroup = index == 1 ? 1 : 2
        guard match.range(at: nameGroup).location != NSNotFound,
          match.range(at: typeGroup).location != NSNotFound
        else { continue }
        let name = (prefix as NSString).substring(with: match.range(at: nameGroup))
        let type = canonicalType((prefix as NSString).substring(with: match.range(at: typeGroup)))
        values[name.lowercased()] = CompletionVisibleBinding(name: name, typeName: type)
      }
    }
    return CompletionSyntaxUtilities.sortedBindings(values)
  }

  func canonicalType(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    value = value.replacingOccurrences(of: "?", with: "")
    if let union = value.firstIndex(of: "|") { value = String(value[..<union]) }
    return CompletionSyntaxUtilities.canonicalNominalType(value)
  }

  func defaultExpression(for rawType: String?) -> String {
    let lower = rawType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let canonical = canonicalType(rawType)?.lowercased() ?? ""
    if lower.contains("nil") || lower.hasSuffix("?") { return "nil" }
    if canonical == "boolean" || canonical == "bool" { return "false" }
    if canonical == "string" { return "\"\"" }
    if canonical == "number" || canonical == "integer" { return "0" }
    if canonical == "table" || lower.hasSuffix("[]") { return "{}" }
    return "nil"
  }

  func initializerInsertion(memberName: String, defaultExpression: String?) -> String {
    "\(memberName) = \(defaultExpression ?? "${1:nil}")"
  }

  func rankingAdjustment(_ input: CompletionLanguageRankingInput) -> Int {
    var score = CompletionLanguageRankingDefaults.adjustment(input)
    if input.isMemberAccess {
      switch input.kind {
      case .method: score += 390
      case .field, .property: score += 120
      case .function: score -= 40
      default: break
      }
    }
    return score
  }

  private func annotatedTableType(in header: String) -> String? {
    let patterns = [
      #"---@type\s+([\p{L}_][\p{L}\p{N}_.]*)\s*\n\s*(?:local\s+)?[\p{L}_][\p{L}\p{N}_]*\s*=\s*$"#,
      #"(?:local\s+)?[\p{L}_][\p{L}\p{N}_]*\s*:\s*([\p{L}_][\p{L}\p{N}_.]*)\s*=\s*$"#,
      #"([\p{Lu}][\p{L}\p{N}_.]*)\s*$"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(
          in: header,
          range: NSRange(location: 0, length: (header as NSString).length)
        ),
        match.range(at: 1).location != NSNotFound
      else { continue }
      return canonicalType((header as NSString).substring(with: match.range(at: 1)))
    }
    return nil
  }

  private func tableMemberName(in segment: String) -> String? {
    guard let equal = CompletionSyntaxUtilities.firstTopLevelIndex(of: "=", in: segment) else {
      return nil
    }
    return CompletionSyntaxUtilities.identifierWords(in: String(segment[..<equal])).last
  }
}
