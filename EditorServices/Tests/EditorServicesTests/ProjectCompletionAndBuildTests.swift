import Foundation
import XCTest

@testable import EditorServices

final class ProjectCompletionAndBuildTests: XCTestCase {
  func testProjectDeclarationCompletionUsesSnippetInsertion() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let declaration = root.appendingPathComponent("Pricing.swift")
    let current = root.appendingPathComponent("Checkout.swift")
    try "func calculateTotal(price: Int, tax: Int) -> Int { price + tax }\n".write(
      to: declaration,
      atomically: true,
      encoding: .utf8
    )
    try "let total = cal\n".write(to: current, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    _ = try await backend.scanSourceWorkspace()
    let session = try await backend.openFileSession(at: current, languageID: "swift")
    let completions = try await session.completions(
      at: .init(line: 0, utf16Column: 15),
      invocation: .automatic
    )

    let completion = try XCTUnwrap(completions.first { $0.label == "calculateTotal" })
    XCTAssertEqual(completion.kind, .function)
    XCTAssertEqual(completion.insertTextFormat, .snippet)
    XCTAssertTrue(completion.insertText?.contains("${1:price}") == true)
    XCTAssertTrue(completion.insertText?.contains("${2:tax}") == true)
    XCTAssertTrue(completion.detail?.contains("Pricing.swift") == true)
    try await session.close()
    try await backend.shutdown()
  }

  func testBuildDiscoveryRecognizesCargoProject() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "[package]\nname = \"sample\"\n".write(
      to: root.appendingPathComponent("Cargo.toml"),
      atomically: true,
      encoding: .utf8
    )

