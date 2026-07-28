import Foundation

#if canImport(AppKit)
  import AppKit
#endif

extension VimEngine {
  private func resolvedSemanticCommand(
    action: VimAction?,
    count: Int,
    register: VimRegister,
    explicit: VimSemanticCommand?
  ) -> VimSemanticCommand {
    if let explicit { return explicit }
    guard let action else {
      preconditionFailure("A mutation requires either a public action or a semantic command")
    }
    return semanticCommand(for: action, count: count, register: register)
  }

  func beginInsertChange(
    action: VimAction?,
    count: Int,
    register: VimRegister,
    semanticCommand resolvedCommand: VimSemanticCommand? = nil
  ) {
    if activeChange == nil {
      beginEditCapture()
      let repeatsInsertedText: Bool
      switch action {
      case .some(.enterInsert), .some(.enterInsertAfterCursor), .some(.enterInsertAtLineStart),
        .some(.enterInsertAtLineEnd):
        repeatsInsertedText = true
      default:
        repeatsInsertedText = false
      }
      activeChange = VimChangeSession(
        before: state,
        commands: [
          resolvedSemanticCommand(
            action: action,
            count: count,
            register: register,
            explicit: resolvedCommand
          )
        ],
        changedText: false,
        insertRepeatCount: repeatsInsertedText ? count : 1
      )
    } else {
      activeChange?.commands.append(
        resolvedSemanticCommand(
          action: action,
          count: count,
          register: register,
          explicit: resolvedCommand
        ))
    }
  }

  func markActiveChangeIfNeeded() {
    guard var session = activeChange else { return }
    session.changedText = session.changedText || session.before.text != state.text
    activeChange = session
  }

  func performMutation(
    action: VimAction?,
    count: Int,
    register: VimRegister,
    semanticCommand resolvedCommand: VimSemanticCommand? = nil,
    _ body: () -> Void
  ) {
    let command = resolvedSemanticCommand(
      action: action,
      count: count,
      register: register,
      explicit: resolvedCommand
    )
    if activeChange != nil {
      let oldText = state.text
      activeChange?.commands.append(command)
      body()
      if oldText != state.text { activeChange?.changedText = true }
      return
    }

    let before = state
    beginEditCapture()
    body()
    let edits = endEditCapture()
    guard before.text != state.text else { return }
    pushUndo(before, edits: edits)
    if !isReplayingChange {
      if let action { lastChange = action }
      lastRepeat = VimRepeatRecord(
        commands: [command],
        finishesInInsertMode: state.mode == .insert || state.mode == .replace
      )
    }
  }

  func escapeToNormalMode() {
    let previousMode = state.mode
    if previousMode == .insert, blockInsertSession != nil {
      replicateVisualBlockInsertionIfNeeded()
    }
    if previousMode == .visualCharacter || previousMode == .visualLine {
      rememberVisualSelection()
    }

    let session = activeChange
    if let session, previousMode == .insert, session.insertRepeatCount > 1 {
      applyCountedInsertRepeat(session)
    }

    if let session,
      let delta = VimEditDelta.between(session.before.text, and: state.text),
      !delta.insertedText.isEmpty
    {
      lastInsertedText = delta.insertedText
    }

    if previousMode == .insert || previousMode == .replace {
      let start = lineStart(at: state.cursor)
      if state.cursor > start {
        state.cursor = previousCharacterBoundary(from: state.cursor)
      }
    }

    state.mode = .normal
    state.selection = nil
    visualAnchor = nil
    visualSelectionShape = .character
    blockInsertSession = nil
    preferredColumn = nil
    preferredVisualColumn = nil
    replaceRestorations.removeAll(keepingCapacity: true)

    if let session {
      activeChange = nil
      let edits = endEditCapture()
      if session.changedText || session.before.text != state.text {
        pushUndo(session.before, edits: edits)
        if !isReplayingChange {
          if case .action(let action, _, _) = session.commands.first {
            lastChange = action
          }
          lastRepeat = VimRepeatRecord(commands: session.commands, finishesInInsertMode: true)
        }
      }
    } else if editCaptureDepth > 0 {
      _ = endEditCapture()
    }
    normalizeCursorForMode()
  }

  func applyCountedInsertRepeat(_ session: VimChangeSession) {
    guard session.insertRepeatCount > 1,
      let delta = VimEditDelta.between(session.before.text, and: state.text),
      delta.removedText.isEmpty,
      !delta.insertedText.isEmpty
    else { return }

    let insertion = delta.location + delta.insertedUTF16Count
    let extra = String(repeating: delta.insertedText, count: session.insertRepeatCount - 1)
    replace(range: insertion..<insertion, with: extra)
  }

