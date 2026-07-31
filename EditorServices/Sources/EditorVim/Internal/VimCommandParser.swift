import Foundation

struct VimCommandPrefix: Hashable, Sendable {
  var count = 0
  var register: VimRegister = .unnamed

  var effectiveCount: Int { max(1, count) }
  var isEmpty: Bool { count == 0 && register == .unnamed }

  mutating func appendCountDigit(_ digit: Int) {
    count = VimCommandParser.appendingCountDigit(digit, to: count)
  }
}

struct VimPendingOperation: Hashable, Sendable {
  var value: VimOperator
  var prefixCount: Int
  var suffixCount = 0
  var register: VimRegister
  var forcedKind: VimMotionKind?

  var effectiveCount: Int {
    VimCommandParser.combinedCount(prefixCount, suffixCount)
  }

  mutating func appendCountDigit(_ digit: Int) {
    suffixCount = VimCommandParser.appendingCountDigit(digit, to: suffixCount)
  }
}

enum VimMotionConsumer: Hashable, Sendable {
  case normal(VimCommandPrefix)
  case operation(VimPendingOperation)
  case visual(VimCommandPrefix)

  var count: Int {
    switch self {
    case .normal(let prefix), .visual(let prefix): return prefix.effectiveCount
    case .operation(let pending): return pending.effectiveCount
    }
  }

  var register: VimRegister {
    switch self {
    case .normal(let prefix), .visual(let prefix): return prefix.register
    case .operation(let pending): return pending.register
    }
  }
}

struct VimPendingFind: Hashable, Sendable {
  var forward: Bool
  var till: Bool
  var consumer: VimMotionConsumer
}

struct VimPendingSearch: Hashable, Sendable {
  var forward: Bool
  var consumer: VimMotionConsumer
  var query = ""
}

enum VimPendingMark: Hashable, Sendable {
  case set(VimCommandPrefix)
  case jump(linewise: Bool, prefix: VimCommandPrefix)
  case motion(linewise: Bool, consumer: VimMotionConsumer)
}

enum VimParserState: Hashable, Sendable {
  case idle(VimCommandPrefix)
  case awaitingRegister(VimCommandPrefix)
  case awaitingG(VimCommandPrefix)
  case awaitingWindowCommand(VimCommandPrefix)
  case awaitingMotion(VimPendingOperation)
  case awaitingGMotion(VimPendingOperation)
  case awaitingTextObject(VimMotionConsumer, inner: Bool)
  case awaitingFind(VimPendingFind)
  case awaitingSearch(VimPendingSearch)
  case awaitingMark(VimPendingMark)
  case awaitingReplace(VimCommandPrefix)
  case awaitingMacroRegister(VimCommandPrefix)
  case awaitingMacroStart(VimCommandPrefix)
}

enum VimParserStep: Hashable, Sendable {
  case awaitingMoreInput
  case command(VimSemanticCommand)
  case cancelled
}

/// Pure token parser for Normal, Visual, and operator-pending commands.
///
/// It owns exactly one explicit state. Parsing never reads or mutates the
/// editor buffer; it only returns a semantic command once a sequence is
/// complete.
struct VimCommandParser: Sendable {
  var state: VimParserState = .idle(VimCommandPrefix())

  static let maximumCount = 1_000_000_000

  var isIncomplete: Bool {
    switch state {
    case .idle(let prefix): return !prefix.isEmpty
    default: return true
    }
  }

  var isAtCommandBoundary: Bool {
    if case .idle(let prefix) = state { return prefix.isEmpty }
    return false
  }

  var isOperatorPending: Bool {
    switch state {
    case .awaitingMotion, .awaitingGMotion:
      return true
    case .awaitingTextObject(let consumer, _):
      if case .operation = consumer { return true }
      return false
    case .awaitingFind(let pending):
      if case .operation = pending.consumer { return true }
      return false
    case .awaitingSearch(let pending):
      if case .operation = pending.consumer { return true }
      return false
    case .awaitingMark(.motion(_, let consumer)):
      if case .operation = consumer { return true }
      return false
    default:
      return false
    }
  }

