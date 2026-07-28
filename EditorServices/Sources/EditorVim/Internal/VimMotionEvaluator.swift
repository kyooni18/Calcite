import Foundation

extension VimEngine {
  func move(_ motion: VimMotion, count: Int) {
    move(.standard(motion), count: count)
  }

  func evaluateMotion(
    _ motion: VimMotion,
    count: Int,
    from origin: Int
  ) -> VimMotionResult {
    evaluateMotion(.standard(motion), count: count, from: origin)
  }

  private func evaluateStandardMotion(
    _ motion: VimMotion,
    count: Int,
    from origin: Int
  ) -> VimMotionResult {
    let effectiveCount = max(1, count)
    var destination = clamp(origin)
    var desiredColumn: Int?
    var succeeded = true
    let kind: VimMotionKind
    let inclusive: Bool

    switch motion {
    case .left:
      kind = .characterwise
      inclusive = false
      let start = lineStart(at: destination)
      for _ in 0..<effectiveCount {
        let previous = previousCharacterBoundary(from: destination)
        guard previous >= start, previous < destination else { break }
        destination = previous
      }

    case .right:
      kind = .characterwise
      inclusive = false
      destination = characterOffset(
        from: destination,
        count: effectiveCount,
        limit: normalLineEnd(at: destination)
      )

    case .lineStart:
      kind = .characterwise
      inclusive = false
      destination = lineStart(at: destination)

    case .firstNonBlank:
      kind = .characterwise
      inclusive = false
      destination = firstNonBlank(at: destination)

    case .lineEnd:
      kind = .characterwise
      inclusive = true
      if effectiveCount > 1 {
        lineIndex.synchronize(with: state.text)
        let currentLine = lineIndex.oneBasedLine(
          containing: destination,
          textLength: state.text.utf16.count
        )
        let targetLine = min(lineIndex.lineCount, currentLine + effectiveCount - 1)
        destination = lineIndex.offset(ofOneBasedLine: targetLine)
      }
      destination = normalLineEnd(at: destination)
      desiredColumn = Int.max

    case .documentStart:
      kind = .linewise
      inclusive = false
      destination = firstNonBlank(at: 0)

    case .documentEnd:
      kind = .linewise
      inclusive = false
      if state.text.isEmpty {
        destination = 0
      } else {
        let probe = previousCharacterBoundary(from: state.text.utf16.count)
        destination = firstNonBlank(at: lineStart(at: probe))
      }

    case .up, .down, .pageUp, .pageDown, .halfPageUp, .halfPageDown:
      kind = .linewise
      inclusive = false
      let direction: Int
      let lineMultiplier: Int
      switch motion {
      case .up:
        direction = -1
        lineMultiplier = 1
      case .down:
        direction = 1
        lineMultiplier = 1
      case .pageUp:
        direction = -1
        lineMultiplier = viewportPageLineCount
      case .pageDown:
        direction = 1
        lineMultiplier = viewportPageLineCount
      case .halfPageUp:
        direction = -1
        lineMultiplier = viewportHalfPageLineCount
      default:
        direction = 1
        lineMultiplier = viewportHalfPageLineCount
      }

      lineIndex.synchronize(with: state.text)
      let currentLine = lineIndex.oneBasedLine(
        containing: destination,
        textLength: state.text.utf16.count
      )
      let boundedCount = min(effectiveCount, lineIndex.lineCount)
      let multiplied = boundedCount.multipliedReportingOverflow(by: max(1, lineMultiplier))
      let distance = min(
        lineIndex.lineCount,
        multiplied.overflow ? lineIndex.lineCount : multiplied.partialValue
      )
      let targetLine =
        direction < 0
        ? max(1, currentLine - distance)
        : min(lineIndex.lineCount, currentLine + distance)
      let targetStart = lineIndex.offset(ofOneBasedLine: targetLine)
      let desired =
        preferredColumn
        ?? logicalDisplayColumn(from: lineStart(at: destination), to: destination)
      destination =
        desired == Int.max
        ? normalLineEnd(at: targetStart)
        : logicalOffset(
          from: targetStart,
          atDisplayColumn: desired,
          contentEnd: lineContentEnd(at: targetStart)
        )
      desiredColumn = desired

    case .wordForward:
      kind = .characterwise
      inclusive = false
      for _ in 0..<effectiveCount {
        let next = nextWord(from: destination, whole: false)
        guard next != destination else { break }
        destination = next
      }

    case .wordBackward:
      kind = .characterwise
      inclusive = false
      for _ in 0..<effectiveCount {
        let next = previousWord(from: destination, whole: false)
        guard next != destination else { break }
        destination = next
      }

    case .wordEnd:
      kind = .characterwise
      inclusive = true
      for _ in 0..<effectiveCount {
        let next = wordEnd(from: destination, whole: false)
        guard next != destination else { break }
        destination = next
      }

    case .findForward(let character):
      kind = .characterwise
      inclusive = true
      if let found = findDestination(
        character,
        from: destination,
        forward: true,
        till: false,
        count: effectiveCount
      ) {
        destination = found
      } else {
        succeeded = false
      }

    case .findBackward(let character):
      kind = .characterwise
      inclusive = true
      if let found = findDestination(
        character,
        from: destination,
        forward: false,
        till: false,
        count: effectiveCount
      ) {
        destination = found
      } else {
        succeeded = false
      }

    case .tillForward(let character):
      kind = .characterwise
      inclusive = true
      if let found = findDestination(
        character,
        from: destination,
        forward: true,
        till: true,
        count: effectiveCount
      ) {
        destination = found
      } else {
        succeeded = false
      }

    case .tillBackward(let character):
      kind = .characterwise
      inclusive = true
      if let found = findDestination(
        character,
        from: destination,
        forward: false,
        till: true,
        count: effectiveCount
      ) {
        destination = found
      } else {
        succeeded = false
      }

    case .matchingPair:
      kind = .characterwise
      inclusive = true
      if let matched = matchingPairDestination(from: destination) {
        destination = matched
      } else {
        succeeded = false
      }

    case .line(let number):
      kind = .linewise
      inclusive = false
      destination = firstNonBlank(at: lineOffset(max(1, number)))
    }

    return VimMotionResult(
      destination: clamp(destination),
      kind: kind,
      inclusive: inclusive,
      crossedLine: lineStart(at: origin) != lineStart(at: destination),
      desiredColumn: desiredColumn,
      succeeded: succeeded
    )
  }

