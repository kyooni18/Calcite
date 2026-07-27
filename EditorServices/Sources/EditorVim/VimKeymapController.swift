import Foundation

public struct VimKeyMapping: Hashable, Sendable {
  public var sequence: String
  public var command: String

  public init(sequence: String, command: String) {
    self.sequence = sequence
    self.command = command
  }
}

public struct VimKeyHandlingResult: Sendable {
  public var consumed: Bool
  public var awaitingMoreInput: Bool
  public var execution: VimExecutionResult?

  public init(
    consumed: Bool,
    awaitingMoreInput: Bool = false,
    execution: VimExecutionResult? = nil
  ) {
    self.consumed = consumed
    self.awaitingMoreInput = awaitingMoreInput
    self.execution = execution
  }
}

/// Converts one-key-at-a-time editor input into complete Vim invocations.
///
/// The controller owns transient keyboard state. Built-in commands and user mappings
/// share one token queue, so ambiguous mappings, mapping remainders, and native Vim
/// prefixes are resolved through the same path.
public final class VimKeymapController: @unchecked Sendable {
  public let engine: VimEngine

  private let lock = NSRecursiveLock()
  private var storedPendingNotation = ""
  private var storedPrompt: String?

  public private(set) var pendingNotation: String {
    get { lock.withLock { storedPendingNotation } }
    set { lock.withLock { storedPendingNotation = newValue } }
  }

  public private(set) var prompt: String? {
    get { lock.withLock { storedPrompt } }
    set { lock.withLock { storedPrompt = newValue } }
  }

  private enum PromptKind {
    case command
    case search(forward: Bool)
  }

  private var promptKind: PromptKind?
  private var promptBuffer: [Character] = []
  private var promptCursor = 0
  private var commandHistory: [String] = []
  private var searchHistory: [String] = []
  private var historyIndex: Int?