  func cancelOpenChangeWithoutCommit() {
    activeChange = nil
    if editCaptureDepth > 0 { _ = endEditCapture() }
    replaceRestorations.removeAll(keepingCapacity: true)
    if state.mode == .insert || state.mode == .replace {
      state.mode = .normal
      normalizeCursorForMode()
    }
  }

  func pushUndo(_ value: VimState, edits: [VimEditDelta] = []) {
    guard historySuppressionDepth == 0,
      let entry = VimHistoryEntry.make(before: value, after: state, edits: edits)
    else { return }
    undoTree.append(entry)
    recordChangePosition(value.cursor)
  }

  @discardableResult
  func applyHistory(_ entry: VimHistoryEntry, forward: Bool) -> Bool {
    let updatedText =
      forward
      ? entry.applyingForward(to: state.text)
      : entry.applyingBackward(to: state.text)
    guard let updatedText else { return false }

    state = (forward ? entry.after : entry.before).applying(to: updatedText)
    recordHistoryApplication(entry, forward: forward)
    lineIndex.invalidate()
    state.mode = .normal
    state.selection = nil
    visualAnchor = nil
    visualSelectionShape = .character
    blockInsertSession = nil
    preferredColumn = nil
    preferredVisualColumn = nil
    normalizeCursorForMode()
    return true
  }

  func repeatRecordedChange(count: Int) throws {
    guard let record = lastRepeat else {
      if let lastChange { _ = try execute(lastChange, count: count) }
      return
    }

    let before = state
    beginEditCapture()
    var captureEnded = false
    historySuppressionDepth += 1
    isReplayingChange = true
    defer {
      if !captureEnded, editCaptureDepth > 0 { _ = endEditCapture() }
      isReplayingChange = false
      historySuppressionDepth -= 1
    }

    for _ in 0..<count {
      for command in record.commands {
        _ = try replay(command)
      }
      if record.finishesInInsertMode, state.mode == .insert || state.mode == .replace {
        _ = try execute(.escape)
      }
    }

    let edits = endEditCapture()
    captureEnded = true
    if let entry = VimHistoryEntry.make(before: before, after: state, edits: edits) {
      undoTree.append(entry)
      recordChangePosition(before.cursor)
    }
    lastRepeat = record
  }

  func beginEditCapture() {
    if editCaptureDepth == 0 { capturedEdits.removeAll(keepingCapacity: true) }
    editCaptureDepth += 1
  }

  @discardableResult
  func endEditCapture() -> [VimEditDelta] {
    guard editCaptureDepth > 0 else { return [] }
    editCaptureDepth -= 1
    guard editCaptureDepth == 0 else { return [] }
    let result = capturedEdits
    capturedEdits.removeAll(keepingCapacity: true)
    return result
  }

  func recordEdit(_ edit: VimEditDelta) {
    recordExecutionEdit(edit)
    guard editCaptureDepth > 0 else { return }
    capturedEdits.append(edit)
  }

  func insert(_ string: String) {
    guard !string.isEmpty else { return }
    let insertionOffset = state.cursor
    let replacedRange: Range<Int>
    if state.mode == .replace, insertionOffset < lineContentEnd(at: insertionOffset) {
      let replacementCount = max(1, string.count)
      let endOffset = min(
        lineContentEnd(at: insertionOffset),
        advanceCharacters(from: insertionOffset, count: replacementCount)
      )
      let original = substring(insertionOffset..<endOffset)
      replaceRestorations.append(
        VimReplaceRestoration(
          location: insertionOffset,
          originalText: original,
          insertedUTF16Count: string.utf16.count
        )
      )
      replacedRange = insertionOffset..<endOffset
    } else {
      if state.mode == .replace {
        replaceRestorations.append(
          VimReplaceRestoration(
            location: insertionOffset,
            originalText: "",
            insertedUTF16Count: string.utf16.count
          )
        )
      }
      replacedRange = insertionOffset..<insertionOffset
    }
    replace(range: replacedRange, with: string)
    state.cursor = normalizedVimUTF16Offset(
      insertionOffset + string.utf16.count,
      in: state.text
    )
  }

  func replaceCharacter(_ character: Character, count: Int) {
    let start = state.cursor
    let end = min(lineContentEnd(at: start), advanceCharacters(from: start, count: count))
    guard end > start else { return }
    let replacement = String(
      repeating: String(character),
      count: characterDistance(from: start, to: end)
    )
    replace(range: start..<end, with: replacement)
    state.cursor =
      replacement.isEmpty
      ? start
      : previousCharacterBoundary(from: start + replacement.utf16.count)
  }

