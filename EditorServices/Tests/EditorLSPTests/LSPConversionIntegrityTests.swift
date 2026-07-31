import EditorCore
import LanguageServerProtocol
import XCTest

@testable import EditorLSP

final class LSPConversionIntegrityTests: XCTestCase {
  func testPositionAndRangeConversionPreservesUTF16Coordinates() {
    let range = EditorTextRange(
      start: .init(line: 4, utf16Column: 7),
      end: .init(line: 5, utf16Column: 2)
    )

    XCTAssertEqual(LSPConversion.range(LSPConversion.range(range)), range)
  }

  func testSemanticTokenDeltaDecoding() throws {
    let tokens = SemanticTokens(data: [0, 2, 3, 0, 1, 1, 4, 2, 1, 0])
    let legend = SemanticTokensLegend(
      tokenTypes: ["type", "function"], tokenModifiers: ["declaration"])

    let highlights = try LSPConversion.semanticHighlights(tokens, legend: legend)

    XCTAssertEqual(highlights.count, 2)
    XCTAssertEqual(highlights[0].range.start, .init(line: 0, utf16Column: 2))
    XCTAssertEqual(highlights[0].modifiers, ["declaration"])
    XCTAssertEqual(highlights[1].range.start, .init(line: 1, utf16Column: 4))
    XCTAssertEqual(highlights[1].tokenType, "function")
  }
}
