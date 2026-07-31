import Combine
import Foundation

@MainActor
final class EditorLiveDebugController: ObservableObject {
  typealias RootResolver = @MainActor (EditorDebugLaunchTarget) -> [URL]
  typealias Filter = @MainActor (URL, EditorDebugLaunchTarget) -> Bool
  typealias ApplyChanges = @MainActor (ProjectFileChangeBatch, UInt64) async -> Void

  private let rootResolver: RootResolver
  private let filter: Filter
  private let applyChanges: ApplyChanges
  @Published private(set) var phase: EditorLiveDebugPhase = .disabled
  private var monitors: [ProjectFileSystemMonitor] = []
  private var changes = EditorLiveDebugChangeAccumulator()
  private var processingTask: Task<Void, Never>?
  private(set) var generation: UInt64 = 0
  private(set) var isEnabled = false
  private(set) var target: EditorDebugLaunchTarget = .project

  init(
    rootResolver: @escaping RootResolver,
    filter: @escaping Filter,
    applyChanges: @escaping ApplyChanges
  ) {
    self.rootResolver = rootResolver
    self.filter = filter
    self.applyChanges = applyChanges
  }

  deinit {
    processingTask?.cancel()
  }

  func report(_ phase: EditorLiveDebugPhase) {
    setPhase(phase)
  }

  private func setPhase(_ value: EditorLiveDebugPhase) {
    guard phase != value else { return }
    phase = value
  }

  func configure(enabled: Bool, target: EditorDebugLaunchTarget) {
    generation &+= 1
    self.target = target
    isEnabled = enabled
    processingTask?.cancel()
    processingTask = nil
    for monitor in monitors { monitor.stop() }
    monitors.removeAll(keepingCapacity: false)
    changes.reset()

    guard enabled else {
      setPhase(.disabled)
      return
    }

    let roots = Array(Set(rootResolver(target).map(\.standardizedFileURL)))
    guard !roots.isEmpty else {
      setPhase(.failed("No Live Debug watch root is available."))
      return
    }
    let currentGeneration = generation
    monitors = roots.map { root in
      ProjectFileSystemMonitor(rootURL: root) { [weak self] batch in
        Task { @MainActor [weak self] in
          guard let self, self.generation == currentGeneration else { return }
          self.receive(batch)
        }
      }
    }
    setPhase(.watching)
  }

  func enqueueFullRestart(for paths: Set<URL>) {
    receive(ProjectFileChangeBatch(changedPaths: paths, requiresFullRescan: true))
  }

  func stop() {
    configure(enabled: false, target: target)
  }

  private func receive(_ incoming: ProjectFileChangeBatch) {
    guard isEnabled else { return }
    var batch = incoming
    batch.changedPaths = Set(batch.changedPaths.filter { filter($0, target) })
    batch.removedPaths = Set(batch.removedPaths.filter { filter($0, target) })
    batch.renamedPaths = Set(batch.renamedPaths.filter { filter($0, target) })
    guard !batch.isEmpty else { return }

    changes.merge(batch)
    setPhase(.changesPending(changes.changedPathCount))
    guard processingTask == nil else { return }

    let taskGeneration = generation
    processingTask = Task { [weak self] in
      guard let self else { return }
      await self.process(taskGeneration: taskGeneration)
    }
  }

  private func process(taskGeneration: UInt64) async {
    defer {
      if generation == taskGeneration { processingTask = nil }
    }
    while isEnabled, generation == taskGeneration, !Task.isCancelled {
      var observed = changes.generation
      while true {
        do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
        guard generation == taskGeneration, !Task.isCancelled else { return }
        if observed == changes.generation { break }
        observed = changes.generation
      }

      let batch = changes.drain().batch
      guard !batch.isEmpty else {
        setPhase(isEnabled ? .watching : .disabled)
        return
      }
      await applyChanges(batch, taskGeneration)
      guard generation == taskGeneration, !Task.isCancelled else { return }
      if changes.isEmpty {
        setPhase(isEnabled ? .watching : .disabled)
        return
      }
      setPhase(.changesPending(changes.changedPathCount))
    }
  }
}
