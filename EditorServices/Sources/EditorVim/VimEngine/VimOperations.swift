import Foundation

extension VimEngine {
  func move(_ motion: VimMotion, count: Int) {
    let result = motionResult(for: motion, count: count)
    state.cursor = result.destination
    normalizeCursorForCurrentMode()
    refreshSelectionRanges()
  }

  func motionResult(for motion: VimMotion, count: Int) -> VimMotionResult {
    let source = buffer
    let effectiveCount = max(1, count)
    var destination = state.cursor
    var kind: VimRegisterKind = .characterwise
    var inclusive = false

    switch motion {
    case .left:
      preferredVisualColumn = nil
      if state.mode == .insert || state.mode == .replace {
        destination = source.advance(from: destination, by: -effectiveCount)
      } else {
        destination = max(
          source.lineStart(at: destination),
          source.advance(from: destination, by: -effectiveCount)
        )
      }

    case .right:
      preferredVisualColumn = nil
      if state.mode == .insert || state.mode == .replace {
        destination = source.advance(from: destination, by: effectiveCount)
      } else {
        destination = min(
          source.normalLineEnd(at: destination),
          source.advance(from: destination, by: effectiveCount)
        )
      }

    case .up:
      kind = .linewise
      destination = verticalDestination(from: destination, delta: -effectiveCount)

    case .down:
      kind = .linewise
      destination = verticalDestination(from: destination, delta: effectiveCount)

    case .lineStart:
      preferredVisualColumn = nil
      destination = source.lineStart(at: destination)

    case .firstNonBlank:
      preferredVisualColumn = nil
      destination = source.firstNonBlank(at: destination)

    case .lineEnd:
      preferredVisualColumn = nil
      for _ in 1..<effectiveCount {
        let next = source.nextLineStart(from: destination)
        if next == destination || next >= source.length { break }
        destination = next
      }
      destination = source.normalLineEnd(at: destination)
      inclusive = true

    case .lineContentEnd:
      preferredVisualColumn = nil
      destination = source.lineContentEnd(at: destination)

    case .nextLineFirstNonBlank:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount {
        destination = source.nextLineStart(from: destination)
      }
      destination = source.firstNonBlank(at: destination)

    case .previousLineFirstNonBlank:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount {
        destination = source.previousLineStart(from: destination)
      }
      destination = source.firstNonBlank(at: destination)

    case .currentLineFirstNonBlank:
      preferredVisualColumn = nil
      for _ in 1..<effectiveCount {
        destination = source.nextLineStart(from: destination)
      }
      destination = source.firstNonBlank(at: destination)

    case .column(let column):
      preferredVisualColumn = nil
      let start = source.lineStart(at: destination)
      destination = source.offset(
        inLineStartingAt: start,
        visualColumn: max(0, column - 1),
        tabWidth: tabWidth
      )

    case .wordForward:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount { destination = source.nextWordStart(from: destination) }

    case .bigWordForward:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount {
        destination = source.nextWordStart(from: destination, bigWord: true)
      }

    case .wordBackward:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount { destination = source.previousWordStart(from: destination) }

    case .bigWordBackward:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount {
        destination = source.previousWordStart(from: destination, bigWord: true)
      }

    case .wordEnd:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount { destination = source.wordEnd(from: destination) }
      inclusive = true

    case .bigWordEnd:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount {
        destination = source.wordEnd(from: destination, bigWord: true)
      }
      inclusive = true

    case .wordEndBackward:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount { destination = source.previousWordEnd(from: destination) }
      inclusive = true

    case .bigWordEndBackward:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount {
        destination = source.previousWordEnd(from: destination, bigWord: true)
      }
      inclusive = true

    case .sentenceForward:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount { destination = source.sentenceForward(from: destination) }

    case .sentenceBackward:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount { destination = source.sentenceBackward(from: destination) }

    case .paragraphForward:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount { destination = source.paragraphForward(from: destination) }

    case .paragraphBackward:
      preferredVisualColumn = nil
      for _ in 0..<effectiveCount { destination = source.paragraphBackward(from: destination) }

    case .documentStart:
      preferredVisualColumn = nil
      kind = .linewise
      destination = effectiveCount > 1 ? source.offsetOfLine(effectiveCount) : 0
      destination = source.firstNonBlank(at: destination)

    case .documentEnd:
      preferredVisualColumn = nil
      kind = .linewise
      if effectiveCount > 1 {
        destination = source.offsetOfLine(effectiveCount)
        destination = source.firstNonBlank(at: destination)
      } else {
        destination = source.normalDocumentEnd()
      }

    case .screenTop:
      preferredVisualColumn = nil
      destination = source.firstNonBlank(at: 0)

    case .screenMiddle:
      preferredVisualColumn = nil
      let total = max(1, source.lineNumber(at: source.length))
      destination = source.firstNonBlank(at: source.offsetOfLine((total + 1) / 2))

    case .screenBottom:
      preferredVisualColumn = nil
      destination = source.firstNonBlank(at: source.lastLineStart())

    case .pageUp:
      kind = .linewise
      destination = verticalDestination(
        from: destination,
        delta: -(scrollPageLineCount * effectiveCount)
      )

    case .pageDown:
      kind = .linewise
      destination = verticalDestination(
        from: destination,
        delta: scrollPageLineCount * effectiveCount
      )

    case .halfPageUp:
      kind = .linewise
      destination = verticalDestination(
        from: destination,
        delta: -(scrollHalfPageLineCount * effectiveCount)
      )

    case .halfPageDown:
      kind = .linewise
      destination = verticalDestination(
        from: destination,
        delta: scrollHalfPageLineCount * effectiveCount
      )

    case .findForward(let character):
      preferredVisualColumn = nil
      lastFind = VimFindState(character: character, forward: true, till: false)
      destination =
        source.find(
          character,
          from: destination,
          forward: true,
          till: false,
          count: effectiveCount
        ) ?? destination
      inclusive = true

    case .findBackward(let character):
      preferredVisualColumn = nil
      lastFind = VimFindState(character: character, forward: false, till: false)
      destination =
        source.find(
          character,
          from: destination,
          forward: false,
          till: false,
          count: effectiveCount
        ) ?? destination
      inclusive = true

    case .tillForward(let character):
      preferredVisualColumn = nil
      lastFind = VimFindState(character: character, forward: true, till: true)
      destination =
        source.find(
          character,
          from: destination,
          forward: true,
          till: true,
          count: effectiveCount
        ) ?? destination
      inclusive = true

    case .tillBackward(let character):
      preferredVisualColumn = nil
      lastFind = VimFindState(character: character, forward: false, till: true)
      destination =
        source.find(
          character,
          from: destination,
          forward: false,
          till: true,
          count: effectiveCount
        ) ?? destination
      inclusive = true

    case .repeatFind(let reverse):
      preferredVisualColumn = nil
      if let lastFind {
        let forward = reverse ? !lastFind.forward : lastFind.forward
        destination =
          source.find(
            lastFind.character,
            from: destination,
            forward: forward,
            till: lastFind.till,
            count: effectiveCount
          ) ?? destination
        inclusive = true
      }

    case .matchingPair:
      preferredVisualColumn = nil
      destination = source.matchingPair(from: destination) ?? destination
      inclusive = true

    case .line(let number):
      preferredVisualColumn = nil
      kind = .linewise
      destination = source.firstNonBlank(at: source.offsetOfLine(max(1, number)))
    }

    return VimMotionResult(destination: destination, kind: kind, inclusive: inclusive)
  }

