import Foundation

extension VimEngine {
  func executeMotionExpressionUnlocked(
    _ motion: VimMotionExpression,
    count: Int
  ) throws -> VimExecutionResult {
    guard count > 0 else { throw VimError.invalidCount }
    let before = state

    let result = evaluateMotion(motion, count: count, from: state.cursor)
    guard result.succeeded else { return VimExecutionResult(state: state) }
    if recording != nil, macroDepth == 0, !isReplayingChange {
      recordingActions.append(.motion(motion, count: count))
    }
    updateMotionHistoryAfterSuccessfulExecution(motion)
    if result.isJump || motion.standardMotion.map(isJumpMotion) == true {
      recordJumpOrigin()
    }
    if motion.isSelectionMotion, let range = result.explicitRange {
      let wasReversed = visualAnchor.map { state.cursor < $0 } ?? false
      visualSelectionShape = .character
      state.mode = .visualCharacter
      if wasReversed {
        visualAnchor = previousCharacterBoundary(from: range.upperBound)
        state.cursor = range.lowerBound
      } else {
        visualAnchor = range.lowerBound
        state.cursor =
          range.isEmpty ? range.lowerBound : previousCharacterBoundary(from: range.upperBound)
      }
      updateVisualSelection()
      return VimExecutionResult(state: state, didChangeText: false)
    }
    state.cursor = result.destination
    if motion.isDisplayLineMotion {
      preferredVisualColumn = result.desiredColumn
      preferredColumn = nil
    } else {
      preferredColumn = result.desiredColumn
      preferredVisualColumn = nil
    }
    normalizeCursorForMode()
    updateVisualSelection()
    return VimExecutionResult(state: state, didChangeText: before.text != state.text)
  }

  func executeOperationUnlocked(
    _ op: VimOperator,
    motion: VimMotionExpression,
    count: Int,
    register: VimRegister,
    forcedKind: VimMotionKind? = nil
  ) throws -> VimExecutionResult {
    guard count > 0 else { throw VimError.invalidCount }

    let before = state
    let semantic = VimSemanticCommand.operation(
      op,
      motion: motion,
      count: count,
      register: register,
      forcedKind: forcedKind
    )
    let resolvedMotion: VimMotionExpression
    if op == .change,
      motion.isWordForwardMotion,
      wordClass(
        at: state.cursor,
        whole: motion == .wholeWordForward
      ) != .whitespace
    {
      resolvedMotion = motion == .wholeWordForward ? .wholeWordEnd : .standard(.wordEnd)
    } else {
      resolvedMotion = motion
    }

    let origin = state.cursor
    let result = evaluateMotion(resolvedMotion, count: count, from: origin)
    guard result.succeeded else { return VimExecutionResult(state: state) }
    let evaluated = operatorRange(
      for: resolvedMotion,
      result: result,
      origin: origin,
      forcedKind: forcedKind
    )
    guard evaluated.succeeded else { return VimExecutionResult(state: state) }
    if recording != nil, macroDepth == 0, !isReplayingChange {
      recordingActions.append(semantic)
    }
    updateMotionHistoryAfterSuccessfulExecution(motion)
    if result.isJump { recordJumpOrigin() }

    if op == .change {
      beginInsertChange(
        action: nil,
        count: count,
        register: register,
        semanticCommand: semantic
      )
      applyOperation(op, evaluated: evaluated, register: register)
      markActiveChangeIfNeeded()
    } else {
      performMutation(
        action: nil,
        count: count,
        register: register,
        semanticCommand: semantic
      ) {
        applyOperation(op, evaluated: evaluated, register: register)
      }
    }
    normalizeCursorForMode()
    return VimExecutionResult(state: state, didChangeText: before.text != state.text)
  }

  private func updateMotionHistoryAfterSuccessfulExecution(_ motion: VimMotionExpression) {
    switch motion {
    case .standard(.findForward(let character)):
      lastFind = (character, true, false)
    case .standard(.findBackward(let character)):
      lastFind = (character, false, false)
    case .standard(.tillForward(let character)):
      lastFind = (character, true, true)
    case .standard(.tillBackward(let character)):
      lastFind = (character, false, true)
    case .search(let query, let forward):
      lastSearch = (query, forward)
      registers[.named("/")] = VimRegisterValue(text: query, linewise: false)
    case .wordSearch(let forward, let wholeWord):
      guard let range = wordObjectRangeAt(origin: state.cursor) else { break }
      let escaped = NSRegularExpression.escapedPattern(for: substring(range))
      let pattern = wholeWord ? "\\b" + escaped + "\\b" : escaped
      lastSearch = (pattern, forward)
      registers[.named("/")] = VimRegisterValue(text: pattern, linewise: false)
    default:
      break
    }
  }

  private func applyOperation(
    _ op: VimOperator,
    evaluated: VimOperatorRange,
    register: VimRegister
  ) {
    if evaluated.isBlockwise {
      applyBlockwiseOperator(
        op,
        ranges: evaluated.blockRanges,
        width: evaluated.blockWidth,
        register: register
      )
    } else {
      apply(
        op,
        range: evaluated.range,
        register: register,
        linewise: evaluated.linewise
      )
    }
  }

  private func applyBlockwiseOperator(
    _ op: VimOperator,
    ranges: [Range<Int>],
    width: Int,
    register: VimRegister
  ) {
    guard !ranges.isEmpty else { return }
    let nonEmpty = ranges.filter { !$0.isEmpty }
    let value = VimRegisterValue(
      text: ranges.map(substring).joined(separator: "\n"),
      shape: .blockwise(width: max(1, width))
    )

    switch op {
    case .yank:
      writeOperationRegister(register, value: value, operation: .yank)
      state.cursor = ranges[0].lowerBound
      state.mode = .normal

    case .delete:
      writeOperationRegister(register, value: value, operation: .smallDelete)
      let offsets = blockOffsetsAfterDeleting(ranges)
      for range in nonEmpty.reversed() { replace(range: range, with: "") }
      state.cursor = offsets.first ?? ranges[0].lowerBound
      state.mode = .normal

    case .change:
      writeOperationRegister(register, value: value, operation: .smallDelete)
      let offsets = blockOffsetsAfterDeleting(ranges)
      for range in nonEmpty.reversed() { replace(range: range, with: "") }
      state.cursor = offsets.first ?? ranges[0].lowerBound
      state.mode = .insert
      state.selection = nil
      blockInsertSession = VimBlockInsertSession(
        originalText: state.text,
        primaryOffset: state.cursor,
        targetOffsets: Array(offsets.dropFirst()),
        append: false,
        height: ranges.count
      )

    case .uppercase, .lowercase, .swapCase, .rot13:
      for range in nonEmpty.reversed() {
        replace(
          range: range,
          with: transformedBlockText(substring(range), operation: op)
        )
      }
      state.cursor = ranges[0].lowerBound
      state.mode = .normal

    case .indent, .outdent:
      let lower = ranges.map { lineStart(at: $0.lowerBound) }.min() ?? ranges[0].lowerBound
      let upper = ranges.map { lineEndIncludingNewline(at: $0.lowerBound) }.max() ?? lower
      adjustIndent(in: lower..<max(lower, upper), delta: op == .indent ? 1 : -1)
      state.mode = .normal

    case .format:
      publishMessage(
        VimMessage(
          text: "Formatting a blockwise operator range is not supported",
          code: "E481",
          severity: .warning,
          lifetime: .timed(milliseconds: 2600)
        )
      )
    }
  }
}
