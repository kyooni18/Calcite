import Foundation
import XCTest

@testable import EditorServices

final class ThirteenIssueRegressionTests: XCTestCase {
  func testBuildTaskResolverUsesOnePolicyForAvailabilityAndExecution() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("main.swift")
    try "print(\"ok\")\n".write(to: file, atomically: true, encoding: .utf8)

    let projectWithoutRun = EditorBuildPlan(projectKind: .xcode, commands: [])
    let fallback = try XCTUnwrap(
      EditorBuildTaskResolver.resolve(
        projectPlan: projectWithoutRun,
        activeFileURL: file,
        kind: .run
      ))
    guard case .standalone(let resolvedFile, let plan) = fallback else {
      return XCTFail("Expected the standalone file target used by both availability and execution")
    }
    XCTAssertEqual(resolvedFile, file.standardizedFileURL)
    XCTAssertNotNil(plan.command(for: .run))
    XCTAssertTrue(
      EditorBuildTaskResolver.canExecute(
        projectPlan: projectWithoutRun,
        activeFileURL: file,
        kind: .run
      ))

    let projectCommand = EditorBuildCommand(
      id: "project-run",
      title: "Run Project",
      kind: .run,
      executable: "project-runner",
      arguments: [],
      workingDirectory: root
    )
    let projectPlan = EditorBuildPlan(projectKind: .xcode, commands: [projectCommand])
    let preferred = try XCTUnwrap(
      EditorBuildTaskResolver.resolve(
        projectPlan: projectPlan,
        activeFileURL: file,
        kind: .run
      ))
    guard case .project(let resolvedCommand) = preferred else {
      return XCTFail("Expected the project command to take precedence")
    }
    XCTAssertEqual(resolvedCommand, projectCommand)
  }

  func testPythonPackageManagersSelectNativeBuildCommands() throws {
    let cases: [(marker: String, pyproject: String, executable: String, arguments: [String])] = [
      ("uv.lock", "[project]\nname = \"sample\"\n", "uv", ["build"]),
      ("poetry.lock", "[tool.poetry]\nname = \"sample\"\n", "poetry", ["build"]),
      ("pdm.lock", "[tool.pdm]\n", "pdm", ["build"]),
      ("hatch.toml", "[tool.hatch.build]\n", "hatch", ["build"]),
    ]

    for item in cases {
      let root = try makeTemporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      try item.pyproject.write(
        to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
      try Data().write(to: root.appendingPathComponent(item.marker))

      let command = try XCTUnwrap(
        EditorBuildDiscovery.inspect(workspaceURL: root).command(for: .build))
      XCTAssertEqual(command.executable, item.executable, item.marker)
      XCTAssertEqual(command.arguments, item.arguments, item.marker)
    }
  }

  func testPythonRunAndTestDiscoverySupportsScriptsSrcModulesAndUnittest() throws {
    do {
      let root = try makeTemporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      try """
      [project]
      name = "sample"

      [project.scripts]
      calcite-tool = "sample.cli:main"
      """.write(
        to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
      let run = try XCTUnwrap(EditorBuildDiscovery.inspect(workspaceURL: root).command(for: .run))
      XCTAssertEqual(run.executable, "python")
      XCTAssertEqual(run.arguments.first, "-c")
      XCTAssertEqual(run.arguments.count, 2)
      XCTAssertTrue(run.arguments.last?.contains("sample.cli") == true)
      XCTAssertTrue(run.arguments.last?.contains("main") == true)
    }

    do {
      let root = try makeTemporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let module = root.appendingPathComponent("src/sample", isDirectory: true)
      try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
      try "print('module')\n".write(
        to: module.appendingPathComponent("__main__.py"), atomically: true, encoding: .utf8)
      try "[project]\nname = \"sample\"\n".write(
        to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
      try "import unittest\n".write(
        to: root.appendingPathComponent("test_root.py"), atomically: true, encoding: .utf8)

      let plan = EditorBuildDiscovery.inspect(workspaceURL: root)
      let run = try XCTUnwrap(plan.command(for: .run))
      XCTAssertEqual(run.executable, "python")
      XCTAssertEqual(run.arguments, ["-m", "sample"])
      XCTAssertEqual(run.environment["PYTHONPATH"], root.appendingPathComponent("src").path)
      let test = try XCTUnwrap(plan.command(for: .test))
      XCTAssertEqual(test.executable, "python")
      XCTAssertEqual(test.arguments, ["-m", "unittest", "discover", "-v"])
    }
  }

  func testPythonTopLevelModulesAreIndexedButUserSiteIsExcludedForVenv() async throws {
    let root = try makeTemporaryDirectory()
    let home = try makeTemporaryDirectory()
    let environment = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: home)
      try? FileManager.default.removeItem(at: environment)
    }

    let selectedSite = environment.appendingPathComponent(
      "lib/python3.12/site-packages", isDirectory: true)
    let unselectedLocalSite = root.appendingPathComponent(
      ".venv/lib/python3.12/site-packages", isDirectory: true)
    let userSite = home.appendingPathComponent(
      ".local/lib/python3.12/site-packages", isDirectory: true)
    try FileManager.default.createDirectory(at: selectedSite, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: unselectedLocalSite, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: userSite, withIntermediateDirectories: true)
    let selectedModule = selectedSite.appendingPathComponent("selected_module.py")
    let selectedStub = selectedSite.appendingPathComponent("selected_stub.pyi")
    let unselectedLocalModule = unselectedLocalSite.appendingPathComponent("local_only.py")
    let userModule = userSite.appendingPathComponent("user_only.py")
    try "class SelectedModule: pass\n".write(
      to: selectedModule, atomically: true, encoding: .utf8)
    try "class SelectedStub: ...\n".write(
      to: selectedStub, atomically: true, encoding: .utf8)
    try "class UserOnly: pass\n".write(to: userModule, atomically: true, encoding: .utf8)

    let index = ExternalSourceIndex(
      workspaceURL: root,
      languageCatalog: .standard,
      configuration: .init(),
      environment: [
        "HOME": home.path,
        "PATH": environment.appendingPathComponent("bin").path + ":/usr/bin:/bin",
        "CALCITE_PYTHON_VENV": environment.path,
        "PYTHONNOUSERSITE": "1",
      ]
    )
    _ = await index.refresh()
    let files = await index.files(refreshIfNeeded: false).map { $0.file.url.standardizedFileURL }

    XCTAssertTrue(files.contains(selectedModule.standardizedFileURL))
    XCTAssertTrue(files.contains(selectedStub.standardizedFileURL))
    XCTAssertFalse(files.contains(unselectedLocalModule.standardizedFileURL))
    XCTAssertFalse(files.contains(userModule.standardizedFileURL))
  }

  func testCancelledExternalIndexRefreshDoesNotPublishStaleResults() async throws {
    let root = try makeTemporaryDirectory()
    let dependency = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: dependency)
    }
    let source = dependency.appendingPathComponent("Dependency.swift")
    try "public struct Dependency {}\n".write(
      to: source, atomically: true, encoding: .utf8)

    let index = ExternalSourceIndex(
      workspaceURL: root,
      languageCatalog: .standard,
      configuration: .init(
        discoversPackageRootsAutomatically: false,
        explicitRootURLs: [dependency]
      ),
      environment: ["PATH": "/usr/bin:/bin"]
    )
    let cancelled = Task {
      try? await Task.sleep(for: .milliseconds(50))
      return await index.refresh()
    }
    cancelled.cancel()
    let cancelledReport = await cancelled.value
    XCTAssertEqual(cancelledReport.indexedFileCount, 0)
    let filesAfterCancellation = await index.files(refreshIfNeeded: false)
    XCTAssertTrue(filesAfterCancellation.isEmpty)

    let completedReport = await index.refresh()
    XCTAssertEqual(completedReport.indexedFileCount, 1)
    let completedFiles = await index.files(refreshIfNeeded: false).map(\.file.url)
    XCTAssertEqual(completedFiles, [source])
  }

  func testPythonUserSiteCanStillBeIndexedWithoutIsolationFlag() async throws {
    let root = try makeTemporaryDirectory()
    let home = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: home)
    }
    let userSite = home.appendingPathComponent(
      ".local/lib/python3.12/site-packages", isDirectory: true)
    try FileManager.default.createDirectory(at: userSite, withIntermediateDirectories: true)
    let module = userSite.appendingPathComponent("user_visible.py")
    try "class UserVisible: pass\n".write(to: module, atomically: true, encoding: .utf8)

    let index = ExternalSourceIndex(
      workspaceURL: root,
      languageCatalog: .standard,
      configuration: .init(),
      environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"]
    )
    _ = await index.refresh()
    let files = await index.files(refreshIfNeeded: false).map { $0.file.url.standardizedFileURL }
    XCTAssertTrue(files.contains(module.standardizedFileURL))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("Calcite-Regression-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
