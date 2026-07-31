import Foundation

/// Owns the coalescing state for file-driven debug restarts. Keeping this state out of
/// `EditorWorkspaceController` makes generation checks explicit and independently testable.
struct EditorLiveDebugChangeAccumulator: Sendable {
  private(set) var pending = ProjectFileChangeBatch()
  private(set) var generation: UInt64 = 0

  var isEmpty: Bool { pending.isEmpty }

  var changedPathCount: Int {
    pending.changedPaths.count
      + pending.removedPaths.count
      + pending.renamedPaths.count
      + (pending.requiresFullRescan ? 1 : 0)
  }

  @discardableResult
  mutating func merge(_ batch: ProjectFileChangeBatch) -> UInt64 {
    guard !batch.isEmpty else { return generation }
    pending.merge(batch)
    generation &+= 1
    return generation
  }

  mutating func drain() -> (batch: ProjectFileChangeBatch, generation: UInt64) {
    let result = (pending, generation)
    pending = ProjectFileChangeBatch()
    return result
  }

  mutating func reset() {
    pending = ProjectFileChangeBatch()
    generation &+= 1
  }
}
