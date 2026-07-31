import Foundation

extension VimEngine {
  func executeEx(_ raw: String) throws -> [VimHostRequest] {
    let commands = VimExParser.splitCommands(raw)
    guard commands.count > 1 else {
      return try executeSingleEx(commands.first ?? raw)
    }

    return try executeGroupedExHistory {
      var requests: [VimHostRequest] = []
      for command in commands {
        requests.append(contentsOf: try executeSingleEx(command))
      }
      return requests
    }
  }

  private func executeSingleEx(_ raw: String) throws -> [VimHostRequest] {
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

    if name == "&" {
      return try repeatSubstitute(range: parsed.range, useLastSearch: false)
    }
    if name == "~" {
      return try repeatSubstitute(range: parsed.range, useLastSearch: true)
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

    if name == "bn" || VimExParser.matches(name, command: "bnext", minimum: 2) {
      return [.custom("vim-buffer-next")]
    }
    if name == "bp" || VimExParser.matches(name, command: "bprevious", minimum: 2) {
      return [.custom("vim-buffer-previous")]
    }
    if VimExParser.matches(name, command: "bfirst", minimum: 2) {
      return [.custom("vim-buffer-first")]
    }
    if VimExParser.matches(name, command: "blast", minimum: 2) {
      return [.custom("vim-buffer-last")]
    }
    if VimExParser.matches(name, command: "tabnext", minimum: 4) { return [.nextTab] }
    if VimExParser.matches(name, command: "tabprevious", minimum: 4) { return [.previousTab] }

    if VimExParser.matches(name, command: "edit") {
      return arguments.isEmpty
        ? [.custom("reload-file")] : [.openFile(unescapeExArgument(arguments))]
    }
    if name == "ls" || VimExParser.matches(name, command: "buffers", minimum: 3)
      || VimExParser.matches(name, command: "files", minimum: 2)
    {
      return [.custom("vim-buffer-list")]
    }
    if VimExParser.matches(name, command: "badd", minimum: 2) {
      guard !arguments.isEmpty else { return [] }
      return [.custom("vim-buffer-add:\(unescapeExArgument(arguments))")]
    }
    if VimExParser.matches(name, command: "buffer") {
      if arguments.isEmpty { return [.custom("vim-buffer-current")] }
      if let number = Int(arguments) { return [.switchBuffer(number)] }
      return [.custom("vim-buffer-switch:\(arguments)")]
    }
    if VimExParser.matches(name, command: "bdelete", minimum: 2) {
      return [.custom("vim-buffer-delete:\(parsed.bang ? "!" : "")\(arguments)")]
    }
    if VimExParser.matches(name, command: "bunload", minimum: 3) {
      return [.custom("vim-buffer-unload:\(parsed.bang ? "!" : "")\(arguments)")]
    }
    if VimExParser.matches(name, command: "bwipeout", minimum: 2) {
      return [.custom("vim-buffer-wipeout:\(parsed.bang ? "!" : "")\(arguments)")]
    }
    if name == "sp" || VimExParser.matches(name, command: "split", minimum: 2) {
      return arguments.isEmpty
        ? [.split(horizontal: true)]
        : [.custom("vim-window-split-horizontal:\(unescapeExArgument(arguments))")]
    }
    if name == "vs" || VimExParser.matches(name, command: "vsplit", minimum: 2) {
      return arguments.isEmpty
        ? [.split(horizontal: false)]
        : [.custom("vim-window-split-vertical:\(unescapeExArgument(arguments))")]
    }
    if VimExParser.matches(name, command: "new") {
      return arguments.isEmpty
        ? [.newWindow(horizontal: true)]
        : [.custom("vim-window-split-horizontal:\(unescapeExArgument(arguments))")]
    }
    if VimExParser.matches(name, command: "vnew", minimum: 2) {
      return arguments.isEmpty
        ? [.newWindow(horizontal: false)]
        : [.custom("vim-window-split-vertical:\(unescapeExArgument(arguments))")]
    }
    if VimExParser.matches(name, command: "close") {
      return parsed.bang ? [.custom("vim-window-force-close")] : [.closeWindow]
    }
    if VimExParser.matches(name, command: "only") { return [.closeOtherWindows] }
    if VimExParser.matches(name, command: "wincmd") {
      return [.custom("vim-wincmd:\(arguments)")]
    }
    if VimExParser.matches(name, command: "tabnew", minimum: 4) { return [.newTab] }
    if VimExParser.matches(name, command: "tabclose", minimum: 4) {
      return [.custom("vim-tab-close")]
    }

    if VimExParser.matches(name, command: "delete") {
      let specification = try exRegisterSpecification(arguments)
      let range = exLineRange(extending: parsed.range, count: specification.count)
      performMutation(action: .command(command), count: 1, register: specification.register) {
        apply(.delete, range: range, register: specification.register, linewise: true)
      }
      normalizeCursorForMode()
      return []
    }
    if VimExParser.matches(name, command: "yank") {
      let specification = try exRegisterSpecification(arguments)
      let range = exLineRange(extending: parsed.range, count: specification.count)
      apply(.yank, range: range, register: specification.register, linewise: true)
      return []
    }
    if VimExParser.matches(name, command: "put", minimum: 2) {
      let specification = try exRegisterSpecification(arguments)
      if let range = parsed.range { state.cursor = lineOffset(exLineNumber(range)) }
      let value = registerValue(for: specification.register)
      let semantic = VimSemanticCommand.paste(
        value, after: !parsed.bang, count: specification.count)
      performMutation(
        action: parsed.bang ? .pasteBefore : .pasteAfter,
        count: specification.count,
        register: specification.register,
        semanticCommand: semantic
      ) {
        paste(value, after: !parsed.bang, count: specification.count)
      }
      normalizeCursorForMode()
      return []
    }
    if name == "t" || VimExParser.matches(name, command: "copy", minimum: 2) {
      copyExRange(parsed.range, destination: arguments, command: command)
      return []
    }
    if VimExParser.matches(name, command: "move", minimum: 1) {
      moveExRange(parsed.range, destination: arguments, command: command)
      return []
    }
    if VimExParser.matches(name, command: "join") {
      joinExRange(parsed.range, arguments: arguments, command: command)
      return []
    }
    if VimExParser.matches(name, command: "normal") {
      guard !arguments.isEmpty else { return [] }
      try executeNormal(arguments, range: parsed.range)
      return []
    }
    if VimExParser.matches(name, command: "global")
      || VimExParser.matches(name, command: "vglobal")
    {
      try executeGlobal(
        arguments,
        range: parsed.range,
        invert: name.first == "v"
      )
      return []
    }
    if VimExParser.matches(name, command: "sort") {
      sortExRange(parsed.range, arguments: arguments, command: command)
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
    publishMessage(
      VimMessage(
        text: "Not an editor command: \(command)",
        code: "E492",
        severity: .error,
        lifetime: .timed(milliseconds: 3200)
      )
    )
    return []
  }

  private func executeGroupedExHistory<T>(_ body: () throws -> T) throws -> T {
    let ownsHistory = historySuppressionDepth == 0
    let before = state
    if ownsHistory { beginEditCapture() }
    historySuppressionDepth += 1
    var ended = false
    defer {
      if ownsHistory, !ended, editCaptureDepth > 0 { _ = endEditCapture() }
      historySuppressionDepth -= 1
    }
    let value = try body()
    guard ownsHistory else { return value }
    let edits = endEditCapture()
    ended = true
    if let transaction = VimChangeTransaction.make(before: before, after: state, edits: edits) {
      undoTree.append(transaction)
      recordChangePosition(before.cursor)
    }
    return value
  }

  func applySetOptions(_ arguments: String) {
    for option in arguments.split(whereSeparator: \.isWhitespace).map(String.init) {
      let lowercase = option.lowercased()
      if let specification = optionValue(
        in: option, lowercase: lowercase, prefixes: ["iskeyword+=", "isk+="])
      {
        keywordOptions.add(specification)
        continue
      }
      if let specification = optionValue(
        in: option, lowercase: lowercase, prefixes: ["iskeyword-=", "isk-="])
      {
        keywordOptions.remove(specification)
        continue
      }
      if let specification = optionValue(
        in: option, lowercase: lowercase, prefixes: ["iskeyword=", "isk="])
      {
        keywordOptions.assign(specification)
        continue
      }
      if lowercase == "iskeyword&" || lowercase == "isk&" {
        keywordOptions.reset()
        continue
      }
      if let width = optionValue(
        in: option,
        lowercase: lowercase,
        prefixes: ["textwidth=", "tw="]
      ).flatMap(Int.init) {
        textWidth = max(0, width)
        continue
      }
      if lowercase == "textwidth&" || lowercase == "tw&" {
        textWidth = 0
        continue
      }

      switch lowercase {
      case "ic", "ignorecase": searchIgnoreCase = true
      case "noic", "noignorecase": searchIgnoreCase = false
      case "scs", "smartcase": searchSmartCase = true
      case "noscs", "nosmartcase": searchSmartCase = false
      case "ws", "wrapscan": searchWrap = true
      case "nows", "nowrapscan": searchWrap = false
      case "invic", "invignorecase": searchIgnoreCase.toggle()
      case "invscs", "invsmartcase": searchSmartCase.toggle()
      case "invws", "invwrapscan": searchWrap.toggle()
      default: break
      }
    }
  }

  private func optionValue(
    in option: String,
    lowercase: String,
    prefixes: [String]
  ) -> String? {
    guard let prefix = prefixes.first(where: { lowercase.hasPrefix($0) }) else { return nil }
    return String(option.dropFirst(prefix.count))
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

  private func exLineRange(extending expression: String?, count: Int) -> Range<Int> {
    let base = exLineRange(expression)
    guard count > 1 else { return base }
    let first = lineIndex.oneBasedLine(
      containing: base.lowerBound, textLength: state.text.utf16.count)
    let last = min(totalLineCount(), first + count - 1)
    return lineStart(at: lineOffset(first))..<lineEndIncludingNewline(at: lineOffset(last))
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
          base = lineIndex.oneBasedLine(containing: position, textLength: state.text.utf16.count)
        }
      }
    } else if address.first == "/" || address.first == "?" {
      let delimiter = address.removeFirst()
      var pattern = ""
      var escaped = false
      while let character = address.first {
        address.removeFirst()
        if escaped {
          pattern.append("\\")
          pattern.append(character)
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == delimiter {
          break
        } else {
          pattern.append(character)
        }
      }
      if let line = exSearchLine(pattern, forward: delimiter == "/", currentLine: current) {
        base = line
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
    return lineIndex.oneBasedLine(containing: state.cursor, textLength: state.text.utf16.count)
  }

  func totalLineCount() -> Int {
    lineIndex.synchronize(with: state.text)
    return lineIndex.lineCount
  }

  func executeSubstitute(_ command: String) throws -> Bool {
    let parsed = VimExParser.parse(command)
    guard
      parsed.name == "s"
        || VimExParser.matches(parsed.name, command: "substitute", minimum: 1)
    else { return false }

    guard let delimiter = parsed.arguments.first else {
      throw VimError.incompleteCommand(command)
    }
    let components = splitSubstitute(parsed.arguments.dropFirst(), delimiter: delimiter)
    guard components.count >= 2 else { throw VimError.incompleteCommand(command) }

    let pattern = components[0].isEmpty ? (lastSearch?.0 ?? lastSubstitutePattern) : components[0]
    guard !pattern.isEmpty else { throw VimError.incompleteCommand(command) }
    let rawReplacement = components[1]
    let replacement = rawReplacement == "~" ? lastSubstituteReplacement : rawReplacement
    let flags = components.count > 2 ? components[2] : ""
    let forceCase: Bool? = flags.contains("i") ? true : (flags.contains("I") ? false : nil)
    let compiled: VimCompiledRegex
    do {
      compiled = try VimRegexCompiler.compile(
        pattern,
        ignoreCase: searchIgnoreCase,
        smartCase: searchSmartCase,
        forceCaseInsensitive: forceCase
      )
    } catch {
      throw VimError.unsupportedNotation(command)
    }

    let target = exLineRange(parsed.range)
    let targetText = substring(target)
    let matches = substituteMatches(
      compiled.expression,
      in: targetText,
      global: flags.contains("g")
    )

    lastSearch = (pattern, true)
    registers[.named("/")] = VimRegisterValue(text: pattern, linewise: false)
    lastSubstitutePattern = pattern
    lastSubstituteReplacement = replacement
    lastSubstituteFlags = flags
    guard !matches.isEmpty, !flags.contains("n"), !flags.contains("c") else { return true }

    let template = VimRegexCompiler.replacementTemplate(replacement)
    let edits: [(Range<Int>, String)] = matches.map { match in
      let value = compiled.expression.replacementString(
        for: match,
        in: targetText,
        offset: 0,
        template: template
      )
      let lower = target.lowerBound + match.range.location
      return (lower..<(lower + match.range.length), value)
    }

    performMutation(action: .command(command), count: 1, register: .unnamed) {
      for edit in edits.reversed() { replace(range: edit.0, with: edit.1) }
    }
    if let last = edits.last {
      state.cursor = firstNonBlank(at: lineStart(at: last.0.lowerBound))
    }
    normalizeCursorForMode()
    return true
  }

  private func repeatSubstitute(range: String?, useLastSearch: Bool) throws -> [VimHostRequest] {
    let pattern = useLastSearch ? (lastSearch?.0 ?? lastSubstitutePattern) : lastSubstitutePattern
    guard !pattern.isEmpty else { return [] }
    let delimiter: Character = "/"
    let escapedPattern = pattern.replacingOccurrences(of: "/", with: "\\/")
    let escapedReplacement = lastSubstituteReplacement.replacingOccurrences(of: "/", with: "\\/")
    let prefix = range ?? ""
    _ = try executeSubstitute(
      "\(prefix)s\(delimiter)\(escapedPattern)\(delimiter)\(escapedReplacement)\(delimiter)\(lastSubstituteFlags)"
    )
    return []
  }

  private func substituteMatches(
    _ expression: NSRegularExpression,
    in text: String,
    global: Bool
  ) -> [NSTextCheckingResult] {
    let source = text as NSString
    guard !global else {
      return expression.matches(in: text, range: NSRange(location: 0, length: source.length))
    }
    var result: [NSTextCheckingResult] = []
    var location = 0
    while location < source.length {
      let line = source.lineRange(for: NSRange(location: location, length: 0))
      if let match = expression.firstMatch(in: text, range: line) { result.append(match) }
      let next = NSMaxRange(line)
      if next <= location { break }
      location = next
    }
    if source.length == 0,
      let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: 0))
    {
      result.append(match)
    }
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
    guard
      let compiled = try? VimRegexCompiler.compile(
        query,
        ignoreCase: searchIgnoreCase,
        smartCase: searchSmartCase
      )
    else {
      publishMessage(
        VimMessage(
          text: "Invalid search pattern: \(query)",
          code: "E54",
          severity: .error,
          lifetime: .timed(milliseconds: 3200)
        )
      )
      return
    }

    let length = state.text.utf16.count
    let matches = compiled.expression.matches(
      in: state.text,
      range: NSRange(location: 0, length: length)
    )
    guard !matches.isEmpty else {
      publishMessage(
        VimMessage(
          text: "Pattern not found: \(query)",
          code: "E486",
          severity: .error,
          lifetime: .timed(milliseconds: 3200)
        )
      )
      return
    }

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
    preferredVisualColumn = nil
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

  private func exSearchLine(_ pattern: String, forward: Bool, currentLine: Int) -> Int? {
    guard
      let compiled = try? VimRegexCompiler.compile(
        pattern.isEmpty ? (lastSearch?.0 ?? "") : pattern,
        ignoreCase: searchIgnoreCase,
        smartCase: searchSmartCase
      )
    else { return nil }
    let matches = compiled.expression.matches(
      in: state.text,
      range: NSRange(location: 0, length: state.text.utf16.count)
    )
    let lines = matches.map {
      lineIndex.oneBasedLine(containing: $0.range.location, textLength: state.text.utf16.count)
    }
    if forward {
      return lines.first(where: { $0 > currentLine }) ?? (searchWrap ? lines.first : nil)
    }
    return lines.last(where: { $0 < currentLine }) ?? (searchWrap ? lines.last : nil)
  }

  private func exRegisterSpecification(_ arguments: String) throws -> (
    register: VimRegister, count: Int, remaining: String
  ) {
    var source = arguments.trimmingCharacters(in: .whitespaces)
    var register: VimRegister = .unnamed
    if source.first == "\"" { source.removeFirst() }
    if let first = source.first, !first.isNumber, !first.isWhitespace {
      register = try VimCommandParser.register(for: first)
      source.removeFirst()
      source = source.trimmingCharacters(in: .whitespaces)
    }
    let digits = source.prefix(while: \.isNumber)
    let count = max(1, Int(digits) ?? 1)
    source.removeFirst(digits.count)
    return (register, count, source.trimmingCharacters(in: .whitespaces))
  }

  private func copyExRange(_ expression: String?, destination: String, command: String) {
    let sourceRange = exLineRange(expression)
    let destinationLine = exLineNumber(destination)
    let destinationOffset = lineOffset(destinationLine)
    let insertion = lineEndIncludingNewline(at: destinationOffset)
    var payload = substring(sourceRange)
    if !payload.hasSuffix("\n"), !payload.hasSuffix("\r") { payload.append("\n") }
    let prefix =
      insertion == state.text.utf16.count && !lineHasTerminator(at: destinationOffset) ? "\n" : ""
    performMutation(action: .command(command), count: 1, register: .unnamed) {
      replace(range: insertion..<insertion, with: prefix + payload)
    }
    state.cursor = firstNonBlank(at: insertion + prefix.utf16.count)
    normalizeCursorForMode()
  }

  private func moveExRange(_ expression: String?, destination: String, command: String) {
    let sourceRange = exLineRange(expression)
    let destinationLine = exLineNumber(destination)
    let destinationOffset = lineOffset(destinationLine)
    let originalInsertion = lineEndIncludingNewline(at: destinationOffset)
    guard originalInsertion < sourceRange.lowerBound || originalInsertion > sourceRange.upperBound
    else {
      return
    }

    var payload = substring(sourceRange)
    if !payload.hasSuffix("\n"), !payload.hasSuffix("\r") { payload.append("\n") }
    let insertionAfterRemoval =
      originalInsertion > sourceRange.upperBound
      ? originalInsertion - sourceRange.count : originalInsertion
    performMutation(action: .command(command), count: 1, register: .unnamed) {
      replace(range: sourceRange, with: "")
      let safeInsertion = min(insertionAfterRemoval, state.text.utf16.count)
      let needsPrefix =
        safeInsertion == state.text.utf16.count && safeInsertion > 0
        && !state.text.hasSuffix("\n") && !state.text.hasSuffix("\r")
      replace(range: safeInsertion..<safeInsertion, with: (needsPrefix ? "\n" : "") + payload)
    }
    state.cursor = firstNonBlank(at: min(insertionAfterRemoval, state.text.utf16.count))
    normalizeCursorForMode()
  }

  private func joinExRange(_ expression: String?, arguments: String, command: String) {
    var range = exLineRange(expression)
    if expression == nil, let count = Int(arguments), count > 1 {
      range = exLineRange(extending: nil, count: count)
    }
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
  }

  private func executeNormal(_ notation: String, range: String?) throws {
    let lines = lineNumbers(in: exLineRange(range))
    try executeGroupedExHistory {
      for line in lines {
        state.cursor = firstNonBlank(at: lineOffset(min(line, totalLineCount())))
        _ = try executeNotation(notation)
      }
    }
  }

  private func executeGlobal(_ arguments: String, range: String?, invert: Bool) throws {
    guard let delimiter = arguments.first else { throw VimError.incompleteCommand(arguments) }
    let components = splitSubstitute(arguments.dropFirst(), delimiter: delimiter)
    guard components.count >= 2 else { throw VimError.incompleteCommand(arguments) }
    let pattern = components[0].isEmpty ? (lastSearch?.0 ?? "") : components[0]
    let nested = components.dropFirst().joined(separator: String(delimiter))
    guard !pattern.isEmpty, !nested.isEmpty else { throw VimError.incompleteCommand(arguments) }
    guard
      let compiled = try? VimRegexCompiler.compile(
        pattern,
        ignoreCase: searchIgnoreCase,
        smartCase: searchSmartCase
      )
    else { throw VimError.unsupportedNotation(arguments) }

    let selected = lineNumbers(in: exLineRange(range ?? "%")).filter { line in
      let lineRange =
        lineStart(at: lineOffset(line))..<lineEndIncludingNewline(at: lineOffset(line))
      let text = substring(lineRange)
      let match =
        compiled.expression.firstMatch(
          in: text,
          range: NSRange(location: 0, length: text.utf16.count)
        ) != nil
      return invert ? !match : match
    }

    try executeGroupedExHistory {
      for line in selected.reversed() {
        guard line <= totalLineCount() else { continue }
        state.cursor = firstNonBlank(at: lineOffset(line))
        _ = try executeEx(nested)
      }
    }
  }

  private func sortExRange(_ expression: String?, arguments: String, command: String) {
    let range = exLineRange(expression)
    let raw = substring(range)
    let endsWithTerminator = raw.hasSuffix("\n") || raw.hasSuffix("\r")
    var lines = raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
    let ignoreCase = arguments.contains("i")
    let numeric = arguments.contains("n")
    lines.sort { lhs, rhs in
      if numeric, let left = Double(lhs.trimmingCharacters(in: .whitespaces)),
        let right = Double(rhs.trimmingCharacters(in: .whitespaces))
      {
        return left < right
      }
      return ignoreCase
        ? lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        : lhs < rhs
    }
    if arguments.contains("u") {
      var seen: Set<String> = []
      lines = lines.filter { seen.insert(ignoreCase ? $0.lowercased() : $0).inserted }
    }
    var replacement = lines.joined(separator: "\n")
    if endsWithTerminator { replacement.append("\n") }
    performMutation(action: .command(command), count: 1, register: .unnamed) {
      replace(range: range, with: replacement)
    }
    state.cursor = firstNonBlank(at: range.lowerBound)
    normalizeCursorForMode()
  }

  private func lineNumbers(in range: Range<Int>) -> [Int] {
    lineIndex.synchronize(with: state.text)
    let first = lineIndex.oneBasedLine(
      containing: range.lowerBound, textLength: state.text.utf16.count)
    let finalOffset = max(range.lowerBound, min(state.text.utf16.count, range.upperBound) - 1)
    let last = lineIndex.oneBasedLine(containing: finalOffset, textLength: state.text.utf16.count)
    return Array(first...max(first, last))
  }

  private func unescapeExArgument(_ value: String) -> String {
    var result = ""
    var escaped = false
    for character in value {
      if escaped {
        result.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else {
        result.append(character)
      }
    }
    if escaped { result.append("\\") }
    return result
  }
}
