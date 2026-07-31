import AppKit
import EditorServices
import Foundation

let editorRichPresentationUTF16Limit = 1_000_000

@MainActor
struct MarkdownCodeBlockDecoration: Equatable {
  let contentRange: NSRange
  let language: String
  let code: String
}

@MainActor
struct InlineDiagnosticMessage: Equatable {
  let lineRange: NSRange
  let message: String
  let severity: Diagnostic.Severity
}

@MainActor
private final class EditorInsertionCaretView: NSView {
  var color = NSColor.textInsertionPointColor {
    didSet { needsDisplay = true }
  }
  private var blinkTimer: Timer?

  override func draw(_ dirtyRect: NSRect) {
    color.setFill()
    NSBezierPath(rect: bounds).fill()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func showImmediately(blinks: Bool = true) {
    blinkTimer?.invalidate()
    blinkTimer = nil
    alphaValue = 1
    isHidden = false
    needsDisplay = true

    guard blinks else { return }
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.isHidden else { return }
        self.alphaValue = self.alphaValue == 0 ? 1 : 0
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    blinkTimer = timer
  }

  func hide() {
    blinkTimer?.invalidate()
    blinkTimer = nil
    alphaValue = 1
    isHidden = true
  }
}

@MainActor
final class CodeEditorTextView: NSTextView {
  var languageID = ""
  var keyEventHandler: ((NSEvent, NSTextView) -> Bool)?
  var textInputHandler: ((Any, NSRange, NSTextView) -> Bool)?
  var markedTextHandler: ((Any, NSRange, NSRange, NSTextView) -> Bool)?
  var unmarkTextHandler: ((NSTextView) -> Bool)?
  var zoomHandler: ((CGFloat, NSTextView) -> Bool)?
  var goToDefinitionHandler: (() -> Void)?
  var findReferencesHandler: (() -> Void)?
  var showQuickHelpHandler: (() -> Void)?
  var showFindHandler: ((Bool) -> Void)?
  var activationHandler: (() -> Void)?
  var nativePointerSelectionHandler: ((NSRange, NSTextView) -> Void)?
  private(set) var isProcessingPointerSelection = false
  private var pointerSelectionRange: NSRange?
  var errorLineRanges: [NSRange] = [] {
    didSet { needsDisplay = true }
  }
  var errorLineTint = NSColor.systemRed.withAlphaComponent(0.18) {
    didSet { needsDisplay = true }
  }
  var inlineDiagnosticMessages: [InlineDiagnosticMessage] = [] {
    didSet { needsDisplay = true }
  }
  var diagnosticColors: [Diagnostic.Severity: NSColor] = [:] {
    didSet { needsDisplay = true }
  }
  var diagnosticMessageTextColor = NSColor.labelColor {
    didSet { needsDisplay = true }
  }
  var editorCursorStyle: EditorCursorStyle = .line {
    didSet {
      guard oldValue != editorCursorStyle else { return }
      refreshInsertionPointRendering()
    }
  }
  /// A mode-specific override supplied by the Vim input controller. Keeping it
  /// separate from the profile style means switching back to GUI editing restores
  /// the user's configured cursor without rewriting the profile.
  var vimCursorStyle: EditorCursorStyle? {
    didSet {
      guard oldValue != vimCursorStyle else { return }
      refreshInsertionPointRendering()
    }
  }
  /// VimEngine owns the cursor in non-insert modes. `NSTextView` exposes only
  /// its projected selection, so the native Vim coordinator supplies the actual
  /// engine endpoint separately for Normal, Replace, and Visual rendering.
  var vimCursorLocation: Int? {
    didSet {
      guard oldValue != vimCursorLocation else { return }
      refreshInsertionPointRendering()
    }
  }
  var editorCursorColor = NSColor.labelColor {
    didSet {
      guard !oldValue.isEqual(editorCursorColor) else { return }
      refreshInsertionPointRendering()
    }
  }
  /// Rich editor presentations can reshape or collapse source glyphs without
  /// changing the underlying insertion offset. In those modes AppKit's native
  /// caret inherits the presented glyph metrics and can become tiny, displaced,
  /// or invisible. Keep the stable editor-owned line caret for those surfaces.
  var requiresPresentationAwareInsertionPoint = false {
    didSet {
      guard oldValue != requiresPresentationAwareInsertionPoint else { return }
      refreshInsertionPointRendering()
    }
  }
  private let customCursorView: EditorInsertionCaretView = {
    let view = EditorInsertionCaretView(frame: .zero)
    view.wantsLayer = true
    view.layer?.masksToBounds = false
    return view
  }()
  private var virtualMarkedText: NSAttributedString?
  private var isDiscardingMarkedText = false
  private enum InlineDiagnosticHitAction {
    case toggle(lineLocation: Int)
    case copy(message: String)
  }

  private struct InlineDiagnosticLayoutCandidate {
    let diagnostic: InlineDiagnosticMessage
    let message: NSAttributedString
    let color: NSColor
    let borderColor: NSColor
    let isExpanded: Bool
    let copyControlWidth: CGFloat
    let preferredFrame: NSRect
  }

  private struct InlineDiagnosticLayout {
    let candidate: InlineDiagnosticLayoutCandidate
    let frame: NSRect
  }

  private var inlineDiagnosticHitTargets: [(rect: NSRect, action: InlineDiagnosticHitAction)] = []
  private var expandedInlineDiagnosticLine: Int?
  var codeBlockDecorations: [MarkdownCodeBlockDecoration] = [] {
    didSet { needsDisplay = true }
  }
  var markdownBulletRanges: [NSRange] = [] {
    didSet { needsDisplay = true }
  }
  var markdownRuleRanges: [NSRange] = [] {
    didSet { needsDisplay = true }
  }
  private var codeBlockCopyButtons: [(rect: NSRect, code: String)] = []

  private var isHandlingForceClick = false

  override func didChangeText() {
    super.didChangeText()
    refreshInsertionPointRendering()
  }

  /// Use AppKit's native caret for ordinary GUI editing. Custom rendering is
  /// reserved for Vim and non-line cursor shapes, so a bridge refresh cannot
  /// leave normal mode with both the native and custom carets hidden.
  override var shouldDrawInsertionPoint: Bool { usesNativeInsertionPoint }

  override func drawInsertionPoint(
    in rect: NSRect,
    color: NSColor,
    turnedOn flag: Bool
  ) {
    guard usesNativeInsertionPoint else { return }
    super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
  }

  private var usesNativeInsertionPoint: Bool {
    !requiresPresentationAwareInsertionPoint
      && vimCursorStyle == nil
      && vimCursorLocation == nil
      && editorCursorStyle == .line
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      activationHandler?()
      refreshInsertionPointRendering()
    }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    customCursorView.hide()
    return result
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    refreshInsertionPointRendering()
  }

  override func layout() {
    super.layout()
    refreshCustomInsertionPoint()
    refreshGeometryDiagnostics()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    refreshCustomInsertionPoint()
    refreshGeometryDiagnostics()
  }

  func refreshInsertionPointRendering() {
    insertionPointColor = usesNativeInsertionPoint ? editorCursorColor : .clear
    if usesNativeInsertionPoint {
      customCursorView.hide()
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
      return
    }
    refreshCustomInsertionPoint()
    window?.invalidateCursorRects(for: self)
  }

  func refreshCustomInsertionPoint() {
    let ownsKeyboardFocus = window?.firstResponder === self
    guard !usesNativeInsertionPoint,
      ownsKeyboardFocus || vimCursorLocation != nil,
      selectedRange().length == 0 || vimCursorLocation != nil,
      let cursorRect = customInsertionPointRect()
    else {
      customCursorView.hide()
      return
    }
    if customCursorView.superview !== self {
      customCursorView.hide()
      addSubview(customCursorView, positioned: .above, relativeTo: nil)
    }
    customCursorView.color = editorCursorColor
    customCursorView.frame = cursorRect.integral
    customCursorView.layer?.zPosition = 10_000
    customCursorView.showImmediately(blinks: vimCursorLocation == nil)
    refreshGeometryDiagnostics()
  }

