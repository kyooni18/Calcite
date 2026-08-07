import AppKit
import SwiftUI

/// Persists the workspace window frame independently for each project and constrains restored
/// frames to a currently connected display.
struct EditorWindowLayoutPersistence: NSViewRepresentable {
  let workspaceURL: URL

  func makeCoordinator() -> Coordinator {
    Coordinator(workspaceURL: workspaceURL)
  }

  func makeNSView(context: Context) -> NSView {
    ProbeView(coordinator: context.coordinator)
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.attach(to: nsView.window)
  }

  @MainActor
  final class Coordinator {
    private let frameKey: String
    private let legacyFrameKey: String?
    private weak var observedWindow: NSWindow?
    // `deinit` is nonisolated even though the coordinator is main-actor isolated.
    // Observer installation and removal otherwise remain main-actor confined.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var didCompleteInitialRestore = false
    private var isRestoringFrame = false

    init(workspaceURL: URL) {
      let standardizedPath = workspaceURL.standardizedFileURL.path
      let canonicalPath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
      frameKey = "calcite.windowFrame.\(Self.stableIdentifier(canonicalPath))"
      legacyFrameKey =
        canonicalPath == standardizedPath
        ? nil
        : "calcite.windowFrame.\(Self.stableIdentifier(standardizedPath))"
    }

    deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(to window: NSWindow?) {
      guard let window else { return }
      if observedWindow !== window {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        observedWindow = window
        observe(window)
        Task { @MainActor [weak self, weak window] in
          await Task.yield()
          guard let self, let window else { return }
          self.restoreFrame(on: window)
        }
      }
    }

    private func observe(_ window: NSWindow) {
      let center = NotificationCenter.default
      observers = [
        center.addObserver(
          forName: NSWindow.didResizeNotification,
          object: window,
          queue: .main
        ) { [weak self, weak window] _ in
          Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.didCompleteInitialRestore,
              !self.isRestoringFrame
            else { return }
            self.saveFrame(window.frame)
          }
        },
        center.addObserver(
          forName: NSWindow.didMoveNotification,
          object: window,
          queue: .main
        ) { [weak self, weak window] _ in
          Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.didCompleteInitialRestore,
              !self.isRestoringFrame
            else { return }
            self.saveFrame(window.frame)
          }
        },
        center.addObserver(
          forName: NSWindow.willCloseNotification,
          object: window,
          queue: .main
        ) { [weak self, weak window] _ in
          Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.didCompleteInitialRestore else { return }
            self.saveFrame(window.frame)
          }
        },
      ]
    }

    private func restoreFrame(on window: NSWindow) {
      guard !didCompleteInitialRestore else { return }
      didCompleteInitialRestore = true
      let defaults = UserDefaults.standard
      let canonicalValue = defaults.string(forKey: frameKey)
      let legacyValue = legacyFrameKey.flatMap { defaults.string(forKey: $0) }
      guard let value = canonicalValue ?? legacyValue else { return }
      let savedFrame = NSRectFromString(value)
      guard savedFrame.width.isFinite, savedFrame.height.isFinite,
        savedFrame.origin.x.isFinite, savedFrame.origin.y.isFinite,
        savedFrame.width > 0, savedFrame.height > 0
      else { return }

      let frame = Self.constrainedFrame(savedFrame, screens: NSScreen.screens)
      isRestoringFrame = true
      window.setFrame(frame, display: false)
      if canonicalValue == nil {
        defaults.set(NSStringFromRect(frame), forKey: frameKey)
        if let legacyFrameKey { defaults.removeObject(forKey: legacyFrameKey) }
      }
      Task { @MainActor [weak self] in
        await Task.yield()
        self?.isRestoringFrame = false
      }
    }

    private func saveFrame(_ frame: NSRect) {
      guard frame.width > 0, frame.height > 0 else { return }
      UserDefaults.standard.set(NSStringFromRect(frame), forKey: frameKey)
    }

    private static func constrainedFrame(_ frame: NSRect, screens: [NSScreen]) -> NSRect {
      guard !screens.isEmpty else { return frame }
      let intersections = screens.map { ($0, intersectionArea(frame, $0.visibleFrame)) }
      let bestIntersection = intersections.max { $0.1 < $1.1 }
      let screen: NSScreen
      if let bestIntersection, bestIntersection.1 > 0 {
        screen = bestIntersection.0
      } else {
        screen = NSScreen.main ?? screens[0]
      }
      let visible = screen.visibleFrame
      let width = min(frame.width, visible.width)
      let height = min(frame.height, visible.height)

      let hadVisibleIntersection = intersectionArea(frame, visible) > 0
      let x: CGFloat
      let y: CGFloat
      if hadVisibleIntersection {
        x = min(max(frame.minX, visible.minX), visible.maxX - width)
        y = min(max(frame.minY, visible.minY), visible.maxY - height)
      } else {
        x = visible.midX - width / 2
        y = visible.midY - height / 2
      }
      return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
      let intersection = lhs.intersection(rhs)
      guard !intersection.isNull else { return 0 }
      return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func stableIdentifier(_ value: String) -> String {
      var hash: UInt64 = 14_695_981_039_346_656_037
      for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
      return String(hash, radix: 16)
    }
  }

  private final class ProbeView: NSView {
    weak var coordinator: Coordinator?

    init(coordinator: Coordinator) {
      self.coordinator = coordinator
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      coordinator?.attach(to: window)
    }
  }
}
