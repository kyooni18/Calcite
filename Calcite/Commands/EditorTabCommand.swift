import Foundation

nonisolated enum EditorTabCommand: Equatable, Sendable {
  case find
  case replace
  case zoomIn
  case zoomOut
  case resetZoom
}

nonisolated struct EditorTabCommandEvent: Equatable, Sendable {
  let id = UUID()
  let targetTabID: UUID
  let command: EditorTabCommand
}

nonisolated enum EditorLayoutCommand: Equatable, Sendable {
  case splitRight
  case splitBelow
  case closeSplit
}
