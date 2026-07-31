import Foundation

nonisolated enum EditorProcessOwner: Hashable, Sendable {
  case build(workspacePath: String, generation: UInt64)
  case run(workspacePath: String, generation: UInt64)
  case test(workspacePath: String, generation: UInt64)
  case debug(workspacePath: String)
  case liveDebug(workspacePath: String)
  case terminal(workspacePath: String, sessionID: UUID)

  var workspacePath: String {
    switch self {
    case .build(let path, _), .run(let path, _), .test(let path, _),
      .debug(let path), .liveDebug(let path), .terminal(let path, _):
      return URL(fileURLWithPath: path).standardizedFileURL.path
    }
  }
}

/// A registration identity returned by ``EditorProcessRegistry``.
///
/// Process owners are intentionally stable, but a single owner can be registered more than once
/// during rapid restarts. The lease prevents an older operation from unregistering the process
/// that replaced it.
nonisolated struct EditorProcessLease: Hashable, Sendable {
  let owner: EditorProcessOwner
  let id: UUID
}

nonisolated enum EditorProcessReplacementPolicy: Sendable {
  /// Stop the previously registered process before the new registration becomes authoritative.
  case terminateExisting
  /// Replace only the ownership record. Use when another coordinator already replaced or restarted
  /// the underlying process and invoking the old terminator would stop the new session as well.
  case preserveExistingProcess
}

actor EditorProcessRegistry {
  typealias Terminator = @Sendable () async -> Void

  private struct Entry {
    let lease: EditorProcessLease
    let terminate: Terminator
  }

  static let shared = EditorProcessRegistry()

  private var entries: [EditorProcessOwner: Entry] = [:]

  /// Registers a process owner and returns a lease for conditional cleanup.
  ///
  /// The new entry is installed before an earlier terminator is awaited. Actor reentrancy can then
  /// allow another registration to arrive while cleanup is running without giving the older call a
  /// chance to overwrite or unregister that newer entry.
  @discardableResult
  func register(
    owner: EditorProcessOwner,
    replacementPolicy: EditorProcessReplacementPolicy = .terminateExisting,
    terminate: @escaping Terminator
  ) async -> EditorProcessLease {
    let lease = EditorProcessLease(owner: owner, id: UUID())
    let previous = entries.updateValue(Entry(lease: lease, terminate: terminate), forKey: owner)
    if replacementPolicy == .terminateExisting, let previous {
      await previous.terminate()
    }
    return lease
  }

  /// Removes a registration only when the supplied lease is still current.
  /// Stale process completion callbacks therefore cannot erase a replacement process.
  @discardableResult
  func unregister(_ lease: EditorProcessLease) -> Bool {
    guard entries[lease.owner]?.lease == lease else { return false }
    entries.removeValue(forKey: lease.owner)
    return true
  }

  /// Force-removes the current registration for an owner without invoking its terminator.
  /// This is reserved for coordinators that already stopped the underlying process themselves.
  @discardableResult
  func unregister(owner: EditorProcessOwner) -> EditorProcessLease? {
    entries.removeValue(forKey: owner)?.lease
  }

  func terminate(owner: EditorProcessOwner) async {
    guard let entry = entries.removeValue(forKey: owner) else { return }
    await entry.terminate()
  }

  func terminate(workspaceURL: URL) async {
    await terminate(workspacePath: workspaceURL.standardizedFileURL.path)
  }

  func terminate(workspacePath: String) async {
    let normalized = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
    let matching = entries.filter { $0.key.workspacePath == normalized }
    for owner in matching.keys { entries.removeValue(forKey: owner) }
    for entry in matching.values { await entry.terminate() }
  }

  func terminateAll() async {
    let values = entries.values
    entries.removeAll()
    for entry in values { await entry.terminate() }
  }

  func activeOwners(workspaceURL: URL) -> Set<EditorProcessOwner> {
    let path = workspaceURL.standardizedFileURL.path
    return Set(entries.keys.filter { $0.workspacePath == path })
  }

  func currentLease(for owner: EditorProcessOwner) -> EditorProcessLease? {
    entries[owner]?.lease
  }

  var activeOwners: Set<EditorProcessOwner> { Set(entries.keys) }
  var activeCount: Int { entries.count }
}
