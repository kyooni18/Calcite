import EditorCore
import EditorWorkspace
import Foundation

/// Summary of a dependency/library source-index refresh.
public struct ExternalSourceIndexReport: Hashable, Sendable {
  public var packageCount: Int
  public var indexedFileCount: Int
  public var reusedFileCount: Int
  public var skippedFileCount: Int
  public var removedFileCount: Int
  public var wasTruncated: Bool
  public var elapsedSeconds: Double

  public init(
    packageCount: Int = 0,
    indexedFileCount: Int = 0,
    reusedFileCount: Int = 0,
    skippedFileCount: Int = 0,
    removedFileCount: Int = 0,
    wasTruncated: Bool = false,
    elapsedSeconds: Double = 0
  ) {
    self.packageCount = packageCount
    self.indexedFileCount = indexedFileCount
    self.reusedFileCount = reusedFileCount
    self.skippedFileCount = skippedFileCount
    self.removedFileCount = removedFileCount
    self.wasTruncated = wasTruncated
    self.elapsedSeconds = elapsedSeconds
  }
}

struct ExternalIndexedSourceFile: Sendable {
  var file: SourceCodeFile
  var packageName: String
}

struct ExternalSourceIndexSnapshot: Sendable {
  var generation: Int
  var files: [ExternalIndexedSourceFile]
}

private struct ExternalSourceRoot: Hashable, Sendable {
  var url: URL
  var packageName: String
}

private struct ExternalSourceCandidate: Sendable {
  var url: URL
  var packageName: String
  var relativePath: String
  var languageID: String
  var byteCount: Int
  var modificationDate: Date?
}

private struct ExternalSourceEntry: Sendable {
  var file: SourceCodeFile
  var packageName: String
}

