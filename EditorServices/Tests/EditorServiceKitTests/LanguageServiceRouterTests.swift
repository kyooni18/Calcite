import EditorCore
import XCTest

@testable import EditorServiceKit

private enum RouterTestError: Error, Equatable { case expected }

private actor RouterLanguageStub: LanguageIntelligenceProviding {
  nonisolated let diagnostics: AsyncStream<DiagnosticBatch>
  nonisolated let messages: AsyncStream<LanguageServerMessage>
  private let diagnosticContinuation: AsyncStream<DiagnosticBatch>.Continuation
  private let messageContinuation: AsyncStream<LanguageServerMessage>.Continuation

  private(set) var snapshots: [URL: TextSnapshot] = [:]
  private(set) var openCalls: [(URL, String, TextSnapshot)] = []
  private(set) var changeCalls: [(URL, AppliedTextEdit)] = []
  private(set) var closeCalls: [URL] = []
  private(set) var executedCommands: [EditorCommand] = []
  var completionValues: [Completion] = []
  var definitionValues: [SourceLocation] = []
  var codeActionValues: [EditorCodeAction] = []
  var completionError: Error?
  var openError: Error?
  var changeError: Error?
  var saveError: Error?
  var closeError: Error?
  var hoverValue: HoverResult?
  var resolveDetail: String?

  init() {
    (diagnostics, diagnosticContinuation) = AsyncStream.makeStream(of: DiagnosticBatch.self)
    (messages, messageContinuation) = AsyncStream.makeStream(of: LanguageServerMessage.self)
  }

  func open(uri: URL, languageID: String, snapshot: TextSnapshot) throws {
    if let openError { throw openError }
    snapshots[uri] = snapshot
    openCalls.append((uri, languageID, snapshot))
  }

  func change(uri: URL, change: AppliedTextEdit) throws {
    if let changeError { throw changeError }
    snapshots[uri] = change.newSnapshot
    changeCalls.append((uri, change))
  }

  func save(uri: URL, snapshot: TextSnapshot) throws {
    if let saveError { throw saveError }
  }

  func completions(uri: URL, at position: TextPosition, triggerCharacter: String?) throws
    -> [Completion]
  {
    if let completionError { throw completionError }
    return completionValues
  }

  func resolveCompletion(_ completion: Completion) -> Completion {
    var result = completion
    result.detail = resolveDetail
    return result
  }

  func hover(uri: URL, at position: TextPosition) -> HoverResult? { hoverValue }
  func definitions(uri: URL, at position: TextPosition) -> [SourceLocation] { definitionValues }

  func codeActions(
    uri: URL, range: TextRange, diagnostics: [Diagnostic], only: [String]?
  ) -> [EditorCodeAction] { codeActionValues }

  func executeCommand(_ command: EditorCommand) -> EditorJSONValue? {
    executedCommands.append(command)
    return .string(command.command)
  }

  func close(uri: URL) throws {
    if let closeError { throw closeError }
    snapshots.removeValue(forKey: uri)
    closeCalls.append(uri)
  }

  func configureOpenError(_ error: Error?) { openError = error }
  func configureSaveError(_ error: Error?) { saveError = error }

  func configureCompletions(_ values: [Completion], error: Error? = nil) {
    completionValues = values
    completionError = error
  }

  func configureDefinitions(_ values: [SourceLocation]) { definitionValues = values }
  func configureCodeActions(_ values: [EditorCodeAction]) { codeActionValues = values }
  func configureChangeError(_ error: Error?) { changeError = error }
  func configureCloseError(_ error: Error?) { closeError = error }
  func configureHover(_ value: HoverResult?) { hoverValue = value }
  func configureResolveDetail(_ detail: String?) { resolveDetail = detail }

  func emitDiagnostic(_ batch: DiagnosticBatch) { diagnosticContinuation.yield(batch) }
  func emitMessage(_ message: LanguageServerMessage) { messageContinuation.yield(message) }
}

