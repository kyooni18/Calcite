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
public struct VimViewID: Hashable, Sendable, Codable {
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

@_spi(Calcite)
public struct VimBufferSnapshot: Hashable, Sendable {
  public var text: String
  public var revision: UInt64

  public init(text: String, revision: UInt64) {
    self.text = text
    self.revision = revision
  }
}

@_spi(Calcite)
public struct VimViewRuntimeSnapshot: Hashable, Sendable, Codable {
  public var cursor: Int
  public var mode: VimMode
  public var visualAnchor: Int?
  public var visualSelectionShape: VimSelectionShape
  public var preferredColumn: Int?
  public var preferredVisualColumn: Int?
  public var inputSourceIdentifier: String?
  public var horizontalScrollOffset: Double
  public var verticalScrollOffset: Double
  public var zoomScale: Double
  public var viewportTopLine: Int
  public var viewportBottomLine: Int

  public init(
    cursor: Int,
    mode: VimMode,
    visualAnchor: Int? = nil,
    visualSelectionShape: VimSelectionShape = .character,
    preferredColumn: Int? = nil,
    preferredVisualColumn: Int? = nil,
    inputSourceIdentifier: String? = nil,
    horizontalScrollOffset: Double = 0,
    verticalScrollOffset: Double = 0,
    zoomScale: Double = 1,
    viewportTopLine: Int = 1,
    viewportBottomLine: Int = 20
  ) {
    self.cursor = max(0, cursor)
    self.mode = mode
    self.visualAnchor = visualAnchor.map { max(0, $0) }
    self.visualSelectionShape = visualSelectionShape
    self.preferredColumn = preferredColumn.map { max(0, $0) }
    self.preferredVisualColumn = preferredVisualColumn.map { max(0, $0) }
    self.inputSourceIdentifier = inputSourceIdentifier
    self.horizontalScrollOffset = max(0, horizontalScrollOffset)
    self.verticalScrollOffset = max(0, verticalScrollOffset)
    self.zoomScale = min(max(zoomScale, 0.5), 2)
    self.viewportTopLine = max(1, viewportTopLine)
    self.viewportBottomLine = max(self.viewportTopLine, viewportBottomLine)
  }
}

@_spi(Calcite)
public enum VimControllerAttachment: Hashable, Sendable {
  case activate
  case retain
}

@_spi(Calcite)
public enum VimBufferCommitResult: Hashable, Sendable {
  case committed(VimBufferSnapshot)
  case conflict(current: VimBufferSnapshot)
  case missingBuffer
}

extension VimEngine {
  @discardableResult
  func registerSessionBuffer(
    id: VimBufferID,
    name: String,
    text: String,
    tabWidth: Int,
    history: VimHistorySnapshot
  ) -> VimBufferInfo {
    lock.withLock {
      globalStateStorage.history.merge(history)
      if var record = sessionStorage.buffers[id] {
        record.info.name = name
        record.info.isLoaded = true
        record.state.tabWidth = max(1, tabWidth)
        sessionStorage.buffers[id] = record
        return record.info
      }

      let info = VimBufferInfo(
        id: id,
        number: sessionStorage.nextBufferNumber,
        name: name
      )
      sessionStorage.nextBufferNumber += 1
      sessionStorage.buffers[id] = VimEngineBufferRecord(
        info: info,
        state: VimBufferStateStorage(text: text, tabWidth: tabWidth)
      )
      sessionStorage.bufferOrder.append(id)
      return info
    }
  }

  func updateSessionBufferMetadata(
    id: VimBufferID,
    name: String? = nil,
    isLoaded: Bool? = nil,
    isModified: Bool? = nil,
    isListed: Bool? = nil
  ) {
    lock.withLock {
      guard var record = sessionStorage.buffers[id] else { return }
      if let name { record.info.name = name }
      if let isLoaded { record.info.isLoaded = isLoaded }
      if let isModified { record.info.isModified = isModified }
      if let isListed { record.info.isListed = isListed }
      sessionStorage.buffers[id] = record
    }
  }

  func sessionBufferInfo(id: VimBufferID) -> VimBufferInfo? {
    lock.withLock { sessionStorage.buffers[id]?.info }
  }

  func sessionBufferInfo(number: Int) -> VimBufferInfo? {
    lock.withLock {
      sessionStorage.buffers.values.first(where: { $0.info.number == number })?.info
    }
  }

  var sessionListedBuffers: [VimBufferInfo] {
    lock.withLock {
      sessionStorage.bufferOrder
        .compactMap { sessionStorage.buffers[$0]?.info }
        .filter(\.isListed)
    }
  }

