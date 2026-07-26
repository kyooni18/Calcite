#if os(macOS)
  import AppKit
  import SwiftUI

  struct TerminalTextView: NSViewRepresentable {
    let snapshot: TerminalRenderedSnapshot
    let outputEpoch: UInt64
    let preferences: EditorTerminalPreferences
    let appearanceRevision: UInt64
    let send: (String) -> Void
    var sendMouse: ((TerminalMouseInput) -> Void)? = nil
    let clear: () -> Void
    let resize: (Int, Int) -> Void
    var save: (() -> Void)? = nil
    var navigateSection: ((Bool) -> Void)? = nil
    var navigateSectionDirection: ((MainSectionDirection) -> Void)? = nil
    var allowsScrolling = true
    /// Vim/Neovim use the terminal mouse protocol; consuming these events here
    /// prevents NSTextView from creating a native text selection.
    var routesPointerEventsToTerminal = false

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
      let scrollView = TerminalScrollView()
      scrollView.hasVerticalScroller = allowsScrolling
      scrollView.hasHorizontalScroller = false
      scrollView.autohidesScrollers = true
      scrollView.allowsScrolling = allowsScrolling
      scrollView.borderType = .noBorder
      scrollView.drawsBackground = true
      // Leave room below the shell prompt when the terminal view is remounted.
      scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 18, right: 0)

      let textView = TerminalInputTextView()
      textView.isEditable = false
      textView.isSelectable = !routesPointerEventsToTerminal
      textView.suppressesNativePointerInteraction = routesPointerEventsToTerminal
      textView.isRichText = false
      textView.drawsBackground = true
      textView.textContainer?.lineFragmentPadding = 0
      textView.autoresizingMask = [.width]
      textView.isAutomaticQuoteSubstitutionEnabled = false
      textView.isAutomaticDashSubstitutionEnabled = false
      textView.isAutomaticTextReplacementEnabled = false
      textView.isContinuousSpellCheckingEnabled = false
      textView.keyHandler = context.coordinator.handle
      textView.pointerHandler = { [weak coordinator = context.coordinator] event, input in
        coordinator?.routePointer(input, from: event) ?? false
      }
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
      scrollView.pointerHandler = { [weak coordinator] event in
        coordinator?.routeScroll(event) ?? false
      }
      context.coordinator.updateAppearance(force: true)
      context.coordinator.updateSize()
      context.coordinator.updateSnapshot(snapshot)
      context.coordinator.focusInput()
      return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
      context.coordinator.parent = self
      scrollView.hasVerticalScroller = allowsScrolling
      (scrollView as? TerminalScrollView)?.allowsScrolling = allowsScrolling
      if let textView = scrollView.documentView as? TerminalInputTextView {
        textView.isSelectable = !routesPointerEventsToTerminal
        textView.suppressesNativePointerInteraction = routesPointerEventsToTerminal
      }
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
      private var resizePublicationTask: Task<Void, Never>?
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

      /// A horizontal window drag can cross many terminal columns before zsh has finished
      /// repainting the first one. Publish only the settled size so output from an intermediate
      /// SIGWINCH is never decoded using a later width.
      func scheduleResizePublication(_ size: (columns: Int, rows: Int)) {
        pendingSize = size
        resizePublicationTask?.cancel()

        resizePublicationTask = Task { @MainActor [weak self] in
          do {
            try await Task.sleep(for: .milliseconds(50))
          } catch {
            return
          }
          guard let self else { return }
          guard !Task.isCancelled else { return }
          guard let size = self.pendingSize else { return }
          self.pendingSize = nil
          self.resizePublicationTask = nil
          self.parent.resize(size.columns, size.rows)
        }
      }

      func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains([.control, .option]),
          !flags.contains(.command),
          !flags.contains(.shift),
          let navigateSection = parent.navigateSection
        {
          switch event.keyCode {
          case 123:
            navigateSection(false)
            return true
          case 124:
            navigateSection(true)
            return true
          default:
            break
          }
        }

        if let direction = hostSectionDirection(for: event, flags: flags),
          let navigateSectionDirection = parent.navigateSectionDirection
        {
          navigateSectionDirection(direction)
          return true
        }

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
          case "s":
            if let save = parent.save {
              save()
              return true
            }
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

      func routePointer(_ input: TerminalPointerInput, from event: NSEvent) -> Bool {
        guard parent.routesPointerEventsToTerminal else { return false }
        focusInput()
        guard let mouse = mouseInput(input, event: event) else { return true }
        parent.sendMouse?(mouse)
        return true
      }

      func routeScroll(_ event: NSEvent) -> Bool {
        guard parent.routesPointerEventsToTerminal else { return false }
        focusInput()
        let delta = event.scrollingDeltaY
        guard delta != 0, let point = terminalPoint(for: event) else { return true }
        parent.sendMouse?(.scroll(up: delta > 0, column: point.column, row: point.row))
        return true
      }

      private func mouseInput(_ input: TerminalPointerInput, event: NSEvent) -> TerminalMouseInput? {
        guard let point = terminalPoint(for: event) else { return nil }
        switch input {
        case .leftDown: return .buttonDown(0, column: point.column, row: point.row)
        case .leftUp: return .buttonUp(0, column: point.column, row: point.row)
        case .leftDrag: return .drag(0, column: point.column, row: point.row)
        case .rightDown: return .buttonDown(2, column: point.column, row: point.row)
        case .rightUp: return .buttonUp(2, column: point.column, row: point.row)
        case .rightDrag: return .drag(2, column: point.column, row: point.row)
        }
      }

      private func terminalPoint(for event: NSEvent) -> (column: Int, row: Int)? {
        guard let textView, let font = textView.font else { return nil }
        let location = textView.convert(event.locationInWindow, from: nil)
        let origin = textView.textContainerOrigin
        let width = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let height = max(1, textView.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize)
        return (
          column: max(1, Int((location.x - origin.x) / width) + 1),
          row: max(1, Int((location.y - origin.y) / height) + 1)
        )
      }

      private func hostSectionDirection(
        for event: NSEvent,
        flags: NSEvent.ModifierFlags
      ) -> MainSectionDirection? {
        guard flags.contains([.command, .option]),
          !flags.contains(.control),
          !flags.contains(.shift)
        else {
          return nil
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "h": return .left
        case "j": return .down
        case "k": return .up
        case "l": return .right
        default: return nil
        }
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
    var allowsScrolling = true
    var pointerHandler: ((NSEvent) -> Bool)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else { return }
      focusHandler?()
    }

    override func layout() {
      super.layout()
      resizeHandler?()
    }

    override func scrollWheel(with event: NSEvent) {
      if pointerHandler?(event) == true { return }
      guard allowsScrolling else {
        focusHandler?()
        return
      }
      super.scrollWheel(with: event)
    }
  }

  @MainActor
  final class TerminalInputTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?
    var pointerHandler: ((NSEvent, TerminalPointerInput) -> Bool)?
    var suppressesNativePointerInteraction = false
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
      if pointerHandler?(event, .leftDown) == true { return }
      window?.makeFirstResponder(self)
      resetCursorBlink()
      super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
      if pointerHandler?(event, .leftUp) == true { return }
      super.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
      if pointerHandler?(event, .leftDrag) == true { return }
      super.mouseDragged(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
      if pointerHandler?(event, .rightDown) == true { return }
      super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
      if pointerHandler?(event, .rightUp) == true { return }
      super.rightMouseUp(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
      if pointerHandler?(event, .rightDrag) == true { return }
      super.rightMouseDragged(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
      if suppressesNativePointerInteraction { return nil }
      return super.menu(for: event)
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

enum TerminalPointerInput {
    case leftDown, leftUp, leftDrag, rightDown, rightUp, rightDrag
  }
#endif
