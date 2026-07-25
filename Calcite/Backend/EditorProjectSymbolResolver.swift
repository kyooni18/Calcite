import EditorServices
import Foundation

actor EditorProjectSymbolResolver {
  private let workspaceURL: URL
  private var cachedFiles: [URL]?
  private var cacheTimestamp = ContinuousClock.now

  init(workspaceURL: URL) {
    self.workspaceURL = workspaceURL.standardizedFileURL
  }

  func definitionLocations(
    for symbol: String,
    originatingURL: URL,
    inMemoryDocuments: [URL: String] = [:]
  ) async -> [SourceLocation] {
    guard let expression = Self.definitionExpression(for: symbol) else { return [] }
    let files = sourceFiles(prioritizing: originatingURL)
    var results: [SourceLocation] = []

    for file in files {
      if Task.isCancelled { return [] }
      guard let text = Self.text(for: file, inMemoryDocuments: inMemoryDocuments) else {
        continue
      }
      let fullRange = NSRange(location: 0, length: (text as NSString).length)
      for match in expression.matches(in: text, range: fullRange) {
        guard match.numberOfRanges > 1 else { continue }
        let symbolRange = match.range(at: 1)
        guard symbolRange.location != NSNotFound,
          let location = Self.location(url: file, text: text, range: symbolRange)
        else { continue }
        results.append(location)
        if results.count >= 32 { return results }
      }
    }
    return results
  }

  func referenceLocations(
    for symbol: String,
    originatingURL: URL,
    inMemoryDocuments: [URL: String] = [:]
  ) async -> [SourceLocation] {
    guard let expression = Self.referenceExpression(for: symbol) else { return [] }
    let files = sourceFiles(prioritizing: originatingURL)
    var results: [SourceLocation] = []

    for file in files {
      if Task.isCancelled { return [] }
      guard let text = Self.text(for: file, inMemoryDocuments: inMemoryDocuments) else {
        continue
      }
      let fullRange = NSRange(location: 0, length: (text as NSString).length)
      for match in expression.matches(in: text, range: fullRange) {
        guard let location = Self.location(url: file, text: text, range: match.range) else {
          continue
        }
        results.append(location)
        if results.count >= 250 { return results }
      }
    }
    return results
  }

  func invalidate() {
    cachedFiles = nil
    cacheTimestamp = .now
  }

  private func sourceFiles(prioritizing originatingURL: URL) -> [URL] {
    let files: [URL]
    if let cachedFiles,
      cacheTimestamp.duration(to: .now) < .seconds(2)
    {
      files = cachedFiles
    } else {
      files = Self.scanSourceFiles(in: workspaceURL)
      cachedFiles = files
      cacheTimestamp = .now
    }

    let origin = originatingURL.standardizedFileURL
    return files.sorted { lhs, rhs in
      if lhs == origin { return true }
      if rhs == origin { return false }
      return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
  }

  nonisolated private static func scanSourceFiles(in root: URL) -> [URL] {
    guard let scan = try? ProjectFileScanner.scan(rootURL: root) else { return [] }
    return scan.files.lazy.filter { url in
      guard Self.sourceExtensions.contains(url.pathExtension.lowercased()) else { return false }
      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
      return (size ?? 0) <= Self.maximumFileSize
    }.prefix(Self.maximumFileCount).map { $0 }
  }

  nonisolated private static func text(
    for url: URL,
    inMemoryDocuments: [URL: String]
  ) -> String? {
    if let value = inMemoryDocuments[url.standardizedFileURL] { return value }
    return readSourceFile(url)
  }

  nonisolated private static func readSourceFile(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
      data.count <= maximumFileSize
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  nonisolated private static func definitionExpression(
    for symbol: String
  ) -> NSRegularExpression? {
    let escaped = NSRegularExpression.escapedPattern(for: symbol)
    let attributes =
      #"(?:(?:@[A-Za-z_][A-Za-z0-9_.]*(?:\([^\n]*\))?)\s+)*"#
    let modifiers =
      #"(?:(?:public|private|fileprivate|internal|open|final|static|class|mutating|nonmutating|override|convenience|required|async|throws|rethrows|export|default|abstract|sealed|partial|data|suspend|inline|pub(?:\([^\n)]*\))?)\s+)*"#
    let declarationKeywords =
      #"(?:class|struct|enum|protocol|actor|extension|typealias|associatedtype|func|fn|fun|var|let|const|subscript|macro|interface|record|object|function|type|namespace|trait|impl|def|module|union)"#
    let pattern =
      #"(?m)^[\t ]*"# + attributes + #"\b"# + modifiers + declarationKeywords
      + #"\s+[`]?("# + escaped + #")[`]?\b"#
    return try? NSRegularExpression(pattern: pattern)
  }

  nonisolated private static func referenceExpression(
    for symbol: String
  ) -> NSRegularExpression? {
    let escaped = NSRegularExpression.escapedPattern(for: symbol)
    return try? NSRegularExpression(
      pattern: "(?<![\\p{L}\\p{N}_])(" + escaped + ")(?![\\p{L}\\p{N}_])")
  }

  nonisolated private static func location(
    url: URL,
    text: String,
    range: NSRange
  ) -> SourceLocation? {
    let snapshot = TextSnapshot(text: text)
    guard let start = try? snapshot.position(atUTF16Offset: range.location),
      let end = try? snapshot.position(atUTF16Offset: NSMaxRange(range))
    else { return nil }
    return SourceLocation(
      uri: url,
      range: EditorTextRange(start: start, end: end)
    )
  }

  nonisolated private static let maximumFileSize = 2_000_000
  nonisolated private static let maximumFileCount = 20_000
  nonisolated private static let sourceExtensions: Set<String> = [
    "swift", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "rs", "go",
    "py", "pyi", "js", "jsx", "ts", "tsx", "java", "kt", "kts", "cs", "rb", "php",
    "scala", "sc", "zig", "lua", "sh", "bash", "zsh", "fish", "sql",
  ]
}
