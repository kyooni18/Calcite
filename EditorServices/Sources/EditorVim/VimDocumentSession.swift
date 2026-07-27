import EditorCore
import Foundation

public actor VimDocumentSession {
  public let document: EditorDocument
  public let engine: VimEngine

  private var synchronizedDocumentVersion: Int

  public init(document: EditorDocument, leader: String = "\\", localLeader: String = "\\") async {
    self.document = document
    let snapshot = await document.snapshot
    self.engine = VimEngine(text: snapshot.text, leader: leader, localLeader: localLeader)
    self.synchronizedDocumentVersion = snapshot.version
  }

  public func synchronizeFromDocument() async {
    let snapshot = await document.snapshot
    engine.synchronize(text: snapshot.text)
    synchronizedDocumentVersion = snapshot.version
  }

  @discardableResult
  public func execute(_ invocation: VimInvocation) async throws -> VimExecutionResult {
    var attempt = 0
    while true {
      attempt += 1
      let baseSnapshot = await document.snapshot
      if baseSnapshot.version != synchronizedDocumentVersion
        || baseSnapshot.text != engine.state.text
      {
        engine.synchronize(text: baseSnapshot.text, cursor: engine.state.cursor)
        synchronizedDocumentVersion = baseSnapshot.version
      }

      let before = engine.state
      let result = try engine.execute(invocation)
      guard result.didChangeText || result.state.text != before.text else { return result }

      // An EditorDocument can change while this actor is suspended on another actor.
      // Rebase and execute once more instead of applying an edit calculated from a stale version.
      let latestSnapshot = await document.snapshot
      if latestSnapshot.version != baseSnapshot.version {
        engine.synchronize(text: latestSnapshot.text, cursor: before.cursor)
        synchronizedDocumentVersion = latestSnapshot.version
        if attempt < 2 { continue }
        return VimExecutionResult(state: engine.state)
      }

      do {
        guard let edit = try Self.incrementalEdit(from: before.text, to: result.state.text) else {
          return result
        }
        let applied = try await document.apply(edit)
        synchronizedDocumentVersion = applied.newSnapshot.version
        return result
      } catch {
        let authoritative = await document.snapshot
        engine.synchronize(text: authoritative.text, cursor: before.cursor)
        synchronizedDocumentVersion = authoritative.version
        throw error
      }
    }
  }

  private static func incrementalEdit(from oldText: String, to newText: String) throws -> TextEdit?
  {
    guard oldText != newText else { return nil }
    guard let delta = VimEditDelta.between(oldText, and: newText) else { return nil }
    let oldSnapshot = TextSnapshot(text: oldText)
    let start = try oldSnapshot.position(atUTF16Offset: delta.location)
    let end = try oldSnapshot.position(
      atUTF16Offset: delta.location + delta.removedUTF16Count
    )
    return TextEdit(
      range: EditorTextRange(start: start, end: end),
      replacement: delta.insertedText
    )
  }
}
