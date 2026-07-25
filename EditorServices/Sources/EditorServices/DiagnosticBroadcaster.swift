import EditorCore
import Foundation

actor DiagnosticBroadcaster {
  private struct Subscriber {
    var uri: URL
    var continuation: AsyncStream<DiagnosticBatch>.Continuation
  }

  private var subscribers: [UUID: Subscriber] = [:]
  private var latest: [URL: DiagnosticBatch] = [:]
  private var finished = false

  func stream(for uri: URL, replayLatest: Bool) -> AsyncStream<DiagnosticBatch> {
    guard !finished else { return AsyncStream { $0.finish() } }
    let id = UUID()
    let stream = AsyncStream<DiagnosticBatch>(bufferingPolicy: .bufferingNewest(1)) {
      continuation in
      subscribers[id] = Subscriber(uri: uri, continuation: continuation)
      if replayLatest, let value = latest[uri] { continuation.yield(value) }
      continuation.onTermination = { [weak self] _ in
        Task { await self?.remove(id) }
      }
    }
    return stream
  }

  func publish(_ batch: DiagnosticBatch) {
    guard !finished else { return }
    latest[batch.uri] = batch
    for subscriber in subscribers.values where subscriber.uri == batch.uri {
      subscriber.continuation.yield(batch)
    }
  }

  func clear(_ uri: URL) {
    latest.removeValue(forKey: uri)
  }

  func finish() {
    guard !finished else { return }
    finished = true
    for subscriber in subscribers.values { subscriber.continuation.finish() }
    subscribers.removeAll()
    latest.removeAll()
  }

  private func remove(_ id: UUID) {
    subscribers.removeValue(forKey: id)
  }
}
