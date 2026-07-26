import EditorCore
import Foundation

struct VimRecordedStep: Sendable {
  var action: VimAction
  var count: Int
  var register: VimRegister
}

struct VimChangeTransaction: Sendable {
  var snapshot: VimState
  var steps: [VimRecordedStep]
}

struct VimFindState: Sendable {
  var character: Character
  var forward: Bool
  var till: Bool
}

struct VimOperationTarget: Sendable {
  var ranges: [Range<Int>]
  var kind: VimRegisterKind

  var isEmpty: Bool { ranges.allSatisfy(\.isEmpty) }
}

struct VimMotionResult: Sendable {
  var destination: Int
  var kind: VimRegisterKind = .characterwise
  var inclusive: Bool = false
}

public final class VimEngine: @unchecked Sendable {
  public internal(set) var state: VimState
  public var leader: String
  public var localLeader: String
  public var tabWidth: Int {
    didSet { tabWidth = max(1, tabWidth) }
  }
  public var scrollPageLineCount: Int = 20
  public var scrollHalfPageLineCount: Int = 10
  public var macroRecursionLimit: Int = 100

  var registers = VimRegisterStore()
  var marks: [Character: Int] = [:]
  var macros: [Character: [VimRecordedStep]] = [:]
  var recording: Character?
  var recordingSteps: [VimRecordedStep] = []
  var lastPlayedMacro: Character?
  var leaderMappings: [String: VimInvocation] = [:]
  var localLeaderMappings: [String: VimInvocation] = [:]
  var undoStack: [VimState] = []
  var redoStack: [VimState] = []
  var activeChange: VimChangeTransaction?
  var lastChangeSteps: [VimRecordedStep] = []
  var lastSearch: (query: String, forward: Bool)?
  var lastFind: VimFindState?
  var lastVisualSelection: (mode: VimMode, selection: VimSelection)?
  var preferredVisualColumn: Int?
  var macroDepth = 0
  var suppressHistory = false
  var suppressChangeRecording = false
  var suppressMacroRecording = false

  public init(
    text: String = "",
    cursor: Int = 0,
    leader: String = "\\",
    localLeader: String = "\\",
    tabWidth: Int = 2
  ) {
    self.state = VimState(text: text, cursor: cursor)
    self.leader = leader
    self.localLeader = localLeader
    self.tabWidth = max(1, tabWidth)
    normalizeCursorForCurrentMode()
  }

  public func synchronize(text: String, cursor: Int? = nil) {
    let textChanged = text != state.text
    state.text = text
    if let cursor {
      state.cursor = buffer.normalize(cursor)
    } else {
      state.cursor = buffer.normalize(state.cursor)
    }

    if textChanged {
      activeChange = nil
      undoStack.removeAll(keepingCapacity: false)
      redoStack.removeAll(keepingCapacity: false)
      lastChangeSteps.removeAll(keepingCapacity: false)
      state.mode = .normal
      state.selection = nil
    } else if cursor != nil {
      if state.mode.isVisual { state.mode = .normal }
      state.selection = nil
    }
    normalizeCursorForCurrentMode()
    refreshSelectionRanges()
  }

  public func register(_ register: VimRegister) -> String {
    registers.value(for: register).text
  }

  public func registerValue(_ register: VimRegister) -> VimRegisterValue {
    registers.value(for: register)
  }

  public func setRegister(_ register: VimRegister, text: String) {
    registers.set(VimRegisterValue(text: text), for: register)
  }

  public func setRegister(_ register: VimRegister, value: VimRegisterValue) {
    registers.set(value, for: register)
  }

  public func macro(_ name: Character) -> [VimAction] {
    macros[normalizedRegisterName(name), default: []].map(\.action)
  }

