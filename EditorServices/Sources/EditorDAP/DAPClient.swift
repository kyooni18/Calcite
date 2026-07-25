import Foundation

public enum DebugSessionState: Hashable, Sendable {
  case disconnected, initializing, initialized, configuring, running
  case stopped(reason: String?)
  case terminated
}

public enum DebugClientError: Error, Equatable, Sendable {
  case invalidState(expected: String, actual: DebugSessionState)
  case unsupportedCapability(String)
}

public actor DAPClient {
  private let session: DAPSession
  public nonisolated let requestTimeout: Duration
  private var eventTask: Task<Void, Never>?
  private let eventContinuation: AsyncStream<DAPEvent>.Continuation
  public nonisolated let events: AsyncStream<DAPEvent>
  public private(set) var state: DebugSessionState = .disconnected
  public private(set) var capabilities: Capabilities?

  public init(session: DAPSession, requestTimeout: Duration = .seconds(30)) {
    self.session = session
    self.requestTimeout = requestTimeout
    (events, eventContinuation) = AsyncStream.makeStream(of: DAPEvent.self)
  }

  deinit {
    eventTask?.cancel()
    eventContinuation.finish()
  }

  public func startEventMonitoring() {
    guard eventTask == nil else { return }
    eventTask = Task { [session] in
      for await event in session.events {
        self.handle(event)
      }
    }
  }

  public func initialize(
    _ arguments: InitializeArguments,
    timeout: Duration? = nil
  ) async throws -> Capabilities {
    guard state == .disconnected else {
      throw DebugClientError.invalidState(expected: "disconnected", actual: state)
    }
    state = .initializing
    startEventMonitoring()
    do {
      let result: Capabilities = try await request(
        command: "initialize",
        arguments: arguments,
        timeout: timeout
      )
      capabilities = result
      // Some adapters emit `initialized` unusually early. `launch` and `attach`
      // accept both initialized/configuring so that event ordering cannot deadlock setup.
      if state == .initializing { state = .initialized }
      return result
    } catch {
      state = .disconnected
      throw error
    }
  }

  public func launch<Arguments: Encodable & Sendable>(_ arguments: Arguments) async throws {
    try requireOneOf([.initialized, .configuring], expected: "initialized")
    _ = try await typedVoid("launch", arguments)
    state = .configuring
  }

  public func attach<Arguments: Encodable & Sendable>(_ arguments: Arguments) async throws {
    try requireOneOf([.initialized, .configuring], expected: "initialized")
    _ = try await typedVoid("attach", arguments)
    state = .configuring
  }

  public func configurationDone() async throws {
    try requireOneOf([.configuring, .initialized], expected: "configuring")
    if capabilities?.supportsConfigurationDoneRequest == true {
      _ = try await typedVoid("configurationDone", EmptyArguments())
    }
    state = .running
  }

  public func setBreakpoints(_ arguments: SetBreakpointsArguments) async throws -> [Breakpoint] {
    try requireActive()
    if arguments.breakpoints.contains(where: { $0.condition != nil }),
      capabilities?.supportsConditionalBreakpoints != true
    {
      throw DebugClientError.unsupportedCapability("supportsConditionalBreakpoints")
    }
    if arguments.breakpoints.contains(where: { $0.hitCondition != nil }),
      capabilities?.supportsHitConditionalBreakpoints != true
    {
      throw DebugClientError.unsupportedCapability("supportsHitConditionalBreakpoints")
    }
    let body: SetBreakpointsResponseBody = try await request(
      command: "setBreakpoints", arguments: arguments)
    return body.breakpoints
  }

  public func setFunctionBreakpoints(_ breakpoints: [FunctionBreakpoint]) async throws
    -> [Breakpoint]
  {
    try requireCapability(
      capabilities?.supportsFunctionBreakpoints, named: "supportsFunctionBreakpoints")
    let body: SetBreakpointsResponseBody = try await request(
      command: "setFunctionBreakpoints",
      arguments: SetFunctionBreakpointsArguments(breakpoints: breakpoints)
    )
    return body.breakpoints
  }

  public func setExceptionBreakpoints(_ filters: [String]) async throws {
    try requireActive()
    _ = try await typedVoid(
      "setExceptionBreakpoints", SetExceptionBreakpointsArguments(filters: filters))
  }

  public func threads() async throws -> [DAPThread] {
    try requireActive()
    let body: ThreadsResponseBody = try await request(
      command: "threads", arguments: EmptyArguments())
    return body.threads
  }

  public func stackTrace(threadId: Int, startFrame: Int? = nil, levels: Int? = nil) async throws
    -> StackTraceResponseBody
  {
    try requireActive()
    return try await request(
      command: "stackTrace",
      arguments: StackTraceArguments(threadId: threadId, startFrame: startFrame, levels: levels)
    )
  }

  public func scopes(frameId: Int) async throws -> [Scope] {
    try requireActive()
    let body: ScopesResponseBody = try await request(
      command: "scopes", arguments: ScopesArguments(frameId: frameId))
    return body.scopes
  }

  public func variables(reference: Int, filter: String? = nil, start: Int? = nil, count: Int? = nil)
    async throws -> [Variable]
  {
    try requireActive()
    let body: VariablesResponseBody = try await request(
      command: "variables",
      arguments: VariablesArguments(
        variablesReference: reference, filter: filter, start: start, count: count)
    )
    return body.variables
  }

  public func setVariable(reference: Int, name: String, value: String) async throws
    -> SetVariableResponseBody
  {
    try requireCapability(capabilities?.supportsSetVariable, named: "supportsSetVariable")
    return try await request(
      command: "setVariable",
      arguments: SetVariableArguments(variablesReference: reference, name: name, value: value)
    )
  }

  public func evaluate(_ expression: String, frameId: Int? = nil, context: String? = nil)
    async throws -> EvaluateResponseBody
  {
    try requireActive()
    return try await request(
      command: "evaluate",
      arguments: EvaluateArguments(expression: expression, frameId: frameId, context: context)
    )
  }

  public func exceptionInfo(threadId: Int) async throws -> ExceptionInfoResponseBody {
    try requireCapability(
      capabilities?.supportsExceptionInfoRequest, named: "supportsExceptionInfoRequest")
    return try await request(
      command: "exceptionInfo", arguments: ExceptionInfoArguments(threadId: threadId))
  }

  public func source(reference: Int, source: Source? = nil) async throws -> SourceResponseBody {
    try requireActive()
    return try await request(
      command: "source",
      arguments: SourceArguments(source: source, sourceReference: reference)
    )
  }

  public func modules(start: Int? = nil, count: Int? = nil) async throws -> ModulesResponseBody {
    try requireCapability(capabilities?.supportsModulesRequest, named: "supportsModulesRequest")
    return try await request(
      command: "modules", arguments: ModulesArguments(startModule: start, moduleCount: count))
  }

  public func loadedSources() async throws -> [Source] {
    try requireCapability(
      capabilities?.supportsLoadedSourcesRequest, named: "supportsLoadedSourcesRequest")
    let body: LoadedSourcesResponseBody = try await request(
      command: "loadedSources", arguments: EmptyArguments())
    return body.sources
  }

  public func continueExecution(threadId: Int, singleThread: Bool? = nil) async throws
    -> ContinueResponseBody
  {
    try requireStopped()
    let result: ContinueResponseBody = try await request(
      command: "continue",
      arguments: ThreadControlArguments(threadId: threadId, singleThread: singleThread)
    )
    state = .running
    return result
  }

  public func pause(threadId: Int) async throws {
    try requireOneOf([.running], expected: "running")
    _ = try await typedVoid("pause", ThreadControlArguments(threadId: threadId))
  }

  public func next(threadId: Int, singleThread: Bool? = nil) async throws {
    try requireStopped()
    _ = try await typedVoid(
      "next", ThreadControlArguments(threadId: threadId, singleThread: singleThread))
    state = .running
  }

  public func stepIn(threadId: Int, singleThread: Bool? = nil) async throws {
    try requireStopped()
    _ = try await typedVoid(
      "stepIn", ThreadControlArguments(threadId: threadId, singleThread: singleThread))
    state = .running
  }

  public func stepOut(threadId: Int, singleThread: Bool? = nil) async throws {
    try requireStopped()
    _ = try await typedVoid(
      "stepOut", ThreadControlArguments(threadId: threadId, singleThread: singleThread))
    state = .running
  }

  public func stepBack(threadId: Int, singleThread: Bool? = nil) async throws {
    try requireCapability(capabilities?.supportsStepBack, named: "supportsStepBack")
    try requireStopped()
    _ = try await typedVoid(
      "stepBack", ThreadControlArguments(threadId: threadId, singleThread: singleThread))
    state = .running
  }

  public func reverseContinue(threadId: Int, singleThread: Bool? = nil) async throws {
    try requireCapability(capabilities?.supportsStepBack, named: "supportsStepBack")
    try requireStopped()
    _ = try await typedVoid(
      "reverseContinue", ThreadControlArguments(threadId: threadId, singleThread: singleThread))
    state = .running
  }

  public func restartFrame(_ frameId: Int) async throws {
    try requireCapability(capabilities?.supportsRestartFrame, named: "supportsRestartFrame")
    try requireStopped()
    _ = try await typedVoid("restartFrame", RestartFrameArguments(frameId: frameId))
    state = .running
  }

  public func restart<Arguments: Encodable & Sendable>(_ arguments: Arguments) async throws {
    try requireCapability(capabilities?.supportsRestartRequest, named: "supportsRestartRequest")
    try requireActive()
    _ = try await typedVoid("restart", arguments)
    state = .running
  }

  public func terminate() async throws {
    try requireCapability(capabilities?.supportsTerminateRequest, named: "supportsTerminateRequest")
    try requireActive()
    _ = try await typedVoid("terminate", EmptyArguments())
    state = .terminated
  }

  public func disconnect(_ arguments: DisconnectArguments = .init()) async throws {
    guard state != .disconnected else { return }
    _ = try await typedVoid("disconnect", arguments)
    await session.disconnect()
    state = .disconnected
  }

  public func rawRequest(
    command: String,
    arguments: DAPValue? = nil,
    timeout: Duration? = nil
  ) async throws -> DAPResponse {
    try requireActive()
    return try await request(command: command, arguments: arguments, timeout: timeout)
  }

  private func request(
    command: String,
    arguments: DAPValue? = nil,
    timeout: Duration? = nil
  ) async throws -> DAPResponse {
    try await session.request(
      command: command,
      arguments: arguments,
      timeout: timeout ?? requestTimeout
    )
  }

  private func request<Arguments: Encodable & Sendable, Body: Decodable & Sendable>(
    command: String,
    arguments: Arguments,
    response: Body.Type = Body.self,
    timeout: Duration? = nil
  ) async throws -> Body {
    try await session.request(
      command: command,
      arguments: arguments,
      response: response,
      timeout: timeout ?? requestTimeout
    )
  }

  private func typedVoid<Arguments: Encodable & Sendable>(
    _ command: String,
    _ arguments: Arguments
  ) async throws -> DAPValue {
    try await request(command: command, arguments: arguments, response: DAPValue.self)
  }

  private func requireActive() throws {
    switch state {
    case .initialized, .configuring, .running, .stopped:
      return
    case .disconnected, .initializing, .terminated:
      throw DebugClientError.invalidState(expected: "active debug session", actual: state)
    }
  }

  private func requireStopped() throws {
    guard case .stopped = state else {
      throw DebugClientError.invalidState(expected: "stopped", actual: state)
    }
  }

  private func requireCapability(_ supported: Bool?, named name: String) throws {
    try requireActive()
    guard supported == true else { throw DebugClientError.unsupportedCapability(name) }
  }

  private func requireOneOf(_ allowed: [DebugSessionState], expected: String) throws {
    guard allowed.contains(state) else {
      throw DebugClientError.invalidState(expected: expected, actual: state)
    }
  }

  private func handle(_ event: DAPEvent) {
    eventContinuation.yield(event)
    switch event.event {
    case "initialized":
      if state == .initializing || state == .initialized { state = .configuring }
    case "stopped":
      var reason: String?
      if case .object(let body) = event.body, case .string(let value) = body["reason"] {
        reason = value
      }
      state = .stopped(reason: reason)
    case "continued":
      state = .running
    case "terminated", "exited":
      state = .terminated
    default:
      break
    }
  }
}
