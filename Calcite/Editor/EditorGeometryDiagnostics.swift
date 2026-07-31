import AppKit
import Foundation

@MainActor
struct EditorGeometrySnapshot: Equatable, CustomStringConvertible {
  let textViewFrame: NSRect
  let textViewBounds: NSRect
  let clipViewBounds: NSRect?
  let visibleRect: NSRect
  let textContainerOrigin: NSPoint
  let textContainerInset: NSSize
  let selectedRange: NSRange
  let vimCursorLocation: Int?
  let cursorStyle: EditorCursorStyle
  let glyphIndex: Int?
  let glyphRect: NSRect?
  let cursorRect: NSRect?
  let horizontalOrigin: CGFloat

  var description: String {
    let selected = "\(selectedRange.location)..<\(NSMaxRange(selectedRange))"
    let vim = vimCursorLocation.map(String.init) ?? "native"
    let glyph = glyphIndex.map(String.init) ?? "none"
    let glyphGeometry = glyphRect.map(Self.describe) ?? "none"
    let cursorGeometry = cursorRect.map(Self.describe) ?? "none"
    return [
      "Selection: \(selected)",
      "Vim cursor: \(vim)",
      "Style: \(cursorStyle.rawValue)",
      "Glyph: \(glyph) \(glyphGeometry)",
      "Cursor: \(cursorGeometry)",
      "Visible: \(Self.describe(visibleRect))",
      "Clip: \(clipViewBounds.map(Self.describe) ?? "none")",
      "Text origin: \(Self.describe(textContainerOrigin))",
      "Text inset: \(Int(textContainerInset.width)) × \(Int(textContainerInset.height))",
      "Horizontal origin: \(String(format: "%.2f", horizontalOrigin))",
    ].joined(separator: "\n")
  }

  private static func describe(_ rect: NSRect) -> String {
    String(
      format: "(%.1f, %.1f) %.1f × %.1f",
      rect.origin.x,
      rect.origin.y,
      rect.size.width,
      rect.size.height
    )
  }

  private static func describe(_ point: NSPoint) -> String {
    String(format: "(%.1f, %.1f)", point.x, point.y)
  }
}

@MainActor
private final class EditorGeometryDiagnosticsHUD: NSView {
  var text = "" {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    NSColor.separatorColor.setStroke()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()
    (text as NSString).draw(
      in: bounds.insetBy(dx: 8, dy: 6),
      withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor.labelColor,
      ]
    )
  }
}

@MainActor
extension CodeEditorTextView {
  var geometryDiagnosticsEnabled: Bool {
    get { geometryDiagnosticsHUD != nil }
    set {
      if newValue {
        installGeometryDiagnosticsHUDIfNeeded()
        refreshGeometryDiagnostics()
      } else {
        geometryDiagnosticsHUD?.removeFromSuperview()
      }
    }
  }

  func geometrySnapshot() -> EditorGeometrySnapshot {
    let sourceLength = (string as NSString).length
    let location = min(max(vimCursorLocation ?? selectedRange().location, 0), sourceLength)
    let glyphIndex: Int?
    let glyphRect: NSRect?
    if let layoutManager, let textContainer, sourceLength > 0 {
      let character = min(location, sourceLength - 1)
      let glyph = layoutManager.glyphIndexForCharacter(at: character)
      glyphIndex = glyph
      let raw = layoutManager.boundingRect(
        forGlyphRange: NSRange(location: glyph, length: 1),
        in: textContainer
      )
      glyphRect = raw.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    } else {
      glyphIndex = nil
      glyphRect = nil
    }
    return EditorGeometrySnapshot(
      textViewFrame: frame,
      textViewBounds: bounds,
      clipViewBounds: enclosingScrollView?.contentView.bounds,
      visibleRect: visibleRect,
      textContainerOrigin: textContainerOrigin,
      textContainerInset: textContainerInset,
      selectedRange: selectedRange(),
      vimCursorLocation: vimCursorLocation,
      cursorStyle: vimCursorStyle ?? editorCursorStyle,
      glyphIndex: glyphIndex,
      glyphRect: glyphRect,
      cursorRect: customInsertionPointRect(),
      horizontalOrigin: enclosingScrollView?.contentView.bounds.origin.x ?? bounds.origin.x
    )
  }

  func refreshGeometryDiagnostics() {
    guard let hud = geometryDiagnosticsHUD else { return }
    hud.text = geometrySnapshot().description
    let width: CGFloat = min(max(280, bounds.width * 0.38), 430)
    let height: CGFloat = 158
    hud.frame = NSRect(
      x: max(8, visibleRect.maxX - width - 10),
      y: visibleRect.minY + 10,
      width: width,
      height: height
    )
    hud.layer?.zPosition = 20_000
  }

  private var geometryDiagnosticsHUD: EditorGeometryDiagnosticsHUD? {
    subviews.first(where: { $0 is EditorGeometryDiagnosticsHUD }) as? EditorGeometryDiagnosticsHUD
  }

  private func installGeometryDiagnosticsHUDIfNeeded() {
    guard geometryDiagnosticsHUD == nil else { return }
    let hud = EditorGeometryDiagnosticsHUD(frame: .zero)
    hud.wantsLayer = true
    addSubview(hud, positioned: .above, relativeTo: nil)
  }
}
