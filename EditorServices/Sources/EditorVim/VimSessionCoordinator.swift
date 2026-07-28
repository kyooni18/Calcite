import Foundation

@_spi(Calcite)
public struct VimBufferID: Hashable, Sendable, Codable {
  public var rawValue: UUID
  public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

@_spi(Calcite)
public struct VimWindowID: Hashable, Sendable, Codable {
  public var rawValue: UUID
  public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

@_spi(Calcite)
public struct VimTabPageID: Hashable, Sendable, Codable {
  public var rawValue: UUID
  public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

@_spi(Calcite)
public struct VimBufferInfo: Hashable, Sendable {
  public var id: VimBufferID
  public var number: Int
  public var name: String
  public var isListed: Bool
  public var isLoaded: Bool
  public var isModified: Bool

  public init(
    id: VimBufferID,
    number: Int,
    name: String,
    isListed: Bool = true,
    isLoaded: Bool = true,
    isModified: Bool = false
  ) {
    self.id = id
    self.number = number
    self.name = name
    self.isListed = isListed
    self.isLoaded = isLoaded
    self.isModified = isModified
  }
}

/// Owns Vim's window-session global state and the buffer/window relationships
/// used by Calcite. A controller is cached per `(window, buffer)` pair, which
/// preserves window-local cursor/parser state while sharing the buffer's undo,
/// marks, options, and the session's registers/macros/history.
@_spi(Calcite)
public final class VimSessionCoordinator: @unchecked Sendable {
  private struct BufferRecord {
    var info: VimBufferInfo
    let state: VimBufferStateStorage
  }

  private struct WindowRecord {
    var currentBuffer: VimBufferID
    var alternateBuffer: VimBufferID?
    var tabPageID: VimTabPageID?
    var controllers: [VimBufferID: VimKeymapController]
  }

  private let lock = NSRecursiveLock()
  private let globalState: VimGlobalStateStorage
  private var buffers: [VimBufferID: BufferRecord] = [:]
  private var bufferOrder: [VimBufferID] = []
  private var windows: [VimWindowID: WindowRecord] = [:]
  private var nextBufferNumber = 1

  public init(leader: String = "\\", localLeader: String = "\\") {
    self.globalState = VimGlobalStateStorage(leader: leader, localLeader: localLeader)
  }

  @discardableResult
  public func registerBuffer(
    id: VimBufferID,
    name: String,
    text: String,
    tabWidth: Int = 2,
    history: VimHistorySnapshot = VimHistorySnapshot()
  ) -> VimBufferInfo {
    lock.withLock {
      globalState.history.merge(history)
      if var record = buffers[id] {
        record.info.name = name
        record.info.isLoaded = true
        record.state.tabWidth = max(1, tabWidth)
        buffers[id] = record
        return record.info
      }
      let info = VimBufferInfo(id: id, number: nextBufferNumber, name: name)
      nextBufferNumber += 1
      buffers[id] = BufferRecord(
        info: info,
        state: VimBufferStateStorage(text: text, tabWidth: tabWidth)
      )
      bufferOrder.append(id)
      return info
    }
  }

  public func updateBufferMetadata(
    id: VimBufferID,
    name: String? = nil,
    isLoaded: Bool? = nil,
    isModified: Bool? = nil,
    isListed: Bool? = nil
  ) {
    lock.withLock {
      guard var record = buffers[id] else { return }
      if let name { record.info.name = name }
      if let isLoaded { record.info.isLoaded = isLoaded }
      if let isModified { record.info.isModified = isModified }
      if let isListed { record.info.isListed = isListed }
      buffers[id] = record
    }
  }

  public func bufferInfo(id: VimBufferID) -> VimBufferInfo? {
    lock.withLock { buffers[id]?.info }
  }

  public func bufferInfo(number: Int) -> VimBufferInfo? {
    lock.withLock { buffers.values.first(where: { $0.info.number == number })?.info }
  }