  @discardableResult
  func ensureSessionView(
    windowID: VimWindowID,
    bufferID: VimBufferID,
    cursor: Int,
    tabPageID: VimTabPageID?,
    attachment: VimControllerAttachment
  ) -> VimViewID {
    lock.withLock {
      guard let buffer = sessionStorage.buffers[bufferID] else {
        preconditionFailure("Buffer must be registered before attaching a Vim view")
      }

      var window =
        sessionStorage.windows[windowID]
        ?? VimEngineWindowRecord(
          currentBuffer: nil,
          alternateBuffer: nil,
          tabPageID: tabPageID,
          views: [:],
          viewMRU: []
        )

      let viewID: VimViewID
      if let existing = window.views[bufferID] {
        viewID = existing
      } else {
        viewID = VimViewID(UUID())
        window.views[bufferID] = viewID
        sessionStorage.views[viewID] = VimEngineViewStateStorage(
          id: viewID,
          windowID: windowID,
          bufferID: bufferID,
          text: buffer.state.authoritativeText,
          cursor: cursor
        )
      }

      if attachment == .activate {
        if window.currentBuffer != bufferID, let current = window.currentBuffer {
          window.alternateBuffer = current
        }
        window.currentBuffer = bufferID
        window.viewMRU.removeAll { $0 == bufferID }
        window.viewMRU.insert(bufferID, at: 0)
      }
      if let tabPageID { window.tabPageID = tabPageID }
      sessionStorage.windows[windowID] = window

      withView(viewID) { normalizeCursorForMode() }
      return viewID
    }
  }

  func sessionViewID(windowID: VimWindowID, bufferID: VimBufferID) -> VimViewID? {
    lock.withLock { sessionStorage.windows[windowID]?.views[bufferID] }
  }

  func currentSessionViewID(for windowID: VimWindowID) -> VimViewID? {
    lock.withLock {
      guard let window = sessionStorage.windows[windowID],
        let bufferID = window.currentBuffer
      else { return nil }
      return window.views[bufferID]
    }
  }

  func currentSessionBuffer(for windowID: VimWindowID) -> VimBufferID? {
    lock.withLock { sessionStorage.windows[windowID]?.currentBuffer }
  }

  func alternateSessionBuffer(for windowID: VimWindowID) -> VimBufferID? {
    lock.withLock { sessionStorage.windows[windowID]?.alternateBuffer }
  }

  @discardableResult
  func switchSessionBuffer(in windowID: VimWindowID, to bufferID: VimBufferID) -> Bool {
    lock.withLock {
      guard let buffer = sessionStorage.buffers[bufferID],
        var window = sessionStorage.windows[windowID]
      else { return false }
      if window.views[bufferID] == nil {
        let viewID = VimViewID(UUID())
        window.views[bufferID] = viewID
        sessionStorage.views[viewID] = VimEngineViewStateStorage(
          id: viewID,
          windowID: windowID,
          bufferID: bufferID,
          text: buffer.state.authoritativeText,
          cursor: 0
        )
      }
      if window.currentBuffer != bufferID, let current = window.currentBuffer {
        window.alternateBuffer = current
      }
      window.currentBuffer = bufferID
      window.viewMRU.removeAll { $0 == bufferID }
      window.viewMRU.insert(bufferID, at: 0)
      sessionStorage.windows[windowID] = window
      return true
    }
  }

  func nextSessionBuffer(after bufferID: VimBufferID, forward: Bool) -> VimBufferID? {
    lock.withLock {
      let listed = sessionStorage.bufferOrder.filter {
        sessionStorage.buffers[$0]?.info.isListed == true
      }
      guard !listed.isEmpty, let index = listed.firstIndex(of: bufferID) else {
        return listed.first
      }
      let delta = forward ? 1 : -1
      return listed[(index + delta + listed.count) % listed.count]
    }
  }

