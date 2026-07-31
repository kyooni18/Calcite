import Foundation
import XCTest

@testable import EditorServiceKit

final class LanguageServiceSelectorTests: XCTestCase {
  func testSelectorNormalizesLanguageExtensionAndScheme() {
    let selector = LanguageServiceSelector(
      languageIDs: [" Swift "],
      fileExtensions: [".SWIFT"],
      urlSchemes: ["FILE"]
    )

    XCTAssertTrue(
      selector.matches(
        uri: URL(fileURLWithPath: "/tmp/main.swift"),
        languageID: "swift"
      )
    )
    XCTAssertFalse(
      selector.matches(
        uri: URL(fileURLWithPath: "/tmp/main.rs"),
        languageID: "rust"
      )
    )
  }
}
