import Combine
import EditorServices
import Foundation
import SwiftUI

@MainActor
final class EditorTabChromeState: ObservableObject {
  let title: String
  let fileExtension: String
  @Published fileprivate(set) var isDirty = false

  init(url: URL) {
    self.title = url.lastPathComponent
    self.fileExtension = url.pathExtension.lowercased()
  }
}

private enum EditorCompletionRequestIntent {
  case automatic
  case triggered(String)
  case explicit

  var invocation: EditorCompletionInvocation {
    switch self {
    case .automatic: return .automatic
    case .triggered(let character): return .triggerCharacter(character)
    case .explicit: return .explicit
    }
  }

  var shouldEnrichAfterIdle: Bool {
    if case .automatic = self { return true }
    return false
  }
}

@MainActor
final class EditorTab: ObservableObject, Identifiable {
  let id: UUID
  let url: URL
  let languageID: String
  let chrome: EditorTabChromeState

  @Published private(set) var text: String
  private(set) var textRevision: UInt64 = 0
  private(set) var presentationRevision: UInt64 = 0
  @Published private(set) var syntaxHighlights: [Highlight]
  @Published private(set) var semanticHighlights: [SemanticHighlight]
  @Published private(set) var diagnostics: [Diagnostic]
  @Published private(set) var completions: [Completion] = []
  @Published private(set) var vimMode: VimMode = .insert
  @Published private(set) var vimPrompt: String?
  @Published private(set) var selectedCompletionIndex = 0
  @Published private(set) var isDirty = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var breakpoints: Set<Int> = []
  @Published var selectedRange = NSRange(location: 0, length: 0)
  private(set) var diskModificationTime: TimeInterval?
  private var persistedText: String

  private let pipeline: EditorDocumentPipeline
  private var snippetLibrary: EditorSnippetLibrary
  private var serviceDiagnostics: [Diagnostic]
  private var buildDiagnostics: [Diagnostic] = []
  private var updateTask: Task<Void, Never>?
  private var editTask: Task<Void, Never>?
  private var completionTask: Task<Void, Never>?
  private var pendingEditCount = 0
  private var editEpoch = 0
  private var completionGeneration = 0
  private var diagnosticUpdateGeneration = 0
  private var completionOffset = 0
  private var snippetStops: [NSRange] = []
  private var snippetStopIndex = -1
  private var lineIndex: EditorLineIndex
  var onDiagnosticsChange: (() -> Void)?
  var onContentStateChange: (() -> Void)?

