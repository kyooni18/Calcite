import Foundation

/// A normalized command captured after register and mapping resolution.
///
/// Public `VimAction` values remain the surface API, while repeat and macro
/// playback use this representation so mutable register contents do not alter
/// already-recorded paste operations.
enum VimBlockSemanticCommand: Hashable, Sendable {
  case select(width: Int, height: Int)
  case beginInsert(append: Bool)
  case replace(Character)
}

enum VimSemanticCommand: Hashable, Sendable {
  case action(VimAction, count: Int, register: VimRegister)
  case motion(VimMotionExpression, count: Int)
  case operation(
    VimOperator, motion: VimMotionExpression, count: Int, register: VimRegister,
    forcedKind: VimMotionKind?
  )
  case visualOperation(VimOperator, register: VimRegister)
  case replace(Character, count: Int, register: VimRegister)
  case setMark(Character)
  case jumpToMark(Character, linewise: Bool)
  case playMacro(Character, count: Int)
  case startMacro(Character)
  case direct(String, count: Int, register: VimRegister)
  case paste(VimRegisterValue, after: Bool, count: Int)
  case block(VimBlockSemanticCommand)

  var publicActions: [VimAction] {
    switch self {
    case .action(let action, let count, _):
      return Array(repeating: action, count: max(1, count))
    case .paste(_, let after, let count):
      return Array(repeating: after ? .pasteAfter : .pasteBefore, count: max(1, count))
    case .motion, .operation, .visualOperation, .replace, .setMark, .jumpToMark,
      .playMacro, .startMacro, .direct, .block:
      return []
    }
  }
}

extension VimEngine {
  func semanticCommand(
    for action: VimAction,
    count: Int,
    register: VimRegister
  ) -> VimSemanticCommand {
    switch action {
    case .pasteAfter:
      return .paste(registerValue(for: register), after: true, count: count)
    case .pasteBefore:
      return .paste(registerValue(for: register), after: false, count: count)
    default:
      return .action(action, count: count, register: register)
    }
  }

  @discardableResult
  func replay(_ command: VimSemanticCommand) throws -> VimExecutionResult {
    switch command {
    case .action(let action, let count, let register):
      return try execute(action, count: count, register: register)
    case .motion(let motion, let count):
      guard let resolved = resolvedSearchMotion(motion) else {
        return VimExecutionResult(state: state)
      }
      return try executeMotionExpressionUnlocked(resolved, count: count)
    case .operation(let op, let motion, let count, let register, let forcedKind):
      let resolved = resolvedSearchMotion(motion)
      guard let resolved else { return VimExecutionResult(state: state) }
      return try executeOperationUnlocked(
        op,
        motion: resolved,
        count: count,
        register: register,
        forcedKind: forcedKind
      )
    case .visualOperation(let op, let register):
      return try execute(.operatorSelection(op), register: register)
    case .replace(let character, let count, let register):
      if state.mode == .visualCharacter, visualSelectionShape == .block {
        if recording != nil, macroDepth == 0, !isReplayingChange {
          recordingActions.append(.block(.replace(character)))
        }
        let before = state
        replaceVisualBlock(with: character)
        return VimExecutionResult(state: state, didChangeText: before.text != state.text)
      }
      return try execute(.replaceCharacter(character), count: count, register: register)
    case .setMark(let character):
      return try execute(.setMark(character))
    case .jumpToMark(let character, let linewise):
      return try execute(.jumpToMark(character, linewise: linewise))
    case .playMacro(let character, let count):
      return try execute(.playMacro(character), count: count)
    case .startMacro(let character):
      return try execute(.startMacro(character))
    case .direct(let token, let count, let register):
      return try executeDirectNotationTokenUnlocked(token, count: count, register: register)
    case .paste(let value, let after, let count):
      let before = state
      performMutation(
        action: after ? .pasteAfter : .pasteBefore,
        count: count,
        register: .unnamed,
        semanticCommand: command
      ) {
        paste(value, after: after, count: count)
      }
      normalizeCursorForMode()
      return VimExecutionResult(
        state: state,
        didChangeText: before.text != state.text
      )
    case .block(let block):
      let before = state
      executeBlockSemantic(block)
      return VimExecutionResult(state: state, didChangeText: before.text != state.text)
    }
  }

  private func resolvedSearchMotion(
    _ motion: VimMotionExpression
  ) -> VimMotionExpression? {
    guard case .search(let query, let forward) = motion, query.isEmpty else {
      return motion
    }
    guard let previous = lastSearch?.0, !previous.isEmpty else { return nil }
    return .search(previous, forward: forward)
  }
}
