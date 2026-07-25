#if os(macOS)
  import AppKit
  import SwiftUI

  struct TerminalTextView: NSViewRepresentable {
    let snapshot: TerminalRenderedSnapshot
    let outputEpoch: UInt64
    let preferences: EditorTerminalPreferences
    let appearanceRevision: UInt64
    let send: (String) -> Void
    let clear: () -> Void
    let resize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
      let scrollView = TerminalScrollView()
      scrollView.hasVerticalScroller = true
      scrollView.hasHorizontalScroller = false
      scrollView.autohidesScrollers = true
      scrollView.borderType = .noBorder
      scrollView.drawsBackground = true
      // Leave room below the shell prompt when the terminal view is remounted.
      scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 18, right: 0)

      let textView = TerminalInputTextView()
      textView.isEditable = false
      textView.isSelectable = true
      textView.isRichText = false
      textView.drawsBackground = true
      textView.textContainer?.lineFragmentPadding = 0
      textView.autoresizingMask = [.width]
      textView.isAutomaticQuoteSubstitutionEnabled = false
      textView.isAutomaticDashSubstitutionEnabled = false
      textView.isAutomaticTextReplacementEnabled = false
      textView.isContinuousSpellCheckingEnabled = false
      textView.keyHandler = context.coordinator.handle
      scrollView.documentView = textView

      context.coordinator.textView = textView
      context.coordinator.scrollView = scrollView
      let coordinator = context.coordinator
      scrollView.resizeHandler = { [weak coordinator] in
        coordinator?.updateSize()
      }
      scrollView.focusHandler = { [weak coordinator] in
        coordinator?.focusInput()
        coordinator?.scrollToBottom()
      }
      context.coordinator.updateAppearance(force: true)
      context.coordinator.updateSize()
      context.coordinator.updateSnapshot(snapshot)
      context.coordinator.focusInput()
      return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
      context.coordinator.parent = self
      context.coordinator.updateAppearance()
      context.coordinator.updateSize()
      context.coordinator.updateSnapshot(snapshot)
    }

    @MainActor
    final class Coordinator {
      var parent: TerminalTextView
      weak var textView: TerminalInputTextView?
      weak var scrollView: NSScrollView?

      private var appearance = TerminalAppearance.resolve(.default)
      private var renderedEpoch: UInt64?
      private var renderedSnapshot: TerminalRenderedSnapshot?
      private var lastSize = (columns: 100, rows: 32)
      private var appliedPreferences: EditorTerminalPreferences?
      private var appliedAppearanceRevision: UInt64?
      private var pendingSize: (columns: Int, rows: Int)?
      private var resizePublicationScheduled = false

      init(parent: TerminalTextView) { self.parent = parent }

      func focusInput() {
        guard let textView else { return }
        DispatchQueue.main.async { [weak textView] in
          guard let textView, let window = textView.window else { return }
          if window.firstResponder !== textView {
            window.makeFirstResponder(textView)
          }
        }
      }

      func scrollToBottom() {
        DispatchQueue.main.async { [weak textView, weak scrollView] in
          guard let textView, let scrollView else { return }
          let length = (textView.string as NSString).length
          textView.scrollRangeToVisible(NSRange(location: length, length: 0))
          scrollView.reflectScrolledClipView(scrollView.contentView)
        }
      }

      func updateAppearance(force: Bool = false) {
        guard let textView, let scrollView else { return }
        guard
          force || appliedPreferences != parent.preferences
            || appliedAppearanceRevision != parent.appearanceRevision
        else { return }

        appearance = TerminalAppearance.resolve(parent.preferences)
        appliedPreferences = parent.preferences
        appliedAppearanceRevision = parent.appearanceRevision

        scrollView.backgroundColor = appearance.background
        textView.backgroundColor = appearance.background
        textView.textColor = appearance.foreground
        textView.font = appearance.font
        textView.insertionPointColor = appearance.cursor
        textView.terminalCursorColor = appearance.cursor
        textView.terminalCursorStyle = appearance.cursorStyle
        textView.selectedTextAttributes = [
          .backgroundColor: appearance.selection,
          .foregroundColor: appearance.foreground,
        ]
        textView.textContainerInset = NSSize(
          width: appearance.horizontalPadding,
          height: appearance.verticalPadding
        )
        renderSnapshot(parent.snapshot, preserveSelection: true, forceFullRender: true)
      }

      func updateSnapshot(_ snapshot: TerminalRenderedSnapshot) {
        guard let textView else { return }
        guard renderedEpoch != parent.outputEpoch || renderedSnapshot != snapshot else { return }

        let followsOutput = textView.visibleRect.maxY >= textView.bounds.maxY - 36
        let oldSelection = textView.selectedRange()
        renderSnapshot(
          snapshot,
          preserveSelection: !followsOutput,
          previousSelection: oldSelection,
          forceFullRender: renderedEpoch != parent.outputEpoch
        )
        renderedEpoch = parent.outputEpoch

        if followsOutput { scrollToBottom() }
      }

      func updateSize() {
        guard let textView, let scrollView, let font = textView.font else { return }
        let characterWidth = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let baseLineHeight = textView.layoutManager?.defaultLineHeight(for: font) ?? 14
        let lineHeight = max(1, baseLineHeight + appearance.lineSpacing)
        let inset = textView.textContainerInset
        let size = scrollView.contentView.bounds.size
        let next = (
          columns: max(2, Int(max(0, size.width - inset.width * 2) / characterWidth)),
          rows: max(2, Int(max(0, size.height - inset.height * 2) / lineHeight))
        )
        guard lastSize != next else { return }
        lastSize = next
        scheduleResizePublication(next)
      }

      /// `updateNSView` is part of SwiftUI's render pass. Resizing the terminal can publish a
      /// new rendered snapshot, so publish it on the next main-actor turn instead of from here.
      private func scheduleResizePublication(_ size: (columns: Int, rows: Int)) {
        pendingSize = size
        guard !resizePublicationScheduled else { return }
        resizePublicationScheduled = true

        Task { @MainActor [weak self] in
          await Task.yield()
          guard let self else { return }
          self.resizePublicationScheduled = false
          guard let size = self.pendingSize else { return }
          self.pendingSize = nil
          self.parent.resize(size.columns, size.rows)
        }
      }

      func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
          switch event.charactersIgnoringModifiers?.lowercased() {
          case "c":
            if let textView, textView.selectedRange().length > 0 { textView.copy(nil) }
            return true
          case "v":
            if let value = NSPasteboard.general.string(forType: .string) {
              parent.send(value)
              return true
            }
          case "k":
            parent.clear()
            return true
          default:
            break
          }
          return false
        }

        let value: String?
        switch event.keyCode {
        case 36, 76: value = "\r"
        case 48: value = flags.contains(.shift) ? "\u{1b}[Z" : "\t"
        case 51:
          if flags.contains(.option) {
            value = "\u{1b}\u{7f}"
          } else if flags.contains(.control) {
            value = "\u{08}"
          } else {
            value = "\u{7f}"
          }
        case 53: value = "\u{1b}"
        case 117: value = "\u{1b}[3~"
        case 123: value = modifiedArrow("D", flags: flags)
        case 124: value = modifiedArrow("C", flags: flags)
        case 125: value = modifiedArrow("B", flags: flags)
        case 126: value = modifiedArrow("A", flags: flags)
        case 115: value = "\u{1b}[H"
        case 119: value = "\u{1b}[F"
        case 116: value = "\u{1b}[5~"
        case 121: value = "\u{1b}[6~"
        default:
          if flags.contains(.control),
            let scalar = event.charactersIgnoringModifiers?.uppercased().unicodeScalars.first,
            scalar.value >= 64, scalar.value <= 95
          {
            value = UnicodeScalar(scalar.value - 64).map(String.init)
          } else if let characters = event.characters, !characters.isEmpty {
            value = flags.contains(.option) ? "\u{1b}\(characters)" : characters
          } else {
            value = nil
          }
        }
        guard let value else { return false }
        parent.send(value)
        return true
      }

      private func renderSnapshot(
        _ snapshot: TerminalRenderedSnapshot,
        preserveSelection: Bool,
        previousSelection: NSRange? = nil,
        forceFullRender: Bool = false
      ) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = previousSelection ?? textView.selectedRange()

        if !forceFullRender,
          let previous = renderedSnapshot,
          snapshot != previous,
          snapshot.text.hasPrefix(previous.text),
          styles(in: previous, arePrefixOf: snapshot)
        {
          let previousLength = (previous.text as NSString).length
          let nextLength = (snapshot.text as NSString).length
          if nextLength > previousLength {
            storage.beginEditing()
            storage.append(
              appearance.attributedString(
                for: snapshot,
                range: NSRange(
                  location: previousLength,
                  length: nextLength - previousLength
                )
              )
            )
            storage.endEditing()
          }
        } else if forceFullRender || snapshot != renderedSnapshot {
          storage.setAttributedString(appearance.attributedString(for: snapshot))
        }
        renderedSnapshot = snapshot
        textView.terminalCursorLocation = snapshot.cursorUTF16Location

        guard preserveSelection, selection.length > 0 else { return }
        let length = (snapshot.text as NSString).length
        let location = min(selection.location, length)
        textView.setSelectedRange(
          NSRange(location: location, length: min(selection.length, length - location))
        )
      }

      private func styles(
        in previous: TerminalRenderedSnapshot,
        arePrefixOf next: TerminalRenderedSnapshot
      ) -> Bool {
        let boundary = (previous.text as NSString).length
        let previousSpans = previous.styleSpans
        let nextPrefixSpans = next.styleSpans.compactMap { span -> TerminalStyleSpan? in
          guard span.utf16Location < boundary else { return nil }
          return TerminalStyleSpan(
            utf16Location: span.utf16Location,
            utf16Length: min(span.utf16Length, boundary - span.utf16Location),
            style: span.style
          )
        }
        return previousSpans == nextPrefixSpans
      }

      private func modifiedArrow(_ final: String, flags: NSEvent.ModifierFlags) -> String {
        var modifier = 1
        if flags.contains(.shift) { modifier += 1 }
        if flags.contains(.option) { modifier += 2 }
        if flags.contains(.control) { modifier += 4 }
        return modifier == 1 ? "\u{1b}[\(final)" : "\u{1b}[1;\(modifier)\(final)"
      }
    }
  }

  @MainActor
  private final class TerminalScrollView: NSScrollView {
    var resizeHandler: (() -> Void)?
    var focusHandler: (() -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else { return }
      focusHandler?()
    }

    override func layout() {
      super.layout()
      resizeHandler?()
    }
  }

  @MainActor
  final class TerminalInputTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?
    var terminalCursorLocation = 0 {
      didSet {
        resetCursorBlink()
        needsDisplay = true
      }
    }
    var terminalCursorStyle: EditorCursorStyle = .line {
      didSet { needsDisplay = true }
    }
    var terminalCursorColor = NSColor.textColor {
      didSet { needsDisplay = true }
    }

    private var cursorBlinkTimer: Timer?
    private var cursorIsVisible = true

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window?.firstResponder === self {
        resetCursorBlink()
      } else {
        stopCursorBlinking()
      }
    }

    override func becomeFirstResponder() -> Bool {
      let result = super.becomeFirstResponder()
      if result { resetCursorBlink() }
      return result
    }

    override func resignFirstResponder() -> Bool {
      let result = super.resignFirstResponder()
      stopCursorBlinking()
      needsDisplay = true
      return result
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      resetCursorBlink()
      super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
      resetCursorBlink()
      if keyHandler?(event) == true { return }
      super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      drawTerminalCursor(in: dirtyRect)
    }

    private func startCursorBlinking() {
      guard cursorBlinkTimer == nil else { return }
      cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) {
        [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.cursorIsVisible.toggle()
          self.needsDisplay = true
        }
      }
    }

    private func stopCursorBlinking() {
      cursorBlinkTimer?.invalidate()
      cursorBlinkTimer = nil
      cursorIsVisible = false
    }

    private func resetCursorBlink() {
      cursorIsVisible = true
      if window?.firstResponder === self { startCursorBlinking() }
      needsDisplay = true
    }

    private func drawTerminalCursor(in dirtyRect: NSRect) {
      guard window?.firstResponder === self, cursorIsVisible else { return }
      guard var rect = terminalCursorRect(), rect.intersects(dirtyRect) else { return }

      let characterWidth =
        font.map {
          max(2, ("M" as NSString).size(withAttributes: [.font: $0]).width)
        } ?? 8
      switch terminalCursorStyle {
      case .line:
        rect.size.width = 2
      case .block:
        rect.size.width = max(rect.width, characterWidth)
      case .underline:
        rect.origin.y = rect.maxY - 2
        rect.size.height = 2
        rect.size.width = max(rect.width, characterWidth)
      }

      terminalCursorColor.setFill()
      NSBezierPath(rect: rect).fill()
    }

    private func terminalCursorRect() -> NSRect? {
      let length = (string as NSString).length
      let location = min(max(0, terminalCursorLocation), length)
      guard let layoutManager, let textContainer else { return nil }
      layoutManager.ensureLayout(for: textContainer)

      // `firstRect(forCharacterRange:)` is a screen-coordinate API intended for
      // input methods. Converting its zero-length result back into this text view
      // can resolve to the first line, especially at the end of a line. Keep the
      // cursor entirely in the layout manager's local coordinate system instead.
      if location == length, string.hasSuffix("\n") {
        let rect = layoutManager.extraLineFragmentRect
        guard !rect.isEmpty else { return nil }
        return NSRect(
          x: textContainerOrigin.x + rect.minX,
          y: textContainerOrigin.y + rect.minY,
          width: 2,
          height: rect.height
        )
      }

      let characterLocation = location == length ? max(0, length - 1) : location
      guard length > 0 else {
        let lineHeight = font.map { layoutManager.defaultLineHeight(for: $0) } ?? 14
        return NSRect(
          x: textContainerOrigin.x,
          y: textContainerOrigin.y,
          width: 2,
          height: lineHeight
        )
      }

      let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterLocation)
      let glyphRange = NSRange(location: glyphIndex, length: 1)
      let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
      let lineRect = layoutManager.lineFragmentRect(
        forGlyphAt: glyphIndex,
        effectiveRange: nil,
        withoutAdditionalLayout: true
      )
      let x = location == length ? glyphRect.maxX : glyphRect.minX
      return NSRect(
        x: textContainerOrigin.x + x,
        y: textContainerOrigin.y + lineRect.minY,
        width: 2,
        height: max(1, lineRect.height)
      )
    }
  }
#endif
