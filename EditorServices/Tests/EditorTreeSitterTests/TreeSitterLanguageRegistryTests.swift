import Foundation
import XCTest

@testable import EditorTreeSitter

final class TreeSitterLanguageRegistryTests: XCTestCase {
  func testSwiftRegistrationMatchesLanguageAndExtension() throws {
    let registration = try TreeSitterLanguageRegistry.swiftRegistration(priority: 10)
    let registry = try TreeSitterLanguageRegistry(registrations: [registration])

    XCTAssertEqual(
      registry.matchingRegistration(
        uri: URL(fileURLWithPath: "/tmp/main.swift"),
        languageID: "swift"
      )?.id,
      "tree-sitter-swift"
    )
    XCTAssertNil(
      registry.matchingRegistration(
        uri: URL(fileURLWithPath: "/tmp/main.rs"),
        languageID: "rust"
      )
    )
  }

  func testDuplicateRegistrationIsRejected() throws {
    let registration = try TreeSitterLanguageRegistry.swiftRegistration()
    let registry = try TreeSitterLanguageRegistry(registrations: [registration])

    XCTAssertThrowsError(try registry.register(registration)) { error in
      XCTAssertEqual(
        error as? TreeSitterLanguageRegistryError,
        .duplicateRegistration("tree-sitter-swift")
      )
    }
  }
}
