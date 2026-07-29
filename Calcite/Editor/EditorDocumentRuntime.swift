import Foundation

@MainActor
final class EditorDocumentMutationQueue {
  private var tail: Task<Void, Never>?
  private var generation: UInt64 = 0
  private(set) var pendingCount = 0

  isolated deinit {
    tail?.cancel()
  }

  @discardableResult
  func enqueue(
    _ operation: @escaping @MainActor (_ generation: UInt64) async -> Void
  ) -> UInt64 {
    let previous = tail
    generation &+= 1
    let operationGeneration = generation
    pendingCount += 1
    let task = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, !Task.isCancelled else { return }
      await operation(operationGeneration)
      self.pendingCount = max(0, self.pendingCount - 1)
      if self.generation == operationGeneration {
        self.tail = nil
      }
    }
    tail = task
    return operationGeneration
  }

  func waitForIdle() async {
    let pending = tail
    await pending?.value
  }

  func cancelAndWait() async {
    let pending = tail
    generation &+= 1
    tail = nil
    pendingCount = 0
    pending?.cancel()
    await pending?.value
  }
}

enum EditorDocumentDiskState: Equatable, Sendable {
  case synchronized
  case memoryModified(revision: UInt64)
  case diskModified
  case conflicted
  case saving(revision: UInt64)
  case unavailable(String)
}
