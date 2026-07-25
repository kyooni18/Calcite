import XCTest
@testable import EditorCore

private enum StubError: Error { case failure }
private actor SyntaxStub: SyntaxProviding {
    var snapshot: TextSnapshot?
    var failApply = false
    func open(snapshot: TextSnapshot) { self.snapshot = snapshot }
    func apply(change: AppliedTextEdit) throws { if failApply { throw StubError.failure }; snapshot = change.newSnapshot }
    func highlights(in range: TextRange?) -> [Highlight] { [Highlight(range: .init(start: .zero, end: .zero), capture: "test")] }
    func foldingRanges() -> [FoldingRange] { [] }
    func close() { snapshot = nil }
    func setFailApply(_ value: Bool) { failApply = value }
}
private actor LanguageStub: LanguageIntelligenceProviding {
    nonisolated let diagnostics = AsyncStream<DiagnosticBatch> { _ in }
    var snapshot: TextSnapshot?
    var failChange = false
    var failOpen = false
    func open(uri: URL, languageID: String, snapshot: TextSnapshot) throws { if failOpen { throw StubError.failure }; self.snapshot = snapshot }
    func change(uri: URL, change: AppliedTextEdit) throws { if failChange { throw StubError.failure }; snapshot = change.newSnapshot }
    func save(uri: URL, snapshot: TextSnapshot) {}
    func completions(uri: URL, at position: TextPosition, triggerCharacter: String?) -> [Completion] { [Completion(label: "ok")] }
    func hover(uri: URL, at position: TextPosition) -> HoverResult? { nil }
    func definitions(uri: URL, at position: TextPosition) -> [SourceLocation] { [] }
    func close(uri: URL) { snapshot = nil }
    func setFailChange(_ value: Bool) { failChange = value }
    func setFailOpen(_ value: Bool) { failOpen = value }
}

final class EditorDocumentTests: XCTestCase {
    func testRequiresOpen() async throws {
        let document = EditorDocument(uri: URL(fileURLWithPath: "/tmp/a.swift"), languageID: "swift")
        do { _ = try await document.apply(.init(range: .init(start: .zero, end: .zero), replacement: "x")); XCTFail() }
        catch { XCTAssertEqual(error as? EditorDocumentError, .notOpen) }
    }

    func testOpenApplyAndClose() async throws {
        let syntax = SyntaxStub(), language = LanguageStub()
        let document = EditorDocument(uri: URL(fileURLWithPath: "/tmp/a.swift"), languageID: "swift", text: "a", syntax: syntax, language: language)
        try await document.open()
        _ = try await document.apply(.init(range: .init(start: .init(line: 0, utf16Column: 1), end: .init(line: 0, utf16Column: 1)), replacement: "b"))
        let snapshot = await document.snapshot
        let synchronizedState = await document.state
        let completions = try await document.completions(at: .zero)
        XCTAssertEqual(snapshot.text, "ab")
        XCTAssertEqual(synchronizedState, .synchronized(version: 1))
        XCTAssertEqual(completions.first?.label, "ok")
        try await document.close()
        let closedState = await document.state
        XCTAssertEqual(closedState, .closed)
    }

    func testLanguageFailureRollsBackAllServices() async throws {
        let syntax = SyntaxStub(), language = LanguageStub()
        let document = EditorDocument(uri: URL(fileURLWithPath: "/tmp/a.swift"), languageID: "swift", text: "a", syntax: syntax, language: language)
        try await document.open(); await language.setFailChange(true); await language.setFailOpen(true)
        do { _ = try await document.apply(.init(range: .init(start: .zero, end: .zero), replacement: "x")); XCTFail() } catch {}
        let rolledBack = await document.snapshot
        let syntaxSnapshot = await syntax.snapshot
        let failedState = await document.state
        XCTAssertEqual(rolledBack.text, "a")
        XCTAssertNil(syntaxSnapshot)
        XCTAssertEqual(failedState, .desynchronized(localVersion: 0))
        await language.setFailChange(false); await language.setFailOpen(false)
        try await document.resynchronize()
        let recoveredState = await document.state
        XCTAssertEqual(recoveredState, .synchronized(version: 0))
    }

    func testSyntaxFailureRollsBackBuffer() async throws {
        let syntax = SyntaxStub()
        let document = EditorDocument(uri: URL(fileURLWithPath: "/tmp/a.swift"), languageID: "swift", text: "a", syntax: syntax)
        try await document.open(); await syntax.setFailApply(true)
        do { _ = try await document.apply(.init(range: .init(start: .zero, end: .zero), replacement: "x")); XCTFail() } catch {}
        let snapshot = await document.snapshot
        XCTAssertEqual(snapshot.text, "a")
    }
    func testFailedInitialOpenCleansSyntaxState() async throws {
        let syntax = SyntaxStub(), language = LanguageStub()
        await language.setFailOpen(true)
        let document = EditorDocument(
            uri: URL(fileURLWithPath: "/tmp/failed-open.swift"),
            languageID: "swift",
            text: "let value = 1",
            syntax: syntax,
            language: language
        )
        do { try await document.open(); XCTFail("Expected open to fail") } catch {}
        let syntaxSnapshot = await syntax.snapshot
        let state = await document.state
        XCTAssertNil(syntaxSnapshot)
        XCTAssertEqual(state, .desynchronized(localVersion: 0))
    }

}
