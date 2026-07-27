import AppKit
import Foundation

@MainActor
enum CalciteVimViewportProvider {
  static func visibleUTF16Range(in textView: NSTextView) -> Range<Int>? {
    guard let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer
    else { return nil }
    let glyphRange = layoutManager.glyphRange(
      forBoundingRect: textView.visibleRect,
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
