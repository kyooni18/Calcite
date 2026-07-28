import Foundation

enum VimMotionKind: Hashable, Sendable {
  case characterwise
  case linewise
  case blockwise
}

struct VimMotionResult: Sendable {
  var destination: Int
  var kind: VimMotionKind
  var inclusive: Bool
  var crossedLine: Bool
  var desiredColumn: Int?
  var succeeded: Bool
  var isJump: Bool = false
  var explicitRange: Range<Int>? = nil
}
