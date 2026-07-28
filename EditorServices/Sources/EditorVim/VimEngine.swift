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
  @_spi(Calcite) public var transaction: VimEditTransaction?

  public init(state: VimState, hostRequests: [VimHostRequest] = [], didChangeText: Bool = false) {
    self.state = state
    self.hostRequests = hostRequests
    self.didChangeText = didChangeText
    self.transaction = nil
  }

  @_spi(Calcite)
  public init(
    state: VimState,
    hostRequests: [VimHostRequest] = [],
    didChangeText: Bool = false,
    transaction: VimEditTransaction?
  ) {
    self.state = state
    self.hostRequests = hostRequests
    self.didChangeText = didChangeText
    self.transaction = transaction
  }
}

public enum VimError: Error, Equatable, Sendable {
  case invalidCount, invalidRegister
  case unsupportedNotation(String)
  case incompleteCommand(String)
  case macroRecursionLimit
}

enum VimRegisterShape: Hashable, Sendable {
  case characterwise
  case linewise
  case blockwise(width: Int)
}

struct VimRegisterValue: Hashable, Sendable {
  var text: String
  var shape: VimRegisterShape

  init(text: String, linewise: Bool) {
    self.text = text
    self.shape = linewise ? .linewise : .characterwise
  }

  init(text: String, shape: VimRegisterShape) {
    self.text = text
    self.shape = shape
  }

  var linewise: Bool {
    if case .linewise = shape { return true }
    return false
  }
}

struct VimChangeSession: Sendable {
  var before: VimState
  var commands: [VimSemanticCommand]
  var changedText: Bool
  var insertRepeatCount: Int
}

struct VimReplaceRestoration: Sendable {
  var location: Int
  var originalText: String
  var insertedUTF16Count: Int
}

struct VimRepeatRecord: Sendable {
  var commands: [VimSemanticCommand]
  var finishesInInsertMode: Bool
}

struct VimVisualSnapshot: Sendable {
  var anchor: Int
  var caret: Int
  var mode: VimMode
  var shape: VimSelectionShape
}

struct VimOperatorRange {
  var range: Range<Int>
  var linewise: Bool
  var blockRanges: [Range<Int>] = []
  var blockWidth: Int = 0
  var succeeded: Bool = true

  var isBlockwise: Bool { !blockRanges.isEmpty }
}

enum VimWordClass: Equatable {
  case whitespace
  case keyword
  case punctuation
}

public final class VimEngine: @unchecked Sendable {
  let lock = NSRecursiveLock()
  var storedState: VimState
  let globalStateStorage: VimGlobalStateStorage
  let bufferStateStorage: VimBufferStateStorage

  public internal(set) var state: VimState {
    get { lock.withLock { storedState } }
    set { lock.withLock { storedState = newValue } }
  }

  public var leader: String {
    get { lock.withLock { globalStateStorage.leader } }
    set { lock.withLock { globalStateStorage.leader = newValue } }
  }

  public var localLeader: String {
    get { lock.withLock { globalStateStorage.localLeader } }
    set { lock.withLock { globalStateStorage.localLeader = newValue } }
  }

  public var tabWidth: Int {
    get { lock.withLock { bufferStateStorage.tabWidth } }
    set { lock.withLock { bufferStateStorage.tabWidth = max(1, newValue) } }
  }

  let lineIndex = VimLineIndex()
  var registers: [VimRegister: VimRegisterValue] {
    get { globalStateStorage.registers }
    set { globalStateStorage.registers = newValue }
  }
  var marks: [Character: Int] {
    get { bufferStateStorage.marks }
    set { bufferStateStorage.marks = newValue }
  }
  var macros: [Character: [VimSemanticCommand]] {
    get { globalStateStorage.macros }
    set { globalStateStorage.macros = newValue }
  }
  var recording: Character? {
    get { globalStateStorage.recording }
    set { globalStateStorage.recording = newValue }
  }
  var recordingActions: [VimSemanticCommand] {
    get { globalStateStorage.recordingActions }
    set { globalStateStorage.recordingActions = newValue }
  }
  var leaderMappings: [String: VimInvocation] {
    get { globalStateStorage.leaderMappings }
    set { globalStateStorage.leaderMappings = newValue }
  }
  var localLeaderMappings: [String: VimInvocation] {
    get { globalStateStorage.localLeaderMappings }
    set { globalStateStorage.localLeaderMappings = newValue }
  }
  var undoTree: VimUndoTree { bufferStateStorage.undoTree }
  var undoStack: [VimHistoryEntry] { undoTree.activeTransactions() }
  var redoStack: [VimHistoryEntry] { undoTree.preferredRedoTransactions() }
  var editCaptureDepth = 0
  var capturedEdits: [VimEditDelta] = []
  var executionBatchDepth = 0
  var currentExecutionEdits: [VimEditDelta] = []
  var completedExecutionEdits: [VimEditDelta] = []
  var lastChange: VimAction? {
    get { globalStateStorage.lastChange }
    set { globalStateStorage.lastChange = newValue }
  }
  var lastRepeat: VimRepeatRecord? {
    get { globalStateStorage.lastRepeat }
    set { globalStateStorage.lastRepeat = newValue }
  }
  var activeChange: VimChangeSession?
  var lastSearch: (String, Bool)? {
    get { globalStateStorage.lastSearch }
    set { globalStateStorage.lastSearch = newValue }
  }
  var searchIgnoreCase: Bool {
    get { globalStateStorage.searchIgnoreCase }
    set { globalStateStorage.searchIgnoreCase = newValue }
  }
  var searchSmartCase: Bool {
    get { globalStateStorage.searchSmartCase }
    set { globalStateStorage.searchSmartCase = newValue }
  }
  var searchWrap: Bool {
    get { globalStateStorage.searchWrap }
    set { globalStateStorage.searchWrap = newValue }
  }
  var keywordOptions: VimKeywordOptions {
    get { bufferStateStorage.keywordOptions }
    set { bufferStateStorage.keywordOptions = newValue }
  }
  var textWidth: Int {
    get { bufferStateStorage.textWidth }
    set { bufferStateStorage.textWidth = newValue }
  }
  var visualAnchor: Int?
  var visualSelectionShape: VimSelectionShape = .character
  var lastVisual: VimVisualSnapshot?
  var blockInsertSession: VimBlockInsertSession?
  var preferredColumn: Int?
  var preferredVisualColumn: Int?
  weak var storedVisualGeometryProvider: (any VimVisualGeometryProviding)?
  var lastFind: (character: Character, forward: Bool, till: Bool)?
  var jumpBackStack: [Int] = []
  var jumpForwardStack: [Int] = []
  var changePositions: [Int] {
    get { bufferStateStorage.changePositions }
    set { bufferStateStorage.changePositions = newValue }
  }
  var changePositionIndex = 0
  var temporaryInsertReturnMode: VimMode?
  var lastPlayedMacro: Character?
  var macroDepth = 0
  let macroRecursionLimit = 100
  var historySuppressionDepth = 0
  var isReplayingChange = false
  var replaceRestorations: [VimReplaceRestoration] = []
  var lastInsertedText: String {
    get { bufferStateStorage.lastInsertedText }
    set { bufferStateStorage.lastInsertedText = newValue }
  }
  var lastSubstitutePattern: String {
    get { globalStateStorage.lastSubstitutePattern }
    set { globalStateStorage.lastSubstitutePattern = newValue }
  }
  var lastSubstituteReplacement: String {
    get { globalStateStorage.lastSubstituteReplacement }
    set { globalStateStorage.lastSubstituteReplacement = newValue }
  }
  var lastSubstituteFlags: String {
    get { globalStateStorage.lastSubstituteFlags }
    set { globalStateStorage.lastSubstituteFlags = newValue }
  }
  var pendingMessage: VimMessage?
  var viewportTopLine = 1
  var viewportBottomLine = 20
  var viewportPageLineCount = 20
  var viewportHalfPageLineCount = 10

