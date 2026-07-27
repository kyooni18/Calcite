import Foundation

extension VimEngine {
  func move(_ motion: VimMotion, count: Int) {
    if case .findForward(let character) = motion {
      lastFind = (character, true, false)
    } else if case .findBackward(let character) = motion {
      lastFind = (character, false, false)
    } else if case .tillForward(let character) = motion {
      lastFind = (character, true, true)
    } else if case .tillBackward(let character) = motion {
      lastFind = (character, false, true)
    }

    let result = evaluateMotion(motion, count: count, from: state.cursor)
    state.cursor = result.destination
    preferredColumn = result.desiredColumn
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func evaluateMotion(
    _ motion: VimMotion,
    count: Int,
    from origin: Int
  ) -> VimMotionResult {
    let effectiveCount = max(1, count)
    var destination = clamp(origin)
    var desiredColumn: Int?
    let kind: VimMotionKind
    let inclusive: Bool

    switch motion {
    case .left:
      kind = .characterwise
      inclusive = false
      for _ in 0..<effectiveCount {
        let start = lineStart(at: destination)
        guard destination > start else { break }
        destination = previousCharacterBoundary(from: destination)
      }

    case .right:
      kind = .characterwise
      inclusive = false
      for _ in 0..<effectiveCount {
        let last = normalLineEnd(at: destination)
        guard destination < last else { break }
        destination = nextCharacterBoundary(from: destination)
      }

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
      destination = normalLineEnd(at: destination)

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
      let repetitions: Int
      switch motion {
      case .up:
        direction = -1
        repetitions = effectiveCount
      case .down:
        direction = 1
        repetitions = effectiveCount
      case .pageUp:
        direction = -1
        repetitions = viewportPageLineCount * effectiveCount
      case .pageDown:
        direction = 1
        repetitions = viewportPageLineCount * effectiveCount
      case .halfPageUp:
        direction = -1
        repetitions = viewportHalfPageLineCount * effectiveCount
      default:
        direction = 1
        repetitions = viewportHalfPageLineCount * effectiveCount
      }
      let desired =
        preferredColumn
        ?? characterDistance(from: lineStart(at: destination), to: destination)
      for _ in 0..<repetitions {
        let currentStart = lineStart(at: destination)
        let targetStart =
          direction < 0 ? previousLineStart(currentStart) : nextLineStart(currentStart)
        guard targetStart != currentStart else { break }
        destination = characterOffset(
          from: targetStart,
          count: desired,
          limit: lineContentEnd(at: targetStart)
        )
      }
      desiredColumn = desired

    case .wordForward:
      kind = .characterwise
      inclusive = false
      for _ in 0..<effectiveCount { destination = nextWord(from: destination, whole: false) }

    case .wordBackward:
      kind = .characterwise
      inclusive = false
      for _ in 0..<effectiveCount { destination = previousWord(from: destination, whole: false) }

    case .wordEnd:
      kind = .characterwise
      inclusive = true
      for _ in 0..<effectiveCount { destination = wordEnd(from: destination, whole: false) }

    case .findForward(let character):
      kind = .characterwise
      inclusive = true
      destination =
        findDestination(
          character,
          from: destination,
          forward: true,
          till: false,
          count: effectiveCount
        ) ?? destination

    case .findBackward(let character):
      kind = .characterwise
      inclusive = true
      destination =
        findDestination(
          character,
          from: destination,
          forward: false,
          till: false,
          count: effectiveCount
        ) ?? destination

    case .tillForward(let character):
      kind = .characterwise
      inclusive = true
      destination =
        findDestination(
          character,
          from: destination,
          forward: true,
          till: true,
          count: effectiveCount
        ) ?? destination

    case .tillBackward(let character):
      kind = .characterwise
      inclusive = true
      destination =
        findDestination(
          character,
          from: destination,
          forward: false,
          till: true,
          count: effectiveCount
        ) ?? destination

    case .matchingPair:
      kind = .characterwise
      inclusive = true
      destination = matchingPairDestination(from: destination) ?? destination

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
      desiredColumn: desiredColumn
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
    guard let current = character(at: origin) else { return nil }
    if let close = pairs[current] {
      var depth = 0
      var index = origin
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
    } else if let open = pairs.first(where: { $0.value == current })?.key {
      var depth = 0
      var index = origin
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

  func moveToPreviousWordEnd(count: Int, whole: Bool) {
    for _ in 0..<max(1, count) {
      guard state.cursor > 0 else { break }
      var current = state.cursor
      if let currentClass = wordClass(at: current, whole: whole), currentClass != .whitespace {
        while current > 0 {
          let previous = previousCharacterBoundary(from: current)
          guard wordClass(at: previous, whole: whole) == currentClass else { break }
          current = previous
        }
      }
      guard current > 0 else {
        state.cursor = 0
        break
      }
      current = previousCharacterBoundary(from: current)
      while current > 0, wordClass(at: current, whole: whole) == .whitespace {
        current = previousCharacterBoundary(from: current)
      }
      state.cursor = current
    }
    preferredColumn = nil
    normalizeCursorForMode()
    updateVisualSelection()
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
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func moveToCurrentOrFollowingLine(count: Int) {
    if count > 1 { moveToAdjacentLine(count: count - 1, forward: true) }
    state.cursor = firstNonBlank(at: state.cursor)
    preferredColumn = nil
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
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func moveWholeWordForward(count: Int) {
    preferredColumn = nil
    for _ in 0..<count { state.cursor = nextWord(from: state.cursor, whole: true) }
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func moveWholeWordBackward(count: Int) {
    preferredColumn = nil
    for _ in 0..<count { state.cursor = previousWord(from: state.cursor, whole: true) }
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func moveWholeWordEnd(count: Int) {
    preferredColumn = nil
    for _ in 0..<count { state.cursor = wordEnd(from: state.cursor, whole: true) }
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func operatorRange(for motion: VimMotion, count: Int) -> VimOperatorRange {
    let start = state.cursor
    let result = evaluateMotion(motion, count: count, from: start)
    let destination = result.destination

    if result.kind == .linewise {
      let lower = lineStart(at: min(start, destination))
      let upper = lineEndIncludingNewline(at: max(start, destination))
      return VimOperatorRange(range: lower..<max(lower, upper), linewise: true)
    }

    switch motion {
    case .lineEnd:
      let upper = lineContentEnd(at: start)
      return VimOperatorRange(range: min(start, upper)..<max(start, upper), linewise: false)

    case .wordForward:
      var upper = destination
      if result.crossedLine { upper = lineContentEnd(at: start) }
      return VimOperatorRange(range: min(start, upper)..<max(start, upper), linewise: false)

    case .wordBackward, .lineStart, .firstNonBlank, .left:
      return VimOperatorRange(
        range: min(start, destination)..<max(start, destination),
        linewise: false
      )

    case .right:
      let upper =
        destination == start
        ? min(lineContentEnd(at: start), nextCharacterBoundary(from: start))
        : destination
      return VimOperatorRange(
        range: min(start, upper)..<max(start, upper),
        linewise: false
      )

    case .wordEnd, .findForward, .findBackward, .tillForward, .tillBackward, .matchingPair:
      let lower = min(start, destination)
      let upper = nextCharacterBoundary(from: max(start, destination))
      return VimOperatorRange(range: lower..<max(lower, upper), linewise: false)

    case .up, .down, .pageUp, .pageDown, .halfPageUp, .halfPageDown,
      .documentStart, .documentEnd, .line:
      assertionFailure("Linewise motions are handled before characterwise range evaluation")
      return VimOperatorRange(range: start..<start, linewise: false)
    }
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
