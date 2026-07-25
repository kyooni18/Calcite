import XCTest
@testable import EditorDAP

private actor WriteRecorder {
    private var writes: [Data] = []
    func append(_ data: Data) { writes.append(data) }
    func next() async -> Data {
        while writes.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        return writes.removeFirst()
    }
}

private func request(from framed: Data) throws -> DAPRequest {
    var framer = DAPFramer()
    return try JSONDecoder().decode(DAPRequest.self, from: framer.append(framed).first!)
}

final class DAPSessionTests: XCTestCase {
    func testRequestResponseCorrelation() async throws {
        let recorder = WriteRecorder()
        let session = DAPSession { await recorder.append($0) }
        let task = Task { try await session.request(command: "threads") }
        let outgoing = try request(from: await recorder.next())
        try await session.receive(try DAPFramer.frame(DAPResponse(seq: 9, requestSeq: outgoing.seq, success: true, command: "threads", body: ["threads": []])))
        let response = try await task.value
        XCTAssertEqual(response.command, "threads")
        let pendingCount = await session.pendingRequestCount
        XCTAssertEqual(pendingCount, 0)
    }

    func testFailedResponseThrowsTypedError() async throws {
        let recorder = WriteRecorder(), session = DAPSession { await recorder.append($0) }
        let task = Task { try await session.request(command: "launch") }
        let outgoing = try request(from: await recorder.next())
        try await session.receive(try DAPFramer.frame(DAPResponse(seq: 2, requestSeq: outgoing.seq, success: false, command: "launch", message: "bad")))
        do { _ = try await task.value; XCTFail() }
        catch { XCTAssertEqual(error as? DAPError, .requestFailed(command: "launch", message: "bad")) }
    }

    func testCommandMismatchFailsRequestAndReceive() async throws {
        let recorder = WriteRecorder(), session = DAPSession { await recorder.append($0) }
        let task = Task { try await session.request(command: "threads") }
        let outgoing = try request(from: await recorder.next())
        do { try await session.receive(try DAPFramer.frame(DAPResponse(seq: 2, requestSeq: outgoing.seq, success: true, command: "stackTrace"))); XCTFail() }
        catch { XCTAssertEqual(error as? DAPError, .responseCommandMismatch(expected: "threads", received: "stackTrace")) }
        do { _ = try await task.value; XCTFail() } catch {}
    }

    func testOrphanResponseIsRejected() async throws {
        let session = DAPSession { _ in }
        do { try await session.receive(try DAPFramer.frame(DAPResponse(seq: 2, requestSeq: 99, success: true, command: "x"))); XCTFail() }
        catch { XCTAssertEqual(error as? DAPError, .orphanResponse(99)) }
    }

    func testTimeoutIgnoresLateResponseAndSessionContinues() async throws {
        let recorder = WriteRecorder(), session = DAPSession { await recorder.append($0) }
        let first = Task { try await session.request(command: "slow", timeout: .milliseconds(10)) }
        let firstRequest = try request(from: await recorder.next())
        do { _ = try await first.value; XCTFail() } catch { XCTAssertEqual(error as? DAPError, .timeout(command: "slow")) }
        try await session.receive(try DAPFramer.frame(DAPResponse(seq: 2, requestSeq: firstRequest.seq, success: true, command: "slow")))
        let second = Task { try await session.request(command: "next") }
        let secondRequest = try request(from: await recorder.next())
        try await session.receive(try DAPFramer.frame(DAPResponse(seq: 3, requestSeq: secondRequest.seq, success: true, command: "next")))
        let secondResponse = try await second.value
        XCTAssertEqual(secondResponse.command, "next")
    }

    func testEventStream() async throws {
        let session = DAPSession { _ in }
        let task = Task { for await event in session.events { return event }; throw DAPError.disconnected }
        try await session.receive(try DAPFramer.frame(DAPEvent(seq: 1, event: "stopped", body: ["reason": "breakpoint"])))
        let event = try await task.value
        XCTAssertEqual(event.event, "stopped")
    }

    func testReverseRequestAndResponse() async throws {
        let recorder = WriteRecorder(), session = DAPSession { await recorder.append($0) }
        let event = Task { for await request in session.reverseRequests { return request }; throw DAPError.disconnected }
        try await session.receive(try DAPFramer.frame(DAPRequest(seq: 42, command: "runInTerminal", arguments: ["kind": "integrated"])))
        let reverse = try await event.value
        try await session.respond(to: reverse, body: ["processId": 123])
        var framer = DAPFramer()
        let payload = try framer.append(await recorder.next()).first!
        let response = try JSONDecoder().decode(DAPResponse.self, from: payload)
        XCTAssertEqual(response.requestSeq, 42)
    }

    func testDisconnectFailsPending() async throws {
        let recorder = WriteRecorder(), session = DAPSession { await recorder.append($0) }
        let task = Task { try await session.request(command: "threads") }
        _ = await recorder.next()
        await session.disconnect()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? DAPError, .disconnected) }
    }

    func testCancellationIsTyped() async throws {
        let recorder = WriteRecorder(), session = DAPSession { await recorder.append($0) }
        let task = Task { try await session.request(command: "threads") }
        _ = await recorder.next(); task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? DAPError, .cancelled(command: "threads")) }
    }

    func testSequenceWraps() async throws {
        let recorder = WriteRecorder(), session = DAPSession(initialSequence: Int.max) { await recorder.append($0) }
        let one = Task { try await session.request(command: "one") }
        let r1 = try request(from: await recorder.next())
        XCTAssertEqual(r1.seq, Int.max)
        try await session.receive(try DAPFramer.frame(DAPResponse(seq: 2, requestSeq: r1.seq, success: true, command: "one")))
        _ = try await one.value
        let two = Task { try await session.request(command: "two") }
        let r2 = try request(from: await recorder.next())
        XCTAssertEqual(r2.seq, 1)
        try await session.receive(try DAPFramer.frame(DAPResponse(seq: 3, requestSeq: r2.seq, success: true, command: "two")))
        _ = try await two.value
    }
    func testTimeoutStartsBeforeBlockedWriterCompletes() async throws {
        let session = DAPSession { _ in
            try await Task.sleep(for: .seconds(60))
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await session.request(command: "blocked", timeout: .milliseconds(20))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? DAPError, .timeout(command: "blocked"))
        }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testLateResponseRetentionIsBounded() async throws {
        let session = DAPSession(lateResponseRetentionLimit: 2) { _ in }
        for index in 0..<3 {
            do {
                _ = try await session.request(command: "slow-\(index)", timeout: .milliseconds(2))
                XCTFail("Expected timeout")
            } catch {
                XCTAssertEqual(error as? DAPError, .timeout(command: "slow-\(index)"))
            }
        }
        let retained = await session.retainedLateResponseCount
        XCTAssertEqual(retained, 2)
    }

}
