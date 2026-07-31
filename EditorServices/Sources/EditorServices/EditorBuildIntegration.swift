import EditorCore
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public enum EditorProjectBuildKind: String, Codable, CaseIterable, Sendable {
  case xcode
  case swiftPackage
  case rustCargo
  case goModule
  case nodePackage
  case python
  case gradle
  case maven
  case zig
  case cmake
  case make
  case generic
}

public enum EditorBuildTaskKind: String, Codable, CaseIterable, Sendable {
  case build
  case run
  case test
  case check
  case clean
  case custom
}

public struct EditorBuildCommand: Hashable, Codable, Sendable, Identifiable {
  public let id: String
  public var title: String
  public var kind: EditorBuildTaskKind
  public var executable: String
  public var arguments: [String]
  public var workingDirectory: URL
  public var environment: [String: String]
  /// Optional executable artifact emitted by this task. Relative paths use `workingDirectory`.
  public var artifactPath: String?

  public init(
    id: String,
    title: String,
    kind: EditorBuildTaskKind,
    executable: String,
    arguments: [String],
    workingDirectory: URL,
    environment: [String: String] = [:]
  ) {
    self.init(
      id: id,
      title: title,
      kind: kind,
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      artifactPath: nil
    )
  }

  public init(
    id: String,
    title: String,
    kind: EditorBuildTaskKind,
    executable: String,
    arguments: [String],
    workingDirectory: URL,
    environment: [String: String] = [:],
    artifactPath: String?
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory.standardizedFileURL
    self.environment = environment
    self.artifactPath = artifactPath
  }

  /// Creates a direct command from an argv-style array whose first item is the executable.
  public init(
    id: String,
    title: String,
    kind: EditorBuildTaskKind,
    arguments: [String],
    workingDirectory: URL,
    environment: [String: String] = [:]
  ) {
    self.init(
      id: id,
      title: title,
      kind: kind,
      executable: arguments.first ?? "",
      arguments: Array(arguments.dropFirst()),
      workingDirectory: workingDirectory,
      environment: environment,
      artifactPath: nil
    )
  }

  public init(
    id: String,
    title: String,
    kind: EditorBuildTaskKind,
    arguments: [String],
    workingDirectory: URL,
    environment: [String: String] = [:],
    artifactPath: String?
  ) {
    self.init(
      id: id,
      title: title,
      kind: kind,
      executable: arguments.first ?? "",
      arguments: Array(arguments.dropFirst()),
      workingDirectory: workingDirectory,
      environment: environment,
      artifactPath: artifactPath
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, kind, executable, arguments, workingDirectory, environment, artifactPath
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    kind = try container.decode(EditorBuildTaskKind.self, forKey: .kind)
    executable = try container.decode(String.self, forKey: .executable)
    arguments = try container.decode([String].self, forKey: .arguments)
    workingDirectory = try container.decode(URL.self, forKey: .workingDirectory).standardizedFileURL
    environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    artifactPath = try container.decodeIfPresent(String.self, forKey: .artifactPath)
  }
}

public struct EditorBuildPlan: Hashable, Codable, Sendable {
  public var projectKind: EditorProjectBuildKind
  public var commands: [EditorBuildCommand]

  public init(projectKind: EditorProjectBuildKind, commands: [EditorBuildCommand]) {
    self.projectKind = projectKind
    self.commands = commands
  }

  public func command(for kind: EditorBuildTaskKind) -> EditorBuildCommand? {
    commands.first { $0.kind == kind }
  }
}

public enum EditorBuildTaskTarget: Hashable, Sendable {
  case project(EditorBuildCommand)
  case standalone(fileURL: URL, plan: EditorBuildPlan)

}

/// Resolves command availability and execution through one shared policy so the toolbar cannot
/// advertise an action that the controller later routes somewhere else.
public enum EditorBuildTaskResolver {
  public static func resolve(
    projectPlan: EditorBuildPlan,
    activeFileURL: URL?,
    kind: EditorBuildTaskKind
  ) -> EditorBuildTaskTarget? {
    if let command = projectPlan.command(for: kind) {
      return .project(command)
    }
    guard let activeFileURL,
      let standalone = EditorBuildDiscovery.singleFilePlan(fileURL: activeFileURL),
      standalone.command(for: kind) != nil
        || (kind == .run && standalone.command(for: .build) != nil
          && standalone.command(for: .run) != nil)
    else { return nil }
    return .standalone(fileURL: activeFileURL.standardizedFileURL, plan: standalone)
  }

  public static func canExecute(
    projectPlan: EditorBuildPlan,
    activeFileURL: URL?,
    kind: EditorBuildTaskKind
  ) -> Bool {
    resolve(projectPlan: projectPlan, activeFileURL: activeFileURL, kind: kind) != nil
  }
}

public struct EditorBuildDiagnostic: Hashable, Sendable {
  public var url: URL
  public var line: Int
  public var column: Int
  public var endLine: Int?
  public var endColumn: Int?
  public var severity: Diagnostic.Severity
  public var message: String
  public var code: String?
  public var source: String?

  public init(
    url: URL,
    line: Int,
    column: Int,
    endLine: Int? = nil,
    endColumn: Int? = nil,
    severity: Diagnostic.Severity,
    message: String,
    code: String? = nil,
    source: String? = nil
  ) {
    self.url = url.standardizedFileURL
    let normalizedLine = max(1, line)
    self.line = normalizedLine
    self.column = max(1, column)
    self.endLine = endLine.map { max(normalizedLine, $0) }
    self.endColumn = endColumn.map { max(1, $0) }
    self.severity = severity
    self.message = message
    self.code = code
    self.source = source
  }
}

public struct EditorBuildResult: Hashable, Sendable {
  public var commandID: String
  public var exitCode: Int32
  public var duration: Duration
  public var wasCancelled: Bool

  public init(
    commandID: String,
    exitCode: Int32,
    duration: Duration,
    wasCancelled: Bool = false
  ) {
    self.commandID = commandID
    self.exitCode = exitCode
    self.duration = duration
    self.wasCancelled = wasCancelled
  }

  public var succeeded: Bool { exitCode == 0 && !wasCancelled }
}

public enum EditorBuildEvent: Sendable {
  case started(EditorBuildCommand)
  case output(String, standardError: Bool)
  case diagnostic(EditorBuildDiagnostic)
  case finished(EditorBuildResult)
}

public enum EditorBuildRunnerError: LocalizedError, Sendable {
  case alreadyRunning
  case executableUnavailable(String)
  case invalidWorkingDirectory(String)
  case launchFailed(String)

  public var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      return "A build task is already running."
    case .executableUnavailable(let path):
      return "The build executable is not available: \(path)"
    case .invalidWorkingDirectory(let path):
      return "The build working directory is unavailable: \(path)"
    case .launchFailed(let reason):
      return "The build task could not be launched: \(reason)"
    }
  }
}

