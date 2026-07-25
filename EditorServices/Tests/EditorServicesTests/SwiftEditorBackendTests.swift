import XCTest

@testable import EditorServices

private enum BackendTestError: Error { case completionFailure, changeFailure }

private actor BackendSyntaxStub: SyntaxProviding {
  private var snapshot: TextSnapshot?
  func open(snapshot: TextSnapshot) { self.snapshot = snapshot }
  func apply(change: AppliedTextEdit) { snapshot = change.newSnapshot }
  func highlights(in range: TextRange?) -> [Highlight] {
    [Highlight(range: .init(start: .zero, end: .zero), capture: "keyword")]
  }
  func foldingRanges() -> [FoldingRange] {
    [FoldingRange(range: .init(start: .zero, end: .init(line: 1, utf16Column: 0)))]
  }
  func close() { snapshot = nil }
}

private actor BackendTestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in waiters.append(continuation) }
  }

  func signal() {
    guard !isOpen else { return }
    isOpen = true
    let pending = waiters
    waiters.removeAll(keepingCapacity: false)
    for continuation in pending { continuation.resume() }
  }
}

private actor BackendLanguageStub: LanguageIntelligenceProviding {
  nonisolated let diagnostics: AsyncStream<DiagnosticBatch>
  private let continuation: AsyncStream<DiagnosticBatch>.Continuation
  private var snapshots: [URL: TextSnapshot] = [:]
  private var completionFails = false
  private var failingChangeURIs: Set<URL> = []
  private(set) var completionCount = 0
  private(set) var saveCount = 0
  private let openStarted: BackendTestGate?
  private let openRelease: BackendTestGate?

  init(openStarted: BackendTestGate? = nil, openRelease: BackendTestGate? = nil) {
    self.openStarted = openStarted
    self.openRelease = openRelease
    (diagnostics, continuation) = AsyncStream.makeStream(of: DiagnosticBatch.self)
  }

  func open(uri: URL, languageID: String, snapshot: TextSnapshot) async {
    await openStarted?.signal()
    await openRelease?.wait()
    snapshots[uri] = snapshot
  }
  func change(uri: URL, change: AppliedTextEdit) throws {
    if failingChangeURIs.contains(uri) { throw BackendTestError.changeFailure }
    snapshots[uri] = change.newSnapshot
  }
  func save(uri: URL, snapshot: TextSnapshot) { saveCount += 1 }
  func completions(uri: URL, at position: TextPosition, triggerCharacter: String?) throws
    -> [Completion]
  {
    completionCount += 1
    if completionFails { throw BackendTestError.completionFailure }
    return [
      Completion(label: "actor", kind: .class, insertText: "actor"),
      Completion(label: "actual", kind: .variable),
    ]
  }
  func hover(uri: URL, at position: TextPosition) -> HoverResult? { HoverResult(markdown: "hover") }
  func definitions(uri: URL, at position: TextPosition) -> [SourceLocation] {
    [.init(uri: uri, range: .init(start: .zero, end: .zero))]
  }
  func references(uri: URL, at position: TextPosition, includeDeclaration: Bool) -> [SourceLocation]
  { [.init(uri: uri, range: .init(start: .zero, end: .zero))] }
  func formatting(uri: URL, options: EditorFormattingOptions) -> [TextEdit] {
    [.init(range: .init(start: .zero, end: .zero), replacement: "formatted")]
  }
  func rangeFormatting(uri: URL, range: TextRange, options: EditorFormattingOptions) -> [TextEdit] {
    [.init(range: range, replacement: "range")]
  }
  func prepareRename(uri: URL, at position: TextPosition) -> RenamePreparation? {
    .range(.init(start: .zero, end: position), placeholder: "name")
  }
  func rename(uri: URL, at position: TextPosition, newName: String) -> EditorWorkspaceEdit? {
    EditorWorkspaceEdit(documentEdits: [
      .init(
        uri: uri, edits: [.init(range: .init(start: .zero, end: position), replacement: newName)])
    ])
  }
  func semanticHighlights(uri: URL) -> [SemanticHighlight] {
    [.init(range: .init(start: .zero, end: .zero), tokenType: "type")]
  }
  func signatureHelp(uri: URL, at position: TextPosition) -> EditorSignatureHelp? {
    .init(
      signatures: [.init(label: "call(_:) -> Void", parameters: [.init(label: "value")])],
      activeSignature: 0, activeParameter: 0)
  }
  func documentSymbols(uri: URL) -> [EditorDocumentSymbol] {
    [
      .init(
        name: "Thing", kind: .struct, range: .init(start: .zero, end: .zero),
        selectionRange: .init(start: .zero, end: .zero))
    ]
  }
  func codeActions(uri: URL, range: TextRange, diagnostics: [Diagnostic], only: [String]?)
    -> [EditorCodeAction]
  {
    [
      .init(
        title: "Fix", kind: "quickfix", isPreferred: true,
        command: .init(title: "Fix", command: "fix", arguments: [.string("swift")]))
    ]
  }
  func inlayHints(uri: URL, range: TextRange) -> [EditorInlayHint] {
    [.init(position: .zero, label: ": Int", kind: .type)]
  }
  func close(uri: URL) { snapshots.removeValue(forKey: uri) }

  func emit(_ batch: DiagnosticBatch) { continuation.yield(batch) }
  func setCompletionFailure(_ value: Bool) { completionFails = value }
  func setChangeFailure(_ value: Bool, for uri: URL) {
    if value { failingChangeURIs.insert(uri) } else { failingChangeURIs.remove(uri) }
  }
}

