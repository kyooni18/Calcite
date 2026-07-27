import Foundation

/// A normalized command captured after register and mapping resolution.
///
/// Public `VimAction` values remain the surface API, while repeat and macro
/// playback use this representation so mutable register contents do not alter
/// already-recorded paste operations.
enum VimSemanticCommand: Sendable {
  case action(VimAction, count: Int, register: VimRegister)
  case paste(VimRegisterValue, after: Bool, count: Int)

  var publicActions: [VimAction] {
    switch self {
    case .action(let action, let count, _):
      return Array(repeating: action, count: max(1, count))
    case .paste(_, let after, let count):
      return Array(repeating: after ? .pasteAfter : .pasteBefore, count: max(1, count))
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
    }
  }
}
