import EditorCore
import Foundation

struct CFamilyCompletionLanguageStrategy: CompletionLanguageStrategy {
  let languageIDs: Set<String> = [
    "c", "cpp", "objective-c", "objective-cpp", "csharp", "java", "kotlin", "zig",
  ]

  func initializerContext(in text: String, caretUTF16Offset: Int) -> CompletionInitializerContext? {
    let source = text as NSString
    let caret = CompletionSyntaxUtilities.clampedCaret(caretUTF16Offset, in: source)
    guard
      let opening = CompletionSyntaxUtilities.unmatchedOpening(
        open: 123, close: 125, before: caret, in: source)
    else { return nil }
    let headerStart = max(0, opening - 260)
    let header = source.substring(
      with: NSRange(location: headerStart, length: opening - headerStart))
    guard let typeName = aggregateType(in: header) else { return nil }
    let body = source.substring(
      with: NSRange(location: opening + 1, length: max(0, caret - opening - 1)))
    let segments = CompletionSyntaxUtilities.topLevelComponents(in: body, separatedBy: ",")
    var used = Set<String>()
    for segment in segments.dropLast() {
      if let name = designatedMemberName(in: segment) { used.insert(name.lowercased()) }
    }
    let current = segments.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let equal = CompletionSyntaxUtilities.firstTopLevelIndex(of: "=", in: current),
      let name = CompletionSyntaxUtilities.identifierWords(in: String(current[..<equal])).last
    {
      used.insert(name.lowercased())
      return CompletionInitializerContext(
        typeName: typeName,
        usedMembers: used,
        position: .memberValue(memberName: name)
      )
    }
    if let colon = CompletionSyntaxUtilities.firstTopLevelIndex(of: ":", in: current),
      let name = CompletionSyntaxUtilities.identifierWords(in: String(current[..<colon])).last
    {
      used.insert(name.lowercased())
      return CompletionInitializerContext(
        typeName: typeName,
        usedMembers: used,
        position: .memberValue(memberName: name)
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
        name: item.key, typeName: canonicalType(item.value))
    }
    let pattern =
      #"(?m)(?:^|[;{}])\s*(?:const\s+|static\s+|final\s+|volatile\s+|mut\s+)*([\p{L}_][\p{L}\p{N}_:<>,.?&*\[\]]*)\s+([\p{L}_][\p{L}\p{N}_]*)\s*(?:=|;|,)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return CompletionSyntaxUtilities.sortedBindings(values)
    }
    let ns = prefix as NSString
    for match in regex.matches(in: prefix, range: NSRange(location: 0, length: ns.length)) {
      guard match.numberOfRanges > 2 else { continue }
      let type = canonicalType(ns.substring(with: match.range(at: 1)))
      let name = ns.substring(with: match.range(at: 2))
      values[name.lowercased()] = CompletionVisibleBinding(name: name, typeName: type)
    }
    return CompletionSyntaxUtilities.sortedBindings(values)
  }

  func canonicalType(_ raw: String?) -> String? {
    CompletionSyntaxUtilities.canonicalNominalType(raw)
  }

  func defaultExpression(for rawType: String?) -> String {
    let canonical = canonicalType(rawType)?.lowercased() ?? ""
    if ["bool", "boolean"].contains(canonical) { return "false" }
    if ["char", "short", "int", "long", "float", "double", "size_t", "uint32_t", "uint64_t"]
      .contains(canonical)
    {
      return "0"
    }
    if rawType?.contains("*") == true { return "nullptr" }
    if canonical == "string" || canonical == "std::string" { return "{}" }
    return "{}"
  }

  func initializerInsertion(memberName: String, defaultExpression: String?) -> String {
    ".\(memberName) = \(defaultExpression ?? "${1:{}}")"
  }

  func rankingAdjustment(_ input: CompletionLanguageRankingInput) -> Int {
    var score = CompletionLanguageRankingDefaults.adjustment(input)
    if input.isMemberAccess {
      switch input.kind {
      case .method: score += 330
      case .field, .property: score += 120
      case .function: score -= 30
      default: break
      }
    }
    return score
  }

  private func aggregateType(in header: String) -> String? {
    let patterns = [
      #"(?:struct\s+)?([\p{L}_][\p{L}\p{N}_:<>]*)\s+[\p{L}_][\p{L}\p{N}_]*\s*=\s*$"#,
      #"([\p{L}_][\p{L}\p{N}_:<>]*)\s*$"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(
          in: header, range: NSRange(location: 0, length: (header as NSString).length)),
        match.range(at: 1).location != NSNotFound
      else { continue }
      let candidate = (header as NSString).substring(with: match.range(at: 1))
      if ["if", "else", "switch", "for", "while", "do", "class", "struct", "enum", "namespace"]
        .contains(candidate.lowercased())
      {
        continue
      }
      return canonicalType(candidate)
    }
    return nil
  }

  private func designatedMemberName(in segment: String) -> String? {
    let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("."),
      let equal = CompletionSyntaxUtilities.firstTopLevelIndex(of: "=", in: trimmed)
    {
      return CompletionSyntaxUtilities.identifierWords(in: String(trimmed[..<equal])).last
    }
    if let colon = CompletionSyntaxUtilities.firstTopLevelIndex(of: ":", in: trimmed) {
      return CompletionSyntaxUtilities.identifierWords(in: String(trimmed[..<colon])).last
    }
    return nil
  }
}
