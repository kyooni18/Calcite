import Foundation

extension VimEngine {
  func executeEx(_ raw: String) throws -> [VimHostRequest] {
    let command = raw.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
    if command.hasPrefix("!") { return [.shell(String(command.dropFirst()))] }
    if try executeSubstitute(command) { return [] }

    let parsed = VimExParser.parse(command)
    let name = parsed.name
    let arguments = parsed.arguments

    if name.isEmpty, let range = parsed.range, let line = Int(range) {
      state.cursor = firstNonBlank(at: lineOffset(line))
      normalizeCursorForMode()
      return []
    }

    if VimExParser.matches(name, command: "write") {
      return parsed.bang ? [.custom("force-write")] : [.write]
    }
    if VimExParser.matches(name, command: "quit") {
      return parsed.bang ? [.custom("force-quit")] : [.quit]
    }
    if name == "wq" || VimExParser.matches(name, command: "xit") {
      return [.writeAndQuit]
    }
    if name == "wa" || name == "wall" { return [.custom("save-all")] }

    if name == "bn" || VimExParser.matches(name, command: "bnext", minimum: 2)
      || VimExParser.matches(name, command: "tabnext", minimum: 4)
    {
      return [.nextTab]
    }
    if name == "bp" || VimExParser.matches(name, command: "bprevious", minimum: 2)
      || VimExParser.matches(name, command: "tabprevious", minimum: 4)
    {
      return [.previousTab]
    }

    if VimExParser.matches(name, command: "edit") {
      return arguments.isEmpty ? [.custom("reload-file")] : [.openFile(arguments)]
    }
    if VimExParser.matches(name, command: "buffer") {
      if let number = Int(arguments) { return [.switchBuffer(number)] }
    }
    if name == "sp" || VimExParser.matches(name, command: "split", minimum: 2) {
      return [.split(horizontal: true)]
    }
    if name == "vs" || VimExParser.matches(name, command: "vsplit", minimum: 2) {
      return [.split(horizontal: false)]
    }
    if VimExParser.matches(name, command: "tabnew", minimum: 4) { return [.newTab] }
    if VimExParser.matches(name, command: "tabclose", minimum: 4) { return [.closeTab] }

    if VimExParser.matches(name, command: "delete") {
      let range = exLineRange(parsed.range)
      performMutation(action: .command(command), count: 1, register: .unnamed) {
        apply(.delete, range: range, register: .unnamed, linewise: true)
      }
      normalizeCursorForMode()
      return []
    }
    if VimExParser.matches(name, command: "yank") {
      apply(.yank, range: exLineRange(parsed.range), register: .unnamed, linewise: true)
      return []
    }
    if VimExParser.matches(name, command: "put", minimum: 2) {
      if let range = parsed.range {
        state.cursor = lineOffset(exLineNumber(range))
      }
      performMutation(action: .command(command), count: 1, register: .unnamed) {
        paste(registerValue(for: .unnamed), after: true, count: 1)
      }
      normalizeCursorForMode()
      return []
    }
    if name == "t" || VimExParser.matches(name, command: "copy", minimum: 2) {
      let sourceRange = exLineRange(parsed.range)
      let destinationLine = exLineNumber(arguments)
      let destinationOffset = lineOffset(destinationLine)
      let insertion = lineEndIncludingNewline(at: destinationOffset)
      var payload = substring(sourceRange)
      if !payload.hasSuffix("\n"), !payload.hasSuffix("\r") { payload.append("\n") }
      let prefix =
        insertion == state.text.utf16.count && !lineHasTerminator(at: destinationOffset)
        ? "\n" : ""
      performMutation(action: .command(command), count: 1, register: .unnamed) {
        replace(range: insertion..<insertion, with: prefix + payload)
      }
      state.cursor = firstNonBlank(at: insertion + prefix.utf16.count)
      normalizeCursorForMode()
      return []
    }
    if VimExParser.matches(name, command: "move", minimum: 1) {
      let sourceRange = exLineRange(parsed.range)
      let destinationLine = exLineNumber(arguments)
      let destinationOffset = lineOffset(destinationLine)
      let originalInsertion = lineEndIncludingNewline(at: destinationOffset)
      guard originalInsertion < sourceRange.lowerBound || originalInsertion > sourceRange.upperBound
      else { return [] }

      var payload = substring(sourceRange)
      if !payload.hasSuffix("\n"), !payload.hasSuffix("\r") { payload.append("\n") }
      let insertionAfterRemoval =
        originalInsertion > sourceRange.upperBound
        ? originalInsertion - sourceRange.count
        : originalInsertion
      performMutation(action: .command(command), count: 1, register: .unnamed) {
        replace(range: sourceRange, with: "")
        let safeInsertion = min(insertionAfterRemoval, state.text.utf16.count)
        let needsPrefix =
          safeInsertion == state.text.utf16.count
          && safeInsertion > 0
          && !state.text.hasSuffix("\n")
          && !state.text.hasSuffix("\r")
        replace(
          range: safeInsertion..<safeInsertion,
          with: (needsPrefix ? "\n" : "") + payload
        )
      }
      state.cursor = firstNonBlank(at: min(insertionAfterRemoval, state.text.utf16.count))
      normalizeCursorForMode()
      return []
    }

    if VimExParser.matches(name, command: "join") {
      let range = exLineRange(parsed.range)
      let startLine = lineStart(at: range.lowerBound)
      var joins = 1
      var cursor = lineEndIncludingNewline(at: startLine)
      while cursor < range.upperBound {
        joins += 1
        let next = lineEndIncludingNewline(at: cursor)
        guard next > cursor else { break }
        cursor = next
      }
      state.cursor = startLine
      performMutation(action: .command(command), count: joins, register: .unnamed) {
        for _ in 1..<joins { joinLine() }
      }
      normalizeCursorForMode()
      return []
    }
    if VimExParser.matches(name, command: "normal") {
      guard !arguments.isEmpty else { return [] }
      _ = try executeNotation(arguments)
      return []
    }
    if VimExParser.matches(name, command: "set") {
      applySetOptions(arguments)
      return []
    }

    if name == "format" { return [.format] }
    if ["build", "make", "run", "test", "check", "debug", "terminal", "problems"].contains(name) {
      return [.custom(name == "make" ? "build" : name)]
    }
    if name == "noh" || name == "nohlsearch" { return [] }
    return [.custom(command)]
  }