  func customInsertionPointRect() -> NSRect? {
    guard let layoutManager, let textContainer else { return nil }

    let sourceLength = (string as NSString).length
    let cursorLocation = vimCursorLocation ?? selectedRange().location
    let location = min(max(cursorLocation, 0), sourceLength)
    let layoutLocation = min(location, max(0, sourceLength - 1))
    layoutManager.ensureLayout(
      forCharacterRange: NSRange(
        location: layoutLocation,
        length: sourceLength == 0 ? 0 : 1
      )
    )
    let layoutRect: NSRect
    if sourceLength == 0 || (location == sourceLength && string.hasSuffix("\n")) {
      layoutRect = layoutManager.extraLineFragmentRect
    } else {
      let characterLocation = min(location, sourceLength - 1)
      let glyph = layoutManager.glyphIndexForCharacter(at: characterLocation)
      let glyphRect = layoutManager.boundingRect(
        forGlyphRange: NSRange(location: glyph, length: 1),
        in: textContainer
      )
      if location == sourceLength {
        // TextKit's extra-line-fragment rect is empty at EOF unless the text
        // ends in a newline. Anchor the insertion point after the final glyph
        // so Vim's cursor remains visible and correctly positioned at EOF.
        let lineRect = layoutManager.lineFragmentRect(
          forGlyphAt: glyph,
          effectiveRange: nil
        )
        layoutRect = NSRect(
          x: glyphRect.maxX,
          y: lineRect.minY,
          width: 0,
          height: lineRect.height
        )
      } else {
        layoutRect = glyphRect
      }
    }

    let fallbackLineHeight = font?.boundingRectForFont.height ?? 14
    let lineHeight: CGFloat
    if location == sourceLength, sourceLength > 0, string.hasSuffix("\n") {
      // `extraLineFragmentRect` provides the correct origin for the final
      // empty line, but a trailing newline glyph can own both that line and
      // the preceding one. Its line-fragment height is then two editor rows,
      // which makes a block Vim cursor appear doubled. Derive the normal row
      // height from the editor's uniform font and paragraph spacing instead.
      lineHeight = max(
        fallbackLineHeight,
        fallbackLineHeight + (defaultParagraphStyle?.lineSpacing ?? 0)
      )
    } else {
      lineHeight = max(layoutRect.height, fallbackLineHeight)
    }
    var cursorRect = NSRect(
      x: layoutRect.minX + textContainerOrigin.x,
      y: layoutRect.minY + textContainerOrigin.y,
      width: max(1, layoutRect.width),
      height: lineHeight
    )
    switch vimCursorStyle ?? editorCursorStyle {
    case .line:
      cursorRect.size.width = max(1.5, min(2, lineHeight * 0.12))
    case .block:
      let characterWidth = editorCursorCellWidth(fallback: cursorRect.width)
      // A Vim block occupies exactly one editor cell. The glyph bounding rect
      // can span a tab, ligature, or fallback run and must not widen the cursor.
      cursorRect.size.width = characterWidth
    case .underline:
      cursorRect.origin.y = cursorRect.maxY - 2
      cursorRect.size.height = 2
      let characterWidth = editorCursorCellWidth(fallback: cursorRect.width)
      cursorRect.size.width = characterWidth
    }
    return cursorRect
  }

  private func editorCursorCellWidth(fallback: CGFloat) -> CGFloat {
    guard let font else { return max(2, fallback) }
    let measured = ("M" as NSString).size(withAttributes: [.font: font]).width
    guard measured.isFinite, measured > 0 else { return max(2, fallback) }
    return max(2, measured)
  }

  override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    guard let layoutManager, let textContainer else { return }

    drawCodeBlocks(
      in: rect,
      layoutManager: layoutManager,
      textContainer: textContainer
    )
    drawMarkdownStructures(
      in: rect,
      layoutManager: layoutManager,
      textContainer: textContainer
    )

