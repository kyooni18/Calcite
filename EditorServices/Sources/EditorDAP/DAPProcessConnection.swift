import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public final class DAPProcessConnection: @unchecked Sendable {
  public let session: DAPSession
  public let standardError: AsyncStream<String>
  public let transportErrors: AsyncStream<String>

  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let errorOutput: FileHandle
  private let stderrContinuation: AsyncStream<String>.Continuation
  private let transportContinuation: AsyncStream<String>.Continuation
  private let terminationState = TerminationState()

  public init(
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String]? = nil,
    currentDirectoryURL: URL? = nil
  ) throws {
    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = currentDirectoryURL
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    self.process = process
    self.input = stdinPipe.fileHandleForWriting
    #if canImport(Darwin)
      _ = fcntl(self.input.fileDescriptor, F_SETNOSIGPIPE, 1)
    #elseif canImport(Glibc)
      _ = signal(SIGPIPE, SIG_IGN)
    #endif
    self.output = stdoutPipe.fileHandleForReading
    self.errorOutput = stderrPipe.fileHandleForReading
    (standardError, stderrContinuation) = AsyncStream.makeStream(of: String.self)
    (transportErrors, transportContinuation) = AsyncStream.makeStream(of: String.self)
    let inputHandle = self.input
    self.session = DAPSession { data in try inputHandle.write(contentsOf: data) }

    process.terminationHandler = { [session] _ in
      Task { await session.disconnect() }
    }
    try process.run()
    startReaders()
  }

  deinit { terminate() }

  /// Stops the child process and all pipe readers. This method is idempotent.
  public func terminate() {
    guard terminationState.beginTermination() else { return }
    process.terminationHandler = nil
    if process.isRunning { process.terminate() }
    try? input.close()
    try? output.close()
    try? errorOutput.close()
    Task { await session.disconnect() }
    stderrContinuation.finish()
    transportContinuation.finish()
  }

  private func startReaders() {
    let outputFD = output.fileDescriptor
    let errorFD = errorOutput.fileDescriptor
    let state = terminationState
    let session = session
    let transport = transportContinuation
    let stderr = stderrContinuation

    Task.detached { [weak self] in
      while !state.isTerminating {
        switch Self.readChunk(from: outputFD) {
        case .data(let data):
          do { try await session.receive(data) } catch {
            guard !state.isTerminating else { return }
            transport.yield(String(describing: error))
            await session.disconnect()
            self?.terminate()
            return
          }
        case .endOfFile:
          transport.finish()
          await session.disconnect()
          return
        case .failure(let code):
          guard !state.isTerminating else { return }
          transport.yield("DAP stdout read failed with errno \(code)")
          await session.disconnect()
          self?.terminate()
          return
        case .interrupted:
          continue
        }
      }
    }

    Task.detached {
      var pending = ""
      while !state.isTerminating {
        switch Self.readChunk(from: errorFD) {
        case .data(let data):
          pending += String(decoding: data, as: UTF8.self)
          while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline]).trimmingCharacters(in: .newlines)
            if !line.isEmpty { stderr.yield(line) }
            pending.removeSubrange(...newline)
          }
        case .endOfFile:
          if !pending.isEmpty { stderr.yield(pending) }
          stderr.finish()
          return
        case .failure(let code):
          guard !state.isTerminating else { return }
          if !pending.isEmpty { stderr.yield(pending) }
          transport.yield("DAP stderr read failed with errno \(code)")
          stderr.finish()
          return
        case .interrupted:
          continue
        }
      }
    }
  }

  private enum ReadResult {
    case data(Data)
    case endOfFile
    case interrupted
    case failure(Int32)
  }

  /// Uses POSIX `read` instead of `FileHandle.availableData` because the
  /// latter can trap on Linux when a handle closes concurrently with a read.
  private static func readChunk(from descriptor: Int32) -> ReadResult {
    var bytes = [UInt8](repeating: 0, count: 16 * 1024)
    let count: Int
    #if canImport(Darwin)
      count = Darwin.read(descriptor, &bytes, bytes.count)
    #elseif canImport(Glibc)
      count = Glibc.read(descriptor, &bytes, bytes.count)
    #else
      return .failure(-1)
    #endif

    if count > 0 { return .data(Data(bytes.prefix(count))) }
    if count == 0 { return .endOfFile }
    if errno == EINTR { return .interrupted }
    return .failure(errno)
  }
}

private final class TerminationState: @unchecked Sendable {
  private let lock = NSLock()
  private var terminating = false

  var isTerminating: Bool {
    lock.lock()
    defer { lock.unlock() }
    return terminating
  }

  func beginTermination() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !terminating else { return false }
    terminating = true
    return true
  }
}
