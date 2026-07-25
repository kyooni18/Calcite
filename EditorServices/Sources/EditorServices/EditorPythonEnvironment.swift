import Foundation

public enum EditorPythonEnvironmentKind: String, Hashable, Codable, Sendable {
  case virtualenv
  case conda
  case explicitInterpreter
}

/// A Python environment selected for an editor workspace.
public struct EditorPythonEnvironment: Hashable, Codable, Sendable {
  public var rootURL: URL
  public var executableURL: URL
  public var binURL: URL
  public var kind: EditorPythonEnvironmentKind

  public init(
    rootURL: URL,
    executableURL: URL,
    binURL: URL,
    kind: EditorPythonEnvironmentKind = .virtualenv
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.executableURL = executableURL.standardizedFileURL
    self.binURL = binURL.standardizedFileURL
    self.kind = kind
  }

  public var name: String {
    let value = rootURL.lastPathComponent
    return value.isEmpty ? "Python" : value
  }
}

/// Detects Python environments and produces one consistent environment for build, run,
/// test, formatter, language-server, debugger and terminal processes.
public enum EditorPythonEnvironmentResolver {
  private static let preferredDirectoryNames = [".venv", "venv", ".env", "env"]
  private static let skippedDirectoryNames: Set<String> = [
    ".build", ".git", ".hg", ".svn", ".tox", ".mypy_cache", ".pytest_cache",
    ".ruff_cache", "DerivedData", "Pods", "build", "dist", "node_modules", "target",
  ]
  private static let managedEnvironmentKeys = [
    "VIRTUAL_ENV", "VIRTUAL_ENV_PROMPT", "CONDA_PREFIX", "CONDA_DEFAULT_ENV",
    "CALCITE_PYTHON_VENV", "CALCITE_PYTHON_INTERPRETER", "PYTHONNOUSERSITE",
  ]

  public static func detect(
    workspaceURL: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    explicitInterpreterURL: URL? = nil,
    fileManager: FileManager = .default
  ) -> EditorPythonEnvironment? {
    let workspace = nearestWorkspaceRoot(from: workspaceURL, fileManager: fileManager)

    if let explicitInterpreterURL,
      let value = environmentForInterpreter(
        explicitInterpreterURL, kind: .explicitInterpreter, fileManager: fileManager)
    {
      return value
    }
    if let configured = environment["CALCITE_PYTHON_INTERPRETER"], !configured.isEmpty,
      let value = environmentForInterpreter(
        URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath),
        kind: .explicitInterpreter,
        fileManager: fileManager)
    {
      return value
    }

    // A workspace-owned environment is authoritative. In particular, an unrelated
    // VIRTUAL_ENV inherited from the shell must never hide this project's .venv.
    if let local = localEnvironment(in: workspace, fileManager: fileManager) {
      return local
    }

    for (key, kind) in [
      ("VIRTUAL_ENV", EditorPythonEnvironmentKind.virtualenv),
      ("CONDA_PREFIX", EditorPythonEnvironmentKind.conda),
    ] {
      guard let configured = environment[key], !configured.isEmpty else { continue }
      let candidate = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        .standardizedFileURL
      guard let value = resolvedEnvironment(at: candidate, kind: kind, fileManager: fileManager)
      else { continue }
      if isLinkedInheritedEnvironment(
        value,
        to: workspace,
        environment: environment,
        fileManager: fileManager
      ) {
        return value
      }
    }

