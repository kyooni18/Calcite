import Foundation

extension VimEngine {
  @discardableResult
  public func executeNotation(_ notation: String) throws -> VimExecutionResult {
    let beforeText = state.text
    let tokens = Self.tokens(in: notation)
    var hostRequests: [VimHostRequest] = []
    var index = 0
    var count = 0
    var hasExplicitCount = false
    var selectedRegister: VimRegister = .unnamed
    var awaitingRegister = false
    var pendingOperator: (operation: VimOperator, count: Int, repeatToken: String)?
    var pendingTextObjectInner: Bool?
    var pendingOperatorG = false
    var pendingG = false
    var pendingZ = false
    var pendingFind: (forward: Bool, till: Bool, count: Int, operation: VimOperator?)?
    var pendingReplaceCount: Int?
    var pendingMark = false
    var pendingJump: Bool?
    var pendingMacroPlaybackCount: Int?
    var pendingMacroStart = false
    var pendingInsertRegister = false
    var pendingWindowCommandCount: Int?
    var pendingBracketCommand: (forward: Bool, count: Int)?

    func effectiveCount() -> Int { max(1, count) }
    func resetCommandPrefix() {
      count = 0
      hasExplicitCount = false
      selectedRegister = .unnamed
    }
    func executeAction(_ action: VimAction, count actionCount: Int? = nil) throws {
      let result = try execute(
        action,
        count: actionCount ?? effectiveCount(),
        register: selectedRegister
      )
      hostRequests += result.hostRequests
      resetCommandPrefix()
    }

    while index < tokens.count {
      let token = tokens[index]
      index += 1
      let lowerToken = token.lowercased()

      if state.mode == .insert || state.mode == .replace {
        if pendingInsertRegister {
          guard let register = Self.register(for: token) else {
            throw VimError.invalidRegister
          }
          hostRequests += try execute(.insertRegister(register)).hostRequests
          pendingInsertRegister = false
          continue
        }

        switch lowerToken {
        case "<esc>", "<c-[>", "<c-c>":
          hostRequests += try execute(.escape).hostRequests
        case "<cr>", "<enter>":
          hostRequests += try execute(.insertNewline).hostRequests
        case "<bs>", "<c-h>":
          hostRequests += try execute(.deleteBeforeCursor).hostRequests
        case "<c-w>":
          hostRequests += try execute(.deleteWordBeforeCursor).hostRequests
        case "<c-u>":
          hostRequests += try execute(.deleteToLineStart).hostRequests
        case "<tab>":
          hostRequests += try execute(.insert("\t")).hostRequests
        case "<left>":
          hostRequests += try execute(.move(.left)).hostRequests
        case "<right>":
          hostRequests += try execute(.move(.right)).hostRequests
        case "<up>":
          hostRequests += try execute(.move(.up)).hostRequests
        case "<down>":
          hostRequests += try execute(.move(.down)).hostRequests
        case "<home>":
          hostRequests += try execute(.move(.lineStart)).hostRequests
        case "<end>":
          hostRequests += try execute(.move(.lineContentEnd)).hostRequests
        case "<del>":
          hostRequests += try execute(.deleteCharacter).hostRequests
        case "<pageup>":
          hostRequests += try execute(.move(.pageUp)).hostRequests
        case "<pagedown>":
          hostRequests += try execute(.move(.pageDown)).hostRequests
        case "<c-r>":
          pendingInsertRegister = true
        default:
          guard !token.hasPrefix("<") else {
            throw VimError.unsupportedNotation(token)
          }
          hostRequests += try execute(.insert(token)).hostRequests
        }
        continue
      }

      if awaitingRegister {
        guard let register = Self.register(for: token) else { throw VimError.invalidRegister }
        selectedRegister = register
        awaitingRegister = false
        continue
      }

      if let windowCount = pendingWindowCommandCount {
        pendingWindowCommandCount = nil
        let request: VimHostRequest?
        switch token {
        case "h", "<Left>": request = .custom("section-left")
        case "j", "<Down>": request = .custom("section-down")
        case "k", "<Up>": request = .custom("section-up")
        case "l", "<Right>", "w": request = .custom("section-right")
        case "W": request = .custom("section-left")
        case "s", "S": request = .split(horizontal: true)
        case "v": request = .split(horizontal: false)
        case "c", "q": request = .closeWindow
        case "n": request = .newTab
        case "t": request = .custom("section-up")
        case "b": request = .custom("section-down")
        default: request = nil
        }
        guard let request else { throw VimError.unsupportedNotation("<C-w>\(token)") }
        for _ in 0..<windowCount { hostRequests += try execute(.host(request)).hostRequests }
        resetCommandPrefix()
        continue
      }

      if let bracket = pendingBracketCommand {
        pendingBracketCommand = nil
        let request: VimHostRequest
        switch token {
        case "d", "c":
          request = .custom(bracket.forward ? "next-diagnostic" : "previous-diagnostic")
        default:
          throw VimError.unsupportedNotation("\(bracket.forward ? "]" : "[")\(token)")
        }
        for _ in 0..<bracket.count { hostRequests += try execute(.host(request)).hostRequests }
        resetCommandPrefix()
        continue
      }

      if let replaceCount = pendingReplaceCount {
        guard let character = token.first, !token.hasPrefix("<") else {
          throw VimError.unsupportedNotation(token)
        }
        hostRequests += try execute(
          .replaceCharacter(character),
          count: replaceCount,
          register: selectedRegister
        ).hostRequests
        pendingReplaceCount = nil
        resetCommandPrefix()
        continue
      }

      if pendingMark {
        guard let character = token.first, token.count == 1 else {
          throw VimError.unsupportedNotation(token)
        }
        hostRequests += try execute(.setMark(character)).hostRequests
        pendingMark = false
        resetCommandPrefix()
        continue
      }

      if let linewise = pendingJump {
        guard let character = token.first, token.count == 1 else {
          throw VimError.unsupportedNotation(token)
        }
        hostRequests += try execute(.jumpToMark(character, linewise: linewise)).hostRequests
        pendingJump = nil
        resetCommandPrefix()
        continue
      }

      if let macroCount = pendingMacroPlaybackCount {
        guard let character = token.first, token.count == 1 else {
          throw VimError.unsupportedNotation(token)
        }
        if token == "@" {
          hostRequests += try execute(.playLastMacro, count: macroCount).hostRequests
        } else {
          hostRequests += try execute(.playMacro(character), count: macroCount).hostRequests
        }
        pendingMacroPlaybackCount = nil
        resetCommandPrefix()
        continue
      }

      if pendingMacroStart {
        guard let character = token.first, token.count == 1 else {
          throw VimError.unsupportedNotation(token)
        }
        hostRequests += try execute(.startMacro(character)).hostRequests
        pendingMacroStart = false
        resetCommandPrefix()
        continue
      }

      if let activeFind = pendingFind {
        guard let character = token.first, token.count == 1 else {
          throw VimError.unsupportedNotation(token)
        }
        let motion: VimMotion
        switch (activeFind.forward, activeFind.till) {
        case (true, false): motion = .findForward(character)
        case (false, false): motion = .findBackward(character)
        case (true, true): motion = .tillForward(character)
        case (false, true): motion = .tillBackward(character)
        }
        if let operation = activeFind.operation {
          hostRequests += try execute(
            .operatorMotion(operation, motion),
            count: activeFind.count,
            register: selectedRegister
          ).hostRequests
        } else {
          hostRequests += try execute(.move(motion), count: activeFind.count).hostRequests
        }
        pendingFind = nil
        resetCommandPrefix()
        continue
      }

      if pendingOperatorG, let pending = pendingOperator {
        pendingOperatorG = false
        let suffixCount = effectiveCount()
        count = 0
        let motion: VimMotion?
        switch token {
        case "g": motion = .documentStart
        case "e": motion = .wordEndBackward
        case "E": motion = .bigWordEndBackward
        default: motion = nil
        }
        guard let motion else { throw VimError.unsupportedNotation("g\(token)") }
        let total = pending.count * suffixCount
        pendingOperator = nil
        pendingTextObjectInner = nil
        hostRequests += try execute(
          .operatorMotion(pending.operation, motion),
          count: total,
          register: selectedRegister
        ).hostRequests
        resetCommandPrefix()
        continue
      }

      if let pending = pendingOperator {
        if pendingTextObjectInner == nil, token == "i" || token == "a" {
          pendingTextObjectInner = token == "i"
          continue
        }

        if token.count == 1, let digit = Int(token) {
          count = count * 10 + digit
          continue
        }

        if token == "g" {
          pendingOperatorG = true
          continue
        }

        if ["f", "F", "t", "T"].contains(token) {
          let suffixCount = effectiveCount()
          count = 0
          pendingFind = (
            forward: token == "f" || token == "t",
            till: token == "t" || token == "T",
            count: pending.count * suffixCount,
            operation: pending.operation
          )
          pendingOperator = nil
          pendingTextObjectInner = nil
          continue
        }

        let suffixCount = effectiveCount()
        count = 0
        let total = pending.count * suffixCount
        pendingOperator = nil

        if let inner = pendingTextObjectInner {
          pendingTextObjectInner = nil
          guard let object = Self.textObject(for: token) else {
            throw VimError.unsupportedNotation("\(inner ? "i" : "a")\(token)")
          }
          hostRequests += try execute(
            .operatorTextObject(pending.operation, object, inner: inner),
            count: total,
            register: selectedRegister
          ).hostRequests
          resetCommandPrefix()
          continue
        }

        if token == pending.repeatToken {
          hostRequests += try execute(
            .operatorLine(pending.operation),
            count: total,
            register: selectedRegister
          ).hostRequests
          resetCommandPrefix()
          continue
        }

        guard let motion = Self.motion(for: token) else {
          throw VimError.incompleteCommand("operator + \(token)")
        }
        hostRequests += try execute(
          .operatorMotion(pending.operation, motion),
          count: total,
          register: selectedRegister
        ).hostRequests
        resetCommandPrefix()
        continue
      }

      if pendingG {
        pendingG = false
        let commandCount = effectiveCount()
        switch token {
        case "g": try executeAction(.move(.documentStart), count: commandCount)
        case "e": try executeAction(.move(.wordEndBackward), count: commandCount)
        case "E": try executeAction(.move(.bigWordEndBackward), count: commandCount)
        case "j": try executeAction(.move(.down), count: commandCount)
        case "k": try executeAction(.move(.up), count: commandCount)
        case "0": try executeAction(.move(.lineStart), count: commandCount)
        case "$": try executeAction(.move(.lineEnd), count: commandCount)
        case "J": try executeAction(.joinLinesWithoutSpace, count: commandCount)
        case "v": try executeAction(.reselectVisual, count: 1)
        case "d": try executeAction(.host(.definition), count: 1)
        case "D": try executeAction(.host(.declaration), count: 1)
        case "r": try executeAction(.host(.references), count: 1)
        case "~":
          pendingOperator = (.swapCase, commandCount, "~")
          count = 0
        case "u":
          pendingOperator = (.lowercase, commandCount, "u")
          count = 0
        case "U":
          pendingOperator = (.uppercase, commandCount, "U")
          count = 0
        case "q":
          pendingOperator = (.format, commandCount, "q")
          count = 0
        case "t":
          if hasExplicitCount {
            try executeAction(.host(.switchBuffer(commandCount)), count: 1)
          } else {
            try executeAction(.host(.nextTab), count: 1)
          }
        case "T":
          for _ in 0..<commandCount {
            hostRequests += try execute(.host(.previousTab)).hostRequests
          }
          resetCommandPrefix()
        default:
          throw VimError.unsupportedNotation("g\(token)")
        }
        continue
      }

      if pendingZ {
        pendingZ = false
        switch token {
        case "Z": hostRequests += try execute(.host(.writeAndQuit)).hostRequests
        case "Q": hostRequests += try execute(.host(.custom("force-quit"))).hostRequests
        default: throw VimError.unsupportedNotation("Z\(token)")
        }
        resetCommandPrefix()
        continue
      }

      if token == "\"" {
        awaitingRegister = true
        continue
      }

      if token.count == 1, let digit = Int(token), !(token == "0" && count == 0) {
        count = count * 10 + digit
        hasExplicitCount = true
        continue
      }

      if state.mode.isVisual {
        let visualOperation: VimOperator?
        switch token {
        case "d", "x": visualOperation = .delete
        case "c", "s": visualOperation = .change
        case "y": visualOperation = .yank
        case ">": visualOperation = .indent
        case "<": visualOperation = .outdent
        case "U": visualOperation = .uppercase
        case "u": visualOperation = .lowercase
        case "~": visualOperation = .swapCase
        case "=": visualOperation = .format
        default: visualOperation = nil
        }
        if let visualOperation {
          try executeAction(.operatorSelection(visualOperation))
          continue
        }
        if token == "o" || token == "O" {
          try executeAction(.switchVisualEndpoint, count: 1)
          continue
        }
      }

      let commandCount = effectiveCount()
      switch token {
      case "h", "<Left>": try executeAction(.move(.left), count: commandCount)
      case "j", "<Down>": try executeAction(.move(.down), count: commandCount)
      case "k", "<Up>": try executeAction(.move(.up), count: commandCount)
      case "l", "<Right>": try executeAction(.move(.right), count: commandCount)
      case "w": try executeAction(.move(.wordForward), count: commandCount)
      case "W": try executeAction(.move(.bigWordForward), count: commandCount)
      case "b": try executeAction(.move(.wordBackward), count: commandCount)
      case "B": try executeAction(.move(.bigWordBackward), count: commandCount)
      case "e": try executeAction(.move(.wordEnd), count: commandCount)
      case "E": try executeAction(.move(.bigWordEnd), count: commandCount)
      case "0", "<Home>": try executeAction(.move(.lineStart), count: 1)
      case "^": try executeAction(.move(.firstNonBlank), count: 1)
      case "$", "<End>": try executeAction(.move(.lineEnd), count: commandCount)
      case "+", "<CR>": try executeAction(.move(.nextLineFirstNonBlank), count: commandCount)
      case "-": try executeAction(.move(.previousLineFirstNonBlank), count: commandCount)
      case "_": try executeAction(.move(.currentLineFirstNonBlank), count: commandCount)
      case "|": try executeAction(.move(.column(commandCount)), count: 1)
      case "{": try executeAction(.move(.paragraphBackward), count: commandCount)
      case "}": try executeAction(.move(.paragraphForward), count: commandCount)
      case "(": try executeAction(.move(.sentenceBackward), count: commandCount)
      case ")": try executeAction(.move(.sentenceForward), count: commandCount)
      case "G":
        if hasExplicitCount {
          try executeAction(.move(.line(commandCount)), count: 1)
        } else {
          try executeAction(.move(.documentEnd), count: 1)
        }
      case "H": try executeAction(.move(.screenTop), count: commandCount)
      case "M": try executeAction(.move(.screenMiddle), count: commandCount)
      case "L": try executeAction(.move(.screenBottom), count: commandCount)
      case "%": try executeAction(.move(.matchingPair), count: commandCount)
      case ";": try executeAction(.move(.repeatFind(reverse: false)), count: commandCount)
      case ",": try executeAction(.move(.repeatFind(reverse: true)), count: commandCount)
      case "<C-b>", "<PageUp>": try executeAction(.move(.pageUp), count: commandCount)
      case "<C-f>", "<PageDown>": try executeAction(.move(.pageDown), count: commandCount)
      case "<C-u>": try executeAction(.move(.halfPageUp), count: commandCount)
      case "<C-d>": try executeAction(.move(.halfPageDown), count: commandCount)
      case "<C-e>": try executeAction(.host(.scroll(lines: commandCount)), count: 1)
      case "<C-y>": try executeAction(.host(.scroll(lines: -commandCount)), count: 1)

      case "f", "F", "t", "T":
        pendingFind = (
          forward: token == "f" || token == "t",
          till: token == "t" || token == "T",
          count: commandCount,
          operation: nil
        )
        count = 0

      case "r":
        pendingReplaceCount = commandCount
        count = 0

      case "i": try executeAction(.enterInsert, count: 1)
      case "a": try executeAction(.enterInsertAfterCursor, count: 1)
      case "I": try executeAction(.enterInsertAtLineStart, count: 1)
      case "A": try executeAction(.enterInsertAtLineEnd, count: 1)
      case "o": try executeAction(.openLineBelow, count: commandCount)
      case "O": try executeAction(.openLineAbove, count: commandCount)
      case "R": try executeAction(.enterReplace, count: 1)
      case "v": try executeAction(.enterVisualCharacter, count: 1)
      case "V": try executeAction(.enterVisualLine, count: 1)
      case "<C-v>", "<C-q>": try executeAction(.enterVisualBlock, count: 1)
      case "x", "<Del>": try executeAction(.deleteCharacter, count: commandCount)
      case "X": try executeAction(.deleteBeforeCursor, count: commandCount)
      case "s": try executeAction(.substituteCharacter, count: commandCount)
      case "S": try executeAction(.operatorLine(.change), count: commandCount)
      case "D": try executeAction(.operatorMotion(.delete, .lineEnd), count: commandCount)
      case "C": try executeAction(.operatorMotion(.change, .lineEnd), count: commandCount)
      case "Y": try executeAction(.operatorLine(.yank), count: commandCount)
      case "J": try executeAction(.joinLines, count: commandCount)
      case "~": try executeAction(.toggleCaseCharacter, count: commandCount)
      case "u": try executeAction(.undo, count: commandCount)
      case "<C-r>": try executeAction(.redo, count: commandCount)
      case ".": try executeAction(.repeatLastChange, count: commandCount)
      case "p": try executeAction(.pasteAfter, count: commandCount)
      case "P": try executeAction(.pasteBefore, count: commandCount)
      case "n": try executeAction(.nextSearch, count: commandCount)
      case "N": try executeAction(.previousSearch, count: commandCount)
      case "*": try executeAction(.searchWordUnderCursor(forward: true), count: commandCount)
      case "#": try executeAction(.searchWordUnderCursor(forward: false), count: commandCount)
      case "K": try executeAction(.host(.hover), count: 1)
      case "<C-]>": try executeAction(.host(.definition), count: 1)
      case "<C-n>": try executeAction(.host(.completion), count: 1)
      case "<C-a>": try executeAction(.adjustNumber(1), count: commandCount)
      case "<C-x>": try executeAction(.adjustNumber(-1), count: commandCount)
      case "<C-w>":
        pendingWindowCommandCount = commandCount
        count = 0
      case "[":
        pendingBracketCommand = (forward: false, count: commandCount)
        count = 0
      case "]":
        pendingBracketCommand = (forward: true, count: commandCount)
        count = 0

      case "m":
        pendingMark = true
        count = 0
      case "'":
        pendingJump = true
        count = 0
      case "`":
        pendingJump = false
        count = 0
      case "@":
        pendingMacroPlaybackCount = commandCount
        count = 0
      case "q":
        if isRecordingMacro {
          try executeAction(.stopMacro, count: 1)
        } else {
          pendingMacroStart = true
          count = 0
        }
      case "g":
        pendingG = true
        count = commandCount
      case "Z":
        pendingZ = true
        count = 0

      case "d":
        pendingOperator = (.delete, commandCount, "d")
        count = 0
      case "c":
        pendingOperator = (.change, commandCount, "c")
        count = 0
      case "y":
        pendingOperator = (.yank, commandCount, "y")
        count = 0
      case ">":
        pendingOperator = (.indent, commandCount, ">")
        count = 0
      case "<":
        pendingOperator = (.outdent, commandCount, "<")
        count = 0
      case "=":
        pendingOperator = (.format, commandCount, "=")
        count = 0

      case "<Esc>": try executeAction(.escape, count: 1)
      default:
        if token == leader {
          let remaining = tokens[index...].joined()
          hostRequests += try execute(.leader(remaining)).hostRequests
          index = tokens.count
          resetCommandPrefix()
        } else {
          throw VimError.unsupportedNotation(token)
        }
      }
    }

    if awaitingRegister || pendingOperator != nil || pendingTextObjectInner != nil
      || pendingOperatorG || pendingG || pendingZ || pendingFind != nil
      || pendingReplaceCount != nil || pendingMark || pendingJump != nil
      || pendingMacroPlaybackCount != nil || pendingMacroStart || pendingInsertRegister
      || pendingWindowCommandCount != nil || pendingBracketCommand != nil || count != 0
    {
      throw VimError.incompleteCommand(notation)
    }

    return VimExecutionResult(
      state: state,
      hostRequests: hostRequests,
      didChangeText: beforeText != state.text
    )
  }