    if !errorLineRanges.isEmpty {
      errorLineTint.setFill()
      let origin = textContainerOrigin
      for characterRange in errorLineRanges {
        let glyphRange = layoutManager.glyphRange(
          forCharacterRange: characterRange,
          actualCharacterRange: nil
        )
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
          [weak self] lineRect, _, _, _, _ in
          guard let self else { return }
          let tintedLine = NSRect(
            x: self.bounds.minX,
            y: lineRect.minY + origin.y,
            width: self.bounds.width,
            height: lineRect.height
          )
          let visibleTint = tintedLine.intersection(rect)
          if !visibleTint.isNull { __NSRectFill(visibleTint) }
        }
      }
    }

  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let layoutManager, let textContainer else { return }
    drawErrorLineAccents(
      in: dirtyRect,
      layoutManager: layoutManager,
      textContainer: textContainer
    )
    drawInlineDiagnosticMessages(
      in: dirtyRect,
      layoutManager: layoutManager,
      textContainer: textContainer
    )
  }

  private func drawErrorLineAccents(
    in dirtyRect: NSRect,
    layoutManager: NSLayoutManager,
    textContainer: NSTextContainer
  ) {
    guard !errorLineRanges.isEmpty else { return }
    let origin = textContainerOrigin
    errorLineTint.withAlphaComponent(0.86).setFill()
    for characterRange in errorLineRanges {
      let glyphRange = layoutManager.glyphRange(
        forCharacterRange: characterRange,
        actualCharacterRange: nil
      )
      layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
        [weak self] lineRect, _, _, _, _ in
        guard let self else { return }
        let accent = NSRect(
          x: origin.x,
          y: lineRect.maxY + origin.y - 2,
          width: max(0, self.visibleRect.maxX - origin.x),
          height: 2
        )
        let visibleAccent = accent.intersection(dirtyRect)
        if !visibleAccent.isNull { __NSRectFill(visibleAccent) }
      }
    }
  }

  private func drawInlineDiagnosticMessages(
    in dirtyRect: NSRect,
    layoutManager: NSLayoutManager,
    textContainer: NSTextContainer
  ) {
    inlineDiagnosticHitTargets.removeAll(keepingCapacity: true)
    guard !inlineDiagnosticMessages.isEmpty else { return }

    let origin = textContainerOrigin
    let viewport = visibleRect
    let candidates = inlineDiagnosticMessages.compactMap { diagnostic in
      makeInlineDiagnosticLayoutCandidate(
        for: diagnostic,
        layoutManager: layoutManager,
        origin: origin,
        viewport: viewport
      )
    }
    let layouts = resolveInlineDiagnosticLayouts(candidates, in: viewport)

    for layout in layouts {
      let candidate = layout.candidate
      let diagnostic = candidate.diagnostic
      let bubble = layout.frame
      let copyRect = NSRect(
        x: bubble.maxX - 42,
        y: bubble.minY + 4,
        width: 34,
        height: 12
      )

      // Hit targets are rebuilt for the whole visible viewport, even during a partial redraw.
      if candidate.isExpanded {
        inlineDiagnosticHitTargets.append(
          (copyRect.insetBy(dx: -4, dy: -4), .copy(message: diagnostic.message)))
      }
      inlineDiagnosticHitTargets.append(
        (bubble, .toggle(lineLocation: diagnostic.lineRange.location)))

      guard bubble.intersects(dirtyRect) || candidate.isExpanded else { continue }

      let pill = NSBezierPath(roundedRect: bubble, xRadius: 6, yRadius: 6)
      backgroundColor.withAlphaComponent(1).setFill()
      pill.fill()
      NSGraphicsContext.saveGraphicsState()
      let glow = NSShadow()
      glow.shadowColor = candidate.borderColor.withAlphaComponent(0.22)
      glow.shadowBlurRadius = 6
      glow.shadowOffset = .zero
      glow.set()
      candidate.borderColor.withAlphaComponent(0.48).setStroke()
      pill.lineWidth = 1.25
      pill.stroke()
      NSGraphicsContext.restoreGraphicsState()
      candidate.borderColor.withAlphaComponent(0.7).setStroke()
      pill.lineWidth = 1
      pill.stroke()

      let symbolRect = NSRect(
        x: bubble.minX + 6,
        y: bubble.midY - 6,
        width: 12,
        height: 12
      )
      candidate.color.withAlphaComponent(0.16).setFill()
      NSBezierPath(ovalIn: symbolRect).fill()
      candidate.color.withAlphaComponent(0.72).setStroke()
      NSBezierPath(ovalIn: symbolRect).stroke()
      let symbol = diagnosticSymbol(for: diagnostic.severity)
      let symbolAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .bold),
        .foregroundColor: candidate.color.withAlphaComponent(0.9),
      ]
      let symbolSize = (symbol as NSString).size(withAttributes: symbolAttributes)
      (symbol as NSString).draw(
        at: NSPoint(
          x: symbolRect.midX - symbolSize.width / 2,
          y: symbolRect.midY - symbolSize.height / 2 + 0.5
        ),
        withAttributes: symbolAttributes
      )
      candidate.message.draw(
        with: NSRect(
          x: bubble.minX + 24,
          y: bubble.minY + 3,
          width: max(0, bubble.width - 30 - candidate.copyControlWidth),
          height: bubble.height - 6
        ),
        options: candidate.isExpanded
          ? [.usesLineFragmentOrigin, .usesFontLeading]
          : [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
      )
      if candidate.isExpanded {
        let title = "Copy" as NSString
        let copyAttributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
          .foregroundColor: candidate.borderColor.withAlphaComponent(0.95),
        ]
        title.draw(at: copyRect.origin, withAttributes: copyAttributes)
      }
    }
  }

  private func makeInlineDiagnosticLayoutCandidate(
    for diagnostic: InlineDiagnosticMessage,
    layoutManager: NSLayoutManager,
    origin: NSPoint,
    viewport: NSRect
  ) -> InlineDiagnosticLayoutCandidate? {
    let glyphRange = layoutManager.glyphRange(
      forCharacterRange: diagnostic.lineRange,
      actualCharacterRange: nil
    )
    guard glyphRange.length > 0 else { return nil }
    let usedRect = layoutManager.lineFragmentUsedRect(
      forGlyphAt: glyphRange.location,
      effectiveRange: nil
    ).offsetBy(dx: origin.x, dy: origin.y)
    guard usedRect.intersects(viewport) else { return nil }

    let color = diagnosticColor(for: diagnostic.severity)
    let borderColor = mutedDiagnosticColor(for: diagnostic.severity)
    let isExpanded = expandedInlineDiagnosticLine == diagnostic.lineRange.location
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = isExpanded ? .byWordWrapping : .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: max(10, (font?.pointSize ?? 12) - 2), weight: .medium),
      .foregroundColor: diagnosticMessageTextColor.withAlphaComponent(0.92),
      .paragraphStyle: paragraph,
    ]
    let text = diagnostic.message as NSString
    let desiredWidth = text.size(withAttributes: attributes).width + 34
    let maximumWidth = min(480, max(0, viewport.width - 16))
    guard maximumWidth >= 52 else { return nil }
    let width = isExpanded ? maximumWidth : min(desiredWidth, maximumWidth)
    let preferredX = max(usedRect.maxX + 72, origin.x + 4)
    let x = min(max(viewport.minX + 8, preferredX), viewport.maxX - width - 8)
    let copyControlWidth: CGFloat = isExpanded ? 46 : 0
    let messageWidth = max(0, width - 30 - copyControlWidth)
    let message = NSAttributedString(string: text as String, attributes: attributes)
    let messageHeight =
      isExpanded
      ? ceil(
        message.boundingRect(
          with: NSSize(width: messageWidth, height: .greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
      )
      : 14
    let height = max(20, min(isExpanded ? messageHeight + 10 : 20, 110))
    let preferredFrame = NSRect(
      x: x,
      y: usedRect.minY + max(0, (usedRect.height - height) / 2),
      width: width,
      height: height
    )
    return InlineDiagnosticLayoutCandidate(
      diagnostic: diagnostic,
      message: message,
      color: color,
      borderColor: borderColor,
      isExpanded: isExpanded,
      copyControlWidth: copyControlWidth,
      preferredFrame: preferredFrame
    )
  }

  private func resolveInlineDiagnosticLayouts(
    _ candidates: [InlineDiagnosticLayoutCandidate],
    in viewport: NSRect
  ) -> [InlineDiagnosticLayout] {
    let margin: CGFloat = 8
    let spacing: CGFloat = 6
    let usableViewport = viewport.insetBy(dx: margin, dy: margin)
    guard usableViewport.width > 0, usableViewport.height > 0 else { return [] }

    let ordered = candidates.enumerated().sorted { lhs, rhs in
      let lhsY = lhs.element.preferredFrame.minY
      let rhsY = rhs.element.preferredFrame.minY
      if abs(lhsY - rhsY) > 0.5 { return lhsY < rhsY }
      if lhs.element.isExpanded != rhs.element.isExpanded {
        return lhs.element.isExpanded
      }
      return lhs.offset < rhs.offset
    }

    var occupied: [NSRect] = []
    var resolvedByIndex: [Int: InlineDiagnosticLayout] = [:]
    resolvedByIndex.reserveCapacity(ordered.count)

    for (originalIndex, candidate) in ordered {
      var frame = candidate.preferredFrame
      frame.origin.x = min(
        max(frame.origin.x, usableViewport.minX),
        max(usableViewport.minX, usableViewport.maxX - frame.width)
      )
      frame.origin.y = min(
        max(frame.origin.y, usableViewport.minY),
        max(usableViewport.minY, usableViewport.maxY - frame.height)
      )

      let preferredY = frame.minY
      let downward = resolveDiagnosticFrameDownward(
        frame,
        occupied: occupied,
        viewport: usableViewport,
        spacing: spacing
      )
      let upward = resolveDiagnosticFrameUpward(
        frame,
        occupied: occupied,
        viewport: usableViewport,
        spacing: spacing
      )
      if let downward, let upward {
        frame =
          abs(downward.minY - preferredY) <= abs(upward.minY - preferredY)
          ? downward
          : upward
      } else if let downward {
        frame = downward
      } else if let upward {
        frame = upward
      } else {
        // In an over-constrained viewport, preserve the closest anchor and avoid drifting
        // outside the editor. The frame may touch another badge but never leaves the viewport.
        frame.origin.y = min(
          max(frame.origin.y, usableViewport.minY),
          max(usableViewport.minY, usableViewport.maxY - frame.height)
        )
      }

      occupied.append(frame)
      resolvedByIndex[originalIndex] = InlineDiagnosticLayout(candidate: candidate, frame: frame)
    }

    return candidates.indices.compactMap { resolvedByIndex[$0] }
  }

  private func resolveDiagnosticFrameDownward(
    _ initialFrame: NSRect,
    occupied: [NSRect],
    viewport: NSRect,
    spacing: CGFloat
  ) -> NSRect? {
    var frame = initialFrame
    for _ in 0...occupied.count {
      let collisions = occupied.filter { diagnosticFramesOverlap(frame, $0, spacing: spacing) }
      guard !collisions.isEmpty else {
        return frame.maxY <= viewport.maxY ? frame : nil
      }
      frame.origin.y = collisions.map(\.maxY).max()! + spacing
      if frame.maxY > viewport.maxY { return nil }
    }
    return nil
  }

  private func resolveDiagnosticFrameUpward(
    _ initialFrame: NSRect,
    occupied: [NSRect],
    viewport: NSRect,
    spacing: CGFloat
  ) -> NSRect? {
    var frame = initialFrame
    for _ in 0...occupied.count {
      let collisions = occupied.filter { diagnosticFramesOverlap(frame, $0, spacing: spacing) }
      guard !collisions.isEmpty else {
        return frame.minY >= viewport.minY ? frame : nil
      }
      frame.origin.y = collisions.map(\.minY).min()! - spacing - frame.height
      if frame.minY < viewport.minY { return nil }
    }
    return nil
  }

  private func diagnosticFramesOverlap(
    _ lhs: NSRect,
    _ rhs: NSRect,
    spacing: CGFloat
  ) -> Bool {
    lhs.insetBy(dx: -spacing / 2, dy: -spacing / 2).intersects(rhs)
  }

  private func diagnosticColor(for severity: Diagnostic.Severity) -> NSColor {
    if let color = diagnosticColors[severity] { return color }
    switch severity {
    case .error: return NSColor.systemRed
    case .warning: return NSColor.systemOrange
    case .information: return NSColor.systemBlue
    case .hint: return NSColor.systemGreen
    }
  }

  private func mutedDiagnosticColor(for severity: Diagnostic.Severity) -> NSColor {
    let color = diagnosticColor(for: severity)
    return color.blended(withFraction: 0.62, of: NSColor.windowBackgroundColor) ?? color
  }

  private func diagnosticSymbol(for severity: Diagnostic.Severity) -> String {
    switch severity {
    case .error: return "×"
    case .warning: return "!"
    case .information: return "i"
    case .hint: return "~"
    }
  }

  override func setMarkedText(
    _ string: Any,
    selectedRange: NSRange,
    replacementRange: NSRange
  ) {
    if markedTextHandler?(string, selectedRange, replacementRange, self) == true {
      let attributed: NSAttributedString
      if let value = string as? NSAttributedString {
        attributed = value
      } else if let value = string as? String {
        attributed = NSAttributedString(string: value)
      } else {
        attributed = NSAttributedString(string: String(describing: string))
      }
      virtualMarkedText = attributed
      refreshInsertionPointRendering()
      return
    }
    virtualMarkedText = nil
    super.setMarkedText(
      string,
      selectedRange: selectedRange,
      replacementRange: replacementRange
    )
    refreshInsertionPointRendering()
  }

  override func unmarkText() {
    if isDiscardingMarkedText {
      super.unmarkText()
      return
    }
    let consumed = unmarkTextHandler?(self) == true
    virtualMarkedText = nil
    refreshInsertionPointRendering()
    if consumed { return }
    super.unmarkText()
    refreshInsertionPointRendering()
  }

  override func hasMarkedText() -> Bool {
    virtualMarkedText != nil || super.hasMarkedText()
  }

  override func markedRange() -> NSRange {
    if let virtualMarkedText {
      return NSRange(location: selectedRange().location, length: virtualMarkedText.length)
    }
    return super.markedRange()
  }

  func discardMarkedTextState() {
    virtualMarkedText = nil
    isDiscardingMarkedText = true
    defer {
      isDiscardingMarkedText = false
      refreshInsertionPointRendering()
    }
    inputContext?.discardMarkedText()
    if super.hasMarkedText() { super.unmarkText() }
  }

  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    if textInputHandler?(insertString, replacementRange, self) == true {
      virtualMarkedText = nil
      refreshInsertionPointRendering()
      return
    }
    virtualMarkedText = nil
    super.insertText(insertString, replacementRange: replacementRange)
    refreshInsertionPointRendering()
  }

  override func keyDown(with event: NSEvent) {
    activationHandler?()
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command), !flags.contains(.option) {
      // `⌘+` is physically the equals key with Shift held. Matching the
      // character alone lets SwiftUI's command shortcut treat it like `⌘−`
      // on some keyboard layouts, so decide from the physical key first.
      switch event.keyCode {
      case 27:  // -
        if !flags.contains(.shift), zoomHandler?(-0.1, self) == true { return }
      case 24:  // = / +
        if zoomHandler?(0.1, self) == true { return }
      default:
        break
      }

      guard !flags.contains(.shift) else {
        super.keyDown(with: event)
        refreshInsertionPointRendering()
        return
      }

      switch event.charactersIgnoringModifiers {
      case "f", "F":
        showFindHandler?(false)
        return
      case "h", "H":
        showFindHandler?(true)
        return
      default:
        break
      }
    }
    if keyEventHandler?(event, self) == true { return }
    super.keyDown(with: event)
    // Selection notifications can arrive while TextKit is still processing the
    // key event. Refresh once more from the final selection and layout state.
    refreshInsertionPointRendering()
  }

  override func mouseDown(with event: NSEvent) {
    activationHandler?()
    let point = convert(event.locationInWindow, from: nil)
    if let target = inlineDiagnosticHitTargets.first(where: { $0.rect.contains(point) }) {
      switch target.action {
      case .toggle(let lineLocation):
        expandedInlineDiagnosticLine =
          expandedInlineDiagnosticLine == lineLocation
          ? nil
          : lineLocation
        needsDisplay = true
      case .copy(let message):
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message, forType: .string)
      }
      return
    }
    if let button = codeBlockCopyButtons.first(where: { $0.rect.contains(point) }) {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(button.code, forType: .string)
      return
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.command) {
      selectSymbol(at: event)
      goToDefinitionHandler?()
      return
    }
    if modifiers.contains(.option) {
      selectSymbol(at: event)
      showQuickHelpHandler?()
      return
    }
    let selectionBeforeMouseDown = selectedRange()
    pointerSelectionRange = pointerInsertionRange(for: event)
    isProcessingPointerSelection = true
    super.mouseDown(with: event)
    isProcessingPointerSelection = false
    // NSTextView completes click/drag hit-testing during `super`. Notify the
    // Vim bridge only after the final native selection is available. TextKit
    // can synchronously reapply Vim's previous presentation while processing
    // the delegate callback, so retain the hit-tested insertion offset instead
    // of relying solely on `selectedRange()` after `super` returns.
    refreshInsertionPointRendering()
    let finalSelection = selectedRange()
    let pointerSelection = Self.resolvedPointerSelection(
      hitTested: pointerSelectionRange,
      selectionBeforeMouseDown: selectionBeforeMouseDown,
      selectionAfterMouseDown: finalSelection,
      isPlainSingleClick: event.clickCount == 1
        && !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
    )
    pointerSelectionRange = nil
    nativePointerSelectionHandler?(pointerSelection, self)
  }

  override func mouseDragged(with event: NSEvent) {
    super.mouseDragged(with: event)
    refreshInsertionPointRendering()
  }

  /// Returns a UTF-16 insertion range for the physical click independent of
  /// the current native selection. `NSTextView.characterIndexForInsertion(at:)`
  /// already handles wrapped rows, tabs, empty lines, and clicks beyond EOL.
  private func pointerInsertionRange(for event: NSEvent) -> NSRange {
    let point = convert(event.locationInWindow, from: nil)
    let length = (string as NSString).length
    let location = min(max(characterIndexForInsertion(at: point), 0), length)
    return NSRange(location: location, length: 0)
  }

  static func resolvedPointerSelection(
    hitTested: NSRange?,
    selectionBeforeMouseDown: NSRange,
    selectionAfterMouseDown: NSRange,
    isPlainSingleClick: Bool
  ) -> NSRange {
    // For drag, Shift-click, and multi-click selection, AppKit's resulting
    // range carries intentional selection semantics and must be preserved.
    guard isPlainSingleClick, let hitTested else { return selectionAfterMouseDown }

    // Prefer the physical hit target for a plain click. In particular, if a
    // delegate echo restored the old Vim selection during `super.mouseDown`,
    // `selectionAfterMouseDown` equals the pre-click range even though the user
    // clicked elsewhere.
    if selectionAfterMouseDown == selectionBeforeMouseDown
      || selectionAfterMouseDown.length != 0
      || selectionAfterMouseDown.location != hitTested.location
    {
      return hitTested
    }
    return selectionAfterMouseDown
  }

  override func pressureChange(with event: NSEvent) {
    super.pressureChange(with: event)
    guard event.stage >= 2 else {
      isHandlingForceClick = false
      return
    }
    guard !isHandlingForceClick else { return }
    isHandlingForceClick = true
    guard let menu = menu(for: event) else { return }
    let point = convert(event.locationInWindow, from: nil)
    menu.popUp(positioning: nil, at: point, in: self)
  }

  private func drawCodeBlocks(
    in dirtyRect: NSRect,
    layoutManager: NSLayoutManager,
    textContainer: NSTextContainer
  ) {
    codeBlockCopyButtons.removeAll(keepingCapacity: true)
    let origin = textContainerOrigin
    for block in codeBlockDecorations where block.contentRange.length > 0 {
      let glyphRange = layoutManager.glyphRange(
        forCharacterRange: block.contentRange,
        actualCharacterRange: nil
      )
      var blockRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
      blockRect.origin.x = bounds.minX + textContainerInset.width + 18
      blockRect.origin.y += origin.y - 7
      blockRect.size.width = max(120, bounds.width - textContainerInset.width * 2 - 52)
      blockRect.size.height += 14
      guard blockRect.intersects(dirtyRect) else { continue }

      NSColor.textColor.withAlphaComponent(0.055).setFill()
      NSBezierPath(roundedRect: blockRect, xRadius: 7, yRadius: 7).fill()
      NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
      let border = NSBezierPath(roundedRect: blockRect, xRadius: 7, yRadius: 7)
      border.lineWidth = 1
      border.stroke()

      let copyTitle = "Copy"
      let copyAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
      let copySize = (copyTitle as NSString).size(withAttributes: copyAttributes)
      let copyRect = NSRect(
        x: blockRect.maxX - copySize.width - 17,
        y: blockRect.minY + 3,
        width: copySize.width + 10,
        height: copySize.height + 8
      )

      let label = block.language.isEmpty ? "CODE" : block.language.uppercased()
      let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
      let labelSize = (label as NSString).size(withAttributes: labelAttributes)
      let labelRect = NSRect(
        x: copyRect.minX - labelSize.width - 10,
        y: blockRect.minY + 7,
        width: labelSize.width,
        height: labelSize.height
      )
      (label as NSString).draw(in: labelRect, withAttributes: labelAttributes)

      NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
      NSBezierPath(roundedRect: copyRect, xRadius: 5, yRadius: 5).fill()
      (copyTitle as NSString).draw(
        at: NSPoint(x: copyRect.minX + 5, y: copyRect.minY + 4),
        withAttributes: copyAttributes
      )
      codeBlockCopyButtons.append((copyRect, block.code))
    }
  }

  private func drawMarkdownStructures(
    in dirtyRect: NSRect,
    layoutManager: NSLayoutManager,
    textContainer: NSTextContainer
  ) {
    let origin = textContainerOrigin
    NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
    for range in markdownBulletRanges {
      let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      guard glyphRange.length > 0 else { continue }
      let line = layoutManager.lineFragmentRect(
        forGlyphAt: glyphRange.location, effectiveRange: nil)
      let bullet = NSRect(
        x: origin.x + 4,
        y: line.midY + origin.y - 2.5,
        width: 5,
        height: 5
      )
      if bullet.intersects(dirtyRect) { NSBezierPath(ovalIn: bullet).fill() }
    }

    let ruleColor = NSColor.separatorColor.withAlphaComponent(0.62)
    let ruleGradient = NSGradient(colors: [
      ruleColor.withAlphaComponent(0),
      ruleColor,
      ruleColor,
      ruleColor.withAlphaComponent(0),
    ])
    for range in markdownRuleRanges {
      let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      guard glyphRange.length > 0 else { continue }
      let line = layoutManager.lineFragmentRect(
        forGlyphAt: glyphRange.location, effectiveRange: nil)
      let y = line.midY + origin.y
      let ruleRect = NSRect(
        x: origin.x + 12,
        y: y - 2,
        width: max(1, bounds.maxX - origin.x - textContainerInset.width - 36),
        height: 4
      )
      if ruleRect.intersects(dirtyRect) {
        ruleGradient?.draw(in: ruleRect, angle: 90)
      }
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    selectSymbol(at: event, preservingExistingSelection: true)
    // NSTextView's default-menu lookup synchronously waits on an AppKit default-QoS
    // worker when this method is entered from the interactive event thread. Keep the
    // standard edit commands on the responder chain without that blocking lookup.
    let menu = NSMenu(title: "Editor")
    menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Select All",
      action: #selector(NSText.selectAll(_:)),
      keyEquivalent: ""
    )

    let separator = NSMenuItem.separator()
    separator.tag = 91_004
    menu.addItem(separator)

    let definition = NSMenuItem(
      title: "Go to Definition",
      action: #selector(goToDefinitionFromMenu(_:)),
      keyEquivalent: ""
    )
    definition.target = self
    definition.tag = 91_001
    definition.image = NSImage(
      systemSymbolName: "arrow.turn.down.right", accessibilityDescription: nil)
    menu.addItem(definition)

    let references = NSMenuItem(
      title: "Find References",
      action: #selector(findReferencesFromMenu(_:)),
      keyEquivalent: ""
    )
    references.target = self
    references.tag = 91_002
    references.image = NSImage(
      systemSymbolName: "list.bullet.rectangle", accessibilityDescription: nil)
    menu.addItem(references)

    let quickHelp = NSMenuItem(
      title: "Quick Help",
      action: #selector(showQuickHelpFromMenu(_:)),
      keyEquivalent: ""
    )
    quickHelp.target = self
    quickHelp.tag = 91_003
    quickHelp.image = NSImage(
      systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
    menu.addItem(quickHelp)

    let snippets = NSMenuItem(title: "Insert Code Snippet", action: nil, keyEquivalent: "")
    snippets.tag = 91_005
    snippets.image = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: nil)
    let snippetMenu = NSMenu(title: "Insert Code Snippet")
    for snippet in contextualSnippets {
      let item = NSMenuItem(
        title: snippet.title, action: #selector(insertSnippetFromMenu(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = snippet.body
      snippetMenu.addItem(item)
    }
    snippets.submenu = snippetMenu
    menu.addItem(snippets)

    let documentation = NSMenuItem(
      title: "Insert Documentation Comment",
      action: #selector(insertDocumentationCommentFromMenu(_:)),
      keyEquivalent: ""
    )
    documentation.target = self
    documentation.tag = 91_006
    documentation.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
    menu.addItem(documentation)
    return menu
  }

  @objc private func goToDefinitionFromMenu(_ sender: Any?) {
    goToDefinitionHandler?()
  }

  @objc private func findReferencesFromMenu(_ sender: Any?) {
    findReferencesHandler?()
  }

  @objc private func showQuickHelpFromMenu(_ sender: Any?) {
    showQuickHelpHandler?()
  }

  @objc private func insertSnippetFromMenu(_ sender: NSMenuItem) {
    guard let snippet = sender.representedObject as? String else { return }
    insertText(snippet, replacementRange: selectedRange())
  }

  @objc private func insertDocumentationCommentFromMenu(_ sender: Any?) {
    insertText(documentationComment, replacementRange: selectedRange())
  }

  private var contextualSnippets: [(title: String, body: String)] {
    switch languageID.lowercased() {
    case "swift":
      return [
        ("Function", "func name(parameters) {\n\t\n}"),
        ("Structure", "struct Name {\n\t\n}"),
        ("Guard", "guard condition else {\n\treturn\n}"),
      ]
    case "python":
      return [
        ("Function", "def name(arguments):\n\tpass"),
        ("Class", "class Name:\n\tpass"),
        ("If statement", "if condition:\n\tpass"),
      ]
    case "html":
      return [("Element", "<element>content</element>"), ("Link", "<a href=\"\">text</a>")]
    default:
      return [
        ("Function", "function name(arguments) {\n\t\n}"),
        ("If statement", "if (condition) {\n\t\n}"),
        ("For loop", "for (const item of items) {\n\t\n}"),
      ]
    }
  }

  private var documentationComment: String {
    switch languageID.lowercased() {
    case "swift", "rust", "kotlin": return "/// "
    case "python", "shell": return "# "
    case "html", "xml": return "<!--  -->"
    default: return "/**\n * \n */"
    }
  }

  private func selectSymbol(
    at event: NSEvent,
    preservingExistingSelection: Bool = false
  ) {
    guard let offset = characterOffset(at: event) else { return }
    let currentSelection = selectedRange()
    if preservingExistingSelection,
      currentSelection.length > 0,
      NSLocationInRange(offset, currentSelection)
    {
      return
    }

    let source = string as NSString
    guard source.length > 0 else {
      setSelectedRange(NSRange(location: 0, length: 0))
      return
    }
    let clamped = min(max(offset, 0), source.length - 1)
    let symbolRange = source.editorIdentifierRange(containingUTF16Offset: clamped)
    setSelectedRange(
      symbolRange.length > 0
        ? symbolRange
        : NSRange(location: min(offset, source.length), length: 0)
    )
  }

  private func characterOffset(at event: NSEvent) -> Int? {
    guard let layoutManager, let textContainer else { return nil }
    let viewPoint = convert(event.locationInWindow, from: nil)
    let origin = textContainerOrigin
    let containerPoint = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
    guard layoutManager.numberOfGlyphs > 0 else { return 0 }
    let glyphIndex = layoutManager.glyphIndex(
      for: containerPoint,
      in: textContainer,
      fractionOfDistanceThroughGlyph: nil
    )
    if glyphIndex >= layoutManager.numberOfGlyphs { return (string as NSString).length }
    return layoutManager.characterIndexForGlyph(at: glyphIndex)
  }
}