public enum EditorBuildDiscovery {
  /// Creates build/run commands for a standalone source file. Compiled artifacts are
  /// hidden and include the extension so files such as main.c and main.swift cannot collide.
  public static func singleFilePlan(fileURL: URL) -> EditorBuildPlan? {
    EditorSingleFileProviderRegistry.resolve(fileURL: fileURL).plan
  }

  public static func singleFileResolution(
    fileURL: URL,
    workspaceURL: URL? = nil
  ) -> EditorSingleFileResolution {
    EditorSingleFileProviderRegistry.resolve(
      fileURL: fileURL,
      workspaceURL: workspaceURL
    )
  }

  private static var singleFileCacheRoot: URL {
    let base =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return
      base
      .appendingPathComponent("Calcite", isDirectory: true)
      .appendingPathComponent("SingleFileExecution", isDirectory: true)
  }

  private static func stableFileIdentity(_ file: URL) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    let data = (try? Data(contentsOf: file)) ?? Data()
    for byte in Data(file.standardizedFileURL.path.utf8) + data {
      hash ^= UInt64(byte)
      hash &*= 0x100_0000_01b3
    }
    return String(format: "%016llx", hash)
  }

  private static func shebangExecutable(in file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 512),
      let firstLine = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
      firstLine.hasPrefix("#!")
    else { return nil }
    let words = firstLine.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
    guard let first = words.first else { return nil }
    if URL(fileURLWithPath: first).lastPathComponent == "env", words.count > 1 {
      return words[1]
    }
    return first
  }

  private static func javaMainType(in file: URL) -> String? {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }

    func capture(_ pattern: String) -> String? {
      guard
        let expression = try? NSRegularExpression(
          pattern: pattern, options: [.anchorsMatchLines]
        )
      else { return nil }
      let fullRange = NSRange(location: 0, length: (text as NSString).length)
      guard let match = expression.firstMatch(in: text, range: fullRange),
        match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound
      else { return nil }
      return (text as NSString).substring(with: match.range(at: 1))
    }

    let packageName = capture(#"^\s*package\s+([A-Za-z_][A-Za-z0-9_.]*)\s*;"#)
    guard
      let typeName = capture(
        #"^\s*(?:public\s+)?(?:final\s+)?(?:class|record|enum)\s+([A-Za-z_][A-Za-z0-9_]*)"#
      )
    else { return nil }
    return packageName.map { "\($0).\(typeName)" } ?? typeName
  }

  private static func interpretedFilePlan(
    root: URL,
    source: String,
    executable: String,
    arguments: [String] = [],
    title: String
  ) -> EditorBuildPlan {
    plan(
      .generic, root: root,
      tasks: [
        ("file-run", "Run \(title)", .run, [executable] + arguments + [source])
      ])
  }

  private static func compiledFilePlan(
    root: URL,
    source: String,
    output: String,
    compiler: String,
    stem: String,
    compilerArguments: [String] = [],
    placesOutputBeforeSource: Bool = false
  ) -> EditorBuildPlan {
    let arguments =
      placesOutputBeforeSource
      ? compilerArguments + [output, source]
      : [source, "-o", output] + compilerArguments
    return EditorBuildPlan(
      projectKind: .generic,
      commands: [
        command("file-build", "Build \(stem)", .build, compiler, arguments, root),
        command("file-run", "Run \(stem)", .run, output, [], root),
      ])
  }

  public static func inspect(
    workspaceURL: URL,
    preferredXcodeScheme: String? = nil
  ) -> EditorBuildPlan {
    let root = workspaceURL.standardizedFileURL
    let fileManager = FileManager.default

    if let container = xcodeContainer(in: root, fileManager: fileManager) {
      return xcodePlan(
        root: root,
        container: container,
        fileManager: fileManager,
        preferredScheme: preferredXcodeScheme
      )
    }
    if exists("Package.swift", in: root, fileManager: fileManager) {
      return plan(
        .swiftPackage, root: root,
        tasks: [
          ("swift-build", "Build", .build, ["swift", "build"]),
          ("swift-run", "Run", .run, ["swift", "run"]),
          ("swift-test", "Test", .test, ["swift", "test"]),
          ("swift-clean", "Clean", .clean, ["swift", "package", "clean"]),
        ])
    }
    if exists("Cargo.toml", in: root, fileManager: fileManager) {
      return plan(
        .rustCargo, root: root,
        tasks: [
          ("cargo-check", "Check", .check, ["cargo", "check", "--message-format=json"]),
          ("cargo-build", "Build", .build, ["cargo", "build", "--message-format=json"]),
          ("cargo-run", "Run", .run, ["cargo", "run"]),
          ("cargo-test", "Test", .test, ["cargo", "test", "--message-format=json"]),
          ("cargo-clean", "Clean", .clean, ["cargo", "clean"]),
        ])
    }
    if exists("go.mod", in: root, fileManager: fileManager) {
      return plan(
        .goModule, root: root,
        tasks: [
          ("go-build", "Build", .build, ["go", "build", "./..."]),
          ("go-run", "Run", .run, ["go", "run", "."]),
          ("go-test", "Test", .test, ["go", "test", "./..."]),
          ("go-clean", "Clean", .clean, ["go", "clean", "./..."]),
        ])
    }
    if exists("package.json", in: root, fileManager: fileManager) {
      return nodePlan(root: root, fileManager: fileManager)
    }
    if isPythonProject(root: root, fileManager: fileManager) {
      return pythonPlan(root: root, fileManager: fileManager)
    }
    if exists("gradlew", in: root, fileManager: fileManager)
      || exists("build.gradle", in: root, fileManager: fileManager)
      || exists("build.gradle.kts", in: root, fileManager: fileManager)
    {
      return gradlePlan(root: root, fileManager: fileManager)
    }
    if exists("pom.xml", in: root, fileManager: fileManager) {
      return plan(
        .maven, root: root,
        tasks: [
          ("maven-build", "Build", .build, ["mvn", "package"]),
          ("maven-test", "Test", .test, ["mvn", "test"]),
          ("maven-clean", "Clean", .clean, ["mvn", "clean"]),
        ])
    }
    if exists("build.zig", in: root, fileManager: fileManager) {
      return plan(
        .zig, root: root,
        tasks: [
          ("zig-build", "Build", .build, ["zig", "build"]),
          ("zig-run", "Run", .run, ["zig", "build", "run"]),
          ("zig-test", "Test", .test, ["zig", "build", "test"]),
        ])
    }
    if exists("CMakeLists.txt", in: root, fileManager: fileManager) {
      return plan(
        .cmake, root: root,
        tasks: [
          ("cmake-configure", "Configure", .check, ["cmake", "-S", ".", "-B", "build"]),
          ("cmake-build", "Build", .build, ["cmake", "--build", "build"]),
          ("cmake-test", "Test", .test, ["ctest", "--test-dir", "build"]),
        ])
    }
    if exists("Makefile", in: root, fileManager: fileManager)
      || exists("makefile", in: root, fileManager: fileManager)
    {
      return makePlan(root: root)
    }
    return EditorBuildPlan(projectKind: .generic, commands: [])
  }

  public static func xcodeSchemes(workspaceURL: URL) -> [String] {
    let root = workspaceURL.standardizedFileURL
    guard let container = xcodeContainer(in: root, fileManager: .default) else { return [] }
    return xcodeSchemes(in: container.url, fileManager: .default)
  }

  private struct XcodeContainer {
    var url: URL
    var isWorkspace: Bool
  }

  private static func xcodeContainer(
    in root: URL,
    fileManager: FileManager
  ) -> XcodeContainer? {
    guard
      let children = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return nil }

    let sorted = children.sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
    if let workspace = sorted.first(where: { $0.pathExtension == "xcworkspace" }) {
      return XcodeContainer(url: workspace, isWorkspace: true)
    }
    if let project = sorted.first(where: { $0.pathExtension == "xcodeproj" }) {
      return XcodeContainer(url: project, isWorkspace: false)
    }
    return nil
  }

  private static func xcodePlan(
    root: URL,
    container: XcodeContainer,
    fileManager: FileManager,
    preferredScheme: String?
  ) -> EditorBuildPlan {
    let containerFlag = container.isWorkspace ? "-workspace" : "-project"
    let relativeContainer = container.url.lastPathComponent
    let schemes = xcodeSchemes(in: container.url, fileManager: fileManager)
    let projectName = container.url.deletingPathExtension().lastPathComponent
    let scheme =
      preferredScheme.flatMap { schemes.contains($0) ? $0 : nil }
      ?? schemes.first(where: { $0.caseInsensitiveCompare(projectName) == .orderedSame })
      ?? schemes.first
      ?? projectName
    let common = [
      containerFlag, relativeContainer, "-scheme", scheme,
      "-configuration", "Debug", "-derivedDataPath", ".calcite/DerivedData",
    ]
    return EditorBuildPlan(
      projectKind: .xcode,
      commands: [
        command(
          "xcode-resolve", "Resolve Packages", .check, "xcodebuild",
          common + ["-resolvePackageDependencies"], root),
        command("xcode-build", "Build", .build, "xcodebuild", common + ["build"], root),
        command("xcode-test", "Test", .test, "xcodebuild", common + ["test"], root),
        command("xcode-clean", "Clean", .clean, "xcodebuild", common + ["clean"], root),
      ]
    )
  }

  private static func xcodeSchemes(
    in container: URL,
    fileManager: FileManager
  ) -> [String] {
    var directories = [
      container.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
    ]
    if container.pathExtension == "xcworkspace" {
      let root = container.deletingLastPathComponent()
      let projects =
        (try? fileManager.contentsOfDirectory(
          at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
      directories += projects.filter { $0.pathExtension == "xcodeproj" }.map {
        $0.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
      }
    }
    var values: Set<String> = []
    for directory in directories {
      let files =
        (try? fileManager.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
      for file in files where file.pathExtension == "xcscheme" {
        values.insert(file.deletingPathExtension().lastPathComponent)
      }
    }
    return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  private static func gradlePlan(root: URL, fileManager: FileManager) -> EditorBuildPlan {
    let wrapper = root.appendingPathComponent("gradlew")
    let executable: String
    let prefix: [String]
    if fileManager.fileExists(atPath: wrapper.path) {
      if fileManager.isExecutableFile(atPath: wrapper.path) {
        executable = wrapper.path
        prefix = []
      } else {
        executable = "/bin/sh"
        prefix = [wrapper.path]
      }
    } else {
      executable = "gradle"
      prefix = []
    }
    let text = ["build.gradle", "build.gradle.kts"].compactMap {
      try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
    }.joined(separator: "\n")
    let hasRun =
      text.contains("application")
      || text.range(
        of: #"tasks\s*\.?(?:register|create)?\s*\(?[\"']run[\"']"#, options: .regularExpression)
        != nil
    var commands = [
      command("gradle-build", "Build", .build, executable, prefix + ["build"], root),
      command("gradle-test", "Test", .test, executable, prefix + ["test"], root),
      command("gradle-clean", "Clean", .clean, executable, prefix + ["clean"], root),
    ]
    if hasRun {
      commands.insert(command("gradle-run", "Run", .run, executable, prefix + ["run"], root), at: 1)
    }
    return EditorBuildPlan(projectKind: .gradle, commands: commands)
  }

  private static func makePlan(root: URL) -> EditorBuildPlan {
    let file =
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Makefile").path)
      ? root.appendingPathComponent("Makefile") : root.appendingPathComponent("makefile")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    let targets = Set(
      text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
        let raw = String(line)
        guard !raw.hasPrefix("\t"), let colon = raw.firstIndex(of: ":") else { return nil }
        let name = raw[..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("%"), !name.contains("$") else { return nil }
        return name
      })
    var commands = [command("make-build", "Build", .build, "make", [], root)]
    for (name, kind, title) in [
      ("run", EditorBuildTaskKind.run, "Run"),
      ("test", .test, "Test"),
      ("check", .check, "Check"),
      ("clean", .clean, "Clean"),
    ] where targets.contains(name) {
      commands.append(command("make-\(name)", title, kind, "make", [name], root))
    }
    return EditorBuildPlan(projectKind: .make, commands: commands)
  }

  private enum PythonProjectManager {
    case uv
    case poetry
    case pdm
    case hatch
    case standard
  }

  private struct PythonProjectMetadata {
    var manager: PythonProjectManager
    var pyprojectText: String
    var scripts: [String: String]
    var packageModule: String?
    var hasPackageMetadata: Bool
    var usesPytest: Bool
    var hasTests: Bool
  }

  private static func isPythonProject(root: URL, fileManager: FileManager) -> Bool {
    let markers = [
      "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile",
      "poetry.lock", "pdm.lock", "uv.lock", "hatch.toml", "pytest.ini", "tox.ini",
      "environment.yml", "environment.yaml", "__main__.py", "main.py", "app.py",
    ]
    if markers.contains(where: { exists($0, in: root, fileManager: fileManager) }) {
      return true
    }
    if pythonModuleUnderSrc(root: root, fileManager: fileManager) != nil { return true }
    return rootPythonTestFiles(root: root, fileManager: fileManager).isEmpty == false
  }

  private static func pythonPlan(root: URL, fileManager: FileManager) -> EditorBuildPlan {
    let metadata = pythonProjectMetadata(root: root, fileManager: fileManager)
    var commands: [EditorBuildCommand] = [
      command(
        "python-check", "Check", .check, "python", ["-m", "compileall", "-q", "."], root
      )
    ]

    if metadata.hasPackageMetadata {
      commands.append(pythonBuildCommand(root: root, manager: metadata.manager))
    } else {
      commands.append(
        command(
          "python-build", "Build", .build, "python", ["-m", "compileall", "-q", "."],
          root
        ))
    }

    if let run = pythonRunCommand(root: root, metadata: metadata, fileManager: fileManager) {
      commands.append(run)
    }
    if metadata.hasTests {
      commands.append(pythonTestCommand(root: root, metadata: metadata, fileManager: fileManager))
    }
    commands.append(
      EditorBuildCommand(
        id: "python-clean",
        title: "Clean",
        kind: .clean,
        executable: "python",
        arguments: [
          "-c",
          "import pathlib,shutil; [shutil.rmtree(p, ignore_errors=True) for p in "
            + "[pathlib.Path('build'), pathlib.Path('dist'), pathlib.Path('.pytest_cache'), "
            + "pathlib.Path('.mypy_cache'), pathlib.Path('.ruff_cache')]]",
        ],
        workingDirectory: root
      ))
    return EditorBuildPlan(projectKind: .python, commands: commands)
  }

  private static func pythonProjectMetadata(
    root: URL,
    fileManager: FileManager
  ) -> PythonProjectMetadata {
    let pyprojectURL = root.appendingPathComponent("pyproject.toml")
    let pyprojectText = (try? String(contentsOf: pyprojectURL, encoding: .utf8)) ?? ""
    let manager: PythonProjectManager
    if exists("uv.lock", in: root, fileManager: fileManager) {
      manager = .uv
    } else if exists("poetry.lock", in: root, fileManager: fileManager)
      || pyprojectText.contains("[tool.poetry]")
    {
      manager = .poetry
    } else if exists("pdm.lock", in: root, fileManager: fileManager)
      || pyprojectText.contains("[tool.pdm]")
    {
      manager = .pdm
    } else if exists("hatch.toml", in: root, fileManager: fileManager)
      || pyprojectText.contains("[tool.hatch")
    {
      manager = .hatch
    } else {
      manager = .standard
    }

    let requirementsText = ["requirements.txt", "requirements-dev.txt", "dev-requirements.txt"]
      .compactMap { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
      .joined(separator: "\n")
    let scripts = pythonScripts(in: pyprojectText)
    let packageModule = pythonModuleUnderSrc(root: root, fileManager: fileManager)
    let rootTests = rootPythonTestFiles(root: root, fileManager: fileManager)
    let hasTestDirectory = isDirectory(
      root.appendingPathComponent("tests"), fileManager: fileManager)
    let usesPytest =
      exists("pytest.ini", in: root, fileManager: fileManager)
      || exists("conftest.py", in: root, fileManager: fileManager)
      || pyprojectText.contains("[tool.pytest")
      || requirementsText.range(of: #"(?m)^\s*pytest(?:\W|$)"#, options: .regularExpression) != nil
    let hasTests =
      hasTestDirectory || !rootTests.isEmpty || usesPytest
      || exists("tox.ini", in: root, fileManager: fileManager)

    return PythonProjectMetadata(
      manager: manager,
      pyprojectText: pyprojectText,
      scripts: scripts,
      packageModule: packageModule,
      hasPackageMetadata: !pyprojectText.isEmpty
        || exists("setup.py", in: root, fileManager: fileManager)
        || exists("setup.cfg", in: root, fileManager: fileManager),
      usesPytest: usesPytest,
      hasTests: hasTests
    )
  }

  private static func pythonBuildCommand(
    root: URL,
    manager: PythonProjectManager
  ) -> EditorBuildCommand {
    let invocation: [String]
    switch manager {
    case .uv: invocation = ["uv", "build"]
    case .poetry: invocation = ["poetry", "build"]
    case .pdm: invocation = ["pdm", "build"]
    case .hatch: invocation = ["hatch", "build"]
    case .standard:
      // pip's PEP 517 wheel path does not require the optional `build` module to be installed.
      invocation = ["python", "-m", "pip", "wheel", ".", "--no-deps", "--wheel-dir", "dist"]
    }
    return EditorBuildCommand(
      id: "python-build",
      title: "Build",
      kind: .build,
      arguments: invocation,
      workingDirectory: root
    )
  }

  private static func pythonRunCommand(
    root: URL,
    metadata: PythonProjectMetadata,
    fileManager: FileManager
  ) -> EditorBuildCommand? {
    if let script = metadata.scripts.keys.sorted().first,
      let target = metadata.scripts[script]
    {
      let invocation: [String]
      switch metadata.manager {
      case .uv: invocation = ["uv", "run", script]
      case .poetry: invocation = ["poetry", "run", script]
      case .pdm: invocation = ["pdm", "run", script]
      case .hatch: invocation = ["hatch", "run", script]
      case .standard: invocation = pythonEntrypointInvocation(target)
      }
      return EditorBuildCommand(
        id: "python-run-script",
        title: "Run \(script)",
        kind: .run,
        arguments: invocation,
        workingDirectory: root
      )
    }
    if exists("__main__.py", in: root, fileManager: fileManager) {
      return command("python-run", "Run", .run, "python", ["."], root)
    }
    if exists("main.py", in: root, fileManager: fileManager) {
      return command("python-run", "Run", .run, "python", ["main.py"], root)
    }
    if exists("app.py", in: root, fileManager: fileManager) {
      return command("python-run", "Run", .run, "python", ["app.py"], root)
    }
    if let module = metadata.packageModule {
      return EditorBuildCommand(
        id: "python-run-module",
        title: "Run \(module)",
        kind: .run,
        executable: "python",
        arguments: ["-m", module],
        workingDirectory: root,
        environment: ["PYTHONPATH": root.appendingPathComponent("src").path]
      )
    }
    return nil
  }

  private static func pythonTestCommand(
    root: URL,
    metadata: PythonProjectMetadata,
    fileManager: FileManager
  ) -> EditorBuildCommand {
    let base: [String]
    if exists("tox.ini", in: root, fileManager: fileManager) {
      base = ["python", "-m", "tox"]
    } else if metadata.usesPytest {
      base = ["python", "-m", "pytest"]
    } else {
      base = ["python", "-m", "unittest", "discover", "-v"]
    }

    let invocation: [String]
    switch metadata.manager {
    case .uv: invocation = ["uv", "run"] + base
    case .poetry: invocation = ["poetry", "run"] + base
    case .pdm: invocation = ["pdm", "run"] + base
    case .hatch: invocation = ["hatch", "run"] + base
    case .standard: invocation = base
    }
    return EditorBuildCommand(
      id: "python-test",
      title: "Test",
      kind: .test,
      arguments: invocation,
      workingDirectory: root
    )
  }

  private static func pythonScripts(in pyprojectText: String) -> [String: String] {
    var section = ""
    var result: [String: String] = [:]
    for rawLine in pyprojectText.split(whereSeparator: \.isNewline) {
      let line = stripTOMLComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      if line.hasPrefix("["), line.hasSuffix("]") {
        section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        continue
      }
      guard section == "project.scripts" || section == "tool.poetry.scripts",
        let equals = line.firstIndex(of: "=")
      else { continue }
      let key = unquoteTOML(String(line[..<equals]).trimmingCharacters(in: .whitespaces))
      let value = unquoteTOML(
        String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces))
      guard !key.isEmpty, !value.isEmpty else { continue }
      result[key] = value
    }
    return result
  }

  private static func pythonEntrypointInvocation(_ target: String) -> [String] {
    let components = target.split(separator: ":", maxSplits: 1).map(String.init)
    let module = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard components.count == 2 else { return ["python", "-m", module] }
    let callable = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
    let attributes = callable.split(separator: ".").map(String.init)
    guard !module.isEmpty, !attributes.isEmpty else { return ["python", "-m", module] }
    let traversal = attributes.map { "_entry = getattr(_entry, \(pythonStringLiteral($0)))" }
      .joined(separator: "; ")
    let script =
      "import importlib; _entry = importlib.import_module(\(pythonStringLiteral(module))); "
      + traversal + "; raise SystemExit(_entry())"
    return ["python", "-c", script]
  }

  private static func pythonModuleUnderSrc(
    root: URL,
    fileManager: FileManager
  ) -> String? {
    let src = root.appendingPathComponent("src", isDirectory: true)
    let children =
      (try? fileManager.contentsOfDirectory(
        at: src,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )) ?? []
    return children.sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }.first(where: { child in
      isDirectory(child, fileManager: fileManager)
        && fileManager.fileExists(atPath: child.appendingPathComponent("__main__.py").path)
    })?.lastPathComponent
  }

  private static func rootPythonTestFiles(
    root: URL,
    fileManager: FileManager
  ) -> [URL] {
    let children =
      (try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )) ?? []
    return children.filter { url in
      guard url.pathExtension.lowercased() == "py",
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      else { return false }
      let name = url.lastPathComponent.lowercased()
      return name.hasPrefix("test_") || name.hasSuffix("_test.py")
    }
  }

  private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
    var value: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &value) && value.boolValue
  }

  private static func stripTOMLComment(_ line: String) -> String {
    var quote: Character?
    var escaped = false
    for index in line.indices {
      let character = line[index]
      if escaped {
        escaped = false
        continue
      }
      if character == "\\", quote == "\"" {
        escaped = true
        continue
      }
      if character == "\"" || character == "'" {
        if quote == character { quote = nil } else if quote == nil { quote = character }
        continue
      }
      if character == "#", quote == nil { return String(line[..<index]) }
    }
    return line
  }

  private static func unquoteTOML(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, let last = value.last,
      (first == "\"" && last == "\"") || (first == "'" && last == "'")
    else { return value }
    return String(value.dropFirst().dropLast())
  }

  private static func pythonStringLiteral(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
    return "'\(escaped)'"
  }

  private static func nodePlan(root: URL, fileManager: FileManager) -> EditorBuildPlan {
    let manager: String
    if exists("pnpm-lock.yaml", in: root, fileManager: fileManager) {
      manager = "pnpm"
    } else if exists("yarn.lock", in: root, fileManager: fileManager) {
      manager = "yarn"
    } else if exists("bun.lock", in: root, fileManager: fileManager)
      || exists("bun.lockb", in: root, fileManager: fileManager)
    {
      manager = "bun"
    } else {
      manager = "npm"
    }

    let scripts = packageScripts(root: root)
    let preferred: [(String, EditorBuildTaskKind)] = [
      ("build", .build), ("dev", .run), ("start", .run), ("test", .test),
      ("check", .check), ("lint", .check), ("clean", .clean),
    ]
    var seenKinds: Set<EditorBuildTaskKind> = []
    var commands: [EditorBuildCommand] = []
    for (name, kind) in preferred where scripts.contains(name) {
      if kind == .run, seenKinds.contains(.run) { continue }
      seenKinds.insert(kind)
      commands.append(
        command("node-\(name)", name.capitalized, kind, manager, ["run", name], root))
    }
    if commands.isEmpty {
      commands.append(command("node-install", "Install", .custom, manager, ["install"], root))
    }
    return EditorBuildPlan(projectKind: .nodePackage, commands: commands)
  }

  private static func packageScripts(root: URL) -> Set<String> {
    let url = root.appendingPathComponent("package.json")
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let scripts = object["scripts"] as? [String: Any]
    else { return [] }
    return Set(scripts.keys)
  }

  private static func plan(
    _ kind: EditorProjectBuildKind,
    root: URL,
    tasks: [(String, String, EditorBuildTaskKind, [String])]
  ) -> EditorBuildPlan {
    EditorBuildPlan(
      projectKind: kind,
      commands: tasks.compactMap { id, title, taskKind, invocation in
        guard let executable = invocation.first else { return nil }
        return command(id, title, taskKind, executable, Array(invocation.dropFirst()), root)
      }
    )
  }

  private static func command(
    _ id: String,
    _ title: String,
    _ kind: EditorBuildTaskKind,
    _ executable: String,
    _ arguments: [String],
    _ root: URL
  ) -> EditorBuildCommand {
    EditorBuildCommand(
      id: id,
      title: title,
      kind: kind,
      executable: executable,
      arguments: arguments,
      workingDirectory: root
    )
  }

  private static func exists(_ name: String, in root: URL, fileManager: FileManager) -> Bool {
    fileManager.fileExists(atPath: root.appendingPathComponent(name).path)
  }
}

public actor EditorBuildRunner {
  public private(set) var isRunning = false
  private var process: Process?
  private var standardOutput: Pipe?
  private var standardError: Pipe?
  private var streamState: EditorBuildStreamState?
  private var processGroupID: Int32?

  public init() {}

  public func run(
    _ command: EditorBuildCommand,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> AsyncStream<EditorBuildEvent> {
    guard !isRunning else { throw EditorBuildRunnerError.alreadyRunning }
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: command.workingDirectory.path,
        isDirectory: &isDirectory
      ), isDirectory.boolValue
    else {
      throw EditorBuildRunnerError.invalidWorkingDirectory(command.workingDirectory.path)
    }
    let launchEnvironment = EditorProcessEnvironment.prepared(
      base: environment.merging(command.environment) { _, commandValue in commandValue },
      workingDirectory: command.workingDirectory
    )
    let executableURL = try Self.resolveExecutable(
      command.executable,
      workingDirectory: command.workingDirectory,
      environment: launchEnvironment
    )

    let process = Process()
    let output = Pipe()
    let errorPipe = Pipe()
    let launch = Self.launchConfiguration(
      executableURL: executableURL,
      arguments: command.arguments
    )
    process.executableURL = launch.executableURL
    process.arguments = launch.arguments
    process.currentDirectoryURL = command.workingDirectory
    process.environment = launchEnvironment.merging([
      // SwiftPM requires both a PTY and a non-dumb terminal type before it
      // emits its normal incremental build progress.
      "TERM": launch.usesPTY ? "xterm-256color" : "dumb",
      "CLICOLOR": "0",
      "CLICOLOR_FORCE": "0",
      "NO_COLOR": "1",
      "PWD": command.workingDirectory.path,
    ]) { _, override in override }
    process.standardOutput = output
    process.standardError = errorPipe
    self.process = process
    standardOutput = output
    standardError = errorPipe
    isRunning = true

    return AsyncStream { continuation in
      let started = ContinuousClock.now
      let state = EditorBuildStreamState(
        command: command,
        continuation: continuation,
        started: started,
        normalizesPTYOutput: launch.usesPTY
      )
      self.streamState = state
      continuation.yield(.started(command))

      let readerGroup = DispatchGroup()
      Self.readPipe(
        output.fileHandleForReading,
        standardError: false,
        state: state,
        group: readerGroup
      )
      Self.readPipe(
        errorPipe.fileHandleForReading,
        standardError: true,
        state: state,
        group: readerGroup
      )
      process.terminationHandler = { [weak self] process in
        let exitCode = process.terminationStatus
        readerGroup.notify(queue: .global(qos: .utility)) {
          state.finish(exitCode: exitCode)
        }
        Task { await self?.didTerminate(process) }
      }
      continuation.onTermination = { [weak self] _ in
        Task { await self?.cancel() }
      }

      do {
        try process.run()
        self.processGroupID = Self.createProcessGroup(for: process.processIdentifier)
        output.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()
      } catch {
        output.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()
        state.failToLaunch(error)
        self.didFailToLaunch(process)
      }
    }
  }

  private nonisolated static func readPipe(
    _ handle: FileHandle,
    standardError: Bool,
    state: EditorBuildStreamState,
    group: DispatchGroup
  ) {
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer {
        try? handle.close()
        group.leave()
      }
      while true {
        // `read(upToCount:)` may coalesce pipe input until its requested size
        // or EOF. `availableData` returns as soon as the producer writes,
        // which is required for live compiler progress.
        let data = handle.availableData
        guard !data.isEmpty else { return }
        state.consume(data, standardError: standardError)
      }
    }
  }

  private static func resolveExecutable(
    _ configured: String,
    workingDirectory: URL,
    environment: [String: String]
  ) throws -> URL {
    guard
      let executableURL = EditorProcessEnvironment.executableURL(
        named: configured,
        workingDirectory: workingDirectory,
        environment: environment
      )
    else {
      throw EditorBuildRunnerError.executableUnavailable(configured)
    }
    return executableURL
  }

  private nonisolated static func launchConfiguration(
    executableURL: URL,
    arguments: [String]
  ) -> (executableURL: URL, arguments: [String], usesPTY: Bool) {
    #if canImport(Darwin)
      if executableURL.lastPathComponent == "swift" {
        let scriptURL = URL(fileURLWithPath: "/usr/bin/script")
        if FileManager.default.isExecutableFile(atPath: scriptURL.path) {
          return (
            scriptURL,
            // Without -F, macOS script(1) can buffer PTY output for up to
            // 30 seconds, hiding SwiftPM progress until the build finishes.
            ["-q", "-F", "/dev/null", executableURL.path] + arguments,
            true
          )
        }
      }
    #endif
    return (executableURL, arguments, false)
  }

  /// Cancels the current process tree, escalating from interrupt to terminate and finally kill.
  public func cancel(gracePeriod: Duration = .seconds(1)) async {
    guard let process, process.isRunning else { return }
    streamState?.markCancelled()
    signal(SIGINT, process: process)
    if await waitForTermination(of: process, timeout: gracePeriod) { return }

    signal(SIGTERM, process: process)
    if await waitForTermination(of: process, timeout: gracePeriod) { return }

    signal(SIGKILL, process: process)
    _ = await waitForTermination(of: process, timeout: .milliseconds(500))
  }

  private func waitForTermination(of process: Process, timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while process.isRunning, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(25))
    }
    return !process.isRunning
  }

  private func signal(_ value: Int32, process: Process) {
    #if canImport(Darwin) || canImport(Glibc)
      if let processGroupID {
        _ = kill(-processGroupID, value)
      } else {
        _ = kill(process.processIdentifier, value)
      }
    #else
      if value == SIGINT {
        process.interrupt()
      } else {
        process.terminate()
      }
    #endif
  }

  private nonisolated static func createProcessGroup(for processID: Int32) -> Int32? {
    #if canImport(Darwin) || canImport(Glibc)
      if setpgid(processID, processID) == 0 || getpgid(processID) == processID {
        return processID
      }
    #endif
    return nil
  }

  private func didTerminate(_ completed: Process) {
    if process === completed {
      process = nil
      standardOutput = nil
      standardError = nil
      streamState = nil
      processGroupID = nil
      isRunning = false
    }
  }

  private func didFailToLaunch(_ failed: Process) {
    if process === failed {
      process = nil
      standardOutput = nil
      standardError = nil
      streamState = nil
      processGroupID = nil
      isRunning = false
    }
  }
}

