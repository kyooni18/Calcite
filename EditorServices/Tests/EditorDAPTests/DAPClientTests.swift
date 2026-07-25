import XCTest
@testable import EditorDAP

private actor AutoAdapter {
    var sequence = 100
    weak var session: DAPSession?
    func attach(_ session: DAPSession) { self.session = session }
    func write(_ framed: Data) async throws {
        var framer = DAPFramer()
        let request = try JSONDecoder().decode(DAPRequest.self, from: framer.append(framed).first!)
        sequence += 1
        let body: DAPValue
        switch request.command {
        case "initialize": body = ["supportsConfigurationDoneRequest": true, "supportsStepBack": true]
        case "threads": body = ["threads": [["id": 1, "name": "main"]]]
        default: body = [:]
        }
        try await session?.receive(try DAPFramer.frame(DAPResponse(seq: sequence, requestSeq: request.seq, success: true, command: request.command, body: body)))
    }
}

final class DAPClientTests: XCTestCase {
    func testLifecycleAndTypedThreads() async throws {
        let adapter = AutoAdapter()
        let session = DAPSession { try await adapter.write($0) }
        await adapter.attach(session)
        let client = DAPClient(session: session)
        let caps = try await client.initialize(.init(adapterID: "lldb"))
        XCTAssertEqual(caps.supportsStepBack, true)
        try await client.launch(["program": "/tmp/a"])
        try await client.configurationDone()
        let runningState = await client.state
        let threads = try await client.threads()
        XCTAssertEqual(runningState, .running)
        XCTAssertEqual(threads, [DAPThread(id: 1, name: "main")])
        try await client.disconnect()
        let disconnectedState = await client.state
        XCTAssertEqual(disconnectedState, .disconnected)
    }

    func testLaunchRequiresInitialization() async throws {
        let client = DAPClient(session: DAPSession { _ in })
        do { try await client.launch(["program": "x"]); XCTFail() }
        catch { XCTAssertEqual(error as? DebugClientError, .invalidState(expected: "initialized", actual: .disconnected)) }
    }

    func testStoppedEventUpdatesState() async throws {
        let adapter = AutoAdapter(), session = DAPSession { try await adapter.write($0) }
        await adapter.attach(session)
        let client = DAPClient(session: session)
        _ = try await client.initialize(.init(adapterID: "lldb"))
        try await session.receive(try DAPFramer.frame(DAPEvent(seq: 1, event: "stopped", body: ["reason": "breakpoint"])))
        try await Task.sleep(for: .milliseconds(10))
        let state = await client.state
        XCTAssertEqual(state, .stopped(reason: "breakpoint"))
    }
}
