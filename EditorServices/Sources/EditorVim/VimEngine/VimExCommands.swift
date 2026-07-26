import Foundation

private struct VimExRange {
  var startLine: Int
  var endLine: Int
}

extension VimEngine {
  func executeEx(_ raw: String) throws -> [VimHostRequest] {
    let commands = splitExCommands(raw)
    var hostRequests: [VimHostRequest] = []
    for item in commands {
      hostRequests += try executeSingleEx(item)
    }
    return hostRequests
  }

  private func executeSingleEx(_ raw: String) throws -> [VimHostRequest] {
    var command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while command.hasPrefix(":") { command.removeFirst() }
    command = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return [] }

    let parsed = parseExRange(command)
    let range = parsed.range
    command = parsed.command.trimmingCharacters(in: .whitespacesAndNewlines)

    if command.isEmpty, let range {
      state.cursor = buffer.firstNonBlank(at: buffer.offsetOfLine(range.endLine))
      normalizeCursorForCurrentMode()
      return []
    }
    if let line = Int(command) {
      state.cursor = buffer.firstNonBlank(at: buffer.offsetOfLine(max(1, line)))
      normalizeCursorForCurrentMode()
      return []
    }
    if command == "$" {
      state.cursor = buffer.normalDocumentEnd()
      return []
    }

    let name = commandName(command)
    let arguments = commandArguments(command, name: name)

