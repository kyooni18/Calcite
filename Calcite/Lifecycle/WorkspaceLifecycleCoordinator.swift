import Combine
import Foundation

nonisolated enum WorkspaceLifecycleState: Equatable, Sendable {
  case idle
  case starting
  case running
  case stopping
  case stopped
  case failed(String)
}

@MainActor
final class WorkspaceLifecycleCoordinator: ObservableObject {
  @Published private(set) var state: WorkspaceLifecycleState = .idle

  private let controller: EditorWorkspaceController
  private let terminal: EditorTerminalSession
  private var startupTask: Task<StartupResult, Never>?

  init(controller: EditorWorkspaceController, terminal: EditorTerminalSession) {
    self.controller = controller
    self.terminal = terminal
  }

  func start(
    initialFileURL: URL?,
    shouldStartTerminal: Bool,
    onReady: (EditorWorkspaceController?) -> Void
  ) async {
    guard state == .idle else { return }
    state = .starting

    let controller = controller
    let terminal = terminal
    let task = Task { @MainActor in
      await controller.start()
      guard !Task.isCancelled else { return StartupResult.cancelled }

      if case .failed(let message) = controller.phase {
        return .failed(message)
      }

      if let initialFileURL {
        await controller.openDocument(at: initialFileURL)
        guard !Task.isCancelled else { return StartupResult.cancelled }
      }

      if shouldStartTerminal {
        terminal.startIfNeeded()
      }
      return .ready
    }
    startupTask = task

    let result = await task.value
    if startupTask != nil {
      startupTask = nil
    }

    guard state == .starting else { return }
    switch result {
    case .ready:
      state = .running
      onReady(controller)
    case .failed(let message):
      state = .failed(message)
      onReady(controller)
    case .cancelled:
      state = .stopped
      onReady(nil)
    }
  }

  func stop(onReady: (EditorWorkspaceController?) -> Void) async {
    switch state {
    case .stopping, .stopped:
      return
    case .idle:
      state = .stopped
      onReady(nil)
      return
    case .starting, .running, .failed:
      break
    }

    state = .stopping
    onReady(nil)

    if let startupTask {
      startupTask.cancel()
      _ = await startupTask.value
      self.startupTask = nil
    }

    _ = await controller.shutdown()
    state = .stopped
  }
}

nonisolated private enum StartupResult: Sendable {
  case ready
  case failed(String)
  case cancelled
}