  func applySetOptions(_ arguments: String) {
    for option in arguments.split(whereSeparator: \.isWhitespace).map(String.init) {
      switch option.lowercased() {
      case "ic", "ignorecase": searchIgnoreCase = true
      case "noic", "noignorecase": searchIgnoreCase = false
      case "scs", "smartcase": searchSmartCase = true
      case "noscs", "nosmartcase": searchSmartCase = false
      case "ws", "wrapscan": searchWrap = true
      case "nows", "nowrapscan": searchWrap = false
      default: break
      }
    }
  }

  func exLineRange(_ expression: String?) -> Range<Int> {
    guard let expression, !expression.isEmpty else {
      return lineStart(at: state.cursor)..<lineEndIncludingNewline(at: state.cursor)
    }
    if expression == "%" { return 0..<state.text.utf16.count }

    let separator = expression.firstIndex(where: { $0 == "," || $0 == ";" })
    let firstAddress: String
    let secondAddress: String?
    if let separator {
      firstAddress = String(expression[..<separator])
      secondAddress = String(expression[expression.index(after: separator)...])
    } else {
      firstAddress = expression
      secondAddress = nil
    }

    let firstLine = exLineNumber(firstAddress)
    let lastLine = secondAddress.map { exLineNumber($0, currentLine: firstLine) } ?? firstLine
    let lowerLine = min(firstLine, lastLine)
    let upperLine = max(firstLine, lastLine)
    let lower = lineStart(at: lineOffset(lowerLine))
    let upper = lineEndIncludingNewline(at: lineOffset(upperLine))
    return lower..<max(lower, upper)
  }

  func exLineNumber(_ rawAddress: String, currentLine: Int? = nil) -> Int {
    var address = rawAddress.trimmingCharacters(in: .whitespaces)
    let current = currentLine ?? currentLineNumber()
    let total = totalLineCount()
    guard !address.isEmpty else { return current }

    var base = current
    if address.first == "." {
      address.removeFirst()
    } else if address.first == "$" {
      base = total
      address.removeFirst()
    } else if address.first == "'" || address.first == "`" {
      address.removeFirst()
      if let name = address.first {
        address.removeFirst()
        if let position = marks[name] {
          lineIndex.synchronize(with: state.text)
          base = lineIndex.oneBasedLine(
            containing: position,
            textLength: state.text.utf16.count
          )
        }
      }
    } else {
      let digits = address.prefix(while: \.isNumber)
      if !digits.isEmpty {
        base = Int(digits) ?? current
        address.removeFirst(digits.count)
      }
    }

    while !address.isEmpty {
      let sign: Int
      if address.first == "+" {
        sign = 1
      } else if address.first == "-" {
        sign = -1
      } else {
        break
      }
      address.removeFirst()
      let digits = address.prefix(while: \.isNumber)
      let amount = digits.isEmpty ? 1 : (Int(digits) ?? 1)
      address.removeFirst(digits.count)
      base += sign * amount
    }
    return max(1, min(total, base))
  }

  func currentLineNumber() -> Int {
    lineIndex.synchronize(with: state.text)
    return lineIndex.oneBasedLine(
      containing: state.cursor,
      textLength: state.text.utf16.count
    )
  }

  func totalLineCount() -> Int {
    lineIndex.synchronize(with: state.text)
    return lineIndex.lineCount
  }

