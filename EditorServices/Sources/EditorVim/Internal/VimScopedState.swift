import Foundation

/// State shared by every Vim window in one Calcite window/session.
final class VimGlobalStateStorage: @unchecked Sendable {
  var registers: [VimRegister: VimRegisterValue] = [:]
  var macros: [Character: [VimSemanticCommand]] = [:]
  var recording: Character?
  var recordingActions: [VimSemanticCommand] = []
  var leaderMappings: [String: VimInvocation] = [:]
  var localLeaderMappings: [String: VimInvocation] = [:]
  var leader: String
  var localLeader: String
  var lastChange: VimAction?
  var lastRepeat: VimRepeatRecord?
  var lastSearch: (String, Bool)?
  var lastSubstitutePattern = ""
  var lastSubstituteReplacement = ""
  var lastSubstituteFlags = ""
  var searchIgnoreCase = false
  var searchSmartCase = true
  var searchWrap = true
  var history = VimCommandLineHistoryStorage()

  init(leader: String, localLeader: String) {
    self.leader = leader
    self.localLeader = localLeader
  }
}

/// State shared by every view displaying the same Vim buffer.
final class VimBufferStateStorage: @unchecked Sendable {
  let undoTree = VimUndoTree()
  let lineIndex = VimLineIndex()
  var marks: [Character: Int] = [:]
  var changePositions: [Int] = []
  var lastInsertedText = ""
  var keywordOptions = VimKeywordOptions()
  var textWidth = 0
  var tabWidth: Int
  var authoritativeText: String
  var revision: UInt64 = 0

  init(text: String, tabWidth: Int) {
    self.authoritativeText = text
    self.tabWidth = max(1, tabWidth)
    lineIndex.synchronize(with: text)
  }
}

enum VimPromptKind: Sendable {
  case command
  case search(forward: Bool)
}

/// Presentation and input-adapter state for one `(window, buffer)` view.
final class VimWindowStateStorage: @unchecked Sendable {
  var pendingNotation = ""
  var prompt: String?
  var inputPolicy: VimCommandKeyboardPolicy = .automatic
  var languageMap: [Character: Character] = [:]
  var message: VimMessage?
  var messageExpiration: Date?
  var configurationSignature: String?

  var promptKind: VimPromptKind?
  var promptBuffer: [Character] = []
  var promptCursor = 0
  var historyIndex: Int?
  var historySearchPrefix: String?

  var compositionIsActive = false
  var compositionText = ""
  var compositionSelection = 0..<0

  var mappingTries: [VimMappingKey: VimMappingTrie] = [:]
  var mappingConflicts: [VimMappingConflict] = []
  var pendingTokens: [VimInputToken] = []
  var pendingInputDomain: VimMappingInputDomain?
  var commandTokens: [VimInputToken] = []
  var commandParser = VimCommandParser()
  var mappingDepth = 0

  var inputSourceIdentifier: String?
  var horizontalScrollOffset = 0.0
  var verticalScrollOffset = 0.0
  var zoomScale = 1.0
  var viewportTopLine = 1
  var viewportBottomLine = 20
  var viewportPageLineCount = 20
  var viewportHalfPageLineCount = 10
  var pendingScrollLineDelta = 0
  var mappingTimeoutTask: Task<Void, Never>?
  var messageTimeoutTask: Task<Void, Never>?
  var stateChangeHandler: (@MainActor () -> Void)?
  var pendingAsynchronousResults: [VimKeyHandlingResult] = []

  deinit {
    mappingTimeoutTask?.cancel()
    messageTimeoutTask?.cancel()
  }
}

/// All state that affects command execution or restoration for one Vim view.
/// The storage belongs to the session `VimEngine`; controllers and surfaces only
/// retain a `VimViewID` projection into it.
final class VimEngineViewStateStorage: @unchecked Sendable {
  let id: VimViewID
  let windowID: VimWindowID
  let bufferID: VimBufferID
  var state: VimState
  let presentation = VimWindowStateStorage()

  var editCaptureDepth = 0
  var capturedEdits: [VimEditDelta] = []
  var executionBatchDepth = 0
  var currentExecutionEdits: [VimEditDelta] = []
  var completedExecutionEdits: [VimEditDelta] = []
  var activeChange: VimChangeSession?

  var visualAnchor: Int?
  var visualSelectionShape: VimSelectionShape = .character
  var lastVisual: VimVisualSnapshot?
  var blockInsertSession: VimBlockInsertSession?
  var preferredColumn: Int?
  var preferredVisualColumn: Int?
  weak var visualGeometryProvider: (any VimVisualGeometryProviding)?
  var lastFind: (character: Character, forward: Bool, till: Bool)?
  var jumpBackStack: [Int] = []
  var jumpForwardStack: [Int] = []
  var changePositionIndex = 0
  var temporaryInsertReturnMode: VimMode?
  var lastPlayedMacro: Character?
  var macroDepth = 0
  var historySuppressionDepth = 0
  var isReplayingChange = false
  var replaceRestorations: [VimReplaceRestoration] = []

  init(
    id: VimViewID,
    windowID: VimWindowID,
    bufferID: VimBufferID,
    text: String,
    cursor: Int
  ) {
    self.id = id
    self.windowID = windowID
    self.bufferID = bufferID
    self.state = VimState(text: text, cursor: cursor)
  }
}

struct VimEngineBufferRecord {
  var info: VimBufferInfo
  let state: VimBufferStateStorage
}

struct VimEngineWindowRecord {
  var currentBuffer: VimBufferID?
  var alternateBuffer: VimBufferID?
  var tabPageID: VimTabPageID?
  var views: [VimBufferID: VimViewID]
  var viewMRU: [VimBufferID]
}

/// Canonical state graph for one Calcite window session.
final class VimEngineSessionStorage: @unchecked Sendable {
  let globalState: VimGlobalStateStorage
  var buffers: [VimBufferID: VimEngineBufferRecord] = [:]
  var bufferOrder: [VimBufferID] = []
  var windows: [VimWindowID: VimEngineWindowRecord] = [:]
  var views: [VimViewID: VimEngineViewStateStorage] = [:]
  var nextBufferNumber = 1

  init(leader: String, localLeader: String) {
    self.globalState = VimGlobalStateStorage(leader: leader, localLeader: localLeader)
  }
}

final class VimCommandLineHistoryStorage: @unchecked Sendable {
  var commands: [String] = []
  var searches: [String] = []

  func merge(_ snapshot: VimHistorySnapshot) {
    commands = Self.merged(commands, snapshot.commands)
    searches = Self.merged(searches, snapshot.searches)
  }

  private static func merged(_ lhs: [String], _ rhs: [String]) -> [String] {
    var result: [String] = []
    result.reserveCapacity(min(200, lhs.count + rhs.count))
    for value in lhs + rhs where !value.isEmpty {
      if let index = result.firstIndex(of: value) { result.remove(at: index) }
      result.append(value)
    }
    return Array(result.suffix(200))
  }
}
