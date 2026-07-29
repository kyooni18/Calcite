import EditorCore
import Foundation

/// Stable identity for a language-intelligence service registered with a router.
public struct LanguageServiceID: RawRepresentable, Hashable, Codable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public var rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
  public var description: String { rawValue }
}

/// Determines how a routed service participates in feature requests.
public enum LanguageServiceRole: Int, Hashable, Codable, Sendable {
  /// A failure from a primary service is propagated to the caller.
  case primary
  /// Supplemental feature failures are reported as messages and do not hide primary results.
  case supplemental
}

/// Declarative document matching for a language service.
public struct LanguageServiceSelector: Sendable {
  public typealias Predicate = @Sendable (_ uri: URL, _ languageID: String) -> Bool

  public var languageIDs: Set<String>
  public var fileExtensions: Set<String>
  public var urlSchemes: Set<String>
  private let predicate: Predicate

  public init(
    languageIDs: Set<String> = [],
    fileExtensions: Set<String> = [],
    urlSchemes: Set<String> = [],
    predicate: @escaping Predicate = { _, _ in true }
  ) {
    self.languageIDs = Self.normalizedTokens(languageIDs)
    self.fileExtensions = Set(
      fileExtensions.compactMap { value in
        let normalized =
          value
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "."))
          .lowercased()
        return normalized.isEmpty ? nil : normalized
      }
    )
    self.urlSchemes = Self.normalizedTokens(urlSchemes)
    self.predicate = predicate
  }

  public static var all: Self { .init() }

  public func matches(uri: URL, languageID: String) -> Bool {
    let normalizedLanguageID =
      languageID
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let normalizedExtension = uri.pathExtension
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let normalizedScheme = (uri.scheme ?? "file")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    let languageMatches = languageIDs.isEmpty || languageIDs.contains(normalizedLanguageID)
    let extensionMatches = fileExtensions.isEmpty || fileExtensions.contains(normalizedExtension)
    let schemeMatches = urlSchemes.isEmpty || urlSchemes.contains(normalizedScheme)
    return languageMatches && extensionMatches && schemeMatches && predicate(uri, languageID)
  }

  private static func normalizedTokens(_ values: Set<String>) -> Set<String> {
    Set(
      values.compactMap { value in
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
      }
    )
  }
}

/// A language service and its routing metadata.
public struct LanguageServiceRegistration: Sendable {
  public typealias Shutdown = @Sendable () async throws -> Void

  public var id: LanguageServiceID
  public var role: LanguageServiceRole
  public var priority: Int
  public var selector: LanguageServiceSelector
  public var service: any LanguageIntelligenceProviding
  public var shutdown: Shutdown

  public init(
    id: LanguageServiceID,
    service: any LanguageIntelligenceProviding,
    role: LanguageServiceRole = .primary,
    priority: Int = 0,
    selector: LanguageServiceSelector = .all,
    shutdown: @escaping Shutdown = {}
  ) {
    self.id = id
    self.service = service
    self.role = role
    self.priority = priority
    self.selector = selector
    self.shutdown = shutdown
  }
}

/// Public, service-free metadata returned by ``LanguageServiceRouter/registrations()``.
public struct LanguageServiceDescriptor: Hashable, Sendable {
  public var id: LanguageServiceID
  public var role: LanguageServiceRole
  public var priority: Int
  public var languageIDs: Set<String>
  public var fileExtensions: Set<String>
  public var urlSchemes: Set<String>

  public init(
    id: LanguageServiceID,
    role: LanguageServiceRole,
    priority: Int,
    languageIDs: Set<String>,
    fileExtensions: Set<String>,
    urlSchemes: Set<String>
  ) {
    self.id = id
    self.role = role
    self.priority = priority
    self.languageIDs = languageIDs
    self.fileExtensions = fileExtensions
    self.urlSchemes = urlSchemes
  }
}

public enum LanguageServiceRouterError: Error, Equatable, Sendable {
  case invalidIdentifier
  case shutdown
  case duplicateRegistration(LanguageServiceID)
  case unknownRegistration(LanguageServiceID)
  case documentAlreadyOpen(URL)
  case documentNotOpen(URL)
  case lifecycleFailure(
    operation: String,
    service: LanguageServiceID,
    reason: String,
    recoveryFailures: [LanguageServiceID]
  )
  case shutdownFailures([LanguageServiceID])
}

extension LanguageServiceRouterError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidIdentifier:
      return "A language service identifier cannot be empty."
    case .shutdown:
      return "The language service router has shut down."
    case .duplicateRegistration(let id):
      return "A language service is already registered as '\(id.rawValue)'."
    case .unknownRegistration(let id):
      return "No language service is registered as '\(id.rawValue)'."
    case .documentAlreadyOpen(let uri):
      return "The routed document is already open: \(uri.absoluteString)"
    case .documentNotOpen(let uri):
      return "The routed document is not open: \(uri.absoluteString)"
    case .lifecycleFailure(let operation, let service, let reason, let recoveryFailures):
      var message = "Language service '\(service.rawValue)' failed during \(operation): \(reason)"
      if !recoveryFailures.isEmpty {
        message +=
          ". Recovery also failed for: "
          + recoveryFailures.map(\.rawValue).joined(separator: ", ")
      }
      return message
    case .shutdownFailures(let ids):
      return "Language service shutdown failed for: "
        + ids.map(\.rawValue).joined(separator: ", ")
    }
  }
}

