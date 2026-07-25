import Combine
import SwiftUI

@MainActor
final class CommandPaletteState: ObservableObject {
  @Published var isPresented = false
  @Published var mode: CalciteCommandPaletteSurface.Mode = .all
  @Published var query = ""
  @Published var keyboardEvent: CalciteCommandPaletteSurface.KeyboardEvent?
  @Published private(set) var focusRequestID = UUID()

  func present(mode: CalciteCommandPaletteSurface.Mode) {
    self.mode = mode
    isPresented = true
    focusRequestID = UUID()
  }

  func dismiss() {
    isPresented = false
  }

  func send(_ command: CalciteCommandPaletteSurface.KeyboardCommand) {
    if command == .dismiss {
      dismiss()
      return
    }
    if !isPresented {
      present(mode: .all)
    }
    keyboardEvent = .init(command: command)
  }
}