private final class EditorBuildStreamState: @unchecked Sendable {
  private static let ansiExpression = try? NSRegularExpression(
    pattern: #"\u001B\[[0-?]*[ -/]*[@-~]"#
  )
  private let lock = NSLock()
  private let command: EditorBuildCommand
  private let continuation: AsyncStream<EditorBuildEvent>.Continuation
  private let started: ContinuousClock.Instant
  private var outputParser: EditorBuildOutputParser
  private var errorParser: EditorBuildOutputParser
  private var outputDecoder = IncrementalUTF8Decoder()
  private var errorDecoder = IncrementalUTF8Decoder()
  private var outputBuffer = ""
  private var errorBuffer = ""
  private let normalizesPTYOutput: Bool
  private var isFirstPTYOutput = true
  private var emittedDiagnostics: Set<EditorBuildDiagnostic> = []
  private var cancelled = false

  private static let maximumDiagnosticBufferBytes = 1_000_000
  private static let retainedDiagnosticBufferBytes = 64_000
  private var finished = false

  init(
    command: EditorBuildCommand,
    continuation: AsyncStream<EditorBuildEvent>.Continuation,
    started: ContinuousClock.Instant,
    normalizesPTYOutput: Bool = false
  ) {
    self.command = command
    self.continuation = continuation
    self.started = started
    self.normalizesPTYOutput = normalizesPTYOutput
    self.outputParser = EditorBuildOutputParser(workspaceURL: command.workingDirectory)
    self.errorParser = EditorBuildOutputParser(workspaceURL: command.workingDirectory)
  }

