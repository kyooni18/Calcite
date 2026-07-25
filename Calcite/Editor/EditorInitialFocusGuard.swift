import AppKit
import SwiftUI

/// Prevents the toolbar search field from becoming the window's implicit first responder.
/// The inert guard is used only during window setup, so a later user click is never overridden.
struct EditorInitialFocusGuard: NSViewRepresentable {
  static let searchAccessibilityIdentifier = "calcite.top-search"

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> FocusGuardView {
    FocusGuardView(coordinator: context.coordinator)
  }

  func updateNSView(_ nsView: FocusGuardView, context: Context) {
    context.coordinator.attach(view: nsView, to: nsView.window)
  }

  @MainActor
  final class Coordinator {
    private weak var window: NSWindow?
    private weak var guardView: FocusGuardView?

    func attach(view: FocusGuardView, to window: NSWindow?) {
      guard let window else { return }
      guard self.window !== window || guardView !== view else { return }
      self.window = window
      guardView = view

      // Installing a non-text initial responder prevents AppKit from selecting the first text
      // field in the key-view loop. If that selection already happened, replace it immediately
      // during setup; after this method returns, user-initiated focus is left untouched.
      window.initialFirstResponder = view
      if window.firstResponder == nil || isSearchField(window.firstResponder) {
        window.makeFirstResponder(view)
      }
    }

    private func isSearchField(_ responder: NSResponder?) -> Bool {
      guard let editor = responder as? NSTextView,
        let field = editor.delegate as? NSTextField
      else { return false }
      return field.accessibilityIdentifier()
        == EditorInitialFocusGuard.searchAccessibilityIdentifier
    }
  }

  final class FocusGuardView: NSView {
    weak var coordinator: Coordinator?

    override var acceptsFirstResponder: Bool { true }

    init(coordinator: Coordinator) {
      self.coordinator = coordinator
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      coordinator?.attach(view: self, to: window)
    }
  }
}
