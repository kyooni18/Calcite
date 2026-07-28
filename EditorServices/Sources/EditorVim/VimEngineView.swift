import Foundation

/// A stateless projection into one `(window, buffer)` view owned by a session
/// `VimEngine`. It deliberately contains identifiers only; every mutable value
/// remains in the root engine's session graph.
@_spi(Calcite)
public final class VimEngineView: @unchecked Sendable {
  let root: VimEngine
  public let viewID: VimViewID

  init(root: VimEngine, viewID: VimViewID) {
    self.root = root
    self.viewID = viewID
  }

  public var sessionEngine: VimEngine { root }

  public var state: VimState {
    get { root.withView(viewID) { root.state } }
    set { root.withView(viewID) { root.state = newValue } }
  }

  public var leader: String {
    get { root.leader }
    set { root.leader = newValue }
  }

  public var localLeader: String {
    get { root.localLeader }
    set { root.localLeader = newValue }
  }

  public var tabWidth: Int {
    get { root.withView(viewID) { root.tabWidth } }
    set { root.withView(viewID) { root.tabWidth = newValue } }
  }

  public var selectionSet: VimSelectionSet? {
    root.withView(viewID) { root.selectionSet }
  }

  public var windowPresentationState: VimWindowPresentationState {
    root.withView(viewID) { root.windowPresentationState }
  }

  var globalStateStorage: VimGlobalStateStorage { root.globalStateStorage }
  var windowStateStorage: VimWindowStateStorage {
    root.withView(viewID) { root.windowStateStorage }
  }

  var recording: Character? { root.withView(viewID) { root.recording } }
  var lastPlayedMacro: Character? { root.withView(viewID) { root.lastPlayedMacro } }
  var temporaryInsertReturnMode: VimMode? {
    root.withView(viewID) { root.temporaryInsertReturnMode }
  }

  @discardableResult
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    try root.withView(viewID, body)
  }

  public func synchronize(text: String, cursor: Int? = nil) {
    root.withView(viewID) { root.synchronize(text: text, cursor: cursor) }
  }

  @discardableResult
  public func execute(_ invocation: VimInvocation) throws -> VimExecutionResult {
    try root.withView(viewID) { try root.execute(invocation) }
  }

  @discardableResult
  public func execute(
    _ action: VimAction,
    count: Int = 1,
    register: VimRegister = .unnamed
  ) throws -> VimExecutionResult {
    try root.withView(viewID) { try root.execute(action, count: count, register: register) }
  }

  @discardableResult
  public func executeNotation(_ notation: String) throws -> VimExecutionResult {
    try root.withView(viewID) { try root.executeNotation(notation) }
  }

  func executeNotationToken(
    _ token: String,
    parser: inout VimCommandParser
  ) throws -> VimExecutionResult {
    try root.withView(viewID) { try root.executeNotationToken(token, parser: &parser) }
  }

  func executeKeyHandlingTransaction(
    _ body: () throws -> VimKeyHandlingResult
  ) rethrows -> VimKeyHandlingResult {
    try root.withView(viewID) { try root.executeKeyHandlingTransaction(body) }
  }

  func prepareVisualExRange() -> String? {
    root.withView(viewID) { root.prepareVisualExRange() }
  }

  func visualSelectionSnapshotUnlocked() -> VimVisualSelectionSnapshot? {
    root.withView(viewID) { root.visualSelectionSnapshotUnlocked() }
  }

  func consumeMessage() -> VimMessage? {
    root.withView(viewID) { root.consumeMessage() }
  }

  @_spi(Calcite)
  @discardableResult
  public func acceptHostCursorMove(
    toUTF16Offset offset: Int,
    source: VimHostCursorMoveSource
  ) -> VimState {
    root.withView(viewID) {
      root.acceptHostCursorMove(toUTF16Offset: offset, source: source)
    }
  }

  @_spi(Calcite)
  @discardableResult
  public func reconcileExternalText(
    _ text: String,
    cursor: Int? = nil
  ) -> VimExternalReconciliationResult {
    root.withView(viewID) { root.reconcileExternalText(text, cursor: cursor) }
  }

  @_spi(Calcite)
  public func installVisualGeometryProvider(
    _ provider: (any VimVisualGeometryProviding)?
  ) {
    root.withView(viewID) { root.installVisualGeometryProvider(provider) }
  }

  @_spi(Calcite)
  public func updateViewport(visibleUTF16Range: Range<Int>) {
    root.withView(viewID) { root.updateViewport(visibleUTF16Range: visibleUTF16Range) }
  }

  @_spi(Calcite)
  public func requestViewportScroll(lines: Int) {
    root.withView(viewID) { root.requestViewportScroll(lines: lines) }
  }

  @_spi(Calcite)
  public func consumeViewportScrollRequest() -> Int {
    root.withView(viewID) { root.consumeViewportScrollRequest() }
  }

  @_spi(Calcite)
  public func updateWindowPresentation(
    inputSourceIdentifier: String? = nil,
    updatesInputSource: Bool = false,
    horizontalScrollOffset: Double? = nil,
    verticalScrollOffset: Double? = nil,
    zoomScale: Double? = nil
  ) {
    root.withView(viewID) {
      root.updateWindowPresentation(
        inputSourceIdentifier: inputSourceIdentifier,
        updatesInputSource: updatesInputSource,
        horizontalScrollOffset: horizontalScrollOffset,
        verticalScrollOffset: verticalScrollOffset,
        zoomScale: zoomScale
      )
    }
  }

  @_spi(Calcite)
  public func consumeCompletedEdits() -> [(range: Range<Int>, replacement: String)] {
    root.withView(viewID) { root.consumeCompletedEdits() }
  }

  @_spi(Calcite)
  public func publishHostResponse(_ response: VimHostResponse) {
    root.withView(viewID) { root.publishHostResponse(response) }
  }

  public func register(_ register: VimRegister) -> String {
    root.withView(viewID) { root.register(register) }
  }

  public func setRegister(_ register: VimRegister, text: String) {
    root.withView(viewID) { root.setRegister(register, text: text) }
  }

  public func setMacro(_ name: Character, actions: [VimAction]) {
    root.withView(viewID) { root.setMacro(name, actions: actions) }
  }

  public func macro(_ name: Character) -> [VimAction] {
    root.withView(viewID) { root.macro(name) }
  }
}