  func consume(_ data: Data, standardError: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    let text = standardError ? errorDecoder.decode(data) : outputDecoder.decode(data)
    consumeDecoded(text, standardError: standardError)
  }

  func markCancelled() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func finish(exitCode: Int32) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    consumeDecoded(outputDecoder.finish(), standardError: false)
    consumeDecoded(errorDecoder.finish(), standardError: true)
    consumeRemainder(&outputBuffer, standardError: false)
    consumeRemainder(&errorBuffer, standardError: true)
    finished = true
    continuation.yield(
      .finished(
        EditorBuildResult(
          commandID: command.id,
          exitCode: exitCode,
          duration: started.duration(to: .now),
          wasCancelled: cancelled
        )))
    continuation.finish()
  }

  func failToLaunch(_ error: Error) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    finished = true
    continuation.yield(.output("\(error.localizedDescription)\n", standardError: true))
    continuation.yield(
      .finished(
        EditorBuildResult(
          commandID: command.id,
          exitCode: -1,
          duration: started.duration(to: .now)
        )))
    continuation.finish()
  }

  private func consumeDecoded(_ rawText: String, standardError: Bool) {
    var text = rawText
    if normalizesPTYOutput {
      if isFirstPTYOutput {
        isFirstPTYOutput = false
        if text.hasPrefix("\u{4}\u{8}\u{8}") {
          text.removeFirst(3)
        }
      }
      text = text.replacingOccurrences(of: "\r\n", with: "\n")
      text = text.replacingOccurrences(of: "\r", with: "\n")
      if let expression = Self.ansiExpression {
        let range = NSRange(location: 0, length: (text as NSString).length)
        text = expression.stringByReplacingMatches(
          in: text,
          range: range,
          withTemplate: ""
        )
      }
    }
    guard !text.isEmpty else { return }
    continuation.yield(.output(text, standardError: standardError))
    if standardError {
      errorBuffer += text
      consumeCompleteLines(from: &errorBuffer, standardError: true)
      boundDiagnosticBuffer(&errorBuffer)
    } else {
      outputBuffer += text
      consumeCompleteLines(from: &outputBuffer, standardError: false)
      boundDiagnosticBuffer(&outputBuffer)
    }
  }

  private func consumeCompleteLines(from buffer: inout String, standardError: Bool) {
    while let newline = buffer.firstIndex(of: "\n") {
      let line = String(buffer[..<newline])
      buffer.removeSubrange(...newline)
      emitDiagnostic(for: line, standardError: standardError)
    }
  }

  private func boundDiagnosticBuffer(_ buffer: inout String) {
    guard buffer.utf8.count > Self.maximumDiagnosticBufferBytes else { return }
    var suffix = buffer.utf8.suffix(Self.retainedDiagnosticBufferBytes)
    while let first = suffix.first, (0x80...0xBF).contains(first) {
      suffix = suffix.dropFirst()
    }
    buffer = String(decoding: suffix, as: UTF8.self)
  }

  private func consumeRemainder(_ buffer: inout String, standardError: Bool) {
    guard !buffer.isEmpty else { return }
    emitDiagnostic(for: buffer, standardError: standardError)
    buffer.removeAll(keepingCapacity: false)
  }

  private func emitDiagnostic(for line: String, standardError: Bool) {
    let diagnostic =
      standardError
      ? errorParser.consume(line: line)
      : outputParser.consume(line: line)
    if let diagnostic, emittedDiagnostics.insert(diagnostic).inserted {
      continuation.yield(.diagnostic(diagnostic))
    }
  }
}

