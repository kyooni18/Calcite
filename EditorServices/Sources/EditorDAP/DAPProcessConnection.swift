import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public enum DAPProcessTerminationReason: String, Hashable, Sendable {
  case exit
  case uncaughtSignal
  case unknown
}

public struct DAPProcessTermination: Hashable, Sendable {
  public let status: Int32
  public let reason: DAPProcessTerminationReason
  public let expected: Bool

  public init(status: Int32, reason: DAPProcessTerminationReason, expected: Bool) {
    self.status = status
    self.reason = reason
    self.expected = expected
  }
}

public final class DAPProcessConnection: @unchecked Sendable {
  public let session: DAPSession
  public let standardError: AsyncStream<String>
  public let transportErrors: AsyncStream<String>
  public let terminationEvents: AsyncStream<DAPProcessTermination>

  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let errorOutput: FileHandle
  private let stderrContinuation: AsyncStream<String>.Continuation
  private let transportContinuation: AsyncStream<String>.Continuation
  private let terminationContinuation: AsyncStream<DAPProcessTermination>.Continuation
  private let terminationState = TerminationState()
  private var processGroupID: Int32?

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
    (terminationEvents, terminationContinuation) = AsyncStream.makeStream(
      of: DAPProcessTermination.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    let inputHandle = self.input
    self.session = DAPSession { data in try inputHandle.write(contentsOf: data) }

    let terminationState = self.terminationState
    let terminationContinuation = self.terminationContinuation
    process.terminationHandler = { [session] process in
      let expected = terminationState.markProcessExited()
      let reason: DAPProcessTerminationReason =
        switch process.terminationReason {
        case .exit: .exit
        case .uncaughtSignal: .uncaughtSignal
        @unknown default: .unknown
        }
      terminationContinuation.yield(
        DAPProcessTermination(
          status: process.terminationStatus,
          reason: reason,
          expected: expected
        )
      )
      terminationContinuation.finish()
      Task { await session.disconnect() }
    }
    try process.run()
    processGroupID = Self.createProcessGroup(for: process.processIdentifier)
    startReaders()
  }

  deinit { terminate() }

  /// Stops the child process and all pipe readers. This method is idempotent.
  public func terminate() {
    guard terminationState.beginTermination() else { return }
    terminateProcessTree()
    try? input.close()
    try? output.close()
    try? errorOutput.close()
    Task { await session.disconnect() }
    stderrContinuation.finish()
    transportContinuation.finish()
    // On some Foundation implementations a process explicitly terminated by the
    // owner does not invoke its termination handler promptly. Consumers only need
    // unexpected exits, so finishing is sufficient for the expected path.
    terminationContinuation.finish()
  }

  private func terminateProcessTree() {
    guard process.isRunning else { return }
    signalProcess(SIGINT)
    Self.waitBriefly(for: process, microseconds: 100_000)
    guard process.isRunning else { return }
    signalProcess(SIGTERM)
    Self.waitBriefly(for: process, microseconds: 250_000)
    guard process.isRunning else { return }
    signalProcess(SIGKILL)
  }

  private func signalProcess(_ signal: Int32) {
    #if canImport(Darwin)
      if let processGroupID {
        _ = Darwin.kill(-processGroupID, signal)
      } else {
        _ = Darwin.kill(process.processIdentifier, signal)
      }
    #elseif canImport(Glibc)
      if let processGroupID {
        _ = Glibc.kill(-processGroupID, signal)
      } else {
        _ = Glibc.kill(process.processIdentifier, signal)
      }
    #else
      process.terminate()
    #endif
  }

  private static func createProcessGroup(for processID: Int32) -> Int32? {
    #if canImport(Darwin) || canImport(Glibc)
      if setpgid(processID, processID) == 0 || getpgid(processID) == processID {
        return processID
      }
    #endif
    return nil
  }

  private static func waitBriefly(for process: Process, microseconds: useconds_t) {
    var remaining = microseconds
    while process.isRunning, remaining > 0 {
      usleep(min(25_000, remaining))
      remaining -= min(25_000, remaining)
    }
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
  private var expected = false

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
    expected = true
    return true
  }

  /// Returns whether the process exit was initiated by the owner.
  func markProcessExited() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let wasExpected = expected
    terminating = true
    return wasExpected
  }
}