private actor ShutdownFlag {
  private(set) var count = 0
  func mark() { count += 1 }
}

private actor BackendAutoAdapter {
  private var sequence = 100
  weak var session: DAPSession?

  func attach(_ session: DAPSession) { self.session = session }

  func write(_ framed: Data) async throws {
    var framer = DAPFramer()
    let request = try JSONDecoder().decode(DAPRequest.self, from: framer.append(framed).first!)
    sequence += 1
    let body: DAPValue
    switch request.command {
    case "initialize":
      body = [
        "supportsConfigurationDoneRequest": true,
        "supportsFunctionBreakpoints": true,
        "supportsConditionalBreakpoints": true,
        "supportsHitConditionalBreakpoints": true,
        "supportsStepBack": true,
        "supportsSetVariable": true,
        "supportsRestartFrame": true,
        "supportsRestartRequest": true,
        "supportsExceptionInfoRequest": true,
        "supportsLoadedSourcesRequest": true,
        "supportsModulesRequest": true,
        "supportsTerminateRequest": true,
      ]
    case "setBreakpoints", "setFunctionBreakpoints":
      body = ["breakpoints": [["verified": true, "line": 3]]]
    case "threads":
      body = ["threads": [["id": 7, "name": "main"]]]
    case "stackTrace":
      body = ["stackFrames": [["id": 11, "name": "main", "line": 3, "column": 1]]]
    case "scopes":
      body = ["scopes": [["name": "Locals", "variablesReference": 4, "expensive": false]]]
    case "variables":
      body = ["variables": [["name": "value", "value": "42", "variablesReference": 0]]]
    case "evaluate":
      body = ["result": "42", "variablesReference": 0]
    case "setVariable":
      body = ["value": "43", "variablesReference": 0]
    case "exceptionInfo":
      body = ["exceptionId": "E", "description": "failure", "breakMode": "always"]
    case "source":
      body = ["content": "let value = 42", "mimeType": "text/x-swift"]
    case "modules":
      body = ["modules": [["id": 1, "name": "App", "path": "/tmp/App"]], "totalModules": 1]
    case "loadedSources":
      body = ["sources": [["name": "Backend.swift", "path": "/tmp/Backend.swift"]]]
    case "continue":
      body = ["allThreadsContinued": true]
    case "custom/request":
      body = ["ok": true]
    default:
      body = [:]
    }
    let response = DAPResponse(
      seq: sequence,
      requestSeq: request.seq,
      success: true,
      command: request.command,
      body: body
    )
    try await session?.receive(try DAPFramer.frame(response))
  }
}

final class SwiftEditorBackendTests: XCTestCase {
  private let uri = URL(fileURLWithPath: "/tmp/Backend.swift")

