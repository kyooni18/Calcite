import EditorCore
import Foundation

public enum VimMode: String, Sendable, Codable, CaseIterable {
  case normal, insert, replace, visualCharacter, visualLine, commandLine, search
}

public enum VimRegister: Hashable, Sendable {
  case unnamed
  case named(Character)
  case numbered(Int)
  case smallDelete
  case blackHole
  case clipboard
}

public enum VimMotion: Hashable, Sendable {
  case left, right, up, down
  case lineStart, firstNonBlank, lineEnd
  case wordForward, wordBackward, wordEnd
  case documentStart, documentEnd
  case pageUp, pageDown, halfPageUp, halfPageDown
  case findForward(Character)
  case findBackward(Character)
  case tillForward(Character)
  case tillBackward(Character)
  case matchingPair
  case line(Int)
}

public enum VimTextObject: Hashable, Sendable {
  // swift-format-ignore: AlwaysUseLowerCamelCase
  case word, WORD, paragraph, sentence
  case quotes(Character)
  case parentheses, brackets, braces, angles
  case tag
}

public enum VimOperator: String, Hashable, Sendable, Codable, CaseIterable {
  case delete, change, yank, indent, outdent, uppercase, lowercase, swapCase, format, rot13
}

public enum VimHostRequest: Hashable, Sendable {
  case write, quit, writeAndQuit
  case openFile(String)
  case switchBuffer(Int)
  case split(horizontal: Bool)
  case closeWindow
  case nextTab, previousTab, newTab, closeTab
  case scroll(lines: Int)
  case definition, declaration, references, hover, rename, codeAction, format
  case completion
  case shell(String)
  case custom(String)
}

public enum VimAction: Hashable, Sendable {
  case move(VimMotion)
  case enterInsert, enterInsertAfterCursor, enterInsertAtLineStart, enterInsertAtLineEnd
  case enterReplace, escape
  case enterVisualCharacter, enterVisualLine, reselectVisual
  case insert(String)
  case replaceCharacter(Character)
  case insertNewline, openLineBelow, openLineAbove
  case deleteCharacter, deleteBeforeCursor, substituteCharacter, joinLines
  case operatorMotion(VimOperator, VimMotion)
  case operatorLine(VimOperator)
  case operatorTextObject(VimOperator, VimTextObject, inner: Bool)
  case operatorSelection(VimOperator)
  case undo, redo, repeatLastChange
  case pasteAfter, pasteBefore
  case setMark(Character)
  case jumpToMark(Character, linewise: Bool)
  case startMacro(Character)
  case stopMacro
  case playMacro(Character)
  case search(String, forward: Bool)
  case nextSearch, previousSearch
  case command(String)
  case host(VimHostRequest)
  case leader(String)
  case localLeader(String)
}

public enum VimInvocation: Sendable {
  case action(VimAction, count: Int = 1, register: VimRegister = .unnamed)
  case keys(String)
  case notation(String)
  case ex(String)
  case leader(String)
  case localLeader(String)
}

public struct VimSelection: Hashable, Sendable {
  public var lowerBound: Int
  public var upperBound: Int
  public init(_ lowerBound: Int, _ upperBound: Int) {
    self.lowerBound = min(lowerBound, upperBound)
    self.upperBound = max(lowerBound, upperBound)
  }
}

private enum VimUTF16BoundaryBias {
  case backward
  case forward
}

