import EditorCore
import Foundation
import XCTest

final class IncrementalUTF8DecoderTests: XCTestCase {
  func testSplitScalarIsPreservedAcrossChunks() {
    var decoder = IncrementalUTF8Decoder()
    let bytes = Array("A🦀한B".utf8)

    XCTAssertEqual(decoder.decode(Data(bytes[0..<2])), "A")
    XCTAssertTrue(decoder.hasPendingBytes)
    XCTAssertEqual(decoder.decode(Data(bytes[2..<6])), "🦀")
    XCTAssertEqual(decoder.decode(Data(bytes[6...])), "한B")
    XCTAssertEqual(decoder.finish(), "")
  }

  func testIncompleteTailIsRepairedOnlyWhenFinished() {
    var decoder = IncrementalUTF8Decoder()
    XCTAssertEqual(decoder.decode(Data([0xF0, 0x9F, 0xA6])), "")
    XCTAssertEqual(decoder.finish(), "�")
    XCTAssertFalse(decoder.hasPendingBytes)
  }

  func testInvalidInputDoesNotBlockFollowingValidText() {
    var decoder = IncrementalUTF8Decoder()
    XCTAssertEqual(decoder.decode(Data([0xFF, 0x61, 0xE2, 0x28, 0x62])), "�a�(b")
    XCTAssertEqual(decoder.finish(), "")
  }

  func testResetDropsPendingBytes() {
    var decoder = IncrementalUTF8Decoder()
    XCTAssertEqual(decoder.decode(Data([0xE2, 0x82])), "")
    decoder.reset()
    XCTAssertEqual(decoder.decode(Data("ok".utf8)), "ok")
  }
}
