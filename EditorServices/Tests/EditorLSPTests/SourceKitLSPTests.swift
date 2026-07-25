import XCTest
@testable import EditorLSP
@testable import EditorCore

#if os(macOS) || os(Linux)
final class SourceKitLSPTests: XCTestCase {
    func testResolverFindsInstalledSourceKit() throws {
        XCTAssertTrue(try SourceKitLSPResolver.resolve().hasSuffix("sourcekit-lsp"))
    }

    func testRealSourceKitInitializationOpenAndCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Smoke\", targets: [.executableTarget(name: \"Smoke\")])\n"
        try package.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let sources = root.appendingPathComponent("Sources/Smoke", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("main.swift")
        let text = "let value = 1\npri"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let connection = try SourceKitLSPConnection(workspaceURL: root)
        defer { connection.terminate() }
        _ = try await connection.service.initialize()
        try await connection.service.open(uri: file, languageID: "swift", snapshot: TextSnapshot(text: text))
        let completions = try await connection.service.completions(uri: file, at: .init(line: 1, utf16Column: 3))
        XCTAssertFalse(completions.isEmpty)
        try await connection.service.close(uri: file)
        try await connection.service.shutdown()
    }
}
#endif

#if os(macOS) || os(Linux)
extension SourceKitLSPTests {
    func testMissingExplicitSourceKitPathDoesNotFallBack() {
        XCTAssertThrowsError(try SourceKitLSPResolver.resolve(
            explicitPath: "/definitely/missing/sourcekit-lsp",
            environment: ProcessInfo.processInfo.environment
        )) { error in
            XCTAssertEqual(error as? SourceKitLSPResolutionError, .executableNotFound)
        }
    }
}
#endif