  func testUnifiedDocumentAndLanguageWorkflow() async throws {
    let language = BackendLanguageStub()
    let shutdown = ShutdownFlag()
    let backend = SwiftEditorBackend(
      workspaceURL: URL(fileURLWithPath: "/tmp"),
      languageService: language,
      syntaxFactory: { BackendSyntaxStub() },
      languageServerShutdown: { await shutdown.mark() }
    )

    try await backend.openDocument(at: uri, text: "act\n")
    do {
      try await backend.openDocument(at: uri)
      XCTFail("Expected duplicate open")
    } catch {
      XCTAssertEqual(error as? SwiftEditorBackendError, .documentAlreadyOpen(uri))
    }

    let completions = try await backend.completions(in: uri, at: .init(line: 0, utf16Column: 3))
    XCTAssertEqual(completions.filter { $0.label == "actor" }.count, 1)
    XCTAssertTrue(completions.contains { $0.label == "actual" })

    _ = try await backend.apply(
      .init(
        range: .init(start: .init(line: 0, utf16Column: 3), end: .init(line: 0, utf16Column: 3)),
        replacement: "or"
      ), to: uri)
    let editedSnapshot = try await backend.snapshot(of: uri)
    let highlights = try await backend.highlights(in: uri)
    let folds = try await backend.foldingRanges(in: uri)
    let hover = try await backend.hover(in: uri, at: .zero)
    let definitions = try await backend.definitions(in: uri, at: .zero)
    let references = try await backend.references(in: uri, at: .zero)
    let formatting = try await backend.formattingEdits(in: uri)
    let rangeFormatting = try await backend.rangeFormattingEdits(
      in: uri,
      range: .init(start: .zero, end: .zero)
    )
    let renamePreparation = try await backend.prepareRename(
      in: uri,
      at: .init(line: 0, utf16Column: 5)
    )
    let rename = try await backend.rename(
      in: uri,
      at: .init(line: 0, utf16Column: 5),
      to: "item"
    )
    let semantic = try await backend.semanticHighlights(in: uri)
    let signature = try await backend.signatureHelp(in: uri, at: .zero)
    let symbols = try await backend.documentSymbols(in: uri)
    let actions = try await backend.codeActions(
      in: uri,
      range: .init(start: .zero, end: .zero)
    )
    let hints = try await backend.inlayHints(
      in: uri,
      range: .init(start: .zero, end: .zero)
    )

    XCTAssertEqual(editedSnapshot.text, "actor\n")
    XCTAssertEqual(highlights.first?.capture, "keyword")
    XCTAssertEqual(folds.count, 1)
    XCTAssertEqual(hover?.markdown, "hover")
    XCTAssertEqual(definitions.count, 1)
    XCTAssertEqual(references.count, 1)
    XCTAssertEqual(formatting.first?.replacement, "formatted")
    XCTAssertEqual(rangeFormatting.first?.replacement, "range")
    XCTAssertNotNil(renamePreparation)
    XCTAssertEqual(rename?.documentEdits.first?.edits.first?.replacement, "item")
    XCTAssertEqual(semantic.first?.tokenType, "type")
    XCTAssertEqual(signature?.signatures.first?.label, "call(_:) -> Void")
    XCTAssertEqual(symbols.first?.kind, .struct)
    XCTAssertEqual(actions.first?.command?.arguments, [.string("swift")])
    XCTAssertEqual(hints.first?.label, ": Int")

    try await backend.saveDocument(at: uri)
    let saveCount = await language.saveCount
    XCTAssertEqual(saveCount, 1)

    _ = try await backend.replaceText(in: uri, with: "let value = 1")
    let replacedSnapshot = try await backend.snapshot(of: uri)
    XCTAssertEqual(replacedSnapshot.text, "let value = 1")
    try await backend.shutdown()
    let shutdownCount = await shutdown.count
    let remainingDocuments = await backend.openDocumentURLs()
    XCTAssertEqual(shutdownCount, 1)
    XCTAssertTrue(remainingDocuments.isEmpty)
  }

  func testEditWaitsForDocumentThatIsStillOpening() async throws {
    let started = BackendTestGate()
    let release = BackendTestGate()
    let language = BackendLanguageStub(openStarted: started, openRelease: release)
    let backend = SwiftEditorBackend(
      workspaceURL: URL(fileURLWithPath: "/tmp"),
      languageService: language
    )
    let document = URL(fileURLWithPath: "/tmp/opening.rs")
    let openTask = Task {
      try await backend.openDocument(at: document, text: "fn main() {}", languageID: "rust")
    }
    await started.wait()

    let editTask = Task {
      try await backend.apply(
        TextEdit(range: .init(start: .zero, end: .zero), replacement: "pub "),
        to: document
      )
    }
    await release.signal()
    try await openTask.value
    let applied = try await editTask.value

    XCTAssertEqual(applied.newSnapshot.text, "pub fn main() {}")
    try await backend.shutdown()
  }

  func testDocumentLookupNormalizesFileURLs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let canonical = root.appendingPathComponent("main.rs")
    let equivalent = root.appendingPathComponent("nested/../main.rs")
    let backend = SwiftEditorBackend(workspaceURL: root)

    try await backend.openDocument(at: canonical, text: "fn main() {}", languageID: "rust")
    _ = try await backend.apply(
      TextEdit(range: .init(start: .zero, end: .zero), replacement: "pub "),
      to: equivalent
    )