private func normalizedVimUTF16Offset(
  _ offset: Int,
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

public struct VimState: Hashable, Sendable {
  public var text: String
  public var cursor: Int
  public var mode: VimMode
  public var selection: VimSelection?
  public init(
    text: String = "", cursor: Int = 0, mode: VimMode = .normal, selection: VimSelection? = nil
  ) {
    self.text = text
    self.cursor = normalizedVimUTF16Offset(cursor, in: text)
    self.mode = mode
    self.selection = selection
  }
}

public struct VimExecutionResult: Sendable {
  public var state: VimState
  public var hostRequests: [VimHostRequest]
  public var didChangeText: Bool
  public init(state: VimState, hostRequests: [VimHostRequest] = [], didChangeText: Bool = false) {
    self.state = state
    self.hostRequests = hostRequests
    self.didChangeText = didChangeText
  }
}

public enum VimError: Error, Equatable, Sendable {
  case invalidCount, invalidRegister
  case unsupportedNotation(String)
  case incompleteCommand(String)
  case macroRecursionLimit
}

public final class VimEngine: @unchecked Sendable {
  public private(set) var state: VimState
  public var leader: String
  public var localLeader: String
  public var tabWidth: Int

  private var registers: [VimRegister: String] = [:]
  private var marks: [Character: Int] = [:]
  private var macros: [Character: [VimAction]] = [:]
  private var recording: Character?
  private var recordingActions: [VimAction] = []
  private var leaderMappings: [String: VimInvocation] = [:]
  private var localLeaderMappings: [String: VimInvocation] = [:]
  private var undoStack: [VimState] = []
  private var redoStack: [VimState] = []
  private var lastChange: VimAction?
  private var lastSearch: (String, Bool)?

  public init(
    text: String = "", cursor: Int = 0, leader: String = "\\", localLeader: String = "\\",
    tabWidth: Int = 2
  ) {
    self.state = VimState(text: text, cursor: cursor)
    self.leader = leader
    self.localLeader = localLeader
    self.tabWidth = max(1, tabWidth)
  }

  public func synchronize(text: String, cursor: Int? = nil) {
    state.text = text
    state.cursor = clamp(cursor ?? state.cursor)
    state.selection = nil
  }

  public func register(_ register: VimRegister) -> String { registers[register] ?? "" }
  public func setRegister(_ register: VimRegister, text: String) { registers[register] = text }
  public func macro(_ name: Character) -> [VimAction] { macros[name] ?? [] }
  public func setMacro(_ name: Character, actions: [VimAction]) { macros[name] = actions }
  public var isRecordingMacro: Bool { recording != nil }

  public func mapLeader(_ sequence: String, to invocation: VimInvocation) {
    leaderMappings[sequence] = invocation
  }
  public func mapLocalLeader(_ sequence: String, to invocation: VimInvocation) {
    localLeaderMappings[sequence] = invocation
  }
  public func unmapLeader(_ sequence: String) { leaderMappings.removeValue(forKey: sequence) }
  public func unmapLocalLeader(_ sequence: String) {
    localLeaderMappings.removeValue(forKey: sequence)
  }
  public var leaderSequences: [String] { leaderMappings.keys.sorted() }
  public var localLeaderSequences: [String] { localLeaderMappings.keys.sorted() }

  @discardableResult
  public func execute(_ invocation: VimInvocation) throws -> VimExecutionResult {
    switch invocation {
    case .action(let action, let count, let register):
      return try execute(action, count: count, register: register)
    case .keys(let keys), .notation(let keys): return try executeNotation(keys)
    case .ex(let command): return try execute(.command(command))
    case .leader(let sequence):
      guard let mapped = leaderMappings[sequence] else { return VimExecutionResult(state: state) }
      return try execute(mapped)
    case .localLeader(let sequence):
      guard let mapped = localLeaderMappings[sequence] else {
        return VimExecutionResult(state: state)
      }
      return try execute(mapped)
    }
  }

  @discardableResult
  public func execute(_ action: VimAction, count: Int = 1, register: VimRegister = .unnamed) throws
    -> VimExecutionResult
  {
    guard count > 0 else { throw VimError.invalidCount }
    let before = state
    var host: [VimHostRequest] = []
    if recording != nil, action != .stopMacro { recordingActions.append(action) }

    switch action {
    case .move(let motion): move(motion, count: count)
    case .enterInsert: state.mode = .insert
    case .enterInsertAfterCursor:
      state.cursor = nextCharacterBoundary(from: state.cursor)
      state.mode = .insert
    case .enterInsertAtLineStart:
      state.cursor = lineStart(at: state.cursor)
      state.mode = .insert
    case .enterInsertAtLineEnd:
      state.cursor = lineEnd(at: state.cursor)
      state.mode = .insert
    case .enterReplace: state.mode = .replace
    case .escape:
      state.mode = .normal
      state.selection = nil
    case .enterVisualCharacter:
      state.mode = .visualCharacter
      state.selection = VimSelection(state.cursor, state.cursor)
    case .enterVisualLine:
      state.mode = .visualLine
      state.selection = VimSelection(
        lineStart(at: state.cursor), lineEndIncludingNewline(at: state.cursor))
    case .reselectVisual: break
    case .insert(let string): mutate(action) { for _ in 0..<count { insert(string) } }
    case .replaceCharacter(let character):
      mutate(action) { replaceCharacter(character, count: count) }
    case .insertNewline: mutate(action) { insert(String(repeating: "\n", count: count)) }
    case .openLineBelow:
      mutate(action) {
        state.cursor = lineEnd(at: state.cursor)
        insert("\n")
        state.mode = .insert
      }
    case .openLineAbove:
      mutate(action) {
        state.cursor = lineStart(at: state.cursor)
        insert("\n")
        state.cursor = previousCharacterBoundary(from: state.cursor)
        state.mode = .insert
      }
    case .deleteCharacter:
      mutate(action) {
        delete(
          range: state.cursor..<advanceCharacters(from: state.cursor, count: count),
          register: register,
          small: true
        )
      }
    case .deleteBeforeCursor:
      mutate(action) {
        let start = advanceCharacters(from: state.cursor, count: -count)
        delete(range: start..<state.cursor, register: register, small: true)
        state.cursor = start
      }
    case .substituteCharacter:
      mutate(action) {
        delete(
          range: state.cursor..<advanceCharacters(from: state.cursor, count: count),
          register: register,
          small: true
        )
        state.mode = .insert
      }
    case .joinLines: mutate(action) { for _ in 0..<count { joinLine() } }
    case .operatorMotion(let op, let motion):
      mutate(action) { apply(op, range: motionRange(motion, count: count), register: register) }
    case .operatorLine(let op):
      mutate(action) {
        let lower = lineStart(at: state.cursor)
        var upper = lower
        for _ in 0..<count { upper = lineEndIncludingNewline(at: upper) }
        apply(op, range: lower..<max(lower, upper), register: register)
      }
    case .operatorTextObject(let op, let object, let inner):
      mutate(action) { apply(op, range: textObjectRange(object, inner: inner), register: register) }
    case .operatorSelection(let op):
      mutate(action) {
        guard let range = visualRange() else { return }
        apply(op, range: range, register: register)
        if op != .change { state.mode = .normal }
        state.selection = nil
      }
    case .undo:
      if let previous = undoStack.popLast() {
        redoStack.append(state)
        state = previous
      }
    case .redo:
      if let next = redoStack.popLast() {
        undoStack.append(state)
        state = next
      }
    case .repeatLastChange:
      if let lastChange { return try execute(lastChange, count: count, register: register) }
    case .pasteAfter:
      mutate(action) {
        paste(registers[register] ?? registers[.unnamed] ?? "", after: true, count: count)
      }
    case .pasteBefore:
      mutate(action) {
        paste(registers[register] ?? registers[.unnamed] ?? "", after: false, count: count)
      }
    case .setMark(let name): marks[name] = state.cursor
    case .jumpToMark(let name, let linewise):
      if let position = marks[name] { state.cursor = linewise ? lineStart(at: position) : position }
    case .startMacro(let name):
      recording = name
      recordingActions = []
    case .stopMacro:
      if let name = recording { macros[name] = recordingActions }
      recording = nil
      recordingActions = []
    case .playMacro(let name):
      for _ in 0..<count { for item in macros[name] ?? [] { _ = try execute(item) } }
    case .search(let query, let forward):
      lastSearch = (query, forward)
      search(query, forward: forward)
    case .nextSearch:
      if let (query, forward) = lastSearch {
        for _ in 0..<count { search(query, forward: forward) }
      }
    case .previousSearch:
      if let (query, forward) = lastSearch {
        for _ in 0..<count { search(query, forward: !forward) }
      }
    case .command(let command): host.append(contentsOf: try executeEx(command))
    case .host(let request): host.append(request)
    case .leader(let sequence): return try execute(.leader(sequence))
    case .localLeader(let sequence): return try execute(.localLeader(sequence))
    }

    return VimExecutionResult(
      state: state, hostRequests: host, didChangeText: before.text != state.text)
  }

  @discardableResult
  public func executeNotation(_ notation: String) throws -> VimExecutionResult {
    var aggregate: [VimHostRequest] = []
    var count = 0
    var pendingOperator: (value: VimOperator, count: Int)?
    var pendingTextObjectInner: Bool?
    var pendingG = false
    var pendingFind: (forward: Bool, till: Bool, count: Int)?
    var pendingReplace = false
    var pendingMark = false
    var pendingJump: Bool?
    var pendingMacro = false
    var pendingMacroStart = false
    var index = notation.startIndex

    while index < notation.endIndex {
      let token: String
      if notation[index] == "<", let end = notation[index...].firstIndex(of: ">") {
        token = String(notation[index...end])
        index = notation.index(after: end)
      } else {
        token = String(notation[index])
        index = notation.index(after: index)
      }

      if state.mode == .insert || state.mode == .replace {
        let action: VimAction
        switch token.lowercased() {
        case "<esc>": action = .escape
        case "<cr>": action = .insertNewline
        case "<bs>": action = .deleteBeforeCursor
        default: action = .insert(token)
        }
        aggregate += try execute(action).hostRequests
        continue
      }

      if let activeFind = pendingFind {
        guard let character = token.first else { throw VimError.unsupportedNotation(token) }
        aggregate += try execute(.move(
          activeFind.forward
            ? (activeFind.till ? .tillForward(character) : .findForward(character))
            : (activeFind.till ? .tillBackward(character) : .findBackward(character))
        ), count: activeFind.count).hostRequests
        pendingFind = nil
        continue
      }

      if pendingReplace {
        guard let character = token.first else { throw VimError.unsupportedNotation(token) }
        aggregate += try execute(.replaceCharacter(character), count: max(1, count)).hostRequests
        pendingReplace = false
        count = 0
        continue
      }

      if pendingMark {
        guard let character = token.first else { throw VimError.unsupportedNotation(token) }
        aggregate += try execute(.setMark(character)).hostRequests
        pendingMark = false
        continue
      }

      if let linewise = pendingJump {
        guard let character = token.first else { throw VimError.unsupportedNotation(token) }
        aggregate += try execute(.jumpToMark(character, linewise: linewise)).hostRequests
        pendingJump = nil
        continue
      }

      if pendingMacro {
        guard let character = token.first else { throw VimError.unsupportedNotation(token) }
        aggregate += try execute(.playMacro(character), count: max(1, count)).hostRequests
        pendingMacro = false
        count = 0
        continue
      }

      if pendingMacroStart {
        guard let character = token.first else { throw VimError.unsupportedNotation(token) }
        aggregate += try execute(.startMacro(character)).hostRequests
        pendingMacroStart = false
        continue
      }

      if state.mode == .visualCharacter || state.mode == .visualLine {
        let visualOperator: VimOperator?
        switch token {
        case "d", "x": visualOperator = .delete
        case "c": visualOperator = .change
        case "y": visualOperator = .yank
        case ">": visualOperator = .indent
        case "<": visualOperator = .outdent
        case "U": visualOperator = .uppercase
        case "u": visualOperator = .lowercase
        case "~": visualOperator = .swapCase
        default: visualOperator = nil
        }
        if let visualOperator {
          aggregate += try execute(.operatorSelection(visualOperator)).hostRequests
          continue
        }
      }

      if token.count == 1, let digit = Int(token), !(token == "0" && count == 0) {
        count = count * 10 + digit
        continue
      }

      if pendingG {
        pendingG = false
        let effectiveCount = max(1, count)
        count = 0
        let action: VimAction?
        switch token {
        case "g": action = .move(.documentStart)
        case "d": action = .host(.definition)
        case "D": action = .host(.declaration)
        case "r": action = .host(.references)
        default: action = nil
        }
        guard let action else { throw VimError.unsupportedNotation("g\(token)") }
        aggregate += try execute(action, count: effectiveCount).hostRequests
        continue
      }

      if let pending = pendingOperator {
        if pendingTextObjectInner == nil, token == "i" || token == "a" {
          pendingTextObjectInner = token == "i"
          continue
        }

        let suffixCount = max(1, count)
        let effectiveCount = pending.count * suffixCount
        count = 0
        pendingOperator = nil
        let action: VimAction

        if let inner = pendingTextObjectInner {
          pendingTextObjectInner = nil
          guard let object = Self.textObject(for: token) else {
            throw VimError.unsupportedNotation("text object \(token)")
          }
          action = .operatorTextObject(pending.value, object, inner: inner)
        } else if token == Self.operatorToken(for: pending.value) {
          action = .operatorLine(pending.value)
        } else if let motion = Self.motion(for: token) {
          action = .operatorMotion(pending.value, motion)
        } else {
          throw VimError.incompleteCommand("operator + \(token)")
        }
        aggregate += try execute(action, count: effectiveCount).hostRequests
        continue
      }

      let effectiveCount = max(1, count)
      count = 0
      let action: VimAction?
      switch token {
      case "h": action = .move(.left)
      case "j": action = .move(.down)
      case "k": action = .move(.up)
      case "l": action = .move(.right)
      case "w": action = .move(.wordForward)
      case "b": action = .move(.wordBackward)
      case "e": action = .move(.wordEnd)
      case "0": action = .move(.lineStart)
      case "^": action = .move(.firstNonBlank)
      case "$": action = .move(.lineEnd)
      case "G": action = .move(.documentEnd)
      case "%": action = .move(.matchingPair)
      case "<c-b>": action = .move(.pageUp)
      case "<c-f>": action = .move(.pageDown)
      case "<c-u>": action = .move(.halfPageUp)
      case "<c-d>": action = .move(.halfPageDown)
      case "f":
        pendingFind = (forward: true, till: false, count: effectiveCount)
        action = nil
      case "F":
        pendingFind = (forward: false, till: false, count: effectiveCount)
        action = nil
      case "t":
        pendingFind = (forward: true, till: true, count: effectiveCount)
        action = nil
      case "T":
        pendingFind = (forward: false, till: true, count: effectiveCount)
        action = nil
      case "r":
        pendingReplace = true
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
      case "x": action = .deleteCharacter
      case "D": action = .operatorMotion(.delete, .lineEnd)
      case "C": action = .operatorMotion(.change, .lineEnd)
      case "J": action = .joinLines
      case "u": action = .undo
      case "<c-r>": action = .redo
      case ".": action = .repeatLastChange
      case "p": action = .pasteAfter
      case "P": action = .pasteBefore
      case "n": action = .nextSearch
      case "N": action = .previousSearch
      case "K": action = .host(.hover)
      case "<c-]>": action = .host(.definition)
      case "m":
        pendingMark = true
        action = nil
      case "'":
        pendingJump = true
        action = nil
      case "`":
        pendingJump = false
        action = nil
      case "@":
        pendingMacro = true
        action = nil
      case "q":
        if isRecordingMacro { action = .stopMacro }
        else { pendingMacroStart = true; action = nil }
      case "g":
        pendingG = true
        action = nil
      case "d":
        pendingOperator = (.delete, effectiveCount)
        action = nil
      case "c":
        pendingOperator = (.change, effectiveCount)
        action = nil
      case "y":
        pendingOperator = (.yank, effectiveCount)
        action = nil
      case ">":
        pendingOperator = (.indent, effectiveCount)
        action = nil
      case "<":
        pendingOperator = (.outdent, effectiveCount)
        action = nil
      case "<esc>": action = .escape
      default:
        if token == leader { return try execute(.leader(String(notation[index...]))) }
        action = nil
      }
      if let action { aggregate += try execute(action, count: effectiveCount).hostRequests }
    }

    if pendingG || pendingOperator != nil || pendingTextObjectInner != nil || pendingFind != nil
      || pendingReplace || pendingMark || pendingJump != nil || pendingMacro
      || pendingMacroStart
    {
      throw VimError.incompleteCommand(notation)
    }
    return VimExecutionResult(state: state, hostRequests: aggregate)
  }

  private static func operatorToken(for value: VimOperator) -> String {
    switch value {
    case .delete: return "d"
    case .change: return "c"
    case .yank: return "y"
    case .indent: return ">"
    case .outdent: return "<"
    default: return ""
    }
  }

  private static func motion(for token: String) -> VimMotion? {
    switch token {
    case "h": return .left
    case "j": return .down
    case "k": return .up
    case "l": return .right
    case "w": return .wordForward
    case "b": return .wordBackward
    case "e": return .wordEnd
    case "0": return .lineStart
    case "^": return .firstNonBlank
    case "$": return .lineEnd
    case "G": return .documentEnd
    case "%": return .matchingPair
    default: return nil
    }
  }

  private static func textObject(for token: String) -> VimTextObject? {
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

  private func mutate(_ action: VimAction, _ body: () -> Void) {
    undoStack.append(state)
    redoStack.removeAll()
    body()
    lastChange = action
  }

  private func insert(_ string: String) {
    let idx = stringIndex(state.cursor)
    if state.mode == .replace, state.cursor < state.text.utf16.count {
      let endOffset = advanceCharacters(from: state.cursor, count: max(1, string.count))
      let end = stringIndex(endOffset)
      state.text.replaceSubrange(idx..<end, with: string)
    } else {
      state.text.insert(contentsOf: string, at: idx)
    }
    state.cursor = clamp(state.cursor + string.utf16.count)
  }

  private func replaceCharacter(_ character: Character, count: Int) {
    let start = state.cursor
    let end = advanceCharacters(from: start, count: count)
    let a = stringIndex(start)
    let b = stringIndex(end)
    state.text.replaceSubrange(
      a..<b,
      with: String(repeating: String(character), count: max(1, count))
    )
  }

  private func delete(range: Range<Int>, register: VimRegister, small: Bool) {
    let r = normalized(range)
    guard !r.isEmpty else { return }
    let a = stringIndex(r.lowerBound)
    let b = stringIndex(r.upperBound)
    let removed = String(state.text[a..<b])
    if register != .blackHole {
      registers[register] = removed
      registers[.unnamed] = removed
      registers[small ? .smallDelete : .numbered(1)] = removed
    }
    state.text.removeSubrange(a..<b)
    state.cursor = clamp(r.lowerBound)
  }

  private func paste(_ string: String, after: Bool, count: Int) {
    guard !string.isEmpty else { return }
    if after { state.cursor = nextCharacterBoundary(from: state.cursor) }
    insert(String(repeating: string, count: count))
    state.mode = .normal
  }

  private func apply(_ op: VimOperator, range: Range<Int>, register: VimRegister) {
    let r = normalized(range)
    switch op {
    case .delete:
      delete(range: r, register: register, small: !containsNewline(r))
      state.mode = .normal
    case .change:
      delete(range: r, register: register, small: !containsNewline(r))
      state.mode = .insert
    case .yank:
      let a = stringIndex(r.lowerBound)
      let b = stringIndex(r.upperBound)
      let value = String(state.text[a..<b])
      registers[register] = value
      registers[.unnamed] = value
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
        new = String(
          old.map {
            $0.isUppercase
              ? Character(String($0).lowercased())
              : Character(String($0).uppercased())
          })
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
      state.text.replaceSubrange(a..<b, with: new)
    case .indent:
      adjustIndent(in: r, delta: 1)
    case .outdent:
      adjustIndent(in: r, delta: -1)
    case .format: break
    }
  }

  private func adjustIndent(in range: Range<Int>, delta: Int) {
    let source = state.text as NSString
    var starts: [Int] = []
    var location = lineStart(at: range.lowerBound)
    let upper = max(location, range.upperBound)
    while location <= upper, location <= source.length {
      starts.append(location)
      let line = source.lineRange(for: NSRange(location: min(location, source.length), length: 0))
      let next = NSMaxRange(line)
      if next <= location || next > upper { break }
      location = next
    }

    let originalCursor = state.cursor
    for start in starts.reversed() {
      if delta > 0 {
        let index = stringIndex(start)
        state.text.insert(contentsOf: String(repeating: " ", count: tabWidth), at: index)
        if start <= state.cursor { state.cursor += tabWidth }
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
        let lower = stringIndex(start)
        let upperIndex = stringIndex(start + removal)
        state.text.removeSubrange(lower..<upperIndex)
        if start < state.cursor { state.cursor = max(start, state.cursor - removal) }
      }
    }
    state.cursor = clamp(state.cursor)
    if starts.isEmpty { state.cursor = originalCursor }
  }

  private func move(_ motion: VimMotion, count: Int) {
    switch motion {
    case .left: state.cursor = advanceCharacters(from: state.cursor, count: -count)
    case .right: state.cursor = advanceCharacters(from: state.cursor, count: count)
    case .lineStart: state.cursor = lineStart(at: state.cursor)
    case .firstNonBlank: state.cursor = firstNonBlank(at: state.cursor)
    case .lineEnd: state.cursor = lineEnd(at: state.cursor)
    case .documentStart: state.cursor = 0
    case .documentEnd:
      state.cursor = previousCharacterBoundary(from: state.text.utf16.count)
    case .up: for _ in 0..<count { verticalMove(-1) }
    case .down: for _ in 0..<count { verticalMove(1) }
    case .wordForward: for _ in 0..<count { state.cursor = nextWord(from: state.cursor) }
    case .wordBackward: for _ in 0..<count { state.cursor = previousWord(from: state.cursor) }
    case .wordEnd: for _ in 0..<count { state.cursor = wordEnd(from: state.cursor) }
    case .findForward(let c): find(c, forward: true, till: false, count: count)
    case .findBackward(let c): find(c, forward: false, till: false, count: count)
    case .tillForward(let c): find(c, forward: true, till: true, count: count)
    case .tillBackward(let c): find(c, forward: false, till: true, count: count)
    case .pageUp, .halfPageUp: for _ in 0..<(motion == .pageUp ? 20 : 10) { verticalMove(-1) }
    case .pageDown, .halfPageDown: for _ in 0..<(motion == .pageDown ? 20 : 10) { verticalMove(1) }
    case .matchingPair: matchingPair()
    case .line(let number): state.cursor = lineOffset(max(1, number))
    }
    updateVisualSelection()
  }

  private func motionRange(_ motion: VimMotion, count: Int) -> Range<Int> {
    let start = state.cursor
    move(motion, count: count)
    let end = state.cursor
    let upper: Int
    switch motion {
    case .wordForward, .wordBackward, .up, .down, .lineStart, .firstNonBlank,
      .documentStart, .line:
      upper = max(start, end)
    default:
      upper = nextCharacterBoundary(from: max(start, end))
    }
    return min(start, end)..<upper
  }
  private func textObjectRange(_ object: VimTextObject, inner: Bool) -> Range<Int> {
    switch object {
    case .word, .WORD:
      let lower = previousWord(from: state.cursor)
      return lower..<max(lower, nextCharacterBoundary(from: wordEnd(from: state.cursor)))
    case .paragraph, .sentence:
      return lineStart(at: state.cursor)..<lineEndIncludingNewline(at: state.cursor)
    case .quotes(let q): return enclosing(open: q, close: q, inner: inner)
    case .parentheses: return enclosing(open: "(", close: ")", inner: inner)
    case .brackets: return enclosing(open: "[", close: "]", inner: inner)
    case .braces: return enclosing(open: "{", close: "}", inner: inner)
    case .angles, .tag: return enclosing(open: "<", close: ">", inner: inner)
    }
  }

  private func executeEx(_ raw: String) throws -> [VimHostRequest] {
    let command = raw.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
    if command == "w" { return [.write] }
    if command == "q" { return [.quit] }
    if command == "q!" { return [.custom("force-quit")] }
    if command == "wq" || command == "x" { return [.writeAndQuit] }
    if command == "wa" || command == "wall" { return [.custom("save-all")] }
    if command == "bn" || command == "bnext" || command == "tabnext" { return [.nextTab] }
    if command == "bp" || command == "bprevious" || command == "tabprevious" {
      return [.previousTab]
    }
    if command == "format" { return [.format] }
    if ["build", "make", "run", "test", "check", "debug", "terminal", "problems"]
      .contains(command)
    {
      return [.custom(command == "make" ? "build" : command)]
    }
    if command == "noh" || command == "nohlsearch" { return [] }
    if command.hasPrefix("!") { return [.shell(String(command.dropFirst()))] }
    if command.hasPrefix("e ") { return [.openFile(String(command.dropFirst(2)))] }
    if command == "split" || command == "sp" { return [.split(horizontal: true)] }
    if command == "vsplit" || command == "vs" { return [.split(horizontal: false)] }
    if command == "tabnew" { return [.newTab] }
    if command == "tabclose" { return [.closeTab] }
    if command.hasPrefix("s/") {
      let parts = command.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count >= 3 else { throw VimError.incompleteCommand(raw) }
      let old = String(parts[1])
      let new = String(parts[2])
      mutate(.command(raw)) {
        state.text = state.text.replacingOccurrences(of: old, with: new)
        state.cursor = clamp(state.cursor)
      }
      return []
    }
    return [.custom(command)]
  }

  private func search(_ query: String, forward: Bool) {
    guard !query.isEmpty else { return }
    let ns = state.text as NSString
    if forward {
      let start = min(ns.length, state.cursor + 1)
      var result = ns.range(
        of: query, options: [], range: NSRange(location: start, length: ns.length - start))
      if result.location == NSNotFound, start > 0 {
        result = ns.range(of: query, options: [], range: NSRange(location: 0, length: start))
      }
      if result.location != NSNotFound { state.cursor = result.location }
    } else {
      let length = max(0, state.cursor)
      var result = ns.range(
        of: query, options: .backwards, range: NSRange(location: 0, length: length))
      if result.location == NSNotFound, length < ns.length {
        result = ns.range(
          of: query,
          options: .backwards,
          range: NSRange(location: length, length: ns.length - length)
        )
      }
      if result.location != NSNotFound { state.cursor = result.location }
    }
  }

  private func joinLine() {
    let end = lineEnd(at: state.cursor)
    guard end < state.text.utf16.count else { return }
    var next = nextCharacterBoundary(from: end)
    while next < state.text.utf16.count, isWhitespace(at: next) {
      next = nextCharacterBoundary(from: next)
    }
    let a = stringIndex(end)
    let b = stringIndex(next)
    state.text.replaceSubrange(a..<b, with: " ")
    state.cursor = end
  }
  private func updateVisualSelection() {
    if state.mode == .visualCharacter, let selection = state.selection {
      state.selection = VimSelection(selection.lowerBound, state.cursor)
    }
    if state.mode == .visualLine {
      state.selection = VimSelection(
        lineStart(at: state.selection?.lowerBound ?? state.cursor),
        lineEndIncludingNewline(at: state.cursor))
    }
  }
  private func visualRange() -> Range<Int>? {
    guard let selection = state.selection else { return nil }
    let lower = normalizedVimUTF16Offset(selection.lowerBound, in: state.text)
    let rawUpper = normalizedVimUTF16Offset(
      selection.upperBound, in: state.text, bias: .forward)
    let upper = state.mode == .visualLine
      ? rawUpper
      : nextCharacterBoundary(from: rawUpper)
    return lower..<max(lower, upper)
  }
  private func verticalMove(_ delta: Int) {
    let start = lineStart(at: state.cursor)
    let column = state.cursor - start
    let targetStart = delta < 0 ? previousLineStart(start) : nextLineStart(start)
    state.cursor = min(lineEnd(at: targetStart), targetStart + column)
  }
  private func previousLineStart(_ start: Int) -> Int {
    guard start > 0 else { return 0 }
    return lineStart(at: start - 1)
  }
  private func nextLineStart(_ start: Int) -> Int {
    let end = lineEnd(at: start)
    return end < state.text.utf16.count ? end + 1 : start
  }
  private func lineStart(at offset: Int) -> Int {
    let ns = state.text as NSString
    let safe = clamp(offset)
    let r = ns.lineRange(for: NSRange(location: safe, length: 0))
    return r.location
  }
  private func lineEnd(at offset: Int) -> Int {
    let ns = state.text as NSString
    let safe = clamp(offset)
    let r = ns.lineRange(for: NSRange(location: safe, length: 0))
    return max(
      r.location,
      r.location + r.length
        - ((r.length > 0 && ns.character(at: r.location + r.length - 1) == 10) ? 1 : 0))
  }
  private func lineEndIncludingNewline(at offset: Int) -> Int {
    let ns = state.text as NSString
    let r = ns.lineRange(for: NSRange(location: clamp(offset), length: 0))
    return r.location + r.length
  }
  private func firstNonBlank(at offset: Int) -> Int {
    var current = lineStart(at: offset)
    let end = lineEnd(at: offset)
    while current < end, isWhitespace(at: current) {
      current = nextCharacterBoundary(from: current)
    }
    return current
  }
  private func lineOffset(_ number: Int) -> Int {
    let ns = state.text as NSString
    var pos = 0
    for _ in 1..<number {
      let r = ns.lineRange(for: NSRange(location: pos, length: 0))
      pos = min(ns.length, r.location + r.length)
    }
    return pos
  }
  private func nextWord(from offset: Int) -> Int {
    var current = normalizedVimUTF16Offset(offset, in: state.text, bias: .forward)
    if current < state.text.utf16.count, isWord(at: current) {
      while current < state.text.utf16.count, isWord(at: current) {
        current = nextCharacterBoundary(from: current)
      }
    }
    while current < state.text.utf16.count, !isWord(at: current) {
      current = nextCharacterBoundary(from: current)
    }
    return current
  }

  private func previousWord(from offset: Int) -> Int {
    var current = previousCharacterBoundary(from: offset)
    while current > 0, !isWord(at: current) {
      current = previousCharacterBoundary(from: current)
    }
    while current > 0 {
      let previous = previousCharacterBoundary(from: current)
      guard isWord(at: previous) else { break }
      current = previous
    }
    return current
  }

  private func wordEnd(from offset: Int) -> Int {
    var current = normalizedVimUTF16Offset(offset, in: state.text, bias: .forward)
    while current < state.text.utf16.count, !isWord(at: current) {
      current = nextCharacterBoundary(from: current)
    }
    guard current < state.text.utf16.count else { return current }
    while true {
      let next = nextCharacterBoundary(from: current)
      guard next < state.text.utf16.count, isWord(at: next) else { return current }
      current = next
    }
  }

  private func isWord(at offset: Int) -> Bool {
    guard let character = character(at: offset) else { return false }
    let wordSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    return character.unicodeScalars.contains { wordSet.contains($0) }
  }

  private func isWhitespace(at offset: Int) -> Bool {
    guard let character = character(at: offset) else { return false }
    return character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
  }
  private func find(_ character: Character, forward: Bool, till: Bool, count: Int) {
    let ns = state.text as NSString
    var current = state.cursor
    for _ in 0..<count {
      let range =
        forward
        ? NSRange(location: min(ns.length, current + 1), length: max(0, ns.length - current - 1))
        : NSRange(location: 0, length: max(0, current))
      let r = ns.range(of: String(character), options: forward ? [] : .backwards, range: range)
      if r.location == NSNotFound { return }
      current = r.location
    }
    state.cursor = clamp(current + (till ? (forward ? -1 : 1) : 0))
  }
  private func matchingPair() {
    let pairs: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
    let ns = state.text as NSString
    guard state.cursor < ns.length else { return }
    let c = ns.character(at: state.cursor)
    if let close = pairs[c] {
      var depth = 0
      for i in state.cursor..<ns.length {
        let x = ns.character(at: i)
        if x == c { depth += 1 }
        if x == close {
          depth -= 1
          if depth == 0 {
            state.cursor = i
            return
          }
        }
      }
    } else if let open = pairs.first(where: { $0.value == c })?.key {
      var depth = 0
      for i in stride(from: state.cursor, through: 0, by: -1) {
        let x = ns.character(at: i)
        if x == c { depth += 1 }
        if x == open {
          depth -= 1
          if depth == 0 {
            state.cursor = i
            return
          }
        }
      }
    }
  }
  private func enclosing(open: Character, close: Character, inner: Bool) -> Range<Int> {
    let ns = state.text as NSString
    let openText = String(open)
    let closeText = String(close)
    let left = ns.range(
      of: openText,
      options: .backwards,
      range: NSRange(location: 0, length: min(ns.length, state.cursor + openText.utf16.count))
    )
    let rightStart = min(ns.length, state.cursor)
    let right = ns.range(
      of: closeText,
      options: [],
      range: NSRange(location: rightStart, length: ns.length - rightStart)
    )
    guard left.location != NSNotFound, right.location != NSNotFound,
      left.location <= right.location
    else {
      return state.cursor..<state.cursor
    }
    let lower = left.location + (inner ? openText.utf16.count : 0)
    let upper = right.location + (inner ? 0 : closeText.utf16.count)
    return normalized(lower..<upper)
  }

  private func normalized(_ range: Range<Int>) -> Range<Int> {
    let lower = normalizedVimUTF16Offset(range.lowerBound, in: state.text, bias: .backward)
    let upper = normalizedVimUTF16Offset(range.upperBound, in: state.text, bias: .forward)
    return min(lower, upper)..<max(lower, upper)
  }
  private func containsNewline(_ range: Range<Int>) -> Bool {
    let a = stringIndex(range.lowerBound)
    let b = stringIndex(range.upperBound)
    return state.text[a..<b].contains("\n")
  }
  private func character(at offset: Int) -> Character? {
    let startOffset = normalizedVimUTF16Offset(offset, in: state.text, bias: .backward)
    guard startOffset < state.text.utf16.count else { return nil }
    let endOffset = nextCharacterBoundary(from: startOffset)
    let start = stringIndex(startOffset)
    let end = stringIndex(endOffset)
    return state.text[start..<end].first
  }

  private func previousCharacterBoundary(from offset: Int) -> Int {
    var candidate = normalizedVimUTF16Offset(offset, in: state.text, bias: .backward)
    guard candidate > 0 else { return 0 }
    candidate -= 1
    return normalizedVimUTF16Offset(candidate, in: state.text, bias: .backward)
  }

  private func nextCharacterBoundary(from offset: Int) -> Int {
    let count = state.text.utf16.count
    var candidate = normalizedVimUTF16Offset(offset, in: state.text, bias: .forward)
    guard candidate < count else { return count }
    candidate += 1
    return normalizedVimUTF16Offset(candidate, in: state.text, bias: .forward)
  }

  private func advanceCharacters(from offset: Int, count: Int) -> Int {
    var result = normalizedVimUTF16Offset(offset, in: state.text)
    if count >= 0 {
      for _ in 0..<count { result = nextCharacterBoundary(from: result) }
    } else {
      for _ in 0..<(-count) { result = previousCharacterBoundary(from: result) }
    }
    return result
  }

  private func clamp(_ offset: Int) -> Int {
    normalizedVimUTF16Offset(offset, in: state.text)
  }

  private func stringIndex(_ utf16Offset: Int) -> String.Index {
    let safe = normalizedVimUTF16Offset(utf16Offset, in: state.text)
    let index = state.text.utf16.index(state.text.utf16.startIndex, offsetBy: safe)
    return String.Index(index, within: state.text) ?? state.text.endIndex
  }
}