extension NSString {
  fileprivate func editorIdentifierRange(containingUTF16Offset offset: Int) -> NSRange {
    guard offset >= 0, offset < length, editorIsIdentifierCharacter(at: offset) else {
      return NSRange(location: min(max(offset, 0), length), length: 0)
    }
    var lower = offset
    while lower > 0, editorIsIdentifierCharacter(at: lower - 1) { lower -= 1 }
    var upper = offset + 1
    while upper < length, editorIsIdentifierCharacter(at: upper) { upper += 1 }
    return NSRange(location: lower, length: upper - lower)
  }

  private func editorIsIdentifierCharacter(at offset: Int) -> Bool {
    let value = character(at: offset)
    if value == 95 || value == 36 { return true }
    guard let scalar = UnicodeScalar(value) else { return false }
    return CharacterSet.alphanumerics.contains(scalar)
  }
}

@MainActor
final class CodeTextScrollView: NSScrollView {
  var wrapsLines = false
  private var documentSizeSyncScheduled = false
  private var isSynchronizingDocumentSize = false

  override func tile() {
    super.tile()
    requestDocumentSizeSync()
  }

  func requestDocumentSizeSync() {
    guard !documentSizeSyncScheduled else { return }
    documentSizeSyncScheduled = true
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      self.documentSizeSyncScheduled = false
      self.synchronizeDocumentSize()
    }
  }

  func synchronizeDocumentSize() {
    guard !isSynchronizingDocumentSize else { return }
    guard window?.inLiveResize != true else {
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }
        self?.requestDocumentSizeSync()
      }
      return
    }
    guard let textView = documentView as? NSTextView,
      let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer
    else { return }

    isSynchronizingDocumentSize = true
    defer { isSynchronizingDocumentSize = false }

    let inset = textView.textContainerInset
    let viewport = contentSize
    if wrapsLines {
      textContainer.widthTracksTextView = true
      textContainer.containerSize = NSSize(
        width: max(viewport.width, 1),
        height: CGFloat.greatestFiniteMagnitude
      )
    }
    layoutManager.ensureLayout(for: textContainer)
    let used = layoutManager.usedRect(for: textContainer)
    let target = NSSize(
      width: wrapsLines
        ? max(viewport.width, 1) : max(viewport.width, ceil(used.maxX + inset.width * 2 + 12)),
      height: max(viewport.height, ceil(used.maxY + inset.height * 2 + 4))
    )
    guard target.width.isFinite, target.height.isFinite,
      target.width >= 0, target.height >= 0,
      abs(textView.frame.width - target.width) > 0.5
        || abs(textView.frame.height - target.height) > 0.5
    else { return }

    let previousOrigin = contentView.bounds.origin
    textView.setFrameSize(target)
    let maximumX = max(0, target.width - viewport.width)
    let maximumY = max(0, target.height - viewport.height)
    let restoredOrigin = NSPoint(
      x: target.width <= viewport.width + 0.5
        ? 0 : min(max(previousOrigin.x, 0), maximumX),
      y: min(max(previousOrigin.y, 0), maximumY)
    )
    if abs(contentView.bounds.origin.x - restoredOrigin.x) > 0.5
      || abs(contentView.bounds.origin.y - restoredOrigin.y) > 0.5
    {
      contentView.scroll(to: restoredOrigin)
      reflectScrolledClipView(contentView)
    }
    verticalRulerView?.needsDisplay = true
  }
}