    let normalizedText = try await backend.text(of: canonical)
    XCTAssertEqual(normalizedText, "pub fn main() {}")
    try await backend.shutdown()
  }

  func testAutomaticCompletionAvoidsLanguageServiceUntilExplicitlyRequested() async throws {
    let language = BackendLanguageStub()
    let backend = SwiftEditorBackend(
      workspaceURL: URL(fileURLWithPath: "/tmp"),
      languageService: language,
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    try await backend.openDocument(at: uri, text: "act")

    let automatic = try await backend.completions(
      in: uri,
      at: .init(line: 0, utf16Column: 3),
      invocation: .automatic
    )
    XCTAssertTrue(automatic.contains { $0.label == "actor" })
    let automaticRequestCount = await language.completionCount
    XCTAssertEqual(automaticRequestCount, 0)

    let explicit = try await backend.completions(
      in: uri,
      at: .init(line: 0, utf16Column: 3),
      invocation: .explicit
    )
    XCTAssertTrue(explicit.contains { $0.label == "actual" })
    let explicitRequestCount = await language.completionCount
    XCTAssertEqual(explicitRequestCount, 1)
    try await backend.shutdown()
  }

  func testRustContextCompletionIncludesSnippetTabStops() async throws {
    let file = URL(fileURLWithPath: "/tmp/main.rs")
    let backend = SwiftEditorBackend(
      workspaceURL: URL(fileURLWithPath: "/tmp"),
      languageID: "rust",
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    try await backend.openDocument(at: file, text: "f")
    let values = try await backend.completions(
      in: file,
      at: .init(line: 0, utf16Column: 1),
      invocation: .automatic
    )
    let completion = try XCTUnwrap(values.first { $0.label == "fn" })
    XCTAssertEqual(completion.kind, .snippet)
    XCTAssertEqual(completion.insertTextFormat, .snippet)

    let result = try await backend.applyCompletion(
      completion,
      in: file,
      at: .init(line: 0, utf16Column: 1)
    )
    XCTAssertTrue(result.snapshot.text.hasPrefix("fn name("))
    XCTAssertGreaterThanOrEqual(result.tabStops.count, 2)
    try await backend.shutdown()
  }

  func testKeywordFallbackWhenLanguageServerFails() async throws {
    let language = BackendLanguageStub()
    await language.setCompletionFailure(true)
    let backend = SwiftEditorBackend(
      workspaceURL: URL(fileURLWithPath: "/tmp"),
      languageService: language,
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    try await backend.openDocument(at: uri, text: "act")
    let values = try await backend.completions(in: uri, at: .init(line: 0, utf16Column: 3))
    XCTAssertEqual(values.first?.label, "actor")
  }

  func testContextualCompletionUsesCurrentDocumentAndRustWorkspaceSymbols() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let main = root.appendingPathComponent("main.rs")
    let library = root.appendingPathComponent("library.rs")
    try "fn calculate_local() {}\nfn main() { cal }\n".write(
      to: main, atomically: true, encoding: .utf8)
    try "pub fn calculate_workspace() {}\n".write(
      to: library, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      languageID: "rust",
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    _ = try await backend.scanSourceWorkspace()
    try await backend.openFile(at: main)

    let values = try await backend.completions(
      in: main,
      at: .init(line: 1, utf16Column: 15)
    )

    XCTAssertEqual(values.first?.label, "calculate_local")
    XCTAssertTrue(
      values.first(where: { $0.label == "calculate_workspace" })?.detail?
        .hasPrefix("Project • library.rs") == true
    )
    XCTAssertTrue(values.allSatisfy { $0.serviceIdentifier == "editor-context" })
    try await backend.shutdown()
  }

  func testContextualCompletionSupportsMemberTriggersWithoutLanguageServer() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("main.rs")
    let text = "fn calculate_total() -> i32 { 42 }\nfn main() { value. }\n"
    try text.write(to: file, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      languageID: "rust",
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    _ = try await backend.scanSourceWorkspace()
    try await backend.openFile(at: file)

    let values = try await backend.completions(
      in: file,
      at: .init(line: 1, utf16Column: 18),
      triggerCharacter: "."
    )

    XCTAssertTrue(values.contains { $0.label == "calculate_total" })
    try await backend.shutdown()
  }

  func testContextualCompletionIgnoresIdentifiersInsideCommentsAndStrings() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("main.rs")
    let text =
      "// calculate_comment\nconst MESSAGE: &str = \"calculate_string\";\nfn calculate_live() {}\nfn main() { cal }\n"
    try text.write(to: file, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      languageID: "rust",
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    _ = try await backend.scanSourceWorkspace()
    try await backend.openFile(at: file)

    let values = try await backend.completions(
      in: file,
      at: .init(line: 3, utf16Column: 15)
    )

    XCTAssertTrue(values.contains { $0.label == "calculate_live" })
    XCTAssertFalse(values.contains { $0.label == "calculate_comment" })
    XCTAssertFalse(values.contains { $0.label == "calculate_string" })
    try await backend.shutdown()
  }

  func testDiagnosticsAreExposedDirectly() async throws {
    let language = BackendLanguageStub()
    let backend = SwiftEditorBackend(
      workspaceURL: URL(fileURLWithPath: "/tmp"), languageService: language)
    let task = Task<DiagnosticBatch?, Never> {
      for await batch in backend.diagnostics { return batch }
      return nil
    }
    let batch = DiagnosticBatch(
      uri: uri,
      version: 0,
      diagnostics: [
        .init(range: .init(start: .zero, end: .zero), message: "problem", severity: .warning)
      ]
    )
    await language.emit(batch)
    let received = await task.value
    XCTAssertEqual(received, batch)
  }

  func testUnifiedDebuggerWorkflow() async throws {
    let adapter = BackendAutoAdapter()
    let session = DAPSession { try await adapter.write($0) }
    await adapter.attach(session)
    let backend = SwiftEditorBackend(workspaceURL: URL(fileURLWithPath: "/tmp"))

    _ = try await backend.startDebugger(session: session)
    try await backend.launchDebugger(arguments: ["program": "/tmp/program"])
    try await backend.finishDebuggerConfiguration()
    let state = try await backend.debugState()
    let breakpoints = try await backend.setBreakpoints(in: uri, breakpoints: [.init(line: 3)])
    let threads = try await backend.debugThreads()
    let stack = try await backend.stackTrace(threadID: 7)
    let scopes = try await backend.scopes(frameID: 11)
    let variables = try await backend.variables(reference: 4)
    let evaluation = try await backend.evaluate("value", frameID: 11)
    let functionBreakpoints = try await backend.setFunctionBreakpoints([.init(name: "main")])
    try await backend.setExceptionBreakpoints(["swift_error"])
    let changedVariable = try await backend.setVariable(reference: 4, name: "value", value: "43")
    let exception = try await backend.exceptionInfo(threadID: 7)
    let source = try await backend.debugSource(reference: 1)
    let modules = try await backend.debugModules()
    let sources = try await backend.loadedDebugSources()
    let raw = try await backend.rawDebugRequest(command: "custom/request")

    XCTAssertEqual(state, .running)
    XCTAssertEqual(breakpoints.first?.verified, true)
    XCTAssertEqual(functionBreakpoints.first?.verified, true)
    XCTAssertEqual(threads, [DAPThread(id: 7, name: "main")])
    XCTAssertEqual(stack.stackFrames.first?.id, 11)
    XCTAssertEqual(scopes.first?.variablesReference, 4)
    XCTAssertEqual(variables.first?.value, "42")
    XCTAssertEqual(evaluation.result, "42")
    XCTAssertEqual(changedVariable.value, "43")
    XCTAssertEqual(exception.exceptionId, "E")
    XCTAssertEqual(source.content, "let value = 42")
    XCTAssertEqual(modules.modules.first?.name, "App")
    XCTAssertEqual(sources.first?.name, "Backend.swift")
    if case .object(let rawBody) = raw.body {
      XCTAssertEqual(rawBody["ok"], true)
    } else {
      XCTFail("Expected object body")
    }

    try await session.receive(
      try DAPFramer.frame(DAPEvent(seq: 500, event: "stopped", body: ["reason": "breakpoint"])))
    try await Task.sleep(for: .milliseconds(10))
    let continuation = try await backend.continueExecution(threadID: 7)
    XCTAssertEqual(continuation.allThreadsContinued, true)

    try await session.receive(
      try DAPFramer.frame(DAPEvent(seq: 501, event: "stopped", body: ["reason": "step"])))
    try await Task.sleep(for: .milliseconds(10))
    try await backend.stepBack(threadID: 7)
    try await session.receive(
      try DAPFramer.frame(DAPEvent(seq: 502, event: "stopped", body: ["reason": "step"])))
    try await Task.sleep(for: .milliseconds(10))
    try await backend.reverseContinue(threadID: 7)
    try await session.receive(
      try DAPFramer.frame(DAPEvent(seq: 503, event: "stopped", body: ["reason": "step"])))
    try await Task.sleep(for: .milliseconds(10))
    try await backend.restartFrame(11)
    try await backend.restartDebugger()
    try await backend.terminateDebugger()
    try await backend.disconnectDebugger()
    do {
      _ = try await backend.debugState()
      XCTFail("Expected debuggerNotRunning")
    } catch {
      XCTAssertEqual(error as? SwiftEditorBackendError, .debuggerNotRunning)
    }
  }

  func testApplyWorkspaceEditAcrossDocuments() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let a = root.appendingPathComponent("A.swift")
    let b = root.appendingPathComponent("B.swift")
    let created = root.appendingPathComponent("Generated.swift")
    let backend = SwiftEditorBackend(
      workspaceURL: root,
      languageService: BackendLanguageStub()
    )
    try await backend.openDocument(at: a, text: "let a = 1")
    try await backend.openDocument(at: b, text: "let b = 2")

    let result = try await backend.applyWorkspaceEdit(
      .init(
        documentEdits: [
          .init(
            uri: b, version: 0,
            edits: [
              .init(
                range: .init(
                  start: .init(line: 0, utf16Column: 8), end: .init(line: 0, utf16Column: 9)),
                replacement: "20"
              )
            ]),
          .init(
            uri: a, version: 0,
            edits: [
              .init(
                range: .init(
                  start: .init(line: 0, utf16Column: 8), end: .init(line: 0, utf16Column: 9)),
                replacement: "10"
              )
            ]),
        ],
        fileOperations: [.create(uri: created, overwrite: false, ignoreIfExists: true)]
      ))

    let aSnapshot = try await backend.snapshot(of: a)
    let bSnapshot = try await backend.snapshot(of: b)
    XCTAssertEqual(aSnapshot.text, "let a = 10")
    XCTAssertEqual(bSnapshot.text, "let b = 20")
    XCTAssertEqual(result.appliedDocuments, [b, a])
    XCTAssertTrue(result.openedDocuments.isEmpty)
    XCTAssertEqual(
      result.pendingFileOperations, [.create(uri: created, overwrite: false, ignoreIfExists: true)])
  }

  func testWorkspaceEditPreservesSequentialEditsForSameDocument() async throws {
    let backend = SwiftEditorBackend(
      workspaceURL: URL(fileURLWithPath: "/tmp"),
      languageService: BackendLanguageStub()
    )
    try await backend.openDocument(at: uri, text: "ab")

    let result = try await backend.applyWorkspaceEdit(
      .init(documentEdits: [
        .init(
          uri: uri, version: 0,
          edits: [
            .init(
              range: .init(
                start: .init(line: 0, utf16Column: 1), end: .init(line: 0, utf16Column: 2)),
              replacement: "B"
            )
          ]),
        .init(
          uri: uri, version: 1,
          edits: [
            .init(
              range: .init(
                start: .init(line: 0, utf16Column: 2), end: .init(line: 0, utf16Column: 2)),
              replacement: "!"
            )
          ]),
      ]))

    let snapshot = try await backend.snapshot(of: uri)
    XCTAssertEqual(snapshot.text, "aB!")
    XCTAssertEqual(snapshot.version, 2)
    XCTAssertEqual(result.appliedDocuments, [uri])
  }

  func testWorkspaceEditVersionMismatchDoesNotMutate() async throws {
    let backend = SwiftEditorBackend(
      workspaceURL: URL(fileURLWithPath: "/tmp"),
      languageService: BackendLanguageStub()
    )
    try await backend.openDocument(at: uri, text: "let value = 1")

    do {
      _ = try await backend.applyWorkspaceEdit(
        .init(documentEdits: [
          .init(
            uri: uri, version: 9,
            edits: [
              .init(
                range: .init(start: .zero, end: .zero),
                replacement: "// changed\n"
              )
            ])
        ]))
      XCTFail("Expected version mismatch")
    } catch {
      XCTAssertEqual(
        error as? SwiftEditorBackendError,
        .workspaceVersionMismatch(uri, expected: 9, actual: 0)
      )
    }

    let unchanged = try await backend.snapshot(of: uri)
    XCTAssertEqual(unchanged.text, "let value = 1")
  }

  func testWorkspaceEditOpensMissingUTF8File() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Missing.swift")
    try Data("let value = 1".utf8).write(to: file)

    let backend = SwiftEditorBackend(workspaceURL: root, languageService: BackendLanguageStub())
    let result = try await backend.applyWorkspaceEdit(
      .init(documentEdits: [
        .init(
          uri: file,
          edits: [
            .init(
              range: .init(
                start: .init(line: 0, utf16Column: 12), end: .init(line: 0, utf16Column: 13)),
              replacement: "2"
            )
          ])
      ]), openMissingFiles: true)

    let openURLs = await backend.openDocumentURLs()
    let openedSnapshot = try await backend.snapshot(of: file)
    XCTAssertEqual(result.openedDocuments, [file])
    XCTAssertEqual(openURLs, [file])
    XCTAssertEqual(openedSnapshot.text, "let value = 2")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 1")
  }

  func testWorkspaceEditRollsBackEarlierDocuments() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("A.swift")
    let b = root.appendingPathComponent("B.swift")
    let language = BackendLanguageStub()
    let backend = SwiftEditorBackend(workspaceURL: root, languageService: language)
    try await backend.openDocument(at: a, text: "let a = 1")
    try await backend.openDocument(at: b, text: "let b = 2")
    await language.setChangeFailure(true, for: b)

    do {
      _ = try await backend.applyWorkspaceEdit(
        .init(documentEdits: [
          .init(
            uri: a,
            edits: [
              .init(
                range: .init(
                  start: .init(line: 0, utf16Column: 8), end: .init(line: 0, utf16Column: 9)),
                replacement: "10"
              )
            ]),
          .init(
            uri: b,
            edits: [
              .init(
                range: .init(
                  start: .init(line: 0, utf16Column: 8), end: .init(line: 0, utf16Column: 9)),
                replacement: "20"
              )
            ]),
        ]))
      XCTFail("Expected change failure")
    } catch {
      XCTAssertTrue(error is BackendTestError)
    }

    let rolledBackA = try await backend.snapshot(of: a)
    let rolledBackB = try await backend.snapshot(of: b)
    XCTAssertEqual(rolledBackA.text, "let a = 1")
    XCTAssertEqual(rolledBackA.version, 0)
    XCTAssertEqual(rolledBackB.text, "let b = 2")
    XCTAssertEqual(rolledBackB.version, 0)
  }

  func testFileOpenPersistAndShutdownGuard() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("File.swift")
    try Data("let old = 1".utf8).write(to: file)

    let language = BackendLanguageStub()
    let backend = SwiftEditorBackend(workspaceURL: directory, languageService: language)
    try await backend.openFile(at: file)
    let opened = try await backend.snapshot(of: file)
    XCTAssertEqual(opened.text, "let old = 1")

    _ = try await backend.replaceText(in: file, with: "let new = 2")
    try await backend.persistDocument(at: file)
    let persisted = try String(contentsOf: file, encoding: .utf8)
    let saveCount = await language.saveCount
    XCTAssertEqual(persisted, "let new = 2")
    XCTAssertEqual(saveCount, 1)

    try await backend.shutdown()
    do {
      try await backend.openDocument(at: directory.appendingPathComponent("After.swift"))
      XCTFail("Expected shutdown guard")
    } catch {
      XCTAssertEqual(error as? SwiftEditorBackendError, .shutdown)
    }
  }

  func testDebuggerEventsAreRepublished() async throws {
    let adapter = BackendAutoAdapter()
    let session = DAPSession { try await adapter.write($0) }
    await adapter.attach(session)
    let backend = SwiftEditorBackend(workspaceURL: URL(fileURLWithPath: "/tmp"))
    _ = try await backend.startDebugger(session: session)

    let eventTask = Task<DAPEvent?, Never> {
      for await event in backend.debugEvents { return event }
      return nil
    }
    let stopped = DAPEvent(seq: 900, event: "stopped", body: ["reason": "breakpoint"])
    try await session.receive(try DAPFramer.frame(stopped))
    let received = await eventTask.value
    try await Task.sleep(for: .milliseconds(10))
    let state = try await backend.debugState()

    XCTAssertEqual(received, stopped)
    XCTAssertEqual(state, .stopped(reason: "breakpoint"))
    try await backend.disconnectDebugger()
  }

  #if os(macOS) || os(Linux)
    func testConvenienceFactoryBuildsCompleteLocalSwiftBackend() async throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try
        "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Smoke\", targets: [.executableTarget(name: \"Smoke\")])\n"
        .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
      let sources = root.appendingPathComponent("Sources/Smoke", isDirectory: true)
      try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
      let file = sources.appendingPathComponent("main.swift")
      let text = "struct Example {}\npri"
      try text.write(to: file, atomically: true, encoding: .utf8)

      let backend = try await SwiftEditorBackend.makeSwift(workspaceURL: root)
      try await backend.openFile(at: file)
      let highlights = try await backend.highlights(in: file)
      let completions = try await backend.completions(
        in: file,
        at: .init(line: 1, utf16Column: 3)
      )

      XCTAssertTrue(highlights.contains { $0.capture == "keyword" })
      XCTAssertFalse(completions.isEmpty)
      try await backend.shutdown()
    }

    func testStandardFactoryWithoutLSPUsesRealTreeSitter() async throws {
      var configuration = SwiftEditorBackendConfiguration(
        workspaceURL: URL(fileURLWithPath: "/tmp"))
      configuration.enableLanguageServer = false
      let backend = try await SwiftEditorBackend.makeSwift(configuration: configuration)
      let router = try XCTUnwrap(backend.languageServiceRouter)
      let supplemental = BackendLanguageStub()
      try await router.register(
        .init(
          id: "runtime-plugin",
          service: supplemental,
          role: .supplemental,
          selector: .init(languageIDs: ["swift"])
        )
      )
      try await backend.openDocument(at: uri, text: "struct Example { let value = 1 }")
      let highlights = try await backend.highlights(in: uri)
      let completions = try await backend.completions(in: uri, at: .zero)
      XCTAssertTrue(highlights.contains { $0.capture == "keyword" })
      XCTAssertTrue(completions.contains { $0.label == "actual" })
      try await backend.shutdown()
    }
  #endif

  func testBackendErrorsHaveActionableLocalizedDescriptions() {
    let conflict = SwiftEditorBackendError.workspaceVersionConflict(uri, 2, 3)
    let mismatch = SwiftEditorBackendError.workspaceVersionMismatch(uri, expected: 4, actual: 5)
    let rollback = SwiftEditorBackendError.workspaceRollbackFailed(
      primary: "change rejected",
      documents: [uri]
    )

    XCTAssertTrue(conflict.localizedDescription.contains("2"))
    XCTAssertTrue(conflict.localizedDescription.contains("3"))
    XCTAssertTrue(mismatch.localizedDescription.contains("4"))
    XCTAssertTrue(mismatch.localizedDescription.contains("5"))
    XCTAssertTrue(rollback.localizedDescription.contains("change rejected"))
    XCTAssertTrue(rollback.localizedDescription.contains(uri.path))
    XCTAssertFalse(SwiftEditorBackendError.shutdown.localizedDescription.isEmpty)
  }

  func testNativeUTF16EditAndDocumentConvenienceAccessors() async throws {
    let backend = SwiftEditorBackend(workspaceURL: URL(fileURLWithPath: "/tmp"))
    try await backend.openDocument(at: uri, text: "a😀b")

    let initiallyOpen = await backend.isDocumentOpen(at: uri)
    XCTAssertTrue(initiallyOpen)
    _ = try await backend.applyUTF16Edit(
      NSRange(location: 1, length: 2),
      replacement: "X",
      to: uri
    )
    let editedText = try await backend.text(of: uri)
    XCTAssertEqual(editedText, "aXb")

    do {
      _ = try await backend.applyUTF16Edit(
        NSRange(location: NSNotFound, length: 1),
        replacement: "bad",
        to: uri
      )
      XCTFail("Expected invalid UTF-16 range")
    } catch let error as TextBufferError {
      XCTAssertEqual(error, .invalidUTF16Offset(NSNotFound))
    }

    try await backend.closeDocument(at: uri)
    let finallyOpen = await backend.isDocumentOpen(at: uri)
    XCTAssertFalse(finallyOpen)
  }

  func testAutomaticServerWorkspaceEditHandlerAppliesTextEditsAndDeclinesFileOperations()
    async throws
  {
    let backend = SwiftEditorBackend(workspaceURL: URL(fileURLWithPath: "/tmp"))
    try await backend.openDocument(at: uri, text: "let x = 1")
    let handler = SwiftEditorBackend.automaticWorkspaceEditHandler(for: backend)
    let textEdit = EditorWorkspaceEdit(
      documentEdits: [
        WorkspaceDocumentEdit(
          uri: uri,
          edits: [
            TextEdit(
              range: TextRange(
                start: TextPosition(line: 0, utf16Column: 4),
                end: TextPosition(line: 0, utf16Column: 5)
              ),
              replacement: "value"
            )
          ]
        )
      ]
    )

    let applied = try await handler(textEdit, "Rename")
    XCTAssertTrue(applied)
    let updated = try await backend.text(of: uri)
    XCTAssertEqual(updated, "let value = 1")

    let declined = try await handler(
      EditorWorkspaceEdit(
        fileOperations: [
          .create(uri: URL(fileURLWithPath: "/tmp/New.swift"), overwrite: nil, ignoreIfExists: nil)
        ]
      ),
      "Create file"
    )
    XCTAssertFalse(declined)
    try await backend.shutdown()
  }

  func testHeaderImportCompletionPrefersWorkspaceHeaderFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let main = root.appendingPathComponent("main.cpp")
    let header = root.appendingPathComponent("Widget.hpp")
    let implementation = root.appendingPathComponent("Widget.cpp")
    try "#include \"Wi".write(to: main, atomically: true, encoding: .utf8)
    try "class Widget {};".write(to: header, atomically: true, encoding: .utf8)
    try "void work() {}".write(to: implementation, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      languageID: "cpp",
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    _ = try await backend.scanSourceWorkspace()
    try await backend.openFile(at: main)
    let snapshot = try await backend.snapshot(of: main)
    let values = try await backend.completions(
      in: main,
      at: try snapshot.position(atUTF16Offset: snapshot.utf16Count),
      invocation: .automatic
    )

    XCTAssertEqual(values.first?.label, "Widget.hpp")
    XCTAssertEqual(values.first?.kind, .file)
    try await backend.shutdown()
  }

  func testCPlusPlusMemberCompletionUsesHeaderOwnership() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let main = root.appendingPathComponent("main.cpp")
    let serviceHeader = root.appendingPathComponent("Service.hpp")
    let otherHeader = root.appendingPathComponent("Other.hpp")
    try "Service service;\nservice.re".write(to: main, atomically: true, encoding: .utf8)
    try "class Service { public: void reload(); };".write(
      to: serviceHeader, atomically: true, encoding: .utf8)
    try "class Other { public: void reset(); };".write(
      to: otherHeader, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      languageID: "cpp",
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    _ = try await backend.scanSourceWorkspace()
    try await backend.openFile(at: main)
    let snapshot = try await backend.snapshot(of: main)
    let values = try await backend.completions(
      in: main,
      at: try snapshot.position(atUTF16Offset: snapshot.utf16Count),
      invocation: .automatic
    )

    XCTAssertEqual(values.first?.label, "reload")
    XCTAssertTrue(values.contains { $0.label == "reset" })
    try await backend.shutdown()
  }

  func testCPlusPlusTypeReceiverPrefersStaticHeaderMember() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let main = root.appendingPathComponent("main.cpp")
    let header = root.appendingPathComponent("Service.hpp")
    try "Service::ma".write(to: main, atomically: true, encoding: .utf8)
    try "class Service { public: static Service make(); void mapValues(); };".write(
      to: header, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      languageID: "cpp",
      completionStrategy: .mergeKeywordsAndFallbackOnError
    )
    _ = try await backend.scanSourceWorkspace()
    try await backend.openFile(at: main)
    let snapshot = try await backend.snapshot(of: main)
    let values = try await backend.completions(
      in: main,
      at: try snapshot.position(atUTF16Offset: snapshot.utf16Count),
      invocation: .automatic
    )

    XCTAssertEqual(values.first?.label, "make")
    try await backend.shutdown()
  }

}
