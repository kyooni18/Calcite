import AppKit
import EditorServices
import SwiftUI
import UniformTypeIdentifiers

struct CalciteEditorSurface: View {
  @ObservedObject var tab: EditorTab
  @State private var zoomScale: CGFloat = 1
  @State private var showsFind = false
  @State private var showsReplace = false
  @State private var findQuery = ""
  @State private var replacement = ""
  @State private var completionAnchor: CGRect?
  let liveMarkdownStyling: Bool
  let showsMarkdownSyntax: Bool
  let wrapsMarkdownLines: Bool
  let profile: EditorCustomProfile
  let editorMode: EditorInterface
  let onVimHostRequest: (VimHostRequest) -> Void
  let onGoToDefinition: () -> Void
  let onFindReferences: () -> Void
  let onShowQuickHelp: () -> Void
  let onShowQuickFixes: (Diagnostic) -> Void
  let onSelectInputMode: (EditorInterface) -> Void
  let commandEvent: EditorTabCommandEvent?

  var body: some View {
    VStack(spacing: 0) {
      editorPane

      EditorStatusBar(
        tab: tab,
        profile: profile,
        editorMode: editorMode,
        onSelectInputMode: onSelectInputMode
      )
    }
    .clipped()
    .background(profile.surface.background.color.opacity(profile.surface.backgroundOpacity))
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    .onChange(of: commandEvent?.id) { _, _ in
      handle(commandEvent)
    }
  }

  private func handle(_ event: EditorTabCommandEvent?) {
    guard let event, event.targetTabID == tab.id else { return }
    switch event.command {
    case .find:
      showsFind = true
      showsReplace = false
    case .replace:
      showsFind = true
      showsReplace = true
    case .zoomIn:
      updateZoom(by: 0.1)
    case .zoomOut:
      updateZoom(by: -0.1)
    case .resetZoom:
      zoomScale = 1
    }
  }

  private var editorPane: some View {
    ZStack(alignment: .bottomLeading) {
      CodeTextEditor(
        text: tab.text,
        textRevision: tab.textRevision,
        presentationRevision: tab.presentationRevision,
        languageID: tab.languageID,
        liveMarkdownStyling: liveMarkdownStyling,
        showsMarkdownSyntax: showsMarkdownSyntax,
        wrapsMarkdownLines: wrapsMarkdownLines,
        profile: profile,
        syntaxHighlights: tab.syntaxHighlights,
        semanticHighlights: tab.semanticHighlights,
        diagnostics: profile.behavior.showDiagnostics ? tab.diagnostics : [],
        showsInlineDiagnosticMessages: profile.behavior.showInlineDiagnosticMessages,
        breakpoints: tab.breakpoints,
        selectedRange: tab.selectedRange,
        hasCompletions: !tab.completions.isEmpty,
        onWillEdit: tab.markModified,
        onEdit: { range, replacement, resultingText, selectionAfter in
          tab.submitEdit(
            range: range,
            replacement: replacement,
            resultingText: resultingText,
            selectionAfter: selectionAfter,
            suggestionDelay: profile.behavior.suggestionDelay
          )
        },
        onSelectionChange: tab.updateSelection,
        onToggleBreakpoint: { line in
          if line == tab.currentLine {
            tab.toggleBreakpointAtCurrentLine()
          } else {
            tab.updateSelection(selectedRange(forLine: line, in: tab.text))
            tab.toggleBreakpointAtCurrentLine()
          }
        },
        onAcceptCompletion: tab.acceptSelectedCompletion,
        onMoveCompletionDown: tab.selectNextCompletion,
        onMoveCompletionUp: tab.selectPreviousCompletion,
        onDismissCompletions: tab.dismissCompletions,
        onRequestCompletions: tab.requestCompletionsExplicitly,
        onMoveToNextSnippetStop: tab.moveToNextSnippetStop,
        onMoveToPreviousSnippetStop: tab.moveToPreviousSnippetStop,
        onVimHostRequest: onVimHostRequest,
        onGoToDefinition: onGoToDefinition,
        onFindReferences: onFindReferences,
        onShowQuickHelp: onShowQuickHelp,
        onShowFind: { replace in
          showsFind = true
          showsReplace = replace
        },
        zoomScale: zoomScale,
        onZoomChange: { delta in
          zoomScale = min(2, max(0.5, zoomScale + delta))
        },
        onVimModeChange: tab.updateVimMode,
        onVimPromptChange: tab.updateVimPrompt,
        onCaretRectChange: { completionAnchor = $0 }
      )

      if !tab.completions.isEmpty {
        GeometryReader { proxy in
          let panelHeight = EditorCompletionPanel.preferredHeight(for: tab.completions.count)
          let anchor =
            completionAnchor
            ?? CGRect(
              x: 58,
              y: max(8, proxy.size.height - panelHeight - 8),
              width: 1,
              height: 1
            )
          let x = min(
            max(8, anchor.minX),
            max(8, proxy.size.width - EditorCompletionPanel.preferredWidth - 8)
          )
          let below = anchor.maxY + 4
          let y =
            below + panelHeight <= proxy.size.height - 8
            ? below
            : max(8, anchor.minY - panelHeight - 4)

          EditorCompletionPanel(
            completions: tab.completions,
            selectedIndex: tab.selectedCompletionIndex,
            apply: tab.applyCompletion
          )
          .offset(x: x, y: y)
        }
      }

      if profile.behavior.showDiagnostics {
        EditorDiagnosticOverlay(tab: tab, onShowQuickFixes: onShowQuickFixes)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .padding(.top, 10)
          .padding(.trailing, 12)
      }

      if showsFind {
        EditorFindReplaceBar(
          text: tab.text,
          textRevision: tab.textRevision,
          selection: tab.selectedRange,
          query: $findQuery,
          replacement: $replacement,
          showsReplace: $showsReplace,
          close: dismissFindReplace,
          select: { tab.updateSelection($0) },
          replaceCurrent: { range in replace(range: range, with: replacement) },
          replaceAll: replaceAll
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(12)
      }
    }
  }

  private func replace(range: NSRange, with value: String) {
    let source = tab.text as NSString
    let text = source.replacingCharacters(in: range, with: value)
    let selection = NSRange(location: range.location, length: (value as NSString).length)
    tab.submitEdit(
      range: range, replacement: value, resultingText: text, selectionAfter: selection,
      suggestionDelay: profile.behavior.suggestionDelay)
  }

  private func dismissFindReplace() {
    showsFind = false
    showsReplace = false
  }

  private func updateZoom(by delta: CGFloat) {
    zoomScale = min(2, max(0.5, zoomScale + delta))
  }

  private func replaceAll() {
    guard !findQuery.isEmpty else { return }
    let text = tab.text.replacingOccurrences(of: findQuery, with: replacement)
    guard text != tab.text else { return }
    tab.submitEdit(
      range: NSRange(location: 0, length: (tab.text as NSString).length), replacement: text,
      resultingText: text, selectionAfter: tab.selectedRange,
      suggestionDelay: profile.behavior.suggestionDelay)
  }

  private func selectedRange(forLine line: Int, in text: String) -> NSRange {
    let source = text as NSString
    var currentLine = 1
    var location = 0
    while location < source.length, currentLine < line {
      let range = source.lineRange(for: NSRange(location: location, length: 0))
      location = NSMaxRange(range)
      currentLine += 1
    }
    return NSRange(location: min(location, source.length), length: 0)
  }
}

private struct EditorDiagnosticOverlay: View {
  @ObservedObject var tab: EditorTab
  let onShowQuickFixes: (Diagnostic) -> Void
  /// Keep the chosen detail level when this overlay is recreated for a new error.
  @AppStorage("calcite.editorDiagnosticOverlay.isExpanded") private var isExpanded = true
  @AppStorage("calcite.editorDiagnosticOverlay.expandedWidth") private var expandedWidth = 390.0
  @State private var resizeStartWidth: CGFloat?
  @State private var displayedDiagnostics: [Diagnostic] = []
  @State private var displayedErrorMessage: String?
  @State private var delayedUpdateTask: Task<Void, Never>?
  @State private var selectedDiagnosticOffsets: Set<Int> = []

