import XCTest

@testable import EditorServices

private actor BuilderLanguageStub: LanguageIntelligenceProviding {
  nonisolated let diagnostics: AsyncStream<DiagnosticBatch> = AsyncStream { $0.finish() }
  private(set) var opened: [URL: TextSnapshot] = [:]
  private(set) var closed: [URL] = []
  private let completionLabel: String

  init(completionLabel: String = "builder") {
    self.completionLabel = completionLabel
  }

  func open(uri: URL, languageID: String, snapshot: TextSnapshot) { opened[uri] = snapshot }
  func change(uri: URL, change: AppliedTextEdit) { opened[uri] = change.newSnapshot }
  func save(uri: URL, snapshot: TextSnapshot) {}
  func completions(uri: URL, at position: TextPosition, triggerCharacter: String?) -> [Completion] {
    [Completion(label: completionLabel)]
  }
  func hover(uri: URL, at position: TextPosition) -> HoverResult? { nil }
  func definitions(uri: URL, at position: TextPosition) -> [SourceLocation] { [] }
  func close(uri: URL) {
    opened.removeValue(forKey: uri)
    closed.append(uri)
  }
}

private actor BuilderShutdownRecorder {
  private(set) var count = 0
  func record() { count += 1 }
}

final class EditorBackendBuilderTests: XCTestCase {
  func testBuilderComposesRouterAndBackend() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let language = BuilderLanguageStub()
    let builder = EditorBackendBuilder(
      workspaceURL: root,
      completionStrategy: .languageServerOnly
    ).addingLanguageService(
      .init(
        id: "swift",
        service: language,
        selector: .init(languageIDs: ["swift"], fileExtensions: ["swift"])
      )
    )

    let backend = try await builder.build()
    let uri = root.appendingPathComponent("Main.swift")
    let session = try await backend.openDocumentSession(at: uri, text: "let value = 1")

