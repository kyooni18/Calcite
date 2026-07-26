import Foundation

/// Converts one-key-at-a-time editor input into complete Vim invocations.
///
/// The controller owns transient keyboard state such as counts, operators,
/// registers, mappings, command-line history, and insert-mode register input.
/// The engine remains responsible for document state and command semantics.
public final class VimKeymapController: @unchecked Sendable {
  public let engine: VimEngine
  public private(set) var pendingNotation = ""
  public private(set) var prompt: String?

  private enum PromptKind: Equatable {
    case command
    case search(forward: Bool)
  }

  private struct ResolvedMapping: Sendable {
    var invocation: VimInvocation
    var modes: Set<VimMode>?
    var recursive: Bool
  }

  private var promptKind: PromptKind?
  private var promptBuffer = ""
  private var promptHistoryIndex: Int?
  private var commandHistory: [String] = []
  private var searchHistory: [String] = []
  private var mappings: [String: ResolvedMapping] = [:]
  private var mappingPrefixes: Set<String> = []
  private var pendingInsertRegister = false
  private var mappingDepth = 0
  private let mappingRecursionLimit = 100

  public init(
    engine: VimEngine = VimEngine(),
    mappings: [VimKeyMapping] = []
  ) {
    self.engine = engine
    setMappings(mappings)
  }

  public func synchronize(text: String, cursor: Int? = nil) {
    engine.synchronize(text: text, cursor: cursor)
    resetPendingInput()
    cancelPrompt(restoringMode: false)
  }

  public func setMappings(_ values: [VimKeyMapping]) {
    mappings.removeAll(keepingCapacity: true)
    mappingPrefixes.removeAll(keepingCapacity: true)
    for mapping in values {
      let sequence = expandedSequence(mapping.sequence)
      guard !sequence.isEmpty, let invocation = invocation(for: mapping.command) else { continue }
      mappings[sequence] = ResolvedMapping(
        invocation: invocation,
        modes: mapping.modes,
        recursive: mapping.recursive
      )
      var prefix = ""
      for token in VimEngine.tokens(in: sequence) {
        prefix += token
        mappingPrefixes.insert(prefix)
      }
    }
  }

  public func resetPendingInput() {
    pendingNotation.removeAll(keepingCapacity: false)
    pendingInsertRegister = false
  }

  public func cancelPrompt() {
    cancelPrompt(restoringMode: true)
  }

  @discardableResult
  public func handle(token rawToken: String) throws -> VimKeyHandlingResult {
    guard !rawToken.isEmpty else { return VimKeyHandlingResult(consumed: false) }
    let token = normalizeToken(rawToken)

    if promptKind != nil { return try handlePromptToken(token) }

    if engine.state.mode == .insert || engine.state.mode == .replace {
      if pendingInsertRegister {
        defer { pendingInsertRegister = false }
        guard let register = VimEngine.register(for: token) else { throw VimError.invalidRegister }
        let execution = try engine.execute(.action(.insertRegister(register)))
        return VimKeyHandlingResult(consumed: true, execution: execution)
      }
      if token == "<C-r>" {
        resetPendingNotationOnly()
        pendingInsertRegister = true
        return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
      }
      return try handleMappedOrBuiltinToken(token)
    }

    if token == "<Esc>" || token == "<C-[>" {
      resetPendingInput()
      let execution = try engine.execute(.action(.escape))
      return VimKeyHandlingResult(consumed: true, execution: execution)
    }

    if token == ":" {
      beginPrompt(.command, prefix: ":")
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }
    if token == "/" {
      beginPrompt(.search(forward: true), prefix: "/")
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }
    if token == "?" {
      beginPrompt(.search(forward: false), prefix: "?")
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }

    return try handleMappedOrBuiltinToken(token)
  }

  private func handleMappedOrBuiltinToken(_ token: String) throws -> VimKeyHandlingResult {
    pendingNotation += token

    if let mapping = mappings[pendingNotation], mappingApplies(mapping) {
      resetPendingNotationOnly()
      let execution = try executeMapping(mapping)
      return VimKeyHandlingResult(consumed: true, execution: execution)
    }

    if hasApplicableMapping(withPrefix: pendingNotation) {
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }

    let complete = pendingNotation
    do {
      let execution = try engine.execute(.notation(complete))
      resetPendingNotationOnly()
      return VimKeyHandlingResult(consumed: true, execution: execution)
    } catch VimError.incompleteCommand {
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    } catch {
      resetPendingNotationOnly()
      throw error
    }
  }

  private func executeMapping(_ mapping: ResolvedMapping) throws -> VimExecutionResult {
    guard mappingDepth < mappingRecursionLimit else { throw VimError.macroRecursionLimit }
    mappingDepth += 1
    defer { mappingDepth -= 1 }

    guard mapping.recursive else { return try engine.execute(mapping.invocation) }
    switch mapping.invocation {
    case .notation(let notation), .keys(let notation):
      let beforeText = engine.state.text
      var hostRequests: [VimHostRequest] = []
      for token in VimEngine.tokens(in: notation) {
        let result = try handle(token: token)
        if let execution = result.execution {
          hostRequests += execution.hostRequests
        }
      }
      guard pendingNotation.isEmpty else { throw VimError.incompleteCommand(notation) }
      return VimExecutionResult(
        state: engine.state,
        hostRequests: hostRequests,
        didChangeText: beforeText != engine.state.text
      )
    default:
      return try engine.execute(mapping.invocation)
    }
  }

