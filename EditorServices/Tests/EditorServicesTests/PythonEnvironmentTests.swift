import Foundation
import Testing

@testable import EditorServices

@Suite("Python environment discovery")
struct PythonEnvironmentTests {
  @Test("prefers project .venv and activates PATH")
  func detectsPreferredEnvironment() throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }

    let root = workspace.appendingPathComponent(".venv", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try "home = /usr/bin".write(
      to: root.appendingPathComponent("pyvenv.cfg"),
      atomically: true,
      encoding: .utf8
    )
    let python = bin.appendingPathComponent("python")
    try "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: python.path
    )

    let result = EditorPythonEnvironmentResolver.activatedEnvironment(
      workspaceURL: workspace,
      base: ["PATH": "/usr/bin:/bin", "PYTHONHOME": "/bad"]
    )

    #expect(result.python?.rootURL == root.standardizedFileURL)
    #expect(result.python?.executableURL == python.standardizedFileURL)
    #expect(result.environment["VIRTUAL_ENV"] == root.standardizedFileURL.path)
    #expect(result.environment["PATH"]?.hasPrefix(bin.standardizedFileURL.path + ":") == true)
    #expect(result.environment["PYTHONHOME"] == nil)
  }

  @Test("falls back to a shallow named environment")
  func findsNestedEnvironment() throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }

    let root = workspace.appendingPathComponent("tools/python-env", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try "home = /usr/bin".write(
      to: root.appendingPathComponent("pyvenv.cfg"),
      atomically: true,
      encoding: .utf8
    )
    let python = bin.appendingPathComponent("python3")
    try "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: python.path
    )

    let result = EditorPythonEnvironmentResolver.detect(
      workspaceURL: workspace,
      environment: [:]
    )
    #expect(result?.rootURL == root.standardizedFileURL)
  }

  @Test("ignores invalid virtual environment folders")
  func ignoresInvalidEnvironment() throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }

    try FileManager.default.createDirectory(
      at: workspace.appendingPathComponent(".venv", isDirectory: true),
      withIntermediateDirectories: true
    )

    #expect(
      EditorPythonEnvironmentResolver.detect(
        workspaceURL: workspace,
        environment: [:]
      ) == nil
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("Calcite-PythonEnvironment-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("process environment and explicit interpreter share the selected venv")
  func processEnvironmentUsesSelectedInterpreter() throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let root = workspace.appendingPathComponent("custom-env", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try "home = /usr/bin".write(
      to: root.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)
    let python = bin.appendingPathComponent("python")
    try "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

    let prepared = EditorProcessEnvironment.prepared(
      base: ["PATH": "/usr/bin:/bin", "CALCITE_PYTHON_INTERPRETER": python.path],
      workingDirectory: workspace
    )
    #expect(prepared["VIRTUAL_ENV"] == root.standardizedFileURL.path)
    #expect(prepared["CALCITE_PYTHON_INTERPRETER"] == python.standardizedFileURL.path)
    #expect(prepared["PATH"]?.hasPrefix(bin.standardizedFileURL.path + ":") == true)
  }

  @Test("accepts an external active Conda environment for a Conda project")
  func detectsExternalCondaEnvironment() throws {
    let workspace = try temporaryDirectory()
    let conda = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: conda)
    }
    try "name: calcite\n".write(
      to: workspace.appendingPathComponent("environment.yml"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: conda.appendingPathComponent("conda-meta", isDirectory: true),
      withIntermediateDirectories: true
    )
    let bin = conda.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let python = bin.appendingPathComponent("python")
    try "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

    let result = EditorPythonEnvironmentResolver.activatedEnvironment(
      workspaceURL: workspace,
      base: [
        "PATH": "/usr/bin:/bin", "CONDA_PREFIX": conda.path,
        "CONDA_DEFAULT_ENV": "calcite",
      ]
    )
    #expect(result.python?.kind == .conda)
    #expect(result.environment["CONDA_PREFIX"] == conda.standardizedFileURL.path)
    #expect(result.environment["VIRTUAL_ENV"] == nil)
    #expect(result.environment["PATH"]?.hasPrefix(bin.standardizedFileURL.path + ":") == true)
  }

  @Test("recognizes a manually selected Conda interpreter")
  func selectedCondaInterpreterKeepsCondaSemantics() throws {
    let workspace = try temporaryDirectory()
    let conda = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: conda)
    }
    try FileManager.default.createDirectory(
      at: conda.appendingPathComponent("conda-meta", isDirectory: true),
      withIntermediateDirectories: true
    )
    let bin = conda.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let python = bin.appendingPathComponent("python")
    try "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

    let result = EditorPythonEnvironmentResolver.activatedEnvironment(
      workspaceURL: workspace,
      base: ["PATH": "/usr/bin:/bin"],
      explicitInterpreterURL: python
    )
    #expect(result.python?.kind == .conda)
    #expect(result.environment["CONDA_PREFIX"] == conda.standardizedFileURL.path)
    #expect(result.environment["VIRTUAL_ENV"] == nil)
  }

  @Test("project environment wins over an unrelated inherited virtualenv")
  func projectEnvironmentWinsOverInheritedEnvironment() throws {
    let workspace = try temporaryDirectory()
    let inherited = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: inherited)
    }
    let local = workspace.appendingPathComponent(".venv", isDirectory: true)
    let localPython = try createEnvironment(at: local)
    _ = try createEnvironment(at: inherited)

    let result = EditorPythonEnvironmentResolver.activatedEnvironment(
      workspaceURL: workspace,
      base: [
        "PATH": inherited.appendingPathComponent("bin").path + ":/usr/bin:/bin",
        "VIRTUAL_ENV": inherited.path,
      ]
    )

    #expect(result.python?.rootURL == local.standardizedFileURL)
    #expect(result.python?.executableURL == localPython.standardizedFileURL)
    #expect(result.environment["VIRTUAL_ENV"] == local.standardizedFileURL.path)
    #expect(
      result.environment["PATH"]?.hasPrefix(local.appendingPathComponent("bin").path + ":") == true)
    #expect(
      result.environment["PATH"]?.contains(inherited.appendingPathComponent("bin").path) == false)
  }

  @Test("unrelated inherited environments are removed when no project environment exists")
  func stripsUnrelatedInheritedEnvironment() throws {
    let workspace = try temporaryDirectory()
    let inherited = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: inherited)
    }
    _ = try createEnvironment(at: inherited)

    let result = EditorPythonEnvironmentResolver.activatedEnvironment(
      workspaceURL: workspace,
      base: [
        "PATH": inherited.appendingPathComponent("bin").path + ":/usr/bin:/bin",
        "VIRTUAL_ENV": inherited.path,
        "PYTHONHOME": "/wrong",
      ]
    )

    #expect(result.python == nil)
    #expect(result.environment["VIRTUAL_ENV"] == nil)
    #expect(result.environment["PYTHONHOME"] == nil)
    #expect(result.environment["PATH"] == "/usr/bin:/bin")
  }

  @Test("Conda activation uses the shell hook and conda activate")
  func condaActivationCommandUsesConda() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("conda-meta", isDirectory: true),
      withIntermediateDirectories: true
    )
    let python = try createExecutablePython(at: root)
    let environment = EditorPythonEnvironment(
      rootURL: root,
      executableURL: python,
      binURL: python.deletingLastPathComponent(),
      kind: .conda
    )

    let command = EditorPythonEnvironmentResolver.shellActivationCommand(
      for: environment,
      shellPath: "/bin/zsh",
      environment: ["CONDA_EXE": "/opt/conda/bin/conda"]
    )
    #expect(command.contains("shell.zsh hook"))
    #expect(command.contains("conda activate"))
    #expect(command.contains(root.path))
    #expect(command.contains("bin/activate") == false)
  }

  @Test("a direct system interpreter is not treated as a virtual environment")
  func directInterpreterDoesNotSourceActivationScript() throws {
    let workspace = try temporaryDirectory()
    let systemRoot = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: systemRoot)
    }
    let python = try createExecutablePython(at: systemRoot)

    let result = EditorPythonEnvironmentResolver.activatedEnvironment(
      workspaceURL: workspace,
      base: ["PATH": "/usr/bin:/bin"],
      explicitInterpreterURL: python
    )
    #expect(result.python?.kind == .explicitInterpreter)
    #expect(result.environment["VIRTUAL_ENV"] == nil)
    #expect(result.environment["CALCITE_PYTHON_VENV"] == nil)
    #expect(result.environment["CALCITE_PYTHON_INTERPRETER"] == python.standardizedFileURL.path)

    let command = EditorPythonEnvironmentResolver.shellActivationCommand(
      for: result.python, shellPath: "/bin/zsh")
    #expect(command.contains("source ") == false)
    #expect(command.contains("/activate") == false)
    #expect(command.contains(python.path))
  }

  @Test("shell-specific activation commands remain valid outside zsh")
  func activationCommandsMatchShellSyntax() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let python = try createEnvironment(at: root)
    let virtualenv = EditorPythonEnvironment(
      rootURL: root,
      executableURL: python,
      binURL: python.deletingLastPathComponent(),
      kind: .virtualenv
    )
    let conda = EditorPythonEnvironment(
      rootURL: root,
      executableURL: python,
      binURL: python.deletingLastPathComponent(),
      kind: .conda
    )

    let fishVirtualenv = EditorPythonEnvironmentResolver.shellActivationCommand(
      for: virtualenv, shellPath: "/opt/homebrew/bin/fish")
    let fishConda = EditorPythonEnvironmentResolver.shellActivationCommand(
      for: conda, shellPath: "/opt/homebrew/bin/fish")
    let cshVirtualenv = EditorPythonEnvironmentResolver.shellActivationCommand(
      for: virtualenv, shellPath: "/bin/tcsh")
    let cshConda = EditorPythonEnvironmentResolver.shellActivationCommand(
      for: conda, shellPath: "/bin/tcsh")

    #expect(fishVirtualenv.contains("activate.fish"))
    #expect(fishVirtualenv.contains("||") == false)
    #expect(fishConda.contains("shell.fish hook"))
    #expect(fishConda.contains("if eval"))
    #expect(cshVirtualenv.contains("activate.csh"))
    #expect(cshConda.contains("setenv CONDA_PREFIX"))
    #expect(cshConda.contains(" then ") == false)
  }

  private func createEnvironment(at root: URL) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "home = /usr/bin".write(
      to: root.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)
    return try createExecutablePython(at: root)
  }

  private func createExecutablePython(at root: URL) throws -> URL {
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let python = bin.appendingPathComponent("python")
    try "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    return python
  }

}