  var count: Int {
    switch state {
    case .idle(let prefix), .awaitingRegister(let prefix), .awaitingG(let prefix),
      .awaitingWindowCommand(let prefix), .awaitingReplace(let prefix),
      .awaitingMacroRegister(let prefix),
      .awaitingMacroStart(let prefix):
      return prefix.count
    case .awaitingMotion(let pending), .awaitingGMotion(let pending):
      return pending.suffixCount > 0 ? pending.suffixCount : pending.prefixCount
    case .awaitingTextObject(let consumer, _): return consumer.count
    case .awaitingFind(let pending): return pending.consumer.count
    case .awaitingSearch(let pending): return pending.consumer.count
    case .awaitingMark(let pending):
      switch pending {
      case .set(let prefix), .jump(_, let prefix): return prefix.count
      case .motion(_, let consumer): return consumer.count
      }
    }
  }

  var selectedRegister: VimRegister {
    switch state {
    case .idle(let prefix), .awaitingRegister(let prefix), .awaitingG(let prefix),
      .awaitingWindowCommand(let prefix), .awaitingReplace(let prefix),
      .awaitingMacroRegister(let prefix),
      .awaitingMacroStart(let prefix):
      return prefix.register
    case .awaitingMotion(let pending), .awaitingGMotion(let pending): return pending.register
    case .awaitingTextObject(let consumer, _): return consumer.register
    case .awaitingFind(let pending): return pending.consumer.register
    case .awaitingSearch(let pending): return pending.consumer.register
    case .awaitingMark(let pending):
      switch pending {
      case .set(let prefix), .jump(_, let prefix): return prefix.register
      case .motion(_, let consumer): return consumer.register
      }
    }
  }

  var pendingOperator: VimPendingOperation? {
    switch state {
    case .awaitingMotion(let pending), .awaitingGMotion(let pending): return pending
    case .awaitingTextObject(let consumer, _):
      if case .operation(let pending) = consumer { return pending }
    case .awaitingFind(let value):
      if case .operation(let pending) = value.consumer { return pending }
    case .awaitingSearch(let value):
      if case .operation(let pending) = value.consumer { return pending }
    case .awaitingMark(.motion(_, let consumer)):
      if case .operation(let pending) = consumer { return pending }
    default:
      break
    }
    return nil
  }

  var expectedInput: VimExpectedInput {
    switch state {
    case .awaitingSearch: return .promptText
    case .awaitingFind: return .literalCharacter
    case .awaitingReplace: return .replacementCharacter
    case .awaitingRegister, .awaitingMacroRegister, .awaitingMacroStart: return .registerName
    case .awaitingMark: return .markName
    default: return .command
    }
  }

  var displayPrefix: String? {
    switch state {
    case .awaitingSearch(let search): return (search.forward ? "/" : "?") + search.query
    case .awaitingG, .awaitingGMotion: return "g"
    case .awaitingWindowCommand: return "^W"
    case .awaitingTextObject(_, let inner): return inner ? "i" : "a"
    case .awaitingMacroRegister: return "@"
    case .awaitingMacroStart: return "q"
    case .awaitingMark(let mark):
      switch mark {
      case .set: return "m"
      case .jump(let linewise, _), .motion(let linewise, _): return linewise ? "'" : "`"
      }
    default: return nil
    }
  }

  mutating func reset() {
    state = .idle(VimCommandPrefix())
  }