private struct EditorBuildOutputParser {
  private let workspaceURL: URL
  private var pendingRustMessage: (Diagnostic.Severity, String)?
  private var pendingPythonLocation: (path: String, line: String)?

  private static let ansiExpression = try? NSRegularExpression(
    pattern: #"\u001B\[[0-?]*[ -/]*[@-~]"#
  )
  private static let colonExpression = try? NSRegularExpression(
    pattern:
      #"^(.+?):([0-9]+):([0-9]+)(?::|\s*-\s*)(?:(fatal error|error|warning|note|help|remark|information|info|hint)(?:\[([^\]]+)\])?:\s*)?(.*)$"#,
    options: [.caseInsensitive]
  )
  private static let lineOnlyExpression = try? NSRegularExpression(
    pattern:
      #"^(.+?):([0-9]+):\s*(?:(fatal error|error|warning|note|help|remark|information|info|hint)(?:\[([^\]]+)\])?:\s*)?(.*)$"#,
    options: [.caseInsensitive]
  )
  private static let parenthesizedExpression = try? NSRegularExpression(
    pattern:
      #"^(.+?)\(([0-9]+),([0-9]+)\):\s*(fatal error|error|warning|note|remark|info)?\s*([^:]*):?\s*(.*)$"#,
    options: [.caseInsensitive]
  )
  private static let kotlinParenthesizedExpression = try? NSRegularExpression(
    pattern:
      #"^(.+?):\s*\(([0-9]+),\s*([0-9]+)\):\s*(fatal error|error|warning|note|remark|info)?\s*(.*)$"#,
    options: [.caseInsensitive]
  )
  private static let bracketExpression = try? NSRegularExpression(
    pattern: #"^\[(ERROR|WARNING|WARN|INFO|NOTE)\]\s+(.+?):?\[([0-9]+),([0-9]+)\]\s*(.*)$"#,
    options: [.caseInsensitive]
  )
  private static let rustHeaderExpression = try? NSRegularExpression(
    pattern: #"^(error|warning|note|help)(?:\[([^\]]+)\])?:\s*(.*)$"#,
    options: [.caseInsensitive]
  )
  private static let rustLocationExpression = try? NSRegularExpression(
    pattern: #"^\s*-->\s+(.+?):([0-9]+):([0-9]+)\s*$"#
  )
  private static let pythonLocationExpression = try? NSRegularExpression(
    pattern: #"^\s*File \"(.+?)\", line ([0-9]+)(?:, in .*)?$"#
  )
  private static let pythonExceptionExpression = try? NSRegularExpression(
    pattern: #"^([A-Za-z_][A-Za-z0-9_.]*(?:Error|Exception|Warning)):\s*(.*)$"#
  )
  private static let codePrefixExpression = try? NSRegularExpression(
    pattern: #"^(TS[0-9]+|[A-Z][A-Z0-9_-]*[0-9]+):\s*(.*)$"#
  )

