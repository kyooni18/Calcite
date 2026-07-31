import Foundation

public enum EditorSingleFileCapability: Hashable, Sendable {
  case standalone
  case projectContextRequired(reason: String, rootURL: URL)
  case temporaryProjectRequired(reason: String)
  case toolMissing(tool: String)
  case unsupported(reason: String)
}

public struct EditorSingleFileResolution: Hashable, Sendable {
  public var capability: EditorSingleFileCapability
  public var plan: EditorBuildPlan?
  public var providerID: String

  public var runnablePlan: EditorBuildPlan? {
    switch capability {
    case .standalone, .projectContextRequired:
      return plan
    case .temporaryProjectRequired, .toolMissing, .unsupported:
      return nil
    }
  }

  public init(
    capability: EditorSingleFileCapability,
    plan: EditorBuildPlan?,
    providerID: String
  ) {
    self.capability = capability
    self.plan = plan
    self.providerID = providerID
  }
}

public struct EditorSingleFileContext: Hashable, Sendable {
  public let fileURL: URL
  public let workspaceURL: URL?
  public let cacheRoot: URL
  public let outputURL: URL

  public init(fileURL: URL, workspaceURL: URL? = nil) {
    let file = fileURL.standardizedFileURL
    self.fileURL = file
    self.workspaceURL = workspaceURL?.standardizedFileURL
    let base =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let identity = Self.stableIdentity(file)
    cacheRoot =
      base
      .appendingPathComponent("Calcite", isDirectory: true)
      .appendingPathComponent("SingleFileExecution", isDirectory: true)
      .appendingPathComponent(identity, isDirectory: true)
    let ext = file.pathExtension.lowercased()
    outputURL = cacheRoot.appendingPathComponent(
      "calcite-\(file.deletingPathExtension().lastPathComponent)-\(ext.isEmpty ? "file" : ext)"
    )
    try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
  }

  public var rootURL: URL { fileURL.deletingLastPathComponent() }
  public var sourcePath: String { fileURL.path }
  public var stem: String { fileURL.deletingPathExtension().lastPathComponent }
  public var fileExtension: String { fileURL.pathExtension.lowercased() }

  private static func stableIdentity(_ file: URL) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    let data = (try? Data(contentsOf: file)) ?? Data()
    for byte in Data(file.standardizedFileURL.path.utf8) + data {
      hash ^= UInt64(byte)
      hash &*= 0x100_0000_01b3
    }
    return String(format: "%016llx", hash)
  }
}

public protocol EditorSingleFileProvider: Sendable {
  var id: String { get }
  func supports(_ context: EditorSingleFileContext) -> Bool
  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution
}

public struct EditorCustomSingleFileProviderConfiguration: Codable, Hashable, Sendable {
  public var id: String
  public var fileExtensions: [String]
  public var executable: String
  public var arguments: [String]
  public var workingDirectory: String?
  public var environment: [String: String]

  public init(
    id: String,
    fileExtensions: [String],
    executable: String,
    arguments: [String] = ["${file}"],
    workingDirectory: String? = nil,
    environment: [String: String] = [:]
  ) {
    self.id = id
    self.fileExtensions = fileExtensions
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
  }
}

public enum EditorSingleFileProviderRegistry {
  public static let providers: [any EditorSingleFileProvider] = [
    SwiftSingleFileProvider(),
    ClangSingleFileProvider(),
    RustSingleFileProvider(),
    GoSingleFileProvider(),
    JVMSingleFileProvider(),
    JavaScriptSingleFileProvider(),
    PythonSingleFileProvider(),
    ShellSingleFileProvider(),
    InterpretedLanguageSingleFileProvider(),
    CompiledLanguageSingleFileProvider(),
    GenericShebangSingleFileProvider(),
    ExplicitUnsupportedSingleFileProvider(),
  ]

  public static func resolve(
    fileURL: URL,
    workspaceURL: URL? = nil
  ) -> EditorSingleFileResolution {
    let context = EditorSingleFileContext(fileURL: fileURL, workspaceURL: workspaceURL)
    if let custom = customConfigurations(workspaceURL: workspaceURL).first(where: {
      $0.fileExtensions.map {
        $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      }
      .contains(context.fileExtension)
    }) {
      return resolveCustom(custom, context: context)
    }
    guard let provider = providers.first(where: { $0.supports(context) }) else {
      return EditorSingleFileResolution(
        capability: .unsupported(
          reason: "No single-file execution provider recognizes \(fileURL.lastPathComponent)."
        ),
        plan: nil,
        providerID: "none"
      )
    }
    return provider.resolve(context)
  }

