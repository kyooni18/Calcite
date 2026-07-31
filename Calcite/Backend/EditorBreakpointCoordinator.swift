import Combine
import EditorServices
import Foundation

@MainActor
final class EditorBreakpointCoordinator: ObservableObject {
  @Published private(set) var records: [EditorStoredBreakpoint] = []

  private let workspaceURL: URL

  init(workspaceURL: URL) {
    self.workspaceURL = workspaceURL.standardizedFileURL
    reload()
  }

  func reload() {
    records = EditorBreakpointStore.allRecords(under: workspaceURL)
      .values
      .flatMap { $0 }
      .sorted {
        if ($0.documentURL?.path ?? "") == ($1.documentURL?.path ?? "") {
          return $0.effectiveLine < $1.effectiveLine
        }
        return ($0.documentURL?.path ?? "") < ($1.documentURL?.path ?? "")
      }
  }

  func records(for url: URL) -> [EditorStoredBreakpoint] {
    let key = url.standardizedFileURL
    return records.filter { $0.documentURL?.standardizedFileURL == key }
  }

  func update(_ value: EditorStoredBreakpoint) {
    guard let documentURL = value.documentURL else { return }
    var fileRecords = EditorBreakpointStore.loadRecords(for: documentURL)
    if let index = fileRecords.firstIndex(where: { $0.id == value.id }) {
      fileRecords[index] = value
    } else {
      fileRecords.append(value)
    }
    EditorBreakpointStore.saveRecords(fileRecords, for: documentURL)
    reload()
  }

  func setEnabled(_ enabled: Bool, id: UUID) {
    guard var record = records.first(where: { $0.id == id }) else { return }
    record.isEnabled = enabled
    update(record)
  }

  func remove(id: UUID) {
    guard let record = records.first(where: { $0.id == id }) else { return }
    guard let documentURL = record.documentURL else { return }
    var fileRecords = EditorBreakpointStore.loadRecords(for: documentURL)
    fileRecords.removeAll { $0.id == id }
    EditorBreakpointStore.saveRecords(fileRecords, for: documentURL)
    reload()
  }

  func applyVerification(
    documentURL: URL,
    sentRecords: [EditorStoredBreakpoint],
    responses: [Breakpoint]
  ) {
    var fileRecords = EditorBreakpointStore.loadRecords(for: documentURL)
    let responseByID = Dictionary(
      uniqueKeysWithValues: zip(sentRecords, responses).map { ($0.id, $1) }
    )
    for index in fileRecords.indices {
      guard let response = responseByID[fileRecords[index].id] else { continue }
      if let line = response.line, line > 0 {
        fileRecords[index].resolvedLine = line
      }
      if response.verified {
        fileRecords[index].verificationMessage = response.message ?? "Verified by debug adapter"
      } else {
        fileRecords[index].verificationMessage = response.message ?? "Rejected by debug adapter"
      }
    }
    EditorBreakpointStore.saveRecords(fileRecords, for: documentURL)
    reload()
  }

  @discardableResult
  func relocate(documentURL: URL, text: String) -> [EditorStoredBreakpoint] {
    let values = EditorBreakpointStore.relocateRecords(for: documentURL, in: text)
    reload()
    return values
  }
}