  init(workspaceURL: URL) {
    self.workspaceURL = workspaceURL.standardizedFileURL
  }

  mutating func consume(line rawLine: String) -> EditorBuildDiagnostic? {
    let rawRange = NSRange(location: 0, length: (rawLine as NSString).length)
    let plainLine =
      Self.ansiExpression?.stringByReplacingMatches(
        in: rawLine,
        range: rawRange,
        withTemplate: ""
      ) ?? rawLine
    let line = normalizedDiagnosticLine(plainLine.trimmingCharacters(in: .newlines))

    if let cargo = cargoDiagnostic(from: line) { return cargo }

    if let expression = Self.pythonLocationExpression,
      let values = captures(expression, in: line), values.count == 2
    {
      pendingPythonLocation = (values[0], values[1])
      return nil
    }
    if let expression = Self.pythonExceptionExpression,
      let values = captures(expression, in: line), values.count == 2,
      let location = pendingPythonLocation
    {
      pendingPythonLocation = nil
      let message = values[1].isEmpty ? values[0] : "\(values[0]): \(values[1])"
      return diagnostic(
        path: location.path, line: location.line, column: "1", severity: .error,
        message: message, code: values[0], source: "python"
      )
    }

    if let expression = Self.bracketExpression,
      let values = captures(expression, in: line), values.count == 5
    {
      return diagnostic(
        path: values[1], line: values[2], column: values[3],
        severity: severity(values[0]), message: values[4], source: "maven"
      )
    }
    if let expression = Self.kotlinParenthesizedExpression,
      let values = captures(expression, in: line), values.count == 5
    {
      let parsed = parsedSeverityAndMessage(
        explicitSeverity: values[3], message: values[4], fallback: .error
      )
      return diagnostic(
        path: values[0], line: values[1], column: values[2], severity: parsed.severity,
        message: parsed.message, source: "kotlin"
      )
    }
    if let expression = Self.parenthesizedExpression,
      let values = captures(expression, in: line), values.count == 6
    {
      let detail = [values[4], values[5]].filter { !$0.isEmpty }.joined(separator: ": ")
      let parsed = parsedSeverityAndMessage(
        explicitSeverity: values[3], message: detail, fallback: .error
      )
      let (code, message) = splitCode(from: parsed.message)
      return diagnostic(
        path: values[0], line: values[1], column: values[2], severity: parsed.severity,
        message: message, code: code, source: inferredSource(code: code, path: values[0])
      )
    }
    if let expression = Self.rustHeaderExpression,
      let values = captures(expression, in: line), values.count == 3
    {
      let message = values[2].isEmpty ? values[1] : values[2]
      pendingRustMessage = (severity(values[0]), message)
      return nil
    }
    if let expression = Self.rustLocationExpression,
      let values = captures(expression, in: line), values.count == 3,
      let pendingRustMessage
    {
      self.pendingRustMessage = nil
      return diagnostic(
        path: values[0], line: values[1], column: values[2],
        severity: pendingRustMessage.0, message: pendingRustMessage.1, source: "rustc"
      )
    }
    if let expression = Self.colonExpression,
      let values = captures(expression, in: line), values.count == 6
    {
      let parsed = parsedSeverityAndMessage(
        explicitSeverity: values[3], message: values[5], fallback: .error
      )
      let explicitCode = values[4].isEmpty ? nil : values[4]
      let split = splitCode(from: parsed.message)
      return diagnostic(
        path: values[0], line: values[1], column: values[2],
        severity: parsed.severity, message: split.message,
        code: explicitCode ?? split.code,
        source: inferredSource(code: explicitCode ?? split.code, path: values[0])
      )
    }
    if let expression = Self.lineOnlyExpression,
      let values = captures(expression, in: line), values.count == 5
    {
      let parsed = parsedSeverityAndMessage(
        explicitSeverity: values[2], message: values[4], fallback: .error
      )
      let explicitCode = values[3].isEmpty ? nil : values[3]
      let split = splitCode(from: parsed.message)
      return diagnostic(
        path: values[0], line: values[1], column: "1",
        severity: parsed.severity, message: split.message,
        code: explicitCode ?? split.code,
        source: inferredSource(code: explicitCode ?? split.code, path: values[0])
      )
    }
    return nil
  }