/// Routes document lifecycle and language features across independently registered services.
///
/// Selection is deterministic: primary services precede supplemental services, higher priority
/// precedes lower priority, and registration order breaks ties. Document lifecycle calls are sent
/// to every selected service. Feature requests merge additive results or use the first service that
/// supports an exclusive feature. Runtime registration automatically opens matching documents.
public final class LanguageServiceRouter: LanguageIntelligenceProviding, @unchecked Sendable {
  public nonisolated let diagnostics: AsyncStream<DiagnosticBatch>
  public nonisolated let messages: AsyncStream<LanguageServerMessage>

  private let diagnosticContinuation: AsyncStream<DiagnosticBatch>.Continuation
  private let messageContinuation: AsyncStream<LanguageServerMessage>.Continuation
  private let storage: Storage

  public init(registrations: [LanguageServiceRegistration] = []) async throws {
    (diagnostics, diagnosticContinuation) = AsyncStream.makeStream(of: DiagnosticBatch.self)
    (messages, messageContinuation) = AsyncStream.makeStream(of: LanguageServerMessage.self)
    storage = Storage(
      diagnosticContinuation: diagnosticContinuation,
      messageContinuation: messageContinuation
    )
    do {
      for registration in registrations { try await storage.register(registration) }
    } catch {
      try? await storage.shutdown()
      await storage.cancelStreams()
      diagnosticContinuation.finish()
      messageContinuation.finish()
      throw error
    }
  }

  deinit {
    diagnosticContinuation.finish()
    messageContinuation.finish()
    let storage = storage
    Task {
      try? await storage.shutdown()
      await storage.cancelStreams()
    }
  }

  public func register(_ registration: LanguageServiceRegistration) async throws {
    try await storage.register(registration)
  }

  /// Removes a service after closing every bound document.
  ///
  /// When `shutDown` is true, the registration is removed before its shutdown hook runs. A hook
  /// failure is reported to the caller, but the registration remains removed because shutdown may
  /// have partially released irreversible resources.
  public func unregister(_ id: LanguageServiceID, shutDown: Bool = true) async throws {
    try await storage.unregister(id, shutDown: shutDown)
  }

  public func registrations() async -> [LanguageServiceDescriptor] {
    await storage.descriptors()
  }

  public func boundServiceIDs(for uri: URL) async throws -> [LanguageServiceID] {
    try await storage.boundServiceIDs(for: uri)
  }

  /// Re-evaluates selectors for an already open document and transactionally updates its services.
  public func rebindDocument(at uri: URL) async throws {
    try await storage.rebindDocument(at: uri)
  }

  public func shutdown() async throws {
    defer {
      diagnosticContinuation.finish()
      messageContinuation.finish()
    }
    try await storage.shutdown()
  }

  public func open(uri: URL, languageID: String, snapshot: TextSnapshot) async throws {
    try await storage.open(uri: uri, languageID: languageID, snapshot: snapshot)
  }

  public func change(uri: URL, change: AppliedTextEdit) async throws {
    try await storage.change(uri: uri, change: change)
  }

  public func save(uri: URL, snapshot: TextSnapshot) async throws {
    try await storage.save(uri: uri, snapshot: snapshot)
  }

  public func completions(uri: URL, at position: TextPosition, triggerCharacter: String?)
    async throws
    -> [Completion]
  {
    try await storage.completions(
      uri: uri, at: position, triggerCharacter: triggerCharacter)
  }

  public func resolveCompletion(_ completion: Completion) async throws -> Completion {
    try await storage.resolveCompletion(completion)
  }

  public func hover(uri: URL, at position: TextPosition) async throws -> HoverResult? {
    try await storage.hover(uri: uri, at: position)
  }

  public func definitions(uri: URL, at position: TextPosition) async throws -> [SourceLocation] {
    try await storage.definitions(uri: uri, at: position)
  }

  public func references(uri: URL, at position: TextPosition, includeDeclaration: Bool) async throws
    -> [SourceLocation]
  {
    try await storage.references(
      uri: uri, at: position, includeDeclaration: includeDeclaration)
  }

  public func formatting(uri: URL, options: EditorFormattingOptions) async throws -> [TextEdit] {
    try await storage.formatting(uri: uri, options: options)
  }

  public func rangeFormatting(uri: URL, range: EditorTextRange, options: EditorFormattingOptions)
    async throws -> [TextEdit]
  {
    try await storage.rangeFormatting(uri: uri, range: range, options: options)
  }

  public func prepareRename(uri: URL, at position: TextPosition) async throws -> RenamePreparation?
  {
    try await storage.prepareRename(uri: uri, at: position)
  }

