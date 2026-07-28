import Foundation

/// Internal motion vocabulary shared by Normal, Visual, and operator-pending
/// execution. Public `VimMotion` remains the source-compatible adapter.
enum VimMotionExpression: Hashable, Sendable {
  case standard(VimMotion)
  case wholeWordForward
  case wholeWordBackward
  case wholeWordEnd
  case previousWordEnd
  case previousWholeWordEnd
  case displayLineUp
  case displayLineDown
  case adjacentLineUp
  case adjacentLineDown
  case currentOrFollowingLine
  case column
  case lastNonBlank
  case sentenceBackward
  case sentenceForward
  case paragraphBackward
  case paragraphForward
  case mark(Character, linewise: Bool)
  case repeatFind(reverse: Bool)
  case search(String, forward: Bool)
  case repeatSearch(reverse: Bool)
  case viewport(VimViewportPosition)
  case wordSearch(forward: Bool, wholeWord: Bool)
  case nextSearchMatch(reverse: Bool)
  case textObject(VimTextObject, inner: Bool)
  case percentage(Int)

  var standardMotion: VimMotion? {
    guard case .standard(let motion) = self else { return nil }
    return motion
  }

  var isDisplayLineMotion: Bool {
    self == .displayLineUp || self == .displayLineDown
  }

  var isWordForwardMotion: Bool {
    self == .standard(.wordForward) || self == .wholeWordForward
  }

  var isSelectionMotion: Bool {
    switch self {
    case .nextSearchMatch, .textObject:
      return true
    default:
      return false
    }
  }
}

enum VimViewportPosition: Hashable, Sendable {
  case top
  case middle
  case bottom
}