  private var overlayWidth: CGFloat {
    isExpanded ? min(max(CGFloat(expandedWidth), 280), 720) : 250
  }

  private var visibleDiagnostics: [(offset: Int, element: Diagnostic)] {
    let indexed = Array(displayedDiagnostics.enumerated())
    let currentLine = max(0, tab.currentLine - 1)
    let onCurrentLine = indexed.filter { _, diagnostic in
      diagnostic.range.start.line <= currentLine
        && diagnostic.range.end.line >= currentLine
    }
    if !onCurrentLine.isEmpty { return Array(onCurrentLine.prefix(3)) }

    let errors = indexed.filter { $0.element.severity == .error }
    if !errors.isEmpty { return Array(errors.prefix(3)) }
    return Array(indexed.prefix(3))
  }

  var body: some View {
    Group {
      if displayedErrorMessage != nil || !displayedDiagnostics.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          header

          if isExpanded {
            if let error = displayedErrorMessage, !error.isEmpty {
              Divider()
              operationErrorRow(error)
            }

            ForEach(visibleDiagnostics, id: \.offset) { offset, diagnostic in
              Divider()
              diagnosticRow(offset: offset, diagnostic: diagnostic)
            }
          }
        }
        .frame(width: overlayWidth)
        .background {
          CalciteBackground(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 1)
        }
        .overlay(alignment: .bottomLeading) {
          if isExpanded {
            resizeHandle
          }
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor diagnostics")
      }
    }
    .onAppear(perform: updateDisplayedProblemsImmediately)
    .onChange(of: tab.diagnostics) { _, _ in scheduleDisplayedProblemsUpdate() }
    .onChange(of: tab.errorMessage) { _, _ in scheduleDisplayedProblemsUpdate() }
    .onDisappear { delayedUpdateTask?.cancel() }
    .focusable()
    .onCopyCommand {
      guard !selectedDiagnosticOffsets.isEmpty else { return [] }
      let text = displayedDiagnostics.enumerated()
        .filter { selectedDiagnosticOffsets.contains($0.offset) }
        .map { "Line \($0.element.range.start.line + 1): \($0.element.message)" }
        .joined(separator: "\n")
      return [NSItemProvider(object: text as NSString)]
    }
  }

  private func updateDisplayedProblemsImmediately() {
    delayedUpdateTask?.cancel()
    displayedDiagnostics = tab.diagnostics
    displayedErrorMessage = tab.errorMessage
    selectedDiagnosticOffsets = []
  }

  private func scheduleDisplayedProblemsUpdate() {
    delayedUpdateTask?.cancel()
    let diagnostics = tab.diagnostics
    let errorMessage = tab.errorMessage
    delayedUpdateTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .milliseconds(120))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      displayedDiagnostics = diagnostics
      displayedErrorMessage = errorMessage
      selectedDiagnosticOffsets = []
    }
  }

  private var resizeHandle: some View {
    Image(systemName: "arrow.left.and.right")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.tertiary)
      .frame(width: 28, height: 22)
      .contentShape(Rectangle())
      .help("Drag to resize the error popup")
      .accessibilityLabel("Resize error popup")
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            let startWidth = resizeStartWidth ?? overlayWidth
            resizeStartWidth = startWidth
            expandedWidth = Double(min(max(startWidth - value.translation.width, 280), 720))
          }
          .onEnded { _ in
            resizeStartWidth = nil
          }
      )
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(
        systemName: displayedErrorCount > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
      )
      .foregroundStyle(displayedErrorCount > 0 ? Color.red : Color.orange)
      Text(overlayTitle)
        .font(.caption.weight(.semibold))
      Spacer(minLength: 10)
      if isExpanded {
        if displayedErrorCount > 0 {
          Text("\(displayedErrorCount) error\(displayedErrorCount == 1 ? "" : "s")")
            .foregroundStyle(.secondary)
        }
        if displayedWarningCount > 0 {
          Text("\(displayedWarningCount) warning\(displayedWarningCount == 1 ? "" : "s")")
            .foregroundStyle(.secondary)
        }
      } else {
        Text("\(displayedDiagnostics.count + (displayedErrorMessage == nil ? 0 : 1))")
          .foregroundStyle(.secondary)
      }
      Button {
        withAnimation(.easeInOut(duration: 0.14)) { isExpanded.toggle() }
      } label: {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(.caption2.weight(.semibold))
      }
      .buttonStyle(.plain)
    }
    .font(.caption2)
    .padding(.horizontal, 11)
    .frame(minHeight: 32)

  }

  private var overlayTitle: String {
    let currentLine = max(0, tab.currentLine - 1)
    if displayedDiagnostics.contains(where: {
      $0.range.start.line <= currentLine && $0.range.end.line >= currentLine
    }) {
      return "Problems on line \(tab.currentLine)"
    }
    return displayedErrorMessage == nil ? "Editor Problems" : "Editor Error"
  }

  private var displayedErrorCount: Int {
    displayedDiagnostics.filter { $0.severity == .error }.count
  }

  private var displayedWarningCount: Int {
    displayedDiagnostics.filter { $0.severity == .warning }.count
  }

  private func operationErrorRow(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
        .foregroundStyle(.red)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text("Editor service")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(message)
          .font(.caption)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 8)
  }

  private func diagnosticRow(offset: Int, diagnostic: Diagnostic) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: diagnosticSymbol(diagnostic.severity))
        .foregroundStyle(diagnosticColor(diagnostic.severity))
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          Text("Line \(diagnostic.range.start.line + 1)")
            .font(.caption2.monospaced().weight(.semibold))
          if let source = diagnostic.source, !source.isEmpty {
            Text(source)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Text(diagnostic.message)
          .font(.caption)
          .foregroundStyle(.primary)
          .lineLimit(3)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button("Quick Fix…", systemImage: "lightbulb") {
          onShowQuickFixes(diagnostic)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .help("Show fixes suggested by the language service")
      }
      Image(systemName: "arrow.right")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .background(
      selectedDiagnosticOffsets.contains(offset) ? Color.accentColor.opacity(0.18) : .clear
    )
    .onTapGesture {
      if NSEvent.modifierFlags.contains(.command) {
        if selectedDiagnosticOffsets.contains(offset) {
          selectedDiagnosticOffsets.remove(offset)
        } else {
          selectedDiagnosticOffsets.insert(offset)
        }
      } else {
        selectedDiagnosticOffsets = [offset]
        reveal(diagnostic)
      }
    }
    .help("Reveal this diagnostic in the editor")
  }

  private func reveal(_ diagnostic: Diagnostic) {
    let snapshot = TextSnapshot(text: tab.text)
    guard let range = try? snapshot.nsRange(for: diagnostic.range) else { return }
    tab.updateSelection(range)
  }

  private func diagnosticSymbol(_ severity: Diagnostic.Severity) -> String {
    switch severity {
    case .error: return "xmark.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .information: return "info.circle.fill"
    case .hint: return "lightbulb.fill"
    }
  }

  private func diagnosticColor(_ severity: Diagnostic.Severity) -> Color {
    switch severity {
    case .error: return .red
    case .warning: return .orange
    case .information: return .blue
    case .hint: return .secondary
    }
  }
}

private struct EditorStatusBar: View {
  @ObservedObject var tab: EditorTab
  let profile: EditorCustomProfile
  let editorMode: EditorInterface
  let onSelectInputMode: (EditorInterface) -> Void