  public convenience init(
    text: String = "", cursor: Int = 0, leader: String = "\\", localLeader: String = "\\",
    tabWidth: Int = 2
  ) {
    self.init(
      text: text,
      cursor: cursor,
      globalStateStorage: VimGlobalStateStorage(leader: leader, localLeader: localLeader),
      bufferStateStorage: VimBufferStateStorage(text: text, tabWidth: tabWidth)
    )
  }

  init(
    text: String,
    cursor: Int,
    globalStateStorage: VimGlobalStateStorage,
    bufferStateStorage: VimBufferStateStorage
  ) {
    self.storedState = VimState(text: text, cursor: cursor)
    self.globalStateStorage = globalStateStorage
    self.bufferStateStorage = bufferStateStorage
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
            visualSelectionShape = .character
            blockInsertSession = nil
          }
          state.selection = nil
          preferredColumn = nil
          preferredVisualColumn = nil
        }
        normalizeCursorForMode()
        return
      }

      activeChange = nil
      let delta = VimEditDelta.between(before.text, and: text)
      let updatesSharedBufferState = bufferStateStorage.authoritativeText != text
      state.text = text
      if let delta {
        lineIndex.synchronize(with: before.text)
        lineIndex.apply(
          replacementRange: delta.forwardRange,
          removedText: delta.removedText,
          insertedText: delta.insertedText,
          resultingText: text
        )
        if updatesSharedBufferState {
          adjustBufferPositions(
            afterReplacing: delta.forwardRange,
            replacementUTF16Count: delta.insertedUTF16Count
          )
          bufferStateStorage.authoritativeText = text
        }
        adjustWindowPositions(
          afterReplacing: delta.forwardRange,
          replacementUTF16Count: delta.insertedUTF16Count
        )
      } else {
        bufferStateStorage.authoritativeText = text
        lineIndex.invalidate()
      }
      state.cursor = targetCursor
      state.selection = nil
      state.mode = .normal
      visualAnchor = nil
      visualSelectionShape = .character
      blockInsertSession = nil
      preferredColumn = nil
      preferredVisualColumn = nil
      normalizeCursorForMode()

      if historySuppressionDepth == 0,
        let entry = VimHistoryEntry.make(
          before: before,
          after: state,
          edits: delta.map { [$0] } ?? []
        )
      {
        undoTree.append(entry)
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
      (macros[normalizedMacroName(name)] ?? []).flatMap(\.publicActions)
    }
  }

  public func setMacro(_ name: Character, actions: [VimAction]) {
    lock.withLock {
      let normalized = normalizedMacroName(name)
      let values = actions.map {
        VimSemanticCommand.action($0, count: 1, register: .unnamed)
      }
      if name.isUppercase {
        macros[normalized, default: []].append(contentsOf: values)
      } else {
        macros[normalized] = values
      }
    }
  }

  public var isRecordingMacro: Bool { lock.withLock { recording != nil } }

  func publishMessage(_ message: VimMessage) {
    pendingMessage = message
  }

  func consumeMessage() -> VimMessage? {
    defer { pendingMessage = nil }
    return pendingMessage
  }

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
    try lock.withLock {
      try executeTransactionBatch { try executeInvocationUnlocked(invocation) }
    }
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
    try lock.withLock {
      try executeTransactionBatch {
        try executeActionUnlocked(action, count: count, register: register)
      }
    }
  }
}