  func detachSessionBuffer(_ bufferID: VimBufferID, from windowID: VimWindowID) {
    lock.withLock {
      guard var window = sessionStorage.windows[windowID] else { return }
      if let viewID = window.views.removeValue(forKey: bufferID) {
        sessionStorage.views.removeValue(forKey: viewID)
      }
      window.viewMRU.removeAll { $0 == bufferID }

      let usable: (VimBufferID) -> Bool = { candidate in
        guard window.views[candidate] != nil,
          let info = self.sessionStorage.buffers[candidate]?.info
        else { return false }
        return info.isLoaded && info.isListed
      }

      let previousAlternate = window.alternateBuffer
      if window.alternateBuffer == bufferID || window.alternateBuffer.map(usable) != true {
        window.alternateBuffer = nil
      }

      if window.currentBuffer == bufferID {
        let replacement =
          previousAlternate.flatMap { usable($0) ? $0 : nil }
          ?? window.viewMRU.first(where: usable)
          ?? sessionStorage.bufferOrder.first(where: usable)
        window.currentBuffer = replacement
        window.alternateBuffer = nil
        if let replacement {
          window.viewMRU.removeAll { $0 == replacement }
          window.viewMRU.insert(replacement, at: 0)
        }
      }
      sessionStorage.windows[windowID] = window
    }
  }

  func removeSessionWindow(_ windowID: VimWindowID) {
    lock.withLock {
      guard let window = sessionStorage.windows.removeValue(forKey: windowID) else { return }
      for viewID in window.views.values { sessionStorage.views.removeValue(forKey: viewID) }
    }
  }

  func unloadSessionBuffer(_ bufferID: VimBufferID) {
    lock.withLock {
      guard var record = sessionStorage.buffers[bufferID] else { return }
      record.info.isLoaded = false
      sessionStorage.buffers[bufferID] = record
      for windowID in Array(sessionStorage.windows.keys) {
        detachSessionBuffer(bufferID, from: windowID)
      }
    }
  }

  func wipeSessionBuffer(_ bufferID: VimBufferID) {
    lock.withLock {
      sessionStorage.buffers.removeValue(forKey: bufferID)
      sessionStorage.bufferOrder.removeAll { $0 == bufferID }
      for windowID in Array(sessionStorage.windows.keys) {
        detachSessionBuffer(bufferID, from: windowID)
      }
    }
  }

  func sessionBufferSnapshot(_ bufferID: VimBufferID) -> VimBufferSnapshot? {
    lock.withLock {
      guard let storage = sessionStorage.buffers[bufferID]?.state else { return nil }
      return VimBufferSnapshot(text: storage.authoritativeText, revision: storage.revision)
    }
  }

  func sessionViewRuntimeSnapshot(
    windowID: VimWindowID,
    bufferID: VimBufferID
  ) -> VimViewRuntimeSnapshot? {
    lock.withLock {
      guard let viewID = sessionStorage.windows[windowID]?.views[bufferID] else { return nil }
      return withView(viewID) {
        VimViewRuntimeSnapshot(
          cursor: state.cursor,
          mode: state.mode,
          visualAnchor: visualAnchor,
          visualSelectionShape: visualSelectionShape,
          preferredColumn: preferredColumn,
          preferredVisualColumn: preferredVisualColumn,
          inputSourceIdentifier: windowStateStorage.inputSourceIdentifier,
          horizontalScrollOffset: windowStateStorage.horizontalScrollOffset,
          verticalScrollOffset: windowStateStorage.verticalScrollOffset,
          zoomScale: windowStateStorage.zoomScale,
          viewportTopLine: windowStateStorage.viewportTopLine,
          viewportBottomLine: windowStateStorage.viewportBottomLine
        )
      }
    }
  }

  @discardableResult
  func restoreSessionViewRuntimeSnapshot(
    _ snapshot: VimViewRuntimeSnapshot,
    windowID: VimWindowID,
    bufferID: VimBufferID
  ) -> Bool {
    lock.withLock {
      guard let viewID = sessionStorage.windows[windowID]?.views[bufferID] else { return false }
      return withView(viewID) {
        state.cursor = normalizedVimUTF16Offset(snapshot.cursor, in: state.text)
        switch snapshot.mode {
        case .commandLine, .search:
          // Prompt buffers and mapping timers are intentionally transient.
          // Restoring only their mode would leave the window in a prompt state
          // with no prompt to edit, so resume in Normal mode instead.
          state.mode = .normal
        case .normal, .insert, .replace, .visualCharacter, .visualLine:
          state.mode = snapshot.mode
        }
        visualAnchor = snapshot.visualAnchor.map { normalizedVimUTF16Offset($0, in: state.text) }
        visualSelectionShape = snapshot.visualSelectionShape
        preferredColumn = snapshot.preferredColumn
        preferredVisualColumn = snapshot.preferredVisualColumn

        switch state.mode {
        case .visualCharacter, .visualLine:
          if visualAnchor == nil { visualAnchor = state.cursor }
          updateVisualSelection()
        case .normal, .insert, .replace, .commandLine, .search:
          state.selection = nil
          if state.mode != .commandLine && state.mode != .search {
            visualAnchor = nil
            visualSelectionShape = .character
          }
        }
        normalizeCursorForMode()

        windowStateStorage.inputSourceIdentifier = snapshot.inputSourceIdentifier
        windowStateStorage.horizontalScrollOffset = max(0, snapshot.horizontalScrollOffset)
        windowStateStorage.verticalScrollOffset = max(0, snapshot.verticalScrollOffset)
        windowStateStorage.zoomScale = min(max(snapshot.zoomScale, 0.5), 2)
        windowStateStorage.viewportTopLine = max(1, snapshot.viewportTopLine)
        windowStateStorage.viewportBottomLine = max(
          windowStateStorage.viewportTopLine,
          snapshot.viewportBottomLine
        )
        return true
      }
    }
  }

