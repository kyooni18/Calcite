import EditorCore
import Foundation

struct SwiftCompletionLanguageStrategy: CompletionLanguageStrategy {
  let languageIDs: Set<String> = ["swift"]

  func initializerContext(in text: String, caretUTF16Offset: Int) -> CompletionInitializerContext? {
    let source = text as NSString
    let caret = CompletionSyntaxUtilities.clampedCaret(caretUTF16Offset, in: source)
    guard
      let opening = CompletionSyntaxUtilities.unmatchedOpening(
        open: 40,
        close: 41,
        before: caret,
        in: source
      )
    else { return nil }
    let headerStart = max(0, opening - 220)
    let header = source.substring(
      with: NSRange(location: headerStart, length: opening - headerStart))
    guard let typeName = calledType(in: header) else { return nil }
    let body = source.substring(
      with: NSRange(location: opening + 1, length: max(0, caret - opening - 1))
    )
    let segments = CompletionSyntaxUtilities.topLevelComponents(in: body, separatedBy: ",")
    var used = Set<String>()
    for segment in segments.dropLast() {
      if let colon = CompletionSyntaxUtilities.firstTopLevelIndex(of: ":", in: segment),
        let label = CompletionSyntaxUtilities.identifierWords(in: String(segment[..<colon])).last
      {
        used.insert(label.lowercased())
      }
    }
    let current = segments.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let colon = CompletionSyntaxUtilities.firstTopLevelIndex(of: ":", in: current),
      let label = CompletionSyntaxUtilities.identifierWords(in: String(current[..<colon])).last
    {
      used.insert(label.lowercased())
      return CompletionInitializerContext(
        typeName: typeName,
        usedMembers: used,
        position: .memberValue(memberName: label)
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
    consume(
      pattern: #"\b(?:let|var)\s+([\p{L}_][\p{L}\p{N}_]*)\s*:\s*([^=\n{]+)"#,
      in: prefix,
      values: &values
    )
    consume(
      pattern:
        #"\b(?:let|var)\s+([\p{L}_][\p{L}\p{N}_]*)\s*=\s*(?:try[!?]?\s+|await\s+)*([\p{Lu}][\p{L}\p{N}_.]*)\s*\("#,
      in: prefix,
      values: &values
    )
    return CompletionSyntaxUtilities.sortedBindings(values)
  }

  func canonicalType(_ raw: String?) -> String? {
    CompletionSyntaxUtilities.canonicalNominalType(raw)
  }

  func defaultExpression(for rawType: String?) -> String {
    guard let rawType else { return ".init()" }
    let canonical = canonicalType(rawType)?.lowercased() ?? ""
    if rawType.trimmingCharacters(in: .whitespaces).hasSuffix("?") { return "nil" }
    if canonical == "string" { return "\"\"" }
    if canonical == "bool" { return "false" }
    if [
      "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64",
      "float", "double", "cgfloat",
    ].contains(canonical) {
      return "0"
    }
    if canonical == "array" { return "[]" }
    if canonical == "dictionary" || canonical == "set" { return "[]" }
    return ".init()"
  }

  func initializerInsertion(memberName: String, defaultExpression: String?) -> String {
    "\(memberName): \(defaultExpression ?? "${1:.init()}")"
  }

  func rankingAdjustment(_ input: CompletionLanguageRankingInput) -> Int {
    var score = CompletionLanguageRankingDefaults.adjustment(input)
    if input.isMemberAccess {
      switch input.kind {
      case .method: score += 360
      case .property, .field: score += 120
      case .function: score -= 40
      default: break
      }
    }
    return score
  }

  private func calledType(in header: String) -> String? {
    let pattern =
      #"(?:^|[^\p{L}\p{N}_])([\p{Lu}][\p{L}\p{N}_]*(?:\.[\p{Lu}][\p{L}\p{N}_]*)*|[\p{Lu}][\p{L}\p{N}_]*\.init)\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: header, range: NSRange(location: 0, length: (header as NSString).length)),
      match.range(at: 1).location != NSNotFound
    else { return nil }
    let raw = (header as NSString).substring(with: match.range(at: 1))
    return raw.replacingOccurrences(of: ".init", with: "").split(separator: ".").last.map(
      String.init)
  }

  private func consume(
    pattern: String,
    in text: String,
    values: inout [String: CompletionVisibleBinding]
  ) {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    let source = text as NSString
    for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
      guard match.numberOfRanges > 2,
        match.range(at: 1).location != NSNotFound,
        match.range(at: 2).location != NSNotFound
      else { continue }
      let name = source.substring(with: match.range(at: 1))
      let type = canonicalType(source.substring(with: match.range(at: 2)))
      values[name.lowercased()] = CompletionVisibleBinding(name: name, typeName: type)
    }
  }
}