@MainActor
struct EditorTextStyler {
  let profile: EditorCustomProfile
  let zoomScale: CGFloat

  func apply(
    to textView: NSTextView,
    languageID: String,
    liveMarkdownStyling: Bool,
    showsMarkdownSyntax: Bool,
    syntaxHighlights: [Highlight],
    semanticHighlights: [SemanticHighlight],
    diagnostics: [Diagnostic],
    showsInlineDiagnosticMessages: Bool,
    selectedRange: NSRange,
    affectedRange: NSRange? = nil
  ) {
    guard let storage = textView.textStorage,
      let layoutManager = textView.layoutManager
    else { return }

    let font = resolvedFont
    let paragraph = paragraphStyle(font: font)
    let presentationRange = normalizedPresentationRange(
      affectedRange,
      source: textView.string,
      storageLength: storage.length
    )
    let background = profile.surface.background.nsColor.withAlphaComponent(
      profile.surface.background.nsColor.alphaComponent
        * CGFloat(min(max(profile.surface.backgroundOpacity, 0), 1))
    )

    textView.drawsBackground = true
    textView.backgroundColor = background
    textView.textColor = profile.surface.foreground.nsColor
    if !(textView is CodeEditorTextView) {
      textView.insertionPointColor = profile.surface.cursor.nsColor
    }
    textView.selectedTextAttributes = [
      .backgroundColor: profile.surface.selection.nsColor,
      .foregroundColor: profile.surface.foreground.nsColor,
    ]
    textView.font = font
    textView.defaultParagraphStyle = paragraph
    textView.typingAttributes = [
      .font: font,
      .foregroundColor: profile.surface.foreground.nsColor,
      .paragraphStyle: paragraph,
    ]

    if presentationRange.length > 0 {
      storage.beginEditing()
      storage.setAttributes(
        [
          .font: font,
          .foregroundColor: profile.surface.foreground.nsColor,
          .paragraphStyle: paragraph,
        ],
        range: presentationRange
      )
      storage.endEditing()
      clearPresentationAttributes(from: layoutManager, range: presentationRange)
    }
    let snapshot = TextSnapshot(text: textView.string)
    let isLargeDocument = storage.length > editorRichPresentationUTF16Limit
    if let codeTextView = textView as? CodeEditorTextView {
      codeTextView.editorCursorStyle = profile.surface.cursorStyle
      codeTextView.editorCursorColor = profile.surface.cursor.nsColor
      codeTextView.geometryDiagnosticsEnabled = profile.behavior.showGeometryDiagnostics
      codeTextView.refreshInsertionPointRendering()
      codeTextView.errorLineRanges = errorLineRanges(
        in: textView.string,
        diagnostics: diagnostics,
        snapshot: snapshot,
        storageLength: storage.length
      )
      codeTextView.errorLineTint = profile.highlights.error.nsColor.withAlphaComponent(0.24)
      codeTextView.inlineDiagnosticMessages =
        showsInlineDiagnosticMessages && !isLargeDocument
        ? inlineDiagnosticMessages(
          in: textView.string,
          diagnostics: diagnostics,
          snapshot: snapshot,
          storageLength: storage.length
        )
        : []
      codeTextView.diagnosticColors = [
        .error: profile.highlights.error.nsColor,
        .warning: profile.highlights.warning.nsColor,
        .information: profile.highlights.information.nsColor,
        .hint: profile.highlights.hint.nsColor,
      ]
      codeTextView.diagnosticMessageTextColor = profile.surface.foreground.nsColor
    }
    let isLiveMarkdown =
      liveMarkdownStyling
      && !isLargeDocument
      && languageID.lowercased() == "markdown"
    if !isLiveMarkdown {
      applyCurrentLine(
        to: layoutManager,
        storageLength: storage.length,
        source: textView.string,
        selection: selectedRange
      )
      applyErrorLineHighlights(
        to: layoutManager,
        source: textView.string,
        diagnostics: diagnostics,
        snapshot: snapshot,
        storageLength: storage.length,
        limitingTo: presentationRange
      )
    }
    if let codeTextView = textView as? CodeEditorTextView {
      codeTextView.codeBlockDecorations = []
      codeTextView.markdownBulletRanges = []
      codeTextView.markdownRuleRanges = []
    }
    if !isLiveMarkdown {
      for highlight in syntaxHighlights {
        applyColor(
          color(forCapture: highlight.capture),
          range: highlight.range,
          snapshot: snapshot,
          layoutManager: layoutManager,
          storageLength: storage.length,
          limitingTo: presentationRange
        )
      }
      for highlight in semanticHighlights {
        applyColor(
          color(forToken: highlight.tokenType),
          range: highlight.range,
          snapshot: snapshot,
          layoutManager: layoutManager,
          storageLength: storage.length,
          limitingTo: presentationRange
        )
      }
    }
    if isLiveMarkdown {
      let codeBlocks = applyMarkdownStyles(
        to: storage,
        source: textView.string,
        baseFont: font,
        showsSyntax: showsMarkdownSyntax,
        selectedRange: selectedRange
      )
      if let codeTextView = textView as? CodeEditorTextView {
        codeTextView.codeBlockDecorations = codeBlocks
        codeTextView.markdownBulletRanges =
          showsMarkdownSyntax
          ? [] : markdownBulletRanges(in: textView.string)
        codeTextView.markdownRuleRanges = markdownRuleRanges(in: textView.string)
      }
    }
    for diagnostic in diagnostics {
      applyDiagnostic(
        diagnostic,
        snapshot: snapshot,
        layoutManager: layoutManager,
        storageLength: storage.length,
        limitingTo: presentationRange
      )
    }
    layoutManager.invalidateDisplay(forCharacterRange: presentationRange)
    textView.needsDisplay = true
    // Rich Markdown styling changes glyph metrics after the caret was first
    // configured above. Recompute from the final TextKit layout so the caret
    // follows headings and collapsed source markers instead of the old frame.
    (textView as? CodeEditorTextView)?.refreshInsertionPointRendering()
  }