  func verticalDestination(from offset: Int, delta: Int) -> Int {
    let source = buffer
    let desiredColumn =
      preferredVisualColumn
      ?? source.visualColumn(at: offset, tabWidth: tabWidth)
    preferredVisualColumn = desiredColumn
    var lineStart = source.lineStart(at: offset)
    if delta < 0 {
      for _ in 0..<(-delta) {
        let previous = source.previousLineStart(from: lineStart)
        if previous == lineStart { break }
        lineStart = previous
      }
    } else {
      for _ in 0..<delta {
        let next = source.nextLineStart(from: lineStart)
        if next == lineStart || next > source.length { break }
        lineStart = next
      }
    }
    return source.offset(
      inLineStartingAt: lineStart,
      visualColumn: desiredColumn,
      tabWidth: tabWidth
    )
  }

  func target(for motion: VimMotion, count: Int) -> VimOperationTarget {
    let start = state.cursor
    let result = motionResult(for: motion, count: count)
    if result.kind == .linewise {
      let lower = buffer.lineStart(at: min(start, result.destination))
      let upper = buffer.lineFullEnd(at: max(start, result.destination))
      return VimOperationTarget(ranges: [lower..<upper], kind: .linewise)
    }

    let lower = min(start, result.destination)
    var upper = max(start, result.destination)
    if result.inclusive {
      upper = buffer.nextBoundary(from: upper)
    }
    return VimOperationTarget(ranges: [lower..<upper], kind: .characterwise)
  }

