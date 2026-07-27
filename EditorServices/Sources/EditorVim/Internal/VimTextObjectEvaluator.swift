import Foundation

extension VimEngine {
  func textObjectRange(_ object: VimTextObject, inner: Bool, count: Int) -> Range<Int> {
    var range: Range<Int>
    switch object {
    case .word:
      range = wordObjectRange(at: state.cursor, whole: false, inner: inner)
    case .WORD:
      range = wordObjectRange(at: state.cursor, whole: true, inner: inner)
    case .paragraph:
      range = paragraphRange(at: state.cursor, around: !inner)
    case .sentence:
      range = sentenceRange(at: state.cursor, around: !inner)
    case .quotes(let quote):
      range = quoteRange(quote, inner: inner)
    case .parentheses:
      range = enclosingRange(open: "(", close: ")", inner: inner)
    case .brackets:
      range = enclosingRange(open: "[", close: "]", inner: inner)
    case .braces:
      range = enclosingRange(open: "{", close: "}", inner: inner)
    case .angles:
      range = enclosingRange(open: "<", close: ">", inner: inner)
    case .tag:
      range = tagRange(inner: inner)
    }

    guard count > 1, !range.isEmpty else { return range }
    var upper = range.upperBound
    for _ in 1..<count {
      let nextCursor = min(state.text.utf16.count, upper)
      let next: Range<Int>
      switch object {
      case .word:
        next = wordObjectRange(at: nextCursor, whole: false, inner: inner)
      case .WORD:
        next = wordObjectRange(at: nextCursor, whole: true, inner: inner)
      case .paragraph:
        next = paragraphRange(at: nextCursor, around: !inner)
      case .sentence:
        next = sentenceRange(at: nextCursor, around: !inner)
      default:
        return range
      }
      guard next.upperBound > upper else { break }
      upper = next.upperBound
    }
    return range.lowerBound..<upper
  }

  func wordObjectRange(at offset: Int, whole: Bool, inner: Bool) -> Range<Int> {
    guard !state.text.isEmpty else { return 0..<0 }
    var cursor = min(clamp(offset), max(0, state.text.utf16.count - 1))
    if character(at: cursor) == "\n" || character(at: cursor) == "\r" {
      cursor = previousCharacterBoundary(from: cursor)
    }
    guard let classification = wordClass(at: cursor, whole: whole) else { return cursor..<cursor }

    var lower = cursor
    while lower > lineStart(at: cursor) {
      let previous = previousCharacterBoundary(from: lower)
      guard wordClass(at: previous, whole: whole) == classification else { break }
      lower = previous
    }

    var upper = nextCharacterBoundary(from: cursor)
    let contentEnd = lineContentEnd(at: cursor)
    while upper < contentEnd, wordClass(at: upper, whole: whole) == classification {
      upper = nextCharacterBoundary(from: upper)
    }

    guard !inner, classification != .whitespace else { return lower..<upper }

    var trailing = upper
    while trailing < contentEnd, wordClass(at: trailing, whole: whole) == .whitespace {
      trailing = nextCharacterBoundary(from: trailing)
    }
    if trailing > upper { return lower..<trailing }

    var leading = lower
    while leading > lineStart(at: cursor) {
      let previous = previousCharacterBoundary(from: leading)
      guard wordClass(at: previous, whole: whole) == .whitespace else { break }
      leading = previous
    }
    return leading..<upper
  }

  func paragraphRange(at offset: Int, around: Bool) -> Range<Int> {
    var first = lineStart(at: offset)
    var lastExclusive = lineEndIncludingNewline(at: offset)

    if isBlankLine(at: first) {
      while first > 0 {
        let previous = previousLineStart(first)
        guard previous < first, isBlankLine(at: previous) else { break }
        first = previous
      }
      while lastExclusive < state.text.utf16.count, isBlankLine(at: lastExclusive) {
        let next = lineEndIncludingNewline(at: lastExclusive)
        guard next > lastExclusive else { break }
        lastExclusive = next
      }
      return first..<lastExclusive
    }

    while first > 0 {
      let previous = previousLineStart(first)
      guard previous < first, !isBlankLine(at: previous) else { break }
      first = previous
    }

    var current = lastExclusive
    while current < state.text.utf16.count, !isBlankLine(at: current) {
      let next = lineEndIncludingNewline(at: current)
      guard next > current else { break }
      lastExclusive = next
      current = next
    }

    if around {
      while lastExclusive < state.text.utf16.count, isBlankLine(at: lastExclusive) {
        let next = lineEndIncludingNewline(at: lastExclusive)
        guard next > lastExclusive else { break }
        lastExclusive = next
      }
    }
    return first..<max(first, lastExclusive)
  }

