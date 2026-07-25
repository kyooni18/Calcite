import EditorCore
import Foundation

struct JavaScriptCompletionLanguageStrategy: CompletionLanguageStrategy {
  let languageIDs: Set<String> = ["javascript", "typescript"]

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
    guard let typeName = objectLiteralType(in: header) else { return nil }
    let body = source.substring(
      with: NSRange(location: opening + 1, length: max(0, caret - opening - 1)))
    let segments = CompletionSyntaxUtilities.topLevelComponents(in: body, separatedBy: ",")
    var used = Set<String>()
    for segment in segments.dropLast() {
      if let name = objectMemberName(in: segment) { used.insert(name.lowercased()) }
    }
    let current = segments.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
    let patterns = [
      #"\b(?:const|let|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)\s*:\s*([^=;\n]+)"#,
      #"\b(?:const|let|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)\s*=\s*new\s+([\p{Lu}][\p{L}\p{N}_$.]*)\s*\("#,
    ]
    let ns = prefix as NSString
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(in: prefix, range: NSRange(location: 0, length: ns.length)) {
        guard match.numberOfRanges > 2 else { continue }
        let name = ns.substring(with: match.range(at: 1))
        let type = canonicalType(ns.substring(with: match.range(at: 2)))
        values[name.lowercased()] = CompletionVisibleBinding(name: name, typeName: type)
      }
    }
    return CompletionSyntaxUtilities.sortedBindings(values)
  }

  func canonicalType(_ raw: String?) -> String? {
    CompletionSyntaxUtilities.canonicalNominalType(raw)
  }

  func defaultExpression(for rawType: String?) -> String {
    guard let rawType else { return "undefined" }
    let canonical = canonicalType(rawType)?.lowercased() ?? ""
    if rawType.contains("|") && rawType.lowercased().contains("undefined") { return "undefined" }
    if rawType.contains("|") && rawType.lowercased().contains("null") { return "null" }
    if canonical == "string" { return "\"\"" }
    if canonical == "boolean" || canonical == "bool" { return "false" }
    if canonical == "number" || canonical == "bigint" { return "0" }
    if canonical == "array" || rawType.trimmingCharacters(in: .whitespaces).hasSuffix("[]") {
      return "[]"
    }
    if canonical == "record" || canonical == "object" { return "{}" }
    return "undefined"
  }

  func initializerInsertion(memberName: String, defaultExpression: String?) -> String {
    "\(memberName): \(defaultExpression ?? "${1:undefined}")"
  }

  func rankingAdjustment(_ input: CompletionLanguageRankingInput) -> Int {
    var score = CompletionLanguageRankingDefaults.adjustment(input)
    if input.isMemberAccess {
      switch input.kind {
      case .method: score += 350
      case .property, .field: score += 110
      case .function: score -= 30
      default: break
      }
    }
    return score
  }

  private func objectLiteralType(in header: String) -> String? {
    let patterns = [
      #":\s*([\p{L}_$][\p{L}\p{N}_$.<>]*)\s*=\s*$"#,
      #"\bas\s+([\p{L}_$][\p{L}\p{N}_$.<>]*)\s*$"#,
      #"\bsatisfies\s+([\p{L}_$][\p{L}\p{N}_$.<>]*)\s*$"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(
          in: header, range: NSRange(location: 0, length: (header as NSString).length)),
        match.range(at: 1).location != NSNotFound
      else { continue }
      return canonicalType((header as NSString).substring(with: match.range(at: 1)))
    }
    return nil
  }

  private func objectMemberName(in segment: String) -> String? {
    if let colon = CompletionSyntaxUtilities.firstTopLevelIndex(of: ":", in: segment) {
      return CompletionSyntaxUtilities.identifierWords(in: String(segment[..<colon])).last
    }
    return CompletionSyntaxUtilities.identifierWords(in: segment).last
  }
}
