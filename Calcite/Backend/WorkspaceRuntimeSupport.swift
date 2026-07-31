import Foundation

/// A stable identity for work whose lifetime belongs to an editor workspace.
enum WorkspaceTaskKey: Hashable, Sendable, CustomStringConvertible {
  case reconfiguration
  case sessionPersistence
  case projectRefresh
  case buildLaunch
  case debugOperation
  case debugInspection
  case liveDebug
  case backendMessages
  case backendDiagnostics
  case sourceWorkspaceEvents
  case debugEvents
  case debugStandardError
  case debugTransportErrors
  case languageServiceRecovery(String)
  case tabOperation(UUID)
  case auxiliary(String)

  var description: String {
    switch self {
    case .reconfiguration: return "reconfiguration"
    case .sessionPersistence: return "session-persistence"
    case .projectRefresh: return "project-refresh"
    case .buildLaunch: return "build-launch"
    case .debugOperation: return "debug-operation"
    case .debugInspection: return "debug-inspection"
    case .liveDebug: return "live-debug"
    case .backendMessages: return "backend-messages"
    case .backendDiagnostics: return "backend-diagnostics"
    case .sourceWorkspaceEvents: return "source-workspace-events"
    case .debugEvents: return "debug-events"
    case .debugStandardError: return "debug-standard-error"
    case .debugTransportErrors: return "debug-transport-errors"
    case .languageServiceRecovery(let id): return "language-service-recovery-\(id)"
    case .tabOperation(let id): return "tab-operation-\(id.uuidString)"
    case .auxiliary(let name): return name
    }
  }
}

struct WorkspaceTaskLease: Hashable, Sendable {
  let key: WorkspaceTaskKey
  let generation: UInt64
}

struct WorkspaceTaskSnapshot: Equatable, Sendable {
  let key: WorkspaceTaskKey
  let generation: UInt64
  let startedAt: ContinuousClock.Instant
}

enum WorkspaceTaskLifecycleEvent: Sendable {
  case started(WorkspaceTaskLease)
  case cancelled(WorkspaceTaskLease)
  case finished(WorkspaceTaskLease)
}

/// Owns every fire-and-forget task whose result may mutate workspace UI state.
/// Replacing a slot cancels its old task, waits for it to finish, and only then
/// runs the new operation. A lease prevents a superseded operation from publishing.
@MainActor
final class WorkspaceTaskSupervisor {
  private struct Entry {
    let lease: WorkspaceTaskLease
    let startedAt: ContinuousClock.Instant
    let task: Task<Void, Never>
  }

  private var entries: [WorkspaceTaskKey: Entry] = [:]
  private var generations: [WorkspaceTaskKey: UInt64] = [:]
  private var acceptsNewTasks = true
  var onEvent: ((WorkspaceTaskLifecycleEvent) -> Void)?

  var activeCount: Int { entries.count }

  isolated deinit {
    for entry in entries.values { entry.task.cancel() }
  }

  func contains(_ key: WorkspaceTaskKey) -> Bool {
    entries[key] != nil
  }

  @discardableResult
  func replace(
    _ key: WorkspaceTaskKey,
    operation: @escaping @MainActor (WorkspaceTaskLease) async -> Void
  ) -> WorkspaceTaskLease? {
    guard acceptsNewTasks else { return nil }

    let previousEntry = entries.removeValue(forKey: key)
    let previous = previousEntry?.task
    previous?.cancel()
    if let previousEntry { onEvent?(.cancelled(previousEntry.lease)) }
    let generation = generations[key, default: 0] &+ 1
    generations[key] = generation
    let lease = WorkspaceTaskLease(key: key, generation: generation)
    let startedAt = ContinuousClock.now
    let task = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, !Task.isCancelled, self.isCurrent(lease) else { return }
      await operation(lease)
      self.finish(lease)
    }
    entries[key] = Entry(lease: lease, startedAt: startedAt, task: task)
    onEvent?(.started(lease))
    return lease
  }

  func isCurrent(_ lease: WorkspaceTaskLease) -> Bool {
    entries[lease.key]?.lease == lease && !Task.isCancelled
  }

  func cancel(_ key: WorkspaceTaskKey) {
    _ = cancelReturningTask(key)
  }

  func cancelReturningTask(_ key: WorkspaceTaskKey) -> Task<Void, Never>? {
    guard let entry = entries.removeValue(forKey: key) else { return nil }
    generations[key] = max(generations[key, default: 0], entry.lease.generation) &+ 1
    entry.task.cancel()
    onEvent?(.cancelled(entry.lease))
    return entry.task
  }

  func cancelAndWait(_ key: WorkspaceTaskKey) async {
    guard let entry = entries.removeValue(forKey: key) else { return }
    generations[key] = max(generations[key, default: 0], entry.lease.generation) &+ 1
    entry.task.cancel()
    onEvent?(.cancelled(entry.lease))
    await entry.task.value
  }

  func cancelAllAndWait(rejectingNewTasks: Bool = false) async {
    if rejectingNewTasks { acceptsNewTasks = false }
    let pending = entries.values.map(\.task)
    for entry in entries.values {
      generations[entry.lease.key] =
        max(
          generations[entry.lease.key, default: 0], entry.lease.generation) &+ 1
      entry.task.cancel()
      onEvent?(.cancelled(entry.lease))
    }
    entries.removeAll(keepingCapacity: true)
    for task in pending { await task.value }
  }

  func resumeAcceptingTasks() {
    acceptsNewTasks = true
  }

  func snapshots() -> [WorkspaceTaskSnapshot] {
    entries.values
      .map {
        WorkspaceTaskSnapshot(
          key: $0.lease.key,
          generation: $0.lease.generation,
          startedAt: $0.startedAt
        )
      }
      .sorted { $0.key.description < $1.key.description }
  }

  private func finish(_ lease: WorkspaceTaskLease) {
    guard entries[lease.key]?.lease == lease else { return }
    entries.removeValue(forKey: lease.key)
    onEvent?(.finished(lease))
  }
}