    XCTAssertNotNil(backend.languageServiceRouter)
    let registrations = await backend.languageServiceRouter?.registrations()
    XCTAssertEqual(registrations?.map(\.id), ["swift"])
    let completions = try await session.completions(at: .zero)
    XCTAssertEqual(completions.map(\.label), ["builder"])
    XCTAssertEqual(completions.first?.serviceIdentifier, "swift")
    try await backend.shutdown()
  }

  func testBackendExposesRouterForLiveRegistration() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let primary = BuilderLanguageStub()
    let late = BuilderLanguageStub()
    let backend = try await EditorBackendBuilder(workspaceURL: root)
      .addingLanguageService(.init(id: "primary", service: primary))
      .build()
    let uri = root.appendingPathComponent("Main.swift")
    _ = try await backend.openDocumentSession(at: uri, text: "")
    let router = try XCTUnwrap(backend.languageServiceRouter)

    try await router.register(.init(id: "late", service: late, role: .supplemental))

    let bound = try await router.boundServiceIDs(for: uri)
    XCTAssertEqual(bound, ["primary", "late"])
    let lateSnapshot = await late.opened[uri]
    XCTAssertEqual(lateSnapshot?.text, "")
    try await backend.shutdown()
  }

  func testBackendShutdownRunsRegisteredServiceShutdownOnce() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let language = BuilderLanguageStub()
    let recorder = BuilderShutdownRecorder()
    let backend = try await EditorBackendBuilder(workspaceURL: root)
      .addingLanguageService(
        .init(id: "service", service: language, shutdown: { await recorder.record() })
      )
      .build()

    try await backend.shutdown()

    let count = await recorder.count
    XCTAssertEqual(count, 1)
  }

  func testPerDocumentLanguageIDsSelectDifferentServices() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let swift = BuilderLanguageStub(completionLabel: "swift-result")
    let markdown = BuilderLanguageStub(completionLabel: "markdown-result")
    let backend = try await EditorBackendBuilder(
      workspaceURL: root,
      completionStrategy: .languageServerOnly
    )
    .addingLanguageService(
      .init(
        id: "swift",
        service: swift,
        selector: .init(languageIDs: ["swift"], fileExtensions: ["swift"])
      )
    )
    .addingLanguageService(
      .init(
        id: "markdown",
        service: markdown,
        selector: .init(languageIDs: ["markdown"], fileExtensions: ["md"])
      )
    )
    .build()

    let swiftSession = try await backend.openDocumentSession(
      at: root.appendingPathComponent("Main.swift"),
      text: "let value = 1",
      languageID: "swift"
    )
    let markdownSession = try await backend.openDocumentSession(
      at: root.appendingPathComponent("README.md"),
      text: "# Title",
      languageID: "markdown"
    )

    XCTAssertEqual(swiftSession.languageID, "swift")
    XCTAssertEqual(markdownSession.languageID, "markdown")
    let swiftCompletions = try await swiftSession.completions(at: .zero)
    let markdownCompletions = try await markdownSession.completions(at: .zero)
    XCTAssertEqual(swiftCompletions.map(\.label), ["swift-result"])
    XCTAssertEqual(markdownCompletions.map(\.label), ["markdown-result"])
    let swiftOpenedMarkdown = await swift.opened[markdownSession.uri]
    let markdownOpenedSwift = await markdown.opened[swiftSession.uri]
    XCTAssertNil(swiftOpenedMarkdown)
    XCTAssertNil(markdownOpenedSwift)
    try await backend.shutdown()
  }

  func testSourceWorkspaceLanguageSurvivesOpenAndMove() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let markdown = BuilderLanguageStub(completionLabel: "markdown-result")
    let backend = try await EditorBackendBuilder(
      workspaceURL: root,
      completionStrategy: .languageServerOnly
    )
    .addingLanguageService(
      .init(
        id: "markdown",
        service: markdown,
        selector: .init(languageIDs: ["markdown"], fileExtensions: ["md"])
      )
    )
    .build()

    let created = try await backend.createSourceFile(
      at: "README.md",
      content: "# Package",
      persistImmediately: true,
      openInEditor: true
    )
    XCTAssertEqual(created.languageID, "markdown")
    let openedLanguageID = try await backend.documentLanguageID(at: created.url)
    XCTAssertEqual(openedLanguageID, "markdown")

    let moved = try await backend.moveSourceFile(created.id, to: "Docs/Guide.md")
    XCTAssertEqual(moved.languageID, "markdown")
    let movedSession = try await backend.documentSession(at: moved.url)
    XCTAssertEqual(movedSession.languageID, "markdown")
    let completions = try await movedSession.completions(at: .zero)
    XCTAssertEqual(completions.map(\.label), ["markdown-result"])
    try await backend.shutdown()
  }

  func testBuilderWithoutInitialServicesStillExposesLiveRouter() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let backend = try await EditorBackendBuilder(
      workspaceURL: root,
      scanSourceWorkspaceOnConstruction: false
    ).build()

    let router = try XCTUnwrap(backend.languageServiceRouter)
    let initialRegistrations = await router.registrations()
    XCTAssertTrue(initialRegistrations.isEmpty)
    let late = BuilderLanguageStub(completionLabel: "late")
    try await router.register(.init(id: "late", service: late))
    let lateRegistrations = await router.registrations()
    XCTAssertEqual(lateRegistrations.map(\.id), ["late"])
    try await backend.shutdown()
  }

  func testNonDefaultLanguageSurvivesEditsCompletionSearchAndPersistence() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let markdown = BuilderLanguageStub(completionLabel: "heading")
    let backend = try await EditorBackendBuilder(
      workspaceURL: root,
      languageID: "swift",
      completionStrategy: .languageServerOnly
    )
    .addingLanguageService(
      .init(
        id: "markdown",
        service: markdown,
        selector: .init(languageIDs: ["markdown"], fileExtensions: ["md"])
      )
    )
    .build()

    let created = try await backend.createSourceFile(
      at: "README.md",
      content: "# A\n",
      languageID: "markdown",
      persistImmediately: false,
      openInEditor: true
    )
    let session = try await backend.documentSession(at: created.url)
    _ = try await session.apply(
      .init(
        range: .init(
          start: .init(line: 0, utf16Column: 2),
          end: .init(line: 0, utf16Column: 3)
        ),
        replacement: "Title"
      )
    )
    _ = try await session.apply([
      .init(
        range: .init(start: .init(line: 1, utf16Column: 0), end: .init(line: 1, utf16Column: 0)),
        replacement: "Body\n"
      )
    ])

    let completions = try await session.completions(at: .init(line: 1, utf16Column: 4))
    _ = try await session.applyCompletion(completions[0], at: .init(line: 1, utf16Column: 4))
    _ = try await backend.previewSourceReplacement(.literal("Title"), with: "Heading")
    try await session.persist()

    let stored = try await backend.sourceFile(id: created.id)
    let documentLanguageID = try await backend.documentLanguageID(at: created.url)
    XCTAssertEqual(stored.languageID, "markdown")
    XCTAssertEqual(documentLanguageID, "markdown")
    XCTAssertTrue(stored.content.contains("heading"))
    try await backend.shutdown()
  }


  func testBackendShutdownCoalescesAndRejectsNewWorkWhileInProgress() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let language = BuilderLanguageStub()
    let recorder = BuilderShutdownRecorder()
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let backend = try await EditorBackendBuilder(
      workspaceURL: root,
      scanSourceWorkspaceOnConstruction: false
    )
    .addingLanguageService(
      .init(
        id: "service",
        service: language,
        shutdown: {
          await recorder.record()
          startedContinuation.yield(())
          startedContinuation.finish()
          try await Task.sleep(for: .milliseconds(50))
        }
      )
    )
    .build()
    let original = root.appendingPathComponent("Original.swift")
    try await backend.openDocument(at: original, text: "")

    let first = Task { try await backend.shutdown() }
    for await _ in started { break }

    do {
      try await backend.openDocument(
        at: root.appendingPathComponent("Late.swift"), text: "")
      XCTFail("Expected shutdown error")
    } catch let error as SwiftEditorBackendError {
      XCTAssertEqual(error, .shutdown)
    }

    let second = Task { try await backend.shutdown() }
    try await first.value
    try await second.value
    let count = await recorder.count
    XCTAssertEqual(count, 1)
  }

}