  private func normalizedPresentationRange(
    _ requested: NSRange?,
    source: String,
    storageLength: Int
  ) -> NSRange {
    guard storageLength > 0, let requested else {
      return NSRange(location: 0, length: storageLength)
    }
    let text = source as NSString
    let location = min(max(requested.location, 0), storageLength - 1)
    let available = storageLength - location
    let length = min(max(requested.length, 1), available)
    let lineRange = text.lineRange(for: NSRange(location: location, length: length))
    return NSRange(
      location: min(max(lineRange.location, 0), storageLength),
      length: min(
        max(lineRange.length, 0), storageLength - min(max(lineRange.location, 0), storageLength))
    )
  }

  func updateSelection(
    in textView: NSTextView,
    languageID: String,
    liveMarkdownStyling: Bool,
    showsMarkdownSyntax: Bool,
    previousSelection: NSRange?,
    currentSelection: NSRange
  ) {
    guard let storage = textView.textStorage, let layoutManager = textView.layoutManager,
      storage.length > 0
    else { return }
    let isLiveMarkdown = liveMarkdownStyling && languageID.lowercased() == "markdown"
    if isLiveMarkdown {
      // Hidden Markdown markers are handled by a full restyle only when the active line changes.
      // Moving within the same line does not change presentation at all.
      return
    }

    let source = textView.string as NSString
    func lineRange(for selection: NSRange?) -> NSRange? {
      guard let selection else { return nil }
      let location = min(max(selection.location, 0), storage.length)
      let range = source.lineRange(for: NSRange(location: location, length: 0))
      return NSMaxRange(range) <= storage.length ? range : nil
    }

    let previousLine = lineRange(for: previousSelection)
    let currentLine = lineRange(for: currentSelection)
    guard previousLine != currentLine else { return }
    let affected: NSRange
    switch (previousLine, currentLine) {
    case (let old?, let new?): affected = NSUnionRange(old, new)
    case (let old?, nil): affected = old
    case (nil, let new?): affected = new
    case (nil, nil): return
    }

    layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: affected)
    if let codeTextView = textView as? CodeEditorTextView {
      for errorRange in codeTextView.errorLineRanges
      where NSIntersectionRange(errorRange, affected).length > 0 {
        layoutManager.addTemporaryAttribute(
          .backgroundColor,
          value: codeTextView.errorLineTint,
          forCharacterRange: errorRange
        )
      }
    }
    applyCurrentLine(
      to: layoutManager,
      storageLength: storage.length,
      source: textView.string,
      selection: currentSelection
    )
    layoutManager.invalidateDisplay(forCharacterRange: affected)
    textView.needsDisplay = true
  }

  private func applyMarkdownStyles(
    to storage: NSTextStorage,
    source: String,
    baseFont: NSFont,
    showsSyntax: Bool,
    selectedRange: NSRange
  ) -> [MarkdownCodeBlockDecoration] {
    let fullRange = NSRange(location: 0, length: storage.length)
    guard fullRange.length > 0 else { return [] }
    let muted = profile.surface.foreground.nsColor.withAlphaComponent(0.45)
    let syntaxColor = profile.syntax.symbols.punctuation.nsColor
    let accent = profile.syntax.literals.keyword.nsColor
    let codeBackground = profile.surface.foreground.nsColor.withAlphaComponent(0.08)

    func matches(_ pattern: String, options: NSRegularExpression.Options = [])
      -> [NSTextCheckingResult]
    {
      (try? NSRegularExpression(pattern: pattern, options: options))?
        .matches(in: source, range: fullRange) ?? []
    }
    func add(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
      guard range.location != NSNotFound, NSMaxRange(range) <= storage.length else { return }
      storage.addAttributes(attributes, range: range)
    }
    func font(size: CGFloat, traits: NSFontTraitMask) -> NSFont {
      let seed = NSFont.systemFont(ofSize: size)
      return NSFontManager.shared.convert(seed, toHaveTrait: traits)
    }

    storage.beginEditing()
    var codeBlocks: [MarkdownCodeBlockDecoration] = []

    for result in matches("^(#{1,6})[\\t ]+(.+?)[\\t ]*#*$", options: .anchorsMatchLines) {
      let level = result.range(at: 1).length
      let sizes: [CGFloat] = [2.0, 1.65, 1.38, 1.18, 1.05, 1.0]
      add([.foregroundColor: syntaxColor], range: result.range(at: 1))
      add(
        [.font: font(size: baseFont.pointSize * sizes[level - 1], traits: .boldFontMask)],
        range: result.range(at: 2)
      )
    }

    for result in matches("^(.*)\\n(=+|-+)[\\t ]*$", options: .anchorsMatchLines) {
      let headingRange = result.range(at: 1)
      guard headingRange.length > 0 else { continue }
      let level =
        (source as NSString).substring(with: result.range(at: 2)).first == "=" ? 2.0 : 1.65
      add(
        [.font: font(size: baseFont.pointSize * level, traits: .boldFontMask)], range: headingRange)
      add([.foregroundColor: syntaxColor], range: result.range(at: 2))
    }

    for result in matches("\\*\\*(.+?)\\*\\*|__(.+?)__") {
      let content =
        result.range(at: 1).location != NSNotFound ? result.range(at: 1) : result.range(at: 2)
      add([.font: font(size: baseFont.pointSize, traits: .boldFontMask)], range: content)
      add(
        [.foregroundColor: syntaxColor],
        range: NSRange(
          location: result.range.location, length: content.location - result.range.location))
      add(
        [.foregroundColor: syntaxColor],
        range: NSRange(
          location: NSMaxRange(content), length: NSMaxRange(result.range) - NSMaxRange(content)))
    }
    for result in matches("(?<![*_])(?:\\*([^*\\n]+)\\*|_([^_\\n]+)_)(?![*_])") {
      let content =
        result.range(at: 1).location != NSNotFound ? result.range(at: 1) : result.range(at: 2)
      add([.font: font(size: baseFont.pointSize, traits: .italicFontMask)], range: content)
      add(
        [.foregroundColor: syntaxColor],
        range: NSRange(
          location: result.range.location, length: content.location - result.range.location))
      add(
        [.foregroundColor: syntaxColor],
        range: NSRange(
          location: NSMaxRange(content), length: NSMaxRange(result.range) - NSMaxRange(content)))
    }
    for result in matches("~~(.+?)~~") {
      add([.strikethroughStyle: NSUnderlineStyle.single.rawValue], range: result.range(at: 1))
      add(
        [.foregroundColor: syntaxColor], range: NSRange(location: result.range.location, length: 2))
      add(
        [.foregroundColor: syntaxColor],
        range: NSRange(location: NSMaxRange(result.range) - 2, length: 2))
    }
    for result in matches("(?<!`)`([^`\\n]+)`(?!`)") {
      add(
        [
          .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.95, weight: .regular),
          .backgroundColor: codeBackground,
        ],
        range: result.range(at: 1)
      )
      add(
        [.foregroundColor: syntaxColor], range: NSRange(location: result.range.location, length: 1))
      add(
        [.foregroundColor: syntaxColor],
        range: NSRange(location: NSMaxRange(result.range) - 1, length: 1))
    }
    for result in matches("^```([^\\n]*)\\n([\\s\\S]*?)^```[\\t ]*$", options: .anchorsMatchLines) {
      let language = (source as NSString).substring(with: result.range(at: 1))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let contentRange = result.range(at: 2)
      let code = (source as NSString).substring(with: contentRange)
        .trimmingCharacters(in: .newlines)
      codeBlocks.append(
        MarkdownCodeBlockDecoration(
          contentRange: contentRange,
          language: language,
          code: code
        )
      )
      let codeParagraph = paragraphStyle(font: baseFont).mutableCopy() as! NSMutableParagraphStyle
      codeParagraph.firstLineHeadIndent = 28
      codeParagraph.headIndent = 28
      add(
        [
          .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.95, weight: .regular),
          .paragraphStyle: codeParagraph,
        ],
        range: contentRange
      )
      applyCodeSyntaxHighlighting(
        to: storage,
        source: source,
        range: contentRange,
        language: language
      )
      let opening = NSRange(
        location: result.range.location, length: contentRange.location - result.range.location)
      add([.foregroundColor: syntaxColor], range: opening)
      add(
        [.foregroundColor: syntaxColor],
        range: NSRange(
          location: NSMaxRange(contentRange),
          length: NSMaxRange(result.range) - NSMaxRange(contentRange)))
    }
    for result in matches("!?\\[([^]\\n]*)\\]\\(([^)\\n]+)\\)") {
      add(
        [.foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue],
        range: result.range(at: 1))
      add(
        [.foregroundColor: syntaxColor],
        range: NSRange(
          location: result.range.location,
          length: result.range(at: 1).location - result.range.location))
      add(
        [.foregroundColor: syntaxColor],
        range: NSRange(
          location: NSMaxRange(result.range(at: 1)),
          length: NSMaxRange(result.range) - NSMaxRange(result.range(at: 1))))
    }
    for result in matches(
      "^[\\t ]*(>+|[-+*]|\\d+\\.|- \\[[ xX]\\])[\\t ]+", options: .anchorsMatchLines)
    {
      add(
        [.foregroundColor: accent, .font: font(size: baseFont.pointSize, traits: .boldFontMask)],
        range: result.range(at: 1))
    }
    if !showsSyntax {
      for result in matches("^[\\t ]*[-+*][\\t ]+.*$", options: .anchorsMatchLines) {
        let listParagraph = paragraphStyle(font: baseFont).mutableCopy() as! NSMutableParagraphStyle
        listParagraph.firstLineHeadIndent = 18
        listParagraph.headIndent = 18
        add([.paragraphStyle: listParagraph], range: result.range)
      }
    }
    for result in matches("^[\\t ]*((?:[-*_][\\t ]*){3,})$", options: .anchorsMatchLines) {
      add(
        [.foregroundColor: syntaxColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue],
        range: result.range(at: 1))
    }
    let tableLineResults = matches("^.*\\|.*$", options: .anchorsMatchLines)
    let tableSeparatorPattern =
      "^[\\t ]*\\|?[\\t ]*:?-{3,}:?[\\t ]*(?:\\|[\\t ]*:?-{3,}:?[\\t ]*)+\\|?[\\t ]*$"
    let tableSeparators = matches(tableSeparatorPattern, options: .anchorsMatchLines)
    let separatorLocations = Set(tableSeparators.map { $0.range.location })
    let sourceTextForTables = source as NSString
    for (index, result) in tableLineResults.enumerated() {
      let isSeparator = separatorLocations.contains(result.range.location)
      let nextIsSeparator =
        index + 1 < tableLineResults.count
        && separatorLocations.contains(tableLineResults[index + 1].range.location)
        && NSMaxRange(sourceTextForTables.lineRange(for: result.range))
          == tableLineResults[index + 1].range.location
      var attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(
          ofSize: baseFont.pointSize * 0.96,
          weight: nextIsSeparator ? .semibold : .regular
        )
      ]
      if nextIsSeparator {
        attributes[.backgroundColor] = profile.surface.foreground.nsColor.withAlphaComponent(0.07)
      } else if isSeparator {
        attributes[.foregroundColor] = muted
        attributes[.backgroundColor] = profile.surface.foreground.nsColor.withAlphaComponent(0.035)
      }
      add(attributes, range: result.range)

      if let pipeExpression = try? NSRegularExpression(pattern: "\\|") {
        for pipe in pipeExpression.matches(in: source, range: result.range) {
          add([.foregroundColor: syntaxColor], range: pipe.range)
        }
      }
      if isSeparator {
        for marker in matches("[:\\-]+")
        where NSLocationInRange(marker.range.location, result.range) {
          add([.foregroundColor: syntaxColor], range: marker.range)
        }
      }
    }

    if !showsSyntax {
      let collapsedFont = NSFont.systemFont(ofSize: 0.1)
      let sourceText = source as NSString
      let cursorLocation = min(max(selectedRange.location, 0), sourceText.length)
      let activeLineRange = sourceText.lineRange(
        for: NSRange(location: cursorLocation, length: 0)
      )
      func collapse(_ range: NSRange) {
        guard NSIntersectionRange(range, activeLineRange).length == 0 else { return }
        add([.foregroundColor: NSColor.clear, .font: collapsedFont, .kern: -0.1], range: range)
      }
      func collapseOutside(_ result: NSTextCheckingResult, content: NSRange) {
        collapse(
          NSRange(location: result.range.location, length: content.location - result.range.location)
        )
        collapse(
          NSRange(
            location: NSMaxRange(content), length: NSMaxRange(result.range) - NSMaxRange(content)))
      }

      for result in matches("^(#{1,6})[\\t ]+", options: .anchorsMatchLines) {
        collapse(result.range)
      }
      for result in matches("^(.*)\\n(=+|-+)[\\t ]*$", options: .anchorsMatchLines) {
        collapse(result.range(at: 2))
      }
      for result in matches("\\*\\*(.+?)\\*\\*|__(.+?)__") {
        let content =
          result.range(at: 1).location != NSNotFound ? result.range(at: 1) : result.range(at: 2)
        collapseOutside(result, content: content)
      }
      for result in matches("(?<![*_])(?:\\*([^*\\n]+)\\*|_([^_\\n]+)_)(?![*_])") {
        let content =
          result.range(at: 1).location != NSNotFound ? result.range(at: 1) : result.range(at: 2)
        collapseOutside(result, content: content)
      }
      for result in matches("~~(.+?)~~|(?<!`)`([^`\\n]+)`(?!`)") {
        let content =
          result.range(at: 1).location != NSNotFound ? result.range(at: 1) : result.range(at: 2)
        collapseOutside(result, content: content)
      }
      for result in matches("^```([^\\n]*)\\n([\\s\\S]*?)^```[\\t ]*$", options: .anchorsMatchLines)
      {
        collapseOutside(result, content: result.range(at: 2))
      }
      for result in matches("!?\\[([^]\\n]*)\\]\\(([^)\\n]+)\\)") {
        collapseOutside(result, content: result.range(at: 1))
      }
      for result in matches(
        "^[\\t ]*(>+|[-+*]|\\d+\\.|- \\[[ xX]\\])[\\t ]+", options: .anchorsMatchLines)
      {
        collapse(result.range)
      }
      for result in matches("^[\\t ]*((?:[-*_][\\t ]*){3,})$", options: .anchorsMatchLines) {
        collapse(result.range)
      }
    }

    storage.endEditing()
    return codeBlocks
  }

  private func applyCodeSyntaxHighlighting(
    to storage: NSTextStorage,
    source: String,
    range: NSRange,
    language: String
  ) {
    guard range.length > 0 else { return }
    let normalizedLanguage =
      language.lowercased().split(separator: " ").first.map(String.init) ?? ""
    let keywords: [String]
    switch normalizedLanguage {
    case "swift":
      keywords = [
        "actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default",
        "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import",
        "in", "init", "let", "nil", "private", "protocol", "public", "repeat", "return", "self",
        "static", "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while",
      ]
    case "js", "javascript", "jsx", "ts", "typescript", "tsx":
      keywords = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
        "delete", "else", "export", "extends", "false", "finally", "for", "from", "function", "if",
        "import", "in", "instanceof", "let", "new", "null", "of", "return", "static", "super",
        "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "while", "yield",
      ]
    case "py", "python":
      keywords = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
        "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is",
        "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try",
        "while", "with", "yield",
      ]
    case "sh", "bash", "shell", "zsh":
      keywords = [
        "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in",
        "local", "return", "then", "while",
      ]
    case "c", "cpp", "c++", "objc", "objective-c", "java", "kotlin":
      keywords = [
        "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default",
        "do", "double", "else", "enum", "false", "final", "float", "for", "if", "import", "int",
        "interface", "long", "new", "null", "package", "private", "protected", "public", "return",
        "short", "static", "struct", "switch", "this", "throw", "true", "try", "void", "while",
      ]
    case "rs", "rust":
      keywords = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
        "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
        "mut", "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true", "type",
        "unsafe", "use", "where", "while",
      ]
    default:
      keywords = []
    }

    func color(_ value: EditorRGBAColor) -> NSColor { value.nsColor }
    func highlight(
      _ pattern: String, with value: NSColor, options: NSRegularExpression.Options = []
    ) {
      guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
        return
      }
      for match in expression.matches(in: source, range: range) {
        storage.addAttribute(.foregroundColor, value: value, range: match.range)
      }
    }

    if !keywords.isEmpty {
      let escaped = keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
      highlight("\\b(?:\(escaped))\\b", with: color(profile.syntax.literals.keyword))
    }
    highlight(
      "\\b(?:0x[0-9A-Fa-f]+|\\d+(?:\\.\\d+)?)\\b", with: color(profile.syntax.literals.number))
    highlight(
      "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'", with: color(profile.syntax.literals.string))
    if normalizedLanguage == "py" || normalizedLanguage == "python"
      || ["sh", "bash", "shell", "zsh"].contains(normalizedLanguage)
    {
      highlight("#.*$", with: color(profile.syntax.literals.comment), options: .anchorsMatchLines)
    } else {
      highlight(
        "//.*$|/\\*[\\s\\S]*?\\*/", with: color(profile.syntax.literals.comment),
        options: .anchorsMatchLines)
    }
  }

  private func markdownBulletRanges(in source: String) -> [NSRange] {
    let fullRange = NSRange(location: 0, length: (source as NSString).length)
    guard
      let expression = try? NSRegularExpression(
        pattern: "^[\\t ]*[-+*][\\t ]+.+$",
        options: .anchorsMatchLines
      )
    else { return [] }
    return expression.matches(in: source, range: fullRange).map(\.range)
  }

  private func markdownRuleRanges(in source: String) -> [NSRange] {
    let fullRange = NSRange(location: 0, length: (source as NSString).length)
    guard
      let expression = try? NSRegularExpression(
        pattern: "^[\\t ]*(?:---+|___+|\\*\\*\\*+)[\\t ]*$",
        options: .anchorsMatchLines
      )
    else { return [] }
    return expression.matches(in: source, range: fullRange).map(\.range)
  }

  private var resolvedFont: NSFont {
    let size = profile.font.size * zoomScale
    return NSFont(name: profile.font.family, size: size)
      ?? NSFont.monospacedSystemFont(
        ofSize: size, weight: profile.font.weight.nsWeight)
  }

  private func paragraphStyle(font: NSFont) -> NSParagraphStyle {
    let value = NSMutableParagraphStyle()
    value.lineSpacing = profile.font.lineSpacing
    value.defaultTabInterval =
      max(1, font.maximumAdvancement.width) * CGFloat(max(1, profile.behavior.tabWidth))
    return value
  }

  private func clearPresentationAttributes(from layoutManager: NSLayoutManager, range: NSRange) {
    guard range.length > 0 else { return }
    for attribute in [
      NSAttributedString.Key.foregroundColor,
      .backgroundColor,
      .underlineStyle,
      .underlineColor,
      .toolTip,
    ] {
      layoutManager.removeTemporaryAttribute(attribute, forCharacterRange: range)
    }
  }

  private func applyCurrentLine(
    to layoutManager: NSLayoutManager,
    storageLength: Int,
    source: String,
    selection: NSRange
  ) {
    guard storageLength > 0 else { return }
    let safeLocation = min(max(selection.location, 0), storageLength)
    let lineRange = (source as NSString).lineRange(
      for: NSRange(location: safeLocation, length: 0)
    )
    guard NSMaxRange(lineRange) <= storageLength else { return }
    layoutManager.addTemporaryAttribute(
      .backgroundColor,
      value: profile.highlights.currentLine.nsColor,
      forCharacterRange: lineRange
    )
  }

  private func applyColor(
    _ color: NSColor,
    range: EditorTextRange,
    snapshot: TextSnapshot,
    layoutManager: NSLayoutManager,
    storageLength: Int,
    limitingTo limit: NSRange
  ) {
    guard let value = try? snapshot.nsRange(for: range),
      value.length > 0,
      NSMaxRange(value) <= storageLength,
      NSIntersectionRange(value, limit).length > 0
    else { return }
    layoutManager.addTemporaryAttribute(
      .foregroundColor,
      value: color,
      forCharacterRange: value
    )
  }

  private func applyErrorLineHighlights(
    to layoutManager: NSLayoutManager,
    source: String,
    diagnostics: [Diagnostic],
    snapshot: TextSnapshot,
    storageLength: Int,
    limitingTo limit: NSRange
  ) {
    let color = profile.highlights.error.nsColor.withAlphaComponent(0.18)
    for lineRange in errorLineRanges(
      in: source,
      diagnostics: diagnostics,
      snapshot: snapshot,
      storageLength: storageLength
    ) where NSIntersectionRange(lineRange, limit).length > 0 {
      layoutManager.addTemporaryAttribute(
        .backgroundColor,
        value: color,
        forCharacterRange: lineRange
      )
    }
  }

  private func applyDiagnostic(
    _ diagnostic: Diagnostic,
    snapshot: TextSnapshot,
    layoutManager: NSLayoutManager,
    storageLength: Int,
    limitingTo limit: NSRange
  ) {
    guard let rawRange = try? snapshot.nsRange(for: diagnostic.range),
      let value = visibleDiagnosticRange(rawRange, storageLength: storageLength),
      NSIntersectionRange(value, limit).length > 0
    else { return }
    let color: NSColor
    switch diagnostic.severity {
    case .error: color = profile.highlights.error.nsColor
    case .warning: color = profile.highlights.warning.nsColor
    case .information: color = profile.highlights.information.nsColor
    case .hint: color = profile.highlights.hint.nsColor
    }
    let attributes: [NSAttributedString.Key: Any] = [
      .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
      .underlineColor: color,
      .toolTip: diagnostic.message,
    ]
    layoutManager.addTemporaryAttributes(
      attributes,
      forCharacterRange: value
    )
  }

  private func errorLineRanges(
    in source: String,
    diagnostics: [Diagnostic],
    snapshot: TextSnapshot,
    storageLength: Int
  ) -> [NSRange] {
    let source = source as NSString
    return diagnostics.compactMap { diagnostic in
      guard diagnostic.severity == .error,
        let rawRange = try? snapshot.nsRange(for: diagnostic.range),
        rawRange.location >= 0,
        rawRange.location <= storageLength
      else { return nil }

      let safeRange = NSRange(
        location: rawRange.location,
        length: min(rawRange.length, storageLength - rawRange.location)
      )
      let lineRange = source.lineRange(for: safeRange)
      guard lineRange.length > 0, NSMaxRange(lineRange) <= storageLength else { return nil }
      return lineRange
    }
  }

  private func inlineDiagnosticMessages(
    in source: String,
    diagnostics: [Diagnostic],
    snapshot: TextSnapshot,
    storageLength: Int
  ) -> [InlineDiagnosticMessage] {
    let source = source as NSString
    var messages: [Int: InlineDiagnosticMessage] = [:]
    for diagnostic in diagnostics {
      guard let rawRange = try? snapshot.nsRange(for: diagnostic.range),
        rawRange.location >= 0,
        rawRange.location <= storageLength
      else { continue }
      let lineRange = source.lineRange(for: NSRange(location: rawRange.location, length: 0))
      guard lineRange.length > 0, NSMaxRange(lineRange) <= storageLength else { continue }
      let value = InlineDiagnosticMessage(
        lineRange: lineRange,
        message: diagnostic.message,
        severity: diagnostic.severity
      )
      if let existing = messages[lineRange.location],
        existing.severity.rawValue <= diagnostic.severity.rawValue
      {
        continue
      }
      messages[lineRange.location] = value
    }
    return messages.values.sorted { $0.lineRange.location < $1.lineRange.location }
  }

  private func visibleDiagnosticRange(_ range: NSRange, storageLength: Int) -> NSRange? {
    guard range.location >= 0, range.location <= storageLength else { return nil }
    if range.length > 0 {
      guard NSMaxRange(range) <= storageLength else { return nil }
      return range
    }
    guard storageLength > 0 else { return nil }
    let location = min(range.location, storageLength - 1)
    return NSRange(location: location, length: 1)
  }

  private func color(forCapture capture: String) -> NSColor {
    let value = capture.lowercased()
    if value.contains("comment") { return profile.syntax.literals.comment.nsColor }
    if value.contains("string") || value.contains("character") {
      return profile.syntax.literals.string.nsColor
    }
    if value.contains("number") || value.contains("float") || value.contains("integer") {
      return profile.syntax.literals.number.nsColor
    }
    if value.contains("keyword") || value.contains("conditional") || value.contains("repeat") {
      return profile.syntax.literals.keyword.nsColor
    }
    if value.contains("attribute") || value.contains("directive") || value.contains("preproc") {
      return profile.syntax.literals.directive.nsColor
    }
    if value.contains("type") || value.contains("class") || value.contains("struct")
      || value.contains("enum") || value.contains("namespace")
    {
      return profile.syntax.symbols.type.nsColor
    }
    if value.contains("function") || value.contains("method") || value.contains("constructor") {
      return profile.syntax.symbols.function.nsColor
    }
    if value.contains("property") || value.contains("field") {
      return profile.syntax.symbols.property.nsColor
    }
    if value.contains("operator") { return profile.syntax.symbols.operator.nsColor }
    if value.contains("punctuation") || value.contains("delimiter") {
      return profile.syntax.symbols.punctuation.nsColor
    }
    return profile.syntax.symbols.variable.nsColor
  }

  private func color(forToken token: String) -> NSColor {
    switch token.lowercased() {
    case "namespace", "type", "class", "enum", "interface", "struct", "typeparameter":
      return profile.syntax.symbols.type.nsColor
    case "function", "method", "macro":
      return profile.syntax.symbols.function.nsColor
    case "property", "enummember":
      return profile.syntax.symbols.property.nsColor
    case "keyword", "modifier":
      return profile.syntax.literals.keyword.nsColor
    case "comment":
      return profile.syntax.literals.comment.nsColor
    case "string":
      return profile.syntax.literals.string.nsColor
    case "number":
      return profile.syntax.literals.number.nsColor
    case "operator":
      return profile.syntax.symbols.operator.nsColor
    default:
      return profile.syntax.symbols.variable.nsColor
    }
  }
}