    return nil
  }

  public static func activatedEnvironment(
    workspaceURL: URL,
    base: [String: String] = ProcessInfo.processInfo.environment,
    explicitInterpreterURL: URL? = nil,
    fileManager: FileManager = .default
  ) -> (environment: [String: String], python: EditorPythonEnvironment?) {
    let python = detect(
      workspaceURL: workspaceURL,
      environment: base,
      explicitInterpreterURL: explicitInterpreterURL,
      fileManager: fileManager
    )
    var environment = deactivatedEnvironment(base)
    guard let python else { return (environment, nil) }

    switch python.kind {
    case .conda:
      environment["CONDA_PREFIX"] = python.rootURL.path
      environment["CONDA_DEFAULT_ENV"] = python.name
      environment["CALCITE_PYTHON_VENV"] = python.rootURL.path
    case .virtualenv:
      environment["VIRTUAL_ENV"] = python.rootURL.path
      environment["VIRTUAL_ENV_PROMPT"] = "(\(python.name)) "
      environment["CALCITE_PYTHON_VENV"] = python.rootURL.path
    case .explicitInterpreter:
      break
    }
    environment["CALCITE_PYTHON_INTERPRETER"] = python.executableURL.path
    environment["PYTHONNOUSERSITE"] = "1"
    environment.removeValue(forKey: "PYTHONHOME")

    environment["PATH"] = prependingPath(
      python.binURL.path,
      to: environment["PATH"] ?? ""
    )
    return (environment, python)
  }

  /// Produces a shell command that changes an already-running terminal to the selected
  /// environment. Conda environments are activated through Conda's shell hook rather than
  /// by assuming that every environment has a virtualenv-style `bin/activate` script.
  public static func shellActivationCommand(
    for python: EditorPythonEnvironment?,
    shellPath: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    let shell = shellFlavor(shellPath)
    guard let python else { return shell.deactivationCommand }

    switch python.kind {
    case .conda:
      let conda = environment["CONDA_EXE"].flatMap { $0.isEmpty ? nil : $0 } ?? "conda"
      return shell.condaActivationCommand(
        condaExecutable: conda,
        environmentRoot: python.rootURL.path,
        interpreterPath: python.executableURL.path,
        binPath: python.binURL.path
      )
    case .virtualenv:
      #if os(Windows)
        let script = python.rootURL.appendingPathComponent("Scripts/activate").path
      #else
        let scriptName: String
        switch shell {
        case .fish: scriptName = "activate.fish"
        case .csh: scriptName = "activate.csh"
        case .posix: scriptName = "activate"
        }
        let script = python.rootURL.appendingPathComponent("bin/\(scriptName)").path
      #endif
      return shell.virtualEnvironmentActivationCommand(
        scriptPath: script,
        environmentRoot: python.rootURL.path,
        interpreterPath: python.executableURL.path
      )
    case .explicitInterpreter:
      return shell.directInterpreterActivationCommand(
        interpreterPath: python.executableURL.path,
        binPath: python.binURL.path
      )
    }
  }

  private static func localEnvironment(
    in workspace: URL,
    fileManager: FileManager
  ) -> EditorPythonEnvironment? {
    if let value = directlyContainedEnvironment(in: workspace, fileManager: fileManager) {
      return value
    }
    if let value = shallowSearch(in: workspace, fileManager: fileManager) {
      return value
    }

    // A directory opened below a project root may legitimately use the parent's environment.
    // Stop at the first project boundary so an unrelated ancestor cannot leak into the project.
    guard !isProjectBoundary(workspace, fileManager: fileManager) else { return nil }
    var current = workspace.deletingLastPathComponent().standardizedFileURL
    for _ in 0..<7 {
      if let value = directlyContainedEnvironment(in: current, fileManager: fileManager) {
        return value
      }
      if isProjectBoundary(current, fileManager: fileManager) { break }
      let parent = current.deletingLastPathComponent().standardizedFileURL
      if parent.path == current.path { break }
      current = parent
    }
    return nil
  }

  private static func directlyContainedEnvironment(
    in directory: URL,
    fileManager: FileManager
  ) -> EditorPythonEnvironment? {
    for name in preferredDirectoryNames {
      let candidate = directory.appendingPathComponent(name, isDirectory: true)
      if let value = resolvedEnvironment(at: candidate, fileManager: fileManager) { return value }
    }
    return resolvedEnvironment(at: directory, fileManager: fileManager)
  }

  private static func nearestWorkspaceRoot(
    from url: URL,
    fileManager: FileManager
  ) -> URL {
    var candidate = url.standardizedFileURL
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    {
      candidate.deleteLastPathComponent()
    }
    return candidate
  }

  private static func isProjectBoundary(_ url: URL, fileManager: FileManager) -> Bool {
    [
      ".git", "pyproject.toml", "Pipfile", "poetry.lock", "pdm.lock", "uv.lock",
      "requirements.txt", "setup.py", "setup.cfg", "tox.ini", "environment.yml",
      "environment.yaml", "Package.swift", "Cargo.toml",
    ].contains { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }
  }

  private static func shallowSearch(
    in workspace: URL,
    fileManager: FileManager
  ) -> EditorPythonEnvironment? {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
    guard
      let enumerator = fileManager.enumerator(
        at: workspace,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsPackageDescendants],
        errorHandler: { _, _ in true }
      )
    else { return nil }

    let rootComponents = workspace.pathComponents.count
    while let url = enumerator.nextObject() as? URL {
      let depth = url.pathComponents.count - rootComponents
      if depth > 3 {
        enumerator.skipDescendants()
        continue
      }

      let values = try? url.resourceValues(forKeys: keys)
      guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
      let name = values?.name ?? url.lastPathComponent
      if skippedDirectoryNames.contains(name) {
        enumerator.skipDescendants()
        continue
      }
      if let value = resolvedEnvironment(at: url, fileManager: fileManager),
        preferredDirectoryNames.contains(name) || depth <= 3
      {
        return value
      }
    }
    return nil
  }

  private static func environmentForInterpreter(
    _ executableURL: URL,
    kind: EditorPythonEnvironmentKind,
    fileManager: FileManager
  ) -> EditorPythonEnvironment? {
    let executable = executableURL.standardizedFileURL
    guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
    let bin = executable.deletingLastPathComponent()
    let root: URL
    #if os(Windows)
      root = bin.lastPathComponent.lowercased() == "scripts" ? bin.deletingLastPathComponent() : bin
    #else
      root = bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : bin
    #endif
    let resolvedKind: EditorPythonEnvironmentKind
    if fileManager.fileExists(
      atPath: root.appendingPathComponent("conda-meta", isDirectory: true).path
    ) {
      resolvedKind = .conda
    } else if fileManager.fileExists(atPath: root.appendingPathComponent("pyvenv.cfg").path) {
      resolvedKind = .virtualenv
    } else {
      resolvedKind = kind
    }
    return EditorPythonEnvironment(
      rootURL: root, executableURL: executable, binURL: bin, kind: resolvedKind)
  }

  private static func resolvedEnvironment(
    at rootURL: URL,
    kind: EditorPythonEnvironmentKind = .virtualenv,
    fileManager: FileManager
  ) -> EditorPythonEnvironment? {
    let root = rootURL.standardizedFileURL
    let hasVenvMarker = fileManager.fileExists(
      atPath: root.appendingPathComponent("pyvenv.cfg").path)
    let isConda =
      kind == .conda
      || fileManager.fileExists(
        atPath: root.appendingPathComponent("conda-meta", isDirectory: true).path)
    guard hasVenvMarker || isConda else { return nil }

    #if os(Windows)
      let binURL = root.appendingPathComponent("Scripts", isDirectory: true)
      let candidates = ["python.exe", "python3.exe"]
    #else
      let binURL = root.appendingPathComponent("bin", isDirectory: true)
      let candidates = ["python", "python3"]
    #endif

    for name in candidates {
      let executable = binURL.appendingPathComponent(name)
      if fileManager.isExecutableFile(atPath: executable.path) {
        return EditorPythonEnvironment(
          rootURL: root,
          executableURL: executable,
          binURL: binURL,
          kind: isConda ? .conda : kind
        )
      }
    }
    return nil
  }

  private static func isLinkedInheritedEnvironment(
    _ candidate: EditorPythonEnvironment,
    to workspace: URL,
    environment: [String: String],
    fileManager: FileManager
  ) -> Bool {
    if isContained(candidate.rootURL, in: workspace) { return true }

    switch candidate.kind {
    case .conda:
      return condaEnvironmentIsLinked(
        candidate,
        to: workspace,
        environment: environment,
        fileManager: fileManager
      )
    case .virtualenv, .explicitInterpreter:
      return virtualEnvironmentIsLinked(candidate, to: workspace, fileManager: fileManager)
    }
  }

  private static func condaEnvironmentIsLinked(
    _ candidate: EditorPythonEnvironment,
    to workspace: URL,
    environment: [String: String],
    fileManager: FileManager
  ) -> Bool {
    for name in ["environment.yml", "environment.yaml"] {
      let url = workspace.appendingPathComponent(name)
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("prefix:") {
          let value = String(line.dropFirst("prefix:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
          let expanded = NSString(string: value).expandingTildeInPath
          if URL(fileURLWithPath: expanded).standardizedFileURL == candidate.rootURL {
            return true
          }
        }
        if line.hasPrefix("name:") {
          let value = unquotedYAMLValue(String(line.dropFirst("name:".count)))
          let activeName = environment["CONDA_DEFAULT_ENV"] ?? candidate.name
          if !value.isEmpty, value == activeName || value == candidate.name { return true }
        }
      }
    }
    return false
  }

  private static func virtualEnvironmentIsLinked(
    _ candidate: EditorPythonEnvironment,
    to workspace: URL,
    fileManager: FileManager
  ) -> Bool {
    let projectLink = candidate.rootURL.appendingPathComponent(".project")
    if let value = try? String(contentsOf: projectLink, encoding: .utf8) {
      let linked = URL(
        fileURLWithPath: NSString(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
          .expandingTildeInPath
      ).standardizedFileURL
      if linked == workspace { return true }
    }

    let workspaceName = normalizedEnvironmentName(workspace.lastPathComponent)
    let environmentName = normalizedEnvironmentName(candidate.name)
    guard !workspaceName.isEmpty else { return false }
    if environmentName == workspaceName || environmentName.hasPrefix(workspaceName + "-") {
      return true
    }

    let config = candidate.rootURL.appendingPathComponent("pyvenv.cfg")
    if let text = try? String(contentsOf: config, encoding: .utf8) {
      for rawLine in text.split(whereSeparator: \.isNewline) {
        let parts = rawLine.split(separator: "=", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if parts.count == 2, parts[0].lowercased() == "prompt",
          normalizedEnvironmentName(
            parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\"")))
            == workspaceName
        {
          return true
        }
      }
    }
    return false
  }

  private static func isContained(_ candidate: URL, in workspace: URL) -> Bool {
    let root = workspace.standardizedFileURL.path
    let path = candidate.standardizedFileURL.path
    return path == root || path.hasPrefix(root + "/")
  }

  private static func deactivatedEnvironment(_ base: [String: String]) -> [String: String] {
    var environment = base
    let staleBins = ["VIRTUAL_ENV", "CONDA_PREFIX", "CALCITE_PYTHON_VENV"].compactMap {
      environment[$0]
    }.flatMap { root -> [String] in
      let url = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath)
      return [
        url.appendingPathComponent("bin", isDirectory: true).path,
        url.appendingPathComponent("Scripts", isDirectory: true).path,
      ]
    }
    if let path = environment["PATH"] {
      environment["PATH"] = removingPaths(staleBins, from: path)
    }
    for key in managedEnvironmentKeys { environment.removeValue(forKey: key) }
    environment.removeValue(forKey: "PYTHONHOME")
    return environment
  }

  private static func prependingPath(_ value: String, to path: String) -> String {
    let separator = pathListSeparator
    let entries = path.split(separator: separator, omittingEmptySubsequences: false).map(
      String.init)
    return ([value] + entries.filter { $0 != value }).joined(separator: String(separator))
  }

  private static func removingPaths(_ values: [String], from path: String) -> String {
    let blocked = Set(values.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    let separator = pathListSeparator
    return path.split(separator: separator, omittingEmptySubsequences: false)
      .map(String.init)
      .filter { entry in
        guard !entry.isEmpty else { return true }
        return !blocked.contains(URL(fileURLWithPath: entry).standardizedFileURL.path)
      }
      .joined(separator: String(separator))
  }

  private static var pathListSeparator: Character {
    #if os(Windows)
      return ";"
    #else
      return ":"
    #endif
  }

  private enum ShellFlavor {
    case posix(name: String)
    case fish
    case csh

    var deactivationCommand: String {
      switch self {
      case .posix:
        return "deactivate 2>/dev/null || true; conda deactivate 2>/dev/null || true; "
          + "unset VIRTUAL_ENV VIRTUAL_ENV_PROMPT CONDA_PREFIX CONDA_DEFAULT_ENV "
          + "CALCITE_PYTHON_VENV CALCITE_PYTHON_INTERPRETER PYTHONNOUSERSITE\n"
      case .fish:
        return "functions -q deactivate; and deactivate; type -q conda; and conda deactivate; "
          + fishUnsetCommands + "\n"
      case .csh:
        return cshUnsetCommands + "\n"
      }
    }

    func virtualEnvironmentActivationCommand(
      scriptPath: String,
      environmentRoot: String,
      interpreterPath: String
    ) -> String {
      let script = EditorPythonEnvironmentResolver.shellQuote(scriptPath)
      let root = EditorPythonEnvironmentResolver.shellQuote(environmentRoot)
      let interpreter = EditorPythonEnvironmentResolver.shellQuote(interpreterPath)
      switch self {
      case .posix:
        return "conda deactivate 2>/dev/null || true; deactivate 2>/dev/null || true; "
          + "source \(script); export CALCITE_PYTHON_VENV=\(root); "
          + "export CALCITE_PYTHON_INTERPRETER=\(interpreter); export PYTHONNOUSERSITE=1\n"
      case .fish:
        return "type -q conda; and conda deactivate; functions -q deactivate; and deactivate; "
          + "source \(script); set -gx CALCITE_PYTHON_VENV \(root); "
          + "set -gx CALCITE_PYTHON_INTERPRETER \(interpreter); "
          + "set -gx PYTHONNOUSERSITE 1\n"
      case .csh:
        return "source \(script); setenv CALCITE_PYTHON_VENV \(root); "
          + "setenv CALCITE_PYTHON_INTERPRETER \(interpreter); setenv PYTHONNOUSERSITE 1\n"
      }
    }

    func directInterpreterActivationCommand(
      interpreterPath: String,
      binPath: String
    ) -> String {
      let interpreter = EditorPythonEnvironmentResolver.shellQuote(interpreterPath)
      let bin = EditorPythonEnvironmentResolver.shellQuote(binPath)
      switch self {
      case .posix:
        return "deactivate 2>/dev/null || true; conda deactivate 2>/dev/null || true; "
          + "unset VIRTUAL_ENV VIRTUAL_ENV_PROMPT CONDA_PREFIX CONDA_DEFAULT_ENV "
          + "CALCITE_PYTHON_VENV; export CALCITE_PYTHON_INTERPRETER=\(interpreter); "
          + "export PYTHONNOUSERSITE=1; export PATH=\(bin):\"$PATH\"\n"
      case .fish:
        return "functions -q deactivate; and deactivate; type -q conda; and conda deactivate; "
          + fishUnsetCommands + "; set -gx CALCITE_PYTHON_INTERPRETER \(interpreter); "
          + "set -gx PYTHONNOUSERSITE 1; set -gx PATH \(bin) $PATH\n"
      case .csh:
        return cshUnsetCommands + "; setenv CALCITE_PYTHON_INTERPRETER \(interpreter); "
          + "setenv PYTHONNOUSERSITE 1; setenv PATH \(bin):\"$PATH\"\n"
      }
    }

    func condaActivationCommand(
      condaExecutable: String,
      environmentRoot: String,
      interpreterPath: String,
      binPath: String
    ) -> String {
      let conda = EditorPythonEnvironmentResolver.shellQuote(condaExecutable)
      let root = EditorPythonEnvironmentResolver.shellQuote(environmentRoot)
      let interpreter = EditorPythonEnvironmentResolver.shellQuote(interpreterPath)
      let bin = EditorPythonEnvironmentResolver.shellQuote(binPath)
      switch self {
      case .posix(let name):
        return "deactivate 2>/dev/null || true; "
          + "if command -v \(conda) >/dev/null 2>&1; then "
          + "eval \"$(\(conda) shell.\(name) hook 2>/dev/null)\" && conda activate \(root); "
          + "else export CONDA_PREFIX=\(root); export PATH=\(bin):\"$PATH\"; fi; "
          + "export CALCITE_PYTHON_VENV=\(root); "
          + "export CALCITE_PYTHON_INTERPRETER=\(interpreter); export PYTHONNOUSERSITE=1\n"
      case .fish:
        return "functions -q deactivate; and deactivate; "
          + "if eval (\(conda) shell.fish hook 2>/dev/null); and conda activate \(root); "
          + "else; set -gx CONDA_PREFIX \(root); set -gx PATH \(bin) $PATH; end; "
          + "set -gx CALCITE_PYTHON_VENV \(root); "
          + "set -gx CALCITE_PYTHON_INTERPRETER \(interpreter); "
          + "set -gx PYTHONNOUSERSITE 1\n"
      case .csh:
        // Conda's C-shell hook is not guaranteed to be installed. Setting the environment and
        // PATH directly still makes the selected interpreter and packages authoritative.
        return "setenv CONDA_PREFIX \(root); setenv PATH \(bin):\"$PATH\"; "
          + "setenv CALCITE_PYTHON_VENV \(root); "
          + "setenv CALCITE_PYTHON_INTERPRETER \(interpreter); setenv PYTHONNOUSERSITE 1\n"
      }
    }

    private var fishUnsetCommands: String {
      [
        "VIRTUAL_ENV", "VIRTUAL_ENV_PROMPT", "CONDA_PREFIX", "CONDA_DEFAULT_ENV",
        "CALCITE_PYTHON_VENV", "CALCITE_PYTHON_INTERPRETER", "PYTHONNOUSERSITE",
      ].map { "set -e \($0)" }.joined(separator: "; ")
    }

    private var cshUnsetCommands: String {
      [
        "VIRTUAL_ENV", "VIRTUAL_ENV_PROMPT", "CONDA_PREFIX", "CONDA_DEFAULT_ENV",
        "CALCITE_PYTHON_VENV", "CALCITE_PYTHON_INTERPRETER", "PYTHONNOUSERSITE",
      ].map { "if ( $?\($0) ) unsetenv \($0)" }.joined(separator: "; ")
    }
  }

  private static func shellFlavor(_ shellPath: String) -> ShellFlavor {
    switch URL(fileURLWithPath: shellPath).lastPathComponent.lowercased() {
    case "bash": return .posix(name: "bash")
    case "fish": return .fish
    case "tcsh", "csh": return .csh
    default: return .posix(name: "zsh")
    }
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func normalizedEnvironmentName(_ value: String) -> String {
    value.lowercased().unicodeScalars.map { scalar in
      CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
    }.reduce(into: "") { result, character in
      if character != "-" || result.last != "-" { result.append(character) }
    }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private static func unquotedYAMLValue(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
  }
}
