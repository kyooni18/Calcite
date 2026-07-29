import EditorCore
@testable import EditorServiceKit
import Foundation
import XCTest

final class LanguageServiceRouterWorkspaceTests: XCTestCase {
  func testWorkspaceSymbolsAreMergedDeduplicatedAndRouted() async throws {
    let location = SourceLocation(
      uri: URL(fileURLWithPath: "/tmp/project/Sources/Example.swift"),
      range: .init(start: .zero, end: .init(line: 0, utf16Column: 7))
    )
    let primary = WorkspaceLanguageService(
      symbols: [.init(name: "Example", kind: .struct, location: location)]
    )
    let supplemental = WorkspaceLanguageService(
      symbols: [
        .init(name: "Example", kind: .struct, location: location),
        .init(name: "helper", kind: .function, location: location),
      ]
    )
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "primary", service: primary),
      .init(id: "supplemental", service: supplemental, role: .supplemental),
    ])
    defer { Task { try? await router.shutdown() } }

    let symbols = try await router.workspaceSymbols(query: "Ex")

    XCTAssertEqual(symbols.map(\.name), ["Example", "helper"])
    XCTAssertEqual(symbols.map(\.serviceIdentifier), ["primary", "supplemental"])
  }

  func testWorkspaceFileChangesAreBroadcastToEveryService() async throws {
    let first = WorkspaceLanguageService()
    let second = WorkspaceLanguageService()
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "first", service: first),
      .init(id: "second", service: second, role: .supplemental),
    ])
    defer { Task { try? await router.shutdown() } }
    let changes = [
      EditorWorkspaceFileChange(
        uri: URL(fileURLWithPath: "/tmp/project/Sources/New.swift"),
        kind: .created
      ),
      EditorWorkspaceFileChange(
        uri: URL(fileURLWithPath: "/tmp/project/Sources/Old.swift"),
        kind: .deleted
      ),
    ]

    try await router.notifyWorkspaceFileChanges(changes)

    let firstChanges = await first.recordedChanges()
    let secondChanges = await second.recordedChanges()
    XCTAssertEqual(firstChanges, changes)
    XCTAssertEqual(secondChanges, changes)
  }

  func testPullDiagnosticsMergesMatchingProjectServices() async throws {
    let uri = URL(fileURLWithPath: "/tmp/project/Sources/Closed.swift")
    let shared = Diagnostic(
      range: .init(start: .zero, end: .init(line: 0, utf16Column: 1)),
      message: "Shared diagnostic",
      severity: .warning
    )
    let primaryOnly = Diagnostic(
      range: .init(start: .init(line: 1, utf16Column: 0), end: .init(line: 1, utf16Column: 2)),
      message: "Primary diagnostic",
      severity: .error
    )
    let supplementalOnly = Diagnostic(
      range: .init(start: .init(line: 2, utf16Column: 0), end: .init(line: 2, utf16Column: 2)),
      message: "Supplemental diagnostic",
      severity: .information
    )
    let primary = WorkspaceLanguageService(
      diagnosticBatch: .init(uri: uri, version: 3, diagnostics: [shared, primaryOnly])
    )
    let supplemental = WorkspaceLanguageService(
      diagnosticBatch: .init(uri: uri, version: 4, diagnostics: [shared, supplementalOnly])
    )
    let router = try await LanguageServiceRouter(registrations: [
      .init(
        id: "primary",
        service: primary,
        selector: .init(languageIDs: ["swift"], fileExtensions: ["swift"])
      ),
      .init(
        id: "supplemental",
        service: supplemental,
        role: .supplemental,
        selector: .init(languageIDs: ["swift"], fileExtensions: ["swift"])
      ),
    ])
    defer { Task { try? await router.shutdown() } }

    let batch = try await router.pullDiagnostics(uri: uri)

    XCTAssertEqual(batch.version, 4)
    XCTAssertEqual(batch.diagnostics, [shared, primaryOnly, supplementalOnly])
    XCTAssertNil(batch.serviceIdentifier)
  }

  func testPullDiagnosticsDoesNotRequireAnOpenDocument() async throws {
    let uri = URL(fileURLWithPath: "/tmp/project/Sources/Closed.swift")
    let expected = DiagnosticBatch(
      uri: uri,
      version: nil,
      diagnostics: [
        Diagnostic(
          range: .init(start: .zero, end: .init(line: 0, utf16Column: 1)),
          message: "Closed-file diagnostic",
          severity: .warning
        )
      ]
    )
    let service = WorkspaceLanguageService(diagnosticBatch: expected)
    let router = try await LanguageServiceRouter(registrations: [
      .init(
        id: "swift",
        service: service,
        selector: .init(languageIDs: ["swift"], fileExtensions: ["swift"])
      )
    ])
    defer { Task { try? await router.shutdown() } }

    let batch = try await router.pullDiagnostics(uri: uri)

    XCTAssertEqual(batch.uri, uri)
    XCTAssertEqual(batch.diagnostics, expected.diagnostics)
    XCTAssertEqual(batch.serviceIdentifier, "swift")
  }
}

private actor WorkspaceLanguageService: LanguageIntelligenceProviding {
  nonisolated var diagnostics: AsyncStream<DiagnosticBatch> { AsyncStream { $0.finish() } }
  nonisolated var messages: AsyncStream<LanguageServerMessage> { AsyncStream { $0.finish() } }

  private let symbols: [EditorWorkspaceSymbol]
  private let diagnosticBatch: DiagnosticBatch?
  private var changes: [EditorWorkspaceFileChange] = []

  init(
    symbols: [EditorWorkspaceSymbol] = [],
    diagnosticBatch: DiagnosticBatch? = nil
  ) {
    self.symbols = symbols
    self.diagnosticBatch = diagnosticBatch
  }

  func open(uri: URL, languageID: String, snapshot: TextSnapshot) async throws {}
  func change(uri: URL, change: AppliedTextEdit) async throws {}
  func completions(uri: URL, at position: TextPosition, triggerCharacter: String?) async throws
    -> [Completion]
  {
    []
  }
  func hover(uri: URL, at position: TextPosition) async throws -> HoverResult? { nil }
  func definitions(uri: URL, at position: TextPosition) async throws -> [SourceLocation] { [] }
  func close(uri: URL) async throws {}

  func workspaceSymbols(query: String) async throws -> [EditorWorkspaceSymbol] { symbols }

  func notifyWorkspaceFileChanges(_ changes: [EditorWorkspaceFileChange]) async throws {
    self.changes.append(contentsOf: changes)
  }

  func pullDiagnostics(uri: URL, previousResultID: String?) async throws -> DiagnosticBatch {
    guard let diagnosticBatch else {
      throw LanguageFeatureError.unsupported("textDocument/diagnostic")
    }
    return diagnosticBatch
  }

  func recordedChanges() -> [EditorWorkspaceFileChange] { changes }
}