  public static func customConfigurations(workspaceURL: URL?)
    -> [EditorCustomSingleFileProviderConfiguration]
  {
    guard let workspaceURL else { return [] }
    let candidates = [
      workspaceURL.appendingPathComponent(".calcite/single-file-providers.json"),
      workspaceURL.appendingPathComponent(".calcite-single-file-providers.json"),
    ]
    let decoder = JSONDecoder()
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      guard let data = try? Data(contentsOf: url),
        let values = try? decoder.decode(
          [EditorCustomSingleFileProviderConfiguration].self, from: data)
      else { continue }
      return values
    }
    return []
  }

  private static func resolveCustom(
    _ configuration: EditorCustomSingleFileProviderConfiguration,
    context: EditorSingleFileContext
  ) -> EditorSingleFileResolution {
    func expand(_ value: String) -> String {
      value
        .replacingOccurrences(of: "${file}", with: context.sourcePath)
        .replacingOccurrences(of: "${dir}", with: context.rootURL.path)
        .replacingOccurrences(of: "${stem}", with: context.stem)
        .replacingOccurrences(of: "${cache}", with: context.cacheRoot.path)
        .replacingOccurrences(of: "${output}", with: context.outputURL.path)
        .replacingOccurrences(
          of: "${workspace}", with: context.workspaceURL?.path ?? context.rootURL.path)
    }
    let root: URL
    if let configured = configuration.workingDirectory, !configured.isEmpty {
      let expanded = expand(configured)
      root =
        URL(fileURLWithPath: expanded, relativeTo: context.workspaceURL ?? context.rootURL)
        .standardizedFileURL
    } else {
      root = context.rootURL
    }
    let command = EditorBuildCommand(
      id: "custom-file-run-\(configuration.id)",
      title: "Run \(context.fileURL.lastPathComponent)",
      kind: .run,
      executable: expand(configuration.executable),
      arguments: configuration.arguments.map(expand),
      workingDirectory: root,
      environment: configuration.environment.mapValues(expand)
    )
    let plan = EditorBuildPlan(projectKind: .generic, commands: [command])
    return SingleFilePlanFactory.resolution(
      providerID: "custom:\(configuration.id)",
      plan: plan,
      tool: command.executable
    )
  }
}

private enum SingleFilePlanFactory {
  static func command(
    _ id: String,
    _ title: String,
    _ kind: EditorBuildTaskKind,
    _ executable: String,
    _ arguments: [String],
    _ root: URL,
    environment: [String: String] = [:]
  ) -> EditorBuildCommand {
    EditorBuildCommand(
      id: id,
      title: title,
      kind: kind,
      executable: executable,
      arguments: arguments,
      workingDirectory: root,
      environment: environment
    )
  }

  static func interpreted(
    _ context: EditorSingleFileContext,
    executable: String,
    prefixArguments: [String] = [],
    environment: [String: String] = [:]
  ) -> EditorBuildPlan {
    EditorBuildPlan(
      projectKind: .generic,
      commands: [
        command(
          "file-run",
          "Run \(context.fileURL.lastPathComponent)",
          .run,
          executable,
          prefixArguments + [context.sourcePath],
          context.rootURL,
          environment: environment
        )
      ]
    )
  }

  static func compiled(
    _ context: EditorSingleFileContext,
    compiler: String,
    arguments: [String],
    runExecutable: String? = nil,
    runArguments: [String] = []
  ) -> EditorBuildPlan {
    EditorBuildPlan(
      projectKind: .generic,
      commands: [
        command(
          "file-build",
          "Build \(context.stem)",
          .build,
          compiler,
          arguments,
          context.rootURL
        ),
        command(
          "file-run",
          "Run \(context.stem)",
          .run,
          runExecutable ?? context.outputURL.path,
          runArguments,
          context.rootURL
        ),
      ]
    )
  }

  static func resolution(
    providerID: String,
    plan: EditorBuildPlan,
    tool: String
  ) -> EditorSingleFileResolution {
    let availability = EditorProcessEnvironment.executableURL(
      named: tool,
      workingDirectory: plan.commands.first?.workingDirectory
        ?? FileManager.default.temporaryDirectory,
      environment: ProcessInfo.processInfo.environment
    )
    return EditorSingleFileResolution(
      capability: availability == nil ? .toolMissing(tool: tool) : .standalone,
      plan: plan,
      providerID: providerID
    )
  }

