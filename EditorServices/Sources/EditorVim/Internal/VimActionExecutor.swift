import Foundation

extension VimEngine {
  func executeActionUnlocked(
    _ action: VimAction,
    count: Int,
    register: VimRegister
  ) throws -> VimExecutionResult {
    guard count > 0 else { throw VimError.invalidCount }
    let before = state
    var host: [VimHostRequest] = []

    if recording != nil, action != .stopMacro, macroDepth == 0, !isReplayingChange {
      recordingActions.append(
<<<<<<< HEAD
        semanticCommand(for: action, count: count, register: register)
=======
        VimRecordedInvocation(action: action, count: count, register: register)
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
      )
    }

    switch action {
    case .move(let motion):
      if isJumpMotion(motion) { recordJumpOrigin() }
      move(motion, count: count)

    case .enterInsert:
      beginInsertChange(action: action, count: count, register: register)
      state.mode = .insert
      state.selection = nil

    case .enterInsertAfterCursor:
      beginInsertChange(action: action, count: count, register: register)
      state.cursor = insertionOffsetAfterNormalCursor()
      state.mode = .insert
      state.selection = nil

    case .enterInsertAtLineStart:
      beginInsertChange(action: action, count: count, register: register)
      state.cursor = firstNonBlank(at: state.cursor)
      state.mode = .insert
      state.selection = nil

    case .enterInsertAtLineEnd:
      beginInsertChange(action: action, count: count, register: register)
      state.cursor = lineContentEnd(at: state.cursor)
      state.mode = .insert
      state.selection = nil

    case .enterReplace:
      beginInsertChange(action: action, count: count, register: register)
      replaceRestorations.removeAll(keepingCapacity: true)
      state.mode = .replace
      state.selection = nil

    case .escape:
      escapeToNormalMode()

    case .enterVisualCharacter:
      if state.mode == .visualCharacter {
        rememberVisualSelection()
        state.mode = .normal
        state.selection = nil
        visualAnchor = nil
      } else {
        visualAnchor = state.cursor
        state.mode = .visualCharacter
        state.selection = VimSelection(state.cursor, state.cursor)
      }

    case .enterVisualLine:
      if state.mode == .visualLine {
        rememberVisualSelection()
        state.mode = .normal
        state.selection = nil
        visualAnchor = nil
      } else {
        visualAnchor = lineStart(at: state.cursor)
        state.mode = .visualLine
        updateVisualSelection()
      }

    case .reselectVisual:
      if let lastVisual {
        visualAnchor = clamp(lastVisual.anchor)
        state.cursor = clamp(lastVisual.caret)
        state.mode = lastVisual.mode
        updateVisualSelection()
      }

    case .insert(let string):
      performMutation(action: action, count: count, register: register) {
        for _ in 0..<count { insert(string) }
      }

    case .replaceCharacter(let character):
      performMutation(action: action, count: count, register: register) {
        replaceCharacter(character, count: count)
      }
      normalizeCursorForMode()

    case .insertNewline:
      performMutation(action: action, count: count, register: register) {
        insert(String(repeating: "\n", count: count))
      }

    case .openLineBelow:
      beginInsertChange(action: action, count: count, register: register)
      let contentEnd = lineContentEnd(at: state.cursor)
      if lineHasTerminator(at: state.cursor) {
        let insertion = lineEndIncludingNewline(at: state.cursor)
        state.cursor = insertion
        insert(String(repeating: "\n", count: count))
        state.cursor = insertion + max(0, count - 1)
      } else {
        state.cursor = contentEnd
        insert(String(repeating: "\n", count: count))
        state.cursor = contentEnd + count
      }
      markActiveChangeIfNeeded()
      state.mode = .insert

    case .openLineAbove:
      beginInsertChange(action: action, count: count, register: register)
      let start = lineStart(at: state.cursor)
      state.cursor = start
      insert(String(repeating: "\n", count: count))
      state.cursor = start + max(0, count - 1)
      markActiveChangeIfNeeded()
      state.mode = .insert

    case .deleteCharacter:
      let deletionRegister: VimRegister =
        state.mode == .insert || state.mode == .replace ? .blackHole : register
      performMutation(action: action, count: count, register: register) {
        let upper = min(
          lineContentEnd(at: state.cursor), advanceCharacters(from: state.cursor, count: count))
        delete(
          range: state.cursor..<max(state.cursor, upper),
          register: deletionRegister,
          linewise: false
        )
      }
      normalizeCursorForMode()

    case .deleteBeforeCursor:
      if state.mode == .replace, !replaceRestorations.isEmpty {
        performMutation(action: action, count: count, register: register) {
          restoreReplacedTextBeforeCursor(count: count)
        }
      } else {
        let deletionRegister: VimRegister =
          state.mode == .insert || state.mode == .replace ? .blackHole : register
        performMutation(action: action, count: count, register: register) {
          let lowerLimit =
            state.mode == .insert || state.mode == .replace ? lineStart(at: state.cursor) : 0
          let start = max(lowerLimit, advanceCharacters(from: state.cursor, count: -count))
          delete(range: start..<state.cursor, register: deletionRegister, linewise: false)
          state.cursor = start
        }
      }
      normalizeCursorForMode()

    case .substituteCharacter:
      beginInsertChange(action: action, count: count, register: register)
      let upper = min(
        lineContentEnd(at: state.cursor), advanceCharacters(from: state.cursor, count: count))
      delete(range: state.cursor..<max(state.cursor, upper), register: register, linewise: false)
      markActiveChangeIfNeeded()
      state.mode = .insert

    case .joinLines:
      performMutation(action: action, count: count, register: register) {
        let joins = count <= 1 ? 1 : count - 1
        for _ in 0..<joins { joinLine() }
      }
      normalizeCursorForMode()

    case .operatorMotion(let op, let motion):
      let evaluated: VimOperatorRange
      if op == .change, motion == .wordForward,
        wordClass(at: state.cursor, whole: false) != .whitespace
      {
        evaluated = operatorRange(for: .wordEnd, count: count)
      } else {
        evaluated = operatorRange(for: motion, count: count)
      }
      if op == .change {
        beginInsertChange(action: action, count: count, register: register)
        apply(op, range: evaluated.range, register: register, linewise: evaluated.linewise)
        markActiveChangeIfNeeded()
      } else {
        performMutation(action: action, count: count, register: register) {
          apply(op, range: evaluated.range, register: register, linewise: evaluated.linewise)
        }
        if op == .swapCase, motion == .right {
          state.cursor = min(evaluated.range.upperBound, state.text.utf16.count)
        }
      }
      normalizeCursorForMode()

    case .operatorLine(let op):
      let range = linewiseRange(from: state.cursor, count: count)
      if op == .change {
        beginInsertChange(action: action, count: count, register: register)
        apply(op, range: range, register: register, linewise: true)
        markActiveChangeIfNeeded()
      } else {
        performMutation(action: action, count: count, register: register) {
          apply(op, range: range, register: register, linewise: true)
        }
      }
      normalizeCursorForMode()

    case .operatorTextObject(let op, let object, let inner):
      let range = textObjectRange(object, inner: inner, count: count)
      if op == .change {
        beginInsertChange(action: action, count: count, register: register)
        apply(op, range: range, register: register, linewise: object == .paragraph)
        markActiveChangeIfNeeded()
      } else {
        performMutation(action: action, count: count, register: register) {
          apply(op, range: range, register: register, linewise: object == .paragraph)
        }
      }
      normalizeCursorForMode()

    case .operatorSelection(let op):
      guard let visual = visualRange() else { break }
      let wasLinewise = state.mode == .visualLine
      rememberVisualSelection()
      if op == .change {
        beginInsertChange(action: action, count: count, register: register)
        apply(op, range: visual, register: register, linewise: wasLinewise)
        markActiveChangeIfNeeded()
      } else {
        performMutation(action: action, count: count, register: register) {
          apply(op, range: visual, register: register, linewise: wasLinewise)
        }
        state.mode = .normal
      }
      state.selection = nil
      visualAnchor = nil
      normalizeCursorForMode()

    case .undo:
      cancelOpenChangeWithoutCommit()
<<<<<<< HEAD
      if let entry = undoTree.transactionForUndo(), !applyHistory(entry, forward: false) {
        undoTree.append(entry)
=======
      if let entry = undoStack.popLast(), applyHistory(entry, forward: false) {
        redoStack.append(entry)
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
      }

    case .redo:
      cancelOpenChangeWithoutCommit()
<<<<<<< HEAD
      if let entry = undoTree.transactionForRedo() {
        _ = applyHistory(entry, forward: true)
=======
      if let entry = redoStack.popLast(), applyHistory(entry, forward: true) {
        undoStack.append(entry)
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
      }

    case .repeatLastChange:
      try repeatRecordedChange(count: count)

    case .pasteAfter:
      performMutation(action: action, count: count, register: register) {
        paste(registerValue(for: register), after: true, count: count)
      }
      normalizeCursorForMode()

    case .pasteBefore:
      performMutation(action: action, count: count, register: register) {
        paste(registerValue(for: register), after: false, count: count)
      }
      normalizeCursorForMode()

    case .setMark(let name):
      marks[name] = state.cursor

    case .jumpToMark(let name, let linewise):
      if let position = marks[name] {
        recordJumpOrigin()
        state.cursor = linewise ? firstNonBlank(at: position) : clamp(position)
        preferredColumn = nil
        normalizeCursorForMode()
        updateVisualSelection()
      }

    case .startMacro(let name):
      let normalized = normalizedMacroName(name)
      recording = normalized
      recordingActions = name.isUppercase ? (macros[normalized] ?? []) : []

    case .stopMacro:
      if let name = recording { macros[name] = recordingActions }
      recording = nil
      recordingActions = []

    case .playMacro(let requested):
      let name: Character
      if requested == "@", let lastPlayedMacro {
        name = lastPlayedMacro
      } else {
        name = normalizedMacroName(requested)
      }
      guard macroDepth < macroRecursionLimit else { throw VimError.macroRecursionLimit }
      lastPlayedMacro = name
      macroDepth += 1
      defer { macroDepth -= 1 }
      for _ in 0..<count {
        for item in macros[name] ?? [] {
<<<<<<< HEAD
          _ = try replay(item)
=======
          _ = try execute(item.action, count: item.count, register: item.register)
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
        }
      }

    case .search(let query, let forward):
      let resolved = query.isEmpty ? lastSearch?.0 ?? "" : query
      if !resolved.isEmpty {
        recordJumpOrigin()
        lastSearch = (resolved, forward)
        registers[.named("/")] = VimRegisterValue(text: resolved, linewise: false)
        search(resolved, forward: forward)
      }

    case .nextSearch:
      if let (query, forward) = lastSearch {
        recordJumpOrigin()
        for _ in 0..<count { search(query, forward: forward) }
      }

    case .previousSearch:
      if let (query, forward) = lastSearch {
        recordJumpOrigin()
        for _ in 0..<count { search(query, forward: !forward) }
      }

    case .command(let command):
      registers[.named(":")] = VimRegisterValue(text: command, linewise: false)
      host.append(contentsOf: try executeEx(command))

    case .host(let request):
      host.append(request)

    case .leader(let sequence):
      return try execute(.leader(sequence))

    case .localLeader(let sequence):
      return try execute(.localLeader(sequence))
    }

    return VimExecutionResult(
      state: state,
      hostRequests: host,
      didChangeText: before.text != state.text
    )
  }
}
