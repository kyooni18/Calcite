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
  private var storedMessage: VimMessage?
  private var storedConfigurationSignature: String?

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

  @_spi(Calcite)
  public var interactionSnapshot: VimInteractionSnapshot {
    lock.withLock {
      engine.lock.withLock { interactionSnapshotUnlocked() }
    }
  }

  @_spi(Calcite)
  public var historySnapshot: VimHistorySnapshot {
    lock.withLock { VimHistorySnapshot(commands: commandHistory, searches: searchHistory) }
  }

  @_spi(Calcite)
  public func restoreHistory(_ snapshot: VimHistorySnapshot) {
    lock.withLock {
      historyStorage.merge(snapshot)
      historyIndex = nil
      historySearchPrefix = nil
    }
  }

  private enum PromptKind {
    case command
    case search(forward: Bool)
  }

  private var promptKind: PromptKind?
  private var promptBuffer: [Character] = []
  private var promptCursor = 0
  private let historyStorage: VimCommandLineHistoryStorage
  private var commandHistory: [String] {
    get { historyStorage.commands }
    set { historyStorage.commands = newValue }
  }
  private var searchHistory: [String] {
    get { historyStorage.searches }
    set { historyStorage.searches = newValue }
  }
  private var historyIndex: Int?
  private var historySearchPrefix: String?
  private var compositionIsActive = false
  private var compositionText = ""
  private var compositionSelection = 0..<0

  private var mappingTries: [VimMappingKey: VimMappingTrie] = [:]
  private var storedMappingConflicts: [VimMappingConflict] = []
  private var pendingTokens: [VimInputToken] = []
  private var pendingInputDomain: VimMappingInputDomain?
  private var commandTokens: [VimInputToken] = []
  private var commandParser = VimCommandParser()
  private var mappingDepth = 0
  private let mappingRecursionLimit = 100

  public convenience init(
    engine: VimEngine = VimEngine(),
    mappings: [VimKeyMapping] = []
  ) {
    self.init(
      engine: engine,
      mappings: mappings,
      historyStorage: engine.globalStateStorage.history
    )
  }

  init(
    engine: VimEngine,
    mappings: [VimKeyMapping] = [],
    historyStorage: VimCommandLineHistoryStorage
  ) {
    self.engine = engine
    self.historyStorage = historyStorage
    setMappings(mappings)
  }

  public func synchronize(text: String, cursor: Int? = nil) {
    lock.withLock {
      resetPendingInputUnlocked()
      cancelPromptUnlocked()
      engine.synchronize(text: text, cursor: cursor)
    }
  }

  /// Applies host configuration once per semantic signature. A recreated
  /// SwiftUI/AppKit bridge can safely call this with the same signature without
  /// clearing pending mappings, operators, counts, registers, or prompts.
  @_spi(Calcite)
  @discardableResult
  public func applyConfiguration(
    signature: String,
    leader: String,
    localLeader: String,
    tabWidth: Int,
    startInInsertMode: Bool,
    inputPolicy: VimCommandKeyboardPolicy,
    languageMap: [Character: Character],
    mappings: [VimKeyMappingV2]
  ) -> Bool {
    lock.withLock {
      guard storedConfigurationSignature != signature else { return false }
      let isInitialConfiguration = storedConfigurationSignature == nil
      engine.leader = leader
      engine.localLeader = localLeader
      engine.tabWidth = max(1, tabWidth)
      storedInputPolicy = inputPolicy
      storedLanguageMap = languageMap
      setMappings(mappings)
      if isInitialConfiguration, startInInsertMode, engine.state.mode == .normal {
        _ = try? engine.execute(.action(.enterInsert))
      }
      storedConfigurationSignature = signature
      return true
    }
  }

  /// Accepts a native cursor movement without treating it as a document
  /// replacement. This deliberately cancels parser/prompt state while keeping
  /// Insert and Replace modes intact inside the engine.
  @_spi(Calcite)
  @discardableResult
  public func acceptHostCursorMove(
    toUTF16Offset offset: Int,
    source: VimHostCursorMoveSource
  ) -> VimState {
    lock.withLock {
      resetPendingInputUnlocked()
      cancelPromptUnlocked()
      return engine.acceptHostCursorMove(toUTF16Offset: offset, source: source)
    }
  }

  @_spi(Calcite)
  @discardableResult
  public func reconcileExternalText(
    _ text: String,
    cursor: Int? = nil
  ) -> VimExternalReconciliationResult {
    lock.withLock {
      resetPendingInputUnlocked()
      cancelPromptUnlocked()
      let result = engine.reconcileExternalText(text, cursor: cursor)
      if case .cancelledConflict(let message) = result {
        storedMessage = message
      }
      return result
    }
  }

  public func setMappings(_ values: [VimKeyMapping]) {
    setMappings(
      values.map {
        VimKeyMappingV2(
          sequence: $0.sequence,
          command: $0.command,
          modes: [.normal, .visual, .operatorPending],
          recursive: true,
          nowait: false,
          inputDomain: .command
        )
      }
    )
  }

  @_spi(Calcite)
  public var mappingConflicts: [VimMappingConflict] {
    lock.withLock { storedMappingConflicts }
  }

  @_spi(Calcite)
  public func setMappings(_ values: [VimKeyMappingV2]) {
    lock.withLock {
      var grouped: [VimMappingKey: [(tokens: [VimInputToken], mapping: VimResolvedMapping)]] = [:]
      var seen: [VimMappingKey: Set<[VimInputToken]>] = [:]
      var conflicts: [VimMappingConflict] = []

      for value in values {
        let sequence = expandedSequence(value.sequence)
        guard !sequence.isEmpty, let invocation = invocation(for: value.command) else { continue }
        let tokens = Self.tokens(in: sequence)
        guard !tokens.isEmpty else { continue }
        let mapping = VimResolvedMapping(
          invocation: invocation,
          recursive: value.recursive,
          nowait: value.nowait,
          inputDomain: value.inputDomain
        )
        for mode in value.modes {
          let key = VimMappingKey(mode: mode, inputDomain: value.inputDomain)
          if seen[key, default: []].contains(tokens) {
            conflicts.append(
              VimMappingConflict(
                sequence: value.sequence,
                mode: mode,
                inputDomain: value.inputDomain
              )
            )
          }
          seen[key, default: []].insert(tokens)
          grouped[key, default: []].append((tokens: tokens, mapping: mapping))
        }
      }

      var replacements: [VimMappingKey: VimMappingTrie] = [:]
      for mode in VimMappingMode.allCases {
        for inputDomain in VimMappingInputDomain.allCases {
          let key = VimMappingKey(mode: mode, inputDomain: inputDomain)
          let trie = VimMappingTrie()
          trie.replace(with: grouped[key] ?? [])
          replacements[key] = trie
        }
      }
      mappingTries = replacements
      storedMappingConflicts = conflicts
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
        expireMessageForNextInputUnlocked()
        let result = try engine.executeKeyHandlingTransaction {
          try handleUnlocked(token: VimInputToken(notationToken: token))
        }
        collectEngineMessageUnlocked()
        return result
      }
    }
  }

  @_spi(Calcite)
  @discardableResult
  public func handle(event: VimInputEvent) throws -> VimKeyHandlingResult {
    try lock.withLock {
      try engine.lock.withLock {
        expireMessageForNextInputUnlocked()
        let result = try engine.executeKeyHandlingTransaction {
          try handleUnlocked(event: event)
        }
        collectEngineMessageUnlocked()
        return result
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
      if promptKind != nil, stroke.modifiers.contains(.option) {
        switch stroke.physicalKey {
        case .special(.left):
          return try handleUnlocked(
            token: VimInputToken(kind: .modified(.option, "Left")),
            inputDomain: .command
          )
        case .special(.right):
          return try handleUnlocked(
            token: VimInputToken(kind: .modified(.option, "Right")),
            inputDomain: .command
          )
        default:
          break
        }
      }
      guard let token = token(for: stroke) else {
        return VimKeyHandlingResult(consumed: false)
      }
      return try handleUnlocked(token: token, inputDomain: .command)
    }
  }

  private func handleCommittedTextUnlocked(_ text: String) throws -> VimKeyHandlingResult {
    guard !text.isEmpty else {
      return VimKeyHandlingResult(
        consumed: compositionIsActive,
        awaitingMoreInput: promptKind != nil || commandParser.isIncomplete
      )
    }

    var aggregate: VimExecutionResult?
    var awaiting = false
    for character in text {
      let result = try handleUnlocked(
        token: VimInputToken(kind: .text(String(character))),
        inputDomain: .logicalText
      )
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

  private func handleUnlocked(
    token: VimInputToken,
    inputDomain: VimMappingInputDomain = .command
  ) throws -> VimKeyHandlingResult {
    let notation = token.notation
    guard !notation.isEmpty else { return VimKeyHandlingResult(consumed: false) }

    if notation.lowercased() == "<timeout>" { return try flushPendingInput() }
    if promptKind != nil {
      return try enqueuePendingToken(token, inputDomain: inputDomain)
    }

    let mode = engine.state.mode
    if mode == .insert || mode == .replace {
      return try enqueuePendingToken(token, inputDomain: inputDomain)
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
    if token.text == "/", commandParser.isAtCommandBoundary {
      beginPrompt(.search(forward: true), prefix: "/")
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }
    if token.text == "?", commandParser.isAtCommandBoundary {
      beginPrompt(.search(forward: false), prefix: "?")
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }

    return try enqueuePendingToken(token, inputDomain: inputDomain)
  }

  private func enqueuePendingToken(
    _ token: VimInputToken,
    inputDomain: VimMappingInputDomain
  ) throws -> VimKeyHandlingResult {
    if let pendingInputDomain, pendingInputDomain != inputDomain, !pendingTokens.isEmpty {
      let flushed = try flushPendingInput()
      let next = try enqueuePendingToken(token, inputDomain: inputDomain)
      return VimKeyHandlingResult(
        consumed: flushed.consumed || next.consumed,
        awaitingMoreInput: next.awaitingMoreInput,
        execution: Self.merging(flushed.execution, next.execution)
      )
    }

    pendingInputDomain = inputDomain
    pendingTokens.append(token)
    refreshPendingNotation()
    return try resolvePendingInput()
  }

  private func recursiveInputDomain(for token: VimInputToken) -> VimMappingInputDomain {
    if case .special = token.kind { return .command }
    if case .modified = token.kind { return .command }
    if promptKind != nil { return .logicalText }
    switch engine.state.mode {
    case .insert, .replace: return .logicalText
    case .normal, .visualCharacter, .visualLine, .commandLine, .search: return .command
    }
  }

  private func resolvePendingInput() throws -> VimKeyHandlingResult {
    let trie = activeMappingTrieUnlocked(domain: pendingInputDomain ?? .command)
    let match = trie.match(pendingTokens)
    if let exact = match.exact, !match.isPrefix || exact.nowait {
      pendingTokens.removeAll(keepingCapacity: true)
      pendingInputDomain = nil
      refreshPendingNotation()
      return VimKeyHandlingResult(
        consumed: true,
        execution: try executeMapped(exact)
      )
    }
    if match.isPrefix {
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }

    if let fallback = trie.longestExactPrefix(in: pendingTokens) {
      let remainder = Array(pendingTokens.dropFirst(fallback.length))
      let remainderDomain = pendingInputDomain ?? .command
      pendingTokens.removeAll(keepingCapacity: true)
      pendingInputDomain = nil
      refreshPendingNotation()
      var execution = try executeMapped(fallback.mapping)
      var awaiting = false
      for token in remainder {
        let next = try handleUnlocked(token: token, inputDomain: remainderDomain)
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
    let match = activeMappingTrieUnlocked(domain: pendingInputDomain ?? .command)
      .match(pendingTokens)
    if let exact = match.exact {
      pendingTokens.removeAll(keepingCapacity: true)
      pendingInputDomain = nil
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
    pendingInputDomain = nil
    var aggregate: VimExecutionResult?
    if promptKind != nil {
      var awaiting = false
      for token in tokens {
        let result = try handlePromptToken(token)
        if let execution = result.execution {
          aggregate = aggregate.map { Self.merged($0, execution) } ?? execution
        }
        awaiting = result.awaitingMoreInput
      }
      refreshPendingNotation()
      return VimKeyHandlingResult(
        consumed: true,
        awaitingMoreInput: awaiting,
        execution: aggregate
      )
    }
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

  private func executeMapped(_ mapping: VimResolvedMapping) throws -> VimExecutionResult? {
    if !mapping.recursive {
      if promptKind != nil {
        switch mapping.invocation {
        case .keys(let notation), .notation(let notation):
          var aggregate: VimExecutionResult?
          for token in Self.tokens(in: notation) {
            let result = try handlePromptToken(token)
            aggregate = Self.merging(aggregate, result.execution)
          }
          return aggregate
        default:
          break
        }
      }
      return try engine.execute(mapping.invocation)
    }
    guard mappingDepth < mappingRecursionLimit else { throw VimError.macroRecursionLimit }
    mappingDepth += 1
    defer { mappingDepth -= 1 }

    switch mapping.invocation {
    case .keys(let notation), .notation(let notation):
      var aggregate: VimExecutionResult?
      for token in Self.tokens(in: notation) {
        let handled = try handleUnlocked(
          token: token,
          inputDomain: recursiveInputDomain(for: token)
        )
        if let execution = handled.execution {
          aggregate = aggregate.map { Self.merged($0, execution) } ?? execution
        }
      }
      return aggregate
    default:
      return try engine.execute(mapping.invocation)
    }
  }

  private func beginPrompt(_ kind: PromptKind, prefix: String) {
    resetPendingInputUnlocked()
    promptKind = kind
    let initial = prefix == ":'<,'>" ? "'<,'>" : ""
    promptBuffer = Array(initial)
    promptCursor = promptBuffer.count
    historyIndex = nil
    historySearchPrefix = nil
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
    case "<m-left>":
      movePromptCursorToPreviousWord()
    case "<m-right>":
      movePromptCursorToNextWord()
    case "<home>", "<c-b>":
      promptCursor = 0
    case "<end>", "<c-e>":
      promptCursor = promptBuffer.count
    case "<bs>", "<backspace>":
      if promptCursor > 0 {
        promptCursor -= 1
        promptBuffer.remove(at: promptCursor)
        resetHistoryTraversalAfterEdit()
      }
    case "<del>", "<delete>":
      if promptCursor < promptBuffer.count {
        promptBuffer.remove(at: promptCursor)
        resetHistoryTraversalAfterEdit()
      }
    case "<c-u>":
      promptBuffer.removeSubrange(0..<promptCursor)
      promptCursor = 0
      resetHistoryTraversalAfterEdit()
    case "<c-w>":
      deletePromptWordBeforeCursor()
      resetHistoryTraversalAfterEdit()
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
      resetHistoryTraversalAfterEdit()
    }
    updatePromptDisplay(kind)
    return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
  }

  private func movePromptCursorToPreviousWord() {
    while promptCursor > 0, promptBuffer[promptCursor - 1].isWhitespace {
      promptCursor -= 1
    }
    while promptCursor > 0, !promptBuffer[promptCursor - 1].isWhitespace {
      promptCursor -= 1
    }
  }

  private func movePromptCursorToNextWord() {
    while promptCursor < promptBuffer.count, !promptBuffer[promptCursor].isWhitespace {
      promptCursor += 1
    }
    while promptCursor < promptBuffer.count, promptBuffer[promptCursor].isWhitespace {
      promptCursor += 1
    }
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
      if commandHistory.count > 200 { commandHistory.removeFirst(commandHistory.count - 200) }
    case .search:
      if searchHistory.last != value { searchHistory.append(value) }
      if searchHistory.count > 200 { searchHistory.removeFirst(searchHistory.count - 200) }
    }
  }

  private func recallHistory(kind: PromptKind, delta: Int) {
    let history: [String]
    switch kind {
    case .command: history = commandHistory
    case .search: history = searchHistory
    }
    guard !history.isEmpty else { return }

    if historySearchPrefix == nil { historySearchPrefix = String(promptBuffer) }
    let prefix = historySearchPrefix ?? ""
    let candidates = history.indices.filter { prefix.isEmpty || history[$0].hasPrefix(prefix) }
    guard !candidates.isEmpty else { return }

    if delta < 0 {
      let current = historyIndex ?? history.count
      guard let next = candidates.last(where: { $0 < current }) else { return }
      historyIndex = next
      promptBuffer = Array(history[next])
    } else {
      let current = historyIndex ?? -1
      if let next = candidates.first(where: { $0 > current }) {
        historyIndex = next
        promptBuffer = Array(history[next])
      } else {
        historyIndex = nil
        promptBuffer = Array(prefix)
      }
    }
    promptCursor = promptBuffer.count
  }

  private func resetHistoryTraversalAfterEdit() {
    historyIndex = nil
    historySearchPrefix = nil
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
    return commandParser.expectedInput
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
    let notation = (commandTokens + pendingTokens).map(\.notation).joined()
    let leader = engine.leader
    guard !leader.isEmpty, notation.hasPrefix(leader) else {
      storedPendingNotation = notation
      return
    }
    storedPendingNotation = "<leader>" + String(notation.dropFirst(leader.count))
  }

  private func resetPendingInputUnlocked() {
    pendingTokens.removeAll(keepingCapacity: true)
    pendingInputDomain = nil
    commandTokens.removeAll(keepingCapacity: true)
    commandParser.reset()
    storedPendingNotation.removeAll(keepingCapacity: true)
  }

  private func cancelPromptUnlocked() {
    promptKind = nil
    promptBuffer.removeAll(keepingCapacity: true)
    promptCursor = 0
    historyIndex = nil
    historySearchPrefix = nil
    clearCompositionUnlocked()
    storedPrompt = nil
  }

  private func activeMappingModeUnlocked() -> VimMappingMode {
    if promptKind != nil { return .commandLine }
    switch engine.state.mode {
    case .insert: return .insert
    case .replace: return .replace
    case .visualCharacter, .visualLine: return .visual
    case .commandLine, .search: return .commandLine
    case .normal:
      return commandParser.isOperatorPending ? .operatorPending : .normal
    }
  }

  private func activeMappingTrieUnlocked(
    domain: VimMappingInputDomain
  ) -> VimMappingTrie {
    let key = VimMappingKey(mode: activeMappingModeUnlocked(), inputDomain: domain)
    if let trie = mappingTries[key] { return trie }
    let trie = VimMappingTrie()
    mappingTries[key] = trie
    return trie
  }

  private func interactionSnapshotUnlocked() -> VimInteractionSnapshot {
    let expected = expectedInputUnlocked
    let mappingMatch =
      pendingTokens.isEmpty
      ? nil
      : activeMappingTrieUnlocked(domain: pendingInputDomain ?? .command)
        .match(pendingTokens)
    let registerName = displayName(for: commandParser.selectedRegister)
    let prefix = commandParser.displayPrefix

    let pending = VimPendingCommandSnapshot(
      notation: storedPendingNotation,
      expectedInput: expected,
      count: commandParser.count > 0 ? commandParser.count : nil,
      registerName: registerName,
      operatorName: commandParser.pendingOperator?.value.rawValue,
      prefix: prefix,
      isMappingPrefix: mappingMatch?.isPrefix == true
    )

    let commandLine: VimCommandLineSnapshot?
    if let promptKind {
      let kind: VimCommandLineKind
      let historyCount: Int
      switch promptKind {
      case .command:
        kind = .command
        historyCount = commandHistory.count
      case .search(let forward):
        kind = forward ? .searchForward : .searchBackward
        historyCount = searchHistory.count
      }
      let prefix: String
      switch kind {
      case .command: prefix = ":"
      case .searchForward: prefix = "/"
      case .searchBackward: prefix = "?"
      }
      commandLine = VimCommandLineSnapshot(
        kind: kind,
        prefix: prefix,
        text: String(promptBuffer),
        cursorOffset: promptCursor,
        markedText: compositionIsActive ? compositionText : "",
        markedSelection: compositionIsActive ? compositionSelection : 0..<0,
        historyPosition: historyIndex,
        historyCount: historyCount
      )
    } else {
      commandLine = nil
    }

    return VimInteractionSnapshot(
      mode: engine.state.mode,
      pendingCommand: pending,
      commandLine: commandLine,
      macro: VimMacroSnapshot(
        recordingRegister: engine.recording,
        lastPlayedRegister: engine.lastPlayedMacro
      ),
      isTemporaryNormal: engine.temporaryInsertReturnMode != nil,
      isComposingText: compositionIsActive,
      history: VimHistorySnapshot(commands: commandHistory, searches: searchHistory),
      visualSelection: engine.visualSelectionSnapshotUnlocked(),
      message: storedMessage
    )
  }

  private func displayName(for register: VimRegister) -> Character? {
    switch register {
    case .unnamed: return nil
    case .named(let name): return name
    case .numbered(let number): return Character(String(number))
    case .smallDelete: return "-"
    case .blackHole: return "_"
    case .clipboard: return "+"
    }
  }

  private func collectEngineMessageUnlocked() {
    if let message = engine.consumeMessage() { storedMessage = message }
  }

  private func expireMessageForNextInputUnlocked() {
    guard let message = storedMessage else { return }
    switch message.lifetime {
    case .persistent:
      break
    case .untilNextInput, .timed:
      storedMessage = nil
    }
  }

  private static func merging(
    _ first: VimExecutionResult?,
    _ second: VimExecutionResult?
  ) -> VimExecutionResult? {
    switch (first, second) {
    case (.none, .none): return nil
    case (.some(let first), .none): return first
    case (.none, .some(let second)): return second
    case (.some(let first), .some(let second)): return merged(first, second)
    }
  }

  private static func merged(
    _ first: VimExecutionResult,
    _ second: VimExecutionResult
  ) -> VimExecutionResult {
    VimExecutionResult(
      state: second.state,
      hostRequests: first.hostRequests + second.hostRequests,
      didChangeText: first.didChangeText || second.didChangeText,
      transaction: VimEditTransaction.merging(first.transaction, second.transaction)
    )
  }

  private static func tokens(in notation: String) -> [VimInputToken] {
    VimCommandParser.tokens(in: notation).map(VimInputToken.init(notationToken:))
  }
}
