import AppKit
import EditorServices
@_spi(Calcite) import EditorVim
import SwiftUI
import UniformTypeIdentifiers

struct CalciteEditorSurface: View {
  @ObservedObject var tab: EditorTab
  @ObservedObject var editorSession: CalciteBackendWindowSession.EditorSession
  let isActiveDocument: Bool
  let onActivate: () -> Void
  @State private var zoomScale: CGFloat = 1
  @State private var vimPresentationRevision: UInt64 = 0
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
  let vimController: VimKeymapController?
  var onVimHistoryChange: ((VimHistorySnapshot) -> Void)? = nil
  let onVimHostInvocation: (VimHostInvocation) -> VimHostResponse
  let onGoToDefinition: () -> Void
  let onFindReferences: () -> Void
  let onShowQuickHelp: () -> Void
  let onShowQuickFixes: (Diagnostic) -> Void
  let onSelectInputMode: (EditorInterface) -> Void
  let commandEvent: EditorTabCommandEvent?

  var body: some View {
    VStack(spacing: 0) {
      editorPane

      CalciteEditorStatusBar(
        tab: tab,
        selectedRange: surfaceSelectedRange,
        profile: profile,
        editorMode: editorMode,
        vimController: vimController,
        vimPresentationRevision: vimPresentationRevision,
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
      setZoom(1)
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
        selectedRange: surfaceSelectedRange,
        hasCompletions: !tab.completions.isEmpty,
        documentURL: tab.url,
        documentID: tab.id,
        editorSessionID: editorSession.id,
        isActiveSurface: isActiveDocument,
        tabPageID: nil,
        sharedVimController: vimController,
        onWillEdit: tab.markModified,
        onEdit: { range, replacement, resultingText, selectionAfter in
          guard isActiveDocument else { return }
          onActivate()
          editorSession.updateSelection(selectionAfter, for: tab)
          tab.submitEdit(
            range: range,
            replacement: replacement,
            resultingText: resultingText,
            selectionAfter: selectionAfter,
            suggestionDelay: profile.behavior.suggestionDelay
          )
        },
        onVimEdit: { transaction, selectionAfter in
          guard isActiveDocument else { return }
          onActivate()
          editorSession.updateSelection(selectionAfter, for: tab)
          tab.submitVimTransaction(
            transaction,
            selectionAfter: selectionAfter,
            suggestionDelay: profile.behavior.suggestionDelay
          )
        },
        onSelectionChange: { range in
          guard isActiveDocument else { return }
          onActivate()
          editorSession.updateSelection(range, for: tab)
        },
        onToggleBreakpoint: { line in
          guard isActiveDocument else { return }
          onActivate()
          let selection = selectedRange(forLine: line, in: tab.text)
          editorSession.updateSelection(selection, for: tab)
          tab.updateSelection(selection)
          tab.toggleBreakpointAtCurrentLine()
        },
        onAcceptCompletion: tab.acceptSelectedCompletion,
        onMoveCompletionDown: tab.selectNextCompletion,
        onMoveCompletionUp: tab.selectPreviousCompletion,
        onDismissCompletions: tab.dismissCompletions,
        onRequestCompletions: tab.requestCompletionsExplicitly,
        onMoveToNextSnippetStop: tab.moveToNextSnippetStop,
        onMoveToPreviousSnippetStop: tab.moveToPreviousSnippetStop,
        onVimHostInvocation: onVimHostInvocation,
        onGoToDefinition: onGoToDefinition,
        onFindReferences: onFindReferences,
        onShowQuickHelp: onShowQuickHelp,
        onShowFind: { replace in
          showsFind = true
          showsReplace = replace
        },
        zoomScale: effectiveZoomScale,
        onZoomChange: { updateZoom(by: $0) },
        onVimStateChange: {
          vimPresentationRevision &+= 1
          if let snapshot = vimController?.historySnapshot {
            onVimHistoryChange?(snapshot)
          }
        },
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
          selection: surfaceSelectedRange,
          query: $findQuery,
          replacement: $replacement,
          showsReplace: $showsReplace,
          close: dismissFindReplace,
          select: { range in
            onActivate()
            editorSession.updateSelection(range, for: tab)
          },
          replaceCurrent: { range in replace(range: range, with: replacement) },
          replaceAll: replaceAll
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(12)
      }
    }
  }

  private var surfaceSelectedRange: NSRange {
    guard profile.vim.enabled, let vimController else {
      return editorSession.selection(for: tab)
    }
    return CalciteVimSelectionPresenter.presentation(
      for: vimController.engine.state,
      selectionSet: vimController.engine.selectionSet
    ).primaryRange
  }

  private var effectiveZoomScale: CGFloat {
    guard profile.vim.enabled, let vimController else { return zoomScale }
    return CGFloat(vimController.engine.windowPresentationState.zoomScale)
  }

  private func replace(range: NSRange, with value: String) {
    let source = tab.text as NSString
    let text = source.replacingCharacters(in: range, with: value)
    let selection = NSRange(location: range.location, length: (value as NSString).length)
    onActivate()
    editorSession.updateSelection(selection, for: tab)
    tab.submitEdit(
      range: range, replacement: value, resultingText: text, selectionAfter: selection,
      suggestionDelay: profile.behavior.suggestionDelay)
  }

  private func dismissFindReplace() {
    showsFind = false
    showsReplace = false
  }

  private func updateZoom(by delta: CGFloat) {
    setZoom(effectiveZoomScale + delta)
  }

  private func updateZoom(_ delta: CGFloat) {
    updateZoom(by: delta)
  }

  private func setZoom(_ value: CGFloat) {
    let clamped = min(2, max(0.5, value))
    if profile.vim.enabled, let vimController {
      vimController.engine.updateWindowPresentation(zoomScale: Double(clamped))
      vimPresentationRevision &+= 1
    } else {
      zoomScale = clamped
    }
  }

