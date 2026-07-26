import Foundation

nonisolated enum EditorTabCommand: Equatable, Sendable {
  case find
  case replace
  case zoomIn
  case zoomOut
  case resetZoom
}

nonisolated struct EditorTabCommandEvent: Equatable, Sendable {
  let id: UUID
  let targetTabID: UUID
  let command: EditorTabCommand

  init(id: UUID = UUID(), targetTabID: UUID, command: EditorTabCommand) {
    self.id = id
    self.targetTabID = targetTabID
    self.command = command
  }
}

nonisolated enum EditorLayoutCommand: Equatable, Sendable {
  case splitRight
  case splitBelow
  case closeSplit
}
