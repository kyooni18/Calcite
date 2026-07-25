import XCTest

@testable import EditorServices

private actor PipelineSyntaxStub: SyntaxProviding {
  private var snapshot = TextSnapshot(text: "")

  func open(snapshot: TextSnapshot) { self.snapshot = snapshot }
  func apply(change: AppliedTextEdit) { snapshot = change.newSnapshot }
  func highlights(in range: EditorTextRange?) -> [Highlight] {
    let end = (try? snapshot.position(atUTF16Offset: min(3, snapshot.utf16Count))) ?? .zero
    return [.init(range: .init(start: .zero, end: end), capture: "keyword")]
  }
  func foldingRanges() -> [FoldingRange] { [] }
  func close() {}
}

private actor PipelineLanguageStub: LanguageIntelligenceProviding {
  nonisolated let diagnostics: AsyncStream<DiagnosticBatch>
  private let continuation: AsyncStream<DiagnosticBatch>.Continuation
  private var semanticRequestCount = 0

  init() { (diagnostics, continuation) = AsyncStream.makeStream(of: DiagnosticBatch.self) }

  func open(uri: URL, languageID: String, snapshot: TextSnapshot) {}
  func change(uri: URL, change: AppliedTextEdit) {}
  func save(uri: URL, snapshot: TextSnapshot) {}
  func completions(uri: URL, at position: TextPosition, triggerCharacter: String?) -> [Completion] {
    [.init(label: "value", kind: .variable, insertText: "value")]
  }
  func hover(uri: URL, at position: TextPosition) -> HoverResult? { nil }
  func definitions(uri: URL, at position: TextPosition) -> [SourceLocation] { [] }
  func formatting(uri: URL, options: EditorFormattingOptions) -> [TextEdit] { [] }
  func close(uri: URL) {}

  func semanticHighlights(uri: URL) -> [SemanticHighlight] {
    semanticRequestCount += 1
    return [.init(range: .init(start: .zero, end: .zero), tokenType: "variable")]
  }

  func semanticRequests() -> Int { semanticRequestCount }

  func emit(_ batch: DiagnosticBatch) { continuation.yield(batch) }
}

private enum PipelineOpenFailure: Error {
  case rejected
}

private actor PipelineFailingSupplementalLanguageStub: LanguageIntelligenceProviding {
  nonisolated let diagnostics: AsyncStream<DiagnosticBatch> = AsyncStream { $0.finish() }

  func open(uri: URL, languageID: String, snapshot: TextSnapshot) throws {
    throw PipelineOpenFailure.rejected
  }
  func change(uri: URL, change: AppliedTextEdit) {}
  func save(uri: URL, snapshot: TextSnapshot) {}
  func completions(uri: URL, at position: TextPosition, triggerCharacter: String?) -> [Completion] {
    []
  }
  func hover(uri: URL, at position: TextPosition) -> HoverResult? { nil }
  func definitions(uri: URL, at position: TextPosition) -> [SourceLocation] { [] }
  func close(uri: URL) {}
}

