import Foundation

extension VimEngine {
  @discardableResult
  public func executeNotation(_ notation: String) throws -> VimExecutionResult {
    try lock.withLock {
      try executeTransactionBatch { try executeNotationUnlocked(notation) }
    }
  }

  func executeNotationUnlocked(_ notation: String) throws -> VimExecutionResult {
    var parser = VimCommandParser()
    return try executeNotationTokensUnlocked(
      VimCommandParser.tokens(in: notation),
      parser: &parser,
      finalize: true,
      originalNotation: notation
    )
  }

  func executeNotationToken(
    _ token: String,
    parser: inout VimCommandParser
  ) throws -> VimExecutionResult {
    try lock.withLock {
      try executeTransactionBatch {
        try executeNotationTokensUnlocked(
          [token],
          parser: &parser,
          finalize: false,
          originalNotation: token
        )
      }
    }
  }

  func executeNotationTokensUnlocked(
    _ tokens: [String],
    parser: inout VimCommandParser,
    finalize: Bool,
    originalNotation: String
  ) throws -> VimExecutionResult {
    var aggregate: [VimHostRequest] = []
    var changed = false
    var index = 0

    func merge(_ result: VimExecutionResult) {
      aggregate.append(contentsOf: result.hostRequests)
      changed = changed || result.didChangeText
    }

    func restoreTemporaryInsertModeIfCommandCompleted() {
      guard parser.isAtCommandBoundary, let returnMode = temporaryInsertReturnMode else { return }
      if state.mode == .normal || state.mode == .visualCharacter || state.mode == .visualLine {
        state.mode = returnMode
        state.selection = nil
      }
      temporaryInsertReturnMode = nil
    }

    while index < tokens.count {
      let rawToken = tokens[index]
      let token = rawToken.hasPrefix("<") ? rawToken.lowercased() : rawToken
      index += 1

      if state.mode == .insert || state.mode == .replace {
        let lower = token.lowercased()
        switch lower {
        case "<esc>", "<c-[>":
          merge(try execute(.escape))
        case "<cr>", "<enter>":
          merge(try execute(.insertNewline))
        case "<bs>", "<backspace>":
          merge(try execute(.deleteBeforeCursor))
        case "<del>", "<delete>":
          merge(try execute(.deleteCharacter))
        case "<tab>":
          merge(try execute(.insert("\t")))
        case "<c-w>":
          let amount = insertionDeleteWordCount()
          if amount > 0 { merge(try execute(.deleteBeforeCursor, count: amount)) }
        case "<c-u>":
          let amount = characterDistance(from: lineStart(at: state.cursor), to: state.cursor)
          if amount > 0 { merge(try execute(.deleteBeforeCursor, count: amount)) }
        case "<c-t>":
          merge(try execute(.operatorLine(.indent)))
        case "<c-d>":
          merge(try execute(.operatorLine(.outdent)))
        case "<c-a>":
          if !lastInsertedText.isEmpty { merge(try execute(.insert(lastInsertedText))) }
        case "<c-o>":
          temporaryInsertReturnMode = state.mode
          state.mode = .normal
          state.selection = nil
          parser.reset()
        default:
          guard !token.hasPrefix("<") else { continue }
          merge(try execute(.insert(token)))
        }
        continue
      }

      if token == "q", isRecordingMacro, parser.isAtCommandBoundary {
        merge(try execute(.stopMacro))
        restoreTemporaryInsertModeIfCommandCompleted()
        continue
      }

      let step = try parser.consume(token, mode: state.mode)
      switch step {
      case .awaitingMoreInput, .cancelled:
        continue

      case .command(let command):
        if case .direct(let directToken, let count, let register) = command,
          directToken == leader
        {
          let remainder = tokens[index...].joined()
          merge(try execute(.leader(remainder), count: count, register: register))
          index = tokens.count
        } else {
          merge(try replay(command))
        }
        restoreTemporaryInsertModeIfCommandCompleted()
      }
    }

    if finalize, parser.isIncomplete {
      throw VimError.incompleteCommand(originalNotation)
    }

    restoreTemporaryInsertModeIfCommandCompleted()
    return VimExecutionResult(state: state, hostRequests: aggregate, didChangeText: changed)
  }

