import AppKit
@_spi(Calcite) import EditorVim
import Foundation

/// TextKit-backed visual geometry for Vim motions and Visual Block projection.
/// Values are encoded in 1/64-point units so the cross-platform engine can
/// retain an integer preferred column without depending on CoreGraphics.
final class CalciteVimGeometryProvider: @unchecked Sendable, VimVisualGeometryProviding {
  private static let scale: CGFloat = 64
  weak var textView: NSTextView?

  func visualColumn(
    atUTF16Offset offset: Int,
    logicalLineStart: Int,
    text: String
  ) -> Int? {
    guard let textView = validTextView(for: text),
      let caret = layoutRect(at: offset, in: textView)
    else { return nil }
    _ = logicalLineStart
    return max(0, Int((caret.minX * Self.scale).rounded()))
  }

  func utf16Offset(
    inLogicalLineStartingAt lineStart: Int,
    atVisualColumn column: Int,
    contentEnd: Int,
    text: String,
    roundForward: Bool
  ) -> Int? {
    guard let textView = validTextView(for: text),
      let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer,
      let startRect = layoutRect(at: lineStart, in: textView)
    else { return nil }

    let targetX = CGFloat(max(0, column)) / Self.scale
    let target = NSPoint(x: targetX, y: startRect.midY)
    var fraction: CGFloat = 0
    let glyph = layoutManager.glyphIndex(
      for: target,
      in: textContainer,
      fractionOfDistanceThroughGlyph: &fraction
    )
    var character = layoutManager.characterIndexForGlyph(at: glyph)
    if roundForward, fraction >= 0.5, character < contentEnd {
      character = nextBoundary(after: character, in: text)
    }
    return min(max(lineStart, character), contentEnd)
  }

  func visualWidth(
    atUTF16Offset offset: Int,
    logicalLineStart _: Int,
    text: String
  ) -> Int? {
    guard let textView = validTextView(for: text),
      let rect = layoutRect(at: offset, in: textView)
    else { return nil }
    let fallback = textView.font?.maximumAdvancement.width ?? 1
    return max(1, Int((max(rect.width, fallback) * Self.scale).rounded()))
  }

  func moveVertically(
    fromUTF16Offset offset: Int,
    direction: Int,
    preferredColumn: Int?,
    text: String
  ) -> VimVisualMovement? {
    guard direction != 0,
      let textView = validTextView(for: text),
      let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer,
      let currentLine = visualLineFragment(at: offset, in: textView)
    else { return nil }

    let logicalStart = logicalLineStart(at: offset, in: text)
    let currentColumn =
      preferredColumn
      ?? visualColumn(atUTF16Offset: offset, logicalLineStart: logicalStart, text: text)
      ?? 0
    _ = logicalStart
    let targetX = CGFloat(max(0, currentColumn)) / Self.scale
    let targetY =
      direction < 0
      ? currentLine.minY - max(1, currentLine.height) * 0.5
      : currentLine.maxY + max(1, currentLine.height) * 0.5
    let target = NSPoint(x: targetX, y: targetY)
    let usedRect = layoutManager.usedRect(for: textContainer)
    guard usedRect.insetBy(dx: -2, dy: -2).contains(target) else { return nil }

    var fraction: CGFloat = 0
    let glyph = layoutManager.glyphIndex(
      for: target,
      in: textContainer,
      fractionOfDistanceThroughGlyph: &fraction
    )
    var character = layoutManager.characterIndexForGlyph(at: glyph)
    if fraction >= 0.5 { character = nextBoundary(after: character, in: text) }
    character = min(max(0, character), (text as NSString).length)
    guard character != offset else { return nil }
    return VimVisualMovement(utf16Offset: character, preferredColumn: currentColumn)
  }

  private func validTextView(for text: String) -> NSTextView? {
    guard let textView, textView.string == text else { return nil }
    return textView
  }

  private func layoutRect(at rawOffset: Int, in textView: NSTextView) -> NSRect? {
    guard let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer
    else { return nil }
    let length = (textView.string as NSString).length
    let offset = min(max(0, rawOffset), length)
    if length == 0 || (offset == length && textView.string.hasSuffix("\n")) {
      layoutManager.ensureLayout(for: textContainer)
      return layoutManager.extraLineFragmentRect
    }

    let character = min(offset, length - 1)
    layoutManager.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
    let glyph = layoutManager.glyphIndexForCharacter(at: character)
    let glyphRect = layoutManager.boundingRect(
      forGlyphRange: NSRange(location: glyph, length: 1),
      in: textContainer
    )
    if offset == length {
      let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      return NSRect(x: glyphRect.maxX, y: line.minY, width: 0, height: line.height)
    }
    return glyphRect
  }

  private func visualLineFragment(at offset: Int, in textView: NSTextView) -> NSRect? {
    guard let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer
    else { return nil }
    let length = (textView.string as NSString).length
    if length == 0 || (offset >= length && textView.string.hasSuffix("\n")) {
      layoutManager.ensureLayout(for: textContainer)
      return layoutManager.extraLineFragmentRect
    }
    let character = min(max(0, offset), max(0, length - 1))
    let glyph = layoutManager.glyphIndexForCharacter(at: character)
    return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
  }

  private func logicalLineStart(at offset: Int, in text: String) -> Int {
    let ns = text as NSString
    let clamped = min(max(0, offset), ns.length)
    return ns.lineRange(for: NSRange(location: clamped, length: 0)).location
  }

  private func nextBoundary(after offset: Int, in text: String) -> Int {
    let ns = text as NSString
    guard offset < ns.length else { return ns.length }
    return NSMaxRange(ns.rangeOfComposedCharacterSequence(at: offset))
  }
}
