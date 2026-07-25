import EditorServices
import Foundation

struct EditorDebugProgramResolver {
  let workspaceURL: URL

  func resolve(configuredPath: String, projectKind: EditorProjectBuildKind) -> String? {
    let expanded = NSString(string: configuredPath).expandingTildeInPath
    if !expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let url = URL(fileURLWithPath: expanded, relativeTo: workspaceURL).standardizedFileURL
      if FileManager.default.isExecutableFile(atPath: url.path) { return url.path }
      if FileManager.default.fileExists(atPath: url.path) { return url.path }
    }

    let preferred: [URL]
    if projectKind == .rustCargo {
      preferred = cargoApplicationExecutables()
    } else {
      preferred = []
    }
    let candidates =
      (preferred
      + xcodeApplicationExecutables(projectKind: projectKind)
      + candidateDirectories(projectKind: projectKind).flatMap { directory in
        projectKind == .rustCargo
          ? directExecutables(in: directory)
          : executables(in: directory)
      })
      .filter { !Self.excludedExecutableNames.contains($0.lastPathComponent) }
      .reduce(into: [URL]()) { result, url in
        if !result.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
          result.append(url)
        }
      }
    return candidates.first?.path
  }

  private func candidateDirectories(projectKind: EditorProjectBuildKind) -> [URL] {
    var values: [URL] = []
    if projectKind == .swiftPackage {
      values += [
        ".build/debug", ".build/arm64-apple-macosx/debug", ".build/x86_64-apple-macosx/debug",
      ]
      .map { workspaceURL.appendingPathComponent($0) }
    }
    if projectKind == .rustCargo {
      values.append(workspaceURL.appendingPathComponent("target/debug"))
    }
    if projectKind == .zig {
      values.append(workspaceURL.appendingPathComponent("zig-out/bin"))
    }
    if projectKind == .cmake {
      values += ["build", "build/Debug"].map { workspaceURL.appendingPathComponent($0) }
    }
    values.append(workspaceURL.appendingPathComponent("bin"))
    return values
  }

  private func cargoApplicationExecutables() -> [URL] {
    let target = workspaceURL.appendingPathComponent("target/debug", isDirectory: true)
    let names = cargoBinaryNames()
    var values: [URL] = names.compactMap { name in
      let candidate = target.appendingPathComponent(name)
      return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }
    values.append(contentsOf: directExecutables(in: target).filter { candidate in
      let name = candidate.lastPathComponent
      return !name.hasSuffix(".d") && !name.hasSuffix(".rlib") && !name.hasSuffix(".rmeta")
    })
    return values.reduce(into: [URL]()) { result, url in
      if !result.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
        result.append(url)
      }
    }.sorted { lhs, rhs in
      let lhsNamed = names.contains(lhs.lastPathComponent)
      let rhsNamed = names.contains(rhs.lastPathComponent)
      if lhsNamed != rhsNamed { return lhsNamed }
      return modificationDate(lhs) > modificationDate(rhs)
    }
  }

  private func cargoBinaryNames() -> Set<String> {
    let fileManager = FileManager.default
    var manifests: [URL] = [workspaceURL.appendingPathComponent("Cargo.toml")]
    if let enumerator = fileManager.enumerator(
      at: workspaceURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants],
      errorHandler: nil
    ) {
      for case let url as URL in enumerator {
        let relativeDepth = url.pathComponents.count - workspaceURL.pathComponents.count
        if relativeDepth > 4 { enumerator.skipDescendants(); continue }
        if url.lastPathComponent == "Cargo.toml", url.standardizedFileURL != manifests[0].standardizedFileURL {
          manifests.append(url)
        }
      }
    }

    var names = Set<String>()
    for manifest in manifests {
      guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
      if let package = capture(
        #"(?ms)^\s*\[package\].*?^\s*name\s*=\s*[\"]([^\"]+)[\"]"#,
        in: text
      ) {
        names.insert(package)
      }
      if let regex = try? NSRegularExpression(
        pattern: #"(?ms)^\s*\[\[bin\]\].*?^\s*name\s*=\s*[\"]([^\"]+)[\"]"#
      ) {
        let source = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        where match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
          names.insert(source.substring(with: match.range(at: 1)))
        }
      }
    }
    return names
  }

  private func capture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: text,
        range: NSRange(location: 0, length: (text as NSString).length)
      ),
      match.numberOfRanges > 1,
      match.range(at: 1).location != NSNotFound
    else { return nil }
    return (text as NSString).substring(with: match.range(at: 1))
  }

  private func directExecutables(in directory: URL) -> [URL] {
    let values =
      (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )) ?? []
    return values.filter { url in
      guard let resource = try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
      else { return false }
      return resource.isRegularFile == true && resource.isExecutable == true
    }.sorted { modificationDate($0) > modificationDate($1) }
  }

  private func xcodeApplicationExecutables(projectKind: EditorProjectBuildKind) -> [URL] {
    guard projectKind == .xcode else { return [] }
    let root = workspaceURL.appendingPathComponent(
      ".calcite/DerivedData/Build/Products",
      isDirectory: true
    )
    guard
      let configurations = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    let entries =
      configurations
      .filter { $0.lastPathComponent == "Debug" || $0.lastPathComponent.hasPrefix("Debug-") }
      .flatMap { configuration in
        (try? FileManager.default.contentsOfDirectory(
          at: configuration,
          includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
          options: [.skipsHiddenFiles]
        )) ?? []
      }

    return entries.compactMap { bundle in
      guard bundle.pathExtension == "app" else { return nil }
      let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
      let executableName: String
      if let data = try? Data(contentsOf: infoURL),
        let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dictionary = object as? [String: Any],
        let configured = dictionary["CFBundleExecutable"] as? String,
        !configured.isEmpty
      {
        executableName = configured
      } else {
        executableName = bundle.deletingPathExtension().lastPathComponent
      }
      let executable = bundle.appendingPathComponent("Contents/MacOS/\(executableName)")
      return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }
  }

  private func executables(in directory: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [
          .isRegularFileKey, .isExecutableKey, .contentModificationDateKey,
        ],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return [] }
    var values: [URL] = []
    for case let url as URL in enumerator {
      guard values.count < 200,
        let resource = try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey]),
        resource.isRegularFile == true,
        resource.isExecutable == true
      else { continue }
      values.append(url)
    }
    return values
  }

  private func modificationDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
  }

  private static let excludedExecutableNames: Set<String> = [
    "swift-build", "swift-test", "swift-run", "build-script-build", "build-script-build-tool",
  ]
}
