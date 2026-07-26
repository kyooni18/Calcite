import EditorCore
import EditorVim
import XCTest

final class VimDocumentSessionTests: XCTestCase {
  func testSessionAppliesUnicodeEditIncrementally() async throws {
    let document = EditorDocument(
      uri: URL(fileURLWithPath: "/tmp/vim-session-unicode.txt"),
      languageID: "text",
      text: "A👩‍💻B"
    )
    try await document.open()
    let session = await VimDocumentSession(document: document)
    _ = try await session.execute(.notation("lx"))
    let snapshot = await document.snapshot
    XCTAssertEqual(snapshot.text, "AB")
  }

  func testSessionResynchronizesBeforeEditingExternallyChangedDocument() async throws {
    let document = EditorDocument(
      uri: URL(fileURLWithPath: "/tmp/vim-session.txt"),
      languageID: "text",
      text: "abc"
    )
    try await document.open()
    let session = await VimDocumentSession(document: document)

    let snapshot = await document.snapshot
    let end = try snapshot.position(atUTF16Offset: snapshot.utf16Count)
    _ = try await document.apply(
      TextEdit(
        range: EditorTextRange(start: .zero, end: end),
        replacement: "xyz"
      )
    )

    _ = try await session.execute(.notation("x"))
    let finalSnapshot = await document.snapshot
    XCTAssertEqual(finalSnapshot.text, "yz")
  }
}