  public func setMacro(_ name: Character, actions: [VimAction]) {
    macros[normalizedRegisterName(name)] = actions.map {
      VimRecordedStep(action: $0, count: 1, register: .unnamed)
    }
  }

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
    case .keys(let keys), .notation(let keys):
      return try executeNotation(keys)
    case .ex(let command):
      return try execute(.command(command))
    case .leader(let sequence):
      guard let mapped = leaderMappings[sequence] else { return result() }
      return try execute(mapped)
    case .localLeader(let sequence):
      guard let mapped = localLeaderMappings[sequence] else { return result() }
      return try execute(mapped)
    }
  }

  @discardableResult
  public func execute(
    _ action: VimAction,
    count: Int = 1,
    register: VimRegister = .unnamed
  ) throws -> VimExecutionResult {
    guard count > 0 else { throw VimError.invalidCount }
    let before = state
    let step = VimRecordedStep(action: action, count: count, register: register)
    var hostRequests: [VimHostRequest] = []

    recordMacroStepIfNeeded(step)

    switch action {
    case .move(let motion):
      move(motion, count: count)

    case .enterInsert:
      beginInsertChange(with: step)
      state.mode = .insert
      state.selection = nil

    case .enterInsertAfterCursor:
      beginInsertChange(with: step)
      state.cursor = insertionOffsetAfterCursor()
      state.mode = .insert
      state.selection = nil

    case .enterInsertAtLineStart:
      beginInsertChange(with: step)
      state.cursor = buffer.firstNonBlank(at: state.cursor)
      state.mode = .insert
      state.selection = nil

    case .enterInsertAtLineEnd:
      beginInsertChange(with: step)
      state.cursor = buffer.lineContentEnd(at: state.cursor)
      state.mode = .insert
      state.selection = nil

    case .enterReplace:
      beginInsertChange(with: step)
      state.mode = .replace
      state.selection = nil

    case .escape:
      leaveCurrentMode()

    case .enterVisualCharacter:
      toggleVisualMode(.visualCharacter)

    case .enterVisualLine:
      toggleVisualMode(.visualLine)

    case .enterVisualBlock:
      toggleVisualMode(.visualBlock)

    case .reselectVisual:
      if let lastVisualSelection {
        state.mode = lastVisualSelection.mode
        state.selection = lastVisualSelection.selection
        state.cursor = lastVisualSelection.selection.head
        refreshSelectionRanges()
      }

    case .switchVisualEndpoint:
      switchVisualEndpoint()

    case .enterCommandLine:
      state.mode = .commandLine

    case .enterSearch:
      state.mode = .search

    case .insert(let string):
      performTextMutation(step) {
        for _ in 0..<count { insertText(string) }
      }

    case .insertRegister(let source):
      let value = registers.value(for: source)
      performTextMutation(step) { insertText(String(repeating: value.text, count: count)) }

    case .replaceCharacter(let character):
      performTextMutation(step) {
        if state.mode.isVisual {
          replaceVisualSelection(with: character)
        } else {
          replaceCharacters(with: character, count: count)
        }
      }

    case .insertNewline:
      performTextMutation(step) { insertText(String(repeating: "\n", count: count)) }

    case .openLineBelow:
      beginInsertChange(with: step)
      let insertion = buffer.lineContentEnd(at: state.cursor)
      state.cursor = insertion
      insertText(String(repeating: "\n", count: count))
      state.cursor = insertion + 1
      state.mode = .insert

    case .openLineAbove:
      beginInsertChange(with: step)
      let insertion = buffer.lineStart(at: state.cursor)
      state.cursor = insertion
      insertText(String(repeating: "\n", count: count))
      state.cursor = insertion
      state.mode = .insert

    case .deleteCharacter:
      performTextMutation(step) {
        if state.mode == .insert || state.mode == .replace {
          let end = buffer.advance(from: state.cursor, by: count)
          deleteRaw(state.cursor..<end)
        } else {
          let end = min(
            buffer.lineContentEnd(at: state.cursor),
            buffer.advance(from: state.cursor, by: count)
          )
          deleteTarget(
            VimOperationTarget(ranges: [state.cursor..<end], kind: .characterwise),
            register: register,
            enterInsert: false
          )
        }
      }

    case .deleteBeforeCursor:
      performTextMutation(step) {
        let originalMode = state.mode
        if originalMode == .insert || originalMode == .replace {
          let start = buffer.advance(from: state.cursor, by: -count)
          deleteRaw(start..<state.cursor)
          state.mode = originalMode
        } else {
          let start = max(
            buffer.lineStart(at: state.cursor),
            buffer.advance(from: state.cursor, by: -count)
          )
          deleteTarget(
            VimOperationTarget(ranges: [start..<state.cursor], kind: .characterwise),
            register: register,
            enterInsert: false
          )
          state.cursor = start
        }
      }

    case .deleteWordBeforeCursor:
      performTextMutation(step) {
        let originalMode = state.mode
        var start = state.cursor
        for _ in 0..<count { start = buffer.previousWordStart(from: start) }
        deleteRaw(start..<state.cursor)
        state.cursor = start
        state.mode = originalMode
      }

    case .deleteToLineStart:
      performTextMutation(step) {
        let originalMode = state.mode
        let start = buffer.lineStart(at: state.cursor)
        deleteRaw(start..<state.cursor)
        state.cursor = start
        state.mode = originalMode
      }

    case .substituteCharacter:
      beginInsertChange(with: step)
      let end = min(
        buffer.lineContentEnd(at: state.cursor),
        buffer.advance(from: state.cursor, by: count)
      )
      deleteTarget(
        VimOperationTarget(ranges: [state.cursor..<end], kind: .characterwise),
        register: register,
        enterInsert: true
      )

    case .joinLines:
      performTextMutation(step) {
        if state.mode.isVisual {
          joinVisualSelection(insertingSpace: true)
        } else {
          for _ in 0..<count { joinLine(insertingSpace: true) }
        }
      }

    case .joinLinesWithoutSpace:
      performTextMutation(step) {
        if state.mode.isVisual {
          joinVisualSelection(insertingSpace: false)
        } else {
          for _ in 0..<count { joinLine(insertingSpace: false) }
        }
      }

    case .toggleCaseCharacter:
      performTextMutation(step) {
        let end = min(
          buffer.lineContentEnd(at: state.cursor),
          buffer.advance(from: state.cursor, by: count)
        )
        let target = VimOperationTarget(
          ranges: [state.cursor..<end],
          kind: .characterwise
        )
        apply(.swapCase, to: target, register: register)
        state.cursor = buffer.advance(from: state.cursor, by: count)
        normalizeCursorForCurrentMode()
      }

    case .adjustNumber(let delta):
      performTextMutation(step) { adjustNumber(by: delta * count) }

    case .operatorMotion(let operation, let motion):
      if operation == .format {
        hostRequests.append(.format)
      } else {
        let target = target(for: motion, count: count)
        if operation == .change {
          beginInsertChange(with: step)
          apply(operation, to: target, register: register)
        } else {
          performTextMutation(step) { apply(operation, to: target, register: register) }
        }
      }

    case .operatorLine(let operation):
      if operation == .format {
        hostRequests.append(.format)
      } else {
        let target = lineTarget(count: count)
        if operation == .change {
          beginInsertChange(with: step)
          apply(operation, to: target, register: register)
        } else {
          performTextMutation(step) { apply(operation, to: target, register: register) }
        }
      }

    case .operatorTextObject(let operation, let object, let inner):
      if operation == .format {
        hostRequests.append(.format)
      } else {
        let target = target(for: object, inner: inner)
        if operation == .change {
          beginInsertChange(with: step)
          apply(operation, to: target, register: register)
        } else {
          performTextMutation(step) { apply(operation, to: target, register: register) }
        }
      }

    case .operatorSelection(let operation):
      guard let target = visualTarget() else { break }
      rememberVisualSelection()
      if operation == .format {
        hostRequests.append(.format)
      } else if operation == .change {
        beginInsertChange(with: step)
        apply(operation, to: target, register: register)
      } else {
        performTextMutation(step) { apply(operation, to: target, register: register) }
      }
      if operation != .change { state.mode = .normal }
      state.selection = nil

    case .undo:
      cancelUncommittedChange()
      for _ in 0..<count {
        guard let previous = undoStack.popLast() else { break }
        redoStack.append(state)
        state = previous
      }

    case .redo:
      cancelUncommittedChange()
      for _ in 0..<count {
        guard let next = redoStack.popLast() else { break }
        undoStack.append(state)
        state = next
      }

    case .repeatLastChange:
      try repeatLastChange(count: count, fallbackRegister: register)

    case .pasteAfter:
      performTextMutation(step) {
        let value = registers.value(for: register)
        if state.mode.isVisual {
          pasteOverVisualSelection(value, count: count)
        } else {
          paste(value, after: true, count: count)
        }
      }

    case .pasteBefore:
      performTextMutation(step) {
        let value = registers.value(for: register)
        if state.mode.isVisual {
          pasteOverVisualSelection(value, count: count)
        } else {
          paste(value, after: false, count: count)
        }
      }

    case .setMark(let name):
      marks[name] = state.cursor

    case .jumpToMark(let name, let linewise):
      if let position = marks[name] {
        state.cursor = linewise ? buffer.firstNonBlank(at: position) : buffer.normalize(position)
        normalizeCursorForCurrentMode()
      }

    case .startMacro(let name):
      recording = normalizedRegisterName(name)
      recordingSteps.removeAll(keepingCapacity: true)

    case .stopMacro:
      if let recording {
        macros[recording] = recordingSteps
      }
      recording = nil
      recordingSteps.removeAll(keepingCapacity: false)

    case .playMacro(let name):
      hostRequests += try playMacro(name, count: count)

    case .playLastMacro:
      if let lastPlayedMacro { hostRequests += try playMacro(lastPlayedMacro, count: count) }

    case .search(let query, let forward):
      lastSearch = (query, forward)
      search(query, forward: forward, count: count)

    case .searchWordUnderCursor(let forward):
      if let query = buffer.currentWord(at: state.cursor), !query.isEmpty {
        lastSearch = (query, forward)
        search(query, forward: forward, count: count)
      }

    case .nextSearch:
      if let lastSearch { search(lastSearch.query, forward: lastSearch.forward, count: count) }

    case .previousSearch:
      if let lastSearch { search(lastSearch.query, forward: !lastSearch.forward, count: count) }

    case .command(let command):
      hostRequests += try executeEx(command)

    case .host(let request):
      hostRequests.append(request)

    case .leader(let sequence):
      return try execute(.leader(sequence))

    case .localLeader(let sequence):
      return try execute(.localLeader(sequence))
    }

    normalizeCursorForCurrentMode()
    refreshSelectionRanges()
    return VimExecutionResult(
      state: state,
      hostRequests: hostRequests,
      didChangeText: before.text != state.text
    )
  }

  func result(hostRequests: [VimHostRequest] = [], beforeText: String? = nil) -> VimExecutionResult
  {
    VimExecutionResult(
      state: state,
      hostRequests: hostRequests,
      didChangeText: beforeText.map { $0 != state.text } ?? false
    )
  }

  var buffer: VimTextBuffer { VimTextBuffer(state.text) }

  func normalizedRegisterName(_ name: Character) -> Character {
    name.isUppercase ? Character(String(name).lowercased()) : name
  }

  func recordMacroStepIfNeeded(_ step: VimRecordedStep) {
    guard recording != nil, !suppressMacroRecording else { return }
    switch step.action {
    case .stopMacro, .startMacro:
      return
    default:
      recordingSteps.append(step)
    }
  }

  func beginInsertChange(with step: VimRecordedStep) {
    if activeChange == nil {
      activeChange = VimChangeTransaction(snapshot: state, steps: [step])
    } else if !suppressChangeRecording {
      activeChange?.steps.append(step)
    }
  }

  func performTextMutation(_ step: VimRecordedStep, body: () -> Void) {
    if activeChange != nil {
      if !suppressChangeRecording { activeChange?.steps.append(step) }
      body()
      return
    }

    let snapshot = state
    body()
    guard snapshot.text != state.text else { return }
    if !suppressHistory {
      undoStack.append(snapshot)
      redoStack.removeAll(keepingCapacity: true)
    }
    if !suppressChangeRecording { lastChangeSteps = [step] }
  }

  func commitActiveChange(adjustCursor: Bool) {
    guard let change = activeChange else {
      if adjustCursor { normalizeCursorForCurrentMode() }
      return
    }
    activeChange = nil
    let didChangeText = change.snapshot.text != state.text
    if adjustCursor, didChangeText, state.cursor > 0 {
      state.cursor = buffer.previousBoundary(from: state.cursor)
    }
    state.mode = .normal
    state.selection = nil
    normalizeCursorForCurrentMode()

    guard didChangeText else { return }
    if !suppressHistory {
      undoStack.append(change.snapshot)
      redoStack.removeAll(keepingCapacity: true)
    }
    if !suppressChangeRecording {
      var steps = change.steps
      steps.append(VimRecordedStep(action: .escape, count: 1, register: .unnamed))
      lastChangeSteps = steps
    }
  }

  func cancelUncommittedChange() {
    activeChange = nil
    if state.mode == .insert || state.mode == .replace {
      state.mode = .normal
    }
  }

  func leaveCurrentMode() {
    switch state.mode {
    case .insert, .replace:
      commitActiveChange(adjustCursor: true)
    case .visualCharacter, .visualLine, .visualBlock:
      if let selection = state.selection {
        lastVisualSelection = (state.mode, selection)
      }
      state.mode = .normal
      state.selection = nil
    case .commandLine, .search:
      state.mode = .normal
      state.selection = nil
    case .normal:
      state.selection = nil
    }
  }

  func toggleVisualMode(_ mode: VimMode) {
    if state.mode == mode {
      state.mode = .normal
      state.selection = nil
      return
    }
    if state.mode.isVisual {
      state.mode = mode
      preferredVisualColumn =
        mode == .visualBlock
        ? buffer.visualColumn(at: state.cursor, tabWidth: tabWidth)
        : nil
      refreshSelectionRanges()
      return
    }
    state.mode = mode
    state.selection = VimSelection(state.cursor, state.cursor)
    preferredVisualColumn =
      mode == .visualBlock
      ? buffer.visualColumn(at: state.cursor, tabWidth: tabWidth)
      : nil
    refreshSelectionRanges()
  }

  func switchVisualEndpoint() {
    guard state.mode.isVisual, var selection = state.selection else { return }
    let oldAnchor = selection.anchor
    selection.anchor = selection.head
    selection.head = oldAnchor
    state.cursor = selection.head
    state.selection = selection
    refreshSelectionRanges()
  }

  func repeatLastChange(count: Int, fallbackRegister: VimRegister) throws {
    guard !lastChangeSteps.isEmpty else { return }
    let snapshot = state
    let steps = lastChangeSteps
    let previousSuppressHistory = suppressHistory
    let previousSuppressChangeRecording = suppressChangeRecording
    let previousSuppressMacroRecording = suppressMacroRecording
    suppressHistory = true
    suppressChangeRecording = true
    suppressMacroRecording = true
    defer {
      suppressHistory = previousSuppressHistory
      suppressChangeRecording = previousSuppressChangeRecording
      suppressMacroRecording = previousSuppressMacroRecording
      activeChange = nil
    }

    for _ in 0..<count {
      for step in steps {
        let register = step.register == .unnamed ? fallbackRegister : step.register
        _ = try execute(step.action, count: step.count, register: register)
      }
    }
    guard snapshot.text != state.text else { return }
    undoStack.append(snapshot)
    redoStack.removeAll(keepingCapacity: true)
  }

  func playMacro(_ name: Character, count: Int) throws -> [VimHostRequest] {
    let normalized = normalizedRegisterName(name)
    guard let steps = macros[normalized] else { return [] }
    guard macroDepth < macroRecursionLimit else { throw VimError.macroRecursionLimit }
    macroDepth += 1
    lastPlayedMacro = normalized
    let previousSuppress = suppressMacroRecording
    suppressMacroRecording = true
    defer {
      macroDepth -= 1
      suppressMacroRecording = previousSuppress
    }

    var hostRequests: [VimHostRequest] = []
    for _ in 0..<count {
      for step in steps {
        hostRequests += try execute(
          step.action,
          count: step.count,
          register: step.register
        ).hostRequests
      }
    }
    return hostRequests
  }

  func normalizeCursorForCurrentMode() {
    state.cursor = buffer.normalize(state.cursor)
    switch state.mode {
    case .normal, .visualCharacter, .visualLine, .visualBlock:
      let line = buffer.line(at: state.cursor)
      if line.contentEnd > line.start, state.cursor >= line.contentEnd {
        state.cursor = buffer.normalLineEnd(at: state.cursor)
      }
    case .insert, .replace, .commandLine, .search:
      break
    }
  }

  func insertionOffsetAfterCursor() -> Int {
    let line = buffer.line(at: state.cursor)
    guard state.cursor < line.contentEnd else { return line.contentEnd }
    return buffer.nextBoundary(from: state.cursor)
  }

  func refreshSelectionRanges() {
    guard state.mode.isVisual, var selection = state.selection else { return }
    selection.head = state.cursor
    switch state.mode {
    case .visualCharacter:
      let lower = min(selection.anchor, selection.head)
      let upper = buffer.nextBoundary(from: max(selection.anchor, selection.head))
      selection.ranges = [VimSelectionRange(lower, upper)]
    case .visualLine:
      let lower = buffer.lineStart(at: min(selection.anchor, selection.head))
      let upper = buffer.lineFullEnd(at: max(selection.anchor, selection.head))
      selection.ranges = [VimSelectionRange(lower, upper)]
    case .visualBlock:
      selection.ranges = buffer.blockRanges(
        anchorLine: buffer.lineNumber(at: selection.anchor),
        headLine: buffer.lineNumber(at: selection.head),
        anchorColumn: buffer.visualColumn(at: selection.anchor, tabWidth: tabWidth),
        headColumn: preferredVisualColumn
          ?? buffer.visualColumn(at: selection.head, tabWidth: tabWidth),
        tabWidth: tabWidth
      ).map { VimSelectionRange($0.lowerBound, $0.upperBound) }
    default:
      selection.ranges = []
    }
    state.selection = selection
  }
}

extension VimMode {
  var isVisual: Bool {
    self == .visualCharacter || self == .visualLine || self == .visualBlock
  }
}
