import Combine
import Foundation

nonisolated enum EditorExecutionChannel: String, Codable, CaseIterable, Sendable {
  case build
  case run
  case test
  case debuggee
  case debugger
  case adapter
  case terminal
  case liveDebug
  case system
}

nonisolated enum EditorExecutionSeverity: String, Codable, Sendable {
  case trace
  case info
  case notice
  case warning
  case error
}

nonisolated struct EditorExecutionSourceLocation: Hashable, Codable, Sendable {
  var url: URL
  var line: Int
  var column: Int

  init(url: URL, line: Int, column: Int = 1) {
    self.url = url.standardizedFileURL
    self.line = max(1, line)
    self.column = max(1, column)
  }
}

nonisolated struct EditorExecutionEvent: Identifiable, Hashable, Codable, Sendable {
  let id: UUID
  let operationID: UUID
  let sessionID: UUID?
  let timestamp: Date
  let channel: EditorExecutionChannel
  let severity: EditorExecutionSeverity
  let text: String
  let sourceLocation: EditorExecutionSourceLocation?

  init(
    id: UUID = UUID(),
    operationID: UUID,
    sessionID: UUID? = nil,
    timestamp: Date = Date(),
    channel: EditorExecutionChannel,
    severity: EditorExecutionSeverity = .info,
    text: String,
    sourceLocation: EditorExecutionSourceLocation? = nil
  ) {
    self.id = id
    self.operationID = operationID
    self.sessionID = sessionID
    self.timestamp = timestamp
    self.channel = channel
    self.severity = severity
    self.text = text
    self.sourceLocation = sourceLocation
  }
}

@MainActor
final class EditorExecutionEventStore: ObservableObject {
  @Published private(set) var events: [EditorExecutionEvent] = []
  @Published var selectedChannels = Set(EditorExecutionChannel.allCases)
  @Published var activeOperationID: UUID?
  @Published var followsLatestOutput = true

  private let maximumEvents: Int

  init(maximumEvents: Int = 20_000) {
    self.maximumEvents = max(500, maximumEvents)
  }

  var visibleEvents: [EditorExecutionEvent] {
    events.filter { event in
      selectedChannels.contains(event.channel)
        && (activeOperationID == nil || activeOperationID == event.operationID)
    }
  }

  func append(_ event: EditorExecutionEvent) {
    events.append(event)
    if events.count > maximumEvents {
      events.removeFirst(events.count - maximumEvents)
    }
  }

  func append(
    operationID: UUID,
    sessionID: UUID? = nil,
    channel: EditorExecutionChannel,
    severity: EditorExecutionSeverity = .info,
    text: String,
    sourceLocation: EditorExecutionSourceLocation? = nil
  ) {
    guard !text.isEmpty else { return }
    append(
      EditorExecutionEvent(
        operationID: operationID,
        sessionID: sessionID,
        channel: channel,
        severity: severity,
        text: text,
        sourceLocation: sourceLocation
      )
    )
  }

  func clear(operationID: UUID? = nil) {
    guard let operationID else {
      events.removeAll(keepingCapacity: true)
      activeOperationID = nil
      return
    }
    events.removeAll { $0.operationID == operationID }
    if activeOperationID == operationID { activeOperationID = nil }
  }

  func text(operationID: UUID? = nil) -> String {
    events.lazy
      .filter { operationID == nil || $0.operationID == operationID }
      .map(\.text)
      .joined()
  }
}
