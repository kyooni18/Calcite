import XCTest
@testable import EditorCore

final class TextBufferTests: XCTestCase {
    func testEmptySnapshotHasOneLine() throws {
        let snapshot = TextSnapshot(text: "")
        XCTAssertEqual(snapshot.lineCount, 1)
        XCTAssertEqual(try snapshot.position(atUTF16Offset: 0), .zero)
    }

    func testCRLFAndMixedLineEndings() throws {
        let snapshot = TextSnapshot(text: "a\r\nb\rc\nd")
        XCTAssertEqual(snapshot.lineCount, 4)
        XCTAssertEqual(try snapshot.utf16Offset(of: .init(line: 1, utf16Column: 1)), 4)
        XCTAssertThrowsError(try snapshot.position(atUTF16Offset: 2))
    }

    func testUnicodeUTF16AndUTF8Mapping() throws {
        let snapshot = TextSnapshot(text: "가😀x")
        XCTAssertEqual(snapshot.utf16Count, 4)
        XCTAssertEqual(try snapshot.utf8Offset(of: .init(line: 0, utf16Column: 1)), 3)
        XCTAssertEqual(try snapshot.utf8Offset(of: .init(line: 0, utf16Column: 3)), 7)
        XCTAssertThrowsError(try snapshot.utf8Offset(of: .init(line: 0, utf16Column: 2)))
    }

    func testInvalidLineDoesNotTrap() {
        let snapshot = TextSnapshot(text: "x")
        XCTAssertThrowsError(try snapshot.utf8Column(of: .init(line: 99, utf16Column: 0)))
    }

    func testSingleEditIncrementsVersion() throws {
        var buffer = TextBuffer(text: "hello")
        let change = try buffer.apply(.init(range: .init(start: .init(line: 0, utf16Column: 1), end: .init(line: 0, utf16Column: 4)), replacement: "i"))
        XCTAssertEqual(buffer.text, "hio")
        XCTAssertEqual(buffer.version, 1)
        XCTAssertEqual(change.oldUTF16Range, NSRange(location: 1, length: 3))
    }

    func testBatchEditsAreAtomicAndPositionStable() throws {
        var buffer = TextBuffer(text: "abcdef")
        let changes = try buffer.apply([
            .init(range: .init(start: .init(line: 0, utf16Column: 1), end: .init(line: 0, utf16Column: 2)), replacement: "B"),
            .init(range: .init(start: .init(line: 0, utf16Column: 4), end: .init(line: 0, utf16Column: 5)), replacement: "E")
        ])
        XCTAssertEqual(buffer.text, "aBcdEf")
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(buffer.version, 2)
    }

    func testOverlappingBatchDoesNotMutate() {
        var buffer = TextBuffer(text: "abcdef")
        XCTAssertThrowsError(try buffer.apply([
            .init(range: .init(start: .init(line: 0, utf16Column: 1), end: .init(line: 0, utf16Column: 4)), replacement: "x"),
            .init(range: .init(start: .init(line: 0, utf16Column: 3), end: .init(line: 0, utf16Column: 5)), replacement: "y")
        ]))
        XCTAssertEqual(buffer.text, "abcdef")
        XCTAssertEqual(buffer.version, 0)
    }

    func testInvalidBatchDoesNotMutate() {
        var buffer = TextBuffer(text: "abc")
        XCTAssertThrowsError(try buffer.apply([
            .init(range: .init(start: .init(line: 0, utf16Column: 0), end: .init(line: 0, utf16Column: 1)), replacement: "A"),
            .init(range: .init(start: .init(line: 5, utf16Column: 0), end: .init(line: 5, utf16Column: 1)), replacement: "X")
        ]))
        XCTAssertEqual(buffer.text, "abc")
    }

    func testVersionOverflow() {
        var buffer = TextBuffer(text: "a", version: Int.max)
        XCTAssertThrowsError(try buffer.apply(.init(range: .init(start: .zero, end: .zero), replacement: "x")))
        XCTAssertEqual(buffer.text, "a")
    }

    func testCompletionMergePrefersServerAndDeduplicates() {
        let preferred = [Completion(label: "func", insertText: "func"), Completion(label: "foo")]
        let fallback = [Completion(label: "func", insertText: "func"), Completion(label: "for")]
        XCTAssertEqual(CompletionUtilities.merge(preferred: preferred, fallback: fallback).map(\.label), ["func", "foo", "for"])
        XCTAssertTrue(CompletionUtilities.merge(preferred: preferred, fallback: fallback, limit: 0).isEmpty)
    }
    func testSamePositionInsertionsPreserveCallerOrder() throws {
        var buffer = TextBuffer(text: "")
        _ = try buffer.apply([
            .init(range: .init(start: .zero, end: .zero), replacement: "A"),
            .init(range: .init(start: .zero, end: .zero), replacement: "B"),
            .init(range: .init(start: .zero, end: .zero), replacement: "C")
        ])
        XCTAssertEqual(buffer.text, "ABC")
    }

}