    switch name {
    case "w", "write":
      return [.write]
    case "q", "quit":
      return [.quit]
    case "q!", "quit!":
      return [.custom("force-quit")]
    case "wq", "x", "xit", "exit":
      return [.writeAndQuit]
    case "wqa", "wqall":
      return [.custom("save-all"), .custom("quit-all")]
    case "qa", "qall":
      return [.custom("quit-all")]
    case "qa!", "qall!":
      return [.custom("force-quit-all")]
    case "wa", "wall":
      return [.custom("save-all")]

    case "e", "edit":
      return arguments.isEmpty ? [.custom("reload-file")] : [.openFile(arguments)]
    case "enew", "new":
      return [.newTab]
    case "find":
      return arguments.isEmpty ? [.custom("find-file")] : [.openFile(arguments)]

    case "bn", "bnext", "tabn", "tabnext":
      return [.nextTab]
    case "bp", "bprevious", "tabp", "tabprevious":
      return [.previousTab]
    case "b", "buffer":
      if let number = Int(arguments) { return [.switchBuffer(number)] }
      return [.custom(arguments.isEmpty ? "buffers" : "buffer:\(arguments)")]
    case "bd", "bdelete":
      return [.closeTab]
    case "tabnew", "tabe", "tabedit":
      return arguments.isEmpty ? [.newTab] : [.newTab, .openFile(arguments)]
    case "tabclose", "tabc":
      return [.closeTab]
    case "tabonly":
      return [.custom("close-other-tabs")]

    case "split", "sp":
      var requests: [VimHostRequest] = [.split(horizontal: true)]
      if !arguments.isEmpty { requests.append(.openFile(arguments)) }
      return requests
    case "vsplit", "vs":
      var requests: [VimHostRequest] = [.split(horizontal: false)]
      if !arguments.isEmpty { requests.append(.openFile(arguments)) }
      return requests
    case "close", "clo":
      return [.closeWindow]
    case "only":
      return [.custom("close-other-sections")]

    case "format", "fmt":
      return [.format]
    case "make", "build":
      return [.custom("build")]
    case "run", "test", "check", "debug", "terminal", "problems":
      return [.custom(name)]
    case "messages":
      return [.custom("logs")]

    case "noh", "nohl", "nohlsearch":
      return [.custom("clear-search-highlight")]
    case "set", "setlocal", "setglobal":
      return [.custom(arguments.isEmpty ? "show-vim-options" : "set:\(arguments)")]
    case "registers", "reg", "display":
      return [.custom("show-registers")]
    case "marks":
      return [.custom("show-marks")]
    case "jumps":
      return [.custom("show-jumps")]
    case "changes":
      return [.custom("show-changes")]

    case "undo", "u":
      _ = try execute(.undo)
      return []
    case "redo":
      _ = try execute(.redo)
      return []

    case "normal", "normal!":
      guard !arguments.isEmpty else { return [] }
      _ = try executeNotation(arguments)
      return []

    case "d", "delete":
      let target = exLineTarget(range)
      performTextMutation(
        VimRecordedStep(action: .command(raw), count: 1, register: .unnamed)
      ) {
        deleteTarget(target, register: .unnamed, enterInsert: false)
      }
      return []

    case "y", "yank":
      yankTarget(exLineTarget(range), register: .unnamed)
      return []

    case "put", "pu":
      let step = VimRecordedStep(action: .command(raw), count: 1, register: .unnamed)
      performTextMutation(step) {
        if let range {
          state.cursor = buffer.offsetOfLine(range.endLine)
        }
        paste(registers.value(for: .unnamed), after: true, count: 1)
      }
      return []

    case "j", "join":
      let step = VimRecordedStep(action: .command(raw), count: 1, register: .unnamed)
      performTextMutation(step) {
        let lineCount = range.map { max(1, $0.endLine - $0.startLine) } ?? 1
        if let range { state.cursor = buffer.offsetOfLine(range.startLine) }
        for _ in 0..<lineCount { joinLine(insertingSpace: true) }
      }
      return []

    default:
      if name == "s" || name == "substitute" || command.hasPrefix("s") {
        try executeSubstitute(command, range: range, raw: raw)
        return []
      }
      if command.hasPrefix("!") {
        return [.shell(String(command.dropFirst()))]
      }
      return [.custom(command)]
    }
  }

  private func executeSubstitute(
    _ command: String,
    range: VimExRange?,
    raw: String
  ) throws {
    let start: String.Index
    if command.hasPrefix("substitute") {
      start = command.index(command.startIndex, offsetBy: "substitute".count)
    } else if command.hasPrefix("s") {
      start = command.index(after: command.startIndex)
    } else {
      throw VimError.incompleteCommand(raw)
    }
    let remainder = String(command[start...]).trimmingCharacters(in: .whitespaces)
    guard let delimiter = remainder.first else { throw VimError.incompleteCommand(raw) }
    let pieces = splitSubstitute(remainder, delimiter: delimiter)
    guard pieces.count >= 3 else { throw VimError.incompleteCommand(raw) }

    let pattern = pieces[1]
    let replacement = convertVimReplacement(pieces[2])
    let flags = pieces.count > 3 ? pieces[3] : ""
    let options: NSRegularExpression.Options = flags.contains("i") ? [.caseInsensitive] : []
    let expression: NSRegularExpression
    do {
      expression = try NSRegularExpression(pattern: pattern, options: options)
    } catch {
      throw VimError.invalidRegularExpression(pattern)
    }

    let target = exCharacterRange(range)
    let nsRange = NSRange(location: target.lowerBound, length: target.count)
    let matchingOptions: NSRegularExpression.MatchingOptions = []
    let matches = expression.matches(in: state.text, options: matchingOptions, range: nsRange)
    guard !matches.isEmpty else { return }

    let global = flags.contains("g")
    let selectedMatches: [NSTextCheckingResult]
    if global {
      selectedMatches = matches
    } else {
      var firstPerLine: [Int: NSTextCheckingResult] = [:]
      for match in matches {
        let line = buffer.lineNumber(at: match.range.location)
        if firstPerLine[line] == nil { firstPerLine[line] = match }
      }
      selectedMatches = firstPerLine.keys.sorted().compactMap { firstPerLine[$0] }
    }

    let step = VimRecordedStep(action: .command(raw), count: 1, register: .unnamed)
    performTextMutation(step) {
      for match in selectedMatches.reversed() {
        let currentText = state.text
        let currentSource = currentText as NSString
        guard NSMaxRange(match.range) <= currentSource.length else { continue }
        let value = expression.replacementString(
          for: match,
          in: currentText,
          offset: 0,
          template: replacement
        )
        let currentBuffer = VimTextBuffer(currentText)
        let lowerIndex = currentBuffer.stringIndex(match.range.location)
        let upperIndex = currentBuffer.stringIndex(NSMaxRange(match.range))
        state.text.replaceSubrange(lowerIndex..<upperIndex, with: value)
        adjustTrackedPositions(
          replacing: match.range.location..<NSMaxRange(match.range),
          replacementLength: value.utf16.count,
          excludingCursor: true
        )
      }
      state.cursor = min(target.lowerBound, state.text.utf16.count)
    }
  }

  private func exLineTarget(_ range: VimExRange?) -> VimOperationTarget {
    let resolved =
      range
      ?? VimExRange(
        startLine: buffer.lineNumber(at: state.cursor),
        endLine: buffer.lineNumber(at: state.cursor)
      )
    let lower = buffer.offsetOfLine(resolved.startLine)
    let upper = buffer.lineFullEnd(at: buffer.offsetOfLine(resolved.endLine))
    return VimOperationTarget(ranges: [lower..<upper], kind: .linewise)
  }

  private func exCharacterRange(_ range: VimExRange?) -> Range<Int> {
    let target = exLineTarget(range)
    return target.ranges.first ?? state.cursor..<state.cursor
  }

  private func parseExRange(_ raw: String) -> (range: VimExRange?, command: String) {
    var input = raw[...]
    if input.first == "%" {
      input.removeFirst()
      let lastLine = max(1, buffer.lineNumber(at: buffer.length))
      return (VimExRange(startLine: 1, endLine: lastLine), String(input))
    }
    if input.hasPrefix("'<,'>") {
      input.removeFirst(5)
      if let selection = state.selection {
        return (
          VimExRange(
            startLine: buffer.lineNumber(at: selection.lowerBound),
            endLine: buffer.lineNumber(at: selection.upperBound)
          ),
          String(input)
        )
      }
    }

    guard let first = parseExAddress(&input) else { return (nil, raw) }
    var last = first
    if input.first == "," || input.first == ";" {
      input.removeFirst()
      last = parseExAddress(&input) ?? first
    }
    return (
      VimExRange(startLine: min(first, last), endLine: max(first, last)),
      String(input)
    )
  }

  private func parseExAddress(_ input: inout Substring) -> Int? {
    guard let first = input.first else { return nil }
    var value: Int
    if first == "." {
      input.removeFirst()
      value = buffer.lineNumber(at: state.cursor)
    } else if first == "$" {
      input.removeFirst()
      value = max(1, buffer.lineNumber(at: buffer.length))
    } else if first.isNumber {
      var digits = ""
      while let character = input.first, character.isNumber {
        digits.append(character)
        input.removeFirst()
      }
      guard let parsed = Int(digits) else { return nil }
      value = max(1, parsed)
    } else {
      return nil
    }

    while let sign = input.first, sign == "+" || sign == "-" {
      input.removeFirst()
      var digits = ""
      while let character = input.first, character.isNumber {
        digits.append(character)
        input.removeFirst()
      }
      let delta = Int(digits) ?? 1
      value += sign == "+" ? delta : -delta
    }
    return max(1, value)
  }

  private func commandName(_ command: String) -> String {
    if command.hasPrefix("s/") || command.hasPrefix("s#") || command.hasPrefix("s|") {
      return "s"
    }
    if command.hasPrefix("!") { return "!" }
    return command.prefix { !$0.isWhitespace }.lowercased()
  }

  private func commandArguments(_ command: String, name: String) -> String {
    guard command.count > name.count else { return "" }
    let index = command.index(command.startIndex, offsetBy: name.count)
    return command[index...].trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func splitExCommands(_ raw: String) -> [String] {
    var values: [String] = []
    var current = ""
    var escaped = false
    for character in raw {
      if character == "\\", !escaped {
        escaped = true
        current.append(character)
        continue
      }
      if character == "|", !escaped, !isSubstitutePipe(in: current) {
        values.append(current)
        current = ""
      } else {
        current.append(character)
      }
      escaped = false
    }
    if !current.isEmpty { values.append(current) }
    return values.isEmpty ? [raw] : values
  }

  private func isSubstitutePipe(in current: String) -> Bool {
    let parsed = parseExRange(current)
    var command = parsed.command.trimmingCharacters(in: .whitespacesAndNewlines)
    while command.hasPrefix(":") { command.removeFirst() }
    command = command.trimmingCharacters(in: .whitespacesAndNewlines)

    let prefix: String
    if command == "s" || command.hasPrefix("s|") {
      prefix = "s"
    } else if command == "substitute" || command.hasPrefix("substitute|") {
      prefix = "substitute"
    } else {
      return false
    }

    let suffix = command.dropFirst(prefix.count)
    var delimiterCount = 0
    var escaped = false
    for character in suffix {
      if character == "\\", !escaped {
        escaped = true
        continue
      }
      if character == "|", !escaped { delimiterCount += 1 }
      escaped = false
    }
    return delimiterCount < 3
  }

  private func splitSubstitute(_ raw: String, delimiter: Character) -> [String] {
    var values: [String] = []
    var current = ""
    var escaped = false
    for character in raw {
      if character == "\\", !escaped {
        escaped = true
        current.append(character)
        continue
      }
      if character == delimiter, !escaped {
        values.append(current)
        current = ""
      } else {
        current.append(character)
      }
      escaped = false
    }
    values.append(current)
    return values
  }

  private func convertVimReplacement(_ replacement: String) -> String {
    var result = replacement.replacingOccurrences(of: "&", with: "$0")
    for number in 1...9 {
      result = result.replacingOccurrences(of: "\\\(number)", with: "$\(number)")
    }
    return result
  }
}
