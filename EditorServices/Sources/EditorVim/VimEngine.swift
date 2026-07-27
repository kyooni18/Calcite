import EditorCore
import Foundation

#if canImport(AppKit)
  import AppKit
#endif

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

enum VimUTF16BoundaryBias {
  case backward
  case forward
}

func normalizedVimUTF16Offset(
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

struct VimRegisterValue: Sendable {
  var text: String
  var linewise: Bool
}

<<<<<<< HEAD
struct VimChangeSession: Sendable {
  var before: VimState
  var commands: [VimSemanticCommand]
=======
struct VimRecordedInvocation: Sendable {
  var action: VimAction
  var count: Int
  var register: VimRegister
}

struct VimChangeSession: Sendable {
  var before: VimState
  var invocations: [VimRecordedInvocation]
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
  var changedText: Bool
  var insertRepeatCount: Int
}

struct VimReplaceRestoration: Sendable {
  var location: Int
  var originalText: String
  var insertedUTF16Count: Int
}

struct VimRepeatRecord: Sendable {
<<<<<<< HEAD
  var commands: [VimSemanticCommand]
=======
  var invocations: [VimRecordedInvocation]
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
  var finishesInInsertMode: Bool
}

struct VimVisualSnapshot: Sendable {
  var anchor: Int
  var caret: Int
  var mode: VimMode
}

struct VimOperatorRange {
  var range: Range<Int>
  var linewise: Bool
}

enum VimWordClass: Equatable {
  case whitespace
  case keyword
  case punctuation
}

public final class VimEngine: @unchecked Sendable {
  let lock = NSRecursiveLock()
  var storedState: VimState
  var storedLeader: String
  var storedLocalLeader: String
  var storedTabWidth: Int

  public internal(set) var state: VimState {
    get { lock.withLock { storedState } }
    set { lock.withLock { storedState = newValue } }
  }

  public var leader: String {
    get { lock.withLock { storedLeader } }
    set { lock.withLock { storedLeader = newValue } }
  }

  public var localLeader: String {
    get { lock.withLock { storedLocalLeader } }
    set { lock.withLock { storedLocalLeader = newValue } }
  }

  public var tabWidth: Int {
    get { lock.withLock { storedTabWidth } }
    set { lock.withLock { storedTabWidth = max(1, newValue) } }
  }

  let lineIndex = VimLineIndex()
  var registers: [VimRegister: VimRegisterValue] = [:]
  var marks: [Character: Int] = [:]
<<<<<<< HEAD
  var macros: [Character: [VimSemanticCommand]] = [:]
  var recording: Character?
  var recordingActions: [VimSemanticCommand] = []
  var leaderMappings: [String: VimInvocation] = [:]
  var localLeaderMappings: [String: VimInvocation] = [:]
  let undoTree = VimUndoTree()
  var undoStack: [VimHistoryEntry] { undoTree.activeTransactions() }
  var redoStack: [VimHistoryEntry] { undoTree.preferredRedoTransactions() }
  var editCaptureDepth = 0
  var capturedEdits: [VimEditDelta] = []
  var executionBatchDepth = 0
  var currentExecutionEdits: [VimEditDelta] = []
  var completedExecutionEdits: [VimEditDelta] = []
=======
  var macros: [Character: [VimRecordedInvocation]] = [:]
  var recording: Character?
  var recordingActions: [VimRecordedInvocation] = []
  var leaderMappings: [String: VimInvocation] = [:]
  var localLeaderMappings: [String: VimInvocation] = [:]
  var undoStack: [VimHistoryEntry] = []
  var redoStack: [VimHistoryEntry] = []
  var editCaptureDepth = 0
  var capturedEdits: [VimEditDelta] = []
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
  var lastChange: VimAction?
  var lastRepeat: VimRepeatRecord?
  var activeChange: VimChangeSession?
  var lastSearch: (String, Bool)?
  var searchIgnoreCase = false
  var searchSmartCase = true
  var searchWrap = true
  var visualAnchor: Int?
  var lastVisual: VimVisualSnapshot?
  var preferredColumn: Int?
  var lastFind: (character: Character, forward: Bool, till: Bool)?
  var jumpBackStack: [Int] = []
  var jumpForwardStack: [Int] = []
  var changePositions: [Int] = []
  var changePositionIndex = 0
  var temporaryInsertReturnMode: VimMode?
  var lastPlayedMacro: Character?
  var macroDepth = 0
  let macroRecursionLimit = 100
  var historySuppressionDepth = 0
  var isReplayingChange = false
  var replaceRestorations: [VimReplaceRestoration] = []
  var lastInsertedText = ""
<<<<<<< HEAD
  var lastSubstitutePattern = ""
  var lastSubstituteReplacement = ""
  var lastSubstituteFlags = ""
  var viewportTopLine = 1
  var viewportBottomLine = 20
  var viewportPageLineCount = 20
  var viewportHalfPageLineCount = 10
=======
  var lastSubstituteReplacement = ""
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883

  public init(
    text: String = "", cursor: Int = 0, leader: String = "\\", localLeader: String = "\\",
    tabWidth: Int = 2
  ) {
    self.storedState = VimState(text: text, cursor: cursor)
    self.storedLeader = leader
    self.storedLocalLeader = localLeader
    self.storedTabWidth = max(1, tabWidth)
    normalizeCursorForMode()
  }

  public func synchronize(text: String, cursor: Int? = nil) {
    lock.withLock {
      let before = state
      let targetCursor = normalizedVimUTF16Offset(cursor ?? before.cursor, in: text)

      guard before.text != text else {
        state.cursor = targetCursor
        if cursor != nil {
          if state.mode == .visualCharacter || state.mode == .visualLine {
            rememberVisualSelection()
            state.mode = .normal
            visualAnchor = nil
          }
          state.selection = nil
          preferredColumn = nil
        }
        normalizeCursorForMode()
        return
      }

      activeChange = nil
      let delta = VimEditDelta.between(before.text, and: text)
      state.text = text
      if let delta {
        lineIndex.synchronize(with: before.text)
        lineIndex.apply(
          replacementRange: delta.forwardRange,
          removedText: delta.removedText,
          insertedText: delta.insertedText,
          resultingText: text
        )
        adjustStoredPositions(
          afterReplacing: delta.location..<(delta.location + delta.removedUTF16Count),
          replacementUTF16Count: delta.insertedUTF16Count
        )
      } else {
        lineIndex.invalidate()
      }
      state.cursor = targetCursor
      state.selection = nil
      state.mode = .normal
      visualAnchor = nil
      preferredColumn = nil
      normalizeCursorForMode()

      if historySuppressionDepth == 0,
        let entry = VimHistoryEntry.make(
          before: before,
          after: state,
          edits: delta.map { [$0] } ?? []
        )
      {
<<<<<<< HEAD
        undoTree.append(entry)
=======
        undoStack.append(entry)
        redoStack.removeAll(keepingCapacity: true)
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
      }
    }
  }

  public func register(_ register: VimRegister) -> String {
    lock.withLock { registerValue(for: register).text }
  }

  public func setRegister(_ register: VimRegister, text: String) {
    lock.withLock {
      guard register != .blackHole else { return }
      let value = VimRegisterValue(
        text: text,
        linewise: text.hasSuffix("\n") || text.hasSuffix("\r")
      )
      writeExplicitRegister(register, value: value)
    }
  }

  public func macro(_ name: Character) -> [VimAction] {
    lock.withLock {
<<<<<<< HEAD
      (macros[normalizedMacroName(name)] ?? []).flatMap(\.publicActions)
=======
      (macros[normalizedMacroName(name)] ?? []).flatMap { invocation in
        Array(repeating: invocation.action, count: max(1, invocation.count))
      }
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
    }
  }

  public func setMacro(_ name: Character, actions: [VimAction]) {
    lock.withLock {
      let normalized = normalizedMacroName(name)
      let values = actions.map {
<<<<<<< HEAD
        VimSemanticCommand.action($0, count: 1, register: .unnamed)
=======
        VimRecordedInvocation(action: $0, count: 1, register: .unnamed)
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
      }
      if name.isUppercase {
        macros[normalized, default: []].append(contentsOf: values)
      } else {
        macros[normalized] = values
      }
    }
  }

  public var isRecordingMacro: Bool { lock.withLock { recording != nil } }

  public func mapLeader(_ sequence: String, to invocation: VimInvocation) {
    lock.withLock { leaderMappings[sequence] = invocation }
  }

  public func mapLocalLeader(_ sequence: String, to invocation: VimInvocation) {
    lock.withLock { localLeaderMappings[sequence] = invocation }
  }

  public func unmapLeader(_ sequence: String) {
    lock.withLock { _ = leaderMappings.removeValue(forKey: sequence) }
  }

  public func unmapLocalLeader(_ sequence: String) {
    lock.withLock { _ = localLeaderMappings.removeValue(forKey: sequence) }
  }

  public var leaderSequences: [String] { lock.withLock { leaderMappings.keys.sorted() } }
  public var localLeaderSequences: [String] {
    lock.withLock { localLeaderMappings.keys.sorted() }
  }

  @discardableResult
  public func execute(_ invocation: VimInvocation) throws -> VimExecutionResult {
<<<<<<< HEAD
    try lock.withLock {
      try withExecutionBatch { try executeInvocationUnlocked(invocation) }
    }
=======
    try lock.withLock { try executeInvocationUnlocked(invocation) }
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
  }

  private func executeInvocationUnlocked(_ invocation: VimInvocation) throws -> VimExecutionResult {
    switch invocation {
    case .action(let action, let count, let register):
      return try execute(action, count: count, register: register)
    case .keys(let keys), .notation(let keys):
      return try executeNotation(keys)
    case .ex(let command):
      return try execute(.command(command))
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
<<<<<<< HEAD
    try lock.withLock {
      try withExecutionBatch {
        try executeActionUnlocked(action, count: count, register: register)
      }
    }
=======
    try lock.withLock { try executeActionUnlocked(action, count: count, register: register) }
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883
  }
}