  func executeDirectNotationTokenUnlocked(
    _ token: String,
    count: Int,
    register: VimRegister
  ) throws -> VimExecutionResult {
    if state.mode == .visualCharacter || state.mode == .visualLine {
      if visualSelectionShape == .block {
        switch token {
        case "v":
          visualSelectionShape = .character
          state.mode = .visualCharacter
          updateVisualSelection()
          return VimExecutionResult(state: state)
        case "V":
          visualSelectionShape = .line
          state.mode = .visualLine
          updateVisualSelection()
          return VimExecutionResult(state: state)
        case "<c-v>":
          enterVisualBlock()
          return VimExecutionResult(state: state)
        default:
          break
        }
      }

      if token == "o" || token == "O" {
        swapVisualEndpoints()
        return VimExecutionResult(state: state)
      }

      if token == "p" || token == "P" {
        let before = state
        let source = registerValue(for: register)
        if visualSelectionShape == .block {
          pasteOverVisualBlock(source, count: count, sourceRegister: register)
        } else {
          pasteOverVisual(source, count: count, sourceRegister: register)
        }
        return VimExecutionResult(state: state, didChangeText: before.text != state.text)
      }

      let visualOperator: VimOperator?
      switch token {
      case "d", "x", "D", "X": visualOperator = .delete
      case "c", "C", "S", "s": visualOperator = .change
      case "y": visualOperator = .yank
      case ">": visualOperator = .indent
      case "<": visualOperator = .outdent
      case "U", "gU": visualOperator = .uppercase
      case "u", "gu": visualOperator = .lowercase
      case "~", "g~": visualOperator = .swapCase
      case "gq": visualOperator = .format
      case "g?": visualOperator = .rot13
      default: visualOperator = nil
      }
      if let visualOperator {
        return try execute(.operatorSelection(visualOperator), register: register)
      }

      if token == "I" || token == "A" {
        if visualSelectionShape == .block {
          if recording != nil, macroDepth == 0, !isReplayingChange {
            recordingActions.append(.block(.beginInsert(append: token == "A")))
          }
          beginVisualBlockInsert(append: token == "A")
          return VimExecutionResult(state: state)
        }
        guard let range = visualRange() else { return VimExecutionResult(state: state) }
        rememberVisualSelection()
        state.cursor = min(
          token == "I" ? range.lowerBound : range.upperBound, state.text.utf16.count)
        state.mode = .normal
        state.selection = nil
        visualAnchor = nil
        visualSelectionShape = .character
        return try execute(token == "I" ? .enterInsert : .enterInsertAfterCursor)
      }
    }

    let action: VimAction?
    switch token {
    case "<esc>": action = .escape
    case "s": action = .substituteCharacter
    case "S": action = .operatorLine(.change)
    case "X": action = .deleteBeforeCursor
    case "i": action = .enterInsert
    case "a": action = .enterInsertAfterCursor
    case "I": action = .enterInsertAtLineStart
    case "A": action = .enterInsertAtLineEnd
    case "o": action = .openLineBelow
    case "O": action = .openLineAbove
    case "R": action = .enterReplace
    case "v": action = .enterVisualCharacter
    case "V": action = .enterVisualLine
    case "<c-v>":
      if recording != nil, macroDepth == 0, !isReplayingChange {
        recordingActions.append(.block(.select(width: 1, height: 1)))
      }
      enterVisualBlock()
      return VimExecutionResult(state: state)
    case "x": action = .deleteCharacter
    case "D": action = .operatorMotion(.delete, .lineEnd)
    case "C": action = .operatorMotion(.change, .lineEnd)
    case "Y": action = .operatorLine(.yank)
    case "J": action = .joinLines
    case "u": action = .undo
    case "<c-r>": action = .redo
    case ".": action = .repeatLastChange
    case "p": action = .pasteAfter
    case "P": action = .pasteBefore
    case "~": action = .operatorMotion(.swapCase, .right)
    case "K": action = .host(.hover)
    case "<c-]>": action = .host(.definition)
    case "<c-^>", "<c-6>": action = .host(.custom("vim-buffer-alternate"))
    case "<c-b>": action = .move(.pageUp)
    case "<c-f>": action = .move(.pageDown)
    case "<c-u>": action = .move(.halfPageUp)
    case "<c-d>": action = .move(.halfPageDown)
    case "<c-o>":
      jumpBackward(count: count)
      return VimExecutionResult(state: state)
    case "<c-i>":
      jumpForward(count: count)
      return VimExecutionResult(state: state)
    case "gd": action = .host(.definition)
    case "gD": action = .host(.declaration)
    case "gr": action = .host(.references)
    case "gv": action = .reselectVisual
    case "g;":
      moveThroughChangeList(older: true, count: count)
      return VimExecutionResult(state: state)
    case "g,":
      moveThroughChangeList(older: false, count: count)
      return VimExecutionResult(state: state)
    case "q": action = isRecordingMacro ? .stopMacro : nil
    default: action = nil
    }

    guard let action else { return VimExecutionResult(state: state) }
    return try execute(action, count: count, register: register)
  }
}
