import Foundation
import XCTest

@testable import EditorServices

final class EditorServicesExecutionRegistryTests: XCTestCase {
  func testCustomSingleFileProviderExpandsWorkspaceAndFileTokens() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let configDirectory = root.appendingPathComponent(".calcite", isDirectory: true)
    let file = root.appendingPathComponent("Sources/example.foo")
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "print".write(to: file, atomically: true, encoding: .utf8)
    let payload = """
      [
        {
          "id": "foo",
          "fileExtensions": ["foo"],
          "executable": "/usr/bin/env",
          "arguments": ["echo", "${stem}", "${workspace}", "${file}"],
          "environment": {}
        }
      ]
      """
    try payload.write(
      to: configDirectory.appendingPathComponent("single-file-providers.json"),
      atomically: true,
      encoding: .utf8
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let resolution = EditorSingleFileProviderRegistry.resolve(
      fileURL: file,
      workspaceURL: root
    )

    let plan = try XCTUnwrap(resolution.plan)
    let command = try XCTUnwrap(plan.command(for: .run))
    XCTAssertEqual(command.executable, "/usr/bin/env")
    XCTAssertTrue(command.arguments.contains("example"))
    XCTAssertTrue(command.arguments.contains(root.path))
    XCTAssertTrue(command.arguments.contains(file.path))
  }

  func testBuildCommandArtifactPathSurvivesCodingRoundTrip() throws {
    let command = EditorBuildCommand(
      id: "custom",
      title: "Custom",
      kind: .custom,
      executable: "/usr/bin/env",
      arguments: ["true"],
      workingDirectory: URL(fileURLWithPath: "/tmp"),
      artifactPath: "/tmp/output"
    )

    let encoded = try JSONEncoder().encode(command)
    let decoded = try JSONDecoder().decode(EditorBuildCommand.self, from: encoded)
    XCTAssertEqual(decoded.artifactPath, "/tmp/output")
  }
}
