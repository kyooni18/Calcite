import AppKit

@MainActor
final class LineNumberRulerView: NSRulerView {
  private weak var textView: NSTextView?
  private var profile: EditorCustomProfile
  private var breakpoints: Set<Int>
  private let onToggleBreakpoint: (Int) -> Void
  private var lineIndex = EditorLineIndex(text: "")

  override var isFlipped: Bool { true }

  init(
    textView: NSTextView,
    scrollView: NSScrollView,
    profile: EditorCustomProfile,
    breakpoints: Set<Int>,
    onToggleBreakpoint: @escaping (Int) -> Void
  ) {
    self.textView = textView
    self.profile = profile
    self.breakpoints = breakpoints
    self.onToggleBreakpoint = onToggleBreakpoint
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = 48
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(boundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
    reloadLineNumbers()
  }

  required init(coder: NSCoder) {
    profile = .standard
    breakpoints = []
    onToggleBreakpoint = { _ in }
    super.init(coder: coder)
  }

  isolated deinit { NotificationCenter.default.removeObserver(self) }

  func update(
    profile: EditorCustomProfile,
    breakpoints: Set<Int>
  ) {
    self.profile = profile
    self.breakpoints = breakpoints
    updateRuleThickness()
    needsDisplay = true
  }

  @objc private func boundsDidChange(_ notification: Notification) {
    needsDisplay = true
  }

  func reloadLineNumbers() {
    guard let textView else { return }
    let source = textView.string as NSString
    lineIndex.rebuild(with: source as String)
    updateRuleThickness()
    needsDisplay = true
  }

  func applyEdit(range: NSRange, replacement: String, resultingText: String) {
    lineIndex.replace(range: range, replacement: replacement, resultingText: resultingText)
    updateRuleThickness()
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    guard let textView,
      let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer,
      layoutManager.numberOfGlyphs > 0
    else { return }
    let point = textView.convert(event.locationInWindow, from: nil)
    let containerPoint = NSPoint(
      x: max(0, point.x - textView.textContainerOrigin.x),
      y: max(0, point.y - textView.textContainerOrigin.y)
    )
    let glyph = min(
      layoutManager.glyphIndex(for: containerPoint, in: textContainer),
      layoutManager.numberOfGlyphs - 1
    )
    let character = min(
      layoutManager.characterIndexForGlyph(at: glyph),
      (textView.string as NSString).length
    )
    onToggleBreakpoint(lineNumber(at: character))
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView,
      let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer
    else { return }

    profile.surface.background.nsColor.setFill()
    __NSRectFill(bounds)
    NSColor.separatorColor.setFill()
    let separator = NSRect(
      x: bounds.maxX - 1,
      y: max(bounds.minY, rect.minY),
      width: 1,
      height: min(bounds.maxY, rect.maxY) - max(bounds.minY, rect.minY)
    )
    if separator.height > 0 { __NSRectFill(separator) }

    let origin = textView.textContainerOrigin
    let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
    let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
    var lastLine = 0

    layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
      [weak self] lineRect, _, _, glyphRange, _ in
      guard let self, glyphRange.location < layoutManager.numberOfGlyphs else { return }
      let character = layoutManager.characterIndexForGlyph(at: glyphRange.location)
      let line = self.lineNumber(at: character)
      guard line != lastLine else { return }
      lastLine = line
      self.draw(line: line, rect: lineRect, origin: origin)
    }
  }

  private func draw(line: Int, rect: NSRect, origin: NSPoint) {
    guard let textView else { return }
    let font = NSFont.monospacedDigitSystemFont(
      ofSize: max(9, profile.font.size - 2),
      weight: .regular
    )
    let activeLine = lineNumber(at: textView.selectedRange().location)
    let displayedLine =
      profile.vim.enabled && profile.vim.relativeLineNumbers && line != activeLine
      ? abs(line - activeLine)
      : line
    let value = "\(displayedLine)" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: profile.surface.foreground.nsColor.withAlphaComponent(
        line == activeLine ? 0.9 : 0.48
      ),
    ]
    let size = value.size(withAttributes: attributes)
    let textRect = rect.offsetBy(dx: origin.x, dy: origin.y)
    let rulerRect = convert(textRect, from: textView)
    let y = rulerRect.minY + max(0, (rulerRect.height - size.height) / 2)
    value.draw(
      at: NSPoint(x: ruleThickness - size.width - 8, y: y),
      withAttributes: attributes
    )

    if breakpoints.contains(line) {
      profile.highlights.error.nsColor.setFill()
      NSBezierPath(
        ovalIn: NSRect(x: 7, y: rulerRect.midY - 4.5, width: 9, height: 9)
      ).fill()
    }

  }

  private func lineNumber(at characterIndex: Int) -> Int {
    lineIndex.lineNumber(atUTF16Offset: characterIndex)
  }

  private func updateRuleThickness() {
    let digits = max(2, String(lineIndex.lineCount).count)
    let target = max(48, CGFloat(digits) * max(7, profile.font.size * 0.65) + 26)
    guard abs(ruleThickness - target) > 0.5 else { return }
    ruleThickness = target
    Task { @MainActor [weak scrollView] in
      await Task.yield()
      guard !Task.isCancelled else { return }
      scrollView?.needsLayout = true
    }
  }
}