  private let mappingTrie = VimMappingTrie()
  private var pendingTokens: [String] = []
  private var commandTokens: [String] = []
  private var commandParser = VimCommandParser()
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
    lock.withLock {
      resetPendingInputUnlocked()
      cancelPromptUnlocked()
      engine.synchronize(text: text, cursor: cursor)
    }
  }

  public func setMappings(_ values: [VimKeyMapping]) {
    lock.withLock {
      let resolved = values.compactMap {
        mapping -> (tokens: [String], invocation: VimInvocation)? in
        let sequence = expandedSequence(mapping.sequence)
        guard !sequence.isEmpty, let invocation = invocation(for: mapping.command) else {
          return nil
        }
        return (Self.tokens(in: sequence), invocation)
      }
      mappingTrie.replace(with: resolved)
      resetPendingInputUnlocked()
    }
  }

  public func resetPendingInput() {
    lock.withLock { resetPendingInputUnlocked() }
  }

  public func cancelPrompt() {
    lock.withLock { cancelPromptUnlocked() }
  }

  @discardableResult
  public func handle(token: String) throws -> VimKeyHandlingResult {
<<<<<<< HEAD
    try lock.withLock {
      try engine.lock.withLock {
        try engine.withExecutionBatch {
          try handleUnlocked(token: token)
        }
      }
    }
=======
    try lock.withLock { try handleUnlocked(token: token) }
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
  }

  private func handleUnlocked(token: String) throws -> VimKeyHandlingResult {
    guard !token.isEmpty else { return VimKeyHandlingResult(consumed: false) }

    if promptKind != nil { return try handlePromptToken(token) }
    if token.lowercased() == "<timeout>" { return try flushPendingInput() }

    let mode = engine.state.mode
    if mode == .insert || mode == .replace {
      pendingTokens.removeAll(keepingCapacity: true)
      commandTokens.removeAll(keepingCapacity: true)
      commandParser.reset()
      let normalized = token.lowercased() == "<c-[>" ? "<Esc>" : token
      let execution = try engine.executeNotationToken(normalized, parser: &commandParser)
      refreshPendingNotation()
      return VimKeyHandlingResult(
        consumed: true,
        awaitingMoreInput: commandParser.isIncomplete,
        execution: execution
      )
    }

    if token.lowercased() == "<esc>" {
      resetPendingInputUnlocked()
      return VimKeyHandlingResult(
        consumed: true,
        execution: try engine.execute(.notation("<Esc>"))
      )
    }

    if token == ":" {
<<<<<<< HEAD
      beginPrompt(.command, prefix: engine.prepareVisualExRange() ?? ":")
=======
      beginPrompt(.command, prefix: ":")
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
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

    pendingTokens.append(token)
    refreshPendingNotation()
    return try resolvePendingInput()
  }

  private func resolvePendingInput() throws -> VimKeyHandlingResult {
    let match = mappingTrie.match(pendingTokens)
    if let exact = match.exact, !match.isPrefix {
      pendingTokens.removeAll(keepingCapacity: true)
      refreshPendingNotation()
      return VimKeyHandlingResult(
        consumed: true,
        execution: try executeMapped(exact)
      )
    }
    if match.isPrefix {
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }

    if let fallback = mappingTrie.longestExactPrefix(in: pendingTokens) {
      let remainder = Array(pendingTokens.dropFirst(fallback.length))
      pendingTokens.removeAll(keepingCapacity: true)
      refreshPendingNotation()
      var execution = try executeMapped(fallback.invocation)
      for token in remainder {
        let next = try handleUnlocked(token: token)
        if let value = next.execution {
          execution = execution.map { Self.merged($0, value) } ?? value
        }
      }
      return VimKeyHandlingResult(
        consumed: true,
        awaitingMoreInput: !pendingTokens.isEmpty || commandParser.isIncomplete,
        execution: execution
      )
    }

    return try feedPendingTokensToBuiltinParser()
  }

  private func flushPendingInput() throws -> VimKeyHandlingResult {
    guard !pendingTokens.isEmpty else {
      refreshPendingNotation()
      return VimKeyHandlingResult(
        consumed: commandParser.isIncomplete,
        awaitingMoreInput: commandParser.isIncomplete
      )
    }
    let match = mappingTrie.match(pendingTokens)
    if let exact = match.exact {
      pendingTokens.removeAll(keepingCapacity: true)
      refreshPendingNotation()
      return VimKeyHandlingResult(consumed: true, execution: try executeMapped(exact))
    }

    return try feedPendingTokensToBuiltinParser()
  }

  private func feedPendingTokensToBuiltinParser() throws -> VimKeyHandlingResult {
    guard !pendingTokens.isEmpty else {
      refreshPendingNotation()
      return VimKeyHandlingResult(
        consumed: false,
        awaitingMoreInput: commandParser.isIncomplete
      )
    }

    let tokens = pendingTokens
    pendingTokens.removeAll(keepingCapacity: true)
    var aggregate: VimExecutionResult?
    do {
      for token in tokens {
        commandTokens.append(token)
        let execution = try engine.executeNotationToken(token, parser: &commandParser)
        aggregate = aggregate.map { Self.merged($0, execution) } ?? execution
        if commandParser.isAtCommandBoundary {
          commandTokens.removeAll(keepingCapacity: true)
        }
      }
    } catch {
      commandParser.reset()
      commandTokens.removeAll(keepingCapacity: true)
      refreshPendingNotation()
      throw error
    }

    refreshPendingNotation()
    return VimKeyHandlingResult(
      consumed: true,
      awaitingMoreInput: commandParser.isIncomplete,
      execution: aggregate
    )
  }

  private func executeMapped(_ invocation: VimInvocation) throws -> VimExecutionResult? {
    guard mappingDepth < mappingRecursionLimit else { throw VimError.macroRecursionLimit }
    mappingDepth += 1
    defer { mappingDepth -= 1 }

    switch invocation {
    case .keys(let notation), .notation(let notation):
      var aggregate: VimExecutionResult?
      for token in Self.tokens(in: notation) {
        let handled = try handleUnlocked(token: token)
        if let execution = handled.execution {
          aggregate = aggregate.map { Self.merged($0, execution) } ?? execution
        }
      }
      return aggregate
    default:
      return try engine.execute(invocation)
    }
  }

  private func beginPrompt(_ kind: PromptKind, prefix: String) {
    resetPendingInputUnlocked()
    promptKind = kind
<<<<<<< HEAD
    let initial = prefix == ":'<,'>" ? "'<,'>" : ""
    promptBuffer = Array(initial)
    promptCursor = promptBuffer.count
=======
    promptBuffer = []
    promptCursor = 0
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
    historyIndex = nil
    storedPrompt = prefix
  }

  private func handlePromptToken(_ token: String) throws -> VimKeyHandlingResult {
    guard let kind = promptKind else { return VimKeyHandlingResult(consumed: false) }
    switch token.lowercased() {
    case "<esc>", "<c-[>":
      cancelPromptUnlocked()
      return VimKeyHandlingResult(consumed: true)
    case "<left>":
      promptCursor = max(0, promptCursor - 1)
    case "<right>":
      promptCursor = min(promptBuffer.count, promptCursor + 1)
    case "<home>", "<c-b>":
      promptCursor = 0
    case "<end>", "<c-e>":
      promptCursor = promptBuffer.count
    case "<bs>", "<backspace>":
      if promptCursor > 0 {
        promptCursor -= 1
        promptBuffer.remove(at: promptCursor)
      }
    case "<del>", "<delete>":
      if promptCursor < promptBuffer.count { promptBuffer.remove(at: promptCursor) }
    case "<c-u>":
      promptBuffer.removeSubrange(0..<promptCursor)
      promptCursor = 0
    case "<c-w>":
      deletePromptWordBeforeCursor()
    case "<up>":
      recallHistory(kind: kind, delta: -1)
    case "<down>":
      recallHistory(kind: kind, delta: 1)
    case "<cr>", "<enter>":
      let value = String(promptBuffer)
      if !value.isEmpty { appendHistory(value, kind: kind) }
      cancelPromptUnlocked()
      guard !value.isEmpty else { return VimKeyHandlingResult(consumed: true) }
      let result: VimExecutionResult
      switch kind {
      case .command:
        result = try engine.execute(.ex(value))
      case .search(let forward):
        result = try engine.execute(.action(.search(value, forward: forward)))
      }
      return VimKeyHandlingResult(consumed: true, execution: result)
    default:
      guard !token.hasPrefix("<") else {
        updatePromptDisplay(kind)
        return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
      }
      let characters = Array(token)
      promptBuffer.insert(contentsOf: characters, at: promptCursor)
      promptCursor += characters.count
    }
    updatePromptDisplay(kind)
    return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
  }

  private func deletePromptWordBeforeCursor() {
    while promptCursor > 0, promptBuffer[promptCursor - 1].isWhitespace {
      promptCursor -= 1
      promptBuffer.remove(at: promptCursor)
    }
    while promptCursor > 0, !promptBuffer[promptCursor - 1].isWhitespace {
      promptCursor -= 1
      promptBuffer.remove(at: promptCursor)
    }
  }

  private func appendHistory(_ value: String, kind: PromptKind) {
    switch kind {
    case .command:
      if commandHistory.last != value { commandHistory.append(value) }
    case .search:
      if searchHistory.last != value { searchHistory.append(value) }
    }
  }

  private func recallHistory(kind: PromptKind, delta: Int) {
    let history: [String]
    switch kind {
    case .command: history = commandHistory
    case .search: history = searchHistory
    }
    guard !history.isEmpty else { return }
    let current = historyIndex ?? history.count
    let next = max(0, min(history.count, current + delta))
    historyIndex = next
    promptBuffer = next == history.count ? [] : Array(history[next])
    promptCursor = promptBuffer.count
  }

  private func updatePromptDisplay(_ kind: PromptKind) {
    let prefix: String
    switch kind {
    case .command: prefix = ":"
    case .search(let forward): prefix = forward ? "/" : "?"
    }
    storedPrompt = prefix + String(promptBuffer)
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

  private func refreshPendingNotation() {
    storedPendingNotation = (commandTokens + pendingTokens).joined()
  }

  private func resetPendingInputUnlocked() {
    pendingTokens.removeAll(keepingCapacity: true)
    commandTokens.removeAll(keepingCapacity: true)
    commandParser.reset()
    storedPendingNotation.removeAll(keepingCapacity: true)
  }

  private func cancelPromptUnlocked() {
    promptKind = nil
    promptBuffer.removeAll(keepingCapacity: true)
    promptCursor = 0
    historyIndex = nil
    storedPrompt = nil
  }

  private static func merged(
    _ first: VimExecutionResult,
    _ second: VimExecutionResult
  ) -> VimExecutionResult {
    VimExecutionResult(
      state: second.state,
      hostRequests: first.hostRequests + second.hostRequests,
      didChangeText: first.didChangeText || second.didChangeText
    )
  }

  private static func tokens(in notation: String) -> [String] {
    VimCommandParser.tokens(in: notation)
  }
}
