import Foundation

/// Builds a deterministic command-line environment for processes launched by a GUI app.
///
/// Applications started from Finder usually inherit a minimal `PATH`, which omits user
/// toolchains such as Rustup, mise, asdf, Swiftly, Homebrew, and locally installed tools.
/// Build, run, debug, and terminal integrations should use this environment instead of
/// assuming the app process inherited the user's interactive-shell configuration.
public enum EditorProcessEnvironment {
  public static func prepared(
    base: [String: String] = ProcessInfo.processInfo.environment,
    workingDirectory: URL? = nil
  ) -> [String: String] {
    var environment = base
    if let workingDirectory {
      environment =
        EditorPythonEnvironmentResolver.activatedEnvironment(
          workspaceURL: workingDirectory,
          base: environment
        ).environment
    }
    let homeURL = resolvedHomeURL(environment: environment)
    if environment["HOME"]?.isEmpty != false {
      environment["HOME"] = homeURL.path
    }

    var preferred: [String] = []
    func add(_ path: String?) {
      guard let path else { return }
      let expanded = NSString(string: path).expandingTildeInPath
      guard !expanded.isEmpty, !preferred.contains(expanded) else { return }
      preferred.append(expanded)
    }

    if let interpreter = environment["CALCITE_PYTHON_INTERPRETER"], !interpreter.isEmpty {
      add(URL(fileURLWithPath: interpreter).deletingLastPathComponent().path)
    }

    if let workingDirectory {
      let directory = workingDirectory.standardizedFileURL
      add(directory.appendingPathComponent("node_modules/.bin", isDirectory: true).path)
      add(directory.appendingPathComponent(".tools/bin", isDirectory: true).path)
      add(directory.appendingPathComponent("bin", isDirectory: true).path)
    }

    if let cargoHome = environment["CARGO_HOME"], !cargoHome.isEmpty {
      add(
        URL(fileURLWithPath: NSString(string: cargoHome).expandingTildeInPath, isDirectory: true)
          .appendingPathComponent("bin", isDirectory: true).path)
    }
    if let miseData = environment["MISE_DATA_DIR"], !miseData.isEmpty {
      add(
        URL(fileURLWithPath: NSString(string: miseData).expandingTildeInPath, isDirectory: true)
          .appendingPathComponent("shims", isDirectory: true).path)
    }
    if let asdfData = environment["ASDF_DATA_DIR"], !asdfData.isEmpty {
      add(
        URL(fileURLWithPath: NSString(string: asdfData).expandingTildeInPath, isDirectory: true)
          .appendingPathComponent("shims", isDirectory: true).path)
    }
    if let swiftlyHome = environment["SWIFTLY_HOME_DIR"], !swiftlyHome.isEmpty {
      add(
        URL(fileURLWithPath: NSString(string: swiftlyHome).expandingTildeInPath, isDirectory: true)
          .appendingPathComponent("bin", isDirectory: true).path)
    }

    for relative in [
      ".cargo/bin",
      ".local/bin",
      "bin",
      ".local/share/mise/shims",
      ".asdf/shims",
      ".nix-profile/bin",
      ".swiftly/bin",
    ] {
      add(homeURL.appendingPathComponent(relative, isDirectory: true).path)
    }

    for path in [
      "/opt/homebrew/bin", "/opt/homebrew/sbin",
      "/usr/local/bin", "/usr/local/sbin",
      "/nix/var/nix/profiles/default/bin",
    ] {
      add(path)
    }

    var existing: [String] = []
    for entry in (environment["PATH"] ?? "").split(
      separator: ":", omittingEmptySubsequences: false)
    {
      let value = entry.isEmpty ? (workingDirectory?.path ?? "") : String(entry)
      guard !value.isEmpty, !preferred.contains(value), !existing.contains(value) else { continue }
      existing.append(value)
    }

    for path in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    where !preferred.contains(path) && !existing.contains(path) {
      existing.append(path)
    }
    environment["PATH"] = (preferred + existing).joined(separator: ":")
    if let workingDirectory {
      environment["PWD"] = workingDirectory.standardizedFileURL.path
    }
    return environment
  }

  public static func executableURL(
    named configured: String,
    workingDirectory: URL,
    environment baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    let environment = prepared(base: baseEnvironment, workingDirectory: workingDirectory)
    let expanded = NSString(string: configured).expandingTildeInPath
    guard !expanded.isEmpty else { return nil }

    if expanded.contains("/") {
      let url = URL(fileURLWithPath: expanded, relativeTo: workingDirectory).standardizedFileURL
      return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    let overrideKeys = [
      "\(expanded.uppercased().replacingOccurrences(of: "-", with: "_"))_PATH",
      expanded.uppercased().replacingOccurrences(of: "-", with: "_"),
    ]
    for key in overrideKeys {
      guard let value = environment[key], !value.isEmpty else { continue }
      let url = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
        .standardizedFileURL
      if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }

    for directory in (environment["PATH"] ?? "").split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
        .appendingPathComponent(expanded)
        .standardizedFileURL
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  private static func resolvedHomeURL(environment: [String: String]) -> URL {
    if let home = environment["HOME"], !home.isEmpty {
      return URL(fileURLWithPath: NSString(string: home).expandingTildeInPath, isDirectory: true)
        .standardizedFileURL
    }
    return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
  }
}