final class EditorDocumentPipelineTests: XCTestCase {
  func testPipelineSynchronizesIncrementalEditsAndAnalysis() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Main.swift")
    try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)

    let language = PipelineLanguageStub()
    let backend = SwiftEditorBackend(
      workspaceURL: directory,
      languageService: language,
      syntaxFactory: { PipelineSyntaxStub() },
      completionStrategy: .languageServerOnly
    )
    let result = EditorServiceBootstrapResult(
      backend: backend,
      report: .init(),
      debuggerPath: nil
    )
    let workspace = EditorIDEWorkspace(
      serviceResult: result,
      documentConfiguration: .init(analysisDebounce: .milliseconds(1))
    )
    let pipeline = try await workspace.openDocument(at: file)

    _ = try await pipeline.applyUTF16Edit(NSRange(location: 4, length: 1), replacement: "value")
    let analysis = try await pipeline.refreshAnalysis()
    let completions = try await pipeline.completions(atUTF16Offset: 9)

    XCTAssertEqual(analysis.snapshot.text, "let value = 1\n")
    XCTAssertEqual(analysis.syntaxHighlights.first?.capture, "keyword")
    XCTAssertEqual(analysis.semanticHighlights.first?.tokenType, "variable")
    XCTAssertEqual(completions.first?.label, "value")

    try await pipeline.persist()
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 1\n")
    try await workspace.shutdown()
  }

  func testSemanticLanguageServiceWaitsForTypingToBecomeIdle() async throws {
    let language = PipelineLanguageStub()
    let backend = SwiftEditorBackend(
      workspaceURL: URL(fileURLWithPath: "/tmp"),
      languageService: language,
      syntaxFactory: { PipelineSyntaxStub() }
    )
    let pipeline = try await EditorDocumentPipeline.open(
      backend: backend,
      at: URL(fileURLWithPath: "/tmp/SemanticDebounce.swift"),
      text: "let value = 1",
      configuration: .init(
        analysisDebounce: .milliseconds(1),
        semanticAnalysisDebounce: .milliseconds(120)
      )
    )

    _ = try await pipeline.refreshAnalysis()
    let baseline = await language.semanticRequests()
    _ = try await pipeline.applyUTF16Edit(
      NSRange(location: 3, length: 0),
      replacement: " "
    )
    try await Task.sleep(for: .milliseconds(30))
    let earlyCount = await language.semanticRequests()
    XCTAssertEqual(earlyCount, baseline)

    try await Task.sleep(for: .milliseconds(130))
    let idleCount = await language.semanticRequests()
    XCTAssertEqual(idleCount, baseline + 1)
    try await pipeline.close()
  }

  func testPipelineMergesDiagnosticsAndRejectsOlderVersions() async throws {
    let language = PipelineLanguageStub()
    let backend = SwiftEditorBackend(
      workspaceURL: URL(fileURLWithPath: "/tmp"),
      languageService: language
    )
    let uri = URL(fileURLWithPath: "/tmp/Pipeline.swift")
    let pipeline = try await EditorDocumentPipeline.open(
      backend: backend,
      at: uri,
      text: "let value = 1",
      configuration: .init(analysisDebounce: .milliseconds(1))
    )
    _ = try await pipeline.applyUTF16Edit(NSRange(location: 13, length: 0), replacement: "\n")

    let stream = pipeline.updates
    let expected = Diagnostic(
      range: .init(start: .zero, end: .zero),
      message: "current",
      severity: .error
    )
    await language.emit(
      .init(
        uri: uri, version: 0,
        diagnostics: [
          .init(range: .init(start: .zero, end: .zero), message: "stale", severity: .warning)
        ]))
    await language.emit(.init(uri: uri, version: 1, diagnostics: [expected]))

    let received = await firstDiagnostics(from: stream)
    XCTAssertEqual(received, [expected])
    try await pipeline.close()
  }

  func testWorkspaceReusesDocumentPipelineAndRejectsWorkAfterShutdown() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Main.swift")
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: directory,
      languageService: PipelineLanguageStub(),
      syntaxFactory: { PipelineSyntaxStub() }
    )
    let workspace = EditorIDEWorkspace(
      serviceResult: .init(backend: backend, report: .init(), debuggerPath: nil)
    )

    let first = try await workspace.openDocument(at: file)
    let second = try await workspace.openDocument(at: file)
    XCTAssertTrue(first === second)
    let openURLs = await workspace.openDocumentURLs()
    XCTAssertEqual(openURLs, [file.standardizedFileURL])

    try await workspace.shutdown()
    do {
      _ = try await workspace.openDocument(at: file)
      XCTFail("Opening after shutdown must fail")
    } catch let error as SwiftEditorBackendError {
      guard case .shutdown = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testClosedPipelineRejectsCompletionRequests() async throws {
    let backend = SwiftEditorBackend(workspaceURL: URL(fileURLWithPath: "/tmp"))
    let pipeline = try await EditorDocumentPipeline.open(
      backend: backend,
      at: URL(fileURLWithPath: "/tmp/Closed.swift"),
      text: "let value = 1"
    )
    try await pipeline.close()

    do {
      _ = try await pipeline.completions(atUTF16Offset: 0)
      XCTFail("Completion on a closed pipeline must fail")
    } catch let error as SwiftEditorBackendError {
      guard case .documentNotOpen = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRustDocumentOpensWhenSupplementalLanguageServiceFails() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("main.rs")
    let text = "fn calculate_total() -> i32 { 42 }\nfn main() { cal }\n"
    try text.write(to: file, atomically: true, encoding: .utf8)

    let backend = try await EditorBackendBuilder(
      workspaceURL: root,
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    .addingLanguageService(
      .init(
        id: "broken-rust-analyzer",
        service: PipelineFailingSupplementalLanguageStub(),
        role: .supplemental,
        selector: .init(languageIDs: ["rust"], fileExtensions: ["rs"])
      )
    )
    .build()
    _ = try await backend.scanSourceWorkspace()
    let workspace = EditorIDEWorkspace(
      serviceResult: .init(backend: backend, report: .init(), debuggerPath: nil),
      documentConfiguration: .init(analysisDebounce: .milliseconds(1))
    )

    let pipeline = try await workspace.openDocument(at: file, languageID: "rust")
    let snapshot = try await pipeline.snapshot()
    let completions = try await pipeline.completions(atUTF16Offset: 50)

    XCTAssertEqual(snapshot.text, text)
    XCTAssertTrue(completions.contains { $0.label == "calculate_total" })
    try await workspace.shutdown()
  }

  private func firstDiagnostics(
    from stream: AsyncStream<EditorDocumentPipelineUpdate>
  ) async -> [Diagnostic] {
    for await update in stream {
      if case .diagnostics(let diagnostics) = update, !diagnostics.isEmpty {
        return diagnostics
      }
    }
    return []
  }
}