  mutating func consume(_ rawToken: String, mode: VimMode) throws -> VimParserStep {
    let token = rawToken.hasPrefix("<") ? rawToken.lowercased() : rawToken
    let lower = token.lowercased()

    if lower == "<esc>" || lower == "<c-[>" {
      if isAtCommandBoundary {
        return .command(.direct("<esc>", count: 1, register: .unnamed))
      }
      reset()
      return .cancelled
    }

    switch state {
    case .awaitingRegister(var prefix):
      guard let character = singleCharacter(token) else { throw VimError.invalidRegister }
      prefix.register = try Self.register(for: character)
      state = .idle(prefix)
      return .awaitingMoreInput

    case .awaitingSearch(var search):
      if lower == "<cr>" || lower == "<enter>" {
        let motion = VimMotionExpression.search(search.query, forward: search.forward)
        return emit(motion, to: search.consumer)
      }
      guard !token.hasPrefix("<") else { return .awaitingMoreInput }
      search.query.append(token)
      state = .awaitingSearch(search)
      return .awaitingMoreInput

    case .awaitingFind(let pending):
      guard let character = singleCharacter(token) else {
        throw VimError.unsupportedNotation(token)
      }
      let publicMotion: VimMotion =
        pending.forward
        ? (pending.till ? .tillForward(character) : .findForward(character))
        : (pending.till ? .tillBackward(character) : .findBackward(character))
      return emit(.standard(publicMotion), to: pending.consumer)

    case .awaitingReplace(let prefix):
      guard let character = singleCharacter(token) else {
        throw VimError.unsupportedNotation(token)
      }
      return complete(.replace(character, count: prefix.effectiveCount, register: prefix.register))

    case .awaitingMark(let pending):
      guard let character = singleCharacter(token) else {
        throw VimError.unsupportedNotation(token)
      }
      switch pending {
      case .set:
        return complete(.setMark(character))
      case .jump(let linewise, _):
        return complete(.jumpToMark(character, linewise: linewise))
      case .motion(let linewise, let consumer):
        return emit(.mark(character, linewise: linewise), to: consumer)
      }

    case .awaitingMacroRegister(let prefix):
      guard let character = singleCharacter(token) else {
        throw VimError.unsupportedNotation(token)
      }
      return complete(.playMacro(character, count: prefix.effectiveCount))

    case .awaitingMacroStart:
      guard let character = singleCharacter(token) else {
        throw VimError.unsupportedNotation(token)
      }
      return complete(.startMacro(character))

    case .awaitingTextObject(let consumer, let inner):
      guard let object = Self.textObject(for: token) else {
        reset()
        throw VimError.unsupportedNotation("text object \(token)")
      }
      switch consumer {
      case .visual, .operation:
        return emit(.textObject(object, inner: inner), to: consumer)
      case .normal:
        reset()
        throw VimError.unsupportedNotation("text object outside Visual/operator mode")
      }

    case .awaitingWindowCommand(let prefix):
      return consumeWindowCommand(token, prefix: prefix)

    case .awaitingG(let prefix):
      return try consumeG(token, prefix: prefix, mode: mode)

    case .awaitingGMotion(let pending):
      guard let motion = Self.gMotion(for: token, count: pending.effectiveCount) else {
        reset()
        throw VimError.unsupportedNotation("operator + g\(token)")
      }
      return complete(
        .operation(
          pending.value,
          motion: motion,
          count: pending.effectiveCount,
          register: pending.register,
          forcedKind: pending.forcedKind
        ))

    case .awaitingMotion(var pending):
      if let digit = countDigit(token, allowLeadingZero: pending.suffixCount > 0) {
        pending.appendCountDigit(digit)
        state = .awaitingMotion(pending)
        return .awaitingMoreInput
      }
      if pending.forcedKind == nil {
        switch token {
        case "v":
          pending.forcedKind = .characterwise
          state = .awaitingMotion(pending)
          return .awaitingMoreInput
        case "V":
          pending.forcedKind = .linewise
          state = .awaitingMotion(pending)
          return .awaitingMoreInput
        case "<c-v>":
          pending.forcedKind = .blockwise
          state = .awaitingMotion(pending)
          return .awaitingMoreInput
        default:
          break
        }
      }
      if token == "g" {
        state = .awaitingGMotion(pending)
        return .awaitingMoreInput
      }
      if token == "i" || token == "a" {
        state = .awaitingTextObject(.operation(pending), inner: token == "i")
        return .awaitingMoreInput
      }
      if ["f", "F", "t", "T"].contains(token) {
        state = .awaitingFind(
          VimPendingFind(
            forward: token == "f" || token == "t",
            till: token == "t" || token == "T",
            consumer: .operation(pending)
          ))
        return .awaitingMoreInput
      }
      if token == "'" || token == "`" {
        state = .awaitingMark(
          .motion(linewise: token == "'", consumer: .operation(pending)))
        return .awaitingMoreInput
      }
      if token == "/" || (token == "?" && pending.value != .rot13) {
        state = .awaitingSearch(
          VimPendingSearch(forward: token == "/", consumer: .operation(pending)))
        return .awaitingMoreInput
      }
      if token == Self.operatorToken(for: pending.value) {
        return complete(
          .operation(
            pending.value,
            motion: .currentOrFollowingLine,
            count: pending.effectiveCount,
            register: pending.register,
            forcedKind: nil
          ))
      }
      let motion: VimMotionExpression?
      if token == "%", pending.suffixCount > 0 {
        motion = .percentage(pending.effectiveCount)
      } else {
        motion = Self.motion(for: token)
      }
      guard let motion else {
        reset()
        throw VimError.incompleteCommand("operator + \(token)")
      }
      return complete(
        .operation(
          pending.value,
          motion: motion,
          count: pending.effectiveCount,
          register: pending.register,
          forcedKind: pending.forcedKind
        ))

    case .idle(var prefix):
      if token == "\"" {
        state = .awaitingRegister(prefix)
        return .awaitingMoreInput
      }
      if let digit = countDigit(token, allowLeadingZero: prefix.count > 0) {
        prefix.appendCountDigit(digit)
        state = .idle(prefix)
        return .awaitingMoreInput
      }
      if mode == .visualCharacter || mode == .visualLine {
        if token == "i" || token == "a" {
          state = .awaitingTextObject(.visual(prefix), inner: token == "i")
          return .awaitingMoreInput
        }
        let visualDirectTokens: Set<String> = [
          "d", "x", "D", "X", "c", "C", "S", "s", "y", ">", "<", "U", "u",
          "~", "p", "P", "I", "A", "o", "O", "v", "V", "<c-v>",
        ]
        if visualDirectTokens.contains(token) {
          return complete(
            .direct(token, count: prefix.effectiveCount, register: prefix.register))
        }
      }
      if let op = Self.operator(for: token) {
        state = .awaitingMotion(
          VimPendingOperation(
            value: op,
            prefixCount: prefix.effectiveCount,
            register: prefix.register
          ))
        return .awaitingMoreInput
      }
      switch token {
      case "<c-w>":
        state = .awaitingWindowCommand(prefix)
        return .awaitingMoreInput
      case "g":
        state = .awaitingG(prefix)
        return .awaitingMoreInput
      case "f", "F", "t", "T":
        state = .awaitingFind(
          VimPendingFind(
            forward: token == "f" || token == "t",
            till: token == "t" || token == "T",
            consumer: .normal(prefix)
          ))
        return .awaitingMoreInput
      case "/", "?":
        state = .awaitingSearch(
          VimPendingSearch(forward: token == "/", consumer: .normal(prefix)))
        return .awaitingMoreInput
      case "r":
        state = .awaitingReplace(prefix)
        return .awaitingMoreInput
      case "m":
        state = .awaitingMark(.set(prefix))
        return .awaitingMoreInput
      case "'", "`":
        state = .awaitingMark(.jump(linewise: token == "'", prefix: prefix))
        return .awaitingMoreInput
      case "@":
        state = .awaitingMacroRegister(prefix)
        return .awaitingMoreInput
      case "q":
        state = .awaitingMacroStart(prefix)
        return .awaitingMoreInput
      default:
        break
      }
      if token == "%", prefix.count > 0 {
        return complete(.motion(.percentage(prefix.effectiveCount), count: 1))
      }
      if let motion = Self.motion(for: token) {
        let resolved: VimMotionExpression
        if token == "G", prefix.count > 0 {
          resolved = .standard(.line(prefix.effectiveCount))
        } else {
          resolved = motion
        }
        return complete(.motion(resolved, count: prefix.effectiveCount))
      }
      return complete(
        .direct(token, count: prefix.effectiveCount, register: prefix.register))
    }
  }