  static func nearestAncestor(containing name: String, from start: URL) -> URL? {
    var current = start.standardizedFileURL
    while true {
      if FileManager.default.fileExists(atPath: current.appendingPathComponent(name).path) {
        return current
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { return nil }
      current = parent
    }
  }

  static func sourceText(_ context: EditorSingleFileContext) -> String {
    (try? String(contentsOf: context.fileURL, encoding: .utf8)) ?? ""
  }

  static func shebangExecutable(_ context: EditorSingleFileContext) -> String? {
    guard let first = sourceText(context).split(whereSeparator: \.isNewline).first,
      first.hasPrefix("#!")
    else { return nil }
    let words = first.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
    guard let command = words.first else { return nil }
    if URL(fileURLWithPath: command).lastPathComponent == "env", words.count > 1 {
      return words[1]
    }
    return command
  }
}

private struct SwiftSingleFileProvider: EditorSingleFileProvider {
  let id = "swift"
  func supports(_ context: EditorSingleFileContext) -> Bool {
    context.fileExtension == "swift"
  }
  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution {
    let text = SingleFilePlanFactory.sourceText(context)
    let imported = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
      let value = line.trimmingCharacters(in: .whitespaces)
      guard value.hasPrefix("import ") else { return nil }
      return value.dropFirst("import ".count).split(whereSeparator: \.isWhitespace).first.map(
        String.init)
    }
    let standardModules: Set<String> = [
      "Swift", "Foundation", "Darwin", "Glibc", "Dispatch", "CoreFoundation",
      "AppKit", "SwiftUI", "Combine", "Observation", "XCTest", "OSLog",
    ]
    if imported.contains(where: { !standardModules.contains($0) }),
      let root = SingleFilePlanFactory.nearestAncestor(
        containing: "Package.swift", from: context.rootURL)
    {
      return EditorSingleFileResolution(
        capability: .projectContextRequired(
          reason: "The file imports a package module and must run in SwiftPM target context.",
          rootURL: root
        ),
        plan: EditorBuildDiscovery.inspect(workspaceURL: root),
        providerID: id
      )
    }
    let plan = SingleFilePlanFactory.compiled(
      context,
      compiler: "swiftc",
      arguments: [context.sourcePath, "-o", context.outputURL.path]
    )
    return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: "swiftc")
  }
}

private struct ClangSingleFileProvider: EditorSingleFileProvider {
  let id = "clang"
  private let extensions: Set<String> = ["c", "cc", "cpp", "cxx", "c++", "m", "mm"]
  func supports(_ context: EditorSingleFileContext) -> Bool {
    extensions.contains(context.fileExtension)
  }
  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution {
    let ext = context.fileExtension
    let compiler = ["cc", "cpp", "cxx", "c++", "mm"].contains(ext) ? "clang++" : "clang"
    var arguments = [context.sourcePath, "-o", context.outputURL.path]
    if ext == "m" || ext == "mm" { arguments += ["-framework", "Foundation"] }
    let plan = SingleFilePlanFactory.compiled(context, compiler: compiler, arguments: arguments)
    return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: compiler)
  }
}

private struct RustSingleFileProvider: EditorSingleFileProvider {
  let id = "rust"
  func supports(_ context: EditorSingleFileContext) -> Bool { context.fileExtension == "rs" }
  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution {
    let text = SingleFilePlanFactory.sourceText(context)
    let externalUse =
      text.range(
        of: #"(?m)^\s*(?:extern\s+crate|use)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
        options: .regularExpression
      ) != nil
    if externalUse,
      let root = SingleFilePlanFactory.nearestAncestor(
        containing: "Cargo.toml", from: context.rootURL)
    {
      return EditorSingleFileResolution(
        capability: .projectContextRequired(
          reason: "The Rust file uses crate context.", rootURL: root),
        plan: EditorBuildDiscovery.inspect(workspaceURL: root),
        providerID: id
      )
    }
    let plan = SingleFilePlanFactory.compiled(
      context,
      compiler: "rustc",
      arguments: [context.sourcePath, "-o", context.outputURL.path]
    )
    return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: "rustc")
  }
}