private actor ShutdownRecorder {
  private(set) var ids: [String] = []
  func append(_ id: String) { ids.append(id) }
}

private actor InvocationCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

final class LanguageServiceRouterTests: XCTestCase {
  private let swiftURI = URL(fileURLWithPath: "/tmp/Router/Main.swift")
  private let markdownURI = URL(fileURLWithPath: "/tmp/Router/README.md")

  func testSelectorNormalizesLanguageExtensionAndScheme() {
    let selector = LanguageServiceSelector(
      languageIDs: ["  SWIFT  ", "   "],
      fileExtensions: ["  .SWIFT  ", "."],
      urlSchemes: [" FILE ", ""]
    )

    XCTAssertTrue(selector.matches(uri: swiftURI, languageID: "  swift  "))
    XCTAssertEqual(selector.languageIDs, ["swift"])
    XCTAssertEqual(selector.fileExtensions, ["swift"])
    XCTAssertEqual(selector.urlSchemes, ["file"])
    XCTAssertFalse(selector.matches(uri: markdownURI, languageID: "markdown"))
  }

  func testBindingsAreDeterministicByRolePriorityAndRegistrationOrder() async throws {
    let primaryLow = RouterLanguageStub()
    let supplemental = RouterLanguageStub()
    let primaryHighFirst = RouterLanguageStub()
    let primaryHighSecond = RouterLanguageStub()
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "low", service: primaryLow, priority: 0),
      .init(id: "supplemental", service: supplemental, role: .supplemental, priority: 100),
      .init(id: "high-first", service: primaryHighFirst, priority: 10),
      .init(id: "high-second", service: primaryHighSecond, priority: 10),
    ])

    try await router.open(uri: swiftURI, languageID: "swift", snapshot: .init(text: "", version: 0))

    let bound = try await router.boundServiceIDs(for: swiftURI)
    XCTAssertEqual(bound, ["high-first", "high-second", "low", "supplemental"])
  }

  func testSupplementalOpenFailureDoesNotPreventDocumentOpening() async throws {
    let primary = RouterLanguageStub()
    let supplemental = RouterLanguageStub()
    await supplemental.configureOpenError(RouterTestError.expected)
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "primary", service: primary),
      .init(id: "rust-analyzer", service: supplemental, role: .supplemental),
    ])

    try await router.open(
      uri: swiftURI,
      languageID: "rust",
      snapshot: .init(text: "fn main() {}", version: 0)
    )

    let bound = try await router.boundServiceIDs(for: swiftURI)
    let primarySnapshot = await primary.snapshots[swiftURI]
    let supplementalSnapshot = await supplemental.snapshots[swiftURI]
    XCTAssertEqual(bound, ["primary"])
    XCTAssertNotNil(primarySnapshot)
    XCTAssertNil(supplementalSnapshot)
  }

  func testSupplementalChangeFailureUnbindsOnlyFailingService() async throws {
    let primary = RouterLanguageStub()
    let supplemental = RouterLanguageStub()
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "primary", service: primary),
      .init(id: "rust-analyzer", service: supplemental, role: .supplemental),
    ])
    let old = TextSnapshot(text: "fn main() {}", version: 0)
    try await router.open(uri: swiftURI, languageID: "rust", snapshot: old)
    await supplemental.configureChangeError(RouterTestError.expected)
    var buffer = TextBuffer(text: old.text)
    let edit = try buffer.apply(
      .init(
        range: .init(start: .zero, end: .zero),
        replacement: "pub "
      )
    )

    try await router.change(uri: swiftURI, change: edit)

    let bound = try await router.boundServiceIDs(for: swiftURI)
    let primaryText = await primary.snapshots[swiftURI]?.text
    XCTAssertEqual(bound, ["primary"])
    XCTAssertEqual(primaryText, "pub fn main() {}")
  }

  func testSupplementalSaveFailureDoesNotBlockPersistenceLifecycle() async throws {
    let supplemental = RouterLanguageStub()
    await supplemental.configureSaveError(RouterTestError.expected)
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "rust-analyzer", service: supplemental, role: .supplemental)
    ])
    let snapshot = TextSnapshot(text: "fn main() {}", version: 0)
    try await router.open(uri: swiftURI, languageID: "rust", snapshot: snapshot)

    try await router.save(uri: swiftURI, snapshot: snapshot)
    try await router.close(uri: swiftURI)
  }

  func testRuntimeRegistrationRebindsMatchingOpenDocuments() async throws {
    let initial = RouterLanguageStub()
    let late = RouterLanguageStub()
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "initial", service: initial)
    ])
    let snapshot = TextSnapshot(text: "let value = 1", version: 4)
    try await router.open(uri: swiftURI, languageID: "swift", snapshot: snapshot)

    try await router.register(
      .init(
        id: "late",
        service: late,
        role: .supplemental,
        selector: .init(languageIDs: ["swift"], fileExtensions: ["swift"])
      ))

    let initialBound = try await router.boundServiceIDs(for: swiftURI)
    XCTAssertEqual(initialBound, ["initial", "late"])
    let lateSnapshot = await late.snapshots[swiftURI]
    XCTAssertEqual(lateSnapshot, snapshot)

    try await router.unregister("late", shutDown: false)
    let remainingBound = try await router.boundServiceIDs(for: swiftURI)
    XCTAssertEqual(remainingBound, ["initial"])
    let closeCalls = await late.closeCalls
    XCTAssertEqual(closeCalls, [swiftURI])
  }

  func testRuntimeRegistrationDoesNotBindNonmatchingDocuments() async throws {
    let swift = RouterLanguageStub()
    let markdown = RouterLanguageStub()
    let router = try await LanguageServiceRouter(registrations: [
      .init(
        id: "swift",
        service: swift,
        selector: .init(languageIDs: ["swift"], fileExtensions: ["swift"])
      )
    ])
    try await router.open(
      uri: swiftURI, languageID: "swift", snapshot: .init(text: "", version: 0))
    try await router.register(
      .init(
        id: "markdown",
        service: markdown,
        selector: .init(languageIDs: ["markdown"], fileExtensions: ["md"])
      ))

    let bound = try await router.boundServiceIDs(for: swiftURI)
    XCTAssertEqual(bound, ["swift"])
    let markdownCalls = await markdown.openCalls
    XCTAssertTrue(markdownCalls.isEmpty)
  }

  func testCompletionsMergeDeduplicateAndResolveThroughOriginService() async throws {
    let primary = RouterLanguageStub()
    let supplemental = RouterLanguageStub()
    await primary.configureCompletions([
      Completion(label: "shared", resolutionID: UUID()),
      Completion(label: "primary", command: .init(title: "Run", command: "primary.run")),
    ])
    await supplemental.configureCompletions([
      Completion(label: "shared", resolutionID: UUID()),
      Completion(label: "supplemental", resolutionID: UUID()),
    ])
    await supplemental.configureResolveDetail("resolved by supplemental")
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "primary", service: primary),
      .init(id: "supplemental", service: supplemental, role: .supplemental),
    ])
    try await router.open(
      uri: swiftURI, languageID: "swift", snapshot: .init(text: "", version: 0))

    let values = try await router.completions(uri: swiftURI, at: .zero, triggerCharacter: nil)

    XCTAssertEqual(values.map(\.label), ["shared", "primary", "supplemental"])
    XCTAssertEqual(values.map(\.serviceIdentifier), ["primary", "primary", "supplemental"])
    XCTAssertEqual(values[1].command?.serviceIdentifier, "primary")
    XCTAssertNotNil(values[2].resolutionID)

    let resolved = try await router.resolveCompletion(values[2])
    XCTAssertEqual(resolved.detail, "resolved by supplemental")
    XCTAssertEqual(resolved.serviceIdentifier, "supplemental")
    XCTAssertEqual(resolved.resolutionID, values[2].resolutionID)
  }

  func testCommandUsesTaggedOriginService() async throws {
    let primary = RouterLanguageStub()
    let supplemental = RouterLanguageStub()
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "primary", service: primary),
      .init(id: "supplemental", service: supplemental, role: .supplemental),
    ])
    let command = EditorCommand(
      title: "Supplemental",
      command: "supplemental.run",
      serviceIdentifier: "supplemental"
    )

    let result = try await router.executeCommand(command)

    XCTAssertEqual(result, .string("supplemental.run"))
    let primaryCommands = await primary.executedCommands
    let supplementalCommands = await supplemental.executedCommands
    XCTAssertTrue(primaryCommands.isEmpty)
    XCTAssertEqual(supplementalCommands, [command])
  }

  func testAdditiveFeaturesMergeAndDeduplicate() async throws {
    let primary = RouterLanguageStub()
    let supplemental = RouterLanguageStub()
    let first = SourceLocation(uri: swiftURI, range: .init(start: .zero, end: .zero))
    let second = SourceLocation(
      uri: swiftURI,
      range: .init(start: .init(line: 1, utf16Column: 0), end: .init(line: 1, utf16Column: 1))
    )
    await primary.configureDefinitions([first])
    await supplemental.configureDefinitions([first, second])
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "primary", service: primary),
      .init(id: "supplemental", service: supplemental, role: .supplemental),
    ])
    try await router.open(
      uri: swiftURI, languageID: "swift", snapshot: .init(text: "", version: 0))

    let definitions = try await router.definitions(uri: swiftURI, at: .zero)
    XCTAssertEqual(definitions, [first, second])
  }

  func testSupplementalFeatureFailureIsReportedAndIgnored() async throws {
    let primary = RouterLanguageStub()
    let supplemental = RouterLanguageStub()
    await primary.configureCompletions([Completion(label: "primary")])
    await supplemental.configureCompletions([], error: RouterTestError.expected)
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "primary", service: primary),
      .init(id: "supplemental", service: supplemental, role: .supplemental),
    ])
    try await router.open(
      uri: swiftURI, languageID: "swift", snapshot: .init(text: "", version: 0))
    let messageTask = Task<LanguageServerMessage?, Never> {
      for await message in router.messages { return message }
      return nil
    }

    let completions = try await router.completions(
      uri: swiftURI, at: .zero, triggerCharacter: nil)
    let message = await messageTask.value

    XCTAssertEqual(completions.map(\.label), ["primary"])
    XCTAssertEqual(message?.kind, .warning)
    XCTAssertEqual(message?.serviceIdentifier, "supplemental")
  }

  func testPrimaryFeatureFailurePropagates() async throws {
    let primary = RouterLanguageStub()
    await primary.configureCompletions([], error: RouterTestError.expected)
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "primary", service: primary)
    ])
    try await router.open(
      uri: swiftURI, languageID: "swift", snapshot: .init(text: "", version: 0))

    do {
      _ = try await router.completions(uri: swiftURI, at: .zero, triggerCharacter: nil)
      XCTFail("Expected the primary service failure")
    } catch let error as RouterTestError {
      XCTAssertEqual(error, .expected)
    }
  }

  func testSupplementalChangeFailureKeepsPrimaryDocumentCurrent() async throws {
    let primary = RouterLanguageStub()
    let supplemental = RouterLanguageStub()
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "primary", service: primary),
      .init(id: "supplemental", service: supplemental, role: .supplemental),
    ])
    let original = TextSnapshot(text: "a", version: 0)
    try await router.open(uri: swiftURI, languageID: "swift", snapshot: original)
    await supplemental.configureChangeError(RouterTestError.expected)
    var buffer = TextBuffer(text: original.text, version: original.version)
    let change = try buffer.apply(
      TextEdit(range: .init(start: .zero, end: .init(line: 0, utf16Column: 1)), replacement: "b"))

    try await router.change(uri: swiftURI, change: change)

    let primarySnapshot = await primary.snapshots[swiftURI]
    let supplementalSnapshot = await supplemental.snapshots[swiftURI]
    let bound = try await router.boundServiceIDs(for: swiftURI)
    XCTAssertEqual(primarySnapshot, change.newSnapshot)
    XCTAssertNil(supplementalSnapshot)
    XCTAssertEqual(bound, ["primary"])
  }

  func testDiagnosticsAndMessagesCarryServiceIdentity() async throws {
    let service = RouterLanguageStub()
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "sourcekit", service: service)
    ])
    let diagnosticTask = Task<DiagnosticBatch?, Never> {
      for await batch in router.diagnostics { return batch }
      return nil
    }
    let messageTask = Task<LanguageServerMessage?, Never> {
      for await message in router.messages { return message }
      return nil
    }

    await service.emitDiagnostic(.init(uri: swiftURI, version: 1, diagnostics: []))
    await service.emitMessage(.init(kind: .log, message: "ready"))

    let diagnostic = await diagnosticTask.value
    let message = await messageTask.value
    XCTAssertEqual(diagnostic?.serviceIdentifier, "sourcekit")
    XCTAssertEqual(message?.serviceIdentifier, "sourcekit")
  }

  func testShutdownClosesDocumentsAndRunsHooksInReverseRoutingOrder() async throws {
    let first = RouterLanguageStub()
    let second = RouterLanguageStub()
    let recorder = ShutdownRecorder()
    let router = try await LanguageServiceRouter(registrations: [
      .init(
        id: "first", service: first, priority: 10, shutdown: { await recorder.append("first") }),
      .init(
        id: "second", service: second, priority: 0, shutdown: { await recorder.append("second") }),
    ])
    try await router.open(
      uri: swiftURI, languageID: "swift", snapshot: .init(text: "", version: 0))

    try await router.shutdown()

    let shutdownIDs = await recorder.ids
    let firstCloseCalls = await first.closeCalls
    let secondCloseCalls = await second.closeCalls
    let registrations = await router.registrations()
    XCTAssertEqual(shutdownIDs, ["second", "first"])
    XCTAssertEqual(firstCloseCalls, [swiftURI])
    XCTAssertEqual(secondCloseCalls, [swiftURI])
    XCTAssertTrue(registrations.isEmpty)
  }

  func testCodeActionsDeduplicateBeforeOriginTagging() async throws {
    let primary = RouterLanguageStub()
    let supplemental = RouterLanguageStub()
    let action = EditorCodeAction(
      title: "Fix it",
      command: .init(title: "Apply", command: "fix.apply")
    )
    await primary.configureCodeActions([action])
    await supplemental.configureCodeActions([action])
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "primary", service: primary),
      .init(id: "supplemental", service: supplemental, role: .supplemental),
    ])
    try await router.open(
      uri: swiftURI, languageID: "swift", snapshot: .init(text: "", version: 0))

    let actions = try await router.codeActions(
      uri: swiftURI, range: .init(start: .zero, end: .zero), diagnostics: [], only: nil)

    XCTAssertEqual(actions.count, 1)
    XCTAssertEqual(actions[0].command?.serviceIdentifier, "primary")
  }

  func testUnregisterRemainsCommittedWhenShutdownHookFails() async throws {
    let service = RouterLanguageStub()
    let router = try await LanguageServiceRouter(registrations: [
      .init(
        id: "failing-shutdown",
        service: service,
        shutdown: { throw RouterTestError.expected }
      )
    ])
    try await router.open(
      uri: swiftURI, languageID: "swift", snapshot: .init(text: "", version: 0))

    do {
      try await router.unregister("failing-shutdown")
      XCTFail("Expected shutdown-hook failure")
    } catch let error as LanguageServiceRouterError {
      guard case .lifecycleFailure(let operation, let serviceID, _, _) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(operation, "unregistration shutdown")
      XCTAssertEqual(serviceID, "failing-shutdown")
    }

    let registrations = await router.registrations()
    let bound = try await router.boundServiceIDs(for: swiftURI)
    XCTAssertTrue(registrations.isEmpty)
    XCTAssertTrue(bound.isEmpty)
  }

  func testShutdownIsIdempotentCoalescedAndRejectsReuse() async throws {
    let service = RouterLanguageStub()
    let counter = InvocationCounter()
    let router = try await LanguageServiceRouter(registrations: [
      .init(
        id: "service",
        service: service,
        shutdown: {
          await counter.increment()
          try await Task.sleep(for: .milliseconds(25))
        }
      )
    ])
    try await router.open(
      uri: swiftURI, languageID: "swift", snapshot: .init(text: "", version: 0))

    async let first: Void = router.shutdown()
    async let second: Void = router.shutdown()
    _ = try await (first, second)
    try await router.shutdown()

    let shutdownCount = await counter.value
    XCTAssertEqual(shutdownCount, 1)
    do {
      try await router.register(.init(id: "late", service: RouterLanguageStub()))
      XCTFail("Expected shutdown error")
    } catch let error as LanguageServiceRouterError {
      XCTAssertEqual(error, .shutdown)
    }
    do {
      try await router.open(
        uri: markdownURI, languageID: "markdown", snapshot: .init(text: "", version: 0))
      XCTFail("Expected shutdown error")
    } catch let error as LanguageServiceRouterError {
      XCTAssertEqual(error, .shutdown)
    }
  }

  func testFailedShutdownStillFinishesStreamsAndReportsStableResult() async throws {
    let service = RouterLanguageStub()
    let router = try await LanguageServiceRouter(registrations: [
      .init(
        id: "service",
        service: service,
        shutdown: { throw RouterTestError.expected }
      )
    ])
    let streamFinished = Task<Bool, Never> {
      for await _ in router.messages {}
      return true
    }

    for _ in 0..<2 {
      do {
        try await router.shutdown()
        XCTFail("Expected shutdown failure")
      } catch let error as LanguageServiceRouterError {
        XCTAssertEqual(error, .shutdownFailures(["service"]))
      }
    }

    let didFinishStream = await streamFinished.value
    let registrations = await router.registrations()
    XCTAssertTrue(didFinishStream)
    XCTAssertTrue(registrations.isEmpty)
  }

  func testInitializationFailureShutsDownAlreadyAcceptedRegistrations() async throws {
    let first = RouterLanguageStub()
    let duplicate = RouterLanguageStub()
    let recorder = InvocationCounter()

    do {
      _ = try await LanguageServiceRouter(registrations: [
        .init(
          id: "duplicate",
          service: first,
          shutdown: { await recorder.increment() }
        ),
        .init(id: "duplicate", service: duplicate),
      ])
      XCTFail("Expected duplicate registration failure")
    } catch let error as LanguageServiceRouterError {
      XCTAssertEqual(error, .duplicateRegistration("duplicate"))
    }

    let count = await recorder.value
    XCTAssertEqual(count, 1)
  }

  func testCompletionsWithSameLabelButDifferentSemanticsRemainDistinct() async throws {
    let primary = RouterLanguageStub()
    let supplemental = RouterLanguageStub()
    await primary.configureCompletions([
      Completion(label: "value", detail: "primary", insertText: "first")
    ])
    await supplemental.configureCompletions([
      Completion(label: "value", detail: "supplemental", insertText: "second")
    ])
    let router = try await LanguageServiceRouter(registrations: [
      .init(id: "primary", service: primary),
      .init(id: "supplemental", service: supplemental, role: .supplemental),
    ])
    try await router.open(
      uri: swiftURI, languageID: "swift", snapshot: .init(text: "", version: 0))

    let completions = try await router.completions(
      uri: swiftURI, at: .zero, triggerCharacter: nil)

    XCTAssertEqual(completions.map(\.insertText), ["first", "second"])
    XCTAssertEqual(completions.map(\.serviceIdentifier), ["primary", "supplemental"])
  }

}