  private mutating func consumeWindowCommand(
    _ token: String,
    prefix: VimCommandPrefix
  ) -> VimParserStep {
    let count = prefix.effectiveCount
    let request: VimHostRequest
    switch token {
    case "s", "S": request = .split(horizontal: true)
    case "v": request = .split(horizontal: false)
    case "h": request = .focusWindow(direction: .left, count: count)
    case "j": request = .focusWindow(direction: .down, count: count)
    case "k": request = .focusWindow(direction: .up, count: count)
    case "l": request = .focusWindow(direction: .right, count: count)
    case "w", "<c-w>": request = .cycleWindow(direction: .next, count: count)
    case "W": request = .cycleWindow(direction: .previous, count: count)
    case "p": request = .focusPreviousWindow
    case "q", "c": request = .closeWindow
    case "o": request = .closeOtherWindows
    case "n": request = .newWindow(horizontal: true)
    default:
      reset()
      return .cancelled
    }
    return complete(.action(.host(request), count: 1, register: prefix.register))
  }

  private mutating func consumeG(
    _ token: String,
    prefix: VimCommandPrefix,
    mode: VimMode
  ) throws -> VimParserStep {
    // Tabs are a host concern, but `gt`/`gT` are native Vim Normal-mode
    // commands. Emit host requests here instead of treating them as unknown
    // direct notation, so they also work with Calcite's shared Vim controller.
    switch token {
    case "t":
      return complete(.action(.host(.nextTab), count: 1, register: prefix.register))
    case "T":
      return complete(.action(.host(.previousTab), count: 1, register: prefix.register))
    default:
      break
    }
    if let op = Self.gOperator(for: token) {
      if mode == .visualCharacter || mode == .visualLine {
        return complete(.visualOperation(op, register: prefix.register))
      }
      state = .awaitingMotion(
        VimPendingOperation(
          value: op,
          prefixCount: prefix.effectiveCount,
          register: prefix.register
        ))
      return .awaitingMoreInput
    }
    guard let motion = Self.gMotion(for: token, count: prefix.effectiveCount) else {
      return complete(
        .direct("g\(token)", count: prefix.effectiveCount, register: prefix.register))
    }
    return complete(.motion(motion, count: prefix.effectiveCount))
  }