  private func replaceAll() {
    guard !findQuery.isEmpty else { return }
    let text = tab.text.replacingOccurrences(of: findQuery, with: replacement)
    guard text != tab.text else { return }
    tab.submitEdit(
      range: NSRange(location: 0, length: (tab.text as NSString).length), replacement: text,
      resultingText: text, selectionAfter: surfaceSelectedRange,
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
  let documentURL: URL?
  let documentID: UUID?
  let editorSessionID: UUID?
  let isActiveSurface: Bool
  let tabPageID: UUID?
  let sharedVimController: VimKeymapController?
  let onWillEdit: () -> Void
  let onEdit: (NSRange, String, String, NSRange) -> Void
  let onVimEdit: (VimEditTransaction, NSRange) -> Void
  let onSelectionChange: (NSRange) -> Void
  let onToggleBreakpoint: (Int) -> Void
  let onAcceptCompletion: () -> Void
  let onMoveCompletionDown: () -> Void
  let onMoveCompletionUp: () -> Void
  let onDismissCompletions: () -> Void
  let onRequestCompletions: () -> Void
  let onMoveToNextSnippetStop: () -> Bool
  let onMoveToPreviousSnippetStop: () -> Bool
  let onVimHostInvocation: (VimHostInvocation) -> VimHostResponse
  let onGoToDefinition: () -> Void
  let onFindReferences: () -> Void
  let onShowQuickHelp: () -> Void
  let onShowFind: (Bool) -> Void
  let zoomScale: CGFloat
  let onZoomChange: (CGFloat) -> Void
  let onVimStateChange: () -> Void
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
    textView.textInputHandler = { [weak coordinator = context.coordinator] value, range, view in
      coordinator?.handleTextInput(value, replacementRange: range, in: view) ?? false
    }
    textView.markedTextHandler = {
      [weak coordinator = context.coordinator] value, selectedRange, replacementRange, view in
      coordinator?.handleMarkedText(
        value,
        selectedRange: selectedRange,
        replacementRange: replacementRange,
        in: view
      ) ?? false
    }
    textView.unmarkTextHandler = { [weak coordinator = context.coordinator] view in
      coordinator?.handleUnmarkText(in: view) ?? false
    }
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
    textView.nativePointerSelectionHandler = {
      [weak coordinator = context.coordinator] range, textView in
      coordinator?.handleNativePointerSelection(range, in: textView)
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
    let initialSelection = safeSelection(for: text)
    context.coordinator.isApplyingExternalUpdate = true
    textView.setSelectedRange(initialSelection)
    context.coordinator.lastPublishedSelection = initialSelection
    context.coordinator.isApplyingExternalUpdate = false

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
    context.coordinator.updateSurfaceActivation(in: textView)
    context.coordinator.scheduleCaretPublication(for: textView)
    scrollView.requestDocumentSizeSync()
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let bindingChanged = context.coordinator.prepareForRepresentableUpdate(
      documentID: documentID,
      controller: sharedVimController,
      selectedRange: selectedRange
    )
    context.coordinator.parent = self
    context.coordinator.beginRepresentableUpdate()
    defer { context.coordinator.endRepresentableUpdate() }
    guard let textView = scrollView.documentView as? NSTextView else { return }
    if let codeTextView = textView as? CodeEditorTextView {
      codeTextView.languageID = languageID
      codeTextView.textInputHandler = {
        [weak coordinator = context.coordinator] value, range, view in
        coordinator?.handleTextInput(value, replacementRange: range, in: view) ?? false
      }
      codeTextView.markedTextHandler = {
        [weak coordinator = context.coordinator] value, selectedRange, replacementRange, view in
        coordinator?.handleMarkedText(
          value,
          selectedRange: selectedRange,
          replacementRange: replacementRange,
          in: view
        ) ?? false
      }
      codeTextView.unmarkTextHandler = { [weak coordinator = context.coordinator] view in
        coordinator?.handleUnmarkText(in: view) ?? false
      }
      codeTextView.goToDefinitionHandler = onGoToDefinition
      codeTextView.findReferencesHandler = onFindReferences
      codeTextView.showQuickHelpHandler = onShowQuickHelp
      codeTextView.showFindHandler = onShowFind
      codeTextView.zoomHandler = context.coordinator.handleZoom
      codeTextView.nativePointerSelectionHandler = {
        [weak coordinator = context.coordinator] range, textView in
        coordinator?.handleNativePointerSelection(range, in: textView)
      }
    }

    let hasExternalSelectionRequest =
      !bindingChanged && context.coordinator.observeParentSelection(selectedRange)

    if context.coordinator.renderedTextRevision != textRevision
      || context.coordinator.renderedDocumentID != documentID
    {
      let incoming = context.coordinator.documentSynchronizer.classify(
        text: text,
        revision: textRevision,
        documentID: documentID
      )
      let originatedInTextView = incoming == .acknowledgedLocal
      if !originatedInTextView {
        let preservedSelection = textView.selectedRange()
        let requestedSelection = safeSelection(for: text)

        if hasExternalSelectionRequest {
          context.coordinator.noteExternalSelectionRequest(requestedSelection)
        }
        context.coordinator.isApplyingExternalUpdate = true
        textView.string = text
        context.coordinator.synchronizedText = text
        let selection =
          bindingChanged || hasExternalSelectionRequest
          ? requestedSelection
          : clampedSelection(preservedSelection, for: text)
        textView.setSelectedRange(selection)
        (textView as? CodeEditorTextView)?.refreshCustomInsertionPoint()
        context.coordinator.lastPublishedSelection = selection
        context.coordinator.isApplyingExternalUpdate = false
      }
      if originatedInTextView {
        context.coordinator.documentSynchronizer.acknowledge(
          text: text,
          revision: textRevision,
          documentID: documentID
        )
      } else {
        context.coordinator.documentSynchronizer.acceptExternal(
          text: text,
          revision: textRevision,
          documentID: documentID
        )
      }
    } else if hasExternalSelectionRequest, textView.selectedRange() != selectedRange {
      let requestedSelection = safeSelection(for: text)
      context.coordinator.noteExternalSelectionRequest(requestedSelection)
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
    context.coordinator.updateSurfaceActivation(in: textView)
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
    fileprivate let documentSynchronizer: CalciteVimDocumentSynchronizer
    var synchronizedText: String {
      get { documentSynchronizer.synchronizedText }
      set { documentSynchronizer.updateSynchronizedText(newValue) }
    }
    private var pendingPresentationRange: NSRange?
    fileprivate var renderedTextRevision: UInt64 {
      get { documentSynchronizer.renderedRevision }
      set { documentSynchronizer.updateRenderedRevision(newValue) }
    }
    fileprivate var renderedDocumentID: UUID? {
      documentSynchronizer.renderedDocumentID
    }
    fileprivate var expectedLocalTextRevision: UInt64? {
      get { documentSynchronizer.expectedLocalRevision }
      set { documentSynchronizer.updateExpectedLocalRevision(newValue) }
    }
    private var synchronizedVimTextRevision: UInt64? {
      get { documentSynchronizer.vimRevision }
      set { documentSynchronizer.updateVimRevision(newValue) }
    }
    private var vimController: VimKeymapController?
    private enum VimSurfaceAttachmentPhase: Equatable {
      case unattached
      case restoringController
      case active
    }

    private enum VimSurfaceTransition: Equatable {
      case loadingDocument
      case restoringVimState
      case idle
    }

    private var vimAttachmentPhase: VimSurfaceAttachmentPhase = .unattached
    private var surfaceTransition: VimSurfaceTransition = .loadingDocument
    private var attachedVimControllerID: ObjectIdentifier?
    private var attachedVimDocumentID: UUID?
    private var boundDocumentID: UUID?
    private var boundVimControllerID: ObjectIdentifier?
    private var bindingGeneration: UInt64 = 0
    private var wasActiveSurface = false
    private let vimGeometryProvider = CalciteVimGeometryProvider()
    private struct VimDocumentComposition {
      var baseText: String
      var baseSelection: NSRange
      var replacementRange: NSRange
      var currentText: String
    }
    private var vimDocumentComposition: VimDocumentComposition?
    private var vimVirtualCompositionText = ""
    private var lastPublishedVimMode: VimMode?
    private var lastPublishedVimPrompt: String?
    private var hasPublishedVimPrompt = false
    private var lastPublishedVimInteraction: VimInteractionSnapshot?
    private var lastPublishedVimInputSource: String?
    private var hasPublishedVimInputSource = false
    fileprivate var lastPublishedSelection: NSRange?
    private var lastObservedParentSelection: NSRange?
    private var hasPendingNativeSelectionChange = false
    private var pendingNativeSelectionSource: VimHostCursorMoveSource?
    private var pendingNativeSelectionRange: NSRange?
    private var lastRequestedVimNativeRanges: [NSRange]?
    private var lastAppliedVimNativeRanges: [NSRange]?
    private var representableUpdateDepth = 0
    private var deferredSelection: NSRange?
    private var hasDeferredVimStateChange = false
    private var publicationFlushTask: Task<Void, Never>?
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
      self.lastObservedParentSelection = parent.selectedRange
      self.lastPublishedSelection = parent.selectedRange
      self.documentSynchronizer = CalciteVimDocumentSynchronizer(
        text: parent.text,
        revision: parent.textRevision,
        documentID: parent.documentID
      )
      self.boundDocumentID = parent.documentID
      self.boundVimControllerID = parent.sharedVimController.map(ObjectIdentifier.init)
      self.wasActiveSurface = false
    }

    isolated deinit {
      caretPublicationTask?.cancel()
      publicationFlushTask?.cancel()
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
      if parent.isActiveSurface, parent.profile.vim.enabled, let controller = vimController {
        updateVimViewport(controller, in: textView)
      }
      scheduleCaretPublication(for: textView)
    }

    func updateSurfaceActivation(in textView: NSTextView) {
      let becameActive = parent.isActiveSurface && !wasActiveSurface
      wasActiveSurface = parent.isActiveSurface

      guard becameActive else { return }
      if parent.profile.vim.enabled {
        configureVim(for: textView)
      }
      scheduleCaretPublication(for: textView)
      textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true

      Task { @MainActor [weak textView, weak self] in
        await Task.yield()
        guard let self, self.parent.isActiveSurface,
          let textView, let window = textView.window,
          textView.superview != nil
        else { return }
        window.makeFirstResponder(textView)
      }
    }

    func beginRepresentableUpdate() {
      representableUpdateDepth += 1
    }

    func endRepresentableUpdate() {
      representableUpdateDepth = max(0, representableUpdateDepth - 1)
      if representableUpdateDepth == 0 { scheduleDeferredPublicationsIfNeeded() }
    }

    /// Starts a document/controller handoff before the representable adopts its
    /// new SwiftUI value. Any delayed publication from the previous document is
    /// discarded so it cannot update the newly selected tab.
    @discardableResult
    func prepareForRepresentableUpdate(
      documentID: UUID?,
      controller: VimKeymapController?,
      selectedRange: NSRange
    ) -> Bool {
      let controllerID = controller.map(ObjectIdentifier.init)
      guard boundDocumentID != documentID || boundVimControllerID != controllerID else {
        return false
      }

      bindingGeneration &+= 1
      publicationFlushTask?.cancel()
      publicationFlushTask = nil
      clearDeferredPublications()

      boundDocumentID = documentID
      boundVimControllerID = controllerID
      surfaceTransition = .loadingDocument
      vimAttachmentPhase = .unattached
      attachedVimControllerID = nil
      attachedVimDocumentID = nil
      synchronizedVimTextRevision = nil
      hasPendingNativeSelectionChange = false
      pendingNativeSelectionSource = nil
      pendingNativeSelectionRange = nil
      lastRequestedVimNativeRanges = nil
      lastAppliedVimNativeRanges = nil
      pendingPresentationRange = nil
      presentationState = nil
      styledSelection = nil
      lastObservedParentSelection = selectedRange
      lastPublishedSelection = nil
      return true
    }

    /// Returns true only for a selection mutation that originated outside this text view.
    /// SwiftUI echoes selections published by Vim back through `updateNSView`; treating that
    /// acknowledgement as a new native cursor move would cancel Visual and Visual Block mode.
    func observeParentSelection(_ selection: NSRange) -> Bool {
      defer { lastObservedParentSelection = selection }
      guard let previous = lastObservedParentSelection, previous != selection else {
        return false
      }
      return selection != lastPublishedSelection
    }

    func noteExternalSelectionRequest(_ range: NSRange) {
      hasPendingNativeSelectionChange = true
      pendingNativeSelectionSource = .parentRequest
      pendingNativeSelectionRange = range
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
        hasPendingNativeSelectionChange = false
        pendingNativeSelectionSource = nil
        pendingNativeSelectionRange = nil
        lastRequestedVimNativeRanges = nil
        lastAppliedVimNativeRanges = nil
        vimController?.cancelMappingTimeout()
        if let controller = vimController {
          controller.setStateChangeHandler(nil)
          cancelVimComposition(in: textView, controller: controller)
        }
        vimController = nil
        vimAttachmentPhase = .unattached
        attachedVimControllerID = nil
        attachedVimDocumentID = nil
        synchronizedVimTextRevision = nil
        updateVimCursorStyle(for: .insert, in: textView, isEnabled: false)
        publishVimMode(.insert)
        publishVimPrompt(nil)
        publishVimInteraction(VimInteractionSnapshot(mode: .insert))
        publishVimInputSource(nil)
        surfaceTransition = .idle
        return
      }

      let mappings = CalciteVimConfigurationAdapter.mappings(from: profile.mappings)
      let inputPolicy = CalciteVimConfigurationAdapter.inputPolicy(from: profile.keyboardPolicy)
      let languageMap = CalciteVimConfigurationAdapter.languageMap(from: profile.languageMap)
      let signature = CalciteVimConfigurationAdapter.signature(
        profile: profile,
        tabWidth: parent.profile.behavior.tabWidth,
        mappings: mappings
      )

      if let shared = parent.sharedVimController {
        let controllerID = ObjectIdentifier(shared)
        if vimController !== shared
          || attachedVimControllerID != controllerID
          || attachedVimDocumentID != parent.documentID
        {
          if let controller = vimController, controller !== shared {
            cancelVimComposition(in: textView, controller: controller)
          }
          vimController = shared
          attachedVimControllerID = controllerID
          attachedVimDocumentID = parent.documentID
          vimAttachmentPhase = .restoringController
          surfaceTransition = .restoringVimState
          synchronizedVimTextRevision = nil
          hasPendingNativeSelectionChange = false
          pendingNativeSelectionSource = nil
          pendingNativeSelectionRange = nil
          lastRequestedVimNativeRanges = nil
          lastAppliedVimNativeRanges = nil
        }
      } else if vimController == nil {
        let engine = VimEngine(
          text: textView.string,
          cursor: textView.selectedRange().location,
          leader: profile.normalizedLeader,
          localLeader: profile.normalizedLeader,
          tabWidth: parent.profile.behavior.tabWidth
        )
        let controller = VimKeymapController(engine: engine)
        vimController = controller
        attachedVimControllerID = ObjectIdentifier(controller)
        attachedVimDocumentID = parent.documentID
        vimAttachmentPhase = .restoringController
        surfaceTransition = .restoringVimState
        synchronizedVimTextRevision = nil
      }

      guard let controller = vimController else { return }
      guard parent.isActiveSurface else {
        surfaceTransition = .idle
        return
      }
      controller.setStateChangeHandler { @MainActor [weak self] in
        guard let self, self.parent.isActiveSurface else { return }
        self.parent.onVimStateChange()
      }
      _ = controller.applyConfiguration(
        signature: signature,
        leader: profile.normalizedLeader,
        localLeader: profile.normalizedLeader,
        tabWidth: parent.profile.behavior.tabWidth,
        startInInsertMode: profile.startInInsertMode,
        inputPolicy: inputPolicy,
        languageMap: languageMap,
        mappings: mappings
      )

      vimGeometryProvider.textView = textView
      controller.engine.installVisualGeometryProvider(vimGeometryProvider)

      if vimAttachmentPhase == .restoringController {
        restoreAttachedVimController(controller, in: textView)
      } else {
        synchronizeVimControllerIfNeeded(controller, with: textView)
      }

      let state = controller.engine.state
      let selectionPresentation = CalciteVimSelectionPresenter.presentation(
        for: state,
        selectionSet: controller.engine.selectionSet
      )
      let currentRanges = textView.selectedRanges.map(\.rangeValue)
      if !vimOwnsNativeSelection(currentRanges, presentation: selectionPresentation) {
        applyVimSelectionPresentation(
          selectionPresentation,
          to: textView,
          scrollToPrimary: false
        )
      }
      updateVimCursorStyle(for: state.mode, in: textView)
      publishVimMode(state.mode)
      publishVimPrompt(controller.prompt)
      publishVimInteraction(controller.interactionSnapshot)
      publishVimInputSource(textView.inputContext?.selectedKeyboardInputSource)
    }

    private func restoreAttachedVimController(
      _ controller: VimKeymapController,
      in textView: NSTextView
    ) {
      guard vimAttachmentPhase == .restoringController else { return }

      // The cached `(window, buffer)` controller is authoritative during
      // attachment. Reconcile only document text; never feed the newly created
      // NSTextView's inherited selection back into Vim.
      if controller.engine.state.text != textView.string {
        _ = controller.reconcileExternalText(textView.string, cursor: nil)
      }

      let presentation = CalciteVimSelectionPresenter.presentation(
        for: controller.engine.state,
        selectionSet: controller.engine.selectionSet
      )
      applyVimSelectionPresentation(presentation, to: textView, scrollToPrimary: false)
      synchronizedVimTextRevision = parent.textRevision
      vimAttachmentPhase = .active
      surfaceTransition = .idle
      restoreVimWindowPresentation(controller, in: textView)
      applyPendingVimAsynchronousResults(controller, to: textView)
      publishSelection(presentation.primaryRange)
    }

    func handleKeyEvent(_ event: NSEvent, in textView: NSTextView) -> Bool {
      guard parent.isActiveSurface, parent.profile.vim.enabled else { return false }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if flags.contains(.command) { return false }
      configureVim(for: textView)
      guard let controller = vimController else { return false }

      if event.keyCode == 53,
        vimDocumentComposition != nil || controller.isComposingText || textView.hasMarkedText()
      {
        cancelVimComposition(in: textView, controller: controller)
        restoreEditorFocus(after: textView)
        return true
      }

      // Once composition is active, candidate navigation, conversion, deletion,
      // and commit keys belong to the native input method until it finishes.
      if textView.hasMarkedText() { return false }
      if shouldUseNativeTextInput(for: event, controller: controller) { return false }
      guard let stroke = CalciteVimInputAdapter.keyStroke(for: event) else { return false }

      synchronizeVimControllerIfNeeded(controller, with: textView)
      updateVimViewport(controller, in: textView)
      do {
        let result = try controller.handle(event: .key(stroke))
        guard result.consumed else { return false }
        applyVimHandlingResult(result, controller: controller, to: textView)
        updateVimMappingTimeout(
          awaitingMoreInput: result.awaitingMoreInput,
          controller: controller,
          textView: textView
        )
        restoreEditorFocus(after: textView)
        return true
      } catch {
        NSSound.beep()
        controller.cancelMappingTimeout()
        controller.resetPendingInput()
        controller.cancelPrompt()
        publishVimPrompt(nil)
        publishVimError(error, controller: controller, textView: textView)
        return true
      }
    }

    func handleMarkedText(
      _ value: Any,
      selectedRange: NSRange,
      replacementRange: NSRange,
      in textView: NSTextView
    ) -> Bool {
      guard parent.isActiveSurface, parent.profile.vim.enabled, !isApplyingExternalUpdate else {
        return false
      }
      configureVim(for: textView)
      guard let controller = vimController,
        let composingText = Self.inputString(from: value)
      else { return false }

      let mode = controller.engine.state.mode
      let expected = controller.expectedInput
      let usesVirtualComposition =
        controller.isPromptActive
        || ((expected == .literalCharacter || expected == .replacementCharacter)
          && mode != .insert && mode != .replace)

      let selection = Self.clampedUTF16Range(selectedRange, in: composingText)
      do {
        if usesVirtualComposition {
          if !controller.isComposingText {
            _ = try controller.handle(event: .compositionStarted)
          }
          _ = try controller.handle(
            event: .compositionUpdated(
              composingText,
              selectedRange: selection.location..<NSMaxRange(selection)
            )
          )
          vimVirtualCompositionText = composingText
          publishVimPrompt(controller.prompt)
          publishVimInteraction(controller.interactionSnapshot)
          publishVimInputSource(textView.inputContext?.selectedKeyboardInputSource)
          return true
        }

        guard mode == .insert || mode == .replace else { return false }
        if vimDocumentComposition == nil {
          let baseText = controller.engine.state.text
          let baseSelection = Self.clampedRange(textView.selectedRange(), in: baseText)
          let targetRange = Self.effectiveReplacementRange(
            replacementRange,
            fallback: baseSelection,
            in: baseText
          )
          vimDocumentComposition = VimDocumentComposition(
            baseText: baseText,
            baseSelection: baseSelection,
            replacementRange: targetRange,
            currentText: composingText
          )
          _ = try controller.handle(event: .compositionStarted)
        } else {
          vimDocumentComposition?.currentText = composingText
        }
        _ = try controller.handle(
          event: .compositionUpdated(
            composingText,
            selectedRange: selection.location..<NSMaxRange(selection)
          )
        )
        publishVimInteraction(controller.interactionSnapshot)
        publishVimInputSource(textView.inputContext?.selectedKeyboardInputSource)
        return false
      } catch {
        NSSound.beep()
        cancelVimComposition(in: textView, controller: controller)
        publishVimError(error, controller: controller, textView: textView)
        return true
      }
    }

    func handleUnmarkText(in textView: NSTextView) -> Bool {
      guard parent.isActiveSurface, parent.profile.vim.enabled, !isApplyingExternalUpdate else {
        return false
      }
      configureVim(for: textView)
      guard let controller = vimController, controller.isComposingText else { return false }

      let committedText = vimDocumentComposition?.currentText ?? vimVirtualCompositionText
      if committedText.isEmpty {
        cancelVimComposition(in: textView, controller: controller)
        return true
      }
      return commitVimText(
        committedText,
        replacementRange: NSRange(location: NSNotFound, length: 0),
        in: textView,
        controller: controller,
        isCompositionCommit: true
      )
    }

    func handleTextInput(
      _ value: Any,
      replacementRange: NSRange,
      in textView: NSTextView
    ) -> Bool {
      guard parent.isActiveSurface, parent.profile.vim.enabled, !isApplyingExternalUpdate else {
        return false
      }
      configureVim(for: textView)
      guard let controller = vimController,
        let committedText = Self.inputString(from: value),
        !committedText.isEmpty
      else { return false }

      let mode = controller.engine.state.mode
      let expected = controller.expectedInput
      let isHandledTextContext =
        mode == .insert || mode == .replace || controller.isPromptActive
        || expected == .literalCharacter || expected == .replacementCharacter
      guard isHandledTextContext else { return false }

      return commitVimText(
        committedText,
        replacementRange: replacementRange,
        in: textView,
        controller: controller,
        isCompositionCommit: controller.isComposingText || vimDocumentComposition != nil
      )
    }

    private func commitVimText(
      _ committedText: String,
      replacementRange: NSRange,
      in textView: NSTextView,
      controller: VimKeymapController,
      isCompositionCommit: Bool
    ) -> Bool {
      let documentComposition = vimDocumentComposition
      let sourceText: String
      let effectiveRange: NSRange
      if let documentComposition {
        restoreDocumentComposition(documentComposition, in: textView)
        sourceText = documentComposition.baseText
        effectiveRange = documentComposition.replacementRange
      } else {
        sourceText = textView.string
        effectiveRange = Self.effectiveReplacementRange(
          replacementRange,
          fallback: textView.selectedRange(),
          in: sourceText
        )
        (textView as? CodeEditorTextView)?.discardMarkedTextState()
      }
      vimDocumentComposition = nil
      vimVirtualCompositionText = ""

      do {
        let mode = controller.engine.state.mode
        var execution: VimExecutionResult?

        if mode == .insert || mode == .replace {
          controller.engine.synchronize(text: sourceText, cursor: effectiveRange.location)
          if effectiveRange.length > 0 {
            let removed = (sourceText as NSString).substring(with: effectiveRange)
            let characterCount = max(1, removed.count)
            execution = try controller.engine.execute(
              .deleteCharacter,
              count: characterCount,
              register: .blackHole
            )
          }
        }

        let inputResult = try controller.handle(
          event: isCompositionCommit
            ? .compositionCommitted(committedText)
            : .textCommit(
              committedText,
              replacementRange: effectiveRange.location..<NSMaxRange(effectiveRange)
            )
        )
        if let inserted = inputResult.execution {
          execution = execution.map { Self.mergedVimExecution($0, inserted) } ?? inserted
        }
        if let execution {
          applyVimExecution(execution, controller: controller, to: textView)
        } else {
          let currentMode = controller.engine.state.mode
          updateVimCursorStyle(for: currentMode, in: textView)
          publishVimMode(currentMode)
        }
        publishVimPrompt(controller.prompt)
        publishVimInteraction(controller.interactionSnapshot)
        publishVimInputSource(textView.inputContext?.selectedKeyboardInputSource)
        updateVimMappingTimeout(
          awaitingMoreInput: inputResult.awaitingMoreInput,
          controller: controller,
          textView: textView
        )
        return true
      } catch {
        NSSound.beep()
        cancelVimComposition(in: textView, controller: controller)
        publishVimError(error, controller: controller, textView: textView)
        return true
      }
    }

    private func restoreDocumentComposition(
      _ composition: VimDocumentComposition,
      in textView: NSTextView
    ) {
      isApplyingExternalUpdate = true
      (textView as? CodeEditorTextView)?.discardMarkedTextState()
      if textView.string != composition.baseText {
        let rollback = Self.singleEdit(from: textView.string, to: composition.baseText)
        textView.textStorage?.replaceCharacters(in: rollback.range, with: rollback.replacement)
      }
      let selection = Self.clampedRange(composition.baseSelection, in: composition.baseText)
      textView.setSelectedRange(selection)
      synchronizedText = composition.baseText
      pendingEdit = nil
      isApplyingExternalUpdate = false
      pendingPresentationRange = composition.replacementRange
      parent.applyPresentation(to: textView, affectedRange: composition.replacementRange)
      scheduleCaretPublication(for: textView)
    }

    private func cancelVimComposition(
      in textView: NSTextView,
      controller: VimKeymapController
    ) {
      if let composition = vimDocumentComposition {
        restoreDocumentComposition(composition, in: textView)
      } else {
        (textView as? CodeEditorTextView)?.discardMarkedTextState()
      }
      vimDocumentComposition = nil
      vimVirtualCompositionText = ""
      _ = try? controller.handle(event: .compositionCancelled)
      let mode = controller.engine.state.mode
      updateVimCursorStyle(for: mode, in: textView)
      publishVimMode(mode)
      publishVimPrompt(controller.prompt)
      publishVimInteraction(controller.interactionSnapshot)
      publishVimInputSource(textView.inputContext?.selectedKeyboardInputSource)
    }

    private func applyVimHandlingResult(
      _ result: VimKeyHandlingResult,
      controller: VimKeymapController,
      to textView: NSTextView
    ) {
      if let execution = result.execution {
        applyVimExecution(execution, controller: controller, to: textView)
      } else {
        let mode = controller.engine.state.mode
        updateVimCursorStyle(for: mode, in: textView)
        publishVimMode(mode)
      }
      publishVimPrompt(controller.prompt)
      publishVimInteraction(controller.interactionSnapshot)
      publishVimInputSource(textView.inputContext?.selectedKeyboardInputSource)
    }

    private func shouldUseNativeTextInput(
      for event: NSEvent,
      controller: VimKeymapController
    ) -> Bool {
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard !flags.contains(.control), !flags.contains(.command) else { return false }
      let mode = controller.engine.state.mode
      switch event.keyCode {
      case 53:
        return false
      case 115, 119, 123, 124, 125, 126, 116, 121:
        return mode == .insert || mode == .replace
      case 36, 48, 51, 117:
        return false
      default:
        break
      }

      if mode == .insert || mode == .replace || controller.isPromptActive { return true }
      switch controller.expectedInput {
      case .literalCharacter, .replacementCharacter, .promptText:
        return true
      case .command, .registerName, .markName:
        return false
      }
    }

    private static func inputString(from value: Any) -> String? {
      if let string = value as? String { return string }
      if let attributed = value as? NSAttributedString { return attributed.string }
      return nil
    }

    private static func effectiveReplacementRange(
      _ replacementRange: NSRange,
      fallback: NSRange,
      in source: String
    ) -> NSRange {
      replacementRange.location == NSNotFound
        ? clampedRange(fallback, in: source)
        : clampedRange(replacementRange, in: source)
    }

    private static func clampedRange(_ range: NSRange, in source: String) -> NSRange {
      let length = (source as NSString).length
      let location = min(max(0, range.location), length)
      return NSRange(
        location: location,
        length: min(max(0, range.length), length - location)
      )
    }

    private static func clampedUTF16Range(_ range: NSRange, in source: String) -> NSRange {
      clampedRange(range, in: source)
    }

    private func updateVimMappingTimeout(
      awaitingMoreInput: Bool,
      controller: VimKeymapController,
      textView: NSTextView
    ) {
      controller.cancelMappingTimeout()
      guard awaitingMoreInput else { return }

      controller.scheduleMappingTimeout(
        milliseconds: parent.profile.vim.mappingTimeoutMilliseconds
      ) { @MainActor [weak self, weak textView] in
        guard let self else { return }
        guard self.parent.isActiveSurface,
          let textView, textView.superview != nil
        else {
          self.publishVimStateChange()
          return
        }
        self.applyPendingVimAsynchronousResults(controller, to: textView)
      }
    }

    private func applyPendingVimAsynchronousResults(
      _ controller: VimKeymapController,
      to textView: NSTextView
    ) {
      let results = controller.consumePendingAsynchronousResults()
      for result in results {
        applyVimHandlingResult(result, controller: controller, to: textView)
      }
      publishVimInteraction(controller.interactionSnapshot)
    }

    private static func mergedVimExecution(
      _ first: VimExecutionResult,
      _ second: VimExecutionResult
    ) -> VimExecutionResult {
      VimExecutionResult(
        state: second.state,
        hostRequests: first.hostRequests + second.hostRequests,
        didChangeText: first.didChangeText || second.didChangeText,
        transaction: VimEditTransaction.merging(first.transaction, second.transaction)
      )
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
      Task { @MainActor [weak self, weak textView] in
        await Task.yield()
        guard let self, self.parent.isActiveSurface,
          let textView, let window = textView.window,
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
      guard parent.isActiveSurface else { return false }
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
      guard parent.isActiveSurface, !isApplyingExternalUpdate else { return }
      guard vimDocumentComposition == nil else {
        pendingEdit = nil
        return
      }

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
      guard parent.isActiveSurface,
        !isApplyingExternalUpdate,
        surfaceTransition == .idle,
        vimDocumentComposition == nil,
        let textView = notification.object as? NSTextView
      else { return }
      if parent.profile.vim.enabled {
        let currentRanges = textView.selectedRanges.map(\.rangeValue)
        let isPointerSelection =
          (textView as? CodeEditorTextView)?.isProcessingPointerSelection == true
        if let requestedRanges = lastRequestedVimNativeRanges,
          nativeSelectionIsNormalization(currentRanges, of: requestedRanges)
        {
          hasPendingNativeSelectionChange = false
          pendingNativeSelectionSource = nil
          pendingNativeSelectionRange = nil
          lastAppliedVimNativeRanges = currentRanges
        } else if currentRanges == lastAppliedVimNativeRanges {
          hasPendingNativeSelectionChange = false
          pendingNativeSelectionSource = nil
          pendingNativeSelectionRange = nil
        } else {
          hasPendingNativeSelectionChange = true
          pendingNativeSelectionSource = isPointerSelection ? .pointer : .keyboard
          pendingNativeSelectionRange = textView.selectedRange()
          lastRequestedVimNativeRanges = nil
          lastAppliedVimNativeRanges = nil
        }
        // `NSTextView.mouseDown` may emit several intermediate selection
        // notifications while hit-testing or dragging. The text view invokes
        // `handleNativePointerSelection` after `super.mouseDown` completes.
        if !isPointerSelection {
          synchronizeVimCursorAfterSelectionChange(in: textView)
        }
      }
      if let codeTextView = textView as? CodeEditorTextView {
        codeTextView.refreshCustomInsertionPoint()
        codeTextView.window?.invalidateCursorRects(for: codeTextView)
      }
      if (textView as? CodeEditorTextView)?.isProcessingPointerSelection != true {
        publishSelection(textView.selectedRange())
      }
      textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
      scheduleCaretPublication(for: textView)
    }

    func handleNativePointerSelection(_ range: NSRange, in textView: NSTextView) {
      guard parent.isActiveSurface, surfaceTransition == .idle else { return }
      guard parent.profile.vim.enabled else {
        publishSelection(range)
        return
      }
      hasPendingNativeSelectionChange = true
      pendingNativeSelectionSource = .pointer
      pendingNativeSelectionRange = range
      lastRequestedVimNativeRanges = nil
      lastAppliedVimNativeRanges = nil
      synchronizeVimCursorAfterSelectionChange(in: textView, requestedRange: range)
      scheduleCaretPublication(for: textView)
    }

    /// Mouse clicks change AppKit's selection before another key event reaches
    /// Vim. Move the engine immediately; waiting for a SwiftUI update leaves
    /// the next Vim command at the previous cursor.
    private func synchronizeVimCursorAfterSelectionChange(
      in textView: NSTextView,
      requestedRange: NSRange? = nil
    ) {
      guard hasPendingNativeSelectionChange else { return }
      if vimController == nil {
        configureVim(for: textView)
      }
      guard let controller = vimController else { return }

      if controller.engine.state.text != textView.string {
        _ = controller.reconcileExternalText(textView.string, cursor: nil)
      }

      let source = pendingNativeSelectionSource ?? .accessibility
      let targetRange = requestedRange ?? pendingNativeSelectionRange ?? textView.selectedRange()
      controller.acceptHostCursorMove(
        toUTF16Offset: targetRange.location,
        source: source
      )
      let presentation = CalciteVimSelectionPresenter.presentation(
        for: controller.engine.state,
        selectionSet: controller.engine.selectionSet
      )
      applyVimSelectionPresentation(presentation, to: textView, scrollToPrimary: false)
      synchronizedVimTextRevision = parent.textRevision
      publishSelection(presentation.primaryRange)
      updateVimCursorStyle(for: controller.engine.state.mode, in: textView)
      publishVimMode(controller.engine.state.mode)
      publishVimPrompt(controller.prompt)
      publishVimInteraction(controller.interactionSnapshot)
      publishVimInputSource(textView.inputContext?.selectedKeyboardInputSource)
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
      publishVimStateChange()
    }

    private func publishVimInteraction(_ snapshot: VimInteractionSnapshot) {
      guard lastPublishedVimInteraction != snapshot else { return }
      lastPublishedVimInteraction = snapshot
      publishVimStateChange()
    }

    private func publishVimInputSource(_ identifier: String?) {
      vimController?.engine.updateWindowPresentation(
        inputSourceIdentifier: identifier,
        updatesInputSource: true
      )
      if hasPublishedVimInputSource, lastPublishedVimInputSource == identifier { return }
      hasPublishedVimInputSource = true
      lastPublishedVimInputSource = identifier
      publishVimStateChange()
    }

    private func publishVimError(
      _ error: Error,
      controller: VimKeymapController,
      textView: NSTextView
    ) {
      controller.present(message: CalciteVimMessagePresenter.message(for: error))
      publishVimInteraction(controller.interactionSnapshot)
      publishVimInputSource(textView.inputContext?.selectedKeyboardInputSource)
    }

    private func updateVimCursorStyle(
      for mode: VimMode,
      in textView: NSTextView,
      isEnabled: Bool = true
    ) {
      CalciteVimCursorPresenter.apply(
        mode: mode,
        profile: parent.profile,
        to: textView,
        isEnabled: isEnabled
      )
      guard let codeTextView = textView as? CodeEditorTextView else { return }
      switch mode {
      case .visualCharacter, .visualLine:
        codeTextView.vimCursorLocation = vimController?.engine.state.cursor
      case .normal, .insert, .replace, .commandLine, .search:
        codeTextView.vimCursorLocation = nil
      }
    }

    private func publishVimMode(_ mode: VimMode) {
      guard lastPublishedVimMode != mode else { return }
      lastPublishedVimMode = mode
      publishVimStateChange()
    }

    private func publishVimStateChange() {
      if representableUpdateDepth > 0 {
        hasDeferredVimStateChange = true
        scheduleDeferredPublicationsIfNeeded()
      } else {
        parent.onVimStateChange()
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

    private func clearDeferredPublications() {
      deferredSelection = nil
      hasDeferredVimStateChange = false
    }

    private func scheduleDeferredPublicationsIfNeeded() {
      guard publicationFlushTask == nil,
        deferredSelection != nil || hasDeferredVimStateChange
      else { return }

      let generation = bindingGeneration
      publicationFlushTask = Task { @MainActor [weak self] in
        await Task.yield()
        guard let self, !Task.isCancelled else { return }
        guard generation == self.bindingGeneration else {
          self.publicationFlushTask = nil
          return
        }
        guard self.representableUpdateDepth == 0 else {
          self.publicationFlushTask = nil
          self.scheduleDeferredPublicationsIfNeeded()
          return
        }

        let selection = self.deferredSelection
        let publishesVimState = self.hasDeferredVimStateChange
        self.clearDeferredPublications()
        self.publicationFlushTask = nil

        if let selection { self.parent.onSelectionChange(selection) }
        if publishesVimState { self.parent.onVimStateChange() }
      }
    }

    private func updateVimViewport(
      _ controller: VimKeymapController,
      in textView: NSTextView
    ) {
      if let range = CalciteVimViewportProvider.visibleUTF16Range(in: textView) {
        controller.engine.updateViewport(visibleUTF16Range: range)
      }
      if let clipView = textView.enclosingScrollView?.contentView {
        controller.engine.updateWindowPresentation(
          horizontalScrollOffset: Double(clipView.bounds.origin.x),
          verticalScrollOffset: Double(clipView.bounds.origin.y)
        )
      }
    }

    private func restoreVimWindowPresentation(
      _ controller: VimKeymapController,
      in textView: NSTextView
    ) {
      guard let scrollView = textView.enclosingScrollView else { return }
      let state = controller.engine.windowPresentationState
      Task { @MainActor [weak self, weak textView, weak scrollView] in
        await Task.yield()
        guard let self, self.parent.isActiveSurface,
          let textView, let scrollView, textView.superview != nil
        else { return }
        let clipView = scrollView.contentView
        let requested = NSRect(
          x: CGFloat(state.horizontalScrollOffset),
          y: CGFloat(state.verticalScrollOffset),
          width: clipView.bounds.width,
          height: clipView.bounds.height
        )
        let constrained = clipView.constrainBoundsRect(requested)
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
        self.updateVimViewport(controller, in: textView)
      }
    }

    private func applyVimSelectionPresentation(
      _ presentation: CalciteVimSelectionPresenter.Presentation,
      to textView: NSTextView,
      scrollToPrimary: Bool
    ) {
      let requestedRanges = presentation.nativeRanges
      isApplyingExternalUpdate = true
      textView.setSelectedRanges(
        requestedRanges.map { NSValue(range: $0) },
        affinity: .downstream,
        stillSelecting: false
      )
      if scrollToPrimary {
        textView.scrollRangeToVisible(presentation.primaryRange)
      }
      isApplyingExternalUpdate = false
      hasPendingNativeSelectionChange = false
      pendingNativeSelectionSource = nil
      pendingNativeSelectionRange = nil
      lastRequestedVimNativeRanges = requestedRanges
      lastAppliedVimNativeRanges = textView.selectedRanges.map(\.rangeValue)
      (textView as? CodeEditorTextView)?.refreshCustomInsertionPoint()
    }

    private func vimOwnsNativeSelection(
      _ currentRanges: [NSRange],
      presentation: CalciteVimSelectionPresenter.Presentation
    ) -> Bool {
      let requestedRanges = presentation.nativeRanges
      if nativeSelectionIsNormalization(currentRanges, of: requestedRanges) {
        return true
      }
      return lastRequestedVimNativeRanges == requestedRanges
        && lastAppliedVimNativeRanges == currentRanges
    }

    private func nativeSelectionIsNormalization(
      _ currentRanges: [NSRange],
      of requestedRanges: [NSRange]
    ) -> Bool {
      if currentRanges == requestedRanges { return true }

      let ordered: (NSRange, NSRange) -> Bool = { lhs, rhs in
        lhs.location == rhs.location
          ? lhs.length < rhs.length
          : lhs.location < rhs.location
      }
      let currentNonEmpty = currentRanges.filter { $0.length > 0 }.sorted(by: ordered)
      let requestedNonEmpty = requestedRanges.filter { $0.length > 0 }.sorted(by: ordered)
      guard currentNonEmpty == requestedNonEmpty else { return false }

      // NSTextView can omit zero-length selections on short/empty rows of a Visual Block.
      // It must not invent a caret outside one of Vim's requested virtual row positions.
      let requestedEmptyLocations = Set(
        requestedRanges.lazy.filter { $0.length == 0 }.map(\.location)
      )
      return currentRanges.lazy
        .filter { $0.length == 0 }
        .allSatisfy { requestedEmptyLocations.contains($0.location) }
    }

    private func synchronizeVimControllerIfNeeded(
      _ controller: VimKeymapController,
      with textView: NSTextView
    ) {
      guard vimDocumentComposition == nil else { return }
      let currentRanges = textView.selectedRanges.map(\.rangeValue)
      let expectedPresentation = CalciteVimSelectionPresenter.presentation(
        for: controller.engine.state,
        selectionSet: controller.engine.selectionSet
      )
      let selectionChanged =
        !vimOwnsNativeSelection(currentRanges, presentation: expectedPresentation)
      let textChanged =
        synchronizedVimTextRevision != parent.textRevision
        || controller.engine.state.text != textView.string
      guard textChanged || selectionChanged else {
        hasPendingNativeSelectionChange = false
        pendingNativeSelectionSource = nil
        pendingNativeSelectionRange = nil
        return
      }

      let requestedSelection = pendingNativeSelectionRange ?? textView.selectedRange()
      let cursor = requestedSelection.location
      if controller.engine.state.text != textView.string {
        let requestedCursor = hasPendingNativeSelectionChange ? cursor : nil
        _ = controller.reconcileExternalText(textView.string, cursor: requestedCursor)
        let reconciledPresentation = CalciteVimSelectionPresenter.presentation(
          for: controller.engine.state,
          selectionSet: controller.engine.selectionSet
        )
        if !vimOwnsNativeSelection(
          textView.selectedRanges.map(\.rangeValue),
          presentation: reconciledPresentation
        ) {
          applyVimSelectionPresentation(
            reconciledPresentation,
            to: textView,
            scrollToPrimary: false
          )
        } else {
          hasPendingNativeSelectionChange = false
          pendingNativeSelectionSource = nil
          pendingNativeSelectionRange = nil
        }
        lastPublishedSelection = reconciledPresentation.primaryRange
      } else if hasPendingNativeSelectionChange {
        // A real AppKit selection event (mouse, accessibility, or an explicit host request)
        // moves Vim's cursor and intentionally leaves Visual mode. Merely observing a range
        // normalization produced by `setSelectedRanges` does not.
        controller.acceptHostCursorMove(
          toUTF16Offset: cursor,
          source: pendingNativeSelectionSource ?? .accessibility
        )
        let reconciledPresentation = CalciteVimSelectionPresenter.presentation(
          for: controller.engine.state,
          selectionSet: controller.engine.selectionSet
        )
        applyVimSelectionPresentation(
          reconciledPresentation,
          to: textView,
          scrollToPrimary: false
        )
        lastPublishedSelection = reconciledPresentation.primaryRange
      } else {
        // NSTextView may normalize, reorder, or omit zero-length ranges in a block. Vim remains
        // authoritative unless the delegate observed a genuine native selection mutation.
        applyVimSelectionPresentation(
          expectedPresentation,
          to: textView,
          scrollToPrimary: false
        )
      }
      synchronizedVimTextRevision = parent.textRevision
    }

    private func applyVimExecution(
      _ execution: VimExecutionResult,
      controller: VimKeymapController,
      to textView: NSTextView
    ) {
      let state = execution.state
      updateVimCursorStyle(for: state.mode, in: textView)
      let selectionPresentation = CalciteVimSelectionPresenter.presentation(
        for: state,
        selectionSet: controller.engine.selectionSet
      )
      let primarySelection = selectionPresentation.primaryRange
      if state.text != textView.string {
        let sourceText = textView.string
        var transaction = resolvedTransaction(for: execution, sourceText: sourceText)
        transaction.baseRevision = VimDocumentRevision(parent.textRevision)
        var edits = transaction.sequentialEdits.map {
          (range: $0.range, replacement: $0.replacement)
        }
        if !Self.edits(edits, transform: sourceText, into: state.text) {
          let fallback = Self.singleEdit(from: sourceText, to: state.text)
          edits = [
            (
              range: fallback.range.location..<NSMaxRange(fallback.range),
              replacement: fallback.replacement
            )
          ]
          transaction = VimEditTransaction(
            baseRevision: VimDocumentRevision(parent.textRevision),
            origin: .vim,
            beforeState: VimState(
              text: sourceText,
              cursor: textView.selectedRange().location,
              mode: controller.engine.state.mode
            ),
            afterState: state,
            sequentialEdits: edits.map {
              VimTransactionEdit(range: $0.0, replacement: $0.1)
            },
            baseEdits: edits.map {
              VimTransactionEdit(range: $0.0, replacement: $0.1)
            },
            repeatMetadata: VimRepeatMetadata(
              isRepeatable: false,
              finishesInInsertMode: state.mode == .insert || state.mode == .replace
            )
          )
        }

        isApplyingExternalUpdate = true
        textView.textStorage?.beginEditing()
        var intermediate = sourceText
        var presentationRange: NSRange?
        for edit in edits {
          let range = NSRange(location: edit.range.lowerBound, length: edit.range.count)
          textView.textStorage?.replaceCharacters(in: range, with: edit.replacement)
          intermediate = (intermediate as NSString).replacingCharacters(
            in: range,
            with: edit.replacement
          )
          let affected = affectedPresentationRange(
            in: intermediate,
            editedRange: range,
            replacement: edit.replacement
          )
          presentationRange = presentationRange.map { NSUnionRange($0, affected) } ?? affected
          reloadEditorGeometry(
            for: textView,
            editedRange: range,
            replacement: edit.replacement
          )
        }
        textView.textStorage?.endEditing()
        synchronizedText = state.text
        isApplyingExternalUpdate = false
        applyVimSelectionPresentation(
          selectionPresentation,
          to: textView,
          scrollToPrimary: true
        )
        synchronizedVimTextRevision = publishVimTransaction(
          transaction,
          selection: primarySelection
        )
        pendingPresentationRange = presentationRange
        scheduleCaretPublication(for: textView)
      } else {
        let currentRanges = textView.selectedRanges.map(\.rangeValue)
        if !vimOwnsNativeSelection(currentRanges, presentation: selectionPresentation) {
          applyVimSelectionPresentation(
            selectionPresentation,
            to: textView,
            scrollToPrimary: true
          )
          publishSelection(primarySelection)
          reloadEditorGeometry(for: textView)
          scheduleCaretPublication(for: textView)
        } else {
          hasPendingNativeSelectionChange = false
          pendingNativeSelectionSource = nil
          pendingNativeSelectionRange = nil
        }
      }
      publishVimMode(state.mode)
      if !execution.hostRequests.isEmpty {
        CalciteVimHostRouter(
          documentURL: parent.documentURL,
          documentID: parent.documentID,
          editorSessionID: parent.editorSessionID,
          tabPageID: parent.tabPageID,
          revision: parent.textRevision,
          handler: parent.onVimHostInvocation
        ).route(
          execution.hostRequests,
          selection: primarySelection,
          to: controller.engine
        )
        applyPendingVimViewportRequest(controller, in: textView)
        publishVimInteraction(controller.interactionSnapshot)
      }
    }

    private func applyPendingVimViewportRequest(
      _ controller: VimKeymapController,
      in textView: NSTextView
    ) {
      let lines = controller.engine.consumeViewportScrollRequest()
      guard lines != 0, let scrollView = textView.enclosingScrollView else { return }
      let lineHeight = textView.layoutManager.map {
        $0.defaultLineHeight(for: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
      } ?? 16
      let clipView = scrollView.contentView
      let requested = NSRect(
        x: clipView.bounds.origin.x,
        y: clipView.bounds.origin.y + CGFloat(lines) * lineHeight,
        width: clipView.bounds.width,
        height: clipView.bounds.height
      )
      let constrained = clipView.constrainBoundsRect(requested)
      clipView.scroll(to: constrained.origin)
      scrollView.reflectScrolledClipView(clipView)
      updateVimViewport(controller, in: textView)
    }

    private func resolvedTransaction(
      for execution: VimExecutionResult,
      sourceText: String
    ) -> VimEditTransaction {
      if let transaction = execution.transaction,
        transaction.beforeState.text == sourceText,
        transaction.afterState.text == execution.state.text
      {
        return transaction
      }
      let fallback = Self.singleEdit(from: sourceText, to: execution.state.text)
      let edit = VimTransactionEdit(
        range: fallback.range.location..<NSMaxRange(fallback.range),
        replacement: fallback.replacement
      )
      return VimEditTransaction(
        origin: .vim,
        beforeState: VimState(text: sourceText, cursor: 0, mode: execution.state.mode),
        afterState: execution.state,
        sequentialEdits: [edit],
        baseEdits: [edit],
        repeatMetadata: VimRepeatMetadata(
          isRepeatable: false,
          finishesInInsertMode: execution.state.mode == .insert || execution.state.mode == .replace
        )
      )
    }

    private static func edits(
      _ edits: [(range: Range<Int>, replacement: String)],
      transform source: String,
      into expected: String
    ) -> Bool {
      guard !edits.isEmpty else { return source == expected }
      var value = source
      for edit in edits {
        let ns = value as NSString
        guard edit.range.lowerBound >= 0,
          edit.range.upperBound >= edit.range.lowerBound,
          edit.range.upperBound <= ns.length
        else { return false }
        value = ns.replacingCharacters(
          in: NSRange(location: edit.range.lowerBound, length: edit.range.count),
          with: edit.replacement
        )
      }
      return value == expected
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
    private func publishVimTransaction(
      _ transaction: VimEditTransaction,
      selection: NSRange
    ) -> UInt64 {
      parent.onWillEdit()
      let targetRevision = documentSynchronizer.reserveLocalRevision(
        after: renderedTextRevision,
        resultingText: transaction.afterState.text,
        transactionID: transaction.id
      )
      var value = transaction
      value.baseRevision = VimDocumentRevision(renderedTextRevision)
      parent.onVimEdit(value, selection)
      return targetRevision
    }

    @discardableResult
    private func publishEdit(
      range: NSRange,
      replacement: String,
      resultingText: String,
      selection: NSRange
    ) -> UInt64 {
      parent.onWillEdit()
      let targetRevision = documentSynchronizer.reserveLocalRevision(
        after: renderedTextRevision,
        resultingText: resultingText
      )
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
