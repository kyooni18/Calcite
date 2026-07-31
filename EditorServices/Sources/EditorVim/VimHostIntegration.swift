import Foundation

@_spi(Calcite)
public enum VimHostCapability: String, Hashable, Sendable, Codable, CaseIterable {
  case write
  case quit
  case buffers
  case tabs
  case splits
  case scrolling
  case completion
  case definition
  case declaration
  case references
  case hover
  case rename
  case codeAction
  case formatting
  case shell
  case custom
  case openFile
}

@_spi(Calcite)
public struct VimHostCapabilities: Hashable, Sendable {
  public var values: Set<VimHostCapability>

  public init(_ values: Set<VimHostCapability> = []) {
    self.values = values
  }

  public static let none = VimHostCapabilities()
  public static let all = VimHostCapabilities(Set(VimHostCapability.allCases))

  public func supports(_ request: VimHostRequest) -> Bool {
    if case .writeAndQuit = request {
      return values.contains(.write) && values.contains(.quit)
    }
    return values.contains(Self.capability(for: request))
  }

  public static func capability(for request: VimHostRequest) -> VimHostCapability {
    switch request {
    case .write, .writeAndQuit: return .write
    case .quit, .closeWindow, .closeTab: return .quit
    case .openFile: return .openFile
    case .switchBuffer: return .buffers
    case .split, .focusWindow, .cycleWindow, .focusPreviousWindow, .closeOtherWindows, .newWindow: return .splits
    case .nextTab, .previousTab, .newTab: return .tabs
    case .scroll: return .scrolling
    case .definition: return .definition
    case .declaration: return .declaration
    case .references: return .references
    case .hover: return .hover
    case .rename: return .rename
    case .codeAction: return .codeAction
    case .format: return .formatting
    case .completion: return .completion
    case .shell: return .shell
    case .custom: return .custom
    }
  }
}

@_spi(Calcite)
public struct VimHostInvocationContext: Hashable, Sendable {
  public var documentURL: URL?
  public var editorSessionID: UUID?
  public var bufferID: VimBufferID?
  public var windowID: VimWindowID?
  public var tabPageID: VimTabPageID?
  public var selection: VimSelection?
  public var revision: VimDocumentRevision?

  public init(
    documentURL: URL? = nil,
    editorSessionID: UUID? = nil,
    bufferID: VimBufferID? = nil,
    windowID: VimWindowID? = nil,
    tabPageID: VimTabPageID? = nil,
    selection: VimSelection? = nil,
    revision: VimDocumentRevision? = nil
  ) {
    self.documentURL = documentURL
    self.editorSessionID = editorSessionID
    self.bufferID = bufferID
    self.windowID = windowID
    self.tabPageID = tabPageID
    self.selection = selection
    self.revision = revision
  }
}

@_spi(Calcite)
public struct VimHostInvocation: Hashable, Sendable {
  public var id: UUID
  public var request: VimHostRequest
  public var context: VimHostInvocationContext

  public init(
    id: UUID = UUID(),
    request: VimHostRequest,
    context: VimHostInvocationContext = VimHostInvocationContext()
  ) {
    self.id = id
    self.request = request
    self.context = context
  }
}

@_spi(Calcite)
public enum VimHostFailure: Hashable, Sendable {
  case unsupportedCapability(VimHostCapability)
  case staleContext
  case cancelled
  case failed(code: String, message: String)
}

@_spi(Calcite)
public enum VimHostResponse: Hashable, Sendable {
  case accepted
  case completed(message: String?)
  case rejected(VimHostFailure)

  public var message: VimMessage? {
    switch self {
    case .accepted:
      return nil
    case .completed(let message):
      return message.map {
        VimMessage(
          text: $0,
          code: "HOST_OK",
          severity: .information,
          lifetime: .timed(milliseconds: 1800)
        )
      }
    case .rejected(.unsupportedCapability(let capability)):
      return VimMessage(
        text: "Host does not support \(capability.rawValue)",
        code: "HOST_UNSUPPORTED",
        severity: .warning,
        lifetime: .timed(milliseconds: 2600)
      )
    case .rejected(.staleContext):
      return VimMessage(
        text: "The originating editor is no longer active",
        code: "HOST_STALE_CONTEXT",
        severity: .warning,
        lifetime: .timed(milliseconds: 2600)
      )
    case .rejected(.cancelled):
      return VimMessage(
        text: "Host action was cancelled",
        code: "HOST_CANCELLED",
        severity: .information,
        lifetime: .timed(milliseconds: 1800)
      )
    case .rejected(.failed(let code, let message)):
      return VimMessage(
        text: message,
        code: code,
        severity: .error,
        lifetime: .timed(milliseconds: 3200)
      )
    }
  }
}

@_spi(Calcite)
public protocol VimHostHandling: Sendable {
  var capabilities: VimHostCapabilities { get }
  func handle(_ invocation: VimHostInvocation) async -> VimHostResponse
}

extension VimEngine {
  @_spi(Calcite)
  public func publishHostResponse(_ response: VimHostResponse) {
    guard let message = response.message else { return }
    lock.withLock { publishMessage(message) }
  }
}