  func findDestination(
    _ character: Character,
    from origin: Int,
    forward: Bool,
    till: Bool,
    count: Int
  ) -> Int? {
    let start = lineStart(at: origin)
    let end = lineContentEnd(at: origin)
    var current = origin
    for _ in 0..<max(1, count) {
      if forward {
        var candidate = nextCharacterBoundary(from: current)
        var found: Int?
        while candidate < end {
          if self.character(at: candidate) == character {
            found = candidate
            break
          }
          let next = nextCharacterBoundary(from: candidate)
          guard next > candidate else { break }
          candidate = next
        }
        guard let found else { return nil }
        current = found
      } else {
        var candidate = current
        var found: Int?
        while candidate > start {
          candidate = previousCharacterBoundary(from: candidate)
          if self.character(at: candidate) == character {
            found = candidate
            break
          }
        }
        guard let found else { return nil }
        current = found
      }
    }
    if till {
      current =
        forward
        ? previousCharacterBoundary(from: current)
        : nextCharacterBoundary(from: current)
    }
    return clamp(current)
  }

  func matchingPairDestination(from origin: Int) -> Int? {
    let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    let reversePairs = Dictionary(uniqueKeysWithValues: pairs.map { ($0.value, $0.key) })
    let end = lineContentEnd(at: origin)
    var delimiterOffset = clamp(origin)
    while delimiterOffset < end {
      guard let value = character(at: delimiterOffset) else { return nil }
      if pairs[value] != nil || reversePairs[value] != nil { break }
      let next = nextCharacterBoundary(from: delimiterOffset)
      guard next > delimiterOffset else { return nil }
      delimiterOffset = next
    }
    guard delimiterOffset < end, let current = character(at: delimiterOffset) else { return nil }

    if let close = pairs[current] {
      var depth = 0
      var index = delimiterOffset
      while index < state.text.utf16.count {
        let value = character(at: index)
        if value == current { depth += 1 }
        if value == close {
          depth -= 1
          if depth == 0 { return index }
        }
        let next = nextCharacterBoundary(from: index)
        guard next > index else { break }
        index = next
      }
    } else if let open = reversePairs[current] {
      var depth = 0
      var index = delimiterOffset
      while true {
        let value = character(at: index)
        if value == current { depth += 1 }
        if value == open {
          depth -= 1
          if depth == 0 { return index }
        }
        guard index > 0 else { break }
        index = previousCharacterBoundary(from: index)
      }
    }
    return nil
  }