  func lineTarget(count: Int) -> VimOperationTarget {
    let lower = buffer.lineStart(at: state.cursor)
    var upper = lower
    for _ in 0..<max(1, count) {
      let next = buffer.lineFullEnd(at: upper)
      if next <= upper {
        upper = buffer.length
        break
      }
      upper = next
    }
    return VimOperationTarget(ranges: [lower..<max(lower, upper)], kind: .linewise)
  }

  func target(for object: VimTextObject, inner: Bool) -> VimOperationTarget {
    let range: Range<Int>
    switch object {
    case .word:
      range = buffer.wordObjectRange(at: state.cursor, bigWord: false, inner: inner)
    case .WORD:
      range = buffer.wordObjectRange(at: state.cursor, bigWord: true, inner: inner)
    case .paragraph:
      range = buffer.paragraphRange(at: state.cursor, inner: inner)
    case .sentence:
      range = buffer.sentenceRange(at: state.cursor, inner: inner)
    case .quotes(let quote):
      range = buffer.enclosingPair(open: quote, close: quote, at: state.cursor, inner: inner)
    case .parentheses:
      range = buffer.enclosingPair(open: "(", close: ")", at: state.cursor, inner: inner)
    case .brackets:
      range = buffer.enclosingPair(open: "[", close: "]", at: state.cursor, inner: inner)
    case .braces:
      range = buffer.enclosingPair(open: "{", close: "}", at: state.cursor, inner: inner)
    case .angles, .tag:
      range = buffer.enclosingPair(open: "<", close: ">", at: state.cursor, inner: inner)
    }
    return VimOperationTarget(ranges: [range], kind: .characterwise)
  }

  func visualTarget() -> VimOperationTarget? {
    guard state.mode.isVisual, let selection = state.selection else { return nil }
    let ranges = selection.ranges.map { $0.lowerBound..<$0.upperBound }
    let kind: VimRegisterKind
    switch state.mode {
    case .visualLine: kind = .linewise
    case .visualBlock: kind = .blockwise
    default: kind = .characterwise
    }
    return VimOperationTarget(ranges: ranges, kind: kind)
  }

  func rememberVisualSelection() {
    guard state.mode.isVisual, let selection = state.selection else { return }
    lastVisualSelection = (state.mode, selection)
  }

