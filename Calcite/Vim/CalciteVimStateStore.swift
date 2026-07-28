@_spi(Calcite) import EditorVim
import Foundation

/// Versioned workspace-level persistence for Vim session data that must outlive
/// individual documents and editor surfaces.
struct CalciteVimStateStore {
  private struct StoredState: Codable {
    var version: Int
    var history: VimHistorySnapshot
  }

  private static let currentVersion = 1
  private static let maximumFileBytes = 1_000_000

  private let fileURL: URL

  init(workspaceURL: URL) {
    fileURL = Self.storageURL(for: workspaceURL)
  }

  func loadHistory() -> VimHistorySnapshot {
    guard let data = try? Data(contentsOf: fileURL),
      data.count <= Self.maximumFileBytes,
      let state = try? JSONDecoder().decode(StoredState.self, from: data),
      state.version <= Self.currentVersion
    else {
      return VimHistorySnapshot()
    }
    return Self.limited(state.history)
  }

  func saveHistory(_ history: VimHistorySnapshot) {
    let state = StoredState(
      version: Self.currentVersion,
      history: Self.limited(history)
    )
    guard let data = try? JSONEncoder().encode(state) else { return }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL, options: .atomic)
    } catch {
      // Persistence failure must never interrupt editing.
    }
  }

  private static func limited(_ history: VimHistorySnapshot) -> VimHistorySnapshot {
    VimHistorySnapshot(
      commands: Array(history.commands.suffix(200)),
      searches: Array(history.searches.suffix(200))
    )
  }

  private static func storageURL(for workspaceURL: URL) -> URL {
    let applicationSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support",
        isDirectory: true
      )
    return
      applicationSupport
      .appendingPathComponent("Calcite/Workspaces", isDirectory: true)
      .appendingPathComponent(
        stableIdentifier(workspaceURL.standardizedFileURL.path), isDirectory: true
      )
      .appendingPathComponent("vim-state.json")
  }

  private static func stableIdentifier(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }
}
