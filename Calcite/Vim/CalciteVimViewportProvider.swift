import AppKit
import Foundation

@MainActor
enum CalciteVimViewportProvider {
  static func visibleUTF16Range(in textView: NSTextView) -> Range<Int>? {
    guard let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer
    else { return nil }

    // `visibleRect` is in the text view's coordinate space, while the layout
    // manager expects a rect in the text container's space. Those differ by
    // `textContainerOrigin` (normally the editor inset). Passing the view rect
    // through directly makes the reported viewport drift at the document
    // bounds, where even a small offset can omit the first or last line.
    let origin = textView.textContainerOrigin
    let visibleContainerRect = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
    let glyphRange = layoutManager.glyphRange(
      forBoundingRect: visibleContainerRect,
      in: textContainer
    )
    let characterRange = layoutManager.characterRange(
      forGlyphRange: glyphRange,
      actualGlyphRange: nil
    )
    let length = (textView.string as NSString).length
    let lower = min(max(0, characterRange.location), length)
    let upper = min(max(lower, NSMaxRange(characterRange)), length)
    return lower..<upper
  }
}
