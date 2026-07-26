import Foundation

enum VimMotionKind: Sendable {
  case characterwise
  case linewise
}

struct VimMotionResult: Sendable {
  var destination: Int
  var kind: VimMotionKind
  var inclusive: Bool
  var crossedLine: Bool
  var desiredColumn: Int?
}