  func previousWordEndDestination(from origin: Int, whole: Bool) -> Int? {
    guard origin > 0 else { return nil }
    var current = clamp(origin)
    if let currentClass = wordClass(at: current, whole: whole), currentClass != .whitespace {
      while current > 0 {
        let previous = previousCharacterBoundary(from: current)
        guard wordClass(at: previous, whole: whole) == currentClass else { break }
        current = previous
      }
    }
    guard current > 0 else { return nil }
    current = previousCharacterBoundary(from: current)
    while current > 0, wordClass(at: current, whole: whole) == .whitespace {
      current = previousCharacterBoundary(from: current)
    }
    return current
  }

  func moveToPreviousWordEnd(count: Int, whole: Bool) {
    move(whole ? .previousWholeWordEnd : .previousWordEnd, count: count)
  }

  func moveToLastNonBlank(count: Int) {
    if count > 1 {
      for _ in 1..<count {
        let next = nextLineStart(lineStart(at: state.cursor))
        guard next > lineStart(at: state.cursor) else { break }
        state.cursor = next
      }
    }
    var destination = lineContentEnd(at: state.cursor)
    while destination > lineStart(at: state.cursor) {
      let previous = previousCharacterBoundary(from: destination)
      guard isHorizontalWhitespace(at: previous) else { break }
      destination = previous
    }
    if destination == lineContentEnd(at: state.cursor), destination > lineStart(at: state.cursor) {
      destination = previousCharacterBoundary(from: destination)
    }
    state.cursor = destination
    preferredColumn = nil
    preferredVisualColumn = nil
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func moveToAdjacentLine(count: Int, forward: Bool) {
    for _ in 0..<max(1, count) {
      let start = lineStart(at: state.cursor)
      let destination = forward ? nextLineStart(start) : previousLineStart(start)
      guard destination != start else { break }
      state.cursor = destination
    }
    state.cursor = firstNonBlank(at: state.cursor)
    preferredColumn = nil
    preferredVisualColumn = nil
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func moveToCurrentOrFollowingLine(count: Int) {
    if count > 1 { moveToAdjacentLine(count: count - 1, forward: true) }
    state.cursor = firstNonBlank(at: state.cursor)
    preferredColumn = nil
    preferredVisualColumn = nil
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func moveToColumn(_ oneBasedColumn: Int) {
    let start = lineStart(at: state.cursor)
    let end = lineContentEnd(at: state.cursor)
    state.cursor = characterOffset(
      from: start,
      count: max(0, oneBasedColumn - 1),
      limit: end
    )
    preferredColumn = nil
    preferredVisualColumn = nil
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func moveWholeWordForward(count: Int) {
    preferredColumn = nil
    preferredVisualColumn = nil
    for _ in 0..<count { state.cursor = nextWord(from: state.cursor, whole: true) }
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func moveWholeWordBackward(count: Int) {
    preferredColumn = nil
    preferredVisualColumn = nil
    for _ in 0..<count { state.cursor = previousWord(from: state.cursor, whole: true) }
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func moveWholeWordEnd(count: Int) {
    preferredColumn = nil
    preferredVisualColumn = nil
    for _ in 0..<count { state.cursor = wordEnd(from: state.cursor, whole: true) }
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func operatorRange(for motion: VimMotion, count: Int) -> VimOperatorRange {
    operatorRange(for: .standard(motion), count: count, forcedKind: nil)
  }

  func move(_ motion: VimMotionExpression, count: Int) {
    let result = evaluateMotion(motion, count: count, from: state.cursor)
    guard result.succeeded else { return }
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
  }

  func evaluateMotion(
    _ motion: VimMotionExpression,
    count: Int,
    from origin: Int
  ) -> VimMotionResult {
    if let standard = motion.standardMotion {
      return evaluateStandardMotion(standard, count: count, from: origin)
    }

    let effectiveCount = max(1, count)
    var destination = clamp(origin)
    var succeeded = true
    var kind: VimMotionKind = .characterwise
    var inclusive = false
    var desiredColumn: Int?
    var isJump = false
    var explicitRange: Range<Int>?

    switch motion {
    case .standard:
      preconditionFailure("Standard motions are evaluated by the public motion path")

    case .wholeWordForward:
      for _ in 0..<effectiveCount {
        let next = nextWord(from: destination, whole: true)
        guard next != destination else { break }
        destination = next
      }

    case .wholeWordBackward:
      for _ in 0..<effectiveCount {
        let next = previousWord(from: destination, whole: true)
        guard next != destination else { break }
        destination = next
      }

    case .wholeWordEnd:
      inclusive = true
      for _ in 0..<effectiveCount {
        let next = wordEnd(from: destination, whole: true)
        guard next != destination else { break }
        destination = next
      }

    case .previousWordEnd, .previousWholeWordEnd:
      inclusive = true
      let whole = motion == .previousWholeWordEnd
      for _ in 0..<effectiveCount {
        guard let previous = previousWordEndDestination(from: destination, whole: whole) else {
          succeeded = false
          break
        }
        destination = previous
      }

    case .displayLineUp, .displayLineDown:
      let direction = motion == .displayLineUp ? -1 : 1
      var desired = preferredVisualColumn
      for _ in 0..<effectiveCount {
        if let visual = storedVisualGeometryProvider?.moveVertically(
          fromUTF16Offset: destination,
          direction: direction,
          preferredColumn: desired,
          text: state.text
        ) {
          let next = normalizedVimUTF16Offset(visual.utf16Offset, in: state.text)
          guard next != destination else { break }
          destination = next
          desired = max(0, visual.preferredColumn)
        } else {
          let fallback = evaluateStandardMotion(
            direction < 0 ? VimMotion.up : VimMotion.down,
            count: 1,
            from: destination
          )
          guard fallback.destination != destination else { break }
          destination = fallback.destination
          desired = fallback.desiredColumn
        }
      }
      desiredColumn = desired

    case .adjacentLineUp, .adjacentLineDown:
      kind = .linewise
      lineIndex.synchronize(with: state.text)
      let currentLine = lineIndex.oneBasedLine(
        containing: destination,
        textLength: state.text.utf16.count
      )
      let delta = motion == .adjacentLineUp ? -effectiveCount : effectiveCount
      let targetLine = min(lineIndex.lineCount, max(1, currentLine + delta))
      destination = firstNonBlank(at: lineIndex.offset(ofOneBasedLine: targetLine))

    case .currentOrFollowingLine:
      kind = .linewise
      lineIndex.synchronize(with: state.text)
      let currentLine = lineIndex.oneBasedLine(
        containing: destination,
        textLength: state.text.utf16.count
      )
      let targetLine = min(lineIndex.lineCount, currentLine + effectiveCount - 1)
      destination = firstNonBlank(at: lineIndex.offset(ofOneBasedLine: targetLine))

    case .column:
      let start = lineStart(at: destination)
      destination = characterOffset(
        from: start,
        count: max(0, effectiveCount - 1),
        limit: lineContentEnd(at: start)
      )

    case .sentenceBackward:
      for _ in 0..<effectiveCount {
        guard let previous = previousSentenceStart(from: destination) else {
          succeeded = false
          break
        }
        destination = previous
      }

    case .sentenceForward:
      for _ in 0..<effectiveCount {
        guard let next = nextSentenceStart(from: destination) else {
          succeeded = false
          break
        }
        destination = next
      }

    case .paragraphBackward:
      for _ in 0..<effectiveCount {
        guard let previous = previousParagraphBoundary(from: destination) else {
          succeeded = false
          break
        }
        destination = previous
      }

    case .paragraphForward:
      for _ in 0..<effectiveCount {
        guard let next = nextParagraphBoundary(from: destination) else {
          succeeded = false
          break
        }
        destination = next
      }

    case .mark(let name, let linewise):
      guard let mark = marks[name] else {
        succeeded = false
        break
      }
      destination = linewise ? firstNonBlank(at: lineStart(at: mark)) : clamp(mark)
      kind = linewise ? .linewise : .characterwise
      isJump = true

    case .repeatFind(let reverse):
      guard let lastFind else {
        succeeded = false
        break
      }
      let forward = reverse ? !lastFind.forward : lastFind.forward
      guard
        let found = findDestination(
          lastFind.character,
          from: destination,
          forward: forward,
          till: lastFind.till,
          count: effectiveCount
        )
      else {
        succeeded = false
        break
      }
      destination = found
      inclusive = !lastFind.till || !forward

    case .search(let pattern, let forward):
      guard !pattern.isEmpty,
        let found = searchDestination(
          pattern, forward: forward, from: destination, count: effectiveCount)
      else {
        succeeded = false
        break
      }
      destination = found
      isJump = true

    case .repeatSearch(let reverse):
      guard let (pattern, originalDirection) = lastSearch else {
        succeeded = false
        break
      }
      let forward = reverse ? !originalDirection : originalDirection
      guard
        let found = searchDestination(
          pattern,
          forward: forward,
          from: destination,
          count: effectiveCount
        )
      else {
        succeeded = false
        break
      }
      destination = found
      isJump = true

    case .lastNonBlank:
      lineIndex.synchronize(with: state.text)
      let currentLine = lineIndex.oneBasedLine(
        containing: destination,
        textLength: state.text.utf16.count
      )
      let targetLine = min(lineIndex.lineCount, currentLine + effectiveCount - 1)
      let targetStart = lineIndex.offset(ofOneBasedLine: targetLine)
      var candidate = lineContentEnd(at: targetStart)
      while candidate > targetStart {
        let previous = previousCharacterBoundary(from: candidate)
        guard isHorizontalWhitespace(at: previous) else { break }
        candidate = previous
      }
      if candidate > targetStart {
        candidate = previousCharacterBoundary(from: candidate)
      }
      destination = candidate
      inclusive = true

    case .viewport(let position):
      kind = .linewise
      lineIndex.synchronize(with: state.text)
      let top = min(max(1, viewportTopLine), lineIndex.lineCount)
      let bottom = min(max(top, viewportBottomLine), lineIndex.lineCount)
      let targetLine: Int
      switch position {
      case .top:
        targetLine = min(bottom, top + effectiveCount - 1)
      case .middle:
        targetLine = top + (bottom - top) / 2
      case .bottom:
        targetLine = max(top, bottom - effectiveCount + 1)
      }
      destination = firstNonBlank(at: lineIndex.offset(ofOneBasedLine: targetLine))
      isJump = true

    case .wordSearch(let forward, let wholeWord):
      guard let range = wordObjectRangeAt(origin: destination) else {
        succeeded = false
        break
      }
      let word = substring(range)
      guard !word.isEmpty else {
        succeeded = false
        break
      }
      let escaped = NSRegularExpression.escapedPattern(for: word)
      let pattern = wholeWord ? "\\b" + escaped + "\\b" : escaped
      guard
        let found = searchDestination(
          pattern,
          forward: forward,
          from: destination,
          count: effectiveCount
        )
      else {
        succeeded = false
        break
      }
      destination = found
      isJump = true

    case .nextSearchMatch(let reverse):
      guard let (pattern, originalDirection) = lastSearch else {
        succeeded = false
        break
      }
      let forward = reverse ? !originalDirection : originalDirection
      guard
        let range = searchMatchRange(
          pattern,
          forward: forward,
          from: destination,
          count: effectiveCount
        )
      else {
        succeeded = false
        break
      }
      destination =
        range.isEmpty ? range.lowerBound : previousCharacterBoundary(from: range.upperBound)
      inclusive = true
      explicitRange = range
      isJump = true

    case .textObject(let object, let inner):
      let range = textObjectRange(object, inner: inner, count: effectiveCount)
      guard !range.isEmpty else {
        succeeded = false
        break
      }
      destination = previousCharacterBoundary(from: range.upperBound)
      inclusive = true
      explicitRange = range

    case .percentage(let percentage):
      kind = .linewise
      lineIndex.synchronize(with: state.text)
      let bounded = min(100, max(1, percentage))
      let hasTrailingTerminator = state.text.hasSuffix("\n") || state.text.hasSuffix("\r")
      let contentLineCount = max(1, lineIndex.lineCount - (hasTrailingTerminator ? 1 : 0))
      let target = max(1, (contentLineCount * bounded + 99) / 100)
      destination = firstNonBlank(at: lineIndex.offset(ofOneBasedLine: target))
      isJump = true
    }

    return VimMotionResult(
      destination: clamp(destination),
      kind: kind,
      inclusive: inclusive,
      crossedLine: lineStart(at: origin) != lineStart(at: destination),
      desiredColumn: desiredColumn,
      succeeded: succeeded,
      isJump: isJump,
      explicitRange: explicitRange
    )
  }

  func operatorRange(
    for motion: VimMotionExpression,
    count: Int,
    forcedKind: VimMotionKind? = nil
  ) -> VimOperatorRange {
    let start = state.cursor
    let result = evaluateMotion(motion, count: count, from: start)
    return operatorRange(
      for: motion,
      result: result,
      origin: start,
      forcedKind: forcedKind
    )
  }

  func operatorRange(
    for motion: VimMotionExpression,
    result: VimMotionResult,
    origin start: Int,
    forcedKind: VimMotionKind? = nil
  ) -> VimOperatorRange {
    guard result.succeeded else {
      return VimOperatorRange(range: start..<start, linewise: false, succeeded: false)
    }

    let resolvedKind = forcedKind ?? result.kind
    if resolvedKind == .blockwise {
      let projected = blockwiseOperatorRanges(from: start, to: result.destination)
      guard !projected.ranges.isEmpty else {
        return VimOperatorRange(range: start..<start, linewise: false, succeeded: false)
      }
      let lower = projected.ranges.map(\.lowerBound).min() ?? start
      let upper = projected.ranges.map(\.upperBound).max() ?? start
      return VimOperatorRange(
        range: lower..<max(lower, upper),
        linewise: false,
        blockRanges: projected.ranges,
        blockWidth: projected.width
      )
    }

    if forcedKind == nil, let explicitRange = result.explicitRange {
      return VimOperatorRange(
        range: explicitRange,
        linewise: false,
        succeeded: !explicitRange.isEmpty
      )
    }

    if resolvedKind == .linewise {
      let lower = lineStart(at: min(start, result.destination))
      if forcedKind == .linewise,
        !result.inclusive,
        result.destination > start,
        result.destination <= firstNonBlank(at: result.destination)
      {
        let upper = lineStart(at: result.destination)
        return VimOperatorRange(range: lower..<max(lower, upper), linewise: true)
      }
      let upper = lineEndIncludingNewline(at: max(start, result.destination))
      return VimOperatorRange(range: lower..<max(lower, upper), linewise: true)
    }

    let destination = result.destination

    // Vim turns an exclusive forward motion ending in column zero into a
    // linewise operation when it starts at or before the first non-blank.
    if forcedKind == nil,
      !result.inclusive,
      destination > start,
      destination == lineStart(at: destination),
      start <= firstNonBlank(at: start)
    {
      let lower = lineStart(at: start)
      return VimOperatorRange(range: lower..<destination, linewise: true)
    }

    if motion.isWordForwardMotion, result.crossedLine {
      let upper = lineContentEnd(at: start)
      return VimOperatorRange(range: min(start, upper)..<max(start, upper), linewise: false)
    }

    if case .standard(.right) = motion, destination == start {
      let upper = min(lineContentEnd(at: start), nextCharacterBoundary(from: start))
      return VimOperatorRange(range: start..<max(start, upper), linewise: false)
    }

    switch motion {
    case .standard(.findBackward):
      return VimOperatorRange(
        range: min(start, destination)..<max(start, destination),
        linewise: false
      )
    case .standard(.tillBackward):
      return VimOperatorRange(
        range: min(start, destination)..<max(start, destination),
        linewise: false
      )
    case .repeatFind(let reverse):
      if let lastFind {
        let forward = reverse ? !lastFind.forward : lastFind.forward
        if !forward, !lastFind.till {
          return VimOperatorRange(
            range: min(start, destination)..<max(start, destination),
            linewise: false
          )
        }
        if !forward, lastFind.till {
          return VimOperatorRange(
            range: min(start, destination)..<max(start, destination),
            linewise: false
          )
        }
      }
    default:
      break
    }

    let lower = min(start, destination)
    var upper = max(start, destination)
    if result.inclusive {
      upper = nextCharacterBoundary(from: upper)
    }
    return VimOperatorRange(range: lower..<max(lower, upper), linewise: false)
  }

  func blockwiseOperatorRanges(
    from origin: Int,
    to destination: Int
  ) -> (ranges: [Range<Int>], width: Int) {
    lineIndex.synchronize(with: state.text)
    let originLine = lineIndex.oneBasedLine(
      containing: origin,
      textLength: state.text.utf16.count
    )
    let destinationLine = lineIndex.oneBasedLine(
      containing: destination,
      textLength: state.text.utf16.count
    )
    let lowerLine = min(originLine, destinationLine)
    let upperLine = max(originLine, destinationLine)
    let originColumn = logicalDisplayColumn(from: lineStart(at: origin), to: origin)
    let destinationColumn = logicalDisplayColumn(
      from: lineStart(at: destination),
      to: destination
    )
    let lowerColumn = min(originColumn, destinationColumn)
    let upperColumn = max(originColumn, destinationColumn)
    let width = max(1, upperColumn - lowerColumn + 1)

    var ranges: [Range<Int>] = []
    for line in lowerLine...upperLine {
      let start = lineIndex.offset(ofOneBasedLine: line)
      let contentEnd = lineContentEnd(at: start)
      let lower = logicalOffset(
        from: start,
        atDisplayColumn: lowerColumn,
        contentEnd: contentEnd
      )
      let upper = logicalOffset(
        from: start,
        atDisplayColumn: upperColumn + 1,
        contentEnd: contentEnd
      )
      ranges.append(lower..<max(lower, upper))
    }
    return (ranges, width)
  }

  func nextSentenceStart(from origin: Int) -> Int? {
    let length = state.text.utf16.count
    guard origin < length else { return nil }
    let range = sentenceRange(at: origin, around: false)
    var candidate = max(nextCharacterBoundary(from: origin), range.upperBound)
    while candidate < length, isWhitespaceOrNewline(at: candidate) {
      let next = nextCharacterBoundary(from: candidate)
      guard next > candidate else { break }
      candidate = next
    }
    return candidate < length ? candidate : nil
  }

  func previousSentenceStart(from origin: Int) -> Int? {
    guard origin > 0 else { return nil }
    let current = sentenceRange(at: origin, around: false)
    if current.lowerBound < origin { return current.lowerBound }
    var probe = previousCharacterBoundary(from: origin)
    while probe > 0, isWhitespaceOrNewline(at: probe) {
      probe = previousCharacterBoundary(from: probe)
    }
    return sentenceRange(at: probe, around: false).lowerBound
  }

  func nextParagraphBoundary(from origin: Int) -> Int? {
    let range = paragraphRange(at: origin, around: false)
    guard range.upperBound > origin, range.upperBound < state.text.utf16.count else { return nil }
    return range.upperBound
  }

  func previousParagraphBoundary(from origin: Int) -> Int? {
    guard origin > 0 else { return nil }
    let range = paragraphRange(at: origin, around: false)
    if range.lowerBound < origin { return range.lowerBound }
    let probe = previousCharacterBoundary(from: origin)
    return paragraphRange(at: probe, around: false).lowerBound
  }

  func wordObjectRangeAt(origin: Int) -> Range<Int>? {
    let range = wordObjectRange(at: origin, whole: false, inner: true)
    guard !range.isEmpty else { return nil }
    return range
  }

  func searchMatchRange(
    _ query: String,
    forward: Bool,
    from origin: Int,
    count: Int
  ) -> Range<Int>? {
    guard
      let compiled = try? VimRegexCompiler.compile(
        query,
        ignoreCase: searchIgnoreCase,
        smartCase: searchSmartCase
      )
    else { return nil }

    let length = state.text.utf16.count
    let matches = compiled.expression.matches(
      in: state.text,
      range: NSRange(location: 0, length: length)
    )
    guard !matches.isEmpty else { return nil }

    var cursor = clamp(origin)
    var selected: NSTextCheckingResult?
    for iteration in 0..<max(1, count) {
      if forward {
        let current = matches.first(where: {
          $0.range.location <= cursor && cursor < NSMaxRange($0.range)
        })
        let start = iteration == 0 && current != nil ? cursor : nextCharacterBoundary(from: cursor)
        selected =
          current ?? matches.first(where: { $0.range.location >= start })
          ?? (searchWrap ? matches.first : nil)
      } else {
        let current = matches.last(where: {
          $0.range.location <= cursor && cursor < NSMaxRange($0.range)
        })
        selected =
          current ?? matches.last(where: { $0.range.location < cursor })
          ?? (searchWrap ? matches.last : nil)
      }
      guard let selected else { return nil }
      cursor = selected.range.location
    }
    guard let selected else { return nil }
    let lower = selected.range.location
    let upper = min(length, NSMaxRange(selected.range))
    return lower..<max(lower, upper)
  }

  func searchDestination(
    _ query: String,
    forward: Bool,
    from origin: Int,
    count: Int
  ) -> Int? {
    guard
      let compiled = try? VimRegexCompiler.compile(
        query,
        ignoreCase: searchIgnoreCase,
        smartCase: searchSmartCase
      )
    else { return nil }

    let length = state.text.utf16.count
    let matches = compiled.expression.matches(
      in: state.text,
      range: NSRange(location: 0, length: length)
    )
    guard !matches.isEmpty else { return nil }

    var cursor = clamp(origin)
    for _ in 0..<max(1, count) {
      let next: Int?
      if forward {
        let start = min(length, nextCharacterBoundary(from: cursor))
        next =
          matches.first(where: { $0.range.location >= start })?.range.location
          ?? (searchWrap ? matches.first?.range.location : nil)
      } else {
        next =
          matches.last(where: { $0.range.location < cursor })?.range.location
          ?? (searchWrap ? matches.last?.range.location : nil)
      }
      guard let next else { return nil }
      cursor = next
    }
    return cursor
  }

  func linewiseRange(from offset: Int, count: Int) -> Range<Int> {
    let lower = lineStart(at: offset)
    var upper = lower
    for _ in 0..<count {
      let next = lineEndIncludingNewline(at: upper)
      if next <= upper {
        upper = state.text.utf16.count
        break
      }
      upper = next
      if upper >= state.text.utf16.count { break }
    }
    if upper == lower, lower < state.text.utf16.count {
      upper = lineContentEnd(at: lower)
    }
    return lower..<max(lower, upper)
  }
}