  public func rename(uri: URL, at position: TextPosition, newName: String) async throws
    -> EditorWorkspaceEdit?
  {
    try await storage.rename(uri: uri, at: position, newName: newName)
  }

  public func semanticHighlights(uri: URL) async throws -> [SemanticHighlight] {
    try await storage.semanticHighlights(uri: uri)
  }

  public func signatureHelp(uri: URL, at position: TextPosition) async throws
    -> EditorSignatureHelp?
  {
    try await storage.signatureHelp(uri: uri, at: position)
  }

  public func documentSymbols(uri: URL) async throws -> [EditorDocumentSymbol] {
    try await storage.documentSymbols(uri: uri)
  }

  public func workspaceSymbols(query: String) async throws -> [EditorWorkspaceSymbol] {
    try await storage.workspaceSymbols(query: query)
  }

  public func notifyWorkspaceFileChanges(_ changes: [EditorWorkspaceFileChange]) async throws {
    try await storage.notifyWorkspaceFileChanges(changes)
  }

  public func pullDiagnostics(uri: URL, previousResultID: String? = nil) async throws
    -> DiagnosticBatch
  {
    try await storage.pullDiagnostics(uri: uri, previousResultID: previousResultID)
  }

  public func codeActions(
    uri: URL, range: EditorTextRange, diagnostics: [Diagnostic], only: [String]?
  ) async throws -> [EditorCodeAction] {
    try await storage.codeActions(
      uri: uri, range: range, diagnostics: diagnostics, only: only)
  }

  public func inlayHints(uri: URL, range: EditorTextRange) async throws -> [EditorInlayHint] {
    try await storage.inlayHints(uri: uri, range: range)
  }

  public func executeCommand(_ command: EditorCommand) async throws -> EditorJSONValue? {
    try await storage.executeCommand(command)
  }

  public func close(uri: URL) async throws { try await storage.close(uri: uri) }
}

