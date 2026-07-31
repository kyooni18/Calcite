import XCTest

@testable import EditorCore

final class EditorCoreTextIntegrityTests: XCTestCase {
  func testUTF16PositionsRoundTripAcrossEmojiAndCRLF() throws {
    let snapshot = TextSnapshot(text: "a😀b\r\n한글\n")
    let position = TextPosition(line: 0, utf16Column: 3)
    let offset = try snapshot.utf16Offset(of: position)

    XCTAssertEqual(offset, 3)
    XCTAssertEqual(try snapshot.position(atUTF16Offset: offset), position)
    XCTAssertEqual(try snapshot.utf8Column(of: position), 5)
    XCTAssertEqual(try snapshot.lineUTF16Length(1), 2)
  }

  func testBatchEditRejectsOverlapWithoutMutatingBuffer() throws {
    var buffer = TextBuffer(text: "abcdef", version: 7)
    let edits = [
      TextEdit(
        range: .init(
          start: .init(line: 0, utf16Column: 1),
          end: .init(line: 0, utf16Column: 4)
        ),
        replacement: "X"
      ),
      TextEdit(
        range: .init(
          start: .init(line: 0, utf16Column: 3),
          end: .init(line: 0, utf16Column: 5)
        ),
        replacement: "Y"
      ),
    ]

    XCTAssertThrowsError(try buffer.apply(edits)) { error in
      XCTAssertEqual(error as? TextBufferError, .overlappingEdits)
    }
    XCTAssertEqual(buffer.text, "abcdef")
    XCTAssertEqual(buffer.version, 7)
  }
}
