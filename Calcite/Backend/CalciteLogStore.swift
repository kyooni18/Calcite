import AppKit
import Combine
import Foundation
import OSLog

nonisolated struct CalciteLogEntry: Identifiable, Codable, Sendable {
  enum Level: Int, Codable, CaseIterable, Comparable, Sendable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
      switch self {
      case .debug: "Debug"
      case .info: "Info"
      case .notice: "Notice"
      case .warning: "Warning"
      case .error: "Error"
      }
    }

    var systemImage: String {
      switch self {
      case .debug: "ladybug"
      case .info: "info.circle"
      case .notice: "circle"
      case .warning: "exclamationmark.triangle"
      case .error: "xmark.octagon"
      }
    }
  }

  let id: UUID
  let timestamp: Date
  let level: Level
  let category: String
  let message: String
  let metadata: [String: String]

  init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    level: Level,
    category: String,
    message: String,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.timestamp = timestamp
    self.level = level
    self.category = category
    self.message = message
    self.metadata = metadata
  }
}

struct CalciteOperationStatus: Identifiable, Sendable {
  let id: UUID
  let title: String
  let category: String
  var detail: String?
  var progress: Double?
  let startedAt: Date
}

actor CalciteLogFileWriter {
  static let shared = CalciteLogFileWriter()

  private let encoder: JSONEncoder
  private let fileURL: URL
  private let rotatedFileURL: URL
  private let maximumFileSize = 5 * 1_024 * 1_024

  init() {
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support")
    let directory = base.appendingPathComponent("Calcite/Logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    fileURL = directory.appendingPathComponent("calcite-session.jsonl")
    rotatedFileURL = directory.appendingPathComponent("calcite-session.previous.jsonl")
    Self.removeExpiredRotatedLog(at: rotatedFileURL)
  }

  func append(_ entry: CalciteLogEntry) {
    guard var data = try? encoder.encode(entry) else { return }
    data.append(0x0A)
    rotateIfNeeded(forAdditionalBytes: data.count)
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      createProtectedFile(at: fileURL, contents: data)
      return
    }
    guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
    defer { try? handle.close() }
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } catch {
      // Logging must never interfere with editor operation.
    }
  }

  func location() -> URL {
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      createProtectedFile(at: fileURL, contents: nil)
    }
    return fileURL
  }

  private func createProtectedFile(at url: URL, contents: Data?) {
    _ = FileManager.default.createFile(atPath: url.path, contents: contents)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private static func removeExpiredRotatedLog(at url: URL) {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let modifiedAt = attributes[.modificationDate] as? Date,
      Date().timeIntervalSince(modifiedAt) > 14 * 24 * 60 * 60
    else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private func rotateIfNeeded(forAdditionalBytes additionalBytes: Int) {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
      let currentSize = attributes[.size] as? NSNumber,
      currentSize.intValue + additionalBytes > maximumFileSize
    else { return }

    try? FileManager.default.removeItem(at: rotatedFileURL)
    try? FileManager.default.moveItem(at: fileURL, to: rotatedFileURL)
  }
}

@MainActor
final class CalciteLogStore: ObservableObject {
  static let shared = CalciteLogStore()

  @Published private(set) var entries: [CalciteLogEntry] = []
  @Published private(set) var activeOperations: [CalciteOperationStatus] = []

  private let subsystem = Bundle.main.bundleIdentifier ?? "kyooni18.Calcite"
  private var loggers: [String: Logger] = [:]
  private let maximumEntryCount = 2_000

  private init() {}

  @discardableResult
  func beginOperation(
    _ title: String,
    category: String,
    detail: String? = nil,
    progress: Double? = nil
  ) -> UUID {
    let id = UUID()
    activeOperations.append(
      .init(
        id: id,
        title: title,
        category: category,
        detail: detail,
        progress: progress,
        startedAt: Date()
      )
    )
    log(
      .info, category: category, message: "Started: \(title)",
      metadata: detail.map { ["detail": $0] } ?? [:])
    return id
  }

  func updateOperation(_ id: UUID, detail: String? = nil, progress: Double? = nil) {
    guard let index = activeOperations.firstIndex(where: { $0.id == id }) else { return }
    if let detail { activeOperations[index].detail = detail }
    if let progress { activeOperations[index].progress = min(max(progress, 0), 1) }
  }

  func finishOperation(
    _ id: UUID,
    level: CalciteLogEntry.Level = .info,
    message: String? = nil,
    metadata: [String: String] = [:]
  ) {
    guard let index = activeOperations.firstIndex(where: { $0.id == id }) else { return }
    let operation = activeOperations.remove(at: index)
    let elapsed = Date().timeIntervalSince(operation.startedAt)
    var nextMetadata = metadata
    nextMetadata["duration_ms"] = String(Int((elapsed * 1_000).rounded()))
    log(
      level,
      category: operation.category,
      message: message ?? "Finished: \(operation.title)",
      metadata: nextMetadata
    )
  }

  func log(
    _ level: CalciteLogEntry.Level,
    category: String,
    message: String,
    metadata: [String: String] = [:]
  ) {
    let safeMessage = CalciteLogRedactor.sanitize(message: message)
    let safeMetadata = CalciteLogRedactor.sanitize(metadata: metadata)
    let entry = CalciteLogEntry(
      level: level, category: category, message: safeMessage, metadata: safeMetadata)
    entries.append(entry)
    if entries.count > maximumEntryCount {
      entries.removeFirst(entries.count - maximumEntryCount)
    }

    let logger = logger(for: category)
    let rendered =
      safeMetadata.isEmpty
      ? safeMessage
      : "\(safeMessage) | "
        + safeMetadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(
          separator: " ")
    switch level {
    case .debug: logger.debug("\(rendered, privacy: .private)")
    case .info: logger.info("\(rendered, privacy: .private)")
    case .notice: logger.notice("\(rendered, privacy: .private)")
    case .warning: logger.warning("\(rendered, privacy: .private)")
    case .error: logger.error("\(rendered, privacy: .private)")
    }
    Task { await CalciteLogFileWriter.shared.append(entry) }
  }

  func clearVisibleHistory() { entries.removeAll(keepingCapacity: true) }

  func copyVisibleHistory() {
    let formatter = ISO8601DateFormatter()
    let text = entries.map { entry in
      let metadata =
        entry.metadata.isEmpty
        ? ""
        : " "
          + entry.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(
            separator: " ")
      return
        "\(formatter.string(from: entry.timestamp)) [\(entry.level.title.uppercased())] [\(entry.category)] \(entry.message)\(metadata)"
    }.joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  func revealLogFile() {
    Task {
      let url = await CalciteLogFileWriter.shared.location()
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  private func logger(for category: String) -> Logger {
    if let logger = loggers[category] { return logger }
    let logger = Logger(subsystem: subsystem, category: category)
    loggers[category] = logger
    return logger
  }
}