  func executeSubstitute(_ command: String) throws -> Bool {
    let parsed = VimExParser.parse(command)
    guard
      parsed.name == "s"
        || VimExParser.matches(
          parsed.name,
          command: "substitute",
          minimum: 1
        )
    else { return false }

    guard let delimiter = parsed.arguments.first else {
      throw VimError.incompleteCommand(command)
    }
    let body = parsed.arguments.dropFirst()
    let components = splitSubstitute(body, delimiter: delimiter)
    guard components.count >= 2 else { throw VimError.incompleteCommand(command) }

    let pattern = components[0].isEmpty ? (lastSearch?.0 ?? "") : components[0]
    guard !pattern.isEmpty else { throw VimError.incompleteCommand(command) }
    let rawReplacement =
      components[1].isEmpty && components.count > 1
      ? components[1]
      : components[1]
    let replacement = rawReplacement == "~" ? lastSubstituteReplacement : rawReplacement
    let flags = components.count > 2 ? components[2] : ""
    let caseInsensitive =
      flags.contains("i")
      || (!flags.contains("I") && searchIgnoreCase
        && !(searchSmartCase
          && pattern.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }))
    let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
      throw VimError.unsupportedNotation(command)
    }

    let target = exLineRange(parsed.range)
    let targetText = substring(target)
    let targetNS = targetText as NSString
    let fullRange = NSRange(location: 0, length: targetNS.length)
    let template = vimSubstituteTemplate(replacement)
    let replaced: String

    if flags.contains("g") {
      replaced = regex.stringByReplacingMatches(
        in: targetText,
        range: fullRange,
        withTemplate: template
      )
    } else {
      var output = ""
      var lineLocation = 0
      while lineLocation < targetNS.length {
        let line = targetNS.lineRange(for: NSRange(location: lineLocation, length: 0))
        let lineText = targetNS.substring(with: line)
        let lineNS = lineText as NSString
        let lineRange = NSRange(location: 0, length: lineNS.length)
        if let match = regex.firstMatch(in: lineText, range: lineRange) {
          output += regex.stringByReplacingMatches(
            in: lineText,
            options: [],
            range: match.range,
            withTemplate: template
          )
        } else {
          output += lineText
        }
        lineLocation = NSMaxRange(line)
      }
      if targetNS.length == 0 { output = targetText }
      replaced = output
    }

    lastSearch = (pattern, true)
    registers[.named("/")] = VimRegisterValue(text: pattern, linewise: false)
    lastSubstituteReplacement = replacement
    guard replaced != targetText else { return true }
    performMutation(action: .command(command), count: 1, register: .unnamed) {
      replace(range: target, with: replaced)
    }
    return true
  }

  func vimSubstituteTemplate(_ replacement: String) -> String {
    var result = ""
    var escaped = false
    for character in replacement {
      if escaped {
        if let digit = character.wholeNumberValue {
          result += "$\(digit)"
        } else if character == "&" {
          result.append("&")
        } else {
          result.append("\\")
          result.append(character)
        }
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "&" {
        result += "$0"
      } else {
        result.append(character)
      }
    }
    if escaped { result.append("\\") }
    return result
  }

  func splitSubstitute(_ source: Substring, delimiter: Character) -> [String] {
    var result: [String] = []
    var current = ""
    var escaped = false
    for character in source {
      if escaped {
        if character != delimiter { current.append("\\") }
        current.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == delimiter {
        result.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    if escaped { current.append("\\") }
    result.append(current)
    return result
  }

  func search(_ query: String, forward: Bool) {
    guard !query.isEmpty else { return }
    let shouldIgnoreCase =
      searchIgnoreCase
      && !(searchSmartCase
        && query.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) })
    let options: NSRegularExpression.Options = shouldIgnoreCase ? [.caseInsensitive] : []
    let regex =
      (try? NSRegularExpression(pattern: query, options: options))
      ?? (try? NSRegularExpression(
        pattern: NSRegularExpression.escapedPattern(for: query),
        options: options
      ))
    guard let regex else { return }

    let length = state.text.utf16.count
    let fullRange = NSRange(location: 0, length: length)
    let matches = regex.matches(in: state.text, range: fullRange)
    guard !matches.isEmpty else { return }

    let destination: Int?
    if forward {
      let start = min(length, nextCharacterBoundary(from: state.cursor))
      destination =
        matches.first(where: { $0.range.location >= start })?.range.location
        ?? (searchWrap ? matches.first?.range.location : nil)
    } else {
      destination =
        matches.last(where: { $0.range.location < state.cursor })?.range.location
        ?? (searchWrap ? matches.last?.range.location : nil)
    }

    if let destination { state.cursor = destination }
    preferredColumn = nil
    normalizeCursorForMode()
    updateVisualSelection()
  }

  func wordUnderCursor() -> String? {
    let range = wordObjectRange(at: state.cursor, whole: false, inner: true)
    guard !range.isEmpty, wordClass(at: range.lowerBound, whole: false) == .keyword else {
      return nil
    }
    return substring(range)
  }
}