  func applySessionExternalSnapshot(
    _ text: String,
    to bufferID: VimBufferID,
    baseRevision: UInt64
  ) -> VimBufferCommitResult {
    lock.withLock {
      guard let buffer = sessionStorage.buffers[bufferID]?.state else {
        return .missingBuffer
      }
      let current = VimBufferSnapshot(
        text: buffer.authoritativeText,
        revision: buffer.revision
      )
      guard current.revision == baseRevision else {
        return .conflict(current: current)
      }
      guard current.text != text else { return .committed(current) }

      guard
        let originViewID = sessionStorage.views.values.first(where: {
          $0.bufferID == bufferID
        })?.id
      else {
        buffer.authoritativeText = text
        buffer.revision &+= 1
        buffer.lineIndex.synchronize(with: text)
        return .committed(
          VimBufferSnapshot(text: text, revision: buffer.revision)
        )
      }

      withView(originViewID) {
        _ = reconcileExternalText(text, cursor: nil)
      }
      return .committed(
        VimBufferSnapshot(text: buffer.authoritativeText, revision: buffer.revision)
      )
    }
  }

  var sessionHistorySnapshot: VimHistorySnapshot {
    lock.withLock {
      VimHistorySnapshot(
        commands: globalStateStorage.history.commands,
        searches: globalStateStorage.history.searches
      )
    }
  }

  func mergeSessionHistory(_ history: VimHistorySnapshot) {
    lock.withLock { globalStateStorage.history.merge(history) }
  }
}

/// Compatibility façade for Calcite. The state graph, buffer lifecycle, and
/// window/view relationships live entirely in `engine`; this object only caches
/// one stateless input adapter per window.
@_spi(Calcite)
public final class VimSessionCoordinator: @unchecked Sendable {
  public let engine: VimEngine
  private let lock = NSRecursiveLock()
  private var controllers: [VimWindowID: VimKeymapController] = [:]

  public init(leader: String = "\\", localLeader: String = "\\") {
    let engine = VimEngine(text: "", leader: leader, localLeader: localLeader)
    engine.updateSessionBufferMetadata(
      id: engine.defaultBufferID,
      name: "[session-bootstrap]",
      isLoaded: false,
      isListed: false
    )
    engine.lock.withLock {
      if var bootstrap = engine.sessionStorage.buffers[engine.defaultBufferID] {
        bootstrap.info.number = 0
        engine.sessionStorage.buffers[engine.defaultBufferID] = bootstrap
      }
      engine.sessionStorage.nextBufferNumber = 1
    }
    self.engine = engine
  }

  @discardableResult
  public func registerBuffer(
    id: VimBufferID,
    name: String,
    text: String,
    tabWidth: Int = 2,
    history: VimHistorySnapshot = VimHistorySnapshot()
  ) -> VimBufferInfo {
    engine.registerSessionBuffer(
      id: id,
      name: name,
      text: text,
      tabWidth: tabWidth,
      history: history
    )
  }

  public func updateBufferMetadata(
    id: VimBufferID,
    name: String? = nil,
    isLoaded: Bool? = nil,
    isModified: Bool? = nil,
    isListed: Bool? = nil
  ) {
    engine.updateSessionBufferMetadata(
      id: id,
      name: name,
      isLoaded: isLoaded,
      isModified: isModified,
      isListed: isListed
    )
  }

  public func bufferInfo(id: VimBufferID) -> VimBufferInfo? {
    engine.sessionBufferInfo(id: id)
  }

  public func bufferInfo(number: Int) -> VimBufferInfo? {
    engine.sessionBufferInfo(number: number)
  }

