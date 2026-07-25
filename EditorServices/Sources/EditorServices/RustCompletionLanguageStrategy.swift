import EditorCore
import Foundation

struct RustCompletionLanguageStrategy: CompletionLanguageStrategy {
  let languageIDs: Set<String> = ["rust"]

  func initializerContext(
    in text: String,
    caretUTF16Offset: Int
  ) -> CompletionInitializerContext? {
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
    guard let typeName = structLiteralType(in: header) else { return nil }

    let body = source.substring(
      with: NSRange(location: opening + 1, length: max(0, caret - opening - 1))
    )
    let segments = CompletionSyntaxUtilities.topLevelComponents(in: body, separatedBy: ",")
    var used = Set<String>()
    for segment in segments.dropLast() {
      if let field = fieldName(in: segment) { used.insert(field.lowercased()) }
    }

    let current = segments.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let colon = CompletionSyntaxUtilities.firstTopLevelIndex(of: ":", in: current) {
      let left = String(current[..<colon])
      guard let field = CompletionSyntaxUtilities.identifierWords(in: left).last else { return nil }
      used.insert(field.lowercased())
      return CompletionInitializerContext(
        typeName: typeName,
        usedMembers: used,
        position: .memberValue(memberName: field)
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
    var values: [String: CompletionVisibleBinding] = [:]

    for (name, type) in lexicalTypes {
      values[name.lowercased()] = CompletionVisibleBinding(
        name: name, typeName: canonicalType(type))
    }

    let patterns: [(String, Int, Int?)] = [
      (#"\blet\s+(?:mut\s+)?([\p{L}_][\p{L}\p{N}_]*)\s*:\s*([^=;\n]+)"#, 1, 2),
      (
        #"\blet\s+(?:mut\s+)?([\p{L}_][\p{L}\p{N}_]*)\s*=\s*(?:(?:[\p{L}_][\p{L}\p{N}_]*::)*)([\p{Lu}][\p{L}\p{N}_]*)\s*(?:::|\{|\()"#,
        1,
        2
      ),
    ]
    consumeBindings(patterns: patterns, in: prefix, values: &values)
    return CompletionSyntaxUtilities.sortedBindings(values)
  }

  func canonicalType(_ raw: String?) -> String? {
    CompletionSyntaxUtilities.canonicalNominalType(raw)
  }

  func defaultExpression(for rawType: String?) -> String {
    guard let type = rawType?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty
    else { return "Default::default()" }
    let canonical = canonicalType(type)?.lowercased() ?? ""
    if type.hasPrefix("Option<") || canonical == "option" { return "None" }
    if type.hasPrefix("Vec<") || canonical == "vec" { return "Vec::new()" }
    if canonical == "string" { return "String::new()" }
    if canonical == "bool" { return "false" }
    if numericTypes.contains(canonical) { return "0" }
    if type.hasPrefix("&str") || canonical == "str" { return "\"\"" }
    if type.hasPrefix("&[") { return "&[]" }
    return "Default::default()"
  }

  func initializerInsertion(memberName: String, defaultExpression: String?) -> String {
    let value = defaultExpression ?? "${1:Default::default()}"
    return "\(memberName): \(value)"
  }

  func rankingAdjustment(_ input: CompletionLanguageRankingInput) -> Int {
    var score = CompletionLanguageRankingDefaults.adjustment(input)
    if input.isMemberAccess {
      if input.isStaticReceiver {
        switch input.kind {
        case .constructor: score += 430
        case .method, .function: score += 300
        case .enumMember, .constant: score += 180
        case .field, .property: score -= 100
        default: break
        }
      } else {
        switch input.kind {
        case .method: score += 430
        case .field, .property: score += 100
        case .function: score -= 80
        default: break
        }
      }
    }
    return score
  }

  private let numericTypes: Set<String> = [
    "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128",
    "isize", "f32", "f64",
  ]

  private func structLiteralType(in header: String) -> String? {
    let pattern = #"(?:(?:[\p{L}_][\p{L}\p{N}_]*::)*)([\p{Lu}][\p{L}\p{N}_]*)\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: header,
        range: NSRange(location: 0, length: (header as NSString).length)
      ),
      match.numberOfRanges > 1,
      match.range(at: 1).location != NSNotFound
    else { return nil }
    let candidate = (header as NSString).substring(with: match.range(at: 1))
    let prefixRange = NSRange(location: 0, length: match.range.location)
    let preceding = (header as NSString).substring(with: prefixRange)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if ["struct", "enum", "impl", "trait", "fn"].contains(where: { preceding.hasSuffix($0) }) {
      return nil
    }
    return candidate
  }

  private func fieldName(in value: String) -> String? {
    if let colon = CompletionSyntaxUtilities.firstTopLevelIndex(of: ":", in: value) {
      return CompletionSyntaxUtilities.identifierWords(in: String(value[..<colon])).last
    }
    return CompletionSyntaxUtilities.identifierWords(in: value).last
  }

  private func consumeBindings(
    patterns: [(String, Int, Int?)],
    in text: String,
    values: inout [String: CompletionVisibleBinding]
  ) {
    let source = text as NSString
    for (pattern, nameGroup, typeGroup) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        guard match.numberOfRanges > nameGroup, match.range(at: nameGroup).location != NSNotFound
        else { continue }
        let name = source.substring(with: match.range(at: nameGroup))
        let type = typeGroup.flatMap { group -> String? in
          guard match.numberOfRanges > group, match.range(at: group).location != NSNotFound else {
            return nil
          }
          return canonicalType(source.substring(with: match.range(at: group)))
        }
        values[name.lowercased()] = CompletionVisibleBinding(name: name, typeName: type)
      }
    }
  }
}