    let plan = EditorBuildDiscovery.inspect(workspaceURL: root)
    XCTAssertEqual(plan.projectKind, .rustCargo)
    XCTAssertEqual(plan.command(for: .check)?.executable, "cargo")
    XCTAssertEqual(
      plan.command(for: .check)?.arguments.prefix(2), ["check", "--message-format=json"])
    XCTAssertEqual(plan.command(for: .check)?.workingDirectory, root.standardizedFileURL)
    XCTAssertNotNil(plan.command(for: .run))
    XCTAssertNotNil(plan.command(for: .test))
  }

  func testBuildRunnerUsesConfiguredProjectDirectory() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let command = EditorBuildCommand(
      id: "working-directory",
      title: "Working Directory",
      kind: .check,
      executable: "sh",
      arguments: ["-c", #"printf '%s\n%s\n' "$(pwd -P)" "$PWD""#],
      workingDirectory: root
    )
    let runner = EditorBuildRunner()
    let stream = try await runner.run(command)
    var output = ""
    for await event in stream {
      if case .output(let value, _) = event { output += value }
    }

    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    XCTAssertEqual(lines, [root.resolvingSymlinksInPath().path, root.path])
  }

  func testBuildRunnerStreamsOutputAndParsesDiagnostic() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("main.swift")
    try "let value = 1\n".write(to: source, atomically: true, encoding: .utf8)

    let command = EditorBuildCommand(
      id: "diagnostic-test",
      title: "Diagnostic Test",
      kind: .check,
      arguments: [
        "sh", "-c",
        "printf 'main.swift:1:5: error: sample failure\\n' >&2; exit 1",
      ],
      workingDirectory: root
    )
    let runner = EditorBuildRunner()
    let stream = try await runner.run(command)
    var diagnostic: EditorBuildDiagnostic?
    var result: EditorBuildResult?
    for await event in stream {
      switch event {
      case .diagnostic(let value): diagnostic = value
      case .finished(let value): result = value
      default: break
      }
    }

    XCTAssertEqual(diagnostic?.url, source.standardizedFileURL)
    XCTAssertEqual(diagnostic?.line, 1)
    XCTAssertEqual(diagnostic?.column, 5)
    XCTAssertEqual(diagnostic?.severity, .error)
    XCTAssertEqual(result?.exitCode, 1)
  }

  func testTypeScriptArrowFunctionIsIndexedAsProjectSnippet() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let utility = root.appendingPathComponent("utility.ts")
    let current = root.appendingPathComponent("main.ts")
    try "export const formatUser = (name: string, age: number) => `${name}:${age}`\n".write(
      to: utility, atomically: true, encoding: .utf8)
    try "const value = form\n".write(to: current, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    _ = try await backend.scanSourceWorkspace()
    let session = try await backend.openFileSession(at: current, languageID: "typescript")
    let values = try await session.completions(
      at: .init(line: 0, utf16Column: 18), invocation: .automatic)
    let completion = try XCTUnwrap(values.first { $0.label == "formatUser" })
    XCTAssertEqual(completion.insertTextFormat, .snippet)
    XCTAssertTrue(completion.insertText?.contains("${1:name}") == true)
    XCTAssertTrue(completion.insertText?.contains("${2:age}") == true)
    try await session.close()
    try await backend.shutdown()
  }

  func testNodeBuildDiscoveryUsesProjectPackageManagerAndScripts() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("pnpm-lock.yaml"))
    try #"{"scripts":{"build":"tsc","dev":"vite","test":"vitest"}}"#.write(
      to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

    let plan = EditorBuildDiscovery.inspect(workspaceURL: root)
    XCTAssertEqual(plan.projectKind, .nodePackage)
    XCTAssertEqual(plan.command(for: .build)?.executable, "pnpm")
    XCTAssertEqual(plan.command(for: .build)?.arguments, ["run", "build"])
    XCTAssertEqual(plan.command(for: .run)?.arguments, ["run", "dev"])
    XCTAssertEqual(plan.command(for: .test)?.arguments, ["run", "test"])
  }

  func testXcodeBuildDiscoveryUsesSharedSchemeAndStableDerivedData() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let project = root.appendingPathComponent("Calcite.xcodeproj", isDirectory: true)
    let schemes = project.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
    try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "<Scheme/>".write(
      to: schemes.appendingPathComponent("CalciteApp.xcscheme"),
      atomically: true,
      encoding: .utf8
    )

    let plan = EditorBuildDiscovery.inspect(workspaceURL: root)
    XCTAssertEqual(plan.projectKind, .xcode)
    let build = try XCTUnwrap(plan.command(for: .build))
    XCTAssertEqual(build.executable, "xcodebuild")
    XCTAssertEqual(build.workingDirectory, root.standardizedFileURL)
    XCTAssertTrue(build.arguments.contains("Calcite.xcodeproj"))
    XCTAssertTrue(build.arguments.contains("CalciteApp"))
    XCTAssertTrue(build.arguments.contains(".calcite/DerivedData"))
    XCTAssertEqual(build.arguments.last, "build")
    XCTAssertNotNil(plan.command(for: .test))
    XCTAssertNotNil(plan.command(for: .clean))
  }

  func testProjectCompletionIndexRefreshesAfterWorkspaceRescan() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let declaration = root.appendingPathComponent("Library.swift")
    let current = root.appendingPathComponent("Main.swift")
    try "func previousValue() {}\n".write(
      to: declaration, atomically: true, encoding: .utf8)
    try "let value = rena\n".write(to: current, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    _ = try await backend.scanSourceWorkspace()
    let session = try await backend.openFileSession(at: current, languageID: "swift")
    var values = try await session.completions(
      at: .init(line: 0, utf16Column: 16), invocation: .automatic)
    XCTAssertFalse(values.contains { $0.label == "renamedValue" })

    try "func renamedValue(input: Int) {}\n".write(
      to: declaration, atomically: true, encoding: .utf8)
    _ = try await backend.scanSourceWorkspace()
    values = try await session.completions(
      at: .init(line: 0, utf16Column: 16), invocation: .automatic)
    let completion = try XCTUnwrap(values.first { $0.label == "renamedValue" })
    XCTAssertEqual(completion.insertTextFormat, .snippet)
    XCTAssertTrue(completion.insertText?.contains("${1:input}") == true)

    try await session.close()
    try await backend.shutdown()
  }

  func testBuildRunnerParsesLineOnlyAndPrefixedDiagnostics() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let java = root.appendingPathComponent("Sample.java")
    let kotlin = root.appendingPathComponent("Sample.kt")
    try "class Sample {}\n".write(to: java, atomically: true, encoding: .utf8)
    try "class Sample\n".write(to: kotlin, atomically: true, encoding: .utf8)

    let command = EditorBuildCommand(
      id: "multi-diagnostic-test",
      title: "Multi Diagnostic Test",
      kind: .check,
      arguments: [
        "sh", "-c",
        "printf 'Sample.java:9: warning: unchecked conversion\ne: Sample.kt:4:7: error: unresolved reference\n' >&2",
      ],
      workingDirectory: root
    )
    let runner = EditorBuildRunner()
    let stream = try await runner.run(command)
    var diagnostics: [EditorBuildDiagnostic] = []
    for await event in stream {
      if case .diagnostic(let diagnostic) = event { diagnostics.append(diagnostic) }
    }

    XCTAssertEqual(diagnostics.count, 2)
    XCTAssertEqual(diagnostics[0].url, java.standardizedFileURL)
    XCTAssertEqual(diagnostics[0].line, 9)
    XCTAssertEqual(diagnostics[0].column, 1)
    XCTAssertEqual(diagnostics[0].severity, .warning)
    XCTAssertEqual(diagnostics[1].url, kotlin.standardizedFileURL)
    XCTAssertEqual(diagnostics[1].line, 4)
    XCTAssertEqual(diagnostics[1].column, 7)
    XCTAssertEqual(diagnostics[1].severity, .error)
  }

  func testBuildRunnerPreservesUTF8SplitAcrossPipeReads() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let command = EditorBuildCommand(
      id: "utf8-stream",
      title: "UTF-8 Stream",
      kind: .check,
      arguments: [
        "python3", "-c",
        "import os,time; b='A🦀한B\\n'.encode(); "
          + "[(os.write(1, bytes([x])), time.sleep(0.002)) for x in b]",
      ],
      workingDirectory: root
    )
    let runner = EditorBuildRunner()
    let stream = try await runner.run(command)
    var output = ""
    for await event in stream {
      if case .output(let value, _) = event { output += value }
    }
    XCTAssertEqual(output, "A🦀한B\n")
  }

  func testBuildRunnerOverridesColorEnvironmentDeterministically() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let command = EditorBuildCommand(
      id: "environment",
      title: "Environment",
      kind: .check,
      arguments: ["sh", "-c", "printf '%s|%s|%s' \"$TERM\" \"$NO_COLOR\" \"$CLICOLOR\""],
      workingDirectory: root
    )
    let runner = EditorBuildRunner()
    let stream = try await runner.run(
      command,
      environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "", "TERM": "xterm"]
    )
    var output = ""
    for await event in stream {
      if case .output(let value, _) = event { output += value }
    }
    XCTAssertEqual(output, "dumb|1|0")
  }

  func testBuildRunnerRejectsMissingWorkingDirectory() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let command = EditorBuildCommand(
      id: "missing-directory",
      title: "Missing Directory",
      kind: .check,
      arguments: ["true"],
      workingDirectory: root
    )
    let runner = EditorBuildRunner()
    do {
      _ = try await runner.run(command)
      XCTFail("Expected the missing directory to be rejected")
    } catch let error as EditorBuildRunnerError {
      guard case .invalidWorkingDirectory(let path) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(path, root.path)
    }
  }

  func testBuildRunnerCancellationFinishesAndMarksResult() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let command = EditorBuildCommand(
      id: "cancel",
      title: "Cancel",
      kind: .check,
      arguments: ["sh", "-c", "trap '' INT TERM; sleep 30"],
      workingDirectory: root
    )
    let runner = EditorBuildRunner()
    let stream = try await runner.run(command)
    let collector = Task { () -> EditorBuildResult? in
      for await event in stream {
        if case .finished(let result) = event { return result }
      }
      return nil
    }
    try await Task.sleep(for: .milliseconds(100))
    await runner.cancel(gracePeriod: .milliseconds(100))
    let result = try await withThrowingTaskGroup(of: EditorBuildResult?.self) { group in
      group.addTask { await collector.value }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw CancellationError()
      }
      let value = try await group.next() ?? nil
      group.cancelAll()
      return value
    }
    XCTAssertEqual(result?.wasCancelled, true)
    let isRunning = await runner.isRunning
    XCTAssertFalse(isRunning)
  }

  func testBuildRunnerDeduplicatesRepeatedDiagnostics() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "let value = 1\n".write(
      to: root.appendingPathComponent("main.swift"),
      atomically: true,
      encoding: .utf8
    )

    let line = "main.swift:1:5: warning: repeated\n"
    let command = EditorBuildCommand(
      id: "deduplicate",
      title: "Deduplicate",
      kind: .check,
      arguments: ["sh", "-c", "printf '%s%s' \"$0\" \"$0\"", line],
      workingDirectory: root
    )
    let runner = EditorBuildRunner()
    let stream = try await runner.run(command)
    var diagnostics: [EditorBuildDiagnostic] = []
    for await event in stream {
      if case .diagnostic(let diagnostic) = event { diagnostics.append(diagnostic) }
    }
    XCTAssertEqual(diagnostics.count, 1)
  }

  func testExternalSwiftPackageCheckoutIsIndexedWithoutEnteringWorkspaceTree() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let packageSources = root.appendingPathComponent(
      ".build/checkouts/UtilityKit/Sources/UtilityKit",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: packageSources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let external = packageSources.appendingPathComponent("UtilityClient.swift")
    let current = root.appendingPathComponent("Main.swift")
    try "public struct UtilityClient { public func synchronizeCache(force: Bool) {} }\n".write(
      to: external, atomically: true, encoding: .utf8)
    try "import UtilityKit\nlet client = UtilityClient()\nclient.sync\n".write(
      to: current, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    _ = try await backend.scanSourceWorkspace()
    let snapshot = await backend.sourceWorkspaceSnapshot()
    XCTAssertFalse(snapshot.files.contains { $0.url == external.standardizedFileURL })

    let report = await backend.externalSourceIndexReport()
    XCTAssertEqual(report.packageCount, 1)
    XCTAssertGreaterThanOrEqual(report.indexedFileCount, 1)

    let session = try await backend.openFileSession(at: current, languageID: "swift")
    let values = try await session.completions(
      at: .init(line: 2, utf16Column: 11),
      invocation: .triggerCharacter(".")
    )
    let completion = try XCTUnwrap(values.first { $0.label == "synchronizeCache" })
    XCTAssertEqual(completion.insertTextFormat, .snippet)
    XCTAssertTrue(completion.detail?.contains("Library") == true)

    try await session.close()
    try await backend.shutdown()
  }

  func testBuildRunnerFindsCargoInUserToolchainPath() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let cargoDirectory = home.appendingPathComponent(".cargo/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: cargoDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let cargo = cargoDirectory.appendingPathComponent("cargo")
    try "#!/bin/sh\nprintf 'cargo-from-user-toolchain'\n".write(
      to: cargo, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o755))],
      ofItemAtPath: cargo.path
    )

    let command = EditorBuildCommand(
      id: "cargo-path",
      title: "Cargo Path",
      kind: .check,
      executable: "cargo",
      arguments: [],
      workingDirectory: root
    )
    let runner = EditorBuildRunner()
    let stream = try await runner.run(
      command,
      environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"]
    )
    var output = ""
    for await event in stream {
      if case .output(let value, _) = event { output += value }
    }
    XCTAssertEqual(output, "cargo-from-user-toolchain")
  }

  func testCargoLockTransitiveDependencyIsIndexedFromCargoHome() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let cargoHome = home.appendingPathComponent("custom-cargo", isDirectory: true)
    let crate = cargoHome.appendingPathComponent(
      "registry/src/index.crates.io-test/transitive-kit-1.2.3/src",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: crate, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "[package]\nname = \"sample\"\nversion = \"0.1.0\"\n".write(
      to: root.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
    try """
    version = 3

    [[package]]
    name = "sample"
    version = "0.1.0"

    [[package]]
    name = "transitive-kit"
    version = "1.2.3"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    """.write(to: root.appendingPathComponent("Cargo.lock"), atomically: true, encoding: .utf8)
    let source = crate.appendingPathComponent("lib.rs")
    try "pub fn transitive_symbol() {}\n".write(
      to: source, atomically: true, encoding: .utf8)

    let index = ExternalSourceIndex(
      workspaceURL: root,
      languageCatalog: .standard,
      configuration: .init(),
      environment: ["HOME": home.path, "CARGO_HOME": cargoHome.path, "PATH": "/usr/bin:/bin"]
    )
    let report = await index.refresh()
    let snapshot = await index.snapshot(refreshIfNeeded: false)

    XCTAssertGreaterThanOrEqual(report.packageCount, 1)
    XCTAssertTrue(snapshot.files.contains { $0.file.url == source.standardizedFileURL })
  }

  func testXcodeDerivedDataSwiftPackageIsIndexedFromPackageResolved() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("Sample.xcodeproj", isDirectory: true)
    let resolvedDirectory = project.appendingPathComponent(
      "project.xcworkspace/xcshareddata/swiftpm", isDirectory: true)
    let checkout = home.appendingPathComponent(
      "Library/Developer/Xcode/DerivedData/Sample-test/SourcePackages/checkouts/RemoteKit/Sources/RemoteKit",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: resolvedDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try """
    {"version":2,"pins":[{"identity":"remotekit","kind":"remoteSourceControl","location":"https://example.invalid/RemoteKit.git","state":{"revision":"abc","version":"1.0.0"}}]}
    """.write(
      to: resolvedDirectory.appendingPathComponent("Package.resolved"),
      atomically: true,
      encoding: .utf8
    )
    let source = checkout.appendingPathComponent("RemoteClient.swift")
    try "public struct RemoteClient {}\n".write(
      to: source, atomically: true, encoding: .utf8)

    let index = ExternalSourceIndex(
      workspaceURL: root,
      languageCatalog: .standard,
      configuration: .init(),
      environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"]
    )
    _ = await index.refresh()
    let snapshot = await index.snapshot(refreshIfNeeded: false)

    XCTAssertTrue(snapshot.files.contains { $0.file.url == source.standardizedFileURL })
  }

  func testRustOverloadsWithMatchingParameterNamesRemainDistinct() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("main.rs")
    let source = """
      struct Client {}
      impl Client {
        fn send(&self, value: i32) {}
        fn send(&self, value: &str) {}
      }
      fn main() {
        let client: Client = Client {};
        client.se
      }
      """
    try source.write(to: file, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      languageID: "rust",
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    _ = try await backend.scanSourceWorkspace()
    let session = try await backend.openFileSession(at: file, languageID: "rust")
    let snapshot = try await session.snapshot()
    let position = try snapshot.position(
      atUTF16Offset: (snapshot.text as NSString).range(of: "client.se").upperBound
    )
    let values = try await session.completions(at: position, invocation: .automatic)
    let overloads = values.filter { $0.label == "send" }

    XCTAssertEqual(overloads.count, 2)
    XCTAssertTrue(overloads.contains { $0.detail?.contains("value: i32") == true })
    XCTAssertTrue(overloads.contains { $0.detail?.contains("value: &str") == true })

    try await session.close()
    try await backend.shutdown()
  }

  func testNestedCargoPathDependencyUsesManifestDirectoryAsItsBase() async throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let workspace = base.appendingPathComponent("workspace", isDirectory: true)
    let package = workspace.appendingPathComponent("apps/tool", isDirectory: true)
    let dependency = base.appendingPathComponent("shared/helper", isDirectory: true)
    let dependencySources = dependency.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: dependencySources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    try """
    [package]
    name = "tool"
    version = "0.1.0"

    [dependencies]
    helper = { path = "../../../shared/helper" }
    """.write(
      to: package.appendingPathComponent("Cargo.toml"),
      atomically: true,
      encoding: .utf8
    )
    try """
    [package]
    name = "helper"
    version = "0.1.0"
    """.write(
      to: dependency.appendingPathComponent("Cargo.toml"),
      atomically: true,
      encoding: .utf8
    )
    let source = dependencySources.appendingPathComponent("lib.rs")
    try "pub struct ExternalHelper;\n".write(
      to: source, atomically: true, encoding: .utf8
    )

    let index = ExternalSourceIndex(
      workspaceURL: workspace,
      languageCatalog: .standard,
      configuration: .init(),
      environment: ["HOME": base.path, "PATH": "/usr/bin:/bin"]
    )
    _ = await index.refresh()
    let snapshot = await index.snapshot(refreshIfNeeded: false)

    XCTAssertTrue(snapshot.files.contains { $0.file.url == source.standardizedFileURL })
  }

  func testStandalonePlansUseUniqueInterpolatedArtifactsAndRejectHeaders() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let swiftFile = root.appendingPathComponent("main.swift")
    let cFile = root.appendingPathComponent("main.c")
    let header = root.appendingPathComponent("main.h")
    let swiftPlan = try XCTUnwrap(EditorBuildDiscovery.singleFilePlan(fileURL: swiftFile))
    let cPlan = try XCTUnwrap(EditorBuildDiscovery.singleFilePlan(fileURL: cFile))

    let swiftOutput = try XCTUnwrap(swiftPlan.command(for: .build)?.arguments.last)
    let cOutput = try XCTUnwrap(cPlan.command(for: .build)?.arguments.last)
    XCTAssertTrue(swiftOutput.contains(".calcite-main-swift"))
    XCTAssertTrue(cOutput.contains(".calcite-main-c"))
    XCTAssertNotEqual(swiftOutput, cOutput)
    XCTAssertEqual(swiftPlan.command(for: .build)?.title, "Build main")
    XCTAssertNil(EditorBuildDiscovery.singleFilePlan(fileURL: header))
  }

  func testStandaloneObjectiveCUsesClangAndFoundation() throws {
    let root = FileManager.default.temporaryDirectory
    let file = root.appendingPathComponent("sample.m")
    let plan = try XCTUnwrap(EditorBuildDiscovery.singleFilePlan(fileURL: file))
    let command = try XCTUnwrap(plan.command(for: .build))
    XCTAssertEqual(command.executable, "clang")
    XCTAssertTrue(command.arguments.contains("Foundation"))
  }

  func testGradleAndMakeOnlyExposeAvailableRunTasks() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "plugins { id 'java' }".write(
      to: root.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)
    try "#!/bin/sh\n".write(
      to: root.appendingPathComponent("gradlew"), atomically: true, encoding: .utf8)
    var plan = EditorBuildDiscovery.inspect(workspaceURL: root)
    XCTAssertNil(plan.command(for: .run))
    XCTAssertEqual(plan.command(for: .build)?.executable, "/bin/sh")

    try FileManager.default.removeItem(at: root.appendingPathComponent("build.gradle"))
    try FileManager.default.removeItem(at: root.appendingPathComponent("gradlew"))
    try "all:\n\t@echo ok\ncheck:\n\t@echo check\n".write(
      to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
    plan = EditorBuildDiscovery.inspect(workspaceURL: root)
    XCTAssertNil(plan.command(for: .run))
    XCTAssertNotNil(plan.command(for: .check))
    XCTAssertNil(plan.command(for: .test))
  }

  func testBuildRunnerParsesCargoJSONAndTypeScriptDiagnostics() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("main.rs")
    try "fn main() {}\n".write(to: source, atomically: true, encoding: .utf8)
    let cargo =
      #"{"reason":"compiler-message","message":{"message":"mismatched types","code":{"code":"E0308"},"level":"error","spans":[{"file_name":"main.rs","line_start":1,"line_end":1,"column_start":4,"column_end":8,"is_primary":true}]}}"#
    let command = EditorBuildCommand(
      id: "parser", title: "Parser", kind: .check,
      arguments: [
        "sh", "-c",
        "printf '%s\\n' \"$CARGO_JSON\"; printf 'app.ts(3,7): error TS2322: bad value\\n' >&2",
      ],
      workingDirectory: root,
      environment: ["CARGO_JSON": cargo]
    )
    let stream = try await EditorBuildRunner().run(command)
    var diagnostics: [EditorBuildDiagnostic] = []
    for await event in stream {
      if case .diagnostic(let diagnostic) = event { diagnostics.append(diagnostic) }
    }
    let rust = try XCTUnwrap(diagnostics.first { $0.url.lastPathComponent == "main.rs" })
    XCTAssertEqual(rust.code, "E0308")
    XCTAssertEqual(rust.endColumn, 8)
    XCTAssertEqual(rust.source, "rustc")
    let ts = try XCTUnwrap(diagnostics.first { $0.url.lastPathComponent == "app.ts" })
    XCTAssertEqual(ts.code, "TS2322")
    XCTAssertEqual(ts.severity, .error)
  }

  func testBuildRunnerParsesClangSeverityAndPythonTraceback() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let command = EditorBuildCommand(
      id: "mixed-diagnostics", title: "Mixed Diagnostics", kind: .check,
      arguments: [
        "sh", "-c",
        "printf 'main.c:2:4: fatal error: missing header\nmain.c:3:1: remark: vectorized loop\n  File \"script.py\", line 7, in <module>\nValueError: bad value\n' >&2",
      ],
      workingDirectory: root
    )
    let stream = try await EditorBuildRunner().run(command)
    var diagnostics: [EditorBuildDiagnostic] = []
    for await event in stream {
      if case .diagnostic(let diagnostic) = event { diagnostics.append(diagnostic) }
    }

    let fatal = try XCTUnwrap(diagnostics.first { $0.message == "missing header" })
    XCTAssertEqual(fatal.severity, .error)
    XCTAssertEqual(fatal.source, "clang")

    let remark = try XCTUnwrap(diagnostics.first { $0.message == "vectorized loop" })
    XCTAssertEqual(remark.severity, .information)
    XCTAssertEqual(remark.source, "clang")

    let python = try XCTUnwrap(diagnostics.first { $0.url.lastPathComponent == "script.py" })
    XCTAssertEqual(python.line, 7)
    XCTAssertEqual(python.code, "ValueError")
    XCTAssertEqual(python.source, "python")
    XCTAssertEqual(python.message, "ValueError: bad value")
  }

  func testBuildDiscoveryRecognizesPythonProjectAndVenvCommands() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("tests", isDirectory: true),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try "[build-system]\nrequires = [\"setuptools\"]\n\n[tool.pytest.ini_options]\n".write(
      to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
    try "print('ok')\n".write(
      to: root.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)

    let plan = EditorBuildDiscovery.inspect(workspaceURL: root)
    XCTAssertEqual(plan.projectKind, .python)
    XCTAssertEqual(plan.command(for: .check)?.executable, "python")
    XCTAssertEqual(plan.command(for: .check)?.arguments, ["-m", "compileall", "-q", "."])
    XCTAssertEqual(plan.command(for: .build)?.executable, "python")
    XCTAssertEqual(
      plan.command(for: .build)?.arguments,
      ["-m", "pip", "wheel", ".", "--no-deps", "--wheel-dir", "dist"]
    )
    XCTAssertEqual(plan.command(for: .run)?.arguments, ["main.py"])
    XCTAssertEqual(plan.command(for: .test)?.arguments, ["-m", "pytest"])
  }

  func testSelectedPythonEnvironmentFeedsExternalLibraryCompletion() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let environment = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bin = environment.appendingPathComponent("bin", isDirectory: true)
    let package = environment.appendingPathComponent(
      "lib/python3.12/site-packages/remote_pkg", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: environment)
    }

    let python = bin.appendingPathComponent("python")
    try "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    try "class RemoteClient:\n    pass\n".write(
      to: package.appendingPathComponent("client.py"), atomically: true, encoding: .utf8)
    let current = root.appendingPathComponent("main.py")
    try "value = RemoteCl\n".write(to: current, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      languageID: "python",
      completionStrategy: .mergeKeywordsAndFallbackOnError,
      processEnvironment: [
        "PATH": "/usr/bin:/bin", "CALCITE_PYTHON_INTERPRETER": python.path,
      ]
    )
    _ = try await backend.scanSourceWorkspace()
    let session = try await backend.openFileSession(at: current, languageID: "python")
    let values = try await session.completions(
      at: .init(line: 0, utf16Column: 16), invocation: .automatic)

    XCTAssertTrue(values.contains { $0.label == "RemoteClient" })
    try await session.close()
    try await backend.shutdown()
  }

  func testExternalHeaderSymbolsAreCompatibleWithCppAndSwift() {
    let url = URL(fileURLWithPath: "/tmp/external/include/bridge.h")
    let external = ExternalIndexedSourceFile(
      file: SourceCodeFile(
        id: SourceFileID(),
        name: "bridge.h",
        relativePath: "External/bridge.h",
        url: url,
        languageID: "c",
        content: "struct SharedBridge {};\n",
        version: 0,
        savedVersion: 0,
        encoding: .utf8,
        lineEnding: .lineFeed,
        state: .clean,
        diskFingerprint: nil
      ),
      packageName: "bridge"
    )
    var index = ProjectCompletionIndex()
    index.update(workspaceFiles: [], externalFiles: [external], externalGeneration: 1)

    XCTAssertTrue(index.symbols(languageID: "cpp").contains { $0.name == "SharedBridge" })
    XCTAssertTrue(index.symbols(languageID: "swift").contains { $0.name == "SharedBridge" })
  }

}