actor ExternalSourceIndex {
  private let workspaceURL: URL
  private let languageCatalog: EditorLanguageCatalog
  private let configuration: ExternalSourceIndexConfiguration?
  private let environment: [String: String]
  private var entries: [URL: ExternalSourceEntry] = [:]
  private var orderedFiles: [ExternalIndexedSourceFile] = []
  private var generation = 0
  private var hasRefreshed = false
  private var lastReport = ExternalSourceIndexReport()

  init(
    workspaceURL: URL,
    languageCatalog: EditorLanguageCatalog,
    configuration: ExternalSourceIndexConfiguration?,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.workspaceURL = workspaceURL.standardizedFileURL
    self.languageCatalog = languageCatalog
    self.configuration = configuration
    self.environment = environment
  }

  func files(refreshIfNeeded: Bool = true) async -> [ExternalIndexedSourceFile] {
    await snapshot(refreshIfNeeded: refreshIfNeeded).files
  }

  func snapshot(refreshIfNeeded: Bool = true) async -> ExternalSourceIndexSnapshot {
    if refreshIfNeeded, !hasRefreshed { _ = await refresh() }
    return ExternalSourceIndexSnapshot(generation: generation, files: orderedFiles)
  }

  func report() -> ExternalSourceIndexReport { lastReport }

  @discardableResult
  func refresh() async -> ExternalSourceIndexReport {
    guard !Task.isCancelled else { return lastReport }
    guard let configuration, configuration.isEnabled else {
      let removed = entries.count
      entries.removeAll()
      orderedFiles.removeAll()
      generation &+= 1
      hasRefreshed = true
      lastReport = .init(removedFileCount: removed)
      return lastReport
    }

    let started = Date()
    let oldEntries = entries
    let workspaceURL = workspaceURL
    let languageCatalog = languageCatalog
    let environment = environment
    let worker = Task.detached(priority: .utility) {
      Self.scan(
        workspaceURL: workspaceURL,
        languageCatalog: languageCatalog,
        configuration: configuration,
        environment: environment,
        oldEntries: oldEntries
      )
    }
    let output = await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
    guard !Task.isCancelled else { return lastReport }

    entries = output.entries
    orderedFiles = output.entries.values.map {
      ExternalIndexedSourceFile(file: $0.file, packageName: $0.packageName)
    }.sorted { $0.file.url.path.localizedStandardCompare($1.file.url.path) == .orderedAscending }
    generation &+= 1
    hasRefreshed = true
    lastReport = ExternalSourceIndexReport(
      packageCount: output.packageCount,
      indexedFileCount: output.entries.count,
      reusedFileCount: output.reusedCount,
      skippedFileCount: output.skippedCount,
      removedFileCount: oldEntries.keys.filter { output.entries[$0] == nil }.count,
      wasTruncated: output.wasTruncated,
      elapsedSeconds: max(0, Date().timeIntervalSince(started))
    )
    return lastReport
  }

  private struct ScanOutput: Sendable {
    var entries: [URL: ExternalSourceEntry]
    var packageCount: Int
    var reusedCount: Int
    var skippedCount: Int
    var wasTruncated: Bool
  }

  private static func scan(
    workspaceURL: URL,
    languageCatalog: EditorLanguageCatalog,
    configuration: ExternalSourceIndexConfiguration,
    environment: [String: String],
    oldEntries: [URL: ExternalSourceEntry]
  ) -> ScanOutput {
    let roots = discoverRoots(
      workspaceURL: workspaceURL,
      configuration: configuration,
      environment: environment
    )
    var candidates: [ExternalSourceCandidate] = []
    var skipped = 0
    var truncated = false

    for root in roots {
      guard !Task.isCancelled else {
        truncated = true
        break
      }
      guard candidates.count < configuration.maximumFileCount else {
        truncated = true
        break
      }
      let remaining = configuration.maximumFileCount - candidates.count
      let packageLimit = min(configuration.maximumFileCountPerPackage, remaining)
      let result = enumerate(
        root: root,
        languageCatalog: languageCatalog,
        configuration: configuration,
        limit: packageLimit
      )
      candidates.append(contentsOf: result.candidates)
      skipped += result.skipped
      truncated = truncated || result.wasTruncated
    }

    var next: [URL: ExternalSourceEntry] = [:]
    next.reserveCapacity(candidates.count)
    var reused = 0
    for candidate in candidates {
      guard !Task.isCancelled else {
        truncated = true
        break
      }
      let key = candidate.url.standardizedFileURL
      if let existing = oldEntries[key],
        existing.file.diskFingerprint?.byteCount == candidate.byteCount,
        existing.file.diskFingerprint?.modificationDate == candidate.modificationDate,
        existing.packageName == candidate.packageName
      {
        next[key] = existing
        reused += 1
        continue
      }
      guard let data = try? Data(contentsOf: key, options: [.mappedIfSafe]),
        data.count <= configuration.maximumFileSize,
        let decoded = decodeSource(data)
      else {
        skipped += 1
        continue
      }
      let normalized = decoded.text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
      let fingerprint = SourceDiskFingerprint(
        byteCount: data.count,
        contentHash: contentHash(data),
        modificationDate: candidate.modificationDate
      )
      let nextVersion = oldEntries[key].map { $0.file.version + 1 } ?? 0
      let file = SourceCodeFile(
        id: oldEntries[key]?.file.id ?? SourceFileID(),
        name: key.lastPathComponent,
        relativePath: candidate.relativePath,
        url: key,
        languageID: candidate.languageID,
        content: normalized,
        version: nextVersion,
        savedVersion: nextVersion,
        encoding: decoded.hasBOM ? .utf8WithByteOrderMark : .utf8,
        lineEnding: lineEnding(in: decoded.text),
        state: .clean,
        diskFingerprint: fingerprint
      )
      next[key] = ExternalSourceEntry(file: file, packageName: candidate.packageName)
    }

    return ScanOutput(
      entries: next,
      packageCount: roots.count,
      reusedCount: reused,
      skippedCount: skipped,
      wasTruncated: truncated || next.count >= configuration.maximumFileCount
    )
  }

  private struct CargoPackageCoordinate: Hashable, Sendable {
    var name: String
    var version: String?
  }

  private struct GoModuleCoordinate: Hashable, Sendable {
    var path: String
    var version: String
  }

  private static func discoverRoots(
    workspaceURL: URL,
    configuration: ExternalSourceIndexConfiguration,
    environment: [String: String]
  ) -> [ExternalSourceRoot] {
    let fileManager = FileManager.default
    let homeURL = homeDirectory(environment: environment)
    var roots: [ExternalSourceRoot] = []
    var seen: Set<URL> = []

    func add(_ url: URL, packageName: String? = nil) {
      let value = url.standardizedFileURL
      let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
      guard let resource = try? value.resourceValues(forKeys: keys),
        resource.isSymbolicLink != true,
        resource.isDirectory == true || resource.isRegularFile == true,
        seen.insert(value).inserted
      else { return }
      let label = packageName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let defaultLabel =
        resource.isRegularFile == true
        ? value.deletingPathExtension().lastPathComponent : value.lastPathComponent
      roots.append(
        ExternalSourceRoot(
          url: value,
          packageName: label?.isEmpty == false ? label! : defaultLabel
        )
      )
    }

    func addChildren(
      of container: URL,
      matching allowedNames: Set<String>? = nil,
      includesTopLevelSourceFiles: Bool = false
    ) {
      let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
      let values =
        (try? fileManager.contentsOfDirectory(
          at: container,
          includingPropertiesForKeys: Array(keys),
          options: [.skipsHiddenFiles]
        )) ?? []
      for child in values.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let resource = try? child.resourceValues(forKeys: keys)
        guard resource?.isSymbolicLink != true else { continue }
        if resource?.isDirectory == true {
          if let allowedNames, !allowedNames.isEmpty,
            !allowedNames.contains(normalizedPackageIdentity(child.lastPathComponent))
          {
            continue
          }
          add(child)
        } else if includesTopLevelSourceFiles, resource?.isRegularFile == true,
          ["py", "pyi"].contains(child.pathExtension.lowercased())
        {
          add(child, packageName: child.deletingPathExtension().lastPathComponent)
        }
      }
    }

    for explicit in configuration.explicitRootURLs { add(explicit) }
    for key in ["CALCITE_EXTERNAL_SOURCE_ROOTS", "EDITOR_EXTERNAL_SOURCE_ROOTS"] {
      for path in (environment[key] ?? "").split(separator: ":") {
        add(URL(fileURLWithPath: NSString(string: String(path)).expandingTildeInPath))
      }
    }
    guard configuration.discoversPackageRootsAutomatically else {
      return sortedRoots(roots)
    }

    // Monorepos often keep package manifests several directories below the opened root.
    // Discover them once and resolve every relative dependency from the owning manifest,
    // rather than incorrectly treating the workspace root as the base for all packages.
    let swiftManifests = manifestURLs(named: ["Package.swift"], under: workspaceURL)
    let cargoManifests = manifestURLs(named: ["Cargo.toml"], under: workspaceURL)
    let cargoLocks = manifestURLs(named: ["Cargo.lock"], under: workspaceURL)
    let nodeManifests = manifestURLs(named: ["package.json"], under: workspaceURL)
    let goManifests = manifestURLs(named: ["go.mod"], under: workspaceURL)
    let pythonManifests = manifestURLs(
      named: [
        "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile",
        "poetry.lock", "pdm.lock", "uv.lock", "hatch.toml", "pytest.ini", "tox.ini",
        "environment.yml", "environment.yaml",
      ],
      under: workspaceURL
    )

    // Project-local dependency layouts. These are preferred because their versions
    // exactly match the current workspace and they work without invoking a package manager.
    for relative in [
      ".build/checkouts", "SourcePackages/checkouts",
      ".calcite/DerivedData/SourcePackages/checkouts",
      "Carthage/Checkouts", "Pods", "Packages", "Vendor", "vendor",
      "ThirdParty", "third_party", "External", "external",
      "Dependencies", "dependencies",
    ] {
      addChildren(of: workspaceURL.appendingPathComponent(relative, isDirectory: true))
    }

    for manifest in swiftManifests {
      let packageRoot = manifest.deletingLastPathComponent()
      addChildren(of: packageRoot.appendingPathComponent(".build/checkouts", isDirectory: true))
      addChildren(
        of: packageRoot.appendingPathComponent("SourcePackages/checkouts", isDirectory: true)
      )
    }

    for dependency in localDependencyRoots(
      manifests: swiftManifests + cargoManifests
    ) {
      add(dependency.url, packageName: dependency.packageName)
    }

    // Xcode stores SwiftPM checkouts outside the project in DerivedData. Package.resolved
    // identities let us include only dependencies belonging to this workspace.
    let swiftIdentities = swiftPackageIdentities(in: workspaceURL)
    if !swiftIdentities.isEmpty {
      let derivedData =
        homeURL
        .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
      let projects =
        (try? fileManager.contentsOfDirectory(
          at: derivedData,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )) ?? []
      for project in projects {
        addChildren(
          of: project.appendingPathComponent("SourcePackages/checkouts", isDirectory: true),
          matching: swiftIdentities
        )
      }
    }

    for manifest in nodeManifests {
      let packageRoot = manifest.deletingLastPathComponent()
      let nodeModules = packageRoot.appendingPathComponent("node_modules", isDirectory: true)
      let nodeNames = nodeDependencyNames(inManifest: manifest)
      if nodeNames.isEmpty {
        addChildren(of: nodeModules)
      } else {
        for name in nodeNames {
          add(nodeModules.appendingPathComponent(name, isDirectory: true), packageName: name)
        }
      }
    }

    var pythonEnvironments: [URL] = []
    if let selected = environment["CALCITE_PYTHON_VENV"], !selected.isEmpty {
      // The resolver has already selected one environment. Do not mix project-local or inherited
      // environments into completion, because that can advertise packages unavailable at runtime.
      pythonEnvironments.append(URL(fileURLWithPath: selected, isDirectory: true))
    } else if let interpreter = environment["CALCITE_PYTHON_INTERPRETER"], !interpreter.isEmpty {
      let executable = URL(fileURLWithPath: interpreter).standardizedFileURL
      let bin = executable.deletingLastPathComponent()
      pythonEnvironments.append(
        ["bin", "Scripts"].contains(bin.lastPathComponent)
          ? bin.deletingLastPathComponent() : bin
      )
    } else {
      pythonEnvironments = [
        workspaceURL.appendingPathComponent(".venv", isDirectory: true),
        workspaceURL.appendingPathComponent("venv", isDirectory: true),
        workspaceURL.appendingPathComponent(".env", isDirectory: true),
        workspaceURL.appendingPathComponent("env", isDirectory: true),
      ]
      for manifest in pythonManifests {
        let packageRoot = manifest.deletingLastPathComponent()
        for name in [".venv", "venv", ".env", "env"] {
          pythonEnvironments.append(packageRoot.appendingPathComponent(name, isDirectory: true))
        }
      }
      for key in ["VIRTUAL_ENV", "CONDA_PREFIX"] {
        if let path = environment[key], !path.isEmpty {
          pythonEnvironments.append(URL(fileURLWithPath: path, isDirectory: true))
        }
      }
    }
    for root in Set(pythonEnvironments.map(\.standardizedFileURL)) {
      for sitePackages in pythonSitePackages(in: root) {
        addChildren(of: sitePackages, includesTopLevelSourceFiles: true)
      }
    }
    if environment["PYTHONNOUSERSITE"] != "1" {
      for root in pythonUserSitePackages(environment: environment) {
        addChildren(of: root, includesTopLevelSourceFiles: true)
      }
    }
    for path in (environment["PYTHONPATH"] ?? "").split(separator: ":") {
      add(URL(fileURLWithPath: String(path), isDirectory: true))
    }

    // Cargo.lock contains the complete resolved graph, not only direct Cargo.toml entries.
    // This makes transitive crates and renamed dependencies available to fallback completion.
    var cargoPackages = Set(cargoLocks.flatMap(cargoLockedPackages(inManifest:)))
    for name in cargoManifests.flatMap(cargoDependencyNames(inManifest:)) {
      cargoPackages.insert(CargoPackageCoordinate(name: name, version: nil))
    }
    let cargoHome = cargoHomeURL(environment: environment)
    for root in cargoRegistryRoots(packages: cargoPackages, cargoHome: cargoHome) {
      add(root.url, packageName: root.packageName)
    }
    let cargoNames = Set(cargoPackages.map { $0.name.lowercased() })
    for root in cargoGitCheckoutRoots(cargoHome: cargoHome, packageNames: cargoNames) {
      add(root.url, packageName: root.packageName)
    }

    for module in goManifests.flatMap(goModuleCoordinates(inManifest:)) {
      if let root = goModuleRoot(module, environment: environment) {
        add(root, packageName: module.path.split(separator: "/").last.map(String.init))
      }
    }

    // Compiler include paths are explicit user intent and often point at generated SDKs
    // or libraries that are not represented by a package-manager manifest.
    for key in ["CPATH", "CPLUS_INCLUDE_PATH", "C_INCLUDE_PATH", "OBJC_INCLUDE_PATH"] {
      for path in (environment[key] ?? "").split(separator: ":") {
        add(URL(fileURLWithPath: String(path), isDirectory: true))
      }
    }

    return sortedRoots(roots)
  }

  private static func sortedRoots(_ roots: [ExternalSourceRoot]) -> [ExternalSourceRoot] {
    roots.sorted {
      if $0.packageName != $1.packageName {
        return $0.packageName.localizedStandardCompare($1.packageName) == .orderedAscending
      }
      return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
    }
  }

  private static func normalizedPackageIdentity(_ value: String) -> String {
    var result = value.lowercased()
    if result.hasSuffix(".git") { result.removeLast(4) }
    return result.replacingOccurrences(of: "_", with: "-")
  }

  private static func manifestURLs(
    named names: Set<String>,
    under workspaceURL: URL,
    maximumDepth: Int = 6
  ) -> [URL] {
    let fileManager = FileManager.default
    let excludedDirectories: Set<String> = [
      ".git", ".build", "DerivedData", "node_modules", "target", "build", "dist",
      "Pods", "Carthage", "Vendor", "vendor", ".gradle", ".idea", ".cache",
    ]
    guard
      let enumerator = fileManager.enumerator(
        at: workspaceURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsPackageDescendants]
      )
    else { return [] }

    let baseDepth = workspaceURL.pathComponents.count
    var values: [URL] = []
    while let url = enumerator.nextObject() as? URL {
      let depth = url.pathComponents.count - baseDepth
      let resource = try? url.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
      )
      if resource?.isSymbolicLink == true {
        if resource?.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      if resource?.isDirectory == true {
        if depth >= maximumDepth || excludedDirectories.contains(url.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }
      if resource?.isRegularFile == true, names.contains(url.lastPathComponent) {
        values.append(url.standardizedFileURL)
      }
    }
    // The enumerator does not return the root itself as an object.
    for name in names {
      let rootManifest = workspaceURL.appendingPathComponent(name)
      if fileManager.fileExists(atPath: rootManifest.path) {
        values.append(rootManifest.standardizedFileURL)
      }
    }
    return Array(Set(values)).sorted {
      $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
  }

  private static func localDependencyRoots(
    manifests: [URL]
  ) -> [(url: URL, packageName: String?)] {
    var roots: [URL: String?] = [:]
    let patterns = [#"\bpath\s*:\s*\"([^\"]+)\""#, #"\bpath\s*=\s*\"([^\"]+)\""#]
    for manifest in manifests {
      guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
      let source = text as NSString
      for pattern in patterns {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
        for match in expression.matches(
          in: text, range: NSRange(location: 0, length: source.length)
        ) where match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
          let path = source.substring(with: match.range(at: 1))
          let url =
            (path as NSString).isAbsolutePath
            ? URL(fileURLWithPath: path, isDirectory: true)
            : manifest.deletingLastPathComponent().appendingPathComponent(path, isDirectory: true)
          let standardized = url.standardizedFileURL
          roots[standardized] = roots[standardized] ?? standardized.lastPathComponent
        }
      }
    }
    return roots.map { ($0.key, $0.value) }.sorted {
      $0.0.path.localizedStandardCompare($1.0.path) == .orderedAscending
    }
  }

  private static func packageResolvedURLs(in workspaceURL: URL) -> [URL] {
    var values = manifestURLs(named: ["Package.resolved"], under: workspaceURL, maximumDepth: 8)
    values.append(workspaceURL.appendingPathComponent("Package.resolved"))
    values.append(
      workspaceURL.appendingPathComponent(".swiftpm/configuration/Package.resolved")
    )
    return Array(Set(values.map(\.standardizedFileURL)))
  }

  private static func swiftPackageIdentities(in workspaceURL: URL) -> Set<String> {
    var identities: Set<String> = []
    for url in packageResolvedURLs(in: workspaceURL) {
      guard let data = try? Data(contentsOf: url),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      let pins =
        object["pins"] as? [[String: Any]]
        ?? (object["object"] as? [String: Any])?["pins"] as? [[String: Any]]
        ?? []
      for pin in pins {
        let value = pin["identity"] as? String ?? pin["package"] as? String
        if let value, !value.isEmpty { identities.insert(normalizedPackageIdentity(value)) }
      }
    }
    return identities
  }

  private static func nodeDependencyNames(inManifest url: URL) -> [String] {
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [] }
    var names: Set<String> = []
    for key in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
      guard let values = object[key] as? [String: Any] else { continue }
      names.formUnion(values.keys)
    }
    return names.sorted()
  }

  private static func cargoDependencyNames(inManifest url: URL) -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let packageExpression = try? NSRegularExpression(pattern: #"\bpackage\s*=\s*\"([^\"]+)\""#)
    var inDependencySection = false
    var names: Set<String> = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        let section = line.lowercased()
        inDependencySection =
          section == "[dependencies]"
          || section == "[dev-dependencies]"
          || section == "[build-dependencies]"
          || section == "[workspace.dependencies]"
          || section.hasSuffix(".dependencies]")
        continue
      }
      guard inDependencySection, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else {
        continue
      }
      let alias = line[..<equals].trimmingCharacters(in: .whitespaces)
      let source = String(line) as NSString
      let range = NSRange(location: 0, length: source.length)
      if let match = packageExpression?.firstMatch(in: String(line), range: range),
        match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound
      {
        names.insert(source.substring(with: match.range(at: 1)))
      } else if !alias.isEmpty {
        names.insert(alias)
      }
    }
    return names.sorted()
  }

  private static func cargoLockedPackages(inManifest url: URL) -> [CargoPackageCoordinate] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var packages: Set<CargoPackageCoordinate> = []
    var name: String?
    var version: String?

    func flush() {
      if let name, !name.isEmpty {
        packages.insert(CargoPackageCoordinate(name: name, version: version))
      }
      name = nil
      version = nil
    }

    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line == "[[package]]" {
        flush()
      } else if line.hasPrefix("name = ") {
        name = quotedTOMLValue(line)
      } else if line.hasPrefix("version = ") {
        version = quotedTOMLValue(line)
      }
    }
    flush()
    return packages.sorted {
      $0.name == $1.name ? ($0.version ?? "") < ($1.version ?? "") : $0.name < $1.name
    }
  }

  private static func quotedTOMLValue(_ line: String) -> String? {
    guard let first = line.firstIndex(of: "\"") else { return nil }
    let tail = line[line.index(after: first)...]
    guard let last = tail.firstIndex(of: "\"") else { return nil }
    return String(tail[..<last])
  }

  private static func homeDirectory(environment: [String: String]) -> URL {
    if let home = environment["HOME"], !home.isEmpty {
      return URL(
        fileURLWithPath: NSString(string: home).expandingTildeInPath,
        isDirectory: true
      ).standardizedFileURL
    }
    return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
  }

  private static func cargoHomeURL(environment: [String: String]) -> URL {
    if let configured = environment["CARGO_HOME"], !configured.isEmpty {
      return URL(
        fileURLWithPath: NSString(string: configured).expandingTildeInPath,
        isDirectory: true
      ).standardizedFileURL
    }
    return homeDirectory(environment: environment)
      .appendingPathComponent(".cargo", isDirectory: true)
  }

  private static func cargoRegistryRoots(
    packages: Set<CargoPackageCoordinate>,
    cargoHome: URL
  ) -> [(url: URL, packageName: String)] {
    guard !packages.isEmpty else { return [] }
    let registry = cargoHome.appendingPathComponent("registry/src", isDirectory: true)
    let indexes =
      (try? FileManager.default.contentsOfDirectory(
        at: registry, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
      )) ?? []
    var result: [(URL, String)] = []
    var seen: Set<URL> = []
    for index in indexes {
      let installed =
        (try? FileManager.default.contentsOfDirectory(
          at: index, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
      for package in packages {
        let exact = package.version.map { "\(package.name)-\($0)" }
        let matches = installed.filter { candidate in
          if let exact { return candidate.lastPathComponent == exact }
          return candidate.lastPathComponent == package.name
            || candidate.lastPathComponent.hasPrefix(package.name + "-")
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for match in matches.prefix(package.version == nil ? 1 : matches.count)
        where seen.insert(match.standardizedFileURL).inserted {
          result.append((match.standardizedFileURL, package.name))
        }
      }
    }
    return result
  }

  private static func cargoGitCheckoutRoots(
    cargoHome: URL,
    packageNames: Set<String>
  ) -> [(url: URL, packageName: String)] {
    guard !packageNames.isEmpty else { return [] }
    let checkouts = cargoHome.appendingPathComponent("git/checkouts", isDirectory: true)
    guard
      let enumerator = FileManager.default.enumerator(
        at: checkouts,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    let baseDepth = checkouts.pathComponents.count
    var output: [(URL, String)] = []
    var seen: Set<URL> = []
    while let url = enumerator.nextObject() as? URL, output.count < 512 {
      let depth = url.pathComponents.count - baseDepth
      if depth > 6 {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
          enumerator.skipDescendants()
        }
        continue
      }
      if ["target", ".git"].contains(url.lastPathComponent) {
        enumerator.skipDescendants()
        continue
      }
      guard url.lastPathComponent == "Cargo.toml",
        let name = cargoPackageName(in: url), packageNames.contains(name.lowercased())
      else { continue }
      let root = url.deletingLastPathComponent().standardizedFileURL
      if seen.insert(root).inserted { output.append((root, name)) }
      enumerator.skipDescendants()
    }
    return output
  }

  private static func cargoPackageName(in manifestURL: URL) -> String? {
    guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else { return nil }
    var inPackage = false
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        inPackage = line.lowercased() == "[package]"
        continue
      }
      if inPackage, line.hasPrefix("name = ") { return quotedTOMLValue(line) }
    }
    return nil
  }

  private static func pythonSitePackages(in environmentURL: URL) -> [URL] {
    let lib = environmentURL.appendingPathComponent("lib", isDirectory: true)
    let versions =
      (try? FileManager.default.contentsOfDirectory(
        at: lib, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
      )) ?? []
    return versions.flatMap { version in
      [
        version.appendingPathComponent("site-packages", isDirectory: true),
        version.appendingPathComponent("dist-packages", isDirectory: true),
      ]
    }
  }

  private static func pythonUserSitePackages(environment: [String: String]) -> [URL] {
    let home = homeDirectory(environment: environment)
    var roots: [URL] = []
    let macOSRoot = home.appendingPathComponent("Library/Python", isDirectory: true)
    let macVersions =
      (try? FileManager.default.contentsOfDirectory(
        at: macOSRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
      )) ?? []
    roots += macVersions.map { $0.appendingPathComponent("lib/python/site-packages") }

    let linuxRoot = home.appendingPathComponent(".local/lib", isDirectory: true)
    let linuxVersions =
      (try? FileManager.default.contentsOfDirectory(
        at: linuxRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
      )) ?? []
    roots += linuxVersions.flatMap {
      [
        $0.appendingPathComponent("site-packages"),
        $0.appendingPathComponent("dist-packages"),
      ]
    }
    return roots
  }

  private static func goModuleCoordinates(inManifest url: URL) -> [GoModuleCoordinate] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var values: Set<GoModuleCoordinate> = []
    var inRequireBlock = false
    for rawLine in text.split(whereSeparator: \.isNewline) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
      if line == "require (" {
        inRequireBlock = true
        continue
      }
      if inRequireBlock, line == ")" {
        inRequireBlock = false
        continue
      }
      if line.hasPrefix("require ") {
        line = String(line.dropFirst("require ".count))
      } else if !inRequireBlock {
        continue
      }
      let parts = line.split(whereSeparator: \.isWhitespace)
      guard parts.count >= 2 else { continue }
      values.insert(GoModuleCoordinate(path: String(parts[0]), version: String(parts[1])))
    }
    return values.sorted { $0.path < $1.path }
  }

  private static func goModuleRoot(
    _ module: GoModuleCoordinate,
    environment: [String: String]
  ) -> URL? {
    let cache: URL
    if let configured = environment["GOMODCACHE"], !configured.isEmpty {
      cache = URL(fileURLWithPath: configured, isDirectory: true)
    } else {
      let goPath =
        environment["GOPATH"].flatMap { $0.split(separator: ":").first.map(String.init) }
        ?? homeDirectory(environment: environment).appendingPathComponent("go").path
      cache = URL(fileURLWithPath: goPath, isDirectory: true)
        .appendingPathComponent("pkg/mod", isDirectory: true)
    }
    let escapedPath = goModuleCacheEscape(module.path)
    let escapedVersion = goModuleCacheEscape(module.version)
    let candidate = cache.appendingPathComponent(
      "\(escapedPath)@\(escapedVersion)", isDirectory: true)
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
      && isDirectory.boolValue ? candidate.standardizedFileURL : nil
  }

  private static func goModuleCacheEscape(_ value: String) -> String {
    var output = ""
    for scalar in value.unicodeScalars {
      if CharacterSet.uppercaseLetters.contains(scalar) {
        output.append("!")
        output.append(String(scalar).lowercased())
      } else {
        output.unicodeScalars.append(scalar)
      }
    }
    return output
  }

  private struct EnumerationOutput {
    var candidates: [ExternalSourceCandidate]
    var skipped: Int
    var wasTruncated: Bool
  }

  private static func enumerate(
    root: ExternalSourceRoot,
    languageCatalog: EditorLanguageCatalog,
    configuration: ExternalSourceIndexConfiguration,
    limit: Int
  ) -> EnumerationOutput {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      .contentModificationDateKey,
    ]
    guard let rootValues = try? root.url.resourceValues(forKeys: keys),
      rootValues.isSymbolicLink != true
    else { return .init(candidates: [], skipped: 1, wasTruncated: false) }

    if rootValues.isRegularFile == true {
      guard limit > 0,
        let candidate = candidate(
          for: root.url,
          values: rootValues,
          root: root,
          relativePath: root.url.lastPathComponent,
          languageCatalog: languageCatalog,
          configuration: configuration
        )
      else { return .init(candidates: [], skipped: 1, wasTruncated: limit == 0) }
      return .init(candidates: [candidate], skipped: 0, wasTruncated: false)
    }
    guard rootValues.isDirectory == true else {
      return .init(candidates: [], skipped: 1, wasTruncated: false)
    }

    let rootComponents = root.url.standardizedFileURL.pathComponents.count
    guard
      let enumerator = FileManager.default.enumerator(
        at: root.url,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else { return .init(candidates: [], skipped: 1, wasTruncated: false) }

    var output: [ExternalSourceCandidate] = []
    var skipped = 0
    var truncated = false
    while let url = enumerator.nextObject() as? URL {
      guard !Task.isCancelled else {
        truncated = true
        break
      }
      if output.count >= limit {
        truncated = true
        break
      }
      let depth = url.standardizedFileURL.pathComponents.count - rootComponents
      if depth > configuration.maximumDirectoryDepth {
        if (try? url.resourceValues(forKeys: keys).isDirectory) == true {
          enumerator.skipDescendants()
        }
        skipped += 1
        continue
      }
      guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true
      else {
        skipped += 1
        continue
      }
      if values.isDirectory == true {
        let lower = url.lastPathComponent.lowercased()
        if configuration.excludedDirectoryNames.contains(url.lastPathComponent)
          || configuration.excludedDirectoryNames.contains(lower)
          || (!configuration.includesTestsAndExamples
            && ["test", "tests", "spec", "specs", "example", "examples", "benchmark", "benchmarks"]
              .contains(lower))
          || lower.hasSuffix(".dist-info") || lower.hasSuffix(".egg-info")
        {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values.isRegularFile == true else { continue }
      let relative = relativePath(url, under: root.url)
      guard
        let value = candidate(
          for: url,
          values: values,
          root: root,
          relativePath: relative,
          languageCatalog: languageCatalog,
          configuration: configuration
        )
      else {
        skipped += 1
        continue
      }
      output.append(value)
    }
    return EnumerationOutput(candidates: output, skipped: skipped, wasTruncated: truncated)
  }

  private static func candidate(
    for url: URL,
    values: URLResourceValues,
    root: ExternalSourceRoot,
    relativePath: String,
    languageCatalog: EditorLanguageCatalog,
    configuration: ExternalSourceIndexConfiguration
  ) -> ExternalSourceCandidate? {
    let extensionValue = url.pathExtension.lowercased()
    guard configuration.includedFileExtensions.contains(extensionValue) else { return nil }
    let size = values.fileSize ?? 0
    guard size > 0, size <= configuration.maximumFileSize else { return nil }
    return ExternalSourceCandidate(
      url: url.standardizedFileURL,
      packageName: root.packageName,
      relativePath: "Libraries/\(root.packageName)/\(relativePath)",
      languageID: languageCatalog.languageID(forPath: relativePath),
      byteCount: size,
      modificationDate: values.contentModificationDate
    )
  }

  private static func relativePath(_ url: URL, under root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard path == rootPath || path.hasPrefix(rootPrefix) else { return url.lastPathComponent }
    return String(path.dropFirst(rootPath.count)).trimmingCharacters(
      in: CharacterSet(charactersIn: "/")
    )
  }

  private static func decodeSource(_ data: Data) -> (text: String, hasBOM: Bool)? {
    let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
    let content = bom ? data.dropFirst(3) : data[...]
    guard let text = String(data: content, encoding: .utf8) else { return nil }
    return (text, bom)
  }

  private static func contentHash(_ data: Data) -> UInt64 {
    data.reduce(1_469_598_103_934_665_603) { hash, byte in
      (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
  }

  private static func lineEnding(in text: String) -> SourceLineEnding {
    let hasCRLF = text.contains("\r\n")
    let withoutCRLF = text.replacingOccurrences(of: "\r\n", with: "")
    let hasLF = withoutCRLF.contains("\n")
    let hasCR = withoutCRLF.contains("\r")
    let count = [hasCRLF, hasLF, hasCR].filter { $0 }.count
    if count > 1 { return .mixed }
    if hasCRLF { return .carriageReturnLineFeed }
    if hasLF { return .lineFeed }
    if hasCR { return .carriageReturn }
    return .none
  }
}
