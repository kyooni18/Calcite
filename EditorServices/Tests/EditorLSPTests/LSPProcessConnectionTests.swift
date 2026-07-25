import XCTest

@testable import EditorCore
@testable import EditorLSP

#if os(macOS) || os(Linux)
  final class LSPProcessConnectionTests: XCTestCase {
    func testExecutableResolverUsesPATHAndRejectsMissingCommands() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let executable = root.appendingPathComponent("fixture-lsp")
      try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executable.path
      )

      XCTAssertEqual(
        try LSPExecutableResolver.resolve(
          "fixture-lsp",
          environment: ["PATH": root.path]
        ),
        executable.path
      )
      XCTAssertThrowsError(
        try LSPExecutableResolver.resolve(
          "missing-lsp",
          environment: ["PATH": root.path]
        ))
    }

    func testCommonPresetsUseExpectedStdioArguments() {
      XCTAssertEqual(LanguageServerPresets.pyright().arguments, ["--stdio"])
      XCTAssertEqual(LanguageServerPresets.typescript().arguments, ["--stdio"])
      XCTAssertEqual(LanguageServerPresets.bash().arguments, ["start"])
      XCTAssertEqual(LanguageServerPresets.clangd().arguments, [])
    }

    func testStandardErrorIsCapturedWithoutUnicodeLoss() async throws {
      let python: String
      do {
        python = try LSPExecutableResolver.resolve("python3")
      } catch {
        throw XCTSkip("python3 is required for the generic LSP process fixture")
      }

      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let script = root.appendingPathComponent("server.py")
      try Self.serverScript.write(to: script, atomically: true, encoding: .utf8)

      let connection = try LSPProcessConnection(
        workspaceURL: root,
        configuration: .init(executable: python, arguments: [script.path])
      )
      defer { connection.terminate() }

      let line = try await Self.firstValue(from: connection.standardError)
      XCTAssertEqual(line, "fixture stderr 한글🙂")
      try await connection.shutdown()
    }

    func testGenericStdioServerInitializesOpensAndShutsDown() async throws {
      let python: String
      do {
        python = try LSPExecutableResolver.resolve("python3")
      } catch {
        throw XCTSkip("python3 is required for the generic LSP process fixture")
      }

      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let script = root.appendingPathComponent("server.py")
      try Self.serverScript.write(to: script, atomically: true, encoding: .utf8)

      let connection = try LSPProcessConnection(
        workspaceURL: root,
        configuration: .init(executable: python, arguments: [script.path])
      )
      defer { connection.terminate() }
      let response = try await connection.service.initialize()
      XCTAssertEqual(response.serverInfo?.name, "FixtureLSP")

      let file = root.appendingPathComponent("main.py")
      try await connection.service.open(
        uri: file,
        languageID: "python",
        snapshot: TextSnapshot(text: "print('ok')")
      )
      try await connection.service.close(uri: file)
      try await connection.shutdown()
    }

    private enum TimeoutError: Error { case elapsed }

    private static func firstValue(from stream: AsyncStream<String>) async throws -> String? {
      try await withThrowingTaskGroup(of: String?.self) { group in
        group.addTask {
          var iterator = stream.makeAsyncIterator()
          return await iterator.next()
        }
        group.addTask {
          try await Task.sleep(for: .seconds(2))
          throw TimeoutError.elapsed
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
      }
    }

    private static let serverScript = #"""
      import json
      import sys
      import time

      stdin = sys.stdin.buffer
      stdout = sys.stdout.buffer

      stderr_message = "fixture stderr 한글🙂\n".encode("utf-8")
      sys.stderr.buffer.write(stderr_message[:18])
      sys.stderr.buffer.flush()
      time.sleep(0.02)
      sys.stderr.buffer.write(stderr_message[18:])
      sys.stderr.buffer.flush()

      def read_message():
          length = None
          while True:
              line = stdin.readline()
              if not line:
                  return None
              if line in (b"\r\n", b"\n"):
                  break
              name, value = line.decode("ascii").split(":", 1)
              if name.lower() == "content-length":
                  length = int(value.strip())
          if length is None:
              return None
          return json.loads(stdin.read(length).decode("utf-8"))

      def send(value):
          body = json.dumps(value, separators=(",", ":")).encode("utf-8")
          stdout.write(("Content-Length: %d\r\n\r\n" % len(body)).encode("ascii"))
          stdout.write(body)
          stdout.flush()

      while True:
          message = read_message()
          if message is None:
              break
          method = message.get("method")
          if method == "initialize":
              send({
                  "jsonrpc": "2.0",
                  "id": message["id"],
                  "result": {
                      "capabilities": {"textDocumentSync": 1},
                      "serverInfo": {"name": "FixtureLSP", "version": "1"}
                  }
              })
          elif method == "shutdown":
              send({"jsonrpc": "2.0", "id": message["id"], "result": None})
          elif method == "exit":
              break
      """#
  }
#endif
