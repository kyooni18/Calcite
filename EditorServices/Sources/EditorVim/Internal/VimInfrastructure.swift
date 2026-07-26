import Foundation

extension NSRecursiveLock {
  @inline(__always)
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

struct VimStateMetadata: Sendable {
  var cursor: Int
  var mode: VimMode
  var selection: VimSelection?

  init(_ state: VimState) {
    cursor = state.cursor
    mode = state.mode
    selection = state.selection
  }

  func applying(to text: String) -> VimState {
    VimState(text: text, cursor: cursor, mode: mode, selection: selection)
  }
}