  var body: some View {
    HStack(spacing: 10) {
      if let prompt = tab.vimPrompt {
        Text(prompt.isEmpty ? " " : prompt)
          .font(.system(.caption, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text(tab.languageID)
        if tab.isDirty { Text("Modified") }
        Spacer()
      }

      Menu {
        ForEach(EditorInterface.allCases) { mode in
          Button {
            onSelectInputMode(mode)
          } label: {
            if mode == editorMode {
              Label(mode.title, systemImage: "checkmark")
            } else {
              Text(mode.title)
            }
          }
        }
      } label: {
        Text(editorMode.title.uppercased())
          .font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(profile.vim.enabled ? Color.accentColor : Color.secondary)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Choose editor mode")

      if profile.vim.enabled, tab.vimPrompt == nil {
        Text(tab.vimMode.rawValue.uppercased())
          .font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(tab.vimMode == .insert ? Color.green : Color.accentColor)
      }
      if tab.errorCount > 0 {
        Label("\(tab.errorCount)", systemImage: "xmark.circle")
      }
      if tab.warningCount > 0 {
        Label("\(tab.warningCount)", systemImage: "exclamationmark.triangle")
      }
      Text("Ln \(tab.currentLine)")
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .frame(height: 24)
    .background(.bar)
  }
}

@MainActor
struct CodeTextEditor: NSViewRepresentable {
  let text: String
  let textRevision: UInt64
  let presentationRevision: UInt64
  let languageID: String
  var liveMarkdownStyling = true
  var showsMarkdownSyntax = true
  var wrapsMarkdownLines = true
  let profile: EditorCustomProfile
  let syntaxHighlights: [Highlight]
  let semanticHighlights: [SemanticHighlight]
  let diagnostics: [Diagnostic]
  let showsInlineDiagnosticMessages: Bool
  let breakpoints: Set<Int>
  let selectedRange: NSRange
  let hasCompletions: Bool
  let onWillEdit: () -> Void
  let onEdit: (NSRange, String, String, NSRange) -> Void
  let onSelectionChange: (NSRange) -> Void
  let onToggleBreakpoint: (Int) -> Void
  let onAcceptCompletion: () -> Void
  let onMoveCompletionDown: () -> Void
  let onMoveCompletionUp: () -> Void
  let onDismissCompletions: () -> Void
  let onRequestCompletions: () -> Void
  let onMoveToNextSnippetStop: () -> Bool
  let onMoveToPreviousSnippetStop: () -> Bool
  let onVimHostRequest: (VimHostRequest) -> Void
  let onGoToDefinition: () -> Void
  let onFindReferences: () -> Void
  let onShowQuickHelp: () -> Void
  let onShowFind: (Bool) -> Void
  let zoomScale: CGFloat
  let onZoomChange: (CGFloat) -> Void
  let onVimModeChange: (VimMode) -> Void
  let onVimPromptChange: (String?) -> Void
  let onCaretRectChange: (CGRect) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> NSScrollView {
    context.coordinator.beginRepresentableUpdate()
    defer { context.coordinator.endRepresentableUpdate() }

    let scrollView = CodeTextScrollView()
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.wantsLayer = true
    scrollView.layer?.masksToBounds = true

    let initialSize = NSSize(width: 800, height: 600)
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(
      containerSize: NSSize(
        width: wrapsLongLines ? initialSize.width : CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      ))
    textContainer.widthTracksTextView = wrapsLongLines
    textContainer.heightTracksTextView = false
    textContainer.lineFragmentPadding = 6
    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)

    let textView = CodeEditorTextView(
      frame: NSRect(origin: .zero, size: initialSize),
      textContainer: textContainer
    )
    textView.keyEventHandler = context.coordinator.handleKeyEvent
    textView.languageID = languageID
    textView.zoomHandler = context.coordinator.handleZoom
    textView.goToDefinitionHandler = onGoToDefinition
    textView.findReferencesHandler = onFindReferences
    textView.showQuickHelpHandler = onShowQuickHelp
    textView.showFindHandler = onShowFind
    textView.delegate = context.coordinator
    textView.contentDidChangeHandler = { [weak coordinator = context.coordinator] textView in
      coordinator?.handleObservedTextChange(in: textView)
    }
    textView.isEditable = true
    textView.isSelectable = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = !wrapsLongLines
    textView.minSize = NSSize(width: 0, height: initialSize.height)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.autoresizingMask = wrapsLongLines ? [.width] : []
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.string = text

    scrollView.documentView = textView
    context.coordinator.observe(textView: textView, clipView: scrollView.contentView)
    configureLineWrapping(scrollView: scrollView, textView: textView)
    let ruler = LineNumberRulerView(
      textView: textView,
      scrollView: scrollView,
      profile: profile,
      breakpoints: breakpoints,
      onToggleBreakpoint: onToggleBreakpoint
    )
    scrollView.verticalRulerView = ruler
    scrollView.hasVerticalRuler = showsLineNumbers
    scrollView.rulersVisible = showsLineNumbers

    context.coordinator.configureVim(for: textView)
    context.coordinator.applyPresentationIfNeeded(to: textView)
    context.coordinator.scheduleCaretPublication(for: textView)
    scrollView.requestDocumentSizeSync()
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.beginRepresentableUpdate()
    defer { context.coordinator.endRepresentableUpdate() }
    guard let textView = scrollView.documentView as? NSTextView else { return }
    if let codeTextView = textView as? CodeEditorTextView {
      codeTextView.languageID = languageID
      codeTextView.goToDefinitionHandler = onGoToDefinition
      codeTextView.findReferencesHandler = onFindReferences
      codeTextView.showQuickHelpHandler = onShowQuickHelp
      codeTextView.showFindHandler = onShowFind
      codeTextView.zoomHandler = context.coordinator.handleZoom
    }

    if context.coordinator.renderedTextRevision != textRevision {
      let originatedInTextView =
        context.coordinator.expectedLocalTextRevision == textRevision
      if !originatedInTextView {
        let preservedSelection = textView.selectedRange()
        let requestedSelection = safeSelection(for: text)
        let hasExternalSelectionRequest =
          context.coordinator.lastPublishedSelection != selectedRange

        context.coordinator.isApplyingExternalUpdate = true
        textView.string = text
        context.coordinator.synchronizedText = text
        let selection =
          hasExternalSelectionRequest
          ? requestedSelection
          : clampedSelection(preservedSelection, for: text)
        textView.setSelectedRange(selection)
        (textView as? CodeEditorTextView)?.refreshCustomInsertionPoint()
        context.coordinator.lastPublishedSelection = selection
        context.coordinator.isApplyingExternalUpdate = false
      }
      context.coordinator.renderedTextRevision = textRevision
      context.coordinator.expectedLocalTextRevision = nil
    } else if context.coordinator.lastPublishedSelection != selectedRange,
      textView.selectedRange() != selectedRange
    {
      let requestedSelection = safeSelection(for: text)
      context.coordinator.isApplyingExternalUpdate = true
      textView.setSelectedRange(requestedSelection)
      (textView as? CodeEditorTextView)?.refreshCustomInsertionPoint()
      context.coordinator.lastPublishedSelection = requestedSelection
      context.coordinator.isApplyingExternalUpdate = false
    }

    context.coordinator.configureVim(for: textView)
    context.coordinator.applyPresentationIfNeeded(to: textView)
    configureLineWrapping(scrollView: scrollView, textView: textView)
    (scrollView as? CodeTextScrollView)?.requestDocumentSizeSync()
    scrollView.backgroundColor = resolvedBackgroundColor
    scrollView.hasVerticalRuler = showsLineNumbers
    scrollView.rulersVisible = showsLineNumbers
    if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
      ruler.update(
        profile: profile,
        breakpoints: breakpoints
      )
    }
    context.coordinator.scheduleCaretPublication(for: textView)
  }

  private var wrapsLongLines: Bool {
    liveMarkdownStyling && wrapsMarkdownLines && languageID.lowercased() == "markdown"
  }

  private func configureLineWrapping(scrollView: NSScrollView, textView: NSTextView) {
    let wraps = wrapsLongLines
    scrollView.hasHorizontalScroller = !wraps
    (scrollView as? CodeTextScrollView)?.wrapsLines = wraps
    textView.isHorizontallyResizable = !wraps
    textView.autoresizingMask = wraps ? [.width] : []
    textView.textContainer?.widthTracksTextView = wraps
    textView.textContainer?.containerSize = NSSize(
      width: wraps ? max(scrollView.contentSize.width, 1) : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    if wraps {
      textView.setFrameSize(
        NSSize(
          width: max(scrollView.contentSize.width, 1),
          height: max(textView.frame.height, scrollView.contentSize.height))
      )
    }
  }

  private var resolvedBackgroundColor: NSColor {
    profile.surface.background.nsColor.withAlphaComponent(
      profile.surface.background.nsColor.alphaComponent
        * CGFloat(min(max(profile.surface.backgroundOpacity, 0), 1))
    )
  }

  private var showsLineNumbers: Bool {
    profile.behavior.showLineNumbers
      && !(liveMarkdownStyling && languageID.lowercased() == "markdown")
  }

  private func safeSelection(for source: String) -> NSRange {
    clampedSelection(selectedRange, for: source)
  }

  private func clampedSelection(_ range: NSRange, for source: String) -> NSRange {
    let length = (source as NSString).length
    let location = min(max(range.location, 0), length)
    let available = max(0, length - location)
    return NSRange(location: location, length: min(max(range.length, 0), available))
  }

  private func applyPresentation(to textView: NSTextView, affectedRange: NSRange? = nil) {
    EditorTextStyler(profile: profile, zoomScale: zoomScale).apply(
      to: textView,
      languageID: languageID,
      liveMarkdownStyling: liveMarkdownStyling,
      showsMarkdownSyntax: showsMarkdownSyntax,
      syntaxHighlights: syntaxHighlights,
      semanticHighlights: semanticHighlights,
      diagnostics: diagnostics,
      showsInlineDiagnosticMessages: showsInlineDiagnosticMessages,
      selectedRange: safeSelection(for: textView.string),
      affectedRange: affectedRange
    )
  }

  private func refreshSelectionPresentation(
    to textView: NSTextView,
    previousSelection: NSRange?,
    currentSelection: NSRange
  ) {
    EditorTextStyler(profile: profile, zoomScale: zoomScale).updateSelection(
      in: textView,
      languageID: languageID,
      liveMarkdownStyling: liveMarkdownStyling,
      showsMarkdownSyntax: showsMarkdownSyntax,
      previousSelection: previousSelection,
      currentSelection: currentSelection
    )
  }

  private func selectionChangeRequiresMarkdownRestyle(
    in source: String,
    previousSelection: NSRange?,
    currentSelection: NSRange
  ) -> Bool {
    guard liveMarkdownStyling, !showsMarkdownSyntax, languageID.lowercased() == "markdown",
      (source as NSString).length <= editorRichPresentationUTF16Limit,
      let previousSelection
    else { return false }
    let text = source as NSString
    let oldLocation = min(max(previousSelection.location, 0), text.length)
    let newLocation = min(max(currentSelection.location, 0), text.length)
    return text.lineRange(for: NSRange(location: oldLocation, length: 0))
      != text.lineRange(for: NSRange(location: newLocation, length: 0))
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: CodeTextEditor
    var isApplyingExternalUpdate = false
    private var pendingEdit: (range: NSRange, replacement: String)?
    var synchronizedText: String
    private var pendingPresentationRange: NSRange?
    fileprivate var renderedTextRevision: UInt64
    fileprivate var expectedLocalTextRevision: UInt64?
    private var synchronizedVimTextRevision: UInt64?
    private var vimController: VimKeymapController?
    private var vimConfigurationSignature = ""
    private var lastPublishedVimMode: VimMode?
    private var lastPublishedVimPrompt: String?
    private var hasPublishedVimPrompt = false
    fileprivate var lastPublishedSelection: NSRange?
    private var representableUpdateDepth = 0
    private var deferredSelection: NSRange?
    private var deferredVimMode: VimMode?
    private var deferredVimPrompt: String?
    private var hasDeferredVimPrompt = false
    private var publicationFlushScheduled = false
    private var presentationState: PresentationState?
    private var styledSelection: NSRange?
    private weak var observedTextView: NSTextView?
    private weak var observedClipView: NSClipView?
    private var caretPublicationTask: Task<Void, Never>?
    private var lastPublishedCaretRect: CGRect?

    private struct PresentationState: Equatable {
      var textRevision: UInt64
      var presentationRevision: UInt64
      var liveMarkdownStyling: Bool
      var showsMarkdownSyntax: Bool
      var profile: EditorCustomProfile
      var zoomScale: CGFloat
      var showsInlineDiagnosticMessages: Bool
    }

    init(parent: CodeTextEditor) {
      self.parent = parent
      self.renderedTextRevision = parent.textRevision
      self.expectedLocalTextRevision = nil
      self.synchronizedText = parent.text
    }

    isolated deinit {
      caretPublicationTask?.cancel()
      NotificationCenter.default.removeObserver(self)
    }

    func observe(textView: NSTextView, clipView: NSClipView) {
      guard observedTextView !== textView || observedClipView !== clipView else { return }
      NotificationCenter.default.removeObserver(self)
      observedTextView = textView
      observedClipView = clipView
      clipView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(clipViewBoundsDidChange(_:)),
        name: NSView.boundsDidChangeNotification,
        object: clipView
      )
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
      guard notification.object as? NSClipView === observedClipView,
        let textView = observedTextView
      else { return }
      scheduleCaretPublication(for: textView)
    }

    func beginRepresentableUpdate() {
      representableUpdateDepth += 1
    }

    func endRepresentableUpdate() {
      representableUpdateDepth = max(0, representableUpdateDepth - 1)
      if representableUpdateDepth == 0 { scheduleDeferredPublicationsIfNeeded() }
    }

    func applyPresentationIfNeeded(to textView: NSTextView) {
      let currentSelection = parent.clampedSelection(textView.selectedRange(), for: textView.string)
      let next = PresentationState(
        textRevision: parent.textRevision,
        presentationRevision: parent.presentationRevision,
        liveMarkdownStyling: parent.liveMarkdownStyling,
        showsMarkdownSyntax: parent.showsMarkdownSyntax,
        profile: parent.profile,
        zoomScale: parent.zoomScale,
        showsInlineDiagnosticMessages: parent.showsInlineDiagnosticMessages
      )
      let previous = presentationState
      let contentChanged = previous?.textRevision != next.textRevision
      let presentationChanged = previous?.presentationRevision != next.presentationRevision
      let configurationChanged =
        previous.map {
          $0.liveMarkdownStyling != next.liveMarkdownStyling
            || $0.showsMarkdownSyntax != next.showsMarkdownSyntax
            || $0.profile != next.profile
            || $0.zoomScale != next.zoomScale
            || $0.showsInlineDiagnosticMessages != next.showsInlineDiagnosticMessages
        } ?? true
      let selectionChanged = styledSelection != currentSelection
      guard contentChanged || presentationChanged || configurationChanged || selectionChanged else {
        return
      }

      let isLiveMarkdown =
        parent.liveMarkdownStyling
        && (textView.string as NSString).length <= editorRichPresentationUTF16Limit
        && parent.languageID.lowercased() == "markdown"
      let needsFullPresentation =
        previous == nil
        || presentationChanged
        || configurationChanged
        || (contentChanged && (pendingPresentationRange == nil || isLiveMarkdown))

      let wasApplyingExternalUpdate = isApplyingExternalUpdate
      isApplyingExternalUpdate = true
      if needsFullPresentation {
        parent.applyPresentation(to: textView)
      } else if contentChanged, let affectedRange = pendingPresentationRange {
        parent.applyPresentation(to: textView, affectedRange: affectedRange)
      } else if parent.selectionChangeRequiresMarkdownRestyle(
        in: textView.string,
        previousSelection: styledSelection,
        currentSelection: currentSelection
      ) {
        parent.applyPresentation(to: textView)
      } else if selectionChanged {
        parent.refreshSelectionPresentation(
          to: textView,
          previousSelection: styledSelection,
          currentSelection: currentSelection
        )
      }
      presentationState = next
      pendingPresentationRange = nil
      styledSelection = currentSelection
      isApplyingExternalUpdate = wasApplyingExternalUpdate
    }

    func configureVim(for textView: NSTextView) {
      let profile = parent.profile.vim
      guard profile.enabled else {
        vimController = nil
        synchronizedVimTextRevision = nil
        vimConfigurationSignature = ""
        updateVimCursorStyle(for: .insert, in: textView, isEnabled: false)
        publishVimMode(.insert)
        publishVimPrompt(nil)
        return
      }

      let mappings = profile.mappings.map {
        VimKeyMapping(sequence: $0.sequence, command: $0.command)
      }
      let signature =
        ([profile.normalizedLeader, String(parent.profile.behavior.tabWidth)]
        + mappings.map { "\($0.sequence)=\($0.command)" })
        .joined(separator: "|")
      if vimController == nil {
        let engine = VimEngine(
          text: textView.string,
          cursor: textView.selectedRange().location,
          leader: profile.normalizedLeader,
          localLeader: profile.normalizedLeader,
          tabWidth: parent.profile.behavior.tabWidth
        )
        vimController = VimKeymapController(engine: engine, mappings: mappings)
        synchronizedVimTextRevision = parent.textRevision
        if profile.startInInsertMode {
          _ = try? engine.execute(.action(.enterInsert))
        }
      } else if signature != vimConfigurationSignature {
        vimController?.engine.leader = profile.normalizedLeader
        vimController?.engine.localLeader = profile.normalizedLeader
        vimController?.engine.tabWidth = max(1, parent.profile.behavior.tabWidth)
        vimController?.setMappings(mappings)
      }
      vimConfigurationSignature = signature

      if let controller = vimController {
        synchronizeVimControllerIfNeeded(controller, with: textView)
        let mode = controller.engine.state.mode
        updateVimCursorStyle(for: mode, in: textView)
        publishVimMode(mode)
        publishVimPrompt(controller.prompt)
      }
    }

    func handleKeyEvent(_ event: NSEvent, in textView: NSTextView) -> Bool {
      guard parent.profile.vim.enabled else { return false }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if flags.contains(.command) { return false }
      configureVim(for: textView)
      guard let controller = vimController,
        let token = vimToken(for: event, mode: controller.engine.state.mode)
      else { return false }

      synchronizeVimControllerIfNeeded(controller, with: textView)
      do {
        let result = try controller.handle(token: token)
        guard result.consumed else { return false }
        if let execution = result.execution {
          applyVimExecution(execution, to: textView)
        } else {
          let mode = controller.engine.state.mode
          updateVimCursorStyle(for: mode, in: textView)
          publishVimMode(mode)
        }
        publishVimPrompt(controller.prompt)
        restoreEditorFocus(after: textView)
        return true
      } catch VimError.unsupportedNotation {
        NSSound.beep()
        return true
      } catch {
        NSSound.beep()
        controller.resetPendingInput()
        controller.cancelPrompt()
        publishVimPrompt(nil)
        return true
      }
    }

    func handleZoom(_ delta: CGFloat, _: NSTextView) -> Bool {
      parent.onZoomChange(delta)
      return true
    }

    private func restoreEditorFocus(after textView: NSTextView) {
      // Vim commands can publish state or invoke a host action, which causes
      // SwiftUI to update the representable and may briefly move focus away
      // from the editor. Restore it on the next run-loop turn, after those
      // updates have had a chance to finish.
      Task { @MainActor [weak textView] in
        await Task.yield()
        guard let textView, let window = textView.window,
          textView.superview != nil
        else { return }
        window.makeFirstResponder(textView)
      }
    }

    func textView(
      _ textView: NSTextView,
      shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?
    ) -> Bool {
      guard !isApplyingExternalUpdate else { return true }
      let replacement = replacementString ?? ""
      if handleTypingUtility(
        in: textView,
        affectedRange: affectedCharRange,
        replacement: replacement
      ) {
        return false
      }
      pendingEdit = (affectedCharRange, replacement)
      parent.onWillEdit()
      return true
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      handleObservedTextChange(in: textView)
    }

    func handleObservedTextChange(in textView: NSTextView) {
      guard !isApplyingExternalUpdate else { return }

      let resultingText = textView.string
      guard resultingText != synchronizedText else {
        pendingEdit = nil
        return
      }

      let edit: (range: NSRange, replacement: String)
      if let pendingEdit,
        Self.applying(
          pendingEdit,
          to: synchronizedText
        ) == resultingText
      {
        edit = pendingEdit
      } else {
        edit = Self.singleEdit(from: synchronizedText, to: resultingText)
      }
      self.pendingEdit = nil
      synchronizedText = resultingText

      pendingPresentationRange = affectedPresentationRange(
        in: resultingText,
        editedRange: edit.range,
        replacement: edit.replacement
      )
      publishEdit(
        range: edit.range,
        replacement: edit.replacement,
        resultingText: resultingText,
        selection: textView.selectedRange()
      )
      reloadEditorGeometry(
        for: textView,
        editedRange: edit.range,
        replacement: edit.replacement
      )
      scheduleCaretPublication(for: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard !isApplyingExternalUpdate,
        let textView = notification.object as? NSTextView
      else { return }
      if let codeTextView = textView as? CodeEditorTextView {
        codeTextView.refreshCustomInsertionPoint()
        codeTextView.window?.invalidateCursorRects(for: codeTextView)
      }
      publishSelection(textView.selectedRange())
      textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
      scheduleCaretPublication(for: textView)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      switch commandSelector {
      case #selector(NSResponder.moveDown(_:)) where parent.hasCompletions:
        parent.onMoveCompletionDown()
        return true
      case #selector(NSResponder.moveUp(_:)) where parent.hasCompletions:
        parent.onMoveCompletionUp()
        return true
      case #selector(NSResponder.cancelOperation(_:)) where parent.hasCompletions:
        parent.onDismissCompletions()
        return true
      case #selector(NSResponder.complete(_:)):
        parent.onRequestCompletions()
        return true
      case #selector(NSResponder.insertNewline(_:)) where parent.hasCompletions:
        parent.onAcceptCompletion()
        return true
      case #selector(NSResponder.insertNewline(_:))
      where parent.profile.typing.smartNewlines && !isMarkdownDocument:
        insertSmartNewline(in: textView)
        return true
      case #selector(NSResponder.insertTab(_:)):
        if parent.onMoveToNextSnippetStop() { return true }
        parent.onDismissCompletions()
        insertIndent(in: textView)
        return true
      case #selector(NSResponder.insertBacktab(_:)):
        if parent.onMoveToPreviousSnippetStop() { return true }
        parent.onDismissCompletions()
        removeIndent(in: textView)
        return true
      case #selector(NSResponder.deleteBackward(_:)) where parent.profile.typing.deleteBalancedPairs:
        return deleteBalancedPairIfNeeded(in: textView)
      default:
        return false
      }
    }

    private func publishVimPrompt(_ prompt: String?) {
      if hasPublishedVimPrompt, lastPublishedVimPrompt == prompt { return }
      hasPublishedVimPrompt = true
      lastPublishedVimPrompt = prompt
      if representableUpdateDepth > 0 {
        deferredVimPrompt = prompt
        hasDeferredVimPrompt = true
        scheduleDeferredPublicationsIfNeeded()
      } else {
        parent.onVimPromptChange(prompt)
      }
    }

    private func updateVimCursorStyle(
      for mode: VimMode,
      in textView: NSTextView,
      isEnabled: Bool = true
    ) {
      guard let codeTextView = textView as? CodeEditorTextView else { return }
      guard isEnabled else {
        codeTextView.vimCursorStyle = nil
        return
      }

      switch mode {
      case .insert:
        codeTextView.vimCursorStyle = parent.profile.vim.insertCursorStyle.overrideStyle
      case .replace:
        codeTextView.vimCursorStyle = parent.profile.vim.replaceCursorStyle.overrideStyle
      case .normal, .visualCharacter, .visualLine, .visualBlock, .commandLine, .search:
        codeTextView.vimCursorStyle = parent.profile.vim.normalCursorStyle.overrideStyle
      }
    }

    private func publishVimMode(_ mode: VimMode) {
      guard lastPublishedVimMode != mode else { return }
      lastPublishedVimMode = mode
      if representableUpdateDepth > 0 {
        deferredVimMode = mode
        scheduleDeferredPublicationsIfNeeded()
      } else {
        parent.onVimModeChange(mode)
      }
    }

    private func publishSelection(_ range: NSRange) {
      guard lastPublishedSelection != range else { return }
      lastPublishedSelection = range
      if representableUpdateDepth > 0 {
        deferredSelection = range
        scheduleDeferredPublicationsIfNeeded()
      } else {
        parent.onSelectionChange(range)
      }
    }

    private func scheduleDeferredPublicationsIfNeeded() {
      guard !publicationFlushScheduled,
        deferredSelection != nil || deferredVimMode != nil || hasDeferredVimPrompt
      else { return }
      publicationFlushScheduled = true
      Task { @MainActor [weak self] in
        await Task.yield()
        guard let self, !Task.isCancelled else { return }
        self.publicationFlushScheduled = false
        guard self.representableUpdateDepth == 0 else {
          self.scheduleDeferredPublicationsIfNeeded()
          return
        }

        let selection = self.deferredSelection
        let mode = self.deferredVimMode
        let prompt = self.deferredVimPrompt
        let publishesPrompt = self.hasDeferredVimPrompt
        self.deferredSelection = nil
        self.deferredVimMode = nil
        self.deferredVimPrompt = nil
        self.hasDeferredVimPrompt = false

        if let selection { self.parent.onSelectionChange(selection) }
        if let mode { self.parent.onVimModeChange(mode) }
        if publishesPrompt { self.parent.onVimPromptChange(prompt) }
      }
    }

    private func vimToken(for event: NSEvent, mode _: VimMode) -> String? {
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      switch event.keyCode {
      case 36, 76: return "<CR>"
      case 48: return "<Tab>"
      case 51: return "<BS>"
      case 53: return "<Esc>"
      case 115: return "<Home>"
      case 117: return "<Del>"
      case 119: return "<End>"
      case 123: return "<Left>"
      case 124: return "<Right>"
      case 125: return "<Down>"
      case 126: return "<Up>"
      case 116: return "<PageUp>"
      case 121: return "<PageDown>"
      default: break
      }
      guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
        return nil
      }
      if flags.contains(.control), let character = characters.lowercased().first {
        return "<C-\(character)>"
      }
      return event.characters ?? characters
    }

    private func synchronizeVimControllerIfNeeded(
      _ controller: VimKeymapController,
      with textView: NSTextView
    ) {
      let currentRanges = textView.selectedRanges.map(\.rangeValue)
      let expectedRanges = vimSelections(from: controller.engine.state)
      let textChanged =
        synchronizedVimTextRevision != parent.textRevision
        || controller.engine.state.text != textView.string
      guard textChanged || currentRanges != expectedRanges else { return }
      let cursor = currentRanges.first?.location ?? textView.selectedRange().location
      controller.synchronize(text: textView.string, cursor: cursor)
      synchronizedVimTextRevision = parent.textRevision
    }

    private func applyVimExecution(_ execution: VimExecutionResult, to textView: NSTextView) {
      let state = execution.state
      updateVimCursorStyle(for: state.mode, in: textView)
      let selections = vimSelections(from: state)
      let primarySelection = vimPrimarySelection(from: selections, state: state)
      let selectionValues = selections.map { NSValue(range: $0) }
      if state.text != textView.string {
        let edit = Self.singleEdit(from: textView.string, to: state.text)
        isApplyingExternalUpdate = true
        textView.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.setSelectedRanges(selectionValues, affinity: .downstream, stillSelecting: false)
        textView.scrollRangeToVisible(primarySelection)
        isApplyingExternalUpdate = false
        (textView as? CodeEditorTextView)?.refreshCustomInsertionPoint()
        synchronizedVimTextRevision = publishEdit(
          range: edit.range,
          replacement: edit.replacement,
          resultingText: state.text,
          selection: primarySelection
        )
        pendingPresentationRange = affectedPresentationRange(
          in: state.text,
          editedRange: edit.range,
          replacement: edit.replacement
        )
        reloadEditorGeometry(
          for: textView,
          editedRange: edit.range,
          replacement: edit.replacement
        )
        scheduleCaretPublication(for: textView)
      } else {
        let currentRanges = textView.selectedRanges.map(\.rangeValue)
        if currentRanges != selections {
          isApplyingExternalUpdate = true
          textView.setSelectedRanges(selectionValues, affinity: .downstream, stillSelecting: false)
          textView.scrollRangeToVisible(primarySelection)
          isApplyingExternalUpdate = false
          (textView as? CodeEditorTextView)?.refreshCustomInsertionPoint()
          publishSelection(primarySelection)
          reloadEditorGeometry(for: textView)
          scheduleCaretPublication(for: textView)
        }
      }
      publishVimMode(state.mode)
      for request in execution.hostRequests { parent.onVimHostRequest(request) }
    }

    private func vimSelections(from state: VimState) -> [NSRange] {
      let length = (state.text as NSString).length
      if let visual = state.selection, !visual.ranges.isEmpty {
        return visual.ranges.map { range in
          let lower = min(max(range.lowerBound, 0), length)
          let upper = min(max(range.upperBound, lower), length)
          return NSRange(location: lower, length: upper - lower)
        }
      }
      return [NSRange(location: min(max(state.cursor, 0), length), length: 0)]
    }

    private func vimPrimarySelection(from selections: [NSRange], state: VimState) -> NSRange {
      guard let first = selections.first else {
        return NSRange(location: max(0, state.cursor), length: 0)
      }
      guard selections.count > 1 else { return first }
      let lower = selections.map(\.location).min() ?? first.location
      let upper = selections.map(NSMaxRange).max() ?? NSMaxRange(first)
      return NSRange(location: lower, length: max(0, upper - lower))
    }

    private static func applying(
      _ edit: (range: NSRange, replacement: String),
      to source: String
    ) -> String? {
      let value = source as NSString
      guard edit.range.location >= 0,
        edit.range.length >= 0,
        NSMaxRange(edit.range) <= value.length
      else { return nil }
      return value.replacingCharacters(in: edit.range, with: edit.replacement)
    }

    private static func singleEdit(from old: String, to new: String) -> (
      range: NSRange, replacement: String
    ) {
      let oldCharacters = Array(old)
      let newCharacters = Array(new)
      var prefixCharacters = 0
      while prefixCharacters < oldCharacters.count,
        prefixCharacters < newCharacters.count,
        oldCharacters[prefixCharacters] == newCharacters[prefixCharacters]
      {
        prefixCharacters += 1
      }
      var suffixCharacters = 0
      while suffixCharacters < oldCharacters.count - prefixCharacters,
        suffixCharacters < newCharacters.count - prefixCharacters,
        oldCharacters[oldCharacters.count - suffixCharacters - 1]
          == newCharacters[newCharacters.count - suffixCharacters - 1]
      {
        suffixCharacters += 1
      }
      let prefix = oldCharacters.prefix(prefixCharacters).reduce(0) { $0 + String($1).utf16.count }
      let oldSuffix = oldCharacters.suffix(suffixCharacters).reduce(0) {
        $0 + String($1).utf16.count
      }
      let newSuffix = newCharacters.suffix(suffixCharacters).reduce(0) {
        $0 + String($1).utf16.count
      }
      let oldLength = old.utf16.count
      let newLength = new.utf16.count
      let replacement = (new as NSString).substring(
        with: NSRange(location: prefix, length: max(0, newLength - prefix - newSuffix))
      )
      return (
        NSRange(location: prefix, length: max(0, oldLength - prefix - oldSuffix)),
        replacement
      )
    }

    private func handleTypingUtility(
      in textView: NSTextView,
      affectedRange: NSRange,
      replacement: String
    ) -> Bool {
      guard parent.profile.typing.closePairs,
        replacement.utf16.count == 1,
        let character = replacement.first
      else { return false }

      if let closing = Self.pairs[character] {
        if affectedRange.length > 0, parent.profile.typing.surroundSelection {
          let source = textView.string as NSString
          let selected = source.substring(with: affectedRange)
          let value = String(character) + selected + String(closing)
          let selection = NSRange(
            location: affectedRange.location + 1,
            length: affectedRange.length
          )
          applyUtilityEdit(
            in: textView, range: affectedRange, replacement: value, selection: selection)
          return true
        }
        guard affectedRange.length == 0,
          shouldClosePair(character, at: affectedRange.location, in: textView.string)
        else { return false }
        let value = String(character) + String(closing)
        let selection = NSRange(location: affectedRange.location + 1, length: 0)
        applyUtilityEdit(
          in: textView, range: affectedRange, replacement: value, selection: selection)
        return true
      }

      guard Self.closingCharacters.contains(character), affectedRange.length == 0 else {
        return false
      }
      let source = textView.string as NSString
      if affectedRange.location < source.length,
        source.substring(with: NSRange(location: affectedRange.location, length: 1)) == replacement
      {
        let selection = NSRange(location: affectedRange.location + 1, length: 0)
        textView.setSelectedRange(selection)
        parent.onSelectionChange(selection)
        return true
      }
      if isWhitespaceOnlyBeforeCaret(affectedRange.location, in: source) {
        let lineRange = source.lineRange(for: NSRange(location: affectedRange.location, length: 0))
        let prefixRange = NSRange(
          location: lineRange.location,
          length: affectedRange.location - lineRange.location
        )
        let prefix = source.substring(with: prefixRange)
        let dedented = removingOneIndent(from: prefix)
        if dedented != prefix {
          applyUtilityEdit(
            in: textView,
            range: prefixRange,
            replacement: dedented + replacement,
            selection: NSRange(location: lineRange.location + dedented.utf16.count + 1, length: 0)
          )
          return true
        }
      }
      return false
    }

    private func shouldClosePair(_ character: Character, at location: Int, in text: String) -> Bool
    {
      guard character == "\"" || character == "'" || character == "`" else { return true }
      let source = text as NSString
      if location > 0,
        source.substring(with: NSRange(location: location - 1, length: 1)) == "\\"
      {
        return false
      }
      if character == "'" {
        let before =
          location > 0 ? source.substring(with: NSRange(location: location - 1, length: 1)) : ""
        let after =
          location < source.length
          ? source.substring(with: NSRange(location: location, length: 1)) : ""
        if before.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic })
          && after.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic })
        {
          return false
        }
      }
      return true
    }

    private func insertSmartNewline(in textView: NSTextView) {
      let source = textView.string as NSString
      let selection = textView.selectedRange()
      let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
      let beforeRange = NSRange(
        location: lineRange.location,
        length: selection.location - lineRange.location
      )
      let before = source.substring(with: beforeRange)
      let leading = String(before.prefix { $0 == " " || $0 == "\t" })
      let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
      let nextCharacter =
        selection.location < source.length
        ? source.substring(with: NSRange(location: selection.location, length: 1))
        : ""
      let previousCharacter = trimmedBefore.last.map(String.init) ?? ""
      let indent = indentationUnit
      let opensBlock =
        Self.openingCharacters.contains(previousCharacter.first ?? "\0")
        || (usesColonBlocks && previousCharacter == ":")
      let closesPair = Self.pairs[previousCharacter.first ?? "\0"].map(String.init) == nextCharacter

      let replacement: String
      let caretOffset: Int
      if closesPair {
        replacement = "\n" + leading + indent + "\n" + leading
        caretOffset = 1 + leading.utf16.count + indent.utf16.count
      } else if shouldExpandEmptyBlockComment(
        linePrefix: before,
        nextCharacter: nextCharacter
      ) {
        let commentIndent = leading + " * "
        replacement = "\n" + commentIndent + "\n" + leading + " */"
        caretOffset = 1 + commentIndent.utf16.count
      } else {
        let continuation = commentContinuation(in: before)
        let nextIndent = leading + (opensBlock ? indent : "") + continuation
        replacement = "\n" + nextIndent
        caretOffset = replacement.utf16.count
      }
      applyUtilityEdit(
        in: textView,
        range: selection,
        replacement: replacement,
        selection: NSRange(location: selection.location + caretOffset, length: 0)
      )
    }

    private func commentContinuation(in linePrefix: String) -> String {
      let trimmed = linePrefix.drop { $0 == " " || $0 == "\t" }
      for marker in lineCommentMarkers where trimmed.hasPrefix(marker) {
        let content = String(trimmed.dropFirst(marker.count))
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
          return ""
        }
        return marker
      }
      if isInsideBlockComment(linePrefix) { return " * " }
      return ""
    }

    /// Keeps comment continuation language-aware without requiring a syntax service
    /// update on every keystroke. Longest markers must precede their shorter forms.
    private var lineCommentMarkers: [String] {
      switch parent.languageID.lowercased() {
      case "rust": return ["//! ", "/// ", "// "]
      case "swift", "c", "cpp", "c++", "objective-c", "java", "javascript", "typescript",
        "kotlin", "csharp", "go", "dart", "php", "scala", "groovy", "jsonc", "scss", "less":
        return ["/// ", "//! ", "// "]
      case "lua", "sql", "haskell": return ["-- "]
      case "python", "ruby", "shell", "bash", "zsh", "fish", "yaml", "toml", "makefile":
        return ["# "]
      case "visual-basic", "vb": return ["' ", "REM "]
      default: return ["/// ", "//! ", "// ", "# ", "-- "]
      }
    }

    private func isInsideBlockComment(_ linePrefix: String) -> Bool {
      guard let opening = linePrefix.range(of: "/*", options: .backwards) else { return false }
      let afterOpening = linePrefix[opening.upperBound...]
      return !afterOpening.contains("*/")
    }

    private func shouldExpandEmptyBlockComment(linePrefix: String, nextCharacter: String) -> Bool {
      guard nextCharacter.isEmpty else { return false }
      let trimmed = linePrefix.trimmingCharacters(in: .whitespaces)
      return trimmed == "/*" || trimmed == "/**"
    }

    private var usesColonBlocks: Bool {
      ["python", "yaml"].contains(parent.languageID.lowercased())
    }

    private var isMarkdownDocument: Bool {
      parent.languageID.lowercased() == "markdown"
    }

    private var indentationUnit: String {
      parent.profile.behavior.insertSpaces
        ? String(repeating: " ", count: max(1, parent.profile.behavior.tabWidth))
        : "\t"
    }

    private func deleteBalancedPairIfNeeded(in textView: NSTextView) -> Bool {
      let selection = textView.selectedRange()
      guard selection.length == 0, selection.location > 0 else { return false }
      let source = textView.string as NSString
      guard selection.location < source.length else { return false }
      let opening = source.substring(with: NSRange(location: selection.location - 1, length: 1))
      let closing = source.substring(with: NSRange(location: selection.location, length: 1))
      guard let openingCharacter = opening.first,
        Self.pairs[openingCharacter].map(String.init) == closing
      else { return false }
      applyUtilityEdit(
        in: textView,
        range: NSRange(location: selection.location - 1, length: 2),
        replacement: "",
        selection: NSRange(location: selection.location - 1, length: 0)
      )
      return true
    }

    private func applyUtilityEdit(
      in textView: NSTextView,
      range: NSRange,
      replacement: String,
      selection: NSRange
    ) {
      pendingEdit = nil
      isApplyingExternalUpdate = true
      textView.insertText(replacement, replacementRange: range)
      textView.setSelectedRange(selection)
      textView.scrollRangeToVisible(selection)
      synchronizedText = textView.string
      isApplyingExternalUpdate = false
      publishEdit(
        range: range,
        replacement: replacement,
        resultingText: synchronizedText,
        selection: selection
      )
      pendingPresentationRange = affectedPresentationRange(
        in: textView.string,
        editedRange: range,
        replacement: replacement
      )
      reloadEditorGeometry(
        for: textView,
        editedRange: range,
        replacement: replacement
      )
      scheduleCaretPublication(for: textView)
    }

    private func insertIndent(in textView: NSTextView) {
      let width = max(1, parent.profile.behavior.tabWidth)
      let selection = textView.selectedRange()
      let source = textView.string as NSString
      if selection.length > 0,
        source.substring(with: selection).contains("\n")
      {
        let lineRange = source.lineRange(for: selection)
        let original = source.substring(with: lineRange)
        let replacement =
          original
          .split(separator: "\n", omittingEmptySubsequences: false)
          .map { indentationUnit + $0 }
          .joined(separator: "\n")
        applyUtilityEdit(
          in: textView,
          range: lineRange,
          replacement: replacement,
          selection: NSRange(location: lineRange.location, length: replacement.utf16.count)
        )
        return
      }

      if parent.profile.behavior.insertSpaces {
        let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let column = max(0, selection.location - lineRange.location)
        let count = width - (column % width)
        let spaces = String(repeating: " ", count: count)
        applyUtilityEdit(
          in: textView,
          range: selection,
          replacement: spaces,
          selection: NSRange(location: selection.location + spaces.utf16.count, length: 0)
        )
      } else {
        applyUtilityEdit(
          in: textView,
          range: selection,
          replacement: "\t",
          selection: NSRange(location: selection.location + 1, length: 0)
        )
      }
    }

    private func removeIndent(in textView: NSTextView) {
      let source = textView.string as NSString
      let selection = textView.selectedRange()
      let lineRange = source.lineRange(for: selection)
      let original = source.substring(with: lineRange)
      let lines = original.split(separator: "\n", omittingEmptySubsequences: false)
      var changed = false
      let replacement = lines.map { line -> String in
        let value = removingOneIndent(from: String(line))
        if value.count != line.count { changed = true }
        return value
      }.joined(separator: "\n")
      guard changed else { return }
      applyUtilityEdit(
        in: textView,
        range: lineRange,
        replacement: replacement,
        selection: NSRange(location: lineRange.location, length: replacement.utf16.count)
      )
    }

    private func removingOneIndent(from value: String) -> String {
      if value.hasPrefix("\t") { return String(value.dropFirst()) }
      let count = min(max(1, parent.profile.behavior.tabWidth), value.prefix { $0 == " " }.count)
      return String(value.dropFirst(count))
    }

    private func isWhitespaceOnlyBeforeCaret(_ location: Int, in source: NSString) -> Bool {
      let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
      let range = NSRange(location: lineRange.location, length: location - lineRange.location)
      return source.substring(with: range).allSatisfy { $0 == " " || $0 == "\t" }
    }

    @discardableResult
    private func publishEdit(
      range: NSRange,
      replacement: String,
      resultingText: String,
      selection: NSRange
    ) -> UInt64 {
      parent.onWillEdit()
      let targetRevision =
        max(
          renderedTextRevision,
          expectedLocalTextRevision ?? renderedTextRevision
        ) &+ 1
      expectedLocalTextRevision = targetRevision
      parent.onEdit(range, replacement, resultingText, selection)
      return targetRevision
    }

    private func reloadEditorGeometry(
      for textView: NSTextView,
      editedRange: NSRange? = nil,
      replacement: String = ""
    ) {
      if let editedRange {
        (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?
          .applyEdit(
            range: editedRange,
            replacement: replacement,
            resultingText: textView.string
          )
      }
      (textView.enclosingScrollView as? CodeTextScrollView)?.requestDocumentSizeSync()
    }

    private func affectedPresentationRange(
      in text: String,
      editedRange: NSRange,
      replacement: String
    ) -> NSRange {
      let source = text as NSString
      guard source.length > 0 else { return NSRange(location: 0, length: 0) }
      let location = min(max(editedRange.location, 0), source.length)
      let replacementLength = (replacement as NSString).length
      let probe = min(location, source.length - 1)
      var affected = source.lineRange(
        for: NSRange(location: probe, length: min(max(replacementLength, 1), source.length - probe))
      )
      if affected.location > 0 {
        affected = NSUnionRange(
          affected,
          source.lineRange(for: NSRange(location: affected.location - 1, length: 0))
        )
      }
      if NSMaxRange(affected) < source.length {
        affected = NSUnionRange(
          affected,
          source.lineRange(for: NSRange(location: NSMaxRange(affected), length: 0))
        )
      }
      return affected
    }

    func scheduleCaretPublication(for textView: NSTextView) {
      caretPublicationTask?.cancel()
      caretPublicationTask = Task { @MainActor [weak self, weak textView] in
        await Task.yield()
        guard let self, let textView, !Task.isCancelled else { return }
        self.publishCaretRect(for: textView)
      }
    }

    private func publishCaretRect(for textView: NSTextView) {
      guard let layoutManager = textView.layoutManager,
        let textContainer = textView.textContainer,
        let scrollView = textView.enclosingScrollView
      else { return }
      layoutManager.ensureLayout(for: textContainer)
      let sourceLength = (textView.string as NSString).length
      let location = min(max(textView.selectedRange().location, 0), sourceLength)
      let caretRect: NSRect
      if sourceLength == 0 || location == sourceLength {
        caretRect = layoutManager.extraLineFragmentRect
      } else {
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        caretRect = layoutManager.boundingRect(
          forGlyphRange: NSRange(location: glyph, length: 1),
          in: textContainer
        )
      }
      let lineHeight = max(caretRect.height, textView.font?.boundingRectForFont.height ?? 14)
      let textRect = NSRect(
        x: caretRect.minX + textView.textContainerOrigin.x,
        y: caretRect.minY + textView.textContainerOrigin.y,
        width: max(1, caretRect.width),
        height: lineHeight
      )
      let clipView = scrollView.contentView
      let rectInClip = textView.convert(textRect, to: clipView)
      let x = rectInClip.minX - clipView.bounds.minX + clipView.frame.minX
      let y: CGFloat
      if clipView.isFlipped {
        y = rectInClip.minY - clipView.bounds.minY + clipView.frame.minY
      } else {
        y = clipView.bounds.maxY - rectInClip.maxY + clipView.frame.minY
      }
      let result = CGRect(x: x, y: y, width: max(1, rectInClip.width), height: lineHeight)
      guard lastPublishedCaretRect != result else { return }
      lastPublishedCaretRect = result
      parent.onCaretRectChange(result)
    }

    private static let pairs: [Character: Character] = [
      "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`",
    ]
    private static let closingCharacters = Set(pairs.values)
    private static let openingCharacters = Set(pairs.keys)
  }

}