  public var listedBuffers: [VimBufferInfo] { engine.sessionListedBuffers }

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
    tabPageID: VimTabPageID? = nil,
    attachment: VimControllerAttachment = .activate
  ) -> VimKeymapController {
    lock.withLock {
      engine.leader = leader
      engine.localLeader = localLeader
      _ = registerBuffer(
        id: bufferID,
        name: name,
        text: text,
        tabWidth: tabWidth,
        history: history
      )
      _ = engine.ensureSessionView(
        windowID: windowID,
        bufferID: bufferID,
        cursor: cursor,
        tabPageID: tabPageID,
        attachment: attachment
      )

      if let controller = controllers[windowID] { return controller }
      let controller = VimKeymapController(sessionEngine: engine, windowID: windowID)
      controllers[windowID] = controller
      return controller
    }
  }

  @available(*, deprecated, message: "Use attachment: .activate or .retain")
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
    tabPageID: VimTabPageID? = nil,
    makeCurrent: Bool
  ) -> VimKeymapController {
    controller(
      for: windowID,
      displaying: bufferID,
      text: text,
      cursor: cursor,
      name: name,
      leader: leader,
      localLeader: localLeader,
      tabWidth: tabWidth,
      history: history,
      tabPageID: tabPageID,
      attachment: makeCurrent ? .activate : .retain
    )
  }

  public func existingController(
    for windowID: VimWindowID,
    displaying bufferID: VimBufferID
  ) -> VimKeymapController? {
    lock.withLock {
      guard engine.sessionViewID(windowID: windowID, bufferID: bufferID) != nil else {
        return nil
      }
      return controllers[windowID]
    }
  }

  public func view(
    for windowID: VimWindowID,
    displaying bufferID: VimBufferID
  ) -> VimEngineView? {
    guard let viewID = engine.sessionViewID(windowID: windowID, bufferID: bufferID) else {
      return nil
    }
    return engine.viewProjection(viewID)
  }

  public func currentBuffer(for windowID: VimWindowID) -> VimBufferID? {
    engine.currentSessionBuffer(for: windowID)
  }

  public func alternateBuffer(for windowID: VimWindowID) -> VimBufferID? {
    engine.alternateSessionBuffer(for: windowID)
  }

  @discardableResult
  public func switchBuffer(in windowID: VimWindowID, to bufferID: VimBufferID) -> Bool {
    engine.switchSessionBuffer(in: windowID, to: bufferID)
  }

  public func nextBuffer(after bufferID: VimBufferID, forward: Bool) -> VimBufferID? {
    engine.nextSessionBuffer(after: bufferID, forward: forward)
  }

  public func detachBuffer(_ bufferID: VimBufferID, from windowID: VimWindowID) {
    engine.detachSessionBuffer(bufferID, from: windowID)
  }

  public func removeWindow(_ windowID: VimWindowID) {
    lock.withLock {
      controllers.removeValue(forKey: windowID)
      engine.removeSessionWindow(windowID)
    }
  }

  public func unloadBuffer(_ bufferID: VimBufferID) {
    engine.unloadSessionBuffer(bufferID)
  }

  public func wipeBuffer(_ bufferID: VimBufferID) {
    engine.wipeSessionBuffer(bufferID)
  }

  public func bufferSnapshot(_ bufferID: VimBufferID) -> VimBufferSnapshot? {
    engine.sessionBufferSnapshot(bufferID)
  }

  public func runtimeSnapshot(
    for windowID: VimWindowID,
    displaying bufferID: VimBufferID
  ) -> VimViewRuntimeSnapshot? {
    engine.sessionViewRuntimeSnapshot(windowID: windowID, bufferID: bufferID)
  }

  @discardableResult
  public func restoreRuntimeSnapshot(
    _ snapshot: VimViewRuntimeSnapshot,
    for windowID: VimWindowID,
    displaying bufferID: VimBufferID
  ) -> Bool {
    engine.restoreSessionViewRuntimeSnapshot(
      snapshot,
      windowID: windowID,
      bufferID: bufferID
    )
  }

  public func applyExternalSnapshot(
    _ text: String,
    to bufferID: VimBufferID,
    baseRevision: UInt64
  ) -> VimBufferCommitResult {
    engine.applySessionExternalSnapshot(
      text,
      to: bufferID,
      baseRevision: baseRevision
    )
  }

  public func mergeHistory(_ history: VimHistorySnapshot) {
    engine.mergeSessionHistory(history)
  }

  public var historySnapshot: VimHistorySnapshot { engine.sessionHistorySnapshot }
}
