import Foundation

public struct DAPReverseRequestResponse: Hashable, Sendable {
  public var success: Bool
  public var message: String?
  public var body: DAPValue?

  public init(success: Bool, message: String? = nil, body: DAPValue? = nil) {
    self.success = success
    self.message = message
    self.body = body
  }

  public static func succeeded(body: DAPValue? = nil) -> Self {
    .init(success: true, body: body)
  }

  public static func failed(_ message: String) -> Self {
    .init(success: false, message: message)
  }
}

public protocol DAPReverseRequestHandler: Sendable {
  func handleReverseRequest(_ request: DAPRequest) async -> DAPReverseRequestResponse
}

public struct RunInTerminalArguments: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Hashable, Sendable {
    case integrated
    case external
  }

  public var kind: Kind?
  public var title: String?
  public var cwd: String
  public var args: [String]
  public var env: [String: String]?
  public var argsCanBeInterpretedByShell: Bool?

  public init(
    kind: Kind? = nil,
    title: String? = nil,
    cwd: String,
    args: [String],
    env: [String: String]? = nil,
    argsCanBeInterpretedByShell: Bool? = nil
  ) {
    self.kind = kind
    self.title = title
    self.cwd = cwd
    self.args = args
    self.env = env
    self.argsCanBeInterpretedByShell = argsCanBeInterpretedByShell
  }
}

public struct RunInTerminalResponseBody: Codable, Hashable, Sendable {
  public var processId: Int?
  public var shellProcessId: Int?

  public init(processId: Int? = nil, shellProcessId: Int? = nil) {
    self.processId = processId
    self.shellProcessId = shellProcessId
  }
}
