import Combine
import Foundation

#if os(macOS)
  /// Owns terminal sessions for the entire app lifetime, independent of views.
  @MainActor
  final class EditorTerminalSessionRegistry: ObservableObject {
    struct DebugTerminal: Identifiable {
      let id: UUID
      let workspaceURL: URL
      let session: EditorTerminalSession
      let title: String?
    }

    static let shared = EditorTerminalSessionRegistry()

    @Published private(set) var debugTerminals: [UUID: DebugTerminal] = [:]
    @Published private(set) var activeDebugTerminalIDs: [String: UUID] = [:]

    private var sessions: [String: EditorTerminalSession] = [:]

    private init() {}

    func session(for workspaceURL: URL) -> EditorTerminalSession {
      let url = workspaceURL.standardizedFileURL
      if let session = sessions[url.path] {
        return session
      }
      let session = EditorTerminalSession(workspaceURL: url)
      sessions[url.path] = session
      return session
    }

    func createDebugSession(
      workspaceURL: URL,
      id: UUID,
      command: String,
      title: String?
    ) -> EditorTerminalSession {
      let workspaceURL = workspaceURL.standardizedFileURL
      if let existing = debugTerminals[id] { return existing.session }
      let session = EditorTerminalSession(
        workspaceURL: workspaceURL,
        initialCommand: command + "\r",
        monitorsPythonEnvironment: false
      )
      debugTerminals[id] = DebugTerminal(
        id: id,
        workspaceURL: workspaceURL,
        session: session,
        title: title
      )
      activeDebugTerminalIDs[workspaceURL.path] = id
      session.start()
      return session
    }

    func activeDebugSession(for workspaceURL: URL) -> EditorTerminalSession? {
      let path = workspaceURL.standardizedFileURL.path
      guard let id = activeDebugTerminalIDs[path] else { return nil }
      return debugTerminals[id]?.session
    }

    func activeDebugTitle(for workspaceURL: URL) -> String? {
      let path = workspaceURL.standardizedFileURL.path
      guard let id = activeDebugTerminalIDs[path] else { return nil }
      return debugTerminals[id]?.title
    }

    func removeDebugSession(id: UUID) {
      guard let value = debugTerminals.removeValue(forKey: id) else { return }
      if activeDebugTerminalIDs[value.workspaceURL.path] == id {
        activeDebugTerminalIDs.removeValue(forKey: value.workspaceURL.path)
      }
      value.session.stop()
    }

    func removeDebugSessions(for workspaceURL: URL) {
      let path = workspaceURL.standardizedFileURL.path
      let ids = debugTerminals.values.filter { $0.workspaceURL.path == path }.map(\.id)
      for id in ids { removeDebugSession(id: id) }
    }
  }
#endif
