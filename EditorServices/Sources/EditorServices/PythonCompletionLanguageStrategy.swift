import EditorCore
import Foundation

struct PythonCompletionLanguageStrategy: CompletionLanguageStrategy {
  let languageIDs: Set<String> = ["python"]

  func initializerContext(in text: String, caretUTF16Offset: Int) -> CompletionInitializerContext? {
    let source = text as NSString
    let caret = CompletionSyntaxUtilities.clampedCaret(caretUTF16Offset, in: source)
    guard
      let opening = CompletionSyntaxUtilities.unmatchedOpening(
        open: 40, close: 41, before: caret, in: source)
    else { return nil }
    let headerStart = max(0, opening - 180)
    let header = source.substring(
      with: NSRange(location: headerStart, length: opening - headerStart))
    guard let typeName = calledType(in: header) else { return nil }
    let body = source.substring(
      with: NSRange(location: opening + 1, length: max(0, caret - opening - 1)))
    let segments = CompletionSyntaxUtilities.topLevelComponents(in: body, separatedBy: ",")
    var used = Set<String>()
    for segment in segments.dropLast() {
      if let equal = CompletionSyntaxUtilities.firstTopLevelIndex(of: "=", in: segment),
        let name = CompletionSyntaxUtilities.identifierWords(in: String(segment[..<equal])).last
      {
        used.insert(name.lowercased())
      }
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
      #"(?m)^\s*([\p{L}_][\p{L}\p{N}_]*)\s*:\s*([^=\n]+)(?:=|$)"#,
      #"(?m)^\s*([\p{L}_][\p{L}\p{N}_]*)\s*=\s*([\p{Lu}][\p{L}\p{N}_.]*)\s*\("#,
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
    let canonical = canonicalType(rawType)?.lowercased() ?? ""
    if canonical == "optional" || rawType?.contains("None") == true { return "None" }
    if canonical == "str" { return "\"\"" }
    if canonical == "bool" { return "False" }
    if ["int", "float", "complex"].contains(canonical) { return "0" }
    if ["list", "tuple", "set"].contains(canonical) { return "[]" }
    if canonical == "dict" { return "{}" }
    return "None"
  }

  func initializerInsertion(memberName: String, defaultExpression: String?) -> String {
    "\(memberName)=\(defaultExpression ?? "${1:None}")"
  }

  func rankingAdjustment(_ input: CompletionLanguageRankingInput) -> Int {
    var score = CompletionLanguageRankingDefaults.adjustment(input)
    if input.isMemberAccess {
      switch input.kind {
      case .method: score += 300
      case .property, .field: score += 130
      default: break
      }
    }
    return score
  }

  private func calledType(in header: String) -> String? {
    let pattern = #"([\p{Lu}][\p{L}\p{N}_]*(?:\.[\p{Lu}][\p{L}\p{N}_]*)*)\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: header, range: NSRange(location: 0, length: (header as NSString).length)),
      match.range(at: 1).location != NSNotFound
    else { return nil }
    return (header as NSString).substring(with: match.range(at: 1)).split(separator: ".").last.map(
      String.init)
  }
}
