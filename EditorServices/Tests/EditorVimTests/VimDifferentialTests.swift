import EditorVim
import Foundation
import XCTest

final class VimDifferentialTests: XCTestCase {
  private struct Fixture: Decodable {
    let name: String
    let initialText: String
    let initialCursor: Int
    let notation: String
    let expectedText: String
    let expectedCursor: Int
  }

  func testDeterministicSystemVimFixtures() throws {
    let fixtureURL = Bundle.module.url(
      forResource: "vim-differential",
      withExtension: "json",
      subdirectory: "Fixtures"
    )!
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixtureURL))

    XCTAssertGreaterThanOrEqual(fixtures.count, 500)
    for fixture in fixtures {
      let engine = VimEngine(text: fixture.initialText, cursor: fixture.initialCursor)
      do {
        try engine.executeNotation(fixture.notation)
      } catch {
        XCTFail("Fixture \(fixture.name) threw \(error)")
        continue
      }
      XCTAssertEqual(engine.state.text, fixture.expectedText, "Text mismatch: \(fixture.name)")
      XCTAssertEqual(
        engine.state.cursor, fixture.expectedCursor, "Cursor mismatch: \(fixture.name)")
      XCTAssertEqual(engine.state.mode, .normal, "Mode mismatch: \(fixture.name)")
    }
  }
}