  private func mappingApplies(_ mapping: ResolvedMapping) -> Bool {
    mapping.modes?.contains(engine.state.mode) ?? true
  }

  private func hasApplicableMapping(withPrefix prefix: String) -> Bool {
    guard mappingPrefixes.contains(prefix) else { return false }
    return mappings.contains { sequence, mapping in
      sequence.hasPrefix(prefix) && mappingApplies(mapping)
    }
  }

  private func beginPrompt(_ kind: PromptKind, prefix: String) {
    resetPendingInput()
    promptKind = kind
    promptBuffer = ""
    promptHistoryIndex = nil
    prompt = prefix
    switch kind {
    case .command:
      _ = try? engine.execute(.action(.enterCommandLine))
    case .search:
      _ = try? engine.execute(.action(.enterSearch))
    }
  }

  private func cancelPrompt(restoringMode: Bool) {
    promptKind = nil
    promptBuffer = ""
    promptHistoryIndex = nil
    prompt = nil
    if restoringMode, engine.state.mode == .commandLine || engine.state.mode == .search {
      _ = try? engine.execute(.action(.escape))
    }
  }

  private func handlePromptToken(_ token: String) throws -> VimKeyHandlingResult {
    guard let kind = promptKind else { return VimKeyHandlingResult(consumed: false) }
    switch token {
    case "<Esc>", "<C-[>":
      cancelPrompt(restoringMode: true)
      return VimKeyHandlingResult(
        consumed: true, execution: VimExecutionResult(state: engine.state))

    case "<BS>", "<C-h>":
      if !promptBuffer.isEmpty { promptBuffer.removeLast() }
      promptHistoryIndex = nil
      updatePromptDisplay(kind)
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)

    case "<C-w>":
      removeLastPromptWord()
      promptHistoryIndex = nil
      updatePromptDisplay(kind)
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)

    case "<C-u>":
      promptBuffer.removeAll(keepingCapacity: true)
      promptHistoryIndex = nil
      updatePromptDisplay(kind)
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)

    case "<Up>", "<C-p>":
      movePromptHistory(kind, delta: -1)
      updatePromptDisplay(kind)
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)

    case "<Down>", "<C-n>":
      movePromptHistory(kind, delta: 1)
      updatePromptDisplay(kind)
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)

    case "<CR>":
      let value = promptBuffer
      appendPromptHistory(value, kind: kind)
      cancelPrompt(restoringMode: true)
      guard !value.isEmpty else {
        return VimKeyHandlingResult(
          consumed: true, execution: VimExecutionResult(state: engine.state))
      }
      let execution: VimExecutionResult
      switch kind {
      case .command:
        execution = try engine.execute(.ex(value))
      case .search(let forward):
        execution = try engine.execute(.action(.search(value, forward: forward)))
      }
      return VimKeyHandlingResult(consumed: true, execution: execution)

    default:
      guard !token.hasPrefix("<") else {
        return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
      }
      promptBuffer += token
      promptHistoryIndex = nil
      updatePromptDisplay(kind)
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }
  }

  private func appendPromptHistory(_ value: String, kind: PromptKind) {
    guard !value.isEmpty else { return }
    switch kind {
    case .command:
      if commandHistory.last != value { commandHistory.append(value) }
    case .search:
      if searchHistory.last != value { searchHistory.append(value) }
    }
  }

  private func movePromptHistory(_ kind: PromptKind, delta: Int) {
    let history: [String]
    switch kind {
    case .command: history = commandHistory
    case .search: history = searchHistory
    }
    guard !history.isEmpty else { return }
    let current = promptHistoryIndex ?? history.count
    let next = max(0, min(history.count, current + delta))
    promptHistoryIndex = next == history.count ? nil : next
    promptBuffer = next == history.count ? "" : history[next]
  }

  private func removeLastPromptWord() {
    while promptBuffer.last?.isWhitespace == true { promptBuffer.removeLast() }
    while let last = promptBuffer.last, !last.isWhitespace { promptBuffer.removeLast() }
  }

  private func updatePromptDisplay(_ kind: PromptKind) {
    switch kind {
    case .command: prompt = ":" + promptBuffer
    case .search(let forward): prompt = (forward ? "/" : "?") + promptBuffer
    }
  }

  private func expandedSequence(_ sequence: String) -> String {
    sequence
      .replacingOccurrences(of: "<leader>", with: engine.leader, options: .caseInsensitive)
      .replacingOccurrences(
        of: "<localleader>",
        with: engine.localLeader,
        options: .caseInsensitive
      )
  }

  private func invocation(for rawCommand: String) -> VimInvocation? {
    let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return nil }
    if command.hasPrefix(":") { return .ex(command) }
    if command.hasPrefix("<host:"), command.hasSuffix(">") {
      let name = String(command.dropFirst(6).dropLast())
      return name.isEmpty ? nil : .action(.host(.custom(name)))
    }
    return .notation(command)
  }

  private func normalizeToken(_ token: String) -> String {
    VimEngine.tokens(in: token).first ?? token
  }

  private func resetPendingNotationOnly() {
    pendingNotation.removeAll(keepingCapacity: false)
  }
}