  func restoreReplacedTextBeforeCursor(count: Int) {
    for _ in 0..<max(1, count) {
      guard let restoration = replaceRestorations.last else { return }
      let expectedCursor = restoration.location + restoration.insertedUTF16Count
      guard state.cursor == expectedCursor else { return }
      replaceRestorations.removeLast()
      replace(
        range: restoration.location..<expectedCursor,
        with: restoration.originalText
      )
      state.cursor = restoration.location
    }
  }

  func delete(range: Range<Int>, register: VimRegister, linewise: Bool) {
    let r = normalized(range)
    guard !r.isEmpty else { return }
    let startsAtColumnZero = r.lowerBound == lineStart(at: r.lowerBound)
    let crossesLine = containsNewline(r)
    let a = stringIndex(r.lowerBound)
    let b = stringIndex(r.upperBound)
    var removed = String(state.text[a..<b])
    if linewise, !removed.hasSuffix("\n"), !removed.hasSuffix("\r") {
      removed.append("\n")
    }
    writeOperationRegister(
      register,
      value: VimRegisterValue(text: removed, linewise: linewise),
      operation: linewise || containsNewline(r) ? .lineDelete : .smallDelete
    )
    let replacement =
      r.lowerBound == 0 && r.upperBound == state.text.utf16.count
      ? blankLineTerminator(for: r)
      : ""
    replace(range: r, with: replacement)
    if linewise {
      guard !state.text.isEmpty else {
        state.cursor = 0
        return
      }
      var target = min(r.lowerBound, state.text.utf16.count)
      if target == state.text.utf16.count {
        target = previousCharacterBoundary(from: target)
      }
      state.cursor = firstNonBlank(at: lineStart(at: target))
    } else {
      state.cursor = clamp(r.lowerBound)
      if crossesLine, startsAtColumnZero {
        state.cursor = firstNonBlank(at: lineStart(at: state.cursor))
      }
    }
  }

  func blankLineTerminator(for range: Range<Int>) -> String {
    guard !state.text.isEmpty else { return "\n" }
    let probe = min(range.lowerBound, max(0, state.text.utf16.count - 1))
    let contentEnd = lineContentEnd(at: probe)
    let lineEnd = lineEndIncludingNewline(at: probe)
    if lineEnd > contentEnd {
      let terminator = substring(contentEnd..<lineEnd)
      if !terminator.isEmpty { return terminator }
    }
    return "\n"
  }

  func changeLinewise(range: Range<Int>, register: VimRegister) {
    let r = normalized(range)
    guard !r.isEmpty else { return }
    var removed = substring(r)
    if !removed.hasSuffix("\n"), !removed.hasSuffix("\r") {
      removed.append("\n")
    }
    writeOperationRegister(
      register,
      value: VimRegisterValue(text: removed, linewise: true),
      operation: .lineDelete
    )
    let terminator = blankLineTerminator(for: r)
    replace(range: r, with: terminator)
    state.cursor = min(r.lowerBound, state.text.utf16.count)
  }

  enum VimRegisterOperation {
    case yank
    case smallDelete
    case lineDelete
  }

  func registerValue(for requested: VimRegister) -> VimRegisterValue {
    let (register, _) = normalizedRegister(requested)
    if register == .named(".") {
      return VimRegisterValue(text: lastInsertedText, linewise: false)
    }
    if register == .named("/"), let pattern = lastSearch?.0 {
      return VimRegisterValue(text: pattern, linewise: false)
    }
    #if canImport(AppKit)
      if register == .clipboard,
        let value = NSPasteboard.general.string(forType: .string)
      {
        return VimRegisterValue(
          text: value,
          linewise: value.hasSuffix("\n") || value.hasSuffix("\r")
        )
      }
    #endif
    return registers[register] ?? VimRegisterValue(text: "", linewise: false)
  }

  func normalizedRegister(_ requested: VimRegister) -> (VimRegister, append: Bool) {
    guard case .named(let name) = requested else { return (requested, false) }
    let lower = Character(String(name).lowercased())
    return (.named(lower), name.isUppercase)
  }

