import EditorServices
import Foundation

nonisolated enum EditorArtifactResolverKind: String, Sendable {
  case explicitOutput
  case swiftPackage
  case cargo
  case xcode
  case interpretedEntry
  case directExecutable
  case customTask
  case cmake
  case gradle
  case maven
  case go
  case zig
}

nonisolated struct EditorResolvedArtifact: Equatable, Sendable {
  let executableURL: URL
  let debugSymbolsURL: URL?
  let architecture: String?
  let productName: String?
  let resolver: EditorArtifactResolverKind
}

nonisolated enum EditorArtifactResolver {
  static func resolve(
    command: EditorBuildCommand,
    projectKind: EditorProjectBuildKind,
    buildProjectURL: URL,
    buildOutput: String = "",
    sourceSnapshot: EditorPreparedSourceSnapshot? = nil
  ) async -> EditorResolvedArtifact? {
    await Task.detached(priority: .utility) {
      guard
        let candidate = resolveSynchronously(
          command: command,
          projectKind: projectKind,
          buildProjectURL: buildProjectURL.standardizedFileURL,
          buildOutput: buildOutput
        )
      else { return nil }
      return isFresh(
        candidate,
        for: sourceSnapshot,
        command: command
      ) ? candidate : nil
    }.value
  }

  private static func resolveSynchronously(
    command: EditorBuildCommand,
    projectKind: EditorProjectBuildKind,
    buildProjectURL: URL,
    buildOutput: String
  ) -> EditorResolvedArtifact? {
    if let configured = command.artifactPath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !configured.isEmpty
    {
      let url = URL(
        fileURLWithPath: NSString(string: configured).expandingTildeInPath,
        relativeTo: command.workingDirectory
      ).standardizedFileURL
      if isExecutable(url) { return artifact(url, resolver: .customTask) }
      return nil
    }
    if let explicit = explicitOutput(in: command), isExecutable(explicit) {
      return artifact(explicit, resolver: .explicitOutput)
    }

    if command.kind == .run {
      let direct = URL(
        fileURLWithPath: command.executable,
        relativeTo: command.workingDirectory
      ).standardizedFileURL
      if command.executable.contains("/"), isExecutable(direct) {
        return artifact(direct, resolver: .directExecutable)
      }
      if let entry = interpretedEntry(in: command),
        FileManager.default.fileExists(atPath: entry.path)
      {
        return EditorResolvedArtifact(
          executableURL: entry,
          debugSymbolsURL: nil,
          architecture: nil,
          productName: entry.lastPathComponent,
          resolver: .interpretedEntry
        )
      }
    }

    switch projectKind {
    case .swiftPackage:
      return resolveSwiftPackage(command: command, root: buildProjectURL)
    case .rustCargo:
      return resolveCargo(command: command, root: buildProjectURL, buildOutput: buildOutput)
    case .xcode:
      return resolveXcode(command: command, root: buildProjectURL)
    case .cmake:
      return resolveCMake(root: buildProjectURL)
    case .gradle:
      return resolveGradle(root: buildProjectURL)
    case .maven:
      return resolveMaven(root: buildProjectURL)
    case .goModule:
      return resolveGo(command: command, root: buildProjectURL)
    case .zig:
      return resolveZig(command: command, root: buildProjectURL)
    case .nodePackage, .python, .make, .generic:
      return nil
    }
  }

  private static func explicitOutput(in command: EditorBuildCommand) -> URL? {
    let arguments = command.arguments
    for (index, value) in arguments.enumerated() {
      if value == "-o", arguments.indices.contains(index + 1) {
        return URL(fileURLWithPath: arguments[index + 1], relativeTo: command.workingDirectory)
          .standardizedFileURL
      }
      if value.hasPrefix("-femit-bin=") {
        return URL(
          fileURLWithPath: String(value.dropFirst("-femit-bin=".count)),
          relativeTo: command.workingDirectory
        ).standardizedFileURL
      }
      if value.hasPrefix("--out:") {
        return URL(
          fileURLWithPath: String(value.dropFirst("--out:".count)),
          relativeTo: command.workingDirectory
        ).standardizedFileURL
      }
    }
    return nil
  }

  private static func interpretedEntry(in command: EditorBuildCommand) -> URL? {
    let extensions: Set<String> = [
      "py", "pyw", "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts",
      "lua", "rb", "php", "sh", "bash", "zsh", "fish", "pl", "pm", "r",
      "rmd", "dart", "jl", "hs", "lhs", "ml", "ex", "exs", "erl", "scala",
      "sc", "clj", "cljs", "cljc", "groovy", "fs", "fsx", "fsi", "cs",
    ]
    for argument in command.arguments.reversed() where !argument.hasPrefix("-") {
      let url = URL(fileURLWithPath: argument, relativeTo: command.workingDirectory)
        .standardizedFileURL
      if extensions.contains(url.pathExtension.lowercased()) { return url }
    }
    return nil
  }

  private struct SwiftExecutableProduct {
    let name: String
    let targets: Set<String>
  }

  private static func resolveSwiftPackage(
    command: EditorBuildCommand,
    root: URL
  ) -> EditorResolvedArtifact? {
    var showBinArguments = command.arguments
    if !showBinArguments.contains("build") {
      showBinArguments.insert("build", at: 0)
    }
    if !showBinArguments.contains("--show-bin-path") {
      showBinArguments.append("--show-bin-path")
    }
    let binResult = run(
      executable: command.executable.isEmpty ? "swift" : command.executable,
      arguments: showBinArguments,
      workingDirectory: root
    )
    guard binResult.status == 0 else { return nil }
    let binPath = binResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !binPath.isEmpty else { return nil }
    let binURL = URL(fileURLWithPath: binPath, isDirectory: true)

    let products = swiftExecutableProducts(root: root)
    let productNames: [String]
    if let index = command.arguments.lastIndex(of: "--product"),
      command.arguments.indices.contains(index + 1)
    {
      productNames = [command.arguments[index + 1]]
    } else if let index = command.arguments.lastIndex(of: "--target"),
      command.arguments.indices.contains(index + 1)
    {
      let target = command.arguments[index + 1]
      let matching = products.filter { $0.targets.contains(target) }
      productNames = matching.isEmpty ? [target] : matching.map(\.name)
    } else {
      productNames = products.map(\.name)
    }

    let named = productNames.compactMap { name -> URL? in
      let candidate = binURL.appendingPathComponent(name)
      return isExecutable(candidate) ? candidate : nil
    }
    // When package metadata is available, never silently select a different
    // executable than the requested product/target. A broad directory scan is
    // only a compatibility fallback for packages whose metadata cannot be read.
    let candidates = productNames.isEmpty ? directExecutables(in: binURL) : named
    guard let executable = candidates.sorted(by: modifiedMoreRecently).first else { return nil }
    return EditorResolvedArtifact(
      executableURL: executable,
      debugSymbolsURL: dsymURL(for: executable),
      architecture: architecture(of: executable),
      productName: executable.lastPathComponent,
      resolver: .swiftPackage
    )
  }

  private static func swiftExecutableProducts(root: URL) -> [SwiftExecutableProduct] {
    let result = run(
      executable: "swift",
      arguments: ["package", "describe", "--type", "json"],
      workingDirectory: root
    )
    guard result.status == 0,
      let data = result.output.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let products = object["products"] as? [[String: Any]]
    else { return [] }

    return products.compactMap { product in
      guard let name = product["name"] as? String else { return nil }
      let isExecutable: Bool
      if let type = product["type"] as? String {
        isExecutable = type.lowercased().contains("executable")
      } else if let type = product["type"] as? [String: Any] {
        isExecutable = type.keys.contains { $0.lowercased().contains("executable") }
      } else {
        isExecutable = false
      }
      guard isExecutable else { return nil }
      let targets: Set<String>
      if let names = product["targets"] as? [String] {
        targets = Set(names)
      } else if let values = product["targets"] as? [[String: Any]] {
        targets = Set(values.compactMap { $0["name"] as? String })
      } else {
        targets = []
      }
      return SwiftExecutableProduct(name: name, targets: targets)
    }
  }

  private static func resolveCargo(
    command: EditorBuildCommand,
    root: URL,
    buildOutput: String
  ) -> EditorResolvedArtifact? {
    let artifacts = buildOutput.split(whereSeparator: \.isNewline).compactMap { line -> URL? in
      guard let data = String(line).data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["reason"] as? String == "compiler-artifact",
        object["executable"] is String
      else { return nil }
      guard let executable = object["executable"] as? String, !executable.isEmpty else {
        return nil
      }
      let url = URL(fileURLWithPath: executable).standardizedFileURL
      return isExecutable(url) ? url : nil
    }
    if let executable = artifacts.sorted(by: modifiedMoreRecently).first {
      return artifact(executable, resolver: .cargo)
    }

    let metadata = run(
      executable: "cargo",
      arguments: ["metadata", "--format-version", "1", "--no-deps"],
      workingDirectory: root
    )
    let targetDirectory: URL = {
      guard metadata.status == 0,
        let data = metadata.output.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let path = object["target_directory"] as? String
      else { return root.appendingPathComponent("target", isDirectory: true) }
      return URL(fileURLWithPath: path, isDirectory: true)
    }()
    let profile = command.arguments.contains("--release") ? "release" : "debug"
    let directory = targetDirectory.appendingPathComponent(profile, isDirectory: true)
    var names = cargoBinaryNames(root: root)
    if let index = command.arguments.firstIndex(of: "--bin"),
      command.arguments.indices.contains(index + 1)
    {
      names = [command.arguments[index + 1]]
    }
    if names.isEmpty {
      names = directExecutables(in: directory).map(\.lastPathComponent)
    }
    let candidates = names.compactMap { name -> URL? in
      let url = directory.appendingPathComponent(name)
      return isExecutable(url) ? url : nil
    }
    guard let executable = candidates.sorted(by: modifiedMoreRecently).first else { return nil }
    return artifact(executable, resolver: .cargo)
  }

  private static func resolveXcode(
    command: EditorBuildCommand,
    root: URL
  ) -> EditorResolvedArtifact? {
    var arguments = command.arguments
    if let buildIndex = arguments.lastIndex(of: "build") {
      arguments.remove(at: buildIndex)
    }
    arguments += ["-showBuildSettings", "-json"]
    let result = run(executable: command.executable, arguments: arguments, workingDirectory: root)
    guard result.status == 0,
      let data = result.output.data(using: .utf8),
      let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return nil }
    let candidates = values.compactMap { value -> URL? in
      guard let settings = value["buildSettings"] as? [String: Any],
        let directory = settings["TARGET_BUILD_DIR"] as? String,
        let executablePath = settings["EXECUTABLE_PATH"] as? String
      else { return nil }
      let url = URL(fileURLWithPath: directory).appendingPathComponent(executablePath)
      return isExecutable(url) ? url : nil
    }
    guard let executable = candidates.sorted(by: modifiedMoreRecently).first else { return nil }
    return artifact(executable, resolver: .xcode)
  }

  private static func resolveCMake(root: URL) -> EditorResolvedArtifact? {
    let roots = [
      root.appendingPathComponent("build", isDirectory: true),
      root.appendingPathComponent(".calcite/build", isDirectory: true),
      root.appendingPathComponent("cmake-build-debug", isDirectory: true),
    ]
    let candidates = roots.flatMap { recursiveExecutables(in: $0, maximumDepth: 4) }
    guard let executable = candidates.sorted(by: modifiedMoreRecently).first else { return nil }
    return artifact(executable, resolver: .cmake)
  }

  private static func resolveGradle(root: URL) -> EditorResolvedArtifact? {
    let scripts = root.appendingPathComponent("build/scripts", isDirectory: true)
    let candidates = directExecutables(in: scripts)
    guard let executable = candidates.sorted(by: modifiedMoreRecently).first else { return nil }
    return artifact(executable, resolver: .gradle)
  }

  private static func resolveGo(
    command: EditorBuildCommand,
    root: URL
  ) -> EditorResolvedArtifact? {
    // Debug builds are rewritten to use an explicit `-o` path. This fallback supports custom
    // commands that already installed a main package at Go's reported target path.
    let target = run(
      executable: command.executable.isEmpty ? "go" : command.executable,
      arguments: ["list", "-f", "{{if .Main}}{{.Target}}{{end}}", "."],
      workingDirectory: root
    )
    guard target.status == 0 else { return nil }
    let path = target.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    let executable = URL(fileURLWithPath: path).standardizedFileURL
    guard isExecutable(executable) else { return nil }
    return artifact(executable, resolver: .go)
  }

  private static func resolveZig(
    command: EditorBuildCommand,
    root: URL
  ) -> EditorResolvedArtifact? {
    let binDirectory = root.appendingPathComponent("zig-out/bin", isDirectory: true)
    let targetName = zigBuildTarget(in: command.arguments)
    let candidates: [URL]
    if let targetName {
      let exact = binDirectory.appendingPathComponent(targetName)
      candidates = isExecutable(exact) ? [exact] : []
    } else {
      candidates = directExecutables(in: binDirectory)
    }
    guard let executable = candidates.sorted(by: modifiedMoreRecently).first else { return nil }
    return artifact(executable, resolver: .zig)
  }

  private static func zigBuildTarget(in arguments: [String]) -> String? {
    guard let buildIndex = arguments.firstIndex(of: "build") else { return nil }
    let ignored = Set(["run", "test", "install", "uninstall", "check", "clean"])
    for value in arguments.dropFirst(buildIndex + 1) {
      if value == "--" { break }
      if value.hasPrefix("-") { continue }
      if !ignored.contains(value) { return value }
    }
    return nil
  }

  private static func resolveMaven(root: URL) -> EditorResolvedArtifact? {
    let target = root.appendingPathComponent("target", isDirectory: true)
    let candidates =
      ((try? FileManager.default.contentsOfDirectory(
        at: target,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )) ?? []).filter { ["jar", "war"].contains($0.pathExtension.lowercased()) }
    // Java archives are not native executables, so return a launchable `java -jar` artifact only
    // when the custom task explicitly identifies one. Avoid silently selecting arbitrary archives.
    _ = candidates
    return nil
  }

  private static func cargoBinaryNames(root: URL) -> [String] {
    guard
      let text = try? String(
        contentsOf: root.appendingPathComponent("Cargo.toml"),
        encoding: .utf8
      )
    else { return [] }
    let source = text as NSString
    var names: [String] = []
    for pattern in [
      #"(?ms)^\s*\[package\].*?^\s*name\s*=\s*[\"]([^\"]+)[\"]"#,
      #"(?ms)^\s*\[\[bin\]\].*?^\s*name\s*=\s*[\"]([^\"]+)[\"]"#,
    ] {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(
        in: text,
        range: NSRange(location: 0, length: source.length)
      ) where match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
        names.append(source.substring(with: match.range(at: 1)))
      }
    }
    return Array(Set(names))
  }

  private static func directExecutables(in directory: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
      options: [.skipsHiddenFiles]
    )) ?? []).filter(isExecutable)
  }

  private static func recursiveExecutables(in directory: URL, maximumDepth: Int) -> [URL] {
    guard maximumDepth >= 0 else { return [] }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return [] }
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isExecutableKey],
        options: [.skipsHiddenFiles]
      )) ?? []
    var result: [URL] = []
    for entry in entries {
      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
      if values?.isDirectory == true {
        if !["CMakeFiles", "Testing", "_deps"].contains(entry.lastPathComponent) {
          result += recursiveExecutables(in: entry, maximumDepth: maximumDepth - 1)
        }
      } else if isExecutable(entry) {
        result.append(entry)
      }
    }
    return result
  }

  private static func isExecutable(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
      !directory.boolValue
    else { return false }
    return FileManager.default.isExecutableFile(atPath: url.path)
  }

  private static func artifact(
    _ executable: URL,
    resolver: EditorArtifactResolverKind
  ) -> EditorResolvedArtifact {
    EditorResolvedArtifact(
      executableURL: executable.standardizedFileURL,
      debugSymbolsURL: dsymURL(for: executable),
      architecture: architecture(of: executable),
      productName: executable.lastPathComponent,
      resolver: resolver
    )
  }

  private static func dsymURL(for executable: URL) -> URL? {
    let candidate = URL(fileURLWithPath: executable.path + ".dSYM")
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
  }

  private static func architecture(of executable: URL) -> String? {
    let result = run(
      executable: "/usr/bin/file", arguments: [executable.path],
      workingDirectory: executable.deletingLastPathComponent())
    guard result.status == 0 else { return nil }
    if result.output.contains("arm64") { return "arm64" }
    if result.output.contains("x86_64") { return "x86_64" }
    return nil
  }

  private static func isFresh(
    _ artifact: EditorResolvedArtifact,
    for snapshot: EditorPreparedSourceSnapshot?,
    command: EditorBuildCommand
  ) -> Bool {
    guard artifact.resolver != .interpretedEntry else { return true }
    guard let snapshot,
      let newestSource = snapshot.documents.compactMap(\.modificationDate).max()
    else { return true }
    guard
      let artifactDate = try? artifact.executableURL.resourceValues(
        forKeys: [.contentModificationDateKey]
      ).contentModificationDate
    else { return false }
    // File-system timestamp precision varies. One second allows coarse timestamp
    // filesystems without accepting an artifact that clearly predates its inputs.
    return artifactDate.timeIntervalSince(newestSource) >= -1.0
  }

  private static func modifiedMoreRecently(_ lhs: URL, _ rhs: URL) -> Bool {
    let left =
      (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
    let right =
      (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
    return left > right
  }

  private static func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL
  ) -> (status: Int32, output: String) {
    let process = Process()
    let pipe = Pipe()
    if executable.contains("/") {
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [executable] + arguments
    }
    process.currentDirectoryURL = workingDirectory
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    } catch {
      return (-1, "")
    }
  }
}
