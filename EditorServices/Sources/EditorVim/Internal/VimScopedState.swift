import Foundation

/// State shared by every Vim window in one Calcite window/session.
///
/// The storage intentionally remains internal. The public `VimEngine` API keeps
/// constructing isolated state, while Calcite uses `VimSessionCoordinator` to
/// opt into Vim-compatible global/buffer/window ownership.
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

/// State shared by all windows displaying the same Vim buffer.
final class VimBufferStateStorage: @unchecked Sendable {
  let undoTree = VimUndoTree()
  var marks: [Character: Int] = [:]
  var changePositions: [Int] = []
  var lastInsertedText = ""
  var keywordOptions = VimKeywordOptions()
  var textWidth = 0
  var tabWidth: Int
  var authoritativeText: String

  init(text: String, tabWidth: Int) {
    self.authoritativeText = text
    self.tabWidth = max(1, tabWidth)
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