  var title: String { url.lastPathComponent }
  var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
  var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }
  var currentLine: Int {
    lineIndex.lineNumber(atUTF16Offset: selectedRange.location)
  }

  private init(
    id: UUID,
    pipeline: EditorDocumentPipeline,
    analysis: EditorDocumentAnalysis,
    snippetLibrary: EditorSnippetLibrary
  ) {
    self.id = id
    self.pipeline = pipeline
    self.snippetLibrary = snippetLibrary
    self.serviceDiagnostics = analysis.diagnostics
    self.url = pipeline.uri
    self.languageID = pipeline.languageID
    self.chrome = EditorTabChromeState(url: pipeline.uri)
    self.text = analysis.snapshot.text
    self.persistedText = analysis.snapshot.text
    self.lineIndex = EditorLineIndex(text: analysis.snapshot.text)
    self.breakpoints = EditorBreakpointStore.load(for: pipeline.uri)
    self.syntaxHighlights = analysis.syntaxHighlights
    self.semanticHighlights = analysis.semanticHighlights
    self.diagnostics = analysis.diagnostics
    self.diskModificationTime = Self.modificationTime(for: pipeline.uri)
    observePipeline()
  }

  isolated deinit {
    updateTask?.cancel()
    editTask?.cancel()
    completionTask?.cancel()
  }

  static func open(
    pipeline: EditorDocumentPipeline,
    snippetLibrary: EditorSnippetLibrary,
    id: UUID = UUID()
  ) async throws -> EditorTab {
    let analysis = try await pipeline.refreshAnalysis()
    return EditorTab(
      id: id,
      pipeline: pipeline,
      analysis: analysis,
      snippetLibrary: snippetLibrary
    )
  }

  func updateSnippetLibrary(_ value: EditorSnippetLibrary) {
    snippetLibrary = value
  }

  func updateVimMode(_ value: VimMode) {
    if vimMode != value { vimMode = value }
  }

  func updateVimPrompt(_ value: String?) {
    if vimPrompt != value { vimPrompt = value }
  }

  func reportExternalFileIssue(_ message: String) {
    errorMessage = message
  }

  func applyDiskReload() async throws {
    await editTask?.value
    let analysis = try await pipeline.refreshAnalysis()
    persistedText = analysis.snapshot.text
    replaceText(with: analysis.snapshot.text)
    advancePresentationRevision()
    syntaxHighlights = analysis.syntaxHighlights
    semanticHighlights = analysis.semanticHighlights
    serviceDiagnostics = analysis.diagnostics
    buildDiagnostics = []
    publishDiagnostics()
    selectedRange = NSRange(
      location: min(selectedRange.location, analysis.snapshot.utf16Count),
      length: 0
    )
    clearSnippetStops()
    diskModificationTime = Self.modificationTime(for: url)
    setDirty(false)
    errorMessage = nil
    onContentStateChange?()
  }

  func markExternalConflictResolved() {
    diskModificationTime = Self.modificationTime(for: url)
    persistedText = text
    setDirty(false)
    errorMessage = nil
    onContentStateChange?()
  }

  func select(line: Int, column: Int) {
    let snapshot = TextSnapshot(text: text)
    let position = TextPosition(
      line: max(0, line - 1),
      utf16Column: max(0, column - 1)
    )
    if let offset = try? snapshot.utf16Offset(of: position) {
      selectedRange = NSRange(location: offset, length: 0)
    }
  }

  func markModified() {
    setDirty(true)
    onContentStateChange?()
  }

  func submitEdit(
    range: NSRange,
    replacement: String,
    resultingText: String,
    selectionAfter: NSRange,
    suggestionDelay: Double
  ) {
    let previousSnapshot = TextSnapshot(text: text)
    let resultingSnapshot = TextSnapshot(text: resultingText)
    syntaxHighlights = EditorHighlightRangeMapper.remap(
      syntaxHighlights,
      editedRange: range,
      replacementUTF16Length: replacement.utf16.count,
      from: previousSnapshot,
      to: resultingSnapshot
    )
    semanticHighlights = EditorHighlightRangeMapper.remap(
      semanticHighlights,
      editedRange: range,
      replacementUTF16Length: replacement.utf16.count,
      from: previousSnapshot,
      to: resultingSnapshot
    )
    // Language-service diagnostics belong to an exact document snapshot. Mapping
    // them through an edit made old parser errors look current, while a new
    // response was still in flight. Clear them now; `pipeline.applyUTF16Edit`
    // asks the service to analyse the new snapshot and publishes its replacement.
    serviceDiagnostics = []
    buildDiagnostics = EditorHighlightRangeMapper.remap(
      buildDiagnostics,
      editedRange: range,
      replacementUTF16Length: replacement.utf16.count,
      from: previousSnapshot,
      to: resultingSnapshot
    )
    remapBreakpoints(
      editedRange: range,
      replacementUTF16Length: replacement.utf16.count,
      from: previousSnapshot,
      to: resultingSnapshot
    )
    lineIndex.replace(range: range, replacement: replacement, resultingText: resultingText)
    replaceText(with: resultingText, rebuildLineIndex: false)
    selectedRange = selectionAfter
    updateSnippetStops(editedRange: range, replacementUTF16Length: replacement.utf16.count)
    updateDirtyState(for: resultingText)
    onContentStateChange?()
    completions = []
    selectedCompletionIndex = 0
    diagnosticUpdateGeneration &+= 1
    publishDiagnostics()
    pendingEditCount += 1

    let previous = editTask
    let epoch = editEpoch
    editTask = Task { [weak self, pipeline] in
      await previous?.value
      guard let self else { return }
      guard epoch == self.editEpoch else {
        self.pendingEditCount = max(0, self.pendingEditCount - 1)
        return
      }
      do {
        let applied = try await pipeline.applyUTF16Edit(range, replacement: replacement)
        self.pendingEditCount = max(0, self.pendingEditCount - 1)
        if self.pendingEditCount == 0, self.text != applied.newSnapshot.text {
          self.replaceText(with: applied.newSnapshot.text)
        }
        self.errorMessage = nil
      } catch {
        self.pendingEditCount = max(0, self.pendingEditCount - 1)
        self.editEpoch &+= 1
        self.completionGeneration &+= 1
        self.completionTask?.cancel()
        await self.recoverFromBackendFailure(error)
      }
    }
    if let intent = completionIntent(after: replacement, selection: selectionAfter) {
      requestCompletions(
        atUTF16Offset: selectionAfter.location,
        delay: suggestionDelay,
        intent: intent
      )
    } else {
      dismissCompletions()
    }
  }

  private func requestCompletions(
    atUTF16Offset offset: Int,
    delay: Double,
    intent: EditorCompletionRequestIntent
  ) {
    guard !isMarkdownDocument else {
      dismissCompletions()
      return
    }
    completionGeneration &+= 1
    let generation = completionGeneration
    completionOffset = offset
    completionTask?.cancel()
    completionTask = Task { [weak self, pipeline] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .seconds(max(0, delay)))
        await self.editTask?.value
        guard !Task.isCancelled, generation == self.completionGeneration else { return }
        let localOrTriggered = try await pipeline.completions(
          atUTF16Offset: offset,
          invocation: intent.invocation
        )
        guard generation == self.completionGeneration else { return }
        self.publishCompletions(
          self.mergingSnippetCompletions(localOrTriggered, atUTF16Offset: offset)
        )

        guard intent.shouldEnrichAfterIdle,
          self.identifierPrefixLength(atUTF16Offset: offset) >= 3
        else { return }
        try await Task.sleep(for: .milliseconds(360))
        guard !Task.isCancelled, generation == self.completionGeneration else { return }
        if let enriched = try? await pipeline.completions(
          atUTF16Offset: offset,
          invocation: .explicit
        ), generation == self.completionGeneration {
          self.publishCompletions(
            self.mergingSnippetCompletions(enriched, atUTF16Offset: offset)
          )
        }
      } catch is CancellationError {
        return
      } catch {
        self.completions = []
        self.selectedCompletionIndex = 0
        self.errorMessage = error.localizedDescription
      }
    }
  }

  func applyCompletion(_ completion: Completion) {
    completionGeneration &+= 1
    completionTask?.cancel()
    let offset = completionOffset
    let previous = editTask
    editTask = Task { [weak self, pipeline] in
      await previous?.value
      guard let self else { return }
      do {
        let result = try await pipeline.applyCompletion(
          completion,
          atUTF16Offset: offset
        )
        self.replaceText(with: result.snapshot.text)
        self.selectedRange =
          (try? result.snapshot.nsRange(for: result.initialSelection))
          ?? NSRange(location: min(offset, result.snapshot.utf16Count), length: 0)
        self.installSnippetStops(from: result)
        self.completions = []
        self.selectedCompletionIndex = 0
        self.advancePresentationRevision()
        self.syntaxHighlights = []
        self.semanticHighlights = []
        self.serviceDiagnostics = []
        self.publishDiagnostics()
        self.updateDirtyState(for: result.snapshot.text)
        self.onContentStateChange?()
        self.errorMessage = nil
      } catch {
        self.completions = []
        self.selectedCompletionIndex = 0
        self.errorMessage = error.localizedDescription
      }
    }
  }

  var selectedCompletion: Completion? {
    guard completions.indices.contains(selectedCompletionIndex) else { return nil }
    return completions[selectedCompletionIndex]
  }

  func selectNextCompletion() {
    guard !completions.isEmpty else { return }
    selectedCompletionIndex = (selectedCompletionIndex + 1) % completions.count
  }

  func selectPreviousCompletion() {
    guard !completions.isEmpty else { return }
    selectedCompletionIndex = (selectedCompletionIndex - 1 + completions.count) % completions.count
  }

  func acceptSelectedCompletion() {
    guard let selectedCompletion else { return }
    applyCompletion(selectedCompletion)
  }

  func dismissCompletions() {
    completionGeneration &+= 1
    completionTask?.cancel()
    completions = []
    selectedCompletionIndex = 0
  }

  func requestCompletionsExplicitly() {
    guard selectedRange.length == 0, !isMarkdownDocument else {
      dismissCompletions()
      return
    }
    requestCompletions(
      atUTF16Offset: selectedRange.location,
      delay: 0,
      intent: .explicit
    )
  }

  @discardableResult
  func moveToNextSnippetStop() -> Bool {
    moveSnippetStop(by: 1)
  }

  @discardableResult
  func moveToPreviousSnippetStop() -> Bool {
    moveSnippetStop(by: -1)
  }

  func definitionsAtSelection() async throws -> [SourceLocation] {
    await editTask?.value
    return try await pipeline.definitions(atUTF16Offset: navigationUTF16Offset)
  }

  func referencesAtSelection() async throws -> [SourceLocation] {
    await editTask?.value
    return try await pipeline.references(atUTF16Offset: navigationUTF16Offset)
  }

  func hoverAtSelection() async throws -> HoverResult? {
    await editTask?.value
    return try await pipeline.hover(atUTF16Offset: navigationUTF16Offset)
  }

  func prepareRenameAtSelection() async throws -> RenamePreparation? {
    await editTask?.value
    return try await pipeline.prepareRename(atUTF16Offset: navigationUTF16Offset)
  }

  func renameAtSelection(to newName: String) async throws -> EditorWorkspaceEdit? {
    await editTask?.value
    return try await pipeline.rename(atUTF16Offset: navigationUTF16Offset, to: newName)
  }

  func codeActionsAtSelection() async throws -> [EditorCodeAction] {
    await editTask?.value
    let sourceLength = (text as NSString).length
    let location = min(max(selectedRange.location, 0), sourceLength)
    let range: NSRange
    if selectedRange.length > 0 {
      range = NSIntersectionRange(selectedRange, NSRange(location: 0, length: sourceLength))
    } else {
      range = NSRange(location: location, length: 0)
    }
    return try await pipeline.codeActions(inUTF16Range: range, diagnostics: diagnostics)
  }

  var symbolAtSelection: String? {
    let source = text as NSString
    guard source.length > 0 else { return nil }
    let offset = navigationUTF16Offset
    let probe = min(max(offset, 0), max(0, source.length - 1))
    let range = source.rangeOfIdentifier(containingUTF16Offset: probe)
    guard range.length > 0 else { return nil }
    return source.substring(with: range)
  }

  private var navigationUTF16Offset: Int {
    let source = text as NSString
    guard source.length > 0 else { return 0 }

    if selectedRange.length > 0 {
      return min(max(selectedRange.location, 0), source.length - 1)
    }

    let caret = min(max(selectedRange.location, 0), source.length)
    if caret < source.length,
      source.isIdentifierCharacter(atUTF16Offset: caret)
    {
      return caret
    }
    if caret > 0,
      source.isIdentifierCharacter(atUTF16Offset: caret - 1)
    {
      return caret - 1
    }
    return min(caret, source.length - 1)
  }

  func toggleBreakpointAtCurrentLine() {
    let line = currentLine
    if breakpoints.contains(line) {
      breakpoints.remove(line)
    } else {
      breakpoints.insert(line)
    }
    EditorBreakpointStore.save(breakpoints, for: url)
  }

  private func remapBreakpoints(
    editedRange: NSRange,
    replacementUTF16Length: Int,
    from oldSnapshot: TextSnapshot,
    to newSnapshot: TextSnapshot
  ) {
    guard !breakpoints.isEmpty else { return }
    let editEnd = NSMaxRange(editedRange)
    let delta = replacementUTF16Length - editedRange.length
    var mapped: Set<Int> = []
    for line in breakpoints {
      guard
        let oldOffset = try? oldSnapshot.utf16Offset(
          of: TextPosition(line: max(0, line - 1), utf16Column: 0)
        )
      else { continue }
      let newOffset: Int
      if oldOffset < editedRange.location {
        newOffset = oldOffset
      } else if oldOffset >= editEnd {
        newOffset = oldOffset + delta
      } else {
        // The original line start was replaced. Anchor it to the end of the inserted text,
        // which follows the surviving line content when new lines were inserted before it.
        newOffset = editedRange.location + replacementUTF16Length
      }
      let clamped = min(max(0, newOffset), newSnapshot.utf16Count)
      if let position = try? newSnapshot.position(atUTF16Offset: clamped) {
        mapped.insert(position.line + 1)
      }
    }
    breakpoints = mapped
    EditorBreakpointStore.save(mapped, for: url)
  }

  func updateSelection(_ range: NSRange) {
    guard selectedRange != range else { return }
    selectedRange = range
    if range.length > 0 || range.location != completionOffset {
      dismissCompletions()
    }
    if let stop = currentSnippetStop,
      range.location < stop.location || NSMaxRange(range) > NSMaxRange(stop)
    {
      clearSnippetStops()
    }
  }

  private func completionIntent(
    after replacement: String,
    selection: NSRange
  ) -> EditorCompletionRequestIntent? {
    guard !isMarkdownDocument else { return nil }
    guard selection.length == 0, let last = replacement.last else { return nil }
    if last == "." { return .triggered(".") }
    if last == ":", text.hasUTF16Suffix("::", endingAt: selection.location) {
      return .triggered(":")
    }
    if last == ">", text.hasUTF16Suffix("->", endingAt: selection.location) {
      return .triggered(">")
    }
    if last == "_" || last.isLetter || last.isNumber { return .automatic }
    return nil
  }

  private var isMarkdownDocument: Bool {
    languageID.lowercased() == "markdown"
      || ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
  }

  func setBuildDiagnostics(_ values: [EditorBuildDiagnostic]) {
    advancePresentationRevision()
    let snapshot = TextSnapshot(text: text)
    let source = text as NSString
    buildDiagnostics = values.compactMap { value in
      guard source.length > 0 else { return nil }
      let requestedLine = max(0, value.line - 1)
      let linePosition = TextPosition(line: requestedLine, utf16Column: 0)
      guard let rawLineStart = try? snapshot.utf16Offset(of: linePosition) else { return nil }
      var lineStart = 0
      var lineEnd = 0
      var contentsEnd = 0
      source.getLineStart(
        &lineStart,
        end: &lineEnd,
        contentsEnd: &contentsEnd,
        for: NSRange(location: min(rawLineStart, max(0, source.length - 1)), length: 0)
      )
      let requestedColumn = max(0, value.column - 1)
      var startOffset = min(contentsEnd, lineStart + requestedColumn)
      if requestedColumn > contentsEnd - lineStart {
        let lineText = source.substring(
          with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        let leading = (lineText as NSString).leadingWhitespaceUTF16Length
        startOffset = min(contentsEnd, lineStart + leading)
      }

      let endOffset: Int
      if let endLine = value.endLine, let endColumn = value.endColumn,
        let explicit = try? snapshot.utf16Offset(
          of: TextPosition(line: max(0, endLine - 1), utf16Column: max(0, endColumn - 1)))
      {
        endOffset = min(snapshot.utf16Count, max(startOffset + 1, explicit))
      } else {
        let probe = min(startOffset, max(0, source.length - 1))
        let token = source.rangeOfIdentifier(containingUTF16Offset: probe)
        endOffset = token.length > 0 ? NSMaxRange(token) : min(contentsEnd, startOffset + 1)
      }
      guard endOffset > startOffset,
        let start = try? snapshot.position(atUTF16Offset: startOffset),
        let end = try? snapshot.position(atUTF16Offset: endOffset)
      else { return nil }
      return Diagnostic(
        range: EditorTextRange(start: start, end: end),
        message: value.message,
        severity: value.severity,
        code: value.code,
        source: value.source ?? "build"
      )
    }
    publishDiagnostics()
  }

  private func publishDiagnostics() {
    var seen: Set<DiagnosticIdentity> = []
    diagnostics = (serviceDiagnostics + buildDiagnostics)
      .filter { seen.insert(DiagnosticIdentity($0)).inserted }
      .sorted { lhs, rhs in
        if lhs.severity.rawValue != rhs.severity.rawValue {
          return lhs.severity.rawValue < rhs.severity.rawValue
        }
        return lhs.range.start < rhs.range.start
      }
    onDiagnosticsChange?()
  }

  private func mergingSnippetCompletions(
    _ backendValues: [Completion],
    atUTF16Offset offset: Int
  ) -> [Completion] {
    let prefix = identifierPrefix(atUTF16Offset: offset)
    let snippets = snippetLibrary.completions(languageID: languageID, prefix: prefix)
    let snippetsByLabel = Dictionary(grouping: snippets, by: { $0.label.lowercased() })
    var seen = Set<CompletionIdentity>()
    var result: [Completion] = []

    // EditorServices has already ranked local, project, keyword, and language-server candidates.
    // Keep that order intact, then put an expansion with the same trigger immediately after its
    // keyword/symbol instead of replacing it just because their labels match.
    for value in backendValues {
      append(value, to: &result, seen: &seen)
      for snippet in snippetsByLabel[value.label.lowercased()] ?? [] {
        append(snippet, to: &result, seen: &seen)
      }
    }
    for snippet in snippets {
      append(snippet, to: &result, seen: &seen)
    }
    return Array(result.prefix(100))
  }

  private func append(
    _ completion: Completion,
    to result: inout [Completion],
    seen: inout Set<CompletionIdentity>
  ) {
    guard seen.insert(CompletionIdentity(completion)).inserted else { return }
    result.append(completion)
  }

  private func identifierPrefix(atUTF16Offset offset: Int) -> String {
    let snapshot = TextSnapshot(text: text)
    guard let position = try? snapshot.position(atUTF16Offset: offset),
      let range = try? CompletionUtilities.inferredIdentifierRange(
        in: snapshot,
        endingAt: position
      ),
      let nsRange = try? snapshot.nsRange(for: range)
    else { return "" }
    return (text as NSString).substring(with: nsRange)
  }

  private var currentSnippetStop: NSRange? {
    guard snippetStops.indices.contains(snippetStopIndex) else { return nil }
    return snippetStops[snippetStopIndex]
  }

  private func publishCompletions(_ values: [Completion]) {
    completions = values
    selectedCompletionIndex = min(selectedCompletionIndex, max(0, values.count - 1))
    errorMessage = nil
  }

  private func identifierPrefixLength(atUTF16Offset offset: Int) -> Int {
    let snapshot = TextSnapshot(text: text)
    guard let position = try? snapshot.position(atUTF16Offset: offset),
      let range = try? CompletionUtilities.inferredIdentifierRange(
        in: snapshot,
        endingAt: position
      ),
      let nsRange = try? snapshot.nsRange(for: range)
    else { return 0 }
    return nsRange.length
  }

  private func installSnippetStops(from result: CompletionApplicationResult) {
    var ranges = result.tabStops
      .sorted { $0.index < $1.index }
      .compactMap { $0.ranges.first }
      .compactMap { try? result.snapshot.nsRange(for: $0) }
    if let finalOffset = try? result.snapshot.utf16Offset(of: result.finalCursor) {
      let finalRange = NSRange(location: finalOffset, length: 0)
      if ranges.last != finalRange { ranges.append(finalRange) }
    }
    snippetStops = ranges
    snippetStopIndex = ranges.firstIndex(of: selectedRange) ?? (ranges.isEmpty ? -1 : 0)
  }

  private func moveSnippetStop(by delta: Int) -> Bool {
    guard !snippetStops.isEmpty else { return false }
    let next = snippetStopIndex + delta
    guard snippetStops.indices.contains(next) else {
      clearSnippetStops()
      return false
    }
    snippetStopIndex = next
    selectedRange = snippetStops[next]
    dismissCompletions()
    return true
  }

  private func updateSnippetStops(editedRange: NSRange, replacementUTF16Length: Int) {
    guard !snippetStops.isEmpty else { return }
    let delta = replacementUTF16Length - editedRange.length
    snippetStops = snippetStops.compactMap { stop in
      if NSMaxRange(stop) <= editedRange.location { return stop }
      if stop.location >= NSMaxRange(editedRange) {
        return NSRange(location: max(0, stop.location + delta), length: stop.length)
      }
      if stop.location <= editedRange.location && NSMaxRange(stop) >= NSMaxRange(editedRange) {
        return NSRange(location: stop.location, length: max(0, stop.length + delta))
      }
      return nil
    }
    if snippetStops.indices.contains(snippetStopIndex) == false { clearSnippetStops() }
  }

  private func clearSnippetStops() {
    snippetStops = []
    snippetStopIndex = -1
  }

  private func replaceText(with value: String, rebuildLineIndex: Bool = true) {
    guard text != value else { return }
    if rebuildLineIndex { lineIndex.rebuild(with: value) }
    textRevision &+= 1
    text = value
  }

  private func advancePresentationRevision() {
    presentationRevision &+= 1
  }

  private func updateDirtyState(for currentText: String) {
    setDirty(currentText != persistedText)
  }

  private func setDirty(_ value: Bool) {
    if isDirty != value { isDirty = value }
    if chrome.isDirty != value { chrome.isDirty = value }
  }

  func refreshAnalysis() {
    Task { [weak self, pipeline] in
      guard let self else { return }
      do {
        let value = try await pipeline.refreshAnalysis()
        self.consume(.analysis(value))
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  func format(tabWidth: Int, insertSpaces: Bool) {
    let previous = editTask
    editTask = Task { [weak self, pipeline] in
      await previous?.value
      guard let self else { return }
      do {
        let snapshot = try await pipeline.format(
          options: .init(tabSize: tabWidth, insertSpaces: insertSpaces)
        )
        self.replaceText(with: snapshot.text)
        self.updateDirtyState(for: snapshot.text)
        self.onContentStateChange?()
        self.completions = []
        self.selectedCompletionIndex = 0
        self.advancePresentationRevision()
        self.syntaxHighlights = []
        self.semanticHighlights = []
        self.serviceDiagnostics = []
        self.publishDiagnostics()
        self.errorMessage = nil
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  @discardableResult
  func save() async -> Bool {
    await editTask?.value
    do {
      try await pipeline.persist()
      persistedText = text
      diskModificationTime = Self.modificationTime(for: url)
      setDirty(false)
      onContentStateChange?()
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// A successful compiler pass is authoritative for the exact on-disk snapshot
  /// that was just saved. Language servers (notably rust-analyzer) may publish
  /// diagnostics without a document version, so an older asynchronous response
  /// cannot otherwise be distinguished from a response for this snapshot.
  func clearSupersededServiceDiagnosticsAfterSuccessfulBuild() {
    diagnosticUpdateGeneration &+= 1
    serviceDiagnostics = []
    publishDiagnostics()
  }

  func restoreRecoveredText(_ recoveredText: String) async throws {
    await editTask?.value
    guard recoveredText != text else { return }
    let applied = try await pipeline.replaceText(with: recoveredText)
    replaceText(with: applied.newSnapshot.text)
    selectedRange = NSRange(
      location: min(selectedRange.location, applied.newSnapshot.utf16Count), length: 0)
    advancePresentationRevision()
    syntaxHighlights = []
    semanticHighlights = []
    serviceDiagnostics = []
    publishDiagnostics()
    clearSnippetStops()
    updateDirtyState(for: applied.newSnapshot.text)
    onContentStateChange?()
  }

  func close() async {
    completionTask?.cancel()
    clearSnippetStops()
    await editTask?.value
    updateTask?.cancel()
    try? await pipeline.close()
  }

  private func observePipeline() {
    updateTask = Task { [weak self, pipeline] in
      for await update in pipeline.updates {
        guard !Task.isCancelled, let self else { return }
        self.consume(update)
      }
    }
  }

  private func consume(_ update: EditorDocumentPipelineUpdate) {
    switch update {
    case .analysis(let analysis):
      guard pendingEditCount == 0, analysis.snapshot.text == text else { return }
      advancePresentationRevision()
      syntaxHighlights = analysis.syntaxHighlights
      semanticHighlights = analysis.semanticHighlights
      serviceDiagnostics = analysis.diagnostics
      publishDiagnostics()
    case .diagnostics(let values):
      diagnosticUpdateGeneration &+= 1
      let generation = diagnosticUpdateGeneration
      let revision = textRevision
      Task { [weak self, pipeline] in
        try? await Task.sleep(for: .milliseconds(45))
        guard let self, generation == self.diagnosticUpdateGeneration,
          revision == self.textRevision, self.pendingEditCount == 0,
          (try? await pipeline.text()) == self.text
        else { return }
        self.advancePresentationRevision()
        self.serviceDiagnostics = values
        self.publishDiagnostics()
      }
    case .failure(_, let description):
      errorMessage = description
    case .closed:
      completions = []
      selectedCompletionIndex = 0
    }
  }

  private func recoverFromBackendFailure(_ error: Error) async {
    errorMessage = error.localizedDescription
    if let synchronizedText = try? await pipeline.text() {
      replaceText(with: synchronizedText)
      updateDirtyState(for: synchronizedText)
    }
    advancePresentationRevision()
    syntaxHighlights = []
    semanticHighlights = []
    serviceDiagnostics = []
    // Keep the last build result visible while the editor backend reconnects.
    // Backend availability and compiler output have independent lifetimes.
    publishDiagnostics()
    completions = []
    selectedCompletionIndex = 0
    clearSnippetStops()
    onContentStateChange?()
  }

  private static func modificationTime(for url: URL) -> TimeInterval? {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
    return values?.contentModificationDate?.timeIntervalSince1970
  }
}

private struct DiagnosticIdentity: Hashable {
  let range: EditorTextRange
  let message: String
  let severity: Diagnostic.Severity
  let code: String?

  init(_ diagnostic: Diagnostic) {
    range = diagnostic.range
    message = diagnostic.message.trimmingCharacters(in: .whitespacesAndNewlines)
    severity = diagnostic.severity
    code = diagnostic.code
  }
}

private struct CompletionIdentity: Hashable {
  let label: String
  let kind: CompletionKind?
  let insertion: String
  let format: InsertTextFormat?
  let replacement: String?

  init(_ completion: Completion) {
    label = completion.label.lowercased()
    kind = completion.kind
    insertion = completion.insertText ?? completion.label
    format = completion.insertTextFormat
    replacement = completion.primaryEdit?.replacement
  }
}

extension String {
  fileprivate func hasUTF16Suffix(_ suffix: String, endingAt offset: Int) -> Bool {
    let source = self as NSString
    let length = (suffix as NSString).length
    guard offset >= length, offset <= source.length else { return false }
    return source.substring(with: NSRange(location: offset - length, length: length)) == suffix
  }
}

private enum EditorHighlightRangeMapper {
  static func remap(
    _ highlights: [Highlight],
    editedRange: NSRange,
    replacementUTF16Length: Int,
    from oldSnapshot: TextSnapshot,
    to newSnapshot: TextSnapshot
  ) -> [Highlight] {
    highlights.compactMap { highlight in
      guard
        let range = remappedRange(
          highlight.range,
          editedRange: editedRange,
          replacementUTF16Length: replacementUTF16Length,
          from: oldSnapshot,
          to: newSnapshot
        )
      else { return nil }
      return Highlight(range: range, capture: highlight.capture)
    }
  }

  static func remap(
    _ highlights: [SemanticHighlight],
    editedRange: NSRange,
    replacementUTF16Length: Int,
    from oldSnapshot: TextSnapshot,
    to newSnapshot: TextSnapshot
  ) -> [SemanticHighlight] {
    highlights.compactMap { highlight in
      guard
        let range = remappedRange(
          highlight.range,
          editedRange: editedRange,
          replacementUTF16Length: replacementUTF16Length,
          from: oldSnapshot,
          to: newSnapshot
        )
      else { return nil }
      return SemanticHighlight(
        range: range,
        tokenType: highlight.tokenType,
        modifiers: highlight.modifiers
      )
    }
  }

  static func remap(
    _ diagnostics: [Diagnostic],
    editedRange: NSRange,
    replacementUTF16Length: Int,
    from oldSnapshot: TextSnapshot,
    to newSnapshot: TextSnapshot
  ) -> [Diagnostic] {
    diagnostics.compactMap { diagnostic in
      guard
        let range = remappedRange(
          diagnostic.range,
          editedRange: editedRange,
          replacementUTF16Length: replacementUTF16Length,
          from: oldSnapshot,
          to: newSnapshot
        )
      else { return nil }
      return Diagnostic(
        range: range,
        message: diagnostic.message,
        severity: diagnostic.severity,
        code: diagnostic.code,
        source: diagnostic.source
      )
    }
  }

  private static func remappedRange(
    _ sourceRange: EditorTextRange,
    editedRange: NSRange,
    replacementUTF16Length: Int,
    from oldSnapshot: TextSnapshot,
    to newSnapshot: TextSnapshot
  ) -> EditorTextRange? {
    guard editedRange.location >= 0,
      editedRange.length >= 0,
      NSMaxRange(editedRange) <= oldSnapshot.utf16Count,
      let oldRange = try? oldSnapshot.nsRange(for: sourceRange)
    else { return nil }

    let delta = replacementUTF16Length - editedRange.length
    let newRange: NSRange
    if NSMaxRange(oldRange) <= editedRange.location {
      newRange = oldRange
    } else if oldRange.location >= NSMaxRange(editedRange) {
      newRange = NSRange(location: oldRange.location + delta, length: oldRange.length)
    } else if oldRange.location <= editedRange.location
      && NSMaxRange(oldRange) >= NSMaxRange(editedRange)
    {
      newRange = NSRange(
        location: oldRange.location,
        length: max(0, oldRange.length + delta)
      )
    } else {
      return nil
    }

    guard newRange.location >= 0,
      newRange.length > 0,
      NSMaxRange(newRange) <= newSnapshot.utf16Count,
      let start = try? newSnapshot.position(atUTF16Offset: newRange.location),
      let end = try? newSnapshot.position(atUTF16Offset: NSMaxRange(newRange))
    else { return nil }
    return EditorTextRange(start: start, end: end)
  }
}

struct EditorTabLabel: View {
  @ObservedObject var tab: EditorTab
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 5) {
      CIcon(code: fileIconCode(forFileName: tab.title), size: 11)
      Text(tab.title)
        .lineLimit(1)
      if tab.isDirty {
        Circle()
          .frame(width: 6, height: 6)
      }
    }
    .font(.system(size: 11))
    .padding(.leading, 9)
    .padding(.vertical, 6)
    .contentShape(Rectangle())
  }
}

extension NSString {
  fileprivate func isIdentifierCharacter(atUTF16Offset offset: Int) -> Bool {
    guard offset >= 0, offset < length else { return false }
    let scalar = character(at: offset)
    if scalar == 95 || scalar == 36 { return true }
    guard let unicodeScalar = UnicodeScalar(scalar) else { return false }
    return CharacterSet.alphanumerics.contains(unicodeScalar)
  }

  fileprivate func rangeOfIdentifier(containingUTF16Offset offset: Int) -> NSRange {
    guard offset >= 0, offset < length, isIdentifierCharacter(atUTF16Offset: offset) else {
      return NSRange(location: min(max(offset, 0), length), length: 0)
    }

    var lower = offset
    while lower > 0, isIdentifierCharacter(atUTF16Offset: lower - 1) { lower -= 1 }
    var upper = offset + 1
    while upper < length, isIdentifierCharacter(atUTF16Offset: upper) { upper += 1 }
    return NSRange(location: lower, length: upper - lower)
  }
}

extension NSString {
  fileprivate var leadingWhitespaceUTF16Length: Int {
    var offset = 0
    while offset < length {
      let unit = character(at: offset)
      guard unit == 0x20 || unit == 0x09 else { break }
      offset += 1
    }
    return offset
  }
}