  private mutating func emit(
    _ motion: VimMotionExpression,
    to consumer: VimMotionConsumer
  ) -> VimParserStep {
    switch consumer {
    case .normal(let prefix), .visual(let prefix):
      return complete(.motion(motion, count: prefix.effectiveCount))
    case .operation(let pending):
      return complete(
        .operation(
          pending.value,
          motion: motion,
          count: pending.effectiveCount,
          register: pending.register,
          forcedKind: pending.forcedKind
        ))
    }
  }

  private mutating func complete(_ command: VimSemanticCommand) -> VimParserStep {
    reset()
    return .command(command)
  }

  static func appendingCountDigit(_ digit: Int, to count: Int) -> Int {
    let multiplied = count.multipliedReportingOverflow(by: 10)
    guard !multiplied.overflow else { return maximumCount }
    let added = multiplied.partialValue.addingReportingOverflow(digit)
    return added.overflow ? maximumCount : min(added.partialValue, maximumCount)
  }

  static func combinedCount(_ lhs: Int, _ rhs: Int) -> Int {
    let multiplied = max(1, lhs).multipliedReportingOverflow(by: max(1, rhs))
    return multiplied.overflow ? maximumCount : min(multiplied.partialValue, maximumCount)
  }

  private func countDigit(_ token: String, allowLeadingZero: Bool) -> Int? {
    guard token.count == 1, let value = Int(token) else { return nil }
    if value == 0, !allowLeadingZero { return nil }
    return value
  }

  private func singleCharacter(_ token: String) -> Character? {
    guard token.count == 1 else { return nil }
    return token.first
  }

  static func tokens(in notation: String) -> [String] {
    var values: [String] = []
    var index = notation.startIndex
    while index < notation.endIndex {
      if notation[index] == "<", let end = notation[index...].firstIndex(of: ">") {
        values.append(String(notation[index...end]))
        index = notation.index(after: end)
      } else {
        values.append(String(notation[index]))
        index = notation.index(after: index)
      }
    }
    return values
  }

