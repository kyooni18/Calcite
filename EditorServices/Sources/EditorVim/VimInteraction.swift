import Foundation

/// Structured command-line state exposed to Calcite without coupling the engine
/// to AppKit or SwiftUI.
@_spi(Calcite)
public enum VimCommandLineKind: Hashable, Sendable {
  case command
  case searchForward
  case searchBackward
}

@_spi(Calcite)
public struct VimCommandLineSnapshot: Hashable, Sendable {
  public var kind: VimCommandLineKind
  public var prefix: String
  public var text: String
  public var cursorOffset: Int
  public var markedText: String
  public var markedSelection: Range<Int>
  public var historyPosition: Int?
  public var historyCount: Int

  public init(
    kind: VimCommandLineKind,
    prefix: String,
    text: String,
    cursorOffset: Int,
    markedText: String = "",
    markedSelection: Range<Int> = 0..<0,
    historyPosition: Int? = nil,
    historyCount: Int = 0
  ) {
    self.kind = kind
    self.prefix = prefix
    self.text = text
    self.cursorOffset = max(0, min(cursorOffset, text.count))
    self.markedText = markedText
    self.markedSelection = markedSelection
    self.historyPosition = historyPosition
    self.historyCount = max(0, historyCount)
  }
}

@_spi(Calcite)
public struct VimPendingCommandSnapshot: Hashable, Sendable {
  public var notation: String
  public var expectedInput: VimExpectedInput
  public var count: Int?
  public var registerName: Character?
  public var operatorName: String?
  public var prefix: String?
  public var isMappingPrefix: Bool

  public init(
    notation: String = "",
    expectedInput: VimExpectedInput = .command,
    count: Int? = nil,
    registerName: Character? = nil,
    operatorName: String? = nil,
    prefix: String? = nil,
    isMappingPrefix: Bool = false
  ) {
    self.notation = notation
    self.expectedInput = expectedInput
    self.count = count
    self.registerName = registerName
    self.operatorName = operatorName
    self.prefix = prefix
    self.isMappingPrefix = isMappingPrefix
  }
}

@_spi(Calcite)
public struct VimMacroSnapshot: Hashable, Sendable {
  public var recordingRegister: Character?
  public var lastPlayedRegister: Character?

  public init(recordingRegister: Character? = nil, lastPlayedRegister: Character? = nil) {
    self.recordingRegister = recordingRegister
    self.lastPlayedRegister = lastPlayedRegister
  }
}

@_spi(Calcite)
public enum VimMessageSeverity: Int, Hashable, Sendable {
  case information
  case warning
  case error
}

@_spi(Calcite)
public enum VimMessageLifetime: Hashable, Sendable {
  case untilNextInput
  case timed(milliseconds: Int)
  case persistent
}

@_spi(Calcite)
public struct VimMessage: Hashable, Sendable {
  public var text: String
  public var code: String?
  public var severity: VimMessageSeverity
  public var lifetime: VimMessageLifetime

  public init(
    text: String,
    code: String? = nil,
    severity: VimMessageSeverity = .information,
    lifetime: VimMessageLifetime = .untilNextInput
  ) {
    self.text = text
    self.code = code
    self.severity = severity
    self.lifetime = lifetime
  }
}

@_spi(Calcite)
public struct VimHistorySnapshot: Hashable, Sendable, Codable {
  public var commands: [String]
  public var searches: [String]

  public init(commands: [String] = [], searches: [String] = []) {
    self.commands = commands
    self.searches = searches
  }
}

@_spi(Calcite)
public struct VimInteractionSnapshot: Hashable, Sendable {
  public var mode: VimMode
  public var pendingCommand: VimPendingCommandSnapshot
  public var commandLine: VimCommandLineSnapshot?
  public var macro: VimMacroSnapshot
  public var isTemporaryNormal: Bool
  public var isComposingText: Bool
  public var history: VimHistorySnapshot
  public var visualSelection: VimVisualSelectionSnapshot?
  public var message: VimMessage?

  public init(
    mode: VimMode,
    pendingCommand: VimPendingCommandSnapshot = VimPendingCommandSnapshot(),
    commandLine: VimCommandLineSnapshot? = nil,
    macro: VimMacroSnapshot = VimMacroSnapshot(),
    isTemporaryNormal: Bool = false,
    isComposingText: Bool = false,
    history: VimHistorySnapshot = VimHistorySnapshot(),
    visualSelection: VimVisualSelectionSnapshot? = nil,
    message: VimMessage? = nil
  ) {
    self.mode = mode
    self.pendingCommand = pendingCommand
    self.commandLine = commandLine
    self.macro = macro
    self.isTemporaryNormal = isTemporaryNormal
    self.isComposingText = isComposingText
    self.history = history
    self.visualSelection = visualSelection
    self.message = message
  }
}
