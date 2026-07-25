import Foundation
import EditorCore

public actor VimDocumentSession {
  public let document: EditorDocument
  public let engine: VimEngine

  public init(document: EditorDocument, leader: String = "\\", localLeader: String = "\\") async {
    self.document = document
    let snapshot = await document.snapshot
    self.engine = VimEngine(text: snapshot.text, leader: leader, localLeader: localLeader)
  }

  public func synchronizeFromDocument() async {
    let snapshot = await document.snapshot
    engine.synchronize(text: snapshot.text)
  }

  @discardableResult
  public func execute(_ invocation: VimInvocation) async throws -> VimExecutionResult {
    let before = engine.state
    let result = try engine.execute(invocation)
    guard result.didChangeText || result.state.text != before.text else { return result }
    do {
      let snapshot = TextSnapshot(text: before.text)
      let end = try snapshot.position(atUTF16Offset: snapshot.utf16Count)
      _ = try await document.apply(TextEdit(range: EditorTextRange(start: .zero, end: end), replacement: result.state.text))
      return result
    } catch {
      engine.synchronize(text: before.text, cursor: before.cursor)
      throw error
    }
  }
}