  private mutating func cargoDiagnostic(from line: String) -> EditorBuildDiagnostic? {
    guard line.first == "{", let data = line.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      root["reason"] as? String == "compiler-message",
      let message = root["message"] as? [String: Any]
    else { return nil }
    let spans = message["spans"] as? [[String: Any]] ?? []
    guard let span = spans.first(where: { ($0["is_primary"] as? Bool) == true }) ?? spans.first,
      let path = span["file_name"] as? String,
      let lineStart = span["line_start"] as? Int,
      let columnStart = span["column_start"] as? Int
    else { return nil }
    let code = (message["code"] as? [String: Any])?["code"] as? String
    return diagnostic(
      path: path,
      line: String(lineStart),
      column: String(columnStart),
      endLine: span["line_end"] as? Int,
      endColumn: span["column_end"] as? Int,
      severity: severity(message["level"] as? String ?? "error"),
      message: message["message"] as? String ?? "Rust compiler diagnostic",
      code: code,
      source: "rustc"
    )
  }

  private func normalizedDiagnosticLine(_ line: String) -> String {
    guard line.count > 3 else { return line }
    let prefixes = ["e: ", "w: ", "i: ", "error: ", "warning: "]
    if let prefix = prefixes.first(where: { line.lowercased().hasPrefix($0) }),
      ["e: ", "w: ", "i: "].contains(prefix)
    {
      return String(line.dropFirst(prefix.count))
    }
    return line
  }

