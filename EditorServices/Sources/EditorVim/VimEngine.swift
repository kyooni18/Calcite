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
  let sessionStorage: VimEngineSessionStorage
  let defaultWindowID: VimWindowID
  let defaultBufferID: VimBufferID
  let defaultViewID: VimViewID
  private var activeViewStack: [VimViewID] = []
  var bufferPropagationDepth = 0

  var scopedViewID: VimViewID? { activeViewStack.last }
  var activeViewID: VimViewID { scopedViewID ?? defaultViewID }
  var activeViewStorage: VimEngineViewStateStorage {
    guard let storage = sessionStorage.views[activeViewID] else {
      preconditionFailure("VimEngine view is not registered: \(activeViewID.rawValue)")
    }
    return storage
  }
  var storedState: VimState {
    get { activeViewStorage.state }
    set { activeViewStorage.state = newValue }
  }
  var globalStateStorage: VimGlobalStateStorage { sessionStorage.globalState }
  var bufferStateStorage: VimBufferStateStorage {
    guard let storage = sessionStorage.buffers[activeViewStorage.bufferID]?.state else {
      preconditionFailure("VimEngine buffer is not registered: \(activeViewStorage.bufferID.rawValue)")
    }
    return storage
  }
  var windowStateStorage: VimWindowStateStorage { activeViewStorage.presentation }

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

  var lineIndex: VimLineIndex { bufferStateStorage.lineIndex }
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
  var editCaptureDepth: Int {
    get { activeViewStorage.editCaptureDepth }
    set { activeViewStorage.editCaptureDepth = newValue }
  }
  var capturedEdits: [VimEditDelta] {
    get { activeViewStorage.capturedEdits }
    set { activeViewStorage.capturedEdits = newValue }
  }
  var executionBatchDepth: Int {
    get { activeViewStorage.executionBatchDepth }
    set { activeViewStorage.executionBatchDepth = newValue }
  }
  var currentExecutionEdits: [VimEditDelta] {
    get { activeViewStorage.currentExecutionEdits }
    set { activeViewStorage.currentExecutionEdits = newValue }
  }
  var completedExecutionEdits: [VimEditDelta] {
    get { activeViewStorage.completedExecutionEdits }
    set { activeViewStorage.completedExecutionEdits = newValue }
  }
  var lastChange: VimAction? {
    get { globalStateStorage.lastChange }
    set { globalStateStorage.lastChange = newValue }
  }
  var lastRepeat: VimRepeatRecord? {
    get { globalStateStorage.lastRepeat }
    set { globalStateStorage.lastRepeat = newValue }
  }
  var activeChange: VimChangeSession? {
    get { activeViewStorage.activeChange }
    set { activeViewStorage.activeChange = newValue }
  }
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
  var visualAnchor: Int? {
    get { activeViewStorage.visualAnchor }
    set { activeViewStorage.visualAnchor = newValue }
  }
  var visualSelectionShape: VimSelectionShape {
    get { activeViewStorage.visualSelectionShape }
    set { activeViewStorage.visualSelectionShape = newValue }
  }
  var lastVisual: VimVisualSnapshot? {
    get { activeViewStorage.lastVisual }
    set { activeViewStorage.lastVisual = newValue }
  }
  var blockInsertSession: VimBlockInsertSession? {
    get { activeViewStorage.blockInsertSession }
    set { activeViewStorage.blockInsertSession = newValue }
  }
  var preferredColumn: Int? {
    get { activeViewStorage.preferredColumn }
    set { activeViewStorage.preferredColumn = newValue }
  }
  var preferredVisualColumn: Int? {
    get { activeViewStorage.preferredVisualColumn }
    set { activeViewStorage.preferredVisualColumn = newValue }
  }
  weak var storedVisualGeometryProvider: (any VimVisualGeometryProviding)? {
    get { activeViewStorage.visualGeometryProvider }
    set { activeViewStorage.visualGeometryProvider = newValue }
  }
  var lastFind: (character: Character, forward: Bool, till: Bool)? {
    get { activeViewStorage.lastFind }
    set { activeViewStorage.lastFind = newValue }
  }
  var jumpBackStack: [Int] {
    get { activeViewStorage.jumpBackStack }
    set { activeViewStorage.jumpBackStack = newValue }
  }
  var jumpForwardStack: [Int] {
    get { activeViewStorage.jumpForwardStack }
    set { activeViewStorage.jumpForwardStack = newValue }
  }
  var changePositions: [Int] {
    get { bufferStateStorage.changePositions }
    set { bufferStateStorage.changePositions = newValue }
  }
  var changePositionIndex: Int {
    get { activeViewStorage.changePositionIndex }
    set { activeViewStorage.changePositionIndex = newValue }
  }
  var temporaryInsertReturnMode: VimMode? {
    get { activeViewStorage.temporaryInsertReturnMode }
    set { activeViewStorage.temporaryInsertReturnMode = newValue }
  }
  var lastPlayedMacro: Character? {
    get { activeViewStorage.lastPlayedMacro }
    set { activeViewStorage.lastPlayedMacro = newValue }
  }
  var macroDepth: Int {
    get { activeViewStorage.macroDepth }
    set { activeViewStorage.macroDepth = newValue }
  }
  let macroRecursionLimit = 100
  var historySuppressionDepth: Int {
    get { activeViewStorage.historySuppressionDepth }
    set { activeViewStorage.historySuppressionDepth = newValue }
  }
  var isReplayingChange: Bool {
    get { activeViewStorage.isReplayingChange }
    set { activeViewStorage.isReplayingChange = newValue }
  }
  var replaceRestorations: [VimReplaceRestoration] {
    get { activeViewStorage.replaceRestorations }
    set { activeViewStorage.replaceRestorations = newValue }
  }
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
  var pendingMessage: VimMessage? {
    get { windowStateStorage.message }
    set { windowStateStorage.message = newValue }
  }
  var viewportTopLine: Int {
    get { windowStateStorage.viewportTopLine }
    set { windowStateStorage.viewportTopLine = newValue }
  }
  var viewportBottomLine: Int {
    get { windowStateStorage.viewportBottomLine }
    set { windowStateStorage.viewportBottomLine = newValue }
  }
  var viewportPageLineCount: Int {
    get { windowStateStorage.viewportPageLineCount }
    set { windowStateStorage.viewportPageLineCount = newValue }
  }
  var viewportHalfPageLineCount: Int {
    get { windowStateStorage.viewportHalfPageLineCount }
    set { windowStateStorage.viewportHalfPageLineCount = newValue }
  }

  public convenience init(
    text: String = "", cursor: Int = 0, leader: String = "\\", localLeader: String = "\\",
    tabWidth: Int = 2
  ) {
    let windowID = VimWindowID(UUID())
    let bufferID = VimBufferID(UUID())
    let viewID = VimViewID(UUID())
    let session = VimEngineSessionStorage(leader: leader, localLeader: localLeader)
    let info = VimBufferInfo(id: bufferID, number: 1, name: "")
    session.buffers[bufferID] = VimEngineBufferRecord(
      info: info,
      state: VimBufferStateStorage(text: text, tabWidth: tabWidth)
    )
    session.bufferOrder = [bufferID]
    session.nextBufferNumber = 2
    session.windows[windowID] = VimEngineWindowRecord(
      currentBuffer: bufferID,
      alternateBuffer: nil,
      tabPageID: nil,
      views: [bufferID: viewID]
    )
    session.views[viewID] = VimEngineViewStateStorage(
      id: viewID,
      windowID: windowID,
      bufferID: bufferID,
      text: text,
      cursor: cursor
    )
    self.init(
      sessionStorage: session,
      defaultWindowID: windowID,
      defaultBufferID: bufferID,
      defaultViewID: viewID
    )
  }

  init(
    sessionStorage: VimEngineSessionStorage,
    defaultWindowID: VimWindowID,
    defaultBufferID: VimBufferID,
    defaultViewID: VimViewID
  ) {
    self.sessionStorage = sessionStorage
    self.defaultWindowID = defaultWindowID
    self.defaultBufferID = defaultBufferID
    self.defaultViewID = defaultViewID
    withView(defaultViewID) { normalizeCursorForMode() }
  }

  @discardableResult
  func withView<T>(_ viewID: VimViewID, _ body: () throws -> T) rethrows -> T {
    try lock.withLock {
      precondition(sessionStorage.views[viewID] != nil, "Unknown Vim view")
      activeViewStack.append(viewID)
      defer { _ = activeViewStack.popLast() }
      return try body()
    }
  }

  func viewProjection(_ viewID: VimViewID) -> VimEngineView {
    VimEngineView(root: self, viewID: viewID)
  }

  func scopedViewProjection() -> VimEngineView? {
    lock.withLock { scopedViewID.map(viewProjection) }
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
      commitActiveBufferText(before: before.text, after: state.text)
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

extension VimEngine {
  @_spi(Calcite)
  public var windowPresentationState: VimWindowPresentationState {
    lock.withLock {
      VimWindowPresentationState(
        inputSourceIdentifier: windowStateStorage.inputSourceIdentifier,
        horizontalScrollOffset: windowStateStorage.horizontalScrollOffset,
        verticalScrollOffset: windowStateStorage.verticalScrollOffset,
        zoomScale: windowStateStorage.zoomScale,
        viewportTopLine: windowStateStorage.viewportTopLine,
        viewportBottomLine: windowStateStorage.viewportBottomLine
      )
    }
  }

  @_spi(Calcite)
  public func requestViewportScroll(lines: Int) {
    lock.withLock { windowStateStorage.pendingScrollLineDelta += lines }
  }

  @_spi(Calcite)
  public func consumeViewportScrollRequest() -> Int {
    lock.withLock {
      defer { windowStateStorage.pendingScrollLineDelta = 0 }
      return windowStateStorage.pendingScrollLineDelta
    }
  }

  @_spi(Calcite)
  public func updateWindowPresentation(
    inputSourceIdentifier: String? = nil,
    updatesInputSource: Bool = false,
    horizontalScrollOffset: Double? = nil,
    verticalScrollOffset: Double? = nil,
    zoomScale: Double? = nil
  ) {
    lock.withLock {
      if updatesInputSource {
        windowStateStorage.inputSourceIdentifier = inputSourceIdentifier
      }
      if let horizontalScrollOffset, horizontalScrollOffset.isFinite {
        windowStateStorage.horizontalScrollOffset = max(0, horizontalScrollOffset)
      }
      if let verticalScrollOffset, verticalScrollOffset.isFinite {
        windowStateStorage.verticalScrollOffset = max(0, verticalScrollOffset)
      }
      if let zoomScale, zoomScale.isFinite {
        windowStateStorage.zoomScale = min(max(zoomScale, 0.5), 2)
      }
    }
  }
}
