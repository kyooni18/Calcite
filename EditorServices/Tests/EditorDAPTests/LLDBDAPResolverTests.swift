import Foundation
import XCTest
@testable import EditorDAP

#if os(macOS) || os(Linux)
final class LLDBDAPResolverTests: XCTestCase {
    func testExplicitExecutableIsAuthoritative() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("lldb-dap")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertEqual(
            try LLDBDAPResolver.resolve(explicitPath: executable.path, environment: [:]),
            executable.path
        )
    }

    func testMissingExplicitPathDoesNotFallBack() {
        let missing = "/definitely/missing/lldb-dap"
        XCTAssertThrowsError(try LLDBDAPResolver.resolve(
            explicitPath: missing,
            environment: ProcessInfo.processInfo.environment
        )) { error in
            XCTAssertEqual(error as? LLDBDAPResolutionError, .executableNotFound)
        }
    }

    func testNonExecutableExplicitPathIsRejected() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not executable".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        XCTAssertThrowsError(try LLDBDAPResolver.resolve(explicitPath: file.path, environment: [:])) { error in
            XCTAssertEqual(error as? LLDBDAPResolutionError, .notExecutable(file.path))
        }
    }
}
#endif