private actor Storage {
  private enum Lifecycle {
    case active
    case shuttingDown
    case shutDown(LanguageServiceRouterError?)
  }

  private struct Entry {
    var registration: LanguageServiceRegistration
    var order: Int
    var diagnosticTask: Task<Void, Never>?
    var messageTask: Task<Void, Never>?
  }

  private struct Document {
    var languageID: String
    var snapshot: TextSnapshot
    var serviceIDs: [LanguageServiceID]
  }

  private struct CompletionRoute {
    var uri: URL
    var serviceID: LanguageServiceID
    var original: Completion
  }

  private let diagnosticContinuation: AsyncStream<DiagnosticBatch>.Continuation
  private let messageContinuation: AsyncStream<LanguageServerMessage>.Continuation
  private var entries: [LanguageServiceID: Entry] = [:]
  private var documents: [URL: Document] = [:]
  private var completionRoutes: [UUID: CompletionRoute] = [:]
  private var nextOrder = 0
  private var lifecycle = Lifecycle.active
  private var shutdownWaiters: [CheckedContinuation<Void, any Error>] = []

  init(
    diagnosticContinuation: AsyncStream<DiagnosticBatch>.Continuation,
    messageContinuation: AsyncStream<LanguageServerMessage>.Continuation
  ) {
    self.diagnosticContinuation = diagnosticContinuation
    self.messageContinuation = messageContinuation
  }

  func register(_ registration: LanguageServiceRegistration) async throws {
    try ensureActive()
    guard !registration.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LanguageServiceRouterError.invalidIdentifier
    }
    guard entries[registration.id] == nil else {
      throw LanguageServiceRouterError.duplicateRegistration(registration.id)
    }

    var opened: [URL] = []
    do {
      for uri in documents.keys.sorted(by: { $0.absoluteString < $1.absoluteString }) {
        guard let document = documents[uri],
          registration.selector.matches(uri: uri, languageID: document.languageID)
        else { continue }
        try await registration.service.open(
          uri: uri, languageID: document.languageID, snapshot: document.snapshot)
        opened.append(uri)
      }
    } catch {
      var recovery: [LanguageServiceID] = []
      for uri in opened.reversed() {
        do { try await registration.service.close(uri: uri) } catch {
          recovery.append(registration.id)
        }
      }
      throw lifecycleError(
        operation: "registration rebind", service: registration.id, error: error,
        recoveryFailures: recovery)
    }

    let id = registration.id
    let diagnosticSource = registration.service.diagnostics
    let messageSource = registration.service.messages
    let diagnosticContinuation = diagnosticContinuation
    let messageContinuation = messageContinuation
    let diagnosticTask = Task {
      for await batch in diagnosticSource {
        var routed = batch
        routed.serviceIdentifier = id.rawValue
        diagnosticContinuation.yield(routed)
      }
    }
    let messageTask = Task {
      for await message in messageSource {
        var routed = message
        routed.serviceIdentifier = id.rawValue
        messageContinuation.yield(routed)
      }
    }
    entries[id] = Entry(
      registration: registration,
      order: nextOrder,
      diagnosticTask: diagnosticTask,
      messageTask: messageTask
    )
    nextOrder += 1
    for uri in opened {
      guard var document = documents[uri] else { continue }
      document.serviceIDs.append(id)
      document.serviceIDs = orderedIDs(document.serviceIDs)
      documents[uri] = document
    }
  }

  func unregister(_ id: LanguageServiceID, shutDown: Bool) async throws {
    try ensureActive()
    guard let entry = entries[id] else { throw LanguageServiceRouterError.unknownRegistration(id) }
    var closed: [URL] = []
    do {
      for uri in documents.keys.sorted(by: { $0.absoluteString < $1.absoluteString }) {
        guard documents[uri]?.serviceIDs.contains(id) == true else { continue }
        try await entry.registration.service.close(uri: uri)
        closed.append(uri)
      }
    } catch {
      var recovery: [LanguageServiceID] = []
      for uri in closed {
        guard let document = documents[uri] else { continue }
        do {
          try await entry.registration.service.open(
            uri: uri, languageID: document.languageID, snapshot: document.snapshot)
        } catch { recovery.append(id) }
      }
      throw lifecycleError(
        operation: "unregistration", service: id, error: error,
        recoveryFailures: recovery)
    }

    entry.diagnosticTask?.cancel()
    entry.messageTask?.cancel()
    entries.removeValue(forKey: id)
    completionRoutes = completionRoutes.filter { $0.value.serviceID != id }
    for uri in documents.keys { documents[uri]?.serviceIDs.removeAll { $0 == id } }

    if shutDown {
      do { try await entry.registration.shutdown() } catch {
        throw lifecycleError(operation: "unregistration shutdown", service: id, error: error)
      }
    }
  }

  func descriptors() -> [LanguageServiceDescriptor] {
    guard case .active = lifecycle else { return [] }
    return orderedEntries(entries.values).map { entry in
      let registration = entry.registration
      return LanguageServiceDescriptor(
        id: registration.id,
        role: registration.role,
        priority: registration.priority,
        languageIDs: registration.selector.languageIDs,
        fileExtensions: registration.selector.fileExtensions,
        urlSchemes: registration.selector.urlSchemes
      )
    }
  }

  func boundServiceIDs(for uri: URL) throws -> [LanguageServiceID] {
    try ensureActive()
    guard let document = documents[uri] else {
      throw LanguageServiceRouterError.documentNotOpen(uri)
    }
    return document.serviceIDs
  }

  func rebindDocument(at uri: URL) async throws {
    try ensureActive()
    guard let original = documents[uri] else {
      throw LanguageServiceRouterError.documentNotOpen(uri)
    }
    let desired = selectedEntries(uri: uri, languageID: original.languageID).map {
      $0.registration.id
    }
    let removed = original.serviceIDs.filter { !desired.contains($0) }
    let added = desired.filter { !original.serviceIDs.contains($0) }
    var closed: [LanguageServiceID] = []
    var opened: [LanguageServiceID] = []
    do {
      for id in removed {
        guard let entry = entries[id] else { continue }
        try await entry.registration.service.close(uri: uri)
        closed.append(id)
      }
      for id in added {
        guard let entry = entries[id] else { continue }
        try await entry.registration.service.open(
          uri: uri, languageID: original.languageID, snapshot: original.snapshot)
        opened.append(id)
      }
      documents[uri]?.serviceIDs = desired
    } catch {
      var recovery: [LanguageServiceID] = []
      for id in opened.reversed() {
        do { try await entries[id]?.registration.service.close(uri: uri) } catch {
          recovery.append(id)
        }
      }
      for id in closed {
        guard let service = entries[id]?.registration.service else { continue }
        do {
          try await service.open(
            uri: uri, languageID: original.languageID, snapshot: original.snapshot)
        } catch { recovery.append(id) }
      }
      let failedID =
        added.first(where: { !opened.contains($0) })
        ?? removed.first(where: { !closed.contains($0) })
        ?? original.serviceIDs.first
        ?? LanguageServiceID(rawValue: "router")
      throw lifecycleError(
        operation: "document rebind", service: failedID, error: error,
        recoveryFailures: recovery)
    }
  }

  func open(uri: URL, languageID: String, snapshot: TextSnapshot) async throws {
    try ensureActive()
    guard documents[uri] == nil else { throw LanguageServiceRouterError.documentAlreadyOpen(uri) }
    let selected = selectedEntries(uri: uri, languageID: languageID)
    var opened: [Entry] = []
    for entry in selected {
      do {
        try await entry.registration.service.open(
          uri: uri, languageID: languageID, snapshot: snapshot)
        opened.append(entry)
      } catch {
        if entry.registration.role == .supplemental {
          reportLifecycleFailure(operation: "open", entry: entry, error: error)
          continue
        }
        var recovery: [LanguageServiceID] = []
        for openedEntry in opened.reversed() {
          do { try await openedEntry.registration.service.close(uri: uri) } catch {
            recovery.append(openedEntry.registration.id)
          }
        }
        throw lifecycleError(
          operation: "open",
          service: entry.registration.id,
          error: error,
          recoveryFailures: recovery
        )
      }
    }
    documents[uri] = Document(
      languageID: languageID,
      snapshot: snapshot,
      serviceIDs: opened.map { $0.registration.id }
    )
  }

  func change(uri: URL, change: AppliedTextEdit) async throws {
    try ensureActive()
    guard let original = documents[uri] else {
      throw LanguageServiceRouterError.documentNotOpen(uri)
    }
    let selected = entries(for: original)
    var changed: [Entry] = []
    var activeServiceIDs = original.serviceIDs
    for entry in selected {
      do {
        try await entry.registration.service.change(uri: uri, change: change)
        changed.append(entry)
      } catch {
        if entry.registration.role == .supplemental {
          reportLifecycleFailure(operation: "change", entry: entry, error: error)
          try? await entry.registration.service.close(uri: uri)
          activeServiceIDs.removeAll { $0 == entry.registration.id }
          continue
        }
        var recovery: [LanguageServiceID] = []
        for recoveryEntry in selected {
          try? await recoveryEntry.registration.service.close(uri: uri)
          do {
            try await recoveryEntry.registration.service.open(
              uri: uri, languageID: original.languageID, snapshot: original.snapshot)
          } catch { recovery.append(recoveryEntry.registration.id) }
        }
        throw lifecycleError(
          operation: "change",
          service: entry.registration.id,
          error: error,
          recoveryFailures: recovery
        )
      }
    }
    documents[uri]?.snapshot = change.newSnapshot
    documents[uri]?.serviceIDs = activeServiceIDs
    completionRoutes = completionRoutes.filter { $0.value.uri != uri }
  }

  func save(uri: URL, snapshot: TextSnapshot) async throws {
    try ensureActive()
    guard let document = documents[uri] else {
      throw LanguageServiceRouterError.documentNotOpen(uri)
    }
    let selected = entries(for: document)
    for entry in selected {
      do {
        try await entry.registration.service.save(uri: uri, snapshot: snapshot)
      } catch {
        if entry.registration.role == .supplemental {
          reportLifecycleFailure(operation: "save", entry: entry, error: error)
          continue
        }
        throw lifecycleError(
          operation: "save", service: entry.registration.id, error: error)
      }
    }
  }

  func close(uri: URL) async throws {
    try ensureActive()
    try await closeDocument(uri: uri)
  }

  private func closeDocument(uri: URL) async throws {
    guard let document = documents[uri] else {
      throw LanguageServiceRouterError.documentNotOpen(uri)
    }
    let selected = entries(for: document)
    var firstFailure: (LanguageServiceID, Error)?
    for entry in selected.reversed() {
      do { try await entry.registration.service.close(uri: uri) } catch {
        if firstFailure == nil { firstFailure = (entry.registration.id, error) }
      }
    }
    if let firstFailure {
      var recovery: [LanguageServiceID] = []
      for entry in selected {
        try? await entry.registration.service.close(uri: uri)
        do {
          try await entry.registration.service.open(
            uri: uri, languageID: document.languageID, snapshot: document.snapshot)
        } catch { recovery.append(entry.registration.id) }
      }
      throw lifecycleError(
        operation: "close", service: firstFailure.0, error: firstFailure.1,
        recoveryFailures: recovery)
    }
    documents.removeValue(forKey: uri)
    completionRoutes = completionRoutes.filter { $0.value.uri != uri }
  }

  func completions(uri: URL, at position: TextPosition, triggerCharacter: String?) async throws
    -> [Completion]
  {
    try ensureActive()
    let selected = try featureEntries(for: uri)
    completionRoutes = completionRoutes.filter { $0.value.uri != uri }
    var results: [Completion] = []
    var seen: Set<Completion> = []
    for entry in selected {
      do {
        let values = try await entry.registration.service.completions(
          uri: uri, at: position, triggerCharacter: triggerCharacter)
        for original in values {
          guard seen.insert(completionKey(original)).inserted else { continue }
          let routeID = UUID()
          completionRoutes[routeID] = CompletionRoute(
            uri: uri, serviceID: entry.registration.id, original: original)
          results.append(
            tagCompletion(original, serviceID: entry.registration.id, routeID: routeID))
        }
      } catch {
        if try shouldContinue(after: error, entry: entry, feature: "textDocument/completion") {
          continue
        }
      }
    }
    return results
  }

  func resolveCompletion(_ completion: Completion) async throws -> Completion {
    try ensureActive()
    if let routeID = completion.resolutionID, let route = completionRoutes[routeID],
      let entry = entries[route.serviceID]
    {
      let resolved = try await entry.registration.service.resolveCompletion(route.original)
      completionRoutes[routeID]?.original = resolved
      return tagCompletion(resolved, serviceID: route.serviceID, routeID: routeID)
    }
    if let identifier = completion.serviceIdentifier {
      let id = LanguageServiceID(rawValue: identifier)
      guard let entry = entries[id] else {
        throw LanguageServiceRouterError.unknownRegistration(id)
      }
      let resolved = try await entry.registration.service.resolveCompletion(completion)
      return tagCompletion(resolved, serviceID: id, routeID: completion.resolutionID)
    }
    return try await firstSupported(
      feature: "completionItem/resolve", entries: orderedEntries(entries.values)
    ) {
      try await $0.registration.service.resolveCompletion(completion)
    }
  }

  func hover(uri: URL, at position: TextPosition) async throws -> HoverResult? {
    try ensureActive()
    let selected = try featureEntries(for: uri)
    for entry in selected {
      do {
        if let result = try await entry.registration.service.hover(uri: uri, at: position) {
          return result
        }
      } catch {
        if try shouldContinue(after: error, entry: entry, feature: "textDocument/hover") {
          continue
        }
      }
    }
    return nil
  }

  func definitions(uri: URL, at position: TextPosition) async throws -> [SourceLocation] {
    try ensureActive()
    return try await merged(uri: uri, feature: "textDocument/definition") {
      try await $0.registration.service.definitions(uri: uri, at: position)
    }
  }

  func references(uri: URL, at position: TextPosition, includeDeclaration: Bool) async throws
    -> [SourceLocation]
  {
    try ensureActive()
    return try await merged(uri: uri, feature: "textDocument/references") {
      try await $0.registration.service.references(
        uri: uri, at: position, includeDeclaration: includeDeclaration)
    }
  }

  func formatting(uri: URL, options: EditorFormattingOptions) async throws -> [TextEdit] {
    try ensureActive()
    return try await firstSupported(uri: uri, feature: "textDocument/formatting") {
      try await $0.registration.service.formatting(uri: uri, options: options)
    }
  }

  func rangeFormatting(uri: URL, range: EditorTextRange, options: EditorFormattingOptions)
    async throws
    -> [TextEdit]
  {
    try ensureActive()
    return try await firstSupported(uri: uri, feature: "textDocument/rangeFormatting") {
      try await $0.registration.service.rangeFormatting(uri: uri, range: range, options: options)
    }
  }

  func prepareRename(uri: URL, at position: TextPosition) async throws -> RenamePreparation? {
    try ensureActive()
    let selected = try featureEntries(for: uri)
    for entry in selected {
      do {
        if let result = try await entry.registration.service.prepareRename(uri: uri, at: position) {
          return result
        }
      } catch {
        if try shouldContinue(after: error, entry: entry, feature: "textDocument/prepareRename") {
          continue
        }
      }
    }
    return nil
  }

  func rename(uri: URL, at position: TextPosition, newName: String) async throws
    -> EditorWorkspaceEdit?
  {
    try ensureActive()
    let selected = try featureEntries(for: uri)
    for entry in selected {
      do {
        if let result = try await entry.registration.service.rename(
          uri: uri, at: position, newName: newName)
        {
          return result
        }
      } catch {
        if try shouldContinue(after: error, entry: entry, feature: "textDocument/rename") {
          continue
        }
      }
    }
    return nil
  }

  func semanticHighlights(uri: URL) async throws -> [SemanticHighlight] {
    try ensureActive()
    return try await merged(uri: uri, feature: "textDocument/semanticTokens/full") {
      try await $0.registration.service.semanticHighlights(uri: uri)
    }
  }

  func signatureHelp(uri: URL, at position: TextPosition) async throws -> EditorSignatureHelp? {
    try ensureActive()
    let selected = try featureEntries(for: uri)
    for entry in selected {
      do {
        if let result = try await entry.registration.service.signatureHelp(uri: uri, at: position) {
          return result
        }
      } catch {
        if try shouldContinue(after: error, entry: entry, feature: "textDocument/signatureHelp") {
          continue
        }
      }
    }
    return nil
  }

  func documentSymbols(uri: URL) async throws -> [EditorDocumentSymbol] {
    try ensureActive()
    return try await merged(uri: uri, feature: "textDocument/documentSymbol") {
      try await $0.registration.service.documentSymbols(uri: uri)
    }
  }

  func workspaceSymbols(query: String) async throws -> [EditorWorkspaceSymbol] {
    try ensureActive()
    var result: [EditorWorkspaceSymbol] = []
    var seen: Set<EditorWorkspaceSymbol> = []
    for entry in orderedEntries(entries.values) {
      do {
        for symbol in try await entry.registration.service.workspaceSymbols(query: query) {
          var key = symbol
          key.serviceIdentifier = nil
          guard seen.insert(key).inserted else { continue }
          var routed = symbol
          routed.serviceIdentifier = entry.registration.id.rawValue
          result.append(routed)
        }
      } catch {
        if try shouldContinue(after: error, entry: entry, feature: "workspace/symbol") {
          continue
        }
      }
    }
    return result
  }

  func notifyWorkspaceFileChanges(_ changes: [EditorWorkspaceFileChange]) async throws {
    try ensureActive()
    guard !changes.isEmpty else { return }
    for entry in orderedEntries(entries.values) {
      do {
        try await entry.registration.service.notifyWorkspaceFileChanges(changes)
      } catch {
        if try shouldContinue(
          after: error, entry: entry, feature: "workspace/didChangeWatchedFiles")
        {
          continue
        }
      }
    }
  }

  func pullDiagnostics(uri: URL, previousResultID: String?) async throws -> DiagnosticBatch {
    try ensureActive()
    let selected: [Entry]
    if let document = documents[uri] {
      selected = entries(for: document)
    } else {
      let fileExtension = uri.pathExtension.lowercased()
      let scheme = (uri.scheme ?? "file").lowercased()
      selected = orderedEntries(
        entries.values.filter { entry in
          let selector = entry.registration.selector
          let extensionMatches =
            selector.fileExtensions.isEmpty || selector.fileExtensions.contains(fileExtension)
          let schemeMatches = selector.urlSchemes.isEmpty || selector.urlSchemes.contains(scheme)
          return extensionMatches && schemeMatches
        }
      )
    }
    var diagnostics: [Diagnostic] = []
    var seen: Set<Diagnostic> = []
    var versions: [Int] = []
    var successfulServiceIDs: [String] = []
    for entry in selected {
      do {
        let batch = try await entry.registration.service.pullDiagnostics(
          uri: uri, previousResultID: previousResultID)
        successfulServiceIDs.append(entry.registration.id.rawValue)
        if let version = batch.version { versions.append(version) }
        for diagnostic in batch.diagnostics where seen.insert(diagnostic).inserted {
          diagnostics.append(diagnostic)
        }
      } catch {
        if try shouldContinue(after: error, entry: entry, feature: "textDocument/diagnostic") {
          continue
        }
      }
    }
    guard !successfulServiceIDs.isEmpty else {
      throw LanguageFeatureError.unsupported("textDocument/diagnostic")
    }
    return DiagnosticBatch(
      uri: uri.standardizedFileURL,
      version: versions.max(),
      diagnostics: diagnostics,
      serviceIdentifier: successfulServiceIDs.count == 1 ? successfulServiceIDs[0] : nil
    )
  }

  func codeActions(
    uri: URL, range: EditorTextRange, diagnostics: [Diagnostic], only: [String]?
  ) async throws -> [EditorCodeAction] {
    try ensureActive()
    let selected = try featureEntries(for: uri)
    var result: [EditorCodeAction] = []
    var seen: Set<EditorCodeAction> = []
    for entry in selected {
      do {
        let actions = try await entry.registration.service.codeActions(
          uri: uri, range: range, diagnostics: diagnostics, only: only)
        for action in actions {
          var key = action
          if var command = key.command {
            command.serviceIdentifier = nil
            key.command = command
          }
          guard seen.insert(key).inserted else { continue }
          var routed = action
          if var command = routed.command {
            command.serviceIdentifier = entry.registration.id.rawValue
            routed.command = command
          }
          result.append(routed)
        }
      } catch {
        if try shouldContinue(after: error, entry: entry, feature: "textDocument/codeAction") {
          continue
        }
      }
    }
    return result
  }

  func inlayHints(uri: URL, range: EditorTextRange) async throws -> [EditorInlayHint] {
    try ensureActive()
    return try await merged(uri: uri, feature: "textDocument/inlayHint") {
      try await $0.registration.service.inlayHints(uri: uri, range: range)
    }
  }

  func executeCommand(_ command: EditorCommand) async throws -> EditorJSONValue? {
    try ensureActive()
    if let identifier = command.serviceIdentifier {
      let id = LanguageServiceID(rawValue: identifier)
      guard let entry = entries[id] else {
        throw LanguageServiceRouterError.unknownRegistration(id)
      }
      return try await entry.registration.service.executeCommand(command)
    }
    return try await firstSupported(
      feature: "workspace/executeCommand", entries: orderedEntries(entries.values)
    ) {
      try await $0.registration.service.executeCommand(command)
    }
  }

  func shutdown() async throws {
    switch lifecycle {
    case .active:
      lifecycle = .shuttingDown
    case .shuttingDown:
      try await withCheckedThrowingContinuation { continuation in
        shutdownWaiters.append(continuation)
      }
      return
    case .shutDown(let previousError):
      if let previousError { throw previousError }
      return
    }

    var failures: [LanguageServiceID] = []
    for uri in documents.keys.sorted(by: { $0.absoluteString < $1.absoluteString }) {
      do { try await closeDocument(uri: uri) } catch {
        if let document = documents.removeValue(forKey: uri) {
          failures.append(contentsOf: document.serviceIDs)
        }
      }
    }
    for entry in orderedEntries(entries.values).reversed() {
      entry.diagnosticTask?.cancel()
      entry.messageTask?.cancel()
      do { try await entry.registration.shutdown() } catch {
        failures.append(entry.registration.id)
      }
    }
    entries.removeAll()
    completionRoutes.removeAll()
    documents.removeAll()

    let unique = Array(Set(failures)).sorted { $0.rawValue < $1.rawValue }
    let resultError: LanguageServiceRouterError? =
      unique.isEmpty
      ? nil
      : .shutdownFailures(unique)
    lifecycle = .shutDown(resultError)

    let waiters = shutdownWaiters
    shutdownWaiters.removeAll()
    for waiter in waiters {
      if let resultError { waiter.resume(throwing: resultError) } else { waiter.resume() }
    }
    if let resultError { throw resultError }
  }

  func cancelStreams() {
    for entry in entries.values {
      entry.diagnosticTask?.cancel()
      entry.messageTask?.cancel()
    }
  }

  private func ensureActive() throws {
    guard case .active = lifecycle else { throw LanguageServiceRouterError.shutdown }
  }

  private func selectedEntries(uri: URL, languageID: String) -> [Entry] {
    orderedEntries(
      entries.values.filter {
        $0.registration.selector.matches(uri: uri, languageID: languageID)
      })
  }

  private func entries(for document: Document) -> [Entry] {
    document.serviceIDs.compactMap { entries[$0] }
  }

  private func orderedIDs(_ ids: [LanguageServiceID]) -> [LanguageServiceID] {
    orderedEntries(ids.compactMap { entries[$0] }).map { $0.registration.id }
  }

  private func orderedEntries<S: Sequence>(_ values: S) -> [Entry] where S.Element == Entry {
    values.sorted { lhs, rhs in
      if lhs.registration.role != rhs.registration.role {
        return lhs.registration.role.rawValue < rhs.registration.role.rawValue
      }
      if lhs.registration.priority != rhs.registration.priority {
        return lhs.registration.priority > rhs.registration.priority
      }
      if lhs.order != rhs.order { return lhs.order < rhs.order }
      return lhs.registration.id.rawValue < rhs.registration.id.rawValue
    }
  }

  private func featureEntries(for uri: URL) throws -> [Entry] {
    guard let document = documents[uri] else {
      throw LanguageServiceRouterError.documentNotOpen(uri)
    }
    return entries(for: document)
  }

  private func merged<T: Hashable>(
    uri: URL,
    feature: String,
    operation: (Entry) async throws -> [T]
  ) async throws -> [T] {
    let selected = try featureEntries(for: uri)
    var result: [T] = []
    var seen: Set<T> = []
    for entry in selected {
      do {
        for value in try await operation(entry) where seen.insert(value).inserted {
          result.append(value)
        }
      } catch {
        if try shouldContinue(after: error, entry: entry, feature: feature) { continue }
      }
    }
    return result
  }

  private func firstSupported<T>(
    uri: URL,
    feature: String,
    operation: (Entry) async throws -> T
  ) async throws -> T {
    try await firstSupported(
      feature: feature, entries: featureEntries(for: uri), operation: operation)
  }

  private func firstSupported<T>(
    feature: String,
    entries selected: [Entry],
    operation: (Entry) async throws -> T
  ) async throws -> T {
    for entry in selected {
      do { return try await operation(entry) } catch {
        if try shouldContinue(after: error, entry: entry, feature: feature) { continue }
      }
    }
    throw LanguageFeatureError.unsupported(feature)
  }

  private func reportLifecycleFailure(operation: String, entry: Entry, error: Error) {
    messageContinuation.yield(
      LanguageServerMessage(
        kind: .warning,
        message:
          "Supplemental service failed during document \(operation): \(String(describing: error))",
        serviceIdentifier: entry.registration.id.rawValue
      )
    )
  }

  private func shouldContinue(after error: Error, entry: Entry, feature: String) throws -> Bool {
    if case LanguageFeatureError.unsupported = error { return true }
    guard entry.registration.role == .supplemental else { throw error }
    messageContinuation.yield(
      LanguageServerMessage(
        kind: .warning,
        message: "Supplemental service failed during \(feature): \(String(describing: error))",
        serviceIdentifier: entry.registration.id.rawValue
      ))
    return true
  }

  private func completionKey(_ completion: Completion) -> Completion {
    var key = completion
    key.resolutionID = nil
    key.serviceIdentifier = nil
    if var command = key.command {
      command.serviceIdentifier = nil
      key.command = command
    }
    return key
  }

  private func tagCompletion(
    _ completion: Completion,
    serviceID: LanguageServiceID,
    routeID: UUID?
  ) -> Completion {
    var tagged = completion
    tagged.resolutionID = routeID
    tagged.serviceIdentifier = serviceID.rawValue
    if var command = tagged.command {
      command.serviceIdentifier = serviceID.rawValue
      tagged.command = command
    }
    return tagged
  }

  private func lifecycleError(
    operation: String,
    service: LanguageServiceID,
    error: Error,
    recoveryFailures: [LanguageServiceID] = []
  ) -> LanguageServiceRouterError {
    .lifecycleFailure(
      operation: operation,
      service: service,
      reason: String(describing: error),
      recoveryFailures: Array(Set(recoveryFailures)).sorted { $0.rawValue < $1.rawValue }
    )
  }
}