private struct GoSingleFileProvider: EditorSingleFileProvider {
  let id = "go"
  func supports(_ context: EditorSingleFileContext) -> Bool { context.fileExtension == "go" }
  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution {
    let text = SingleFilePlanFactory.sourceText(context)
    if text.contains("import (")
      || text.range(of: #"(?m)^\s*import\s+\"[^\"]+/[^\"]+\""#, options: .regularExpression) != nil,
      let root = SingleFilePlanFactory.nearestAncestor(containing: "go.mod", from: context.rootURL)
    {
      return EditorSingleFileResolution(
        capability: .projectContextRequired(
          reason: "The Go file uses module imports.", rootURL: root),
        plan: EditorBuildDiscovery.inspect(workspaceURL: root),
        providerID: id
      )
    }
    let plan = SingleFilePlanFactory.compiled(
      context,
      compiler: "go",
      arguments: ["build", "-o", context.outputURL.path, context.sourcePath]
    )
    return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: "go")
  }
}

private struct PythonSingleFileProvider: EditorSingleFileProvider {
  let id = "python"
  func supports(_ context: EditorSingleFileContext) -> Bool {
    ["py", "pyw"].contains(context.fileExtension)
  }
  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution {
    let plan = SingleFilePlanFactory.interpreted(context, executable: "python3")
    return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: "python3")
  }
}

private struct JavaScriptSingleFileProvider: EditorSingleFileProvider {
  let id = "javascript-typescript"
  func supports(_ context: EditorSingleFileContext) -> Bool {
    ["js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts"].contains(context.fileExtension)
  }
  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution {
    let isTypeScript = ["jsx", "ts", "tsx", "mts", "cts"].contains(context.fileExtension)
    if isTypeScript,
      let root = SingleFilePlanFactory.nearestAncestor(
        containing: "tsconfig.json", from: context.rootURL),
      SingleFilePlanFactory.sourceText(context).contains("from ")
    {
      return EditorSingleFileResolution(
        capability: .projectContextRequired(
          reason: "The file uses TypeScript project context.", rootURL: root),
        plan: EditorBuildDiscovery.inspect(workspaceURL: root),
        providerID: id
      )
    }
    let tool = isTypeScript ? "tsx" : "node"
    let plan = SingleFilePlanFactory.interpreted(context, executable: tool)
    return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: tool)
  }
}

private struct JVMSingleFileProvider: EditorSingleFileProvider {
  let id = "jvm"
  func supports(_ context: EditorSingleFileContext) -> Bool {
    ["java", "kt", "kts", "scala", "sc", "groovy"].contains(context.fileExtension)
  }
  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution {
    switch context.fileExtension {
    case "java":
      let type = javaMainType(in: context) ?? context.stem
      let plan = EditorBuildPlan(
        projectKind: .generic,
        commands: [
          SingleFilePlanFactory.command(
            "file-build", "Build \(context.stem)", .build, "javac",
            ["-d", context.cacheRoot.path, context.sourcePath], context.rootURL),
          SingleFilePlanFactory.command(
            "file-run", "Run \(context.stem)", .run, "java",
            ["-cp", context.cacheRoot.path, type], context.rootURL),
        ])
      return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: "javac")
    case "kt":
      let jar = context.outputURL.appendingPathExtension("jar")
      let plan = EditorBuildPlan(
        projectKind: .generic,
        commands: [
          SingleFilePlanFactory.command(
            "file-build", "Build \(context.stem)", .build, "kotlinc",
            [context.sourcePath, "-include-runtime", "-d", jar.path], context.rootURL),
          SingleFilePlanFactory.command(
            "file-run", "Run \(context.stem)", .run, "java", ["-jar", jar.path], context.rootURL),
        ])
      return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: "kotlinc")
    case "kts":
      let plan = SingleFilePlanFactory.interpreted(
        context, executable: "kotlinc", prefixArguments: ["-script"])
      return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: "kotlinc")
    case "scala", "sc":
      let plan = SingleFilePlanFactory.interpreted(
        context, executable: "scala-cli", prefixArguments: ["run"])
      return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: "scala-cli")
    default:
      let plan = SingleFilePlanFactory.interpreted(context, executable: "groovy")
      return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: "groovy")
    }
  }

  private func javaMainType(in context: EditorSingleFileContext) -> String? {
    let text = SingleFilePlanFactory.sourceText(context)
    func capture(_ pattern: String) -> String? {
      guard
        let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
      else {
        return nil
      }
      let range = NSRange(location: 0, length: (text as NSString).length)
      guard let match = expression.firstMatch(in: text, range: range),
        match.numberOfRanges > 1,
        match.range(at: 1).location != NSNotFound
      else { return nil }
      return (text as NSString).substring(with: match.range(at: 1))
    }
    let package = capture(#"^\s*package\s+([A-Za-z_][A-Za-z0-9_.]*)\s*;"#)
    guard
      let type = capture(
        #"^\s*(?:public\s+)?(?:final\s+)?(?:class|record|enum)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    else {
      return nil
    }
    return package.map { "\($0).\(type)" } ?? type
  }
}