  private static func motion(for token: String) -> VimMotion? {
    switch token {
    case "h": return .left
    case "j": return .down
    case "k": return .up
    case "l": return .right
    case "w": return .wordForward
    case "W": return .bigWordForward
    case "b": return .wordBackward
    case "B": return .bigWordBackward
    case "e": return .wordEnd
    case "E": return .bigWordEnd
    case "0": return .lineStart
    case "^": return .firstNonBlank
    case "$": return .lineEnd
    case "<End>": return .lineEnd
    case "+": return .nextLineFirstNonBlank
    case "-": return .previousLineFirstNonBlank
    case "_": return .currentLineFirstNonBlank
    case "{": return .paragraphBackward
    case "}": return .paragraphForward
    case "(": return .sentenceBackward
    case ")": return .sentenceForward
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

  static func register(for token: String) -> VimRegister? {
    guard token.count == 1, let character = token.first else { return nil }
    switch character {
    case "\"": return .unnamed
    case "-": return .smallDelete
    case "_": return .blackHole
    case "+", "*": return .clipboard
    case "0"..."9": return Int(String(character)).map(VimRegister.numbered)
    default:
      if character.isLetter { return .named(character) }
      return nil
    }
  }

  static func tokens(in notation: String) -> [String] {
    var values: [String] = []
    var index = notation.startIndex
    while index < notation.endIndex {
      if notation[index] == "<", let end = notation[index...].firstIndex(of: ">") {
        values.append(normalizeSpecialToken(String(notation[index...end])))
        index = notation.index(after: end)
      } else {
        values.append(String(notation[index]))
        index = notation.index(after: index)
      }
    }
    return values
  }

  private static func normalizeSpecialToken(_ token: String) -> String {
    let lower = token.lowercased()
    switch lower {
    case "<esc>": return "<Esc>"
    case "<cr>", "<enter>": return "<CR>"
    case "<bs>", "<backspace>": return "<BS>"
    case "<del>", "<delete>": return "<Del>"
    case "<left>": return "<Left>"
    case "<right>": return "<Right>"
    case "<up>": return "<Up>"
    case "<down>": return "<Down>"
    case "<home>": return "<Home>"
    case "<end>": return "<End>"
    case "<pageup>": return "<PageUp>"
    case "<pagedown>": return "<PageDown>"
    case "<tab>": return "<Tab>"
    default:
      if lower.hasPrefix("<c-") {
        return "<C-" + String(lower.dropFirst(3).dropLast()) + ">"
      }
      return token
    }
  }
}
