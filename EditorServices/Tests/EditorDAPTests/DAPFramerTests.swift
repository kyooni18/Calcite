import XCTest
@testable import EditorDAP

final class DAPFramerTests: XCTestCase {
    func testFragmentedFrame() throws {
        let payload = Data(#"{"type":"event"}"#.utf8)
        let frame = DAPFramer.frame(payload)
        var framer = DAPFramer()
        XCTAssertTrue(try framer.append(frame.prefix(7)).isEmpty)
        XCTAssertEqual(try framer.append(frame.dropFirst(7)), [payload])
    }

    func testMultipleFrames() throws {
        var framer = DAPFramer()
        let a = Data("a".utf8), b = Data("bb".utf8)
        XCTAssertEqual(try framer.append(DAPFramer.frame(a) + DAPFramer.frame(b)), [a, b])
    }

    func testCaseInsensitiveAndExtraHeader() throws {
        var framer = DAPFramer()
        let data = Data("content-length: 2\r\nX-Test: yes\r\n\r\nok".utf8)
        XCTAssertEqual(try framer.append(data), [Data("ok".utf8)])
    }

    func testMatchingDuplicateLengthAllowed() throws {
        var framer = DAPFramer()
        XCTAssertEqual(try framer.append(Data("Content-Length: 1\r\ncontent-length: 1\r\n\r\nx".utf8)), [Data("x".utf8)])
    }

    func testConflictingLengthRejected() {
        var framer = DAPFramer()
        XCTAssertThrowsError(try framer.append(Data("Content-Length: 1\r\nContent-Length: 2\r\n\r\nx".utf8)))
    }

    func testHeaderAndMessageLimits() {
        var header = DAPFramer(maxHeaderBytes: 3)
        XCTAssertThrowsError(try header.append(Data("abcd".utf8)))
        var content = DAPFramer(maxContentBytes: 1)
        XCTAssertThrowsError(try content.append(Data("Content-Length: 2\r\n\r\nxx".utf8)))
    }

    func testNegativeLimitsAreSafe() {
        var framer = DAPFramer(maxHeaderBytes: -1, maxContentBytes: -1)
        XCTAssertThrowsError(try framer.append(Data("x".utf8)))
    }

    func testDAPValuePreservesIntegers() throws {
        let value = try JSONDecoder().decode(DAPValue.self, from: Data("9007199254740991".utf8))
        XCTAssertEqual(value, .integer(9_007_199_254_740_991))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), "9007199254740991")
    }
}
