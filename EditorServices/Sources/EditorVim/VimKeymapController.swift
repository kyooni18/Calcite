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
/// `VimEngine.executeNotation` intentionally executes complete commands. This controller retains
/// counts, operators, and leader sequences across native key events and adds user mappings without
/// placing keyboard state in the editor view.
public final class VimKeymapController: @unchecked Sendable {
  public let engine: VimEngine
  public private(set) var pendingNotation = ""
  public private(set) var prompt: String?

  private enum PromptKind {
    case command
    case search(forward: Bool)
  }

  private var promptKind: PromptKind?
  private var promptBuffer = ""
  private var mappings: [String: VimInvocation] = [:]
  private var mappingPrefixes: Set<String> = []

  public init(
    engine: VimEngine = VimEngine(),
    mappings: [VimKeyMapping] = []
  ) {
    self.engine = engine
    setMappings(mappings)
  }

  public func synchronize(text: String, cursor: Int? = nil) {
    engine.synchronize(text: text, cursor: cursor)
  }

  public func setMappings(_ values: [VimKeyMapping]) {
    mappings.removeAll(keepingCapacity: true)
    mappingPrefixes.removeAll(keepingCapacity: true)
    for mapping in values {
      let sequence = expandedSequence(mapping.sequence)
      guard !sequence.isEmpty, let invocation = invocation(for: mapping.command) else { continue }
      mappings[sequence] = invocation
      var prefix = ""
      for token in Self.tokens(in: sequence) {
        prefix += token
        mappingPrefixes.insert(prefix)
      }
    }
  }

  public func resetPendingInput() {
    pendingNotation.removeAll(keepingCapacity: false)
  }

  public func cancelPrompt() {
    promptKind = nil
    promptBuffer = ""
    prompt = nil
  }

  @discardableResult
  public func handle(token: String) throws -> VimKeyHandlingResult {
    guard !token.isEmpty else { return VimKeyHandlingResult(consumed: false) }

    if promptKind != nil {
      return try handlePromptToken(token)
    }

    if engine.state.mode == .insert || engine.state.mode == .replace {
      resetPendingInput()
      let normalized = token.lowercased() == "<c-[>" ? "<Esc>" : token
      let result = try engine.execute(.notation(normalized))
      return VimKeyHandlingResult(consumed: true, execution: result)
    }

    if token.lowercased() == "<esc>" {
      resetPendingInput()
      let result = try engine.execute(.notation("<Esc>"))
      return VimKeyHandlingResult(consumed: true, execution: result)
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

    pendingNotation += token

    if let mapped = mappings[pendingNotation] {
      resetPendingInput()
      let result = try engine.execute(mapped)
      return VimKeyHandlingResult(consumed: true, execution: result)
    }
    if mappingPrefixes.contains(pendingNotation) {
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }
    if Self.isIncompleteBuiltin(pendingNotation) {
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }

    let complete = pendingNotation
    resetPendingInput()
    do {
      let result = try engine.execute(.notation(complete))
      return VimKeyHandlingResult(consumed: true, execution: result)
    } catch VimError.incompleteCommand {
      pendingNotation = complete
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    } catch {
      resetPendingInput()
      throw error
    }
  }

  private func beginPrompt(_ kind: PromptKind, prefix: String) {
    resetPendingInput()
    promptKind = kind
    promptBuffer = ""
    prompt = prefix
  }

  private func handlePromptToken(_ token: String) throws -> VimKeyHandlingResult {
    guard let promptKind else { return VimKeyHandlingResult(consumed: false) }
    switch token.lowercased() {
    case "<esc>":
      cancelPrompt()
      return VimKeyHandlingResult(consumed: true)
    case "<bs>":
      if !promptBuffer.isEmpty { promptBuffer.removeLast() }
      updatePromptDisplay(promptKind)
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    case "<cr>":
      let value = promptBuffer
      cancelPrompt()
      guard !value.isEmpty else { return VimKeyHandlingResult(consumed: true) }
      let result: VimExecutionResult
      switch promptKind {
      case .command:
        result = try engine.execute(.ex(value))
      case .search(let forward):
        result = try engine.execute(.action(.search(value, forward: forward)))
      }
      return VimKeyHandlingResult(consumed: true, execution: result)
    default:
      guard !token.hasPrefix("<") else {
        return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
      }
      promptBuffer += token
      updatePromptDisplay(promptKind)
      return VimKeyHandlingResult(consumed: true, awaitingMoreInput: true)
    }
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

  private static func isIncompleteBuiltin(_ notation: String) -> Bool {
    let tokens = tokens(in: notation)
    guard !tokens.isEmpty else { return false }
    let nonCount = tokens.drop { token in token.count == 1 && token.first?.isNumber == true }
    guard let first = nonCount.first else { return true }
    if ["d", "c", "y", ">", "<", "g", "f", "F", "t", "T", "r", "m", "'", "`", "@", "q"]
      .contains(first), nonCount.count == 1
    {
      return true
    }
    return false
  }

  private static func tokens(in notation: String) -> [String] {
    var values: [String] = []
    var index = notation.startIndex
    while index < notation.endIndex {
      if notation[index] == "<", let end = notation[index...].firstIndex(of: ">") {
        values.append(String(notation[index...end]))
        index = notation.index(after: end)
      } else {
        values.append(String(notation[index]))
        index = notation.index(after: index)
      }
    }
    return values
  }
}
