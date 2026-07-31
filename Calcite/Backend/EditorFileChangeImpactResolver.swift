import EditorServices
import Foundation

nonisolated enum EditorFileChangeImpact: Equatable, Sendable {
  case ignore
  case resourceReload
  case rebuildTargets(Set<String>)
  case rebuildDependents(Set<String>)
  case projectGraphReload
  case debuggerRestartOnly
}

nonisolated enum EditorFileChangeImpactResolver {
  private static let ignoredDirectories: Set<String> = [
    ".git", ".svn", ".hg", ".build", "build", "DerivedData", "node_modules",
    "target", ".swiftpm", "Pods", ".venv", "venv", ".idea", ".vscode",
    ".gradle", ".cache", "dist", "coverage",
  ]

  private static let projectGraphFiles: Set<String> = [
    "Package.swift", "Package.resolved", "Cargo.toml", "Cargo.lock", "go.mod", "go.sum",
    "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "tsconfig.json",
    "pyproject.toml", "requirements.txt", "Pipfile", "poetry.lock", "build.gradle",
    "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "pom.xml",
    "CMakeLists.txt", "Makefile", "build.zig", "pubspec.yaml",
  ]

  private static let resourceExtensions: Set<String> = [
    "json", "plist", "xml", "yaml", "yml", "toml", "xcassets", "storyboard", "xib",
    "png", "jpg", "jpeg", "gif", "webp", "svg", "metal", "glsl", "vert", "frag",
    "strings", "stringsdict", "css", "html",
  ]

  static func resolve(
    changedURL: URL,
    workspaceURL: URL,
    launchTarget: EditorDebugLaunchTarget
  ) -> EditorFileChangeImpact {
    let file = changedURL.standardizedFileURL
    let root = workspaceURL.standardizedFileURL
    let relativeComponents = relativePathComponents(of: file, under: root)
    if relativeComponents.contains(where: ignoredDirectories.contains) { return .ignore }
    let name = file.lastPathComponent
    if name == ".DS_Store" || name.hasSuffix("~") || name.hasPrefix(".#") { return .ignore }
    if projectGraphFiles.contains(name) { return .projectGraphReload }

    if case .currentFile(let targetURL) = launchTarget,
      !belongsToProjectContext(targetURL, root: root),
      file != targetURL.standardizedFileURL
    {
      return .ignore
    }

    if resourceExtensions.contains(file.pathExtension.lowercased()) {
      return .resourceReload
    }

    if let target = swiftPMTarget(for: file, root: root) {
      let affected = swiftPMAffectedTargets(startingAt: target, root: root)
      return affected.count <= 1 ? .rebuildTargets([target]) : .rebuildDependents(affected)
    }
    if let crate = cargoCrate(for: file, root: root) {
      let affected = cargoAffectedCrates(startingAt: crate, root: root)
      return affected.count <= 1 ? .rebuildTargets([crate]) : .rebuildDependents(affected)
    }
    if belongsToProjectContext(file, root: root) {
      return .rebuildTargets([root.lastPathComponent])
    }
    return .ignore
  }

  private static func relativePathComponents(of file: URL, under root: URL) -> [String] {
    guard belongsToProjectContext(file, root: root) else { return file.pathComponents }
    let relative = String(file.path.dropFirst(root.path.count))
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return relative.split(separator: "/").map(String.init)
  }

  private static func belongsToProjectContext(_ file: URL, root: URL) -> Bool {
    let path = file.standardizedFileURL.path
    return path == root.path || path.hasPrefix(root.path + "/")
  }

  private static func swiftPMTarget(for file: URL, root: URL) -> String? {
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
      belongsToProjectContext(file, root: root)
    else { return nil }
    let relative = file.path.dropFirst(root.path.count)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let parts = relative.split(separator: "/").map(String.init)
    guard parts.count >= 2, parts[0] == "Sources" || parts[0] == "Tests" else { return nil }
    return parts[1]
  }

  private static func swiftPMAffectedTargets(startingAt target: String, root: URL) -> Set<String> {
    guard
      let text = try? String(
        contentsOf: root.appendingPathComponent("Package.swift"),
        encoding: .utf8
      )
    else { return [target] }
    let graph = swiftPMDependencyGraph(in: text)
    return transitiveReverseDependencies(of: target, graph: graph)
  }

  /// Extracts target declarations using balanced parentheses instead of one broad regular
  /// expression. This tolerates multiline manifests and nested `.product`/`.target` entries.
  private static func swiftPMDependencyGraph(in source: String) -> [String: Set<String>] {
    let declarationMarkers = [".target(", ".executableTarget(", ".testTarget(", ".macro("]
    var graph: [String: Set<String>] = [:]
    for marker in declarationMarkers {
      var searchStart = source.startIndex
      while let range = source.range(of: marker, range: searchStart..<source.endIndex) {
        let open = source.index(before: range.upperBound)
        guard let close = matchingDelimiter(in: source, open: open, opening: "(", closing: ")")
        else { break }
        let body = String(source[source.index(after: open)..<close])
        if let name = capture(#"\bname\s*:\s*\"([^\"]+)\""#, in: body) {
          let dependenciesBody = labeledArray(named: "dependencies", in: body) ?? ""
          let quoted = captures(#"\"([^\"]+)\""#, in: dependenciesBody)
          let named = captures(
            #"(?:\.target|\.byName)\s*\(\s*name\s*:\s*\"([^\"]+)\""#, in: dependenciesBody)
          // Product dependencies can share names with local targets, so they are retained only
          // when a corresponding target declaration exists after the complete graph is parsed.
          graph[name, default: []].formUnion(quoted + named)
        }
        searchStart = source.index(after: close)
      }
    }
    let known = Set(graph.keys)
    return graph.mapValues { $0.intersection(known) }
  }

  private static func cargoCrate(for file: URL, root: URL) -> String? {
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Cargo.toml").path),
      belongsToProjectContext(file, root: root)
    else { return nil }
    var current = file.deletingLastPathComponent()
    while current.path.hasPrefix(root.path) {
      let manifest = current.appendingPathComponent("Cargo.toml")
      if let text = try? String(contentsOf: manifest, encoding: .utf8),
        let name = capture(#"(?ms)^\s*\[package\].*?^\s*name\s*=\s*\"([^\"]+)\""#, in: text)
      {
        return name
      }
      if current.path == root.path { break }
      current = current.deletingLastPathComponent()
    }
    return root.lastPathComponent
  }

  private static func cargoAffectedCrates(startingAt crate: String, root: URL) -> Set<String> {
    let graph = cargoDependencyGraph(root: root)
    return transitiveReverseDependencies(of: crate, graph: graph)
  }

  private static func cargoDependencyGraph(root: URL) -> [String: Set<String>] {
    let fileManager = FileManager.default
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return [:] }
    var manifests: [(name: String, text: String)] = []
    for case let url as URL in enumerator {
      if ignoredDirectories.contains(url.lastPathComponent) {
        enumerator.skipDescendants()
        continue
      }
      guard url.lastPathComponent == "Cargo.toml",
        let text = try? String(contentsOf: url, encoding: .utf8),
        let name = capture(#"(?ms)^\s*\[package\].*?^\s*name\s*=\s*\"([^\"]+)\""#, in: text)
      else { continue }
      manifests.append((name, text))
    }
    let known = Set(manifests.map(\.name))
    var graph: [String: Set<String>] = [:]
    for manifest in manifests {
      var dependencies: Set<String> = []
      var activeDependencySection = false
      for rawLine in manifest.text.components(separatedBy: .newlines) {
        let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
          activeDependencySection =
            trimmed.range(
              of: #"^\[(?:dev-|build-)?dependencies(?:\.[^\]]+)?\]$"#,
              options: .regularExpression
            ) != nil || trimmed.contains(".dependencies]")
          continue
        }
        guard activeDependencySection,
          let dependency = capture(#"^\s*([A-Za-z0-9_-]+)\s*="#, in: line)
        else { continue }
        dependencies.insert(dependency)
      }
      graph[manifest.name] = dependencies.intersection(known)
    }
    return graph
  }

  private static func transitiveReverseDependencies(
    of target: String,
    graph: [String: Set<String>]
  ) -> Set<String> {
    var affected: Set<String> = [target]
    var queue = [target]
    while let current = queue.first {
      queue.removeFirst()
      for (candidate, dependencies) in graph where dependencies.contains(current) {
        if affected.insert(candidate).inserted { queue.append(candidate) }
      }
    }
    return affected
  }

  private static func labeledArray(named label: String, in text: String) -> String? {
    guard
      let labelRange = text.range(
        of: #"\b"# + NSRegularExpression.escapedPattern(for: label) + #"\s*:"#,
        options: .regularExpression
      ),
      let open = text[labelRange.upperBound...].firstIndex(of: "["),
      let close = matchingDelimiter(in: text, open: open, opening: "[", closing: "]")
    else { return nil }
    return String(text[text.index(after: open)..<close])
  }

  private static func matchingDelimiter(
    in text: String,
    open: String.Index,
    opening: Character,
    closing: Character
  ) -> String.Index? {
    var depth = 0
    var quote: Character?
    var escaped = false
    var index = open
    while index < text.endIndex {
      let character = text[index]
      if let currentQuote = quote {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == currentQuote {
          quote = nil
        }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character == opening {
        depth += 1
      } else if character == closing {
        depth -= 1
        if depth == 0 { return index }
      }
      index = text.index(after: index)
    }
    return nil
  }

  private static func capture(_ pattern: String, in text: String) -> String? {
    captures(pattern, in: text).first
  }

  private static func captures(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let source = text as NSString
    return regex.matches(
      in: text,
      range: NSRange(location: 0, length: source.length)
    ).compactMap { match in
      guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
      return source.substring(with: match.range(at: 1))
    }
  }
}