  func sentenceRange(at offset: Int, around: Bool) -> Range<Int> {
    let ns = state.text as NSString
    guard ns.length > 0 else { return 0..<0 }
    let safe = min(max(0, offset), ns.length - 1)

    var lower = safe
    while lower > 0 {
      let previous = lower - 1
      let scalar = ns.character(at: previous)
      if scalar == 10 || scalar == 13 {
        let earlier = previous > 0 ? ns.character(at: previous - 1) : 0
        if earlier == 10 || earlier == 13 { break }
      }
      if scalar == 46 || scalar == 33 || scalar == 63 {
        let next = previous + 1
        if next >= ns.length || isWhitespaceOrNewline(at: next) {
          break
        }
      }
      lower -= 1
    }
    while lower < ns.length, isWhitespaceOrNewline(at: lower) { lower += 1 }

    var upper = safe
    while upper < ns.length {
      let scalar = ns.character(at: upper)
      upper += 1
      if scalar == 46 || scalar == 33 || scalar == 63 {
        while upper < ns.length, [34, 39, 41, 93].contains(ns.character(at: upper)) { upper += 1 }
        break
      }
      if scalar == 10 || scalar == 13, upper < ns.length,
        ns.character(at: upper) == 10 || ns.character(at: upper) == 13
      {
        break
      }
    }

    if around {
      while upper < ns.length, isWhitespaceOrNewline(at: upper) { upper += 1 }
    }
    return normalized(lower..<upper)
  }

  func quoteRange(_ quote: Character, inner: Bool) -> Range<Int> {
    let start = lineStart(at: state.cursor)
    let end = lineContentEnd(at: state.cursor)
    var occurrences: [Int] = []
    var current = start
    while current < end {
      if character(at: current) == quote, !isEscaped(at: current) { occurrences.append(current) }
      current = nextCharacterBoundary(from: current)
    }
    guard occurrences.count >= 2 else { return state.cursor..<state.cursor }

    for index in 0..<(occurrences.count - 1) {
      let left = occurrences[index]
      let right = occurrences[index + 1]
      if left <= state.cursor, state.cursor <= right {
        let lower = inner ? nextCharacterBoundary(from: left) : left
        let upper = inner ? right : nextCharacterBoundary(from: right)
        return lower..<max(lower, upper)
      }
    }
    return state.cursor..<state.cursor
  }

  func enclosingRange(open: Character, close: Character, inner: Bool) -> Range<Int> {
    let ns = state.text as NSString
    guard ns.length > 0 else { return 0..<0 }
    var stack: [Int] = []
    var containingOpen: Int?
    var index = 0
    let cursor = min(state.cursor, ns.length - 1)

    while index <= cursor, index < ns.length {
      let current = character(at: index)
      if current == open {
        stack.append(index)
      } else if current == close, !stack.isEmpty {
        stack.removeLast()
      }
      index = nextCharacterBoundary(from: index)
      if index == 0 { break }
    }
    containingOpen = stack.last
    guard let left = containingOpen else { return state.cursor..<state.cursor }

    var depth = 0
    var right: Int?
    index = left
    while index < ns.length {
      let current = character(at: index)
      if current == open { depth += 1 }
      if current == close {
        depth -= 1
        if depth == 0 {
          right = index
          break
        }
      }
      let next = nextCharacterBoundary(from: index)
      guard next > index else { break }
      index = next
    }
    guard let right else { return state.cursor..<state.cursor }
    let lower = inner ? nextCharacterBoundary(from: left) : left
    let upper = inner ? right : nextCharacterBoundary(from: right)
    return lower..<max(lower, upper)
  }

  func tagRange(inner: Bool) -> Range<Int> {
    let pattern = #"<\s*(/?)\s*([A-Za-z][A-Za-z0-9:_-]*)\b[^>]*?>"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return state.cursor..<state.cursor
    }
    let ns = state.text as NSString
    let matches = regex.matches(in: state.text, range: NSRange(location: 0, length: ns.length))
    var stack: [(name: String, range: NSRange)] = []
    var candidates: [(open: NSRange, close: NSRange)] = []

    for match in matches {
      let source = ns.substring(with: match.range)
      if source.hasSuffix("/>") { continue }
      let closing = match.range(at: 1).location != NSNotFound && match.range(at: 1).length > 0
      let name = ns.substring(with: match.range(at: 2)).lowercased()
      if !closing {
        stack.append((name, match.range))
      } else if let index = stack.lastIndex(where: { $0.name == name }) {
        let open = stack[index]
        stack.removeSubrange(index...)
        candidates.append((open.range, match.range))
      }
    }

    let cursor = state.cursor
    let containing =
      candidates
      .filter { $0.open.location <= cursor && cursor <= NSMaxRange($0.close) }
      .min { (NSMaxRange($0.close) - $0.open.location) < (NSMaxRange($1.close) - $1.open.location) }
    guard let containing else { return cursor..<cursor }
    let lower = inner ? NSMaxRange(containing.open) : containing.open.location
    let upper = inner ? containing.close.location : NSMaxRange(containing.close)
    return normalized(lower..<upper)
  }
}
