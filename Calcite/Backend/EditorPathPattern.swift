import Foundation

nonisolated enum EditorPathPattern {
  static func matches(path: String, pattern: String, relativeTo root: URL) -> Bool {
    let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { return false }
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    let relative =
      standardized.hasPrefix(rootPath + "/")
      ? String(standardized.dropFirst(rootPath.count + 1))
      : standardized
    let candidate = pattern.hasPrefix("/") ? standardized : relative
    let regex =
      "^"
      + NSRegularExpression.escapedPattern(for: pattern)
      .replacingOccurrences(of: #"\\*\\*"#, with: ".*")
      .replacingOccurrences(of: #"\\*"#, with: "[^/]*")
      .replacingOccurrences(of: #"\\?"#, with: "[^/]") + "$"
    return candidate.range(of: regex, options: .regularExpression) != nil
      || candidate.split(separator: "/").contains { component in
        String(component).range(of: regex, options: .regularExpression) != nil
      }
  }
}
