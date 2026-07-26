import Foundation

public enum VimMode: String, Sendable, Codable, CaseIterable {
  case normal
  case insert
  case replace
  case visualCharacter
  case visualLine
  case visualBlock
  case commandLine
  case search
}

public enum VimRegister: Hashable, Sendable {
  case unnamed
  case named(Character)
  case numbered(Int)
  case smallDelete
  case blackHole
  case clipboard
}

public enum VimRegisterKind: String, Hashable, Sendable, Codable {
  case characterwise
  case linewise
  case blockwise
}

public struct VimRegisterValue: Hashable, Sendable {
  public var text: String
  public var kind: VimRegisterKind

  public init(text: String = "", kind: VimRegisterKind = .characterwise) {
    self.text = text
    self.kind = kind
  }
}

public enum VimMotion: Hashable, Sendable {
  case left, right, up, down
  case lineStart, firstNonBlank, lineEnd, lineContentEnd
  case nextLineFirstNonBlank, previousLineFirstNonBlank, currentLineFirstNonBlank
  case column(Int)
  case wordForward, bigWordForward
  case wordBackward, bigWordBackward
  case wordEnd, bigWordEnd
  case wordEndBackward, bigWordEndBackward
  case sentenceForward, sentenceBackward
  case paragraphForward, paragraphBackward
  case documentStart, documentEnd
  case screenTop, screenMiddle, screenBottom
  case pageUp, pageDown, halfPageUp, halfPageDown
  case findForward(Character)
  case findBackward(Character)
  case tillForward(Character)
  case tillBackward(Character)
  case repeatFind(reverse: Bool)
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
  case delete
  case change
  case yank
  case indent
  case outdent
  case uppercase
  case lowercase
  case swapCase
  case format
  case rot13
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
  case enterVisualCharacter, enterVisualLine, enterVisualBlock, reselectVisual
  case switchVisualEndpoint
  case enterCommandLine, enterSearch
  case insert(String)
  case insertRegister(VimRegister)
  case replaceCharacter(Character)
  case insertNewline, openLineBelow, openLineAbove
  case deleteCharacter, deleteBeforeCursor, deleteWordBeforeCursor, deleteToLineStart
  case substituteCharacter, joinLines, joinLinesWithoutSpace, toggleCaseCharacter
  case adjustNumber(Int)
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
  case playLastMacro
  case search(String, forward: Bool)
  case searchWordUnderCursor(forward: Bool)
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

public struct VimSelectionRange: Hashable, Sendable {
  public var lowerBound: Int
  public var upperBound: Int

  public init(_ lowerBound: Int, _ upperBound: Int) {
    self.lowerBound = min(lowerBound, upperBound)
    self.upperBound = max(lowerBound, upperBound)
  }
}

public struct VimSelection: Hashable, Sendable {
  public var anchor: Int
  public var head: Int
  public var ranges: [VimSelectionRange]

  public var lowerBound: Int {
    ranges.map(\.lowerBound).min() ?? min(anchor, head)
  }

  public var upperBound: Int {
    ranges.map(\.upperBound).max() ?? max(anchor, head)
  }

  public var isReversed: Bool { head < anchor }

  public init(_ anchor: Int, _ head: Int, ranges: [VimSelectionRange] = []) {
    self.anchor = anchor
    self.head = head
    self.ranges = ranges
  }
}

public struct VimState: Hashable, Sendable {
  public var text: String
  public var cursor: Int
  public var mode: VimMode
  public var selection: VimSelection?

  public init(
    text: String = "",
    cursor: Int = 0,
    mode: VimMode = .normal,
    selection: VimSelection? = nil
  ) {
    self.text = text
    self.cursor = VimTextBuffer.normalize(offset: cursor, in: text)
    self.mode = mode
    self.selection = selection
  }
}

public struct VimExecutionResult: Sendable {
  public var state: VimState
  public var hostRequests: [VimHostRequest]
  public var didChangeText: Bool

  public init(
    state: VimState,
    hostRequests: [VimHostRequest] = [],
    didChangeText: Bool = false
  ) {
    self.state = state
    self.hostRequests = hostRequests
    self.didChangeText = didChangeText
  }
}

public enum VimError: Error, Equatable, Sendable {
  case invalidCount
  case invalidRegister
  case unsupportedNotation(String)
  case incompleteCommand(String)
  case macroRecursionLimit
  case invalidRegularExpression(String)
}

public struct VimKeyMapping: Hashable, Sendable {
  public var sequence: String
  public var command: String
  public var modes: Set<VimMode>?
  public var recursive: Bool

  public init(
    sequence: String,
    command: String,
    modes: Set<VimMode>? = nil,
    recursive: Bool = true
  ) {
    self.sequence = sequence
    self.command = command
    self.modes = modes
    self.recursive = recursive
  }
}

public struct VimKeyHandlingResult: Sendable {
  public var consumed: Bool
  public var awaitingMoreInput: Bool
  public var execution: VimExecutionResult?

  public init(
    consumed: Bool,
    awaitingMoreInput: Bool = false,
    execution: VimExecutionResult? = nil
  ) {
    self.consumed = consumed
    self.awaitingMoreInput = awaitingMoreInput
    self.execution = execution
  }
}
