import Foundation

#if os(macOS)
  /// Owns terminal sessions for the entire app lifetime, independent of views.
  @MainActor
  final class EditorTerminalSessionRegistry {
    static let shared = EditorTerminalSessionRegistry()

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
  }
#endif