  func replaceVisualSelection(with character: Character) {
    guard let target = visualTarget() else { return }
    rememberVisualSelection()
    let first = target.ranges.map(\.lowerBound).min() ?? state.cursor
    for range in target.ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
      let source = buffer
      let normalized = source.normalized(range)
      guard !normalized.isEmpty else { continue }
      let replacement = source.substring(in: normalized).reduce(into: "") { result, value in
        if value == "\n" || value == "\r" {
          result.append(value)
        } else {
          result.append(character)
        }
      }
      state.text.replaceSubrange(
        source.stringIndex(normalized.lowerBound)..<source.stringIndex(normalized.upperBound),
        with: replacement
      )
      adjustTrackedPositions(
        replacing: normalized,
        replacementLength: replacement.utf16.count,
        excludingCursor: true
      )
    }
    state.cursor = min(first, state.text.utf16.count)
    state.mode = .normal
    state.selection = nil
  }

  func pasteOverVisualSelection(_ value: VimRegisterValue, count: Int) {
    guard let target = visualTarget() else { return }
    rememberVisualSelection()
    let insertion = target.ranges.map(\.lowerBound).min() ?? state.cursor
    deleteTarget(target, register: .unnamed, enterInsert: false)
    state.cursor = min(insertion, state.text.utf16.count)
    paste(value, after: false, count: count)
  }

  func joinVisualSelection(insertingSpace: Bool) {
    guard let selection = state.selection else { return }
    rememberVisualSelection()
    let lowerLine = buffer.lineNumber(at: selection.lowerBound)
    let upperLine = buffer.lineNumber(at: max(selection.lowerBound, selection.upperBound - 1))
    state.cursor = buffer.offsetOfLine(lowerLine)
    for _ in lowerLine..<upperLine { joinLine(insertingSpace: insertingSpace) }
    state.mode = .normal
    state.selection = nil
  }

  func insertText(_ string: String) {
    guard !string.isEmpty else { return }
    let source = buffer
    let start = source.normalize(state.cursor)
    let startIndex = source.stringIndex(start)
    var replacedRange = start..<start

    if state.mode == .replace, start < source.length {
      let characterCount = max(1, string.count)
      let end = source.advance(from: start, by: characterCount)
      replacedRange = start..<end
      let endIndex = source.stringIndex(end)
      state.text.replaceSubrange(startIndex..<endIndex, with: string)
    } else {
      state.text.insert(contentsOf: string, at: startIndex)
    }
    adjustTrackedPositions(
      replacing: replacedRange,
      replacementLength: string.utf16.count,
      excludingCursor: true
    )
    state.cursor = start + string.utf16.count
  }

  func replaceCharacters(with character: Character, count: Int) {
    let source = buffer
    let start = source.normalize(state.cursor)
    let lineEnd = source.lineContentEnd(at: start)
    let end = min(lineEnd, source.advance(from: start, by: count))
    guard source.characterDistance(from: start, to: end) >= count else { return }
    guard end > start else { return }
    let replacement = String(repeating: String(character), count: max(1, count))
    let lowerIndex = source.stringIndex(start)
    let upperIndex = source.stringIndex(end)
    state.text.replaceSubrange(lowerIndex..<upperIndex, with: replacement)
    adjustTrackedPositions(
      replacing: start..<end,
      replacementLength: replacement.utf16.count,
      excludingCursor: true
    )
    state.cursor = start
  }

  func deleteRaw(_ range: Range<Int>) {
    let source = buffer
    let normalized = source.normalized(range)
    guard !normalized.isEmpty else { return }
    state.text.removeSubrange(
      source.stringIndex(normalized.lowerBound)..<source.stringIndex(normalized.upperBound)
    )
    adjustTrackedPositions(
      replacing: normalized,
      replacementLength: 0,
      excludingCursor: true
    )
    state.cursor = min(normalized.lowerBound, state.text.utf16.count)
  }

  func deleteTarget(
    _ target: VimOperationTarget,
    register: VimRegister,
    enterInsert: Bool
  ) {
    let source = buffer
    let normalizedRanges = target.ranges.map(source.normalized).filter { !$0.isEmpty }
    guard !normalizedRanges.isEmpty else {
      if enterInsert { state.mode = .insert }
      return
    }

    let fragments = normalizedRanges.map { source.substring(in: $0) }
    var registerText = fragments.joined(separator: target.kind == .blockwise ? "\n" : "")
    if target.kind == .linewise, !registerText.hasSuffix("\n") {
      registerText.append("\n")
    }
    let value = VimRegisterValue(text: registerText, kind: target.kind)
    let isSmall =
      target.kind == .characterwise
      && normalizedRanges.count == 1
      && !registerText.contains("\n")
    registers.recordDelete(value, requested: register, isSmall: isSmall)

    let firstLower = normalizedRanges.map(\.lowerBound).min() ?? state.cursor
    for range in normalizedRanges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
      let current = VimTextBuffer(state.text)
      state.text.removeSubrange(
        current.stringIndex(range.lowerBound)..<current.stringIndex(range.upperBound)
      )
      adjustTrackedPositions(
        replacing: range,
        replacementLength: 0,
        excludingCursor: true
      )
    }
    state.cursor = min(firstLower, state.text.utf16.count)

    if enterInsert {
      if target.kind == .linewise {
        let indent = leadingIndent(in: fragments.first ?? "")
        let insertion = state.cursor
        if insertion < state.text.utf16.count {
          insertText(indent + "\n")
          state.cursor = insertion + indent.utf16.count
        } else if !indent.isEmpty {
          insertText(indent)
        }
      }
      state.mode = .insert
    } else {
      state.mode = .normal
    }
  }

  func yankTarget(_ target: VimOperationTarget, register: VimRegister) {
    let source = buffer
    let ranges = target.ranges.map(source.normalized).filter { !$0.isEmpty }
    guard !ranges.isEmpty else { return }
    var text = ranges.map { source.substring(in: $0) }
      .joined(separator: target.kind == .blockwise ? "\n" : "")
    if target.kind == .linewise, !text.hasSuffix("\n") { text.append("\n") }
    registers.recordYank(
      VimRegisterValue(text: text, kind: target.kind),
      requested: register
    )
    state.cursor = ranges.map(\.lowerBound).min() ?? state.cursor
    state.mode = .normal
    state.selection = nil
  }

  func apply(_ operation: VimOperator, to target: VimOperationTarget, register: VimRegister) {
    guard !target.isEmpty else { return }
    switch operation {
    case .delete:
      deleteTarget(target, register: register, enterInsert: false)
    case .change:
      deleteTarget(target, register: register, enterInsert: true)
    case .yank:
      yankTarget(target, register: register)
    case .indent:
      adjustIndent(in: target, delta: 1)
      state.mode = .normal
      state.selection = nil
    case .outdent:
      adjustIndent(in: target, delta: -1)
      state.mode = .normal
      state.selection = nil
    case .uppercase, .lowercase, .swapCase, .rot13:
      transformText(in: target, operation: operation)
      state.mode = .normal
      state.selection = nil
    case .format:
      break
    }
  }

  func transformText(in target: VimOperationTarget, operation: VimOperator) {
    for range in target.ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
      let source = buffer
      let normalized = source.normalized(range)
      guard !normalized.isEmpty else { continue }
      let old = source.substring(in: normalized)
      let new: String
      switch operation {
      case .uppercase:
        new = old.uppercased()
      case .lowercase:
        new = old.lowercased()
      case .swapCase:
        new = old.reduce(into: "") { result, character in
          if character.isUppercase {
            result += String(character).lowercased()
          } else if character.isLowercase {
            result += String(character).uppercased()
          } else {
            result.append(character)
          }
        }
      case .rot13:
        new = String(
          old.unicodeScalars.map { scalar -> Character in
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
      default:
        new = old
      }
      state.text.replaceSubrange(
        source.stringIndex(normalized.lowerBound)..<source.stringIndex(normalized.upperBound),
        with: new
      )
      adjustTrackedPositions(
        replacing: normalized,
        replacementLength: new.utf16.count,
        excludingCursor: true
      )
    }
  }

  func adjustNumber(by delta: Int) {
    guard delta != 0 else { return }
    let source = buffer
    let line = source.line(at: state.cursor)
    let lineText = source.substring(in: line.start..<line.contentEnd)
    let expression = try? NSRegularExpression(
      pattern: #"[+-]?(?:0[xX][0-9A-Fa-f]+|0[bB][01]+|0[oO][0-7]+|[0-9]+)"#
    )
    guard let expression else { return }
    let matches = expression.matches(
      in: lineText,
      range: NSRange(location: 0, length: lineText.utf16.count)
    )
    let localCursor = state.cursor - line.start
    guard
      let match = matches.first(where: {
        ($0.range.location <= localCursor && NSMaxRange($0.range) > localCursor)
          || $0.range.location >= localCursor
      })
    else { return }

    let raw = (lineText as NSString).substring(with: match.range)
    guard let replacement = adjustedNumber(raw, by: delta), replacement != raw else { return }
    let range = (line.start + match.range.location)..<(line.start + NSMaxRange(match.range))
    state.text.replaceSubrange(
      source.stringIndex(range.lowerBound)..<source.stringIndex(range.upperBound),
      with: replacement
    )
    adjustTrackedPositions(
      replacing: range,
      replacementLength: replacement.utf16.count,
      excludingCursor: true
    )
    let replacementEnd = range.lowerBound + replacement.utf16.count
    state.cursor =
      replacementEnd > range.lowerBound
      ? buffer.previousBoundary(from: replacementEnd)
      : range.lowerBound
  }

  private func adjustedNumber(_ raw: String, by delta: Int) -> String? {
    var body = raw
    var sign: Int64 = 1
    if body.hasPrefix("-") {
      sign = -1
      body.removeFirst()
    } else if body.hasPrefix("+") {
      body.removeFirst()
    }

    let radix: Int
    let prefix: String
    if body.hasPrefix("0x") || body.hasPrefix("0X") {
      radix = 16
      prefix = String(body.prefix(2))
      body.removeFirst(2)
    } else if body.hasPrefix("0b") || body.hasPrefix("0B") {
      radix = 2
      prefix = String(body.prefix(2))
      body.removeFirst(2)
    } else if body.hasPrefix("0o") || body.hasPrefix("0O") {
      radix = 8
      prefix = String(body.prefix(2))
      body.removeFirst(2)
    } else {
      radix = 10
      prefix = ""
    }
    guard let magnitude = Int64(body, radix: radix) else { return nil }
    let signed = magnitude.multipliedReportingOverflow(by: sign)
    guard !signed.overflow else { return nil }
    let adjusted = signed.partialValue.addingReportingOverflow(Int64(delta))
    guard !adjusted.overflow else { return nil }

    let negative = adjusted.partialValue < 0
    let absolute = adjusted.partialValue.magnitude
    var digits = String(absolute, radix: radix)
    if radix == 16, body.contains(where: \.isUppercase) { digits = digits.uppercased() }
    if body.count > 1, body.first == "0", digits.count < body.count {
      digits = String(repeating: "0", count: body.count - digits.count) + digits
    }
    return (negative ? "-" : "") + prefix + digits
  }

  func adjustIndent(in target: VimOperationTarget, delta: Int) {
    let source = buffer
    var starts = Set<Int>()
    for range in target.ranges {
      var lineStart = source.lineStart(at: range.lowerBound)
      let upper = max(lineStart, range.upperBound)
      while lineStart <= upper, lineStart <= source.length {
        starts.insert(lineStart)
        let next = source.lineFullEnd(at: lineStart)
        if next <= lineStart || next >= upper { break }
        lineStart = next
      }
    }

    for start in starts.sorted(by: >) {
      if delta > 0 {
        let indentation = String(repeating: " ", count: tabWidth)
        let current = buffer
        state.text.insert(contentsOf: indentation, at: current.stringIndex(start))
        adjustTrackedPositions(
          replacing: start..<start,
          replacementLength: indentation.utf16.count,
          excludingCursor: false
        )
      } else {
        let current = buffer
        let line = current.line(at: start)
        guard start < line.contentEnd else { continue }
        var removalEnd = start
        if current.character(at: start) == "\t" {
          removalEnd = current.nextBoundary(from: start)
        } else {
          var removed = 0
          while removalEnd < line.contentEnd, removed < tabWidth,
            current.character(at: removalEnd) == " "
          {
            removalEnd = current.nextBoundary(from: removalEnd)
            removed += 1
          }
        }
        guard removalEnd > start else { continue }
        state.text.removeSubrange(
          current.stringIndex(start)..<current.stringIndex(removalEnd)
        )
        adjustTrackedPositions(
          replacing: start..<removalEnd,
          replacementLength: 0,
          excludingCursor: false
        )
      }
    }
    state.cursor = buffer.firstNonBlank(at: state.cursor)
  }

  func paste(_ value: VimRegisterValue, after: Bool, count: Int) {
    guard !value.text.isEmpty else { return }
    switch value.kind {
    case .characterwise:
      let insertion = after ? insertionOffsetAfterCursor() : state.cursor
      let repeated = String(repeating: value.text, count: count)
      state.cursor = insertion
      insertText(repeated)
      state.cursor = after ? buffer.previousBoundary(from: state.cursor) : insertion
      state.mode = .normal

    case .linewise:
      var line = value.text
      if !line.hasSuffix("\n") { line.append("\n") }
      let currentLine = buffer.line(at: state.cursor)
      var insertion = after ? currentLine.fullEnd : currentLine.start
      var repeated = String(repeating: line, count: count)
      var insertedSeparator = false
      if after, currentLine.fullEnd == currentLine.contentEnd, currentLine.fullEnd == buffer.length
      {
        repeated = "\n" + repeated
        insertion = currentLine.contentEnd
        insertedSeparator = true
      }
      state.cursor = insertion
      insertText(repeated)
      let insertedLineStart = insertedSeparator ? insertion + 1 : insertion
      state.cursor = buffer.firstNonBlank(at: insertedLineStart)
      state.mode = .normal

    case .blockwise:
      pasteBlock(value.text, after: after, count: count)
      state.mode = .normal
    }
  }

  func pasteBlock(_ text: String, after: Bool, count: Int) {
    let pieces = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !pieces.isEmpty else { return }
    let source = buffer
    let startLine = source.lineNumber(at: state.cursor)
    let column = source.visualColumn(at: state.cursor, tabWidth: tabWidth) + (after ? 1 : 0)

    for (index, piece) in pieces.enumerated().reversed() {
      let lineNumber = startLine + index
      ensureLineExists(lineNumber)
      let current = buffer
      let lineStart = current.offsetOfLine(lineNumber)
      let line = current.line(at: lineStart)
      let lineWidth = current.visualColumn(at: line.contentEnd, tabWidth: tabWidth)
      if column > lineWidth {
        state.cursor = line.contentEnd
        insertText(String(repeating: " ", count: column - lineWidth))
      }
      let padded = buffer
      let insertion = padded.insertionOffset(
        inLineStartingAt: lineStart,
        visualColumn: column,
        tabWidth: tabWidth
      )
      state.cursor = insertion
      insertText(String(repeating: piece, count: count))
    }
    state.cursor = buffer.offsetOfLine(startLine)
    state.cursor = buffer.offset(
      inLineStartingAt: state.cursor,
      visualColumn: column,
      tabWidth: tabWidth
    )
  }

  func ensureLineExists(_ number: Int) {
    while buffer.lineNumber(at: buffer.length) < number {
      state.cursor = buffer.length
      insertText("\n")
    }
  }

  func joinLine(insertingSpace: Bool) {
    let source = buffer
    let currentLine = source.line(at: state.cursor)
    guard currentLine.fullEnd > currentLine.contentEnd,
      currentLine.fullEnd <= source.length,
      currentLine.fullEnd < source.length || currentLine.contentEnd < source.length
    else { return }

    var nextContent = currentLine.fullEnd
    let nextLine = source.line(at: nextContent)
    while nextContent < nextLine.contentEnd, source.isHorizontalWhitespace(at: nextContent) {
      nextContent = source.nextBoundary(from: nextContent)
    }
    let replacement: String
    if !insertingSpace {
      replacement = ""
    } else if currentLine.contentEnd == currentLine.start {
      replacement = ""
    } else {
      replacement = " "
    }
    let range = currentLine.contentEnd..<nextContent
    state.text.replaceSubrange(
      source.stringIndex(range.lowerBound)..<source.stringIndex(range.upperBound),
      with: replacement
    )
    adjustTrackedPositions(
      replacing: range,
      replacementLength: replacement.utf16.count,
      excludingCursor: true
    )
    state.cursor = currentLine.contentEnd
  }

  func leadingIndent(in text: String) -> String {
    String(text.prefix { $0 == " " || $0 == "\t" })
  }

  func adjustTrackedPositions(
    replacing range: Range<Int>,
    replacementLength: Int,
    excludingCursor: Bool
  ) {
    let removedLength = range.count
    let delta = replacementLength - removedLength
    func adjusted(_ value: Int) -> Int {
      if value < range.lowerBound { return value }
      if value >= range.upperBound { return max(range.lowerBound, value + delta) }
      return range.lowerBound + replacementLength
    }

    for (name, value) in marks { marks[name] = adjusted(value) }
    if !excludingCursor { state.cursor = adjusted(state.cursor) }
    if var selection = state.selection {
      selection.anchor = adjusted(selection.anchor)
      selection.head = adjusted(selection.head)
      state.selection = selection
    }
  }

  func search(_ query: String, forward: Bool, count: Int) {
    guard !query.isEmpty else { return }
    for _ in 0..<max(1, count) {
      guard let match = nextSearchMatch(query, forward: forward) else { return }
      state.cursor = match.location
    }
    normalizeCursorForCurrentMode()
    refreshSelectionRanges()
  }

  func nextSearchMatch(_ query: String, forward: Bool) -> NSRange? {
    let source = state.text as NSString
    guard source.length > 0 else { return nil }
    let expression: NSRegularExpression
    do {
      expression = try NSRegularExpression(pattern: query)
    } catch {
      guard
        let literal = try? NSRegularExpression(
          pattern: NSRegularExpression.escapedPattern(for: query)
        )
      else { return nil }
      expression = literal
    }

    if forward {
      let start = min(source.length, buffer.nextBoundary(from: state.cursor))
      if let match = expression.firstMatch(
        in: state.text,
        range: NSRange(location: start, length: source.length - start)
      ) {
        return match.range
      }
      return expression.firstMatch(
        in: state.text,
        range: NSRange(location: 0, length: start)
      )?.range
    }

    let before = NSRange(location: 0, length: max(0, state.cursor))
    let matches = expression.matches(in: state.text, range: before)
    if let last = matches.last { return last.range }
    let after = NSRange(
      location: min(source.length, state.cursor),
      length: max(0, source.length - state.cursor)
    )
    return expression.matches(in: state.text, range: after).last?.range
  }
}
