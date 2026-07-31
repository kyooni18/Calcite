import Foundation

#if canImport(CoreServices)
  import CoreServices
#endif

nonisolated struct ProjectFileChangeBatch: Equatable, Sendable {
  var changedPaths: Set<URL> = []
  var removedPaths: Set<URL> = []
  var renamedPaths: Set<URL> = []
  var rootWasMovedOrDeleted = false
  var requiresFullRescan = false

  var isEmpty: Bool {
    changedPaths.isEmpty
      && removedPaths.isEmpty
      && renamedPaths.isEmpty
      && !rootWasMovedOrDeleted
      && !requiresFullRescan
  }

  mutating func merge(_ other: ProjectFileChangeBatch) {
    changedPaths.formUnion(other.changedPaths)
    removedPaths.formUnion(other.removedPaths)
    renamedPaths.formUnion(other.renamedPaths)
    rootWasMovedOrDeleted = rootWasMovedOrDeleted || other.rootWasMovedOrDeleted
    requiresFullRescan = requiresFullRescan || other.requiresFullRescan
  }
}

/// Recursive, coalesced project change notifications. Callers receive the affected paths when
/// FSEvents provides them and a full-rescan marker when the event stream reports dropped events.
final nonisolated class ProjectFileSystemMonitor {
  private final class CallbackBox {
    let rootURL: URL
    let handler: @Sendable (ProjectFileChangeBatch) -> Void

    init(
      rootURL: URL,
      handler: @escaping @Sendable (ProjectFileChangeBatch) -> Void
    ) {
      self.rootURL = rootURL.standardizedFileURL
      self.handler = handler
    }
  }

  private let box: CallbackBox

  #if canImport(CoreServices)
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "Calcite.ProjectFileSystemMonitor", qos: .utility)
  #else
    private var timer: DispatchSourceTimer?
  #endif

  init(
    rootURL: URL,
    handler: @escaping @Sendable (ProjectFileChangeBatch) -> Void
  ) {
    box = CallbackBox(rootURL: rootURL, handler: handler)

    #if canImport(CoreServices)
      let callback: FSEventStreamCallback = {
        _, info, eventCount, eventPaths, eventFlags, _ in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        var batch = ProjectFileChangeBatch()

        for index in 0..<eventCount {
          guard let pathPointer = paths[index] else {
            batch.requiresFullRescan = true
            continue
          }
          let url = URL(fileURLWithPath: String(cString: pathPointer)).standardizedFileURL
          let flags = eventFlags[index]

          if ProjectFileSystemMonitor.containsAny(
            flags,
            FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
            FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagMount),
            FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount)
          ) {
            batch.requiresFullRescan = true
          }
            if ProjectFileSystemMonitor.containsAny(flags, FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)) {
            batch.rootWasMovedOrDeleted = true
            batch.requiresFullRescan = true
          }
            if ProjectFileSystemMonitor.containsAny(flags, FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)) {
            batch.removedPaths.insert(url)
            } else if ProjectFileSystemMonitor.containsAny(flags, FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) {
            batch.renamedPaths.insert(url)
          } else {
            batch.changedPaths.insert(url)
          }

          if url == box.rootURL,
            ProjectFileSystemMonitor.containsAny(
              flags,
              FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved),
              FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
            )
          {
            batch.rootWasMovedOrDeleted = true
          }
        }

        if batch.isEmpty { batch.requiresFullRescan = true }
        box.handler(batch)
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
        [box.rootURL.path] as CFArray,
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
      timer.setEventHandler {
        handler(ProjectFileChangeBatch(requiresFullRescan: true))
      }
      timer.resume()
      self.timer = timer
    #endif
  }

  deinit { stop() }

  #if canImport(CoreServices)
    private static func containsAny(
      _ flags: FSEventStreamEventFlags,
      _ values: FSEventStreamEventFlags...
    ) -> Bool {
      values.contains { flags & $0 != 0 }
    }
  #endif

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
