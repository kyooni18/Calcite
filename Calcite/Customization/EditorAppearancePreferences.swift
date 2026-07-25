import AppKit
import SwiftUI

enum EditorInterfaceAppearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }

  var appKitAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

struct EditorWindowAppearanceApplier: NSViewRepresentable {
  let mode: EditorInterfaceAppearance
  let backgroundColor: NSColor?

  func makeNSView(context: Context) -> AppearanceView {
    let view = AppearanceView()
    update(view)
    return view
  }

  func updateNSView(_ nsView: AppearanceView, context: Context) { update(nsView) }

  private func update(_ view: AppearanceView) {
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      window.appearance = mode.appKitAppearance
      if let backgroundColor { window.backgroundColor = backgroundColor }
    }
  }

  final class AppearanceView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      needsDisplay = true
    }
  }
}
