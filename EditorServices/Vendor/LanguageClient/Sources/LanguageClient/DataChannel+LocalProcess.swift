import Foundation
import JSONRPC
import LanguageServerProtocol

#if canImport(ProcessEnv)
  import ProcessEnv

  extension DataChannel {
    @available(macOS 12.0, *)
    public static func localProcessChannel(
      parameters: Process.ExecutionParameters,
      terminationHandler: @escaping @Sendable () -> Void
    ) throws -> DataChannel {
      try localProcessChannel(parameters: parameters, terminationHandler: terminationHandler)
        .channel
    }

    @available(macOS 12.0, *)
    public static func localProcessChannel(
      parameters: Process.ExecutionParameters,
      terminationHandler: @escaping @Sendable () -> Void
    ) throws -> (channel: DataChannel, process: Process) {
      let result = try launchLocalProcess(
        parameters: parameters,
        terminationHandler: terminationHandler,
        captureStandardError: false
      )
      return (result.channel, result.process)
    }

    /// Launches a local JSON-RPC process while exposing stderr as a bounded line stream.
    ///
    /// Stderr is intentionally not printed to the host process. Applications can route the stream
    /// into their own diagnostics or logging UI without flooding Xcode's console.
    @available(macOS 12.0, *)
    public static func localProcessChannelWithStandardError(
      parameters: Process.ExecutionParameters,
      terminationHandler: @escaping @Sendable () -> Void
    ) throws -> (channel: DataChannel, process: Process, standardError: AsyncStream<String>) {
      try launchLocalProcess(
        parameters: parameters,
        terminationHandler: terminationHandler,
        captureStandardError: true
      )
    }

    @available(macOS 12.0, *)
    private static func launchLocalProcess(
      parameters: Process.ExecutionParameters,
      terminationHandler: @escaping @Sendable () -> Void,
      captureStandardError: Bool
    ) throws -> (channel: DataChannel, process: Process, standardError: AsyncStream<String>) {
      let process = Process()

      let stdinPipe = Pipe()
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()

      process.standardInput = stdinPipe
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe
      process.parameters = parameters

      let (stream, continuation) = DataSequence.makeStream()
      let standardError = AsyncStream<String>(bufferingPolicy: .bufferingNewest(256)) {
        standardErrorContinuation in
        process.terminationHandler = { _ in
          continuation.finish()
          standardErrorContinuation.finish()
          terminationHandler()
        }

        Task {
          let dataStream = stdoutPipe.fileHandleForReading.dataStream
          for await data in dataStream {
            continuation.yield(data)
          }
          continuation.finish()
        }

        Task {
          var pending = Data()
          for await data in stderrPipe.fileHandleForReading.dataStream {
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
              var lineData = pending[..<newline]
              if lineData.last == 0x0D { lineData = lineData.dropLast() }
              if captureStandardError, !lineData.isEmpty {
                standardErrorContinuation.yield(String(decoding: lineData, as: UTF8.self))
              }
              pending.removeSubrange(...newline)
            }
          }
          if captureStandardError, !pending.isEmpty {
            standardErrorContinuation.yield(String(decoding: pending, as: UTF8.self))
          }
          standardErrorContinuation.finish()
        }
      }

      do {
        try process.run()
      } catch {
        continuation.finish()
        throw error
      }

      let handler: DataChannel.WriteHandler = {
        // The channel holds a strong reference to the process so it remains alive for the
        // lifetime of the transport.
        _ = process
        try stdinPipe.fileHandleForWriting.write(contentsOf: $0)
      }

      return (DataChannel(writeHandler: handler, dataSequence: stream), process, standardError)
    }
  }

#endif
