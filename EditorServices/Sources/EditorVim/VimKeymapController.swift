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
/// share one typed token queue, so ambiguous mappings, native Vim prefixes, physical
/// key positions, and committed text are resolved through one path.
public final class VimKeymapController: @unchecked Sendable {
  public let engine: VimEngine

  private let lock = NSRecursiveLock()
  private var storedPendingNotation = ""
  private var storedPrompt: String?
  private var storedInputPolicy: VimCommandKeyboardPolicy = .automatic
  private var storedLanguageMap: [Character: Character] = [:]

  public private(set) var pendingNotation: String {
    get { lock.withLock { storedPendingNotation } }
    set { lock.withLock { storedPendingNotation = newValue } }
  }

  public private(set) var prompt: String? {
    get { lock.withLock { storedPrompt } }
    set { lock.withLock { storedPrompt = newValue } }
  }

  @_spi(Calcite)
  public var inputPolicy: VimCommandKeyboardPolicy {
    get { lock.withLock { storedInputPolicy } }
    set {
      lock.withLock {
        storedInputPolicy = newValue
        resetPendingInputUnlocked()
      }
    }
  }

  @_spi(Calcite)
  public var expectedInput: VimExpectedInput {
    lock.withLock { expectedInputUnlocked }
  }

  @_spi(Calcite)
  public var isPromptActive: Bool {
    lock.withLock { promptKind != nil }
  }

