import Foundation

#if canImport(CoreServices)
  import CoreServices
#endif

/// Recursive, coalesced project change notifications. FSEvents avoids repeatedly walking an
/// unchanged project tree while still catching changes made by external tools and build systems.
final nonisolated class ProjectFileSystemMonitor {
  private final class CallbackBox {
    let handler: @Sendable () -> Void
    init(handler: @escaping @Sendable () -> Void) { self.handler = handler }
  }

  private let box: CallbackBox

  #if canImport(CoreServices)
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "Calcite.ProjectFileSystemMonitor", qos: .utility)
  #else
    private var timer: DispatchSourceTimer?
  #endif

  init(rootURL: URL, handler: @escaping @Sendable () -> Void) {
    box = CallbackBox(handler: handler)

    #if canImport(CoreServices)
      let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        box.handler()
      }
      var context = FSEventStreamContext(
        version: 0,
        info: Unmanaged.passUnretained(box).toOpaque(),
        retain: nil,
        release: nil,
        copyDescription: nil
      )
      let flags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents
          | kFSEventStreamCreateFlagNoDefer
          | kFSEventStreamCreateFlagWatchRoot
      )
      stream = FSEventStreamCreate(
        nil,
        callback,
        &context,
        [rootURL.standardizedFileURL.path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.25,
        flags
      )
      if let stream {
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
          FSEventStreamInvalidate(stream)
          FSEventStreamRelease(stream)
          self.stream = nil
        }
      }
    #else
      let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      timer.schedule(deadline: .now() + 30, repeating: 30)
      timer.setEventHandler(handler: handler)
      timer.resume()
      self.timer = timer
    #endif
  }

  deinit { stop() }

  func stop() {
    #if canImport(CoreServices)
      guard let stream else { return }
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    #else
      timer?.cancel()
      timer = nil
    #endif
  }
}
