import Foundation

struct VimLine: Hashable, Sendable {
  var start: Int
  var contentEnd: Int
  var fullEnd: Int

  var isEmpty: Bool { start == contentEnd }
}

enum VimWordClass: Equatable {
  case whitespace
  case keyword
  case punctuation
}

struct VimTextBuffer {
  var text: String

  init(_ text: String) {
    self.text = text
  }

  var length: Int { text.utf16.count }
  var nsText: NSString { text as NSString }

  static func normalize(
    offset: Int,
    in text: String,
    bias: VimUTF16BoundaryBias = .backward
  ) -> Int {
    let count = text.utf16.count
    var candidate = max(0, min(offset, count))

    func isBoundary(_ value: Int) -> Bool {
      let index = text.utf16.index(text.utf16.startIndex, offsetBy: value)
      return String.Index(index, within: text) != nil
    }

    if isBoundary(candidate) { return candidate }
    switch bias {
    case .backward:
      while candidate > 0 {
        candidate -= 1
        if isBoundary(candidate) { return candidate }
      }
    case .forward:
      while candidate < count {
        candidate += 1
        if isBoundary(candidate) { return candidate }
      }
    }
    return bias == .backward ? 0 : count
  }

  func normalize(_ offset: Int, bias: VimUTF16BoundaryBias = .backward) -> Int {
    Self.normalize(offset: offset, in: text, bias: bias)
  }