private struct ShellSingleFileProvider: EditorSingleFileProvider {
  let id = "shell"
  func supports(_ context: EditorSingleFileContext) -> Bool {
    ["sh", "bash", "zsh", "fish"].contains(context.fileExtension)
  }
  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution {
    let fallback = context.fileExtension == "sh" ? "/bin/sh" : context.fileExtension
    let tool = SingleFilePlanFactory.shebangExecutable(context) ?? fallback
    let plan = SingleFilePlanFactory.interpreted(context, executable: tool)
    return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: tool)
  }
}

private struct InterpretedLanguageSingleFileProvider: EditorSingleFileProvider {
  let id = "interpreted"
  private let tools: [String: (String, [String])] = [
    "lua": ("lua", []), "rb": ("ruby", []), "php": ("php", []),
    "pl": ("perl", []), "pm": ("perl", []), "r": ("Rscript", []),
    "rmd": ("Rscript", []), "dart": ("dart", ["run"]), "jl": ("julia", []),
    "hs": ("runghc", []), "lhs": ("runghc", []), "ml": ("ocaml", []),
    "ex": ("elixir", []), "exs": ("elixir", []), "erl": ("escript", []),
    "clj": ("clojure", []), "cljs": ("clojure", []), "cljc": ("clojure", []),
    "fsx": ("dotnet", ["fsi"]), "fsi": ("dotnet", ["fsi"]),
    "fs": ("dotnet", ["fsi"]), "cs": ("dotnet-script", []),
  ]
  func supports(_ context: EditorSingleFileContext) -> Bool { tools[context.fileExtension] != nil }
  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution {
    let (tool, args) = tools[context.fileExtension]!
    let plan = SingleFilePlanFactory.interpreted(context, executable: tool, prefixArguments: args)
    return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: tool)
  }
}

private struct CompiledLanguageSingleFileProvider: EditorSingleFileProvider {
  let id = "compiled-extra"
  func supports(_ context: EditorSingleFileContext) -> Bool {
    ["zig", "nim", "nims"].contains(context.fileExtension)
  }
  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution {
    if context.fileExtension == "zig" {
      let plan = SingleFilePlanFactory.compiled(
        context,
        compiler: "zig",
        arguments: ["build-exe", context.sourcePath, "-femit-bin=\(context.outputURL.path)"]
      )
      return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: "zig")
    }
    let plan = SingleFilePlanFactory.compiled(
      context,
      compiler: "nim",
      arguments: ["c", "--out:\(context.outputURL.path)", context.sourcePath]
    )
    return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: "nim")
  }
}

private struct GenericShebangSingleFileProvider: EditorSingleFileProvider {
  let id = "shebang"
  func supports(_ context: EditorSingleFileContext) -> Bool {
    SingleFilePlanFactory.shebangExecutable(context) != nil
  }
  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution {
    guard let tool = SingleFilePlanFactory.shebangExecutable(context) else {
      return .init(capability: .unsupported(reason: "Invalid shebang."), plan: nil, providerID: id)
    }
    let plan = SingleFilePlanFactory.interpreted(context, executable: tool)
    return SingleFilePlanFactory.resolution(providerID: id, plan: plan, tool: tool)
  }
}

private struct ExplicitUnsupportedSingleFileProvider: EditorSingleFileProvider {
  let id = "unsupported-document"
  private let documentExtensions: Set<String> = [
    "css", "scss", "less", "html", "htm", "json", "jsonc", "yaml", "yml", "toml",
    "xml", "xsd", "svg", "md", "markdown", "mdx", "sql", "proto", "graphql", "gql",
    "vue", "svelte", "tf", "tfvars", "hcl", "dockerfile", "metal", "txt", "edn", "hrl",
    "mli", "pyi", "swiftinterface", "modulemap", "h", "hpp", "hh", "hxx", "inc",
  ]

  func supports(_ context: EditorSingleFileContext) -> Bool {
    documentExtensions.contains(context.fileExtension)
      || context.fileURL.lastPathComponent.lowercased() == "dockerfile"
  }

  func resolve(_ context: EditorSingleFileContext) -> EditorSingleFileResolution {
    EditorSingleFileResolution(
      capability: .unsupported(
        reason:
          "\(context.fileURL.lastPathComponent) is not an independently executable source file."
      ),
      plan: nil,
      providerID: id
    )
  }
}
