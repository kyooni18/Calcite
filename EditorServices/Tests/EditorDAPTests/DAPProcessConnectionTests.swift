import Foundation
import XCTest
@testable import EditorDAP

#if os(macOS) || os(Linux)
final class DAPProcessConnectionTests: XCTestCase {
    func testSubprocessRequestResponseAndStandardError() async throws {
        let python = ["/usr/bin/python3", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { throw XCTSkip("python3 is not installed") }

        let script = #"""
import json, sys
sys.stderr.write("adapter-ready\n")
sys.stderr.flush()
while True:
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            sys.exit(0)
        if line in (b"\r\n", b"\n"):
            break
        key, value = line.decode("ascii").split(":", 1)
        headers[key.lower()] = value.strip()
    body = sys.stdin.buffer.read(int(headers["content-length"]))
    request = json.loads(body)
    response = {
        "seq": request["seq"] + 100,
        "type": "response",
        "request_seq": request["seq"],
        "success": True,
        "command": request["command"],
        "body": {"echo": request.get("arguments")}
    }
    payload = json.dumps(response, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(payload) + payload)
    sys.stdout.buffer.flush()
"""#

        let connection = try DAPProcessConnection(
            executableURL: URL(fileURLWithPath: python),
            arguments: ["-u", "-c", script]
        )
        defer { connection.terminate() }

        let stderrTask = Task<String?, Never> {
            for await line in connection.standardError { return line }
            return nil
        }
        let response = try await connection.session.request(
            command: "echo",
            arguments: ["value": 42],
            timeout: .seconds(2)
        )

        XCTAssertEqual(response.command, "echo")
        if case .object(let body) = response.body,
           case .object(let echo) = body["echo"] {
            XCTAssertEqual(echo["value"], 42)
        } else {
            XCTFail("Expected echoed object")
        }
        let stderrLine = await stderrTask.value
        XCTAssertEqual(stderrLine, "adapter-ready")
    }

    func testRepeatedImmediateTerminationIsSafe() async throws {
        let shell = ["/bin/sh", "/usr/bin/sh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let shell else { throw XCTSkip("sh is not installed") }

        for _ in 0..<20 {
            let connection = try DAPProcessConnection(
                executableURL: URL(fileURLWithPath: shell),
                arguments: ["-c", "sleep 5"]
            )
            connection.terminate()
        }

        try await Task.sleep(for: .milliseconds(100))
    }
}
#endif