enum WorkspaceRuntimeState: Equatable, Sendable {
  case idle
  case starting(UUID)
  case running
  case preparingReconfiguration(UUID)
  case committingReconfiguration(UUID)
  case shuttingDown
  case terminated
  case failed(String)

  func permitsTransition(to next: WorkspaceRuntimeState) -> Bool {
    switch (self, next) {
    case (.idle, .starting), (.idle, .preparingReconfiguration),
      (.idle, .shuttingDown), (.idle, .terminated):
      return true
    case (.starting, .running), (.starting, .preparingReconfiguration),
      (.starting, .failed), (.starting, .shuttingDown), (.starting, .idle):
      return true
    case (.running, .preparingReconfiguration), (.running, .shuttingDown),
      (.running, .failed):
      return true
    case (.preparingReconfiguration, .committingReconfiguration),
      (.preparingReconfiguration, .running), (.preparingReconfiguration, .failed),
      (.preparingReconfiguration, .shuttingDown), (.preparingReconfiguration, .idle):
      return true
    case (.committingReconfiguration, .running), (.committingReconfiguration, .failed),
      (.committingReconfiguration, .shuttingDown):
      return true
    case (.failed, .starting), (.failed, .preparingReconfiguration),
      (.failed, .shuttingDown), (.failed, .idle), (.failed, .running):
      return true
    case (.shuttingDown, .terminated), (.shuttingDown, .failed):
      return true
    case (.terminated, .terminated):
      return true
    default:
      return self == next
    }
  }
}

enum StabilityEventKind: String, Codable, Sendable {
  case lifecycle
  case task
  case document
  case layout
  case languageService
  case debugger
  case persistence
  case warning
  case error
}

struct StabilityEvent: Codable, Sendable {
  let timestamp: Date
  let kind: StabilityEventKind
  let name: String
  let detail: String?
  let metadata: [String: String]
}

/// A bounded in-memory flight recorder. It is intentionally cheap enough to
/// leave enabled and can be exported when an intermittent failure occurs.
@MainActor
final class StabilityEventRecorder {
  static let shared = StabilityEventRecorder()

  private let capacity: Int
  private var events: [StabilityEvent] = []

  init(capacity: Int = 1_000) {
    self.capacity = max(100, capacity)
  }

  func record(
    _ kind: StabilityEventKind,
    _ name: String,
    detail: String? = nil,
    metadata: [String: String] = [:]
  ) {
    events.append(
      StabilityEvent(
        timestamp: Date(), kind: kind, name: name, detail: detail, metadata: metadata))
    if events.count > capacity {
      events.removeFirst(events.count - capacity)
    }
  }

  func snapshot() -> [StabilityEvent] { events }

  func removeAll() { events.removeAll(keepingCapacity: true) }

  func export(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(events).write(to: url, options: [.atomic])
  }
}

struct WorkspaceServiceRecoveryDecision: Equatable, Sendable {
  let attempt: Int
  let delay: Duration
}

/// Bounds automatic service restarts so a crashing language server cannot keep
/// tearing down and rebuilding the workspace forever. Attempts expire after a
/// quiet window, allowing recovery again after the underlying problem is fixed.
struct WorkspaceServiceRecoveryPolicy: Sendable {
  var maximumAttempts: Int
  var attemptWindow: TimeInterval
  var baseDelayMilliseconds: Int

  private var attemptsByService: [String: [Date]] = [:]

  init(
    maximumAttempts: Int = 3,
    attemptWindow: TimeInterval = 60,
    baseDelayMilliseconds: Int = 500
  ) {
    self.maximumAttempts = max(1, maximumAttempts)
    self.attemptWindow = max(1, attemptWindow)
    self.baseDelayMilliseconds = max(0, baseDelayMilliseconds)
  }

  mutating func nextDecision(
    for serviceIdentifier: String,
    now: Date = Date()
  ) -> WorkspaceServiceRecoveryDecision? {
    let key = serviceIdentifier.isEmpty ? "unknown" : serviceIdentifier
    let cutoff = now.addingTimeInterval(-max(1, attemptWindow))
    var attempts = attemptsByService[key, default: []].filter { $0 >= cutoff }
    guard attempts.count < max(1, maximumAttempts) else {
      attemptsByService[key] = attempts
      return nil
    }
    attempts.append(now)
    attemptsByService[key] = attempts
    let attempt = attempts.count
    let multiplier = 1 << max(0, attempt - 1)
    let milliseconds = max(0, baseDelayMilliseconds) * multiplier
    return WorkspaceServiceRecoveryDecision(
      attempt: attempt,
      delay: .milliseconds(milliseconds)
    )
  }

  mutating func reset(_ serviceIdentifier: String? = nil) {
    if let serviceIdentifier {
      attemptsByService.removeValue(forKey: serviceIdentifier)
    } else {
      attemptsByService.removeAll(keepingCapacity: true)
    }
  }
}
