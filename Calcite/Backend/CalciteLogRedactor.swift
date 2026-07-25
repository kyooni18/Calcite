import Foundation

nonisolated enum CalciteLogRedactor {
  private static let sensitiveKeyFragments = [
    "authorization", "cookie", "credential", "password", "passwd", "secret", "token",
    "api_key", "apikey", "private_key", "access_key",
  ]

  static func sanitize(message: String) -> String {
    var result = message.replacingOccurrences(
      of: FileManager.default.homeDirectoryForCurrentUser.path,
      with: "~"
    )
    let patterns = [
      #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#,
      #"\b(?:sk|pk)-[A-Za-z0-9_-]{12,}\b"#,
      #"(?i)\b(?:authorization|cookie|credential|password|passwd|secret|token|api[_-]?key|private[_-]?key|access[_-]?key)\s*[:=]\s*[^\s,;]+"#,
    ]
    for pattern in patterns {
      result = replacingMatches(in: result, pattern: pattern, with: "<redacted>")
    }
    return truncated(result, limit: 16_384)
  }

  static func sanitize(metadata: [String: String]) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: metadata.map { key, value in
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        let isSensitive = sensitiveKeyFragments.contains { normalized.contains($0) }
        return (key, isSensitive ? "<redacted>" : truncated(sanitize(message: value), limit: 4_096))
      })
  }

  private static func replacingMatches(
    in value: String,
    pattern: String,
    with replacement: String
  ) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.stringByReplacingMatches(
      in: value, range: range, withTemplate: replacement
    )
  }

  private static func truncated(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    return String(value.prefix(limit)) + "… <truncated>"
  }
}
