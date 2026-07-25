import EditorServices
import Foundation
import XCTest

final class ProjectAwareLanguageServerActivationTests: XCTestCase {
  func testAutomaticRustFileWithoutWorkspaceMarkerDoesNotStartRustAnalyzer() async throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    try "fn main() {}\n".write(
      to: workspace.appendingPathComponent("main.rs"),
      atomically: true,
      encoding: .utf8
    )

    var configuration = EditorServicesConfiguration(
      workspaceURL: workspace,
      languageSelection: .automatic,
      requirementPolicy: .bestEffort
    )
    configuration.features = .init(languageServers: true, syntax: false, debugging: false)

    let result = try await EditorServiceBootstrap.inspect(configuration: configuration)
    let diagnostic = try XCTUnwrap(
      result.report.diagnostics(for: .rust, feature: .languageServer).first
    )

    XCTAssertEqual(diagnostic.availability, .disabled)
    XCTAssertTrue(diagnostic.recoverySuggestion?.contains("Cargo.toml") == true)
  }

  func testCargoMarkerAllowsRustAnalyzerResolution() async throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    try "[package]\nname = \"sample\"\nversion = \"0.1.0\"\n".write(
      to: workspace.appendingPathComponent("Cargo.toml"),
      atomically: true,
      encoding: .utf8
    )
    try "fn main() {}\n".write(
      to: workspace.appendingPathComponent("main.rs"),
      atomically: true,
      encoding: .utf8
    )

    var configuration = EditorServicesConfiguration(
      workspaceURL: workspace,
      languageSelection: .automatic,
      requirementPolicy: .bestEffort
    )
    configuration.features = .init(languageServers: true, syntax: false, debugging: false)
    configuration.overrides.languageServerExecutables[.rust] = "/bin/true"

    let result = try await EditorServiceBootstrap.inspect(configuration: configuration)
    let diagnostic = try XCTUnwrap(
      result.report.diagnostics(for: .rust, feature: .languageServer).first
    )

    XCTAssertEqual(diagnostic.availability, .available(path: "/bin/true"))
  }

  func testRustProjectJSONCountsAsWorkspaceMarker() async throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    try "{\"crates\": []}\n".write(
      to: workspace.appendingPathComponent("rust-project.json"),
      atomically: true,
      encoding: .utf8
    )

    let report = try await EditorProjectInspector.inspect(workspaceURL: workspace)
    let evidence = try XCTUnwrap(report.evidence(for: .rust))

    XCTAssertTrue(evidence.projectMarkers.contains("rust-project.json"))
  }

  func testManualRustSelectionStillAllowsExplicitSingleFileServerUse() async throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }

    var configuration = EditorServicesConfiguration(
      workspaceURL: workspace,
      languageSelection: .manual([.rust]),
      requirementPolicy: .bestEffort
    )
    configuration.features = .init(languageServers: true, syntax: false, debugging: false)
    configuration.overrides.languageServerExecutables[.rust] = "/bin/true"

    let result = try await EditorServiceBootstrap.inspect(configuration: configuration)
    let diagnostic = try XCTUnwrap(
      result.report.diagnostics(for: .rust, feature: .languageServer).first
    )

    XCTAssertEqual(diagnostic.availability, .available(path: "/bin/true"))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("EditorServicesTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
