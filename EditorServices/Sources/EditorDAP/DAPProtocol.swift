import Foundation

public struct DAPRequest: Codable, Hashable, Sendable {
    public let seq: Int
    public let type: String
    public let command: String
    public let arguments: DAPValue?
    public init(seq: Int, command: String, arguments: DAPValue? = nil) {
        self.seq = seq; self.type = "request"; self.command = command; self.arguments = arguments
    }
}

public struct DAPResponse: Codable, Hashable, Sendable {
    public let seq: Int
    public let type: String
    public let requestSeq: Int
    public let success: Bool
    public let command: String
    public let message: String?
    public let body: DAPValue?
    public init(seq: Int, requestSeq: Int, success: Bool, command: String, message: String? = nil, body: DAPValue? = nil) {
        self.seq = seq; self.type = "response"; self.requestSeq = requestSeq; self.success = success
        self.command = command; self.message = message; self.body = body
    }
    enum CodingKeys: String, CodingKey { case seq, type, requestSeq = "request_seq", success, command, message, body }
}

public struct DAPEvent: Codable, Hashable, Sendable {
    public let seq: Int
    public let type: String
    public let event: String
    public let body: DAPValue?
    public init(seq: Int, event: String, body: DAPValue? = nil) {
        self.seq = seq; self.type = "event"; self.event = event; self.body = body
    }
}

public enum DAPIncoming: Hashable, Sendable { case response(DAPResponse), event(DAPEvent), request(DAPRequest) }

public enum DAPError: Error, Equatable, Sendable {
    case malformedHeader
    case invalidContentLength
    case headerTooLarge
    case messageTooLarge
    case invalidMessage
    case disconnected
    case requestFailed(command: String, message: String?)
    case duplicateResponse(Int)
    case orphanResponse(Int)
    case responseCommandMismatch(expected: String, received: String)
    case timeout(command: String)
    case cancelled(command: String)
    case emptyCommand
    case invalidReverseRequest(Int)
    case sequenceSpaceExhausted
}
