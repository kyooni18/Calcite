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
      guard parser.temporaryNormalTokenCount > 0,
        parser.count == 0,
        parser.pendingOperator == nil,
        !parser.pendingOperatorG,
        parser.pendingTextObjectInner == nil,
        !parser.pendingG,
        parser.pendingFind == nil,
        !parser.pendingReplace,
        !parser.pendingMark,
        parser.pendingJump == nil,
        !parser.pendingMacro,
        !parser.pendingMacroStart,
        !parser.pendingRegister,
        let returnMode = temporaryInsertReturnMode
      else { return }
      state.mode = returnMode
      state.selection = nil
      temporaryInsertReturnMode = nil
      parser.temporaryNormalTokenCount = 0
    }

    while index < tokens.count {
      restoreTemporaryInsertModeIfCommandCompleted()
      let token = tokens[index]
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
        default:
          guard !token.hasPrefix("<") else { continue }
          merge(try execute(.insert(token)))
        }
        continue
      }

      if temporaryInsertReturnMode != nil { parser.temporaryNormalTokenCount += 1 }

      if parser.pendingRegister {
        guard let character = token.first, token.count == 1 else {
          throw VimError.invalidRegister
        }
        parser.selectedRegister = try VimCommandParser.register(for: character)
        parser.pendingRegister = false
        continue
      }

      if let activeFind = parser.pendingFind {
        guard let character = token.first, token.count == 1 else {
          throw VimError.unsupportedNotation(token)
        }
        lastFind = (character, activeFind.forward, activeFind.till)
        merge(
          try execute(
            .move(
              activeFind.forward
                ? (activeFind.till ? .tillForward(character) : .findForward(character))
                : (activeFind.till ? .tillBackward(character) : .findBackward(character))
            ), count: activeFind.count))
        parser.pendingFind = nil
        parser.selectedRegister = .unnamed
        continue
      }

      if parser.pendingReplace {
        guard let character = token.first, token.count == 1 else {
          throw VimError.unsupportedNotation(token)
        }
        if state.mode == .visualCharacter, visualSelectionShape == .block {
          if recording != nil, macroDepth == 0, !isReplayingChange {
            recordingActions.append(.block(.replace(character)))
          }
          let before = state
          replaceVisualBlock(with: character)
          merge(VimExecutionResult(state: state, didChangeText: before.text != state.text))
        } else {
          merge(
            try execute(
              .replaceCharacter(character), count: max(1, parser.count),
              register: parser.selectedRegister))
        }
        parser.pendingReplace = false
        parser.count = 0
        parser.selectedRegister = .unnamed
        continue
      }

      if parser.pendingMark {
        guard let character = token.first, token.count == 1 else {
          throw VimError.unsupportedNotation(token)
        }
        merge(try execute(.setMark(character)))
        parser.pendingMark = false
        parser.selectedRegister = .unnamed
        continue
      }

      if let linewise = parser.pendingJump {
        guard let character = token.first, token.count == 1 else {
          throw VimError.unsupportedNotation(token)
        }
        merge(try execute(.jumpToMark(character, linewise: linewise)))
        parser.pendingJump = nil
        parser.selectedRegister = .unnamed
        continue
      }

      if parser.pendingMacro {
        guard let character = token.first, token.count == 1 else {
          throw VimError.unsupportedNotation(token)
        }
        merge(try execute(.playMacro(character), count: max(1, parser.count)))
        parser.pendingMacro = false
        parser.count = 0
        parser.selectedRegister = .unnamed
        continue
      }

      if parser.pendingMacroStart {
        guard let character = token.first, token.count == 1 else {
          throw VimError.unsupportedNotation(token)
        }
        merge(try execute(.startMacro(character)))
        parser.pendingMacroStart = false
        parser.selectedRegister = .unnamed
        continue
      }

      if state.mode == .visualCharacter || state.mode == .visualLine {
        if visualSelectionShape == .block {
          if token == "v" {
            visualSelectionShape = .character
            state.mode = .visualCharacter
            updateVisualSelection()
            continue
          }
          if token == "V" {
            visualSelectionShape = .line
            state.mode = .visualLine
            updateVisualSelection()
            continue
          }
          if token.lowercased() == "<c-v>" {
            enterVisualBlock()
            continue
          }
        }
        if token == "o" || token == "O" {
          swapVisualEndpoints()
          continue
        }
        if token == "p" || token == "P" {
          let source = registerValue(for: parser.selectedRegister)
          if visualSelectionShape == .block {
            pasteOverVisualBlock(
              source, count: max(1, parser.count), sourceRegister: parser.selectedRegister)
          } else {
            pasteOverVisual(
              source, count: max(1, parser.count), sourceRegister: parser.selectedRegister)
          }
          parser.count = 0
          parser.selectedRegister = .unnamed
          changed = true
          continue
        }
        let visualOperator: VimOperator?
        switch token {
        case "d", "x", "D", "X": visualOperator = .delete
        case "c", "C", "S", "s": visualOperator = .change
        case "y": visualOperator = .yank
        case ">": visualOperator = .indent
        case "<": visualOperator = .outdent
        case "U": visualOperator = .uppercase
        case "u": visualOperator = .lowercase
        case "~": visualOperator = .swapCase
        default: visualOperator = nil
        }
        if let visualOperator {
          merge(try execute(.operatorSelection(visualOperator), register: parser.selectedRegister))
          parser.selectedRegister = .unnamed
          continue
        }
        if token == "I" || token == "A" {
          if visualSelectionShape == .block {
            if recording != nil, macroDepth == 0, !isReplayingChange {
              recordingActions.append(.block(.beginInsert(append: token == "A")))
            }
            beginVisualBlockInsert(append: token == "A")
            merge(VimExecutionResult(state: state))
          } else {
            guard let range = visualRange() else { continue }
            rememberVisualSelection()
            let insertion = token == "I" ? range.lowerBound : range.upperBound
            state.cursor = min(insertion, state.text.utf16.count)
            state.mode = .normal
            state.selection = nil
            visualAnchor = nil
            visualSelectionShape = .character
            merge(try execute(token == "I" ? .enterInsert : .enterInsertAfterCursor))
          }
          continue
        }
      }

      if token == "\"", parser.pendingOperator == nil {
        parser.pendingRegister = true
        continue
      }

      if token.count == 1, let digit = Int(token), !(token == "0" && parser.count == 0) {
        parser.count = parser.count * 10 + digit
        continue
      }

      if parser.pendingG {
        parser.pendingG = false
        let effectiveCount = max(1, parser.count)
        parser.count = 0
        let action: VimAction?
        switch token {
        case "g":
          action = effectiveCount == 1 ? .move(.documentStart) : .move(.line(effectiveCount))
        case "d": action = .host(.definition)
        case "D": action = .host(.declaration)
        case "r": action = .host(.references)
        case "v": action = .reselectVisual
        case "e":
          moveToPreviousWordEnd(count: effectiveCount, whole: false)
          parser.selectedRegister = .unnamed
          continue
        case "E":
          moveToPreviousWordEnd(count: effectiveCount, whole: true)
          parser.selectedRegister = .unnamed
          continue
        case "_":
          moveToLastNonBlank(count: effectiveCount)
          parser.selectedRegister = .unnamed
          continue
        case ";":
          moveThroughChangeList(older: true, count: effectiveCount)
          parser.selectedRegister = .unnamed
          continue
        case ",":
          moveThroughChangeList(older: false, count: effectiveCount)
          parser.selectedRegister = .unnamed
          continue
        case "0": action = .move(.lineStart)
        case "^": action = .move(.firstNonBlank)
        case "$": action = .move(.lineEnd)
        case "j": action = .move(.down)
        case "k": action = .move(.up)
        case "U": action = .operatorMotion(.uppercase, .lineEnd)
        case "u": action = .operatorMotion(.lowercase, .lineEnd)
        case "~": action = .operatorMotion(.swapCase, .lineEnd)
        default: action = nil
        }
        guard let action else { throw VimError.unsupportedNotation("g\(token)") }
        merge(try execute(action, register: parser.selectedRegister))
        parser.selectedRegister = .unnamed
        continue
      }

      if let pending = parser.pendingOperator {
        if parser.pendingOperatorG {
          parser.pendingOperatorG = false
          let suffixCount = max(1, parser.count)
          let effectiveCount = pending.count * suffixCount
          parser.count = 0
          parser.pendingOperator = nil
          guard token == "g" else {
            throw VimError.unsupportedNotation("operator + g\(token)")
          }
          let motion: VimMotion = effectiveCount == 1 ? .documentStart : .line(effectiveCount)
          merge(try execute(.operatorMotion(pending.value, motion), register: pending.register))
          parser.selectedRegister = .unnamed
          continue
        }

        if parser.pendingTextObjectInner == nil, token == "g" {
          parser.pendingOperatorG = true
          continue
        }

        if parser.pendingTextObjectInner == nil, token == "i" || token == "a" {
          parser.pendingTextObjectInner = token == "i"
          continue
        }

        let suffixCount = max(1, parser.count)
        let effectiveCount = pending.count * suffixCount
        parser.count = 0
        parser.pendingOperator = nil
        let action: VimAction

        if let inner = parser.pendingTextObjectInner {
          parser.pendingTextObjectInner = nil
          guard let object = VimCommandParser.textObject(for: token) else {
            throw VimError.unsupportedNotation("text object \(token)")
          }
          action = .operatorTextObject(pending.value, object, inner: inner)
        } else if token == VimCommandParser.operatorToken(for: pending.value) {
          action = .operatorLine(pending.value)
        } else if let motion = VimCommandParser.motion(for: token) {
          action = .operatorMotion(pending.value, motion)
        } else {
          throw VimError.incompleteCommand("operator + \(token)")
        }
        merge(try execute(action, count: effectiveCount, register: pending.register))
        parser.selectedRegister = .unnamed
        continue
      }

      let effectiveCount = max(1, parser.count)
      parser.count = 0
      let action: VimAction?
      switch token {
      case "h": action = .move(.left)
      case "j": action = .move(.down)
      case "k": action = .move(.up)
      case "l": action = .move(.right)
      case "w": action = .move(.wordForward)
      case "b": action = .move(.wordBackward)
      case "e": action = .move(.wordEnd)
      case "W":
        moveWholeWordForward(count: effectiveCount)
        action = nil
      case "B":
        moveWholeWordBackward(count: effectiveCount)
        action = nil
      case "E":
        moveWholeWordEnd(count: effectiveCount)
        action = nil
      case "0": action = .move(.lineStart)
      case "^": action = .move(.firstNonBlank)
      case "$": action = .move(.lineEnd)
      case "+":
        moveToAdjacentLine(count: effectiveCount, forward: true)
        action = nil
      case "-":
        moveToAdjacentLine(count: effectiveCount, forward: false)
        action = nil
      case "_":
        moveToCurrentOrFollowingLine(count: effectiveCount)
        action = nil
      case "|":
        moveToColumn(effectiveCount)
        action = nil
      case "G": action = effectiveCount == 1 ? .move(.documentEnd) : .move(.line(effectiveCount))
      case "H":
        moveToViewport(.top, count: effectiveCount)
        action = nil
      case "M":
        moveToViewport(.middle, count: effectiveCount)
        action = nil
      case "L":
        moveToViewport(.bottom, count: effectiveCount)
        action = nil
      case "%": action = .move(.matchingPair)
      case "<c-b>": action = .move(.pageUp)
      case "<c-f>": action = .move(.pageDown)
      case "<c-u>": action = .move(.halfPageUp)
      case "<c-d>": action = .move(.halfPageDown)
      case "<c-o>":
        jumpBackward(count: effectiveCount)
        action = nil
      case "<c-i>":
        jumpForward(count: effectiveCount)
        action = nil
      case "f":
        parser.pendingFind = (forward: true, till: false, count: effectiveCount)
        action = nil
      case "F":
        parser.pendingFind = (forward: false, till: false, count: effectiveCount)
        action = nil
      case "t":
        parser.pendingFind = (forward: true, till: true, count: effectiveCount)
        action = nil
      case "T":
        parser.pendingFind = (forward: false, till: true, count: effectiveCount)
        action = nil
      case ";":
        if let lastFind {
          find(
            lastFind.character, forward: lastFind.forward, till: lastFind.till,
            count: effectiveCount)
          updateVisualSelection()
        }
        action = nil
      case ",":
        if let lastFind {
          find(
            lastFind.character, forward: !lastFind.forward, till: lastFind.till,
            count: effectiveCount)
          updateVisualSelection()
        }
        action = nil
      case "r":
        parser.pendingReplace = true
        parser.count = effectiveCount
        action = nil
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
      case "<c-v>", "<C-V>", "<C-v>":
        if recording != nil, macroDepth == 0, !isReplayingChange {
          recordingActions.append(.block(.select(width: 1, height: 1)))
        }
        enterVisualBlock()
        action = nil
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
      case "n": action = .nextSearch
      case "N": action = .previousSearch
      case "*":
        if let word = wordUnderCursor() {
          let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
          recordJumpOrigin()
          lastSearch = (pattern, true)
          registers[.named("/")] = VimRegisterValue(text: pattern, linewise: false)
          search(pattern, forward: true)
        }
        action = nil
      case "#":
        if let word = wordUnderCursor() {
          let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
          recordJumpOrigin()
          lastSearch = (pattern, false)
          registers[.named("/")] = VimRegisterValue(text: pattern, linewise: false)
          search(pattern, forward: false)
        }
        action = nil
      case "~": action = .operatorMotion(.swapCase, .right)
      case "K": action = .host(.hover)
      case "<c-]>": action = .host(.definition)
      case "m":
        parser.pendingMark = true
        action = nil
      case "'":
        parser.pendingJump = true
        action = nil
      case "`":
        parser.pendingJump = false
        action = nil
      case "@":
        parser.pendingMacro = true
        action = nil
      case "q":
        if isRecordingMacro {
          action = .stopMacro
        } else {
          parser.pendingMacroStart = true
          action = nil
        }
      case "g":
        parser.pendingG = true
        parser.count = effectiveCount == 1 ? 0 : effectiveCount
        action = nil
      case "d":
        parser.pendingOperator = (.delete, effectiveCount, parser.selectedRegister)
        action = nil
      case "c":
        parser.pendingOperator = (.change, effectiveCount, parser.selectedRegister)
        action = nil
      case "y":
        parser.pendingOperator = (.yank, effectiveCount, parser.selectedRegister)
        action = nil
      case ">":
        parser.pendingOperator = (.indent, effectiveCount, parser.selectedRegister)
        action = nil
      case "<":
        parser.pendingOperator = (.outdent, effectiveCount, parser.selectedRegister)
        action = nil
      case "<esc>": action = .escape
      default:
        if token == leader {
          let remainder = tokens[index...].joined()
          let result = try execute(.leader(remainder))
          merge(result)
          index = tokens.count
        }
        action = nil
      }
      if let action {
        merge(try execute(action, count: effectiveCount, register: parser.selectedRegister))
        parser.selectedRegister = .unnamed
      }
    }

    if finalize, parser.isIncomplete {
      throw VimError.incompleteCommand(originalNotation)
    }

    restoreTemporaryInsertModeIfCommandCompleted()

    return VimExecutionResult(state: state, hostRequests: aggregate, didChangeText: changed)
  }

}