  private func parsedSeverityAndMessage(
    explicitSeverity: String,
    message: String,
    fallback: Diagnostic.Severity
  ) -> (severity: Diagnostic.Severity, message: String) {
    guard explicitSeverity.isEmpty else { return (severity(explicitSeverity), message) }
    let trimmed = message.trimmingCharacters(in: .whitespaces)
    let labels = [
      "fatal error", "error", "warning", "warn", "note", "help", "remark",
      "information", "info", "hint",
    ]
    let lowercased = trimmed.lowercased()
    for label in labels {
      let prefix = label + ":"
      guard lowercased.hasPrefix(prefix) else { continue }
      let content = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
      return (severity(label), content)
    }
    return (fallback, trimmed)
  }

  private func splitCode(from value: String) -> (code: String?, message: String) {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard let expression = Self.codePrefixExpression,
      let values = captures(expression, in: trimmed), values.count == 2
    else { return (nil, trimmed) }
    return (values[0], values[1])
  }

  private func inferredSource(code: String?, path: String) -> String? {
    if code?.hasPrefix("TS") == true { return "typescript" }
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "swift": return "swiftc"
    case "c", "cc", "cpp", "cxx", "m", "mm", "h", "hpp": return "clang"
    case "java": return "javac"
    case "kt", "kts": return "kotlin"
    case "go": return "go"
    case "py", "pyw": return "python"
    case "ts", "tsx": return "typescript"
    default: return nil
    }
  }

  private func diagnostic(
    path: String,
    line: String,
    column: String,
    endLine: Int? = nil,
    endColumn: Int? = nil,
    severity: Diagnostic.Severity,
    message: String,
    code: String? = nil,
    source: String? = nil
  ) -> EditorBuildDiagnostic? {
    guard let lineNumber = Int(line), let columnNumber = Int(column) else { return nil }
    let cleanedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    guard !cleanedPath.isEmpty, !cleanedPath.hasPrefix("<") else { return nil }
    let expanded = NSString(string: cleanedPath).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded, relativeTo: workspaceURL).standardizedFileURL
    let normalizedMessage = message.trimmingCharacters(in: .whitespaces)
    guard !normalizedMessage.isEmpty else { return nil }
    return EditorBuildDiagnostic(
      url: url,
      line: lineNumber,
      column: columnNumber,
      endLine: endLine,
      endColumn: endColumn,
      severity: severity,
      message: normalizedMessage,
      code: code,
      source: source
    )
  }

  private func severity(_ value: String) -> Diagnostic.Severity {
    switch value.lowercased() {
    case "warning", "warn": return .warning
    case "note", "information", "info", "remark": return .information
    case "help", "hint": return .hint
    default: return .error
    }
  }

  private func captures(_ expression: NSRegularExpression, in value: String) -> [String]? {
    let source = value as NSString
    let range = NSRange(location: 0, length: source.length)
    guard let match = expression.firstMatch(in: value, range: range),
      match.range.location != NSNotFound
    else { return nil }
    return (1..<match.numberOfRanges).map { index in
      let capture = match.range(at: index)
      return capture.location == NSNotFound ? "" : source.substring(with: capture)
    }
  }
}