  static func register(for character: Character) throws -> VimRegister {
    if character == "\"" { return .unnamed }
    if character == "_" { return .blackHole }
    if character == "-" { return .smallDelete }
    if character == "+" || character == "*" { return .clipboard }
    if character == "." || character == ":" || character == "/" {
      return .named(character)
    }
    if let digit = character.wholeNumberValue { return .numbered(digit) }
    if character.isLetter { return .named(character) }
    throw VimError.invalidRegister
  }

  static func operatorToken(for value: VimOperator) -> String {
    switch value {
    case .delete: return "d"
    case .change: return "c"
    case .yank: return "y"
    case .indent: return ">"
    case .outdent: return "<"
    case .uppercase: return "U"
    case .lowercase: return "u"
    case .swapCase: return "~"
    case .format: return "q"
    case .rot13: return "?"
    }
  }

  static func `operator`(for token: String) -> VimOperator? {
    switch token {
    case "d": return .delete
    case "c": return .change
    case "y": return .yank
    case ">": return .indent
    case "<": return .outdent
    default: return nil
    }
  }

  static func gOperator(for token: String) -> VimOperator? {
    switch token {
    case "U": return .uppercase
    case "u": return .lowercase
    case "~": return .swapCase
    case "q": return .format
    case "?": return .rot13
    default: return nil
    }
  }

  static func motion(for token: String) -> VimMotionExpression? {
    switch token {
    case "h": return .standard(.left)
    case "j": return .standard(.down)
    case "k": return .standard(.up)
    case "l": return .standard(.right)
    case "w": return .standard(.wordForward)
    case "b": return .standard(.wordBackward)
    case "e": return .standard(.wordEnd)
    case "W": return .wholeWordForward
    case "B": return .wholeWordBackward
    case "E": return .wholeWordEnd
    case "0": return .standard(.lineStart)
    case "^": return .standard(.firstNonBlank)
    case "$": return .standard(.lineEnd)
    case "+": return .adjacentLineDown
    case "-": return .adjacentLineUp
    case "_": return .currentOrFollowingLine
    case "|": return .column
    case "(": return .sentenceBackward
    case ")": return .sentenceForward
    case "{": return .paragraphBackward
    case "}": return .paragraphForward
    case "G": return .standard(.documentEnd)
    case "%": return .standard(.matchingPair)
    case ";": return .repeatFind(reverse: false)
    case ",": return .repeatFind(reverse: true)
    case "n": return .repeatSearch(reverse: false)
    case "N": return .repeatSearch(reverse: true)
    case "H": return .viewport(.top)
    case "M": return .viewport(.middle)
    case "L": return .viewport(.bottom)
    case "*": return .wordSearch(forward: true, wholeWord: true)
    case "#": return .wordSearch(forward: false, wholeWord: true)
    default: return nil
    }
  }

  static func gMotion(for token: String, count: Int) -> VimMotionExpression? {
    switch token {
    case "g": return .standard(count == 1 ? .documentStart : .line(count))
    case "e": return .previousWordEnd
    case "E": return .previousWholeWordEnd
    case "0": return .standard(.lineStart)
    case "^": return .standard(.firstNonBlank)
    case "$": return .standard(.lineEnd)
    case "_": return .lastNonBlank
    case "j": return .displayLineDown
    case "k": return .displayLineUp
    case "*": return .wordSearch(forward: true, wholeWord: false)
    case "#": return .wordSearch(forward: false, wholeWord: false)
    case "n": return .nextSearchMatch(reverse: false)
    case "N": return .nextSearchMatch(reverse: true)
    default: return nil
    }
  }

  static func textObject(for token: String) -> VimTextObject? {
    switch token {
    case "w": return .word
    case "W": return .WORD
    case "p": return .paragraph
    case "s": return .sentence
    case "\"", "'", "`": return token.first.map(VimTextObject.quotes)
    case "(", ")", "b": return .parentheses
    case "[", "]": return .brackets
    case "{", "}", "B": return .braces
    case "<", ">": return .angles
    case "t": return .tag
    default: return nil
    }
  }
}