  func stringIndex(_ offset: Int, bias: VimUTF16BoundaryBias = .backward) -> String.Index {
    let safe = normalize(offset, bias: bias)
    let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: safe)
    return String.Index(utf16Index, within: text) ?? text.endIndex
  }

  func character(at offset: Int) -> Character? {
    let start = normalize(offset)
    guard start < length else { return nil }
    let end = nextBoundary(from: start)
    return text[stringIndex(start)..<stringIndex(end)].first
  }

  func substring(in range: Range<Int>) -> String {
    let normalized = normalized(range)
    return String(text[stringIndex(normalized.lowerBound)..<stringIndex(normalized.upperBound)])
  }

  func normalized(_ range: Range<Int>) -> Range<Int> {
    let lower = normalize(range.lowerBound, bias: .backward)
    let upper = normalize(range.upperBound, bias: .forward)
    return min(lower, upper)..<max(lower, upper)
  }

  func previousBoundary(from offset: Int) -> Int {
    var candidate = normalize(offset, bias: .backward)
    guard candidate > 0 else { return 0 }
    candidate -= 1
    return normalize(candidate, bias: .backward)
  }

  func nextBoundary(from offset: Int) -> Int {
    var candidate = normalize(offset, bias: .forward)
    guard candidate < length else { return length }
    candidate += 1
    return normalize(candidate, bias: .forward)
  }

  func advance(from offset: Int, by characterCount: Int) -> Int {
    var result = normalize(offset)
    if characterCount >= 0 {
      for _ in 0..<characterCount { result = nextBoundary(from: result) }
    } else {
      for _ in 0..<(-characterCount) { result = previousBoundary(from: result) }
    }
    return result
  }

  func characterDistance(from lower: Int, to upper: Int) -> Int {
    var current = normalize(min(lower, upper))
    let limit = normalize(max(lower, upper))
    var count = 0
    while current < limit {
      let next = nextBoundary(from: current)
      guard next > current else { break }
      current = next
      count += 1
    }
    return count
  }

  func line(at offset: Int) -> VimLine {
    let ns = nsText
    let safe = max(0, min(normalize(offset), ns.length))
    let range = ns.lineRange(for: NSRange(location: safe, length: 0))
    var contentEnd = NSMaxRange(range)
    if contentEnd > range.location {
      let last = ns.character(at: contentEnd - 1)
      if last == 10 {
        contentEnd -= 1
        if contentEnd > range.location, ns.character(at: contentEnd - 1) == 13 {
          contentEnd -= 1
        }
      } else if last == 13 {
        contentEnd -= 1
      }
    }
    return VimLine(start: range.location, contentEnd: contentEnd, fullEnd: NSMaxRange(range))
  }

  func lineStart(at offset: Int) -> Int { line(at: offset).start }
  func lineContentEnd(at offset: Int) -> Int { line(at: offset).contentEnd }
  func lineFullEnd(at offset: Int) -> Int { line(at: offset).fullEnd }

  func normalLineEnd(at offset: Int) -> Int {
    let value = line(at: offset)
    guard value.contentEnd > value.start else { return value.start }
    return previousBoundary(from: value.contentEnd)
  }

  func previousLineStart(from offset: Int) -> Int {
    let start = lineStart(at: offset)
    guard start > 0 else { return 0 }
    return lineStart(at: previousBoundary(from: start))
  }

  func nextLineStart(from offset: Int) -> Int {
    let current = line(at: offset)
    return current.fullEnd < length ? current.fullEnd : min(current.fullEnd, length)
  }

  func lineNumber(at offset: Int) -> Int {
    let safe = normalize(offset)
    var number = 1
    var position = 0
    while position < safe {
      let next = lineFullEnd(at: position)
      guard next > position else { break }
      if next > safe { break }
      position = next
      number += 1
    }
    return number
  }

  func offsetOfLine(_ number: Int) -> Int {
    guard number > 1 else { return 0 }
    var current = 0
    var currentNumber = 1
    while currentNumber < number, current < length {
      let next = lineFullEnd(at: current)
      guard next > current else { break }
      current = next
      currentNumber += 1
    }
    return min(current, length)
  }

  func lastLineStart() -> Int {
    guard length > 0 else { return 0 }
    if let last = text.utf16.last, last == 10 || last == 13 { return length }
    return lineStart(at: previousBoundary(from: length))
  }

  func firstNonBlank(at offset: Int) -> Int {
    let line = line(at: offset)
    var current = line.start
    while current < line.contentEnd, isHorizontalWhitespace(at: current) {
      current = nextBoundary(from: current)
    }
    return current
  }

  func visualColumn(at offset: Int, tabWidth: Int) -> Int {
    let line = line(at: offset)
    var current = line.start
    var column = 0
    while current < min(normalize(offset), line.contentEnd) {
      if character(at: current) == "\t" {
        let width = max(1, tabWidth)
        column += width - (column % width)
      } else {
        column += 1
      }
      current = nextBoundary(from: current)
    }
    return column
  }

  func offset(inLineStartingAt start: Int, visualColumn target: Int, tabWidth: Int) -> Int {
    let line = line(at: start)
    guard target > 0 else { return line.start }
    let insertion = insertionOffset(
      inLineStartingAt: start,
      visualColumn: target,
      tabWidth: tabWidth
    )
    if insertion >= line.contentEnd, line.contentEnd > line.start {
      return normalLineEnd(at: line.start)
    }
    return insertion
  }

  func insertionOffset(
    inLineStartingAt start: Int,
    visualColumn target: Int,
    tabWidth: Int
  ) -> Int {
    let line = line(at: start)
    guard target > 0 else { return line.start }
    var current = line.start
    var column = 0
    while current < line.contentEnd {
      let nextColumn: Int
      if character(at: current) == "\t" {
        let width = max(1, tabWidth)
        nextColumn = column + width - (column % width)
      } else {
        nextColumn = column + 1
      }
      if nextColumn > target { return current }
      column = nextColumn
      let next = nextBoundary(from: current)
      if column == target { return next }
      current = next
    }
    return line.contentEnd
  }

  func wordClass(at offset: Int, bigWord: Bool = false) -> VimWordClass? {
    guard let character = character(at: offset) else { return nil }
    if character.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
      return .whitespace
    }
    if bigWord { return .keyword }
    let keywordSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    if character.unicodeScalars.allSatisfy({ keywordSet.contains($0) }) { return .keyword }
    return .punctuation
  }

  func isHorizontalWhitespace(at offset: Int) -> Bool {
    guard let character = character(at: offset) else { return false }
    return character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
  }

  func isWhitespace(at offset: Int) -> Bool {
    wordClass(at: offset) == .whitespace
  }

  func nextWordStart(from offset: Int, bigWord: Bool = false) -> Int {
    var current = normalize(offset)
    guard current < length else { return length }
    let initialClass = wordClass(at: current, bigWord: bigWord)
    if initialClass == .whitespace {
      while current < length, wordClass(at: current, bigWord: bigWord) == .whitespace {
        current = nextBoundary(from: current)
      }
      return current
    }
    while current < length, wordClass(at: current, bigWord: bigWord) == initialClass {
      current = nextBoundary(from: current)
    }
    while current < length, wordClass(at: current, bigWord: bigWord) == .whitespace {
      current = nextBoundary(from: current)
    }
    return current
  }

  func previousWordStart(from offset: Int, bigWord: Bool = false) -> Int {
    guard offset > 0 else { return 0 }
    var current = previousBoundary(from: offset)
    while current > 0, wordClass(at: current, bigWord: bigWord) == .whitespace {
      current = previousBoundary(from: current)
    }
    let targetClass = wordClass(at: current, bigWord: bigWord)
    while current > 0 {
      let previous = previousBoundary(from: current)
      guard wordClass(at: previous, bigWord: bigWord) == targetClass else { break }
      current = previous
    }
    return current
  }

  func wordEnd(from offset: Int, bigWord: Bool = false) -> Int {
    var current = normalize(offset)
    if current >= length { return max(0, previousBoundary(from: length)) }

    if wordClass(at: current, bigWord: bigWord) != .whitespace {
      let next = nextBoundary(from: current)
      if next < length,
        wordClass(at: next, bigWord: bigWord) == wordClass(at: current, bigWord: bigWord)
      {
        current = next
      } else {
        current = next
        while current < length, wordClass(at: current, bigWord: bigWord) == .whitespace {
          current = nextBoundary(from: current)
        }
      }
    } else {
      while current < length, wordClass(at: current, bigWord: bigWord) == .whitespace {
        current = nextBoundary(from: current)
      }
    }

    guard current < length else { return previousBoundary(from: length) }
    let targetClass = wordClass(at: current, bigWord: bigWord)
    while true {
      let next = nextBoundary(from: current)
      guard next < length, wordClass(at: next, bigWord: bigWord) == targetClass else {
        return current
      }
      current = next
    }
  }

  func previousWordEnd(from offset: Int, bigWord: Bool = false) -> Int {
    guard offset > 0 else { return 0 }
    var current = previousBoundary(from: offset)
    while current > 0, wordClass(at: current, bigWord: bigWord) == .whitespace {
      current = previousBoundary(from: current)
    }
    return current
  }

  func wordObjectRange(at offset: Int, bigWord: Bool, inner: Bool) -> Range<Int> {
    guard length > 0 else { return 0..<0 }
    var cursor = min(normalize(offset), max(0, previousBoundary(from: length)))
    var targetClass = wordClass(at: cursor, bigWord: bigWord)
    if targetClass == .whitespace {
      var next = cursor
      while next < length, wordClass(at: next, bigWord: bigWord) == .whitespace {
        next = nextBoundary(from: next)
      }
      if next < length {
        cursor = next
        targetClass = wordClass(at: cursor, bigWord: bigWord)
      }
    }
    guard let targetClass else { return cursor..<cursor }

    var lower = cursor
    while lower > 0 {
      let previous = previousBoundary(from: lower)
      guard wordClass(at: previous, bigWord: bigWord) == targetClass else { break }
      lower = previous
    }
    var upper = nextBoundary(from: cursor)
    while upper < length, wordClass(at: upper, bigWord: bigWord) == targetClass {
      upper = nextBoundary(from: upper)
    }
    guard !inner else { return lower..<upper }

    var trailing = upper
    while trailing < length, wordClass(at: trailing, bigWord: bigWord) == .whitespace,
      character(at: trailing) != "\n", character(at: trailing) != "\r"
    {
      trailing = nextBoundary(from: trailing)
    }
    if trailing > upper { return lower..<trailing }

    var leading = lower
    while leading > 0 {
      let previous = previousBoundary(from: leading)
      guard wordClass(at: previous, bigWord: bigWord) == .whitespace,
        character(at: previous) != "\n", character(at: previous) != "\r"
      else { break }
      leading = previous
    }
    return leading..<upper
  }

  func paragraphForward(from offset: Int) -> Int {
    var current = lineStart(at: offset)
    var sawBlank = line(at: current).isEmpty
    while current < length {
      let next = nextLineStart(from: current)
      guard next > current else { break }
      let isBlank = line(at: next).isEmpty
      if sawBlank, !isBlank { return firstNonBlank(at: next) }
      sawBlank = sawBlank || isBlank
      current = next
    }
    return normalDocumentEnd()
  }

  func paragraphBackward(from offset: Int) -> Int {
    var current = lineStart(at: offset)
    var sawBlank = line(at: current).isEmpty
    while current > 0 {
      let previous = previousLineStart(from: current)
      let isBlank = line(at: previous).isEmpty
      if sawBlank, !isBlank { return firstNonBlank(at: previous) }
      sawBlank = sawBlank || isBlank
      if previous == current { break }
      current = previous
    }
    return 0
  }

  func sentenceForward(from offset: Int) -> Int {
    var current = normalize(offset)
    while current < length {
      if let character = character(at: current), ".!?".contains(character) {
        var next = nextBoundary(from: current)
        while next < length, isWhitespace(at: next) { next = nextBoundary(from: next) }
        return next < length ? next : normalDocumentEnd()
      }
      current = nextBoundary(from: current)
    }
    return normalDocumentEnd()
  }

  func sentenceBackward(from offset: Int) -> Int {
    var current = previousBoundary(from: offset)
    while current > 0 {
      let previous = previousBoundary(from: current)
      if let character = character(at: previous), ".!?".contains(character) {
        var next = nextBoundary(from: previous)
        while next < length, isWhitespace(at: next) { next = nextBoundary(from: next) }
        if next < offset { return next }
      }
      current = previous
    }
    return 0
  }

  func normalDocumentEnd() -> Int {
    guard length > 0 else { return 0 }
    return normalLineEnd(at: lastLineStart())
  }

  func currentWord(at offset: Int, bigWord: Bool = false) -> String? {
    let range = wordObjectRange(at: offset, bigWord: bigWord, inner: true)
    guard !range.isEmpty else { return nil }
    return substring(in: range)
  }

  func find(
    _ character: Character,
    from offset: Int,
    forward: Bool,
    till: Bool,
    count: Int,
    withinCurrentLine: Bool = true
  ) -> Int? {
    let ns = nsText
    let currentLine = line(at: offset)
    var current = normalize(offset)
    for _ in 0..<max(1, count) {
      let range: NSRange
      if forward {
        let start = min(ns.length, nextBoundary(from: current))
        let end = withinCurrentLine ? currentLine.contentEnd : ns.length
        guard start <= end else { return nil }
        range = NSRange(location: start, length: max(0, end - start))
      } else {
        let start = withinCurrentLine ? currentLine.start : 0
        guard current >= start else { return nil }
        range = NSRange(location: start, length: current - start)
      }
      let result = ns.range(
        of: String(character),
        options: forward ? [] : .backwards,
        range: range
      )
      guard result.location != NSNotFound else { return nil }
      current = result.location
    }
    if till {
      return forward ? previousBoundary(from: current) : nextBoundary(from: current)
    }
    return current
  }

  func matchingPair(from offset: Int) -> Int? {
    let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "<": ">"]
    var candidate = normalize(offset)
    let currentLine = line(at: candidate)
    while candidate < currentLine.contentEnd {
      if let value = character(at: candidate), pairs[value] != nil || pairs.values.contains(value) {
        break
      }
      candidate = nextBoundary(from: candidate)
    }
    guard candidate < length, let value = character(at: candidate) else { return nil }

    if let close = pairs[value] {
      var depth = 0
      var current = candidate
      while current < length {
        if character(at: current) == value { depth += 1 }
        if character(at: current) == close {
          depth -= 1
          if depth == 0 { return current }
        }
        current = nextBoundary(from: current)
      }
      return nil
    }

    guard let open = pairs.first(where: { $0.value == value })?.key else { return nil }
    var depth = 0
    var current = candidate
    while true {
      if character(at: current) == value { depth += 1 }
      if character(at: current) == open {
        depth -= 1
        if depth == 0 { return current }
      }
      if current == 0 { break }
      current = previousBoundary(from: current)
    }
    return nil
  }

  func enclosingPair(
    open: Character,
    close: Character,
    at offset: Int,
    inner: Bool
  ) -> Range<Int> {
    guard length > 0 else { return 0..<0 }
    if open == close { return enclosingQuote(open, at: offset, inner: inner) }

    var depth = 0
    var left: Int?
    var current = min(normalize(offset), max(0, previousBoundary(from: length)))
    while true {
      if character(at: current) == close { depth += 1 }
      if character(at: current) == open {
        if depth == 0 {
          left = current
          break
        }
        depth -= 1
      }
      if current == 0 { break }
      current = previousBoundary(from: current)
    }
    guard let left else { return offset..<offset }

    depth = 0
    var right: Int?
    current = left
    while current < length {
      if character(at: current) == open { depth += 1 }
      if character(at: current) == close {
        depth -= 1
        if depth == 0 {
          right = current
          break
        }
      }
      current = nextBoundary(from: current)
    }
    guard let right else { return offset..<offset }
    return inner
      ? nextBoundary(from: left)..<right
      : left..<nextBoundary(from: right)
  }

  func enclosingQuote(_ quote: Character, at offset: Int, inner: Bool) -> Range<Int> {
    let currentLine = line(at: offset)
    var quotes: [Int] = []
    var current = currentLine.start
    var escaped = false
    while current < currentLine.contentEnd {
      let value = character(at: current)
      if value == quote, !escaped { quotes.append(current) }
      if value == "\\" {
        escaped.toggle()
      } else {
        escaped = false
      }
      current = nextBoundary(from: current)
    }
    guard quotes.count >= 2 else { return offset..<offset }
    for index in stride(from: 0, to: quotes.count - 1, by: 2) {
      let left = quotes[index]
      let right = quotes[index + 1]
      if left <= offset, offset <= right {
        return inner
          ? nextBoundary(from: left)..<right
          : left..<nextBoundary(from: right)
      }
    }
    return offset..<offset
  }

  func paragraphRange(at offset: Int, inner: Bool) -> Range<Int> {
    var lower = lineStart(at: offset)
    while lower > 0 {
      let previous = previousLineStart(from: lower)
      if line(at: previous).isEmpty { break }
      lower = previous
    }
    var upper = lineFullEnd(at: offset)
    while upper < length, !line(at: upper).isEmpty {
      let next = lineFullEnd(at: upper)
      guard next > upper else { break }
      upper = next
    }
    if !inner {
      while upper < length, line(at: upper).isEmpty {
        let next = lineFullEnd(at: upper)
        guard next > upper else { break }
        upper = next
      }
    }
    return lower..<upper
  }

  func sentenceRange(at offset: Int, inner: Bool) -> Range<Int> {
    let lower = sentenceBackward(from: nextBoundary(from: offset))
    var upper = sentenceForward(from: offset)
    if upper <= lower { upper = lineFullEnd(at: offset) }
    if inner {
      while upper > lower {
        let previous = previousBoundary(from: upper)
        guard isWhitespace(at: previous) else { break }
        upper = previous
      }
    }
    return lower..<upper
  }

  func blockRanges(anchor: Int, head: Int, tabWidth: Int) -> [Range<Int>] {
    let anchorLine = lineNumber(at: anchor)
    let headLine = lineNumber(at: head)
    let anchorColumn = visualColumn(at: anchor, tabWidth: tabWidth)
    let headColumn = visualColumn(at: head, tabWidth: tabWidth)
    return blockRanges(
      anchorLine: anchorLine,
      headLine: headLine,
      anchorColumn: anchorColumn,
      headColumn: headColumn,
      tabWidth: tabWidth
    )
  }

  func blockRanges(
    anchorLine: Int,
    headLine: Int,
    anchorColumn: Int,
    headColumn: Int,
    tabWidth: Int
  ) -> [Range<Int>] {
    let lowerLine = min(anchorLine, headLine)
    let upperLine = max(anchorLine, headLine)
    let lowerColumn = min(anchorColumn, headColumn)
    let upperColumn = max(anchorColumn, headColumn)

    return (lowerLine...upperLine).compactMap { number in
      let start = offsetOfLine(number)
      let line = line(at: start)
      guard !line.isEmpty else { return line.start..<line.start }
      let lower = insertionOffset(
        inLineStartingAt: start,
        visualColumn: lowerColumn,
        tabWidth: tabWidth
      )
      let upperStart = insertionOffset(
        inLineStartingAt: start,
        visualColumn: upperColumn,
        tabWidth: tabWidth
      )
      let upper =
        upperStart < line.contentEnd
        ? min(line.contentEnd, nextBoundary(from: upperStart))
        : line.contentEnd
      return min(lower, upper)..<max(lower, upper)
    }
  }
}

enum VimUTF16BoundaryBias {
  case backward
  case forward
}
