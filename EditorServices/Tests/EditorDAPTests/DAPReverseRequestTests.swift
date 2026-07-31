import Foundation
import XCTest

@testable import EditorDAP

private actor ReverseRequestRecorder: DAPReverseRequestHandler {
  private(set) var requests: [DAPRequest] = []

  func handleReverseRequest(_ request: DAPRequest) async -> DAPReverseRequestResponse {
    requests.append(request)
    return .succeeded(body: .object(["processId": .integer(42)]))
  }

  func count() -> Int { requests.count }
}

private actor WrittenFrames {
  private var values: [Data] = []
  func append(_ value: Data) { values.append(value) }
  func first() -> Data? { values.first }
}

final class DAPReverseRequestTests: XCTestCase {
  func testRunInTerminalArgumentsRoundTrip() throws {
    let value = RunInTerminalArguments(
      kind: .integrated,
      title: "Demo",
      cwd: "/tmp",
      args: ["/bin/echo", "hello world"],
      env: ["TERM": "xterm-256color"],
      argsCanBeInterpretedByShell: false
    )

    let decoded = try DAPValue.encode(value).decode(RunInTerminalArguments.self)
    XCTAssertEqual(decoded, value)
  }

  func testClientRespondsToReverseRequestThroughHost() async throws {
    let frames = WrittenFrames()
    let session = DAPSession { data in await frames.append(data) }
    let handler = ReverseRequestRecorder()
    let client = DAPClient(session: session, reverseRequestHandler: handler)
    await client.startEventMonitoring()

    let request = DAPRequest(
      seq: 77,
      command: "runInTerminal",
      arguments: try DAPValue.encode(
        RunInTerminalArguments(cwd: "/tmp", args: ["/bin/true"])
      )
    )
    try await session.receive(DAPFramer.frame(request))

    let responseData = try await waitForFrame(frames)
    var framer = DAPFramer()
    let payload = try XCTUnwrap(try framer.append(responseData).first)
    let response = try JSONDecoder().decode(DAPResponse.self, from: payload)

    let handledCount = await handler.count()
    XCTAssertEqual(handledCount, 1)
    XCTAssertEqual(response.requestSeq, 77)
    XCTAssertTrue(response.success)
    XCTAssertEqual(response.command, "runInTerminal")
  }

  private func waitForFrame(_ frames: WrittenFrames) async throws -> Data {
    for _ in 0..<100 {
      if let value = await frames.first() { return value }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for a DAP response frame")
    return Data()
  }
}