  @_spi(Calcite)
  public var isComposingText: Bool {
    lock.withLock { compositionIsActive }
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
  private var compositionIsActive = false
  private var compositionText = ""
  private var compositionSelection = 0..<0

  private let mappingTrie = VimMappingTrie()
  private var pendingTokens: [VimInputToken] = []
  private var commandTokens: [VimInputToken] = []
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
        mapping -> (tokens: [VimInputToken], invocation: VimInvocation)? in
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

  @_spi(Calcite)
  public func setLanguageMap(_ values: [Character: Character]) {
    lock.withLock {
      storedLanguageMap = values
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
    try lock.withLock {
      try engine.lock.withLock {
        try engine.withExecutionBatch {
          try handleUnlocked(token: VimInputToken(notationToken: token))
        }
      }
    }
  }

  @_spi(Calcite)
  @discardableResult
  public func handle(event: VimInputEvent) throws -> VimKeyHandlingResult {
    try lock.withLock {
      try engine.lock.withLock {
        try engine.withExecutionBatch {
          try handleUnlocked(event: event)
        }
      }
    }
  }

  private func handleUnlocked(event: VimInputEvent) throws -> VimKeyHandlingResult {
    switch event {
    case .mappingTimeout:
      return try flushPendingInput()
    case .compositionStarted:
      compositionIsActive = true
      compositionText = ""
      compositionSelection = 0..<0
      refreshPromptDisplayIfNeeded()
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    case .compositionUpdated(let text, let selectedRange):
      compositionIsActive = true
      compositionText = text
      compositionSelection = selectedRange
      refreshPromptDisplayIfNeeded()
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    case .compositionCommitted(let text):
      clearCompositionUnlocked()
      return try handleCommittedTextUnlocked(text)
    case .compositionCancelled:
      let consumed = compositionIsActive
      clearCompositionUnlocked()
      refreshPromptDisplayIfNeeded()
      return VimKeyHandlingResult(
        consumed: consumed,
        awaitingMoreInput: promptKind != nil || commandParser.isIncomplete
      )
    case .textCommit(let text, _):
      clearCompositionUnlocked()
      return try handleCommittedTextUnlocked(text)
    case .key(let stroke):
      if case .special(.escape) = stroke.physicalKey, compositionIsActive {
        clearCompositionUnlocked()
        refreshPromptDisplayIfNeeded()
        return VimKeyHandlingResult(
          consumed: true,
          awaitingMoreInput: promptKind != nil || commandParser.isIncomplete
        )
      }
      guard let token = token(for: stroke) else {
        return VimKeyHandlingResult(consumed: false)
      }
      return try handleUnlocked(token: token)
    }
  }

  private func handleCommittedTextUnlocked(_ text: String) throws -> VimKeyHandlingResult {
    guard !text.isEmpty else {
      return VimKeyHandlingResult(
        consumed: compositionIsActive,
        awaitingMoreInput: promptKind != nil || commandParser.isIncomplete
      )
    }

    if let kind = promptKind {
      let characters = Array(text)
      promptBuffer.insert(contentsOf: characters, at: promptCursor)
      promptCursor += characters.count
      updatePromptDisplay(kind)
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }

    let mode = engine.state.mode
    if mode == .insert || mode == .replace {
      resetPendingInputUnlocked()
      let execution = try engine.execute(.action(.insert(text)))
      return VimKeyHandlingResult(consumed: true, execution: execution)
    }

    var aggregate: VimExecutionResult?
    var awaiting = false
    for character in text {
      let result = try handleUnlocked(token: VimInputToken(kind: .text(String(character))))
      if let execution = result.execution {
        aggregate = aggregate.map { Self.merged($0, execution) } ?? execution
      }
      awaiting = result.awaitingMoreInput
    }
    return VimKeyHandlingResult(
      consumed: true,
      awaitingMoreInput: awaiting,
      execution: aggregate
    )
  }

  private func handleUnlocked(token: VimInputToken) throws -> VimKeyHandlingResult {
    let notation = token.notation
    guard !notation.isEmpty else { return VimKeyHandlingResult(consumed: false) }

    if promptKind != nil { return try handlePromptToken(token) }
    if notation.lowercased() == "<timeout>" { return try flushPendingInput() }

    let mode = engine.state.mode
    if mode == .insert || mode == .replace {
      pendingTokens.removeAll(keepingCapacity: true)
      commandTokens.removeAll(keepingCapacity: true)
      commandParser.reset()
      let execution = try engine.executeNotationToken(notation, parser: &commandParser)
      refreshPendingNotation()
      return VimKeyHandlingResult(
        consumed: true,
        awaitingMoreInput: commandParser.isIncomplete,
        execution: execution
      )
    }

    if case .special(.escape) = token.kind {
      resetPendingInputUnlocked()
      return VimKeyHandlingResult(
        consumed: true,
        execution: try engine.execute(.notation("<Esc>"))
      )
    }

    if token.text == ":" {
      beginPrompt(.command, prefix: engine.prepareVisualExRange() ?? ":")
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }
    if token.text == "/" {
      beginPrompt(.search(forward: true), prefix: "/")
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }
    if token.text == "?" {
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
      var awaiting = false
      for token in remainder {
        let next = try handleUnlocked(token: token)
        if let value = next.execution {
          execution = execution.map { Self.merged($0, value) } ?? value
        }
        awaiting = next.awaitingMoreInput
      }
      return VimKeyHandlingResult(
        consumed: true,
        awaitingMoreInput: awaiting || !pendingTokens.isEmpty || commandParser.isIncomplete,
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
        let execution = try engine.executeNotationToken(token.notation, parser: &commandParser)
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
    let initial = prefix == ":'<,'>" ? "'<,'>" : ""
    promptBuffer = Array(initial)
    promptCursor = promptBuffer.count
    historyIndex = nil
    clearCompositionUnlocked()
    storedPrompt = prefix
  }

  private func handlePromptToken(_ token: VimInputToken) throws -> VimKeyHandlingResult {
    guard let kind = promptKind else { return VimKeyHandlingResult(consumed: false) }
    let notation = token.notation.lowercased()
    switch notation {
    case "<esc>", "<c-[>":
      if compositionIsActive {
        clearCompositionUnlocked()
        updatePromptDisplay(kind)
        return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
      }
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
      guard let text = token.text else {
        updatePromptDisplay(kind)
        return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
      }
      let characters = Array(text)
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
    let before = String(promptBuffer[..<promptCursor])
    let after = String(promptBuffer[promptCursor...])
    let composing = compositionIsActive ? compositionText : ""
    storedPrompt = prefix + before + composing + after
  }

  private func refreshPromptDisplayIfNeeded() {
    guard let kind = promptKind else { return }
    updatePromptDisplay(kind)
  }

  private func clearCompositionUnlocked() {
    compositionIsActive = false
    compositionText = ""
    compositionSelection = 0..<0
  }

  private var expectedInputUnlocked: VimExpectedInput {
    if promptKind != nil { return .promptText }
    let mode = engine.state.mode
    if mode == .insert || mode == .replace { return .literalCharacter }
    if commandParser.pendingFind != nil { return .literalCharacter }
    if commandParser.pendingReplace { return .replacementCharacter }
    if commandParser.pendingRegister || commandParser.pendingMacro
      || commandParser.pendingMacroStart
    {
      return .registerName
    }
    if commandParser.pendingMark || commandParser.pendingJump != nil { return .markName }
    return .command
  }

  private func token(for stroke: VimKeyStroke) -> VimInputToken? {
    if case .special(let special) = stroke.physicalKey { return special.token }

    let expected = expectedInputUnlocked
    let usesCommandIdentity: Bool
    switch expected {
    case .command, .registerName, .markName:
      usesCommandIdentity = true
    case .literalCharacter, .replacementCharacter, .promptText:
      usesCommandIdentity = false
    }

    let logical = stroke.logicalText ?? stroke.textIgnoringModifiers
    let selectedText: String?
    if usesCommandIdentity {
      switch storedInputPolicy {
      case .automatic, .physicalUS:
        selectedText = physicalText(for: stroke) ?? logical
      case .logical:
        selectedText = logical
      case .languageMap:
        selectedText = logical.map(applyingLanguageMap)
      }
    } else {
      selectedText = logical
    }

    guard let selectedText, !selectedText.isEmpty else { return nil }
    if stroke.modifiers.contains(.control) {
      guard let character = selectedText.lowercased().first else { return nil }
      return VimInputToken(kind: .modified(.control, String(character)))
    }
    if stroke.modifiers.contains(.option), usesCommandIdentity {
      return VimInputToken(kind: .modified(.option, selectedText))
    }
    return VimInputToken(kind: .text(selectedText))
  }

  private func physicalText(for stroke: VimKeyStroke) -> String? {
    guard case .character(let unshifted, let shifted) = stroke.physicalKey else { return nil }
    if stroke.modifiers.contains(.shift), let shifted { return String(shifted) }
    return String(unshifted)
  }

  private func applyingLanguageMap(to value: String) -> String {
    String(value.map { storedLanguageMap[$0] ?? $0 })
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
    storedPendingNotation = (commandTokens + pendingTokens).map(\.notation).joined()
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
    clearCompositionUnlocked()
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

  private static func tokens(in notation: String) -> [VimInputToken] {
    VimCommandParser.tokens(in: notation).map(VimInputToken.init(notationToken:))
  }
}
