import Foundation

public actor DAPSession {
    public typealias Writer = @Sendable (Data) async throws -> Void

    private struct Pending {
        let command: String
        let continuation: CheckedContinuation<DAPResponse, Error>
    }

    private let writer: Writer
    private var framer: DAPFramer
    private var nextSequence: Int
    private var pending: [Int: Pending] = [:]
    private var writeTasks: [Int: Task<Void, Never>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var ignoredLateResponses: Set<Int> = []
    private var ignoredLateResponseOrder: [Int] = []
    private let lateResponseRetentionLimit: Int
    private var disconnected = false
    private let eventContinuation: AsyncStream<DAPEvent>.Continuation
    private let reverseContinuation: AsyncStream<DAPRequest>.Continuation
    public nonisolated let events: AsyncStream<DAPEvent>
    public nonisolated let reverseRequests: AsyncStream<DAPRequest>

    public init(
        framer: DAPFramer = DAPFramer(),
        initialSequence: Int = 1,
        writer: @escaping Writer
    ) {
        self.init(
            framer: framer,
            initialSequence: initialSequence,
            lateResponseRetentionLimit: 1024,
            writer: writer
        )
    }

    public init(
        framer: DAPFramer = DAPFramer(),
        initialSequence: Int = 1,
        lateResponseRetentionLimit: Int,
        writer: @escaping Writer
    ) {
        self.writer = writer
        self.framer = framer
        self.nextSequence = max(1, initialSequence)
        self.lateResponseRetentionLimit = max(1, lateResponseRetentionLimit)
        (events, eventContinuation) = AsyncStream.makeStream(of: DAPEvent.self)
        (reverseRequests, reverseContinuation) = AsyncStream.makeStream(of: DAPRequest.self)
    }

    deinit {
        for task in writeTasks.values { task.cancel() }
        for task in timeoutTasks.values { task.cancel() }
        eventContinuation.finish()
        reverseContinuation.finish()
    }

    public func request(
        command: String,
        arguments: DAPValue? = nil,
        timeout: Duration? = nil
    ) async throws -> DAPResponse {
        guard !command.isEmpty else { throw DAPError.emptyCommand }
        guard !disconnected else { throw DAPError.disconnected }
        let sequence = try allocateSequence()
        let request = DAPRequest(seq: sequence, command: command, arguments: arguments)
        let framed = try DAPFramer.frame(request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[sequence] = Pending(command: command, continuation: continuation)

                let writeTask = Task { [writer] in
                    do {
                        try await writer(framed)
                        self.writerFinished(sequence: sequence)
                    } catch is CancellationError {
                        self.writerCancelled(sequence: sequence, command: command)
                    } catch {
                        self.writerFailed(sequence: sequence, error: error)
                    }
                }
                writeTasks[sequence] = writeTask

                if let timeout {
                    timeoutTasks[sequence] = Task {
                        do {
                            try await Task.sleep(for: timeout)
                            self.expire(sequence: sequence, command: command)
                        } catch {
                            // Cancellation means the request completed or was cancelled first.
                        }
                    }
                }
            }
        } onCancel: {
            Task { await self.cancel(sequence: sequence, command: command) }
        }
    }

    public func request<Arguments: Encodable & Sendable, Body: Decodable & Sendable>(
        command: String,
        arguments: Arguments,
        response: Body.Type = Body.self,
        timeout: Duration? = nil
    ) async throws -> Body {
        let raw = try DAPValue.encode(arguments)
        let result = try await request(command: command, arguments: raw, timeout: timeout)
        return try (result.body ?? .object([:])).decode(Body.self)
    }

    public func receive(_ data: Data) throws {
        for payload in try framer.append(data) { try receivePayload(payload) }
    }

    public func respond(
        to request: DAPRequest,
        success: Bool = true,
        message: String? = nil,
        body: DAPValue? = nil
    ) async throws {
        guard request.type == "request", request.seq > 0 else {
            throw DAPError.invalidReverseRequest(request.seq)
        }
        let sequence = try allocateSequence()
        try await writer(try DAPFramer.frame(DAPResponse(
            seq: sequence,
            requestSeq: request.seq,
            success: success,
            command: request.command,
            message: message,
            body: body
        )))
    }

    public func disconnect() {
        guard !disconnected else { return }
        disconnected = true
        let current = pending
        pending.removeAll()
        for task in writeTasks.values { task.cancel() }
        for task in timeoutTasks.values { task.cancel() }
        writeTasks.removeAll()
        timeoutTasks.removeAll()
        for value in current.values { value.continuation.resume(throwing: DAPError.disconnected) }
        eventContinuation.finish()
        reverseContinuation.finish()
    }

    public var pendingRequestCount: Int { pending.count }
    public var retainedLateResponseCount: Int { ignoredLateResponses.count }

    private func receivePayload(_ payload: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = object["type"] as? String else {
            throw DAPError.invalidMessage
        }
        switch type {
        case "response":
            let response = try JSONDecoder().decode(DAPResponse.self, from: payload)
            if ignoredLateResponses.remove(response.requestSeq) != nil {
                ignoredLateResponseOrder.removeAll { $0 == response.requestSeq }
                return
            }
            guard let item = pending.removeValue(forKey: response.requestSeq) else {
                throw DAPError.orphanResponse(response.requestSeq)
            }
            finishTasks(for: response.requestSeq)
            guard response.command == item.command else {
                let error = DAPError.responseCommandMismatch(expected: item.command, received: response.command)
                item.continuation.resume(throwing: error)
                throw error
            }
            if response.success {
                item.continuation.resume(returning: response)
            } else {
                item.continuation.resume(throwing: DAPError.requestFailed(
                    command: response.command,
                    message: response.message
                ))
            }
        case "event":
            eventContinuation.yield(try JSONDecoder().decode(DAPEvent.self, from: payload))
        case "request":
            reverseContinuation.yield(try JSONDecoder().decode(DAPRequest.self, from: payload))
        default:
            throw DAPError.invalidMessage
        }
    }

    private func allocateSequence() throws -> Int {
        let start = nextSequence
        repeat {
            let candidate = nextSequence
            nextSequence = nextSequence == Int.max ? 1 : nextSequence + 1
            if pending[candidate] == nil && !ignoredLateResponses.contains(candidate) { return candidate }
        } while nextSequence != start
        throw DAPError.sequenceSpaceExhausted
    }

    private func writerFinished(sequence: Int) {
        writeTasks.removeValue(forKey: sequence)
    }

    private func writerCancelled(sequence: Int, command: String) {
        writeTasks.removeValue(forKey: sequence)
        guard pending[sequence] != nil else { return }
        cancel(sequence: sequence, command: command)
    }

    private func writerFailed(sequence: Int, error: Error) {
        writeTasks.removeValue(forKey: sequence)
        guard let item = pending.removeValue(forKey: sequence) else { return }
        timeoutTasks.removeValue(forKey: sequence)?.cancel()
        item.continuation.resume(throwing: error)
    }

    private func expire(sequence: Int, command: String) {
        timeoutTasks.removeValue(forKey: sequence)
        guard let item = pending.removeValue(forKey: sequence) else { return }
        writeTasks.removeValue(forKey: sequence)?.cancel()
        retainLateResponse(sequence)
        item.continuation.resume(throwing: DAPError.timeout(command: command))
    }

    private func cancel(sequence: Int, command: String) {
        guard let item = pending.removeValue(forKey: sequence) else { return }
        writeTasks.removeValue(forKey: sequence)?.cancel()
        timeoutTasks.removeValue(forKey: sequence)?.cancel()
        retainLateResponse(sequence)
        item.continuation.resume(throwing: DAPError.cancelled(command: command))
    }

    private func retainLateResponse(_ sequence: Int) {
        guard ignoredLateResponses.insert(sequence).inserted else { return }
        ignoredLateResponseOrder.append(sequence)
        while ignoredLateResponseOrder.count > lateResponseRetentionLimit {
            ignoredLateResponses.remove(ignoredLateResponseOrder.removeFirst())
        }
    }

    private func finishTasks(for sequence: Int) {
        writeTasks.removeValue(forKey: sequence)?.cancel()
        timeoutTasks.removeValue(forKey: sequence)?.cancel()
    }
}