  func writeExplicitRegister(_ requested: VimRegister, value: VimRegisterValue) {
    let (target, append) = normalizedRegister(requested)
    let resolved: VimRegisterValue
    if append, let previous = registers[target] {
      let shape: VimRegisterShape
      switch (previous.shape, value.shape) {
      case (.blockwise(let lhs), .blockwise(let rhs)):
        shape = .blockwise(width: max(lhs, rhs))
      case (.linewise, _), (_, .linewise):
        shape = .linewise
      default:
        shape = .characterwise
      }
      resolved = VimRegisterValue(text: previous.text + value.text, shape: shape)
    } else {
      resolved = value
    }
    registers[target] = resolved
    #if canImport(AppKit)
      if target == .clipboard {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resolved.text, forType: .string)
      }
    #endif
  }

  func writeOperationRegister(
    _ requested: VimRegister,
    value: VimRegisterValue,
    operation: VimRegisterOperation
  ) {
    guard requested != .blackHole else { return }
    writeExplicitRegister(requested, value: value)
    registers[.unnamed] = value

    switch operation {
    case .yank:
      registers[.numbered(0)] = value
    case .smallDelete:
      registers[.smallDelete] = value
    case .lineDelete:
      for number in stride(from: 9, through: 2, by: -1) {
        registers[.numbered(number)] = registers[.numbered(number - 1)]
      }
      registers[.numbered(1)] = value
    }
  }

  func pasteOverVisual(
    _ value: VimRegisterValue,
    count: Int,
    sourceRegister: VimRegister
  ) {
    guard let range = visualRange() else { return }
    let wasLinewise = state.mode == .visualLine
    rememberVisualSelection()
    let semantic = VimSemanticCommand.paste(value, after: false, count: count)
    performMutation(
      action: .pasteBefore,
      count: count,
      register: sourceRegister,
      semanticCommand: semantic
    ) {
      delete(range: range, register: .unnamed, linewise: wasLinewise)
      state.cursor = min(range.lowerBound, state.text.utf16.count)
      paste(value, after: false, count: count)
    }
    state.mode = .normal
    state.selection = nil
    visualAnchor = nil
    visualSelectionShape = .character
    normalizeCursorForMode()
  }

  func paste(_ value: VimRegisterValue, after: Bool, count: Int) {
    guard !value.text.isEmpty else { return }
    switch value.shape {
    case .linewise:
      pasteLinewise(value.text, after: after, count: count)
    case .blockwise:
      pasteBlockwise(value, after: after, count: count)
    case .characterwise:
      pasteCharacterwise(value.text, after: after, count: count)
    }
    state.mode = .normal
  }

  func pasteCharacterwise(_ string: String, after: Bool, count: Int) {
    let insertion: Int
    if after, state.cursor < lineContentEnd(at: state.cursor) {
      insertion = nextCharacterBoundary(from: state.cursor)
    } else {
      insertion = state.cursor
    }
    state.cursor = insertion
    let payload = String(repeating: string, count: count)
    insert(payload)
    state.cursor = payload.isEmpty ? insertion : previousCharacterBoundary(from: state.cursor)
  }

  func pasteLinewise(_ raw: String, after: Bool, count: Int) {
    let repeated = String(repeating: raw, count: count)
    let payload = repeated.hasSuffix("\n") ? repeated : repeated + "\n"
    if state.text.isEmpty {
      state.cursor = 0
      insert(String(payload.dropLast()))
      state.cursor = firstNonBlank(at: 0)
      return
    }
    let currentStart = lineStart(at: state.cursor)
    let currentEnd = lineEndIncludingNewline(at: state.cursor)

    if after {
      if currentEnd < state.text.utf16.count || lineHasTerminator(at: state.cursor) {
        state.cursor = currentEnd
        insert(payload)
        state.cursor = currentEnd
      } else {
        let body = String(payload.dropLast())
        state.cursor = state.text.utf16.count
        insert("\n" + body)
        state.cursor = currentEnd + 1
      }
    } else {
      state.cursor = currentStart
      insert(payload)
      state.cursor = currentStart
    }
    state.cursor = firstNonBlank(at: state.cursor)
  }

  func apply(
    _ op: VimOperator,
    range: Range<Int>,
    register: VimRegister,
    linewise: Bool
  ) {
    let r = normalized(range)
    guard !r.isEmpty || op == .format else { return }

    switch op {
    case .delete:
      delete(range: r, register: register, linewise: linewise)
      state.mode = .normal

    case .change:
      if linewise {
        changeLinewise(range: r, register: register)
      } else {
        delete(range: r, register: register, linewise: false)
      }
      state.mode = .insert
      if state.cursor > state.text.utf16.count {
        state.cursor = state.text.utf16.count
      }

    case .yank:
      let a = stringIndex(r.lowerBound)
      let b = stringIndex(r.upperBound)
      var value = String(state.text[a..<b])
      if linewise, !value.hasSuffix("\n"), !value.hasSuffix("\r") { value.append("\n") }
      writeOperationRegister(
        register,
        value: VimRegisterValue(text: value, linewise: linewise),
        operation: .yank
      )
      state.cursor = r.lowerBound

    case .uppercase, .lowercase, .swapCase, .rot13:
      let a = stringIndex(r.lowerBound)
      let b = stringIndex(r.upperBound)
      let old = String(state.text[a..<b])
      let new: String
      switch op {
      case .uppercase:
        new = old.uppercased()
      case .lowercase:
        new = old.lowercased()
      case .swapCase:
        new = old.map { character in
          let source = String(character)
          if source == source.uppercased(), source != source.lowercased() {
            return source.lowercased()
          }
          if source == source.lowercased(), source != source.uppercased() {
            return source.uppercased()
          }
          return source
        }.joined()
      default:
        new = String(
          old.unicodeScalars.map { scalar in
            let value = scalar.value
            if (65...90).contains(value),
              let transformed = UnicodeScalar(65 + (value - 65 + 13) % 26)
            {
              return Character(transformed)
            }
            if (97...122).contains(value),
              let transformed = UnicodeScalar(97 + (value - 97 + 13) % 26)
            {
              return Character(transformed)
            }
            return Character(String(scalar))
          })
      }
      replace(range: r, with: new)
      state.cursor = r.lowerBound

    case .indent:
      adjustIndent(in: r, delta: 1)

    case .outdent:
      adjustIndent(in: r, delta: -1)

    case .format:
      formatText(in: r)
      state.cursor = r.lowerBound
    }
  }

  func formatText(in range: Range<Int>) {
    let source = substring(range)
    guard !source.isEmpty else { return }

    let lineTerminator: String
    if source.contains("\r\n") {
      lineTerminator = "\r\n"
    } else if source.contains("\r") {
      lineTerminator = "\r"
    } else {
      lineTerminator = "\n"
    }
    let hasFinalTerminator = source.hasSuffix("\n") || source.hasSuffix("\r")
    let normalized =
      source
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if hasFinalTerminator, lines.last == "" { lines.removeLast() }

    let width = max(1, textWidth == 0 ? 79 : textWidth)
    var formatted: [String] = []
    var index = 0
    while index < lines.count {
      if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
        formatted.append("")
        index += 1
        continue
      }

      let indentation = String(lines[index].prefix { $0 == " " || $0 == "\t" })
      var words: [Substring] = []
      while index < lines.count,
        !lines[index].trimmingCharacters(in: .whitespaces).isEmpty
      {
        words.append(
          contentsOf: lines[index].split(whereSeparator: { $0.isWhitespace })
        )
        index += 1
      }

      var line = indentation
      for word in words {
        let candidateLength = line.utf16.count + (line == indentation ? 0 : 1) + word.utf16.count
        if line != indentation, candidateLength > width {
          formatted.append(line)
          line = indentation + word
        } else {
          if line != indentation { line.append(" ") }
          line.append(contentsOf: word)
        }
      }
      formatted.append(line)
    }

    var replacement = formatted.joined(separator: lineTerminator)
    if hasFinalTerminator { replacement += lineTerminator }
    replace(range: range, with: replacement)
  }

  func adjustIndent(in range: Range<Int>, delta: Int) {
    let source = state.text as NSString
    var starts: [Int] = []
    var location = lineStart(at: range.lowerBound)
    let upper = max(location, range.upperBound)
    while location < upper, location <= source.length {
      starts.append(location)
      let line = source.lineRange(for: NSRange(location: min(location, source.length), length: 0))
      let next = NSMaxRange(line)
      if next <= location || next > upper { break }
      location = next
    }

    let originalCursor = state.cursor
    for start in starts.reversed() {
      if delta > 0 {
        replace(
          range: start..<start,
          with: String(repeating: " ", count: tabWidth)
        )
      } else {
        let current = state.text as NSString
        guard start < current.length else { continue }
        let lineEnd = NSMaxRange(current.lineRange(for: NSRange(location: start, length: 0)))
        var removal = 0
        if current.character(at: start) == 9 {
          removal = 1
        } else {
          while removal < tabWidth, start + removal < lineEnd,
            current.character(at: start + removal) == 32
          {
            removal += 1
          }
        }
        guard removal > 0 else { continue }
        replace(range: start..<(start + removal), with: "")
      }
    }
    if let first = starts.first {
      state.cursor = firstNonBlank(at: first)
    } else {
      state.cursor = originalCursor
    }
  }
}