  public var listedBuffers: [VimBufferInfo] {
    lock.withLock {
      bufferOrder.compactMap { buffers[$0]?.info }.filter(\.isListed)
    }
  }

  public func controller(
    for windowID: VimWindowID,
    displaying bufferID: VimBufferID,
    text: String,
    cursor: Int,
    name: String,
    leader: String,
    localLeader: String,
    tabWidth: Int,
    history: VimHistorySnapshot = VimHistorySnapshot(),
    tabPageID: VimTabPageID? = nil
  ) -> VimKeymapController {
    lock.withLock {
      globalState.leader = leader
      globalState.localLeader = localLeader
      _ = registerBuffer(
        id: bufferID,
        name: name,
        text: text,
        tabWidth: tabWidth,
        history: history
      )

      var record =
        windows[windowID]
        ?? WindowRecord(
          currentBuffer: bufferID,
          alternateBuffer: nil,
          tabPageID: tabPageID,
          controllers: [:]
        )
      if record.currentBuffer != bufferID {
        record.alternateBuffer = record.currentBuffer
        record.currentBuffer = bufferID
      }
      if let tabPageID { record.tabPageID = tabPageID }

      if let controller = record.controllers[bufferID] {
        controller.engine.leader = leader
        controller.engine.localLeader = localLeader
        controller.engine.tabWidth = tabWidth
        windows[windowID] = record
        return controller
      }

      let bufferState = buffers[bufferID]!.state
      let engine = VimEngine(
        text: text,
        cursor: cursor,
        globalStateStorage: globalState,
        bufferStateStorage: bufferState
      )
      let controller = VimKeymapController(
        engine: engine,
        historyStorage: globalState.history
      )
      record.controllers[bufferID] = controller
      windows[windowID] = record
      return controller
    }
  }

  public func currentBuffer(for windowID: VimWindowID) -> VimBufferID? {
    lock.withLock { windows[windowID]?.currentBuffer }
  }

  public func alternateBuffer(for windowID: VimWindowID) -> VimBufferID? {
    lock.withLock { windows[windowID]?.alternateBuffer }
  }

  @discardableResult
  public func switchBuffer(
    in windowID: VimWindowID,
    to bufferID: VimBufferID
  ) -> Bool {
    lock.withLock {
      guard buffers[bufferID] != nil, var record = windows[windowID] else { return false }
      guard record.currentBuffer != bufferID else { return true }
      record.alternateBuffer = record.currentBuffer
      record.currentBuffer = bufferID
      windows[windowID] = record
      return true
    }
  }

  public func nextBuffer(after bufferID: VimBufferID, forward: Bool) -> VimBufferID? {
    lock.withLock {
      let listed = bufferOrder.filter { buffers[$0]?.info.isListed == true }
      guard !listed.isEmpty, let index = listed.firstIndex(of: bufferID) else {
        return listed.first
      }
      let delta = forward ? 1 : -1
      return listed[(index + delta + listed.count) % listed.count]
    }
  }

  public func removeWindow(_ windowID: VimWindowID) {
    lock.withLock { _ = windows.removeValue(forKey: windowID) }
  }

  /// Removes buffer state only after the host has detached every window.
  public func wipeBuffer(_ bufferID: VimBufferID) {
    lock.withLock {
      buffers.removeValue(forKey: bufferID)
      bufferOrder.removeAll { $0 == bufferID }
      for id in Array(windows.keys) {
        guard var record = windows[id] else { continue }
        record.controllers.removeValue(forKey: bufferID)
        if record.alternateBuffer == bufferID { record.alternateBuffer = nil }
        windows[id] = record
      }
    }
  }

  public func mergeHistory(_ history: VimHistorySnapshot) {
    lock.withLock { globalState.history.merge(history) }
  }

  public var historySnapshot: VimHistorySnapshot {
    lock.withLock {
      VimHistorySnapshot(
        commands: globalState.history.commands,
        searches: globalState.history.searches
      )
    }
  }
}
