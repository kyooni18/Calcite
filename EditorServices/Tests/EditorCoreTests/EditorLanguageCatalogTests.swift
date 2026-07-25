import XCTest
@testable import EditorCore

final class EditorLanguageCatalogTests: XCTestCase {
  func testStandardCatalogRecognizesBroadLanguageSet() {
    let catalog = EditorLanguageCatalog.standard
    XCTAssertEqual(catalog.languageID(forPath: "Sources/main.swift"), "swift")
    XCTAssertEqual(catalog.languageID(forPath: "Modules/Remote.swiftinterface"), "swift")
    XCTAssertEqual(catalog.languageID(forPath: "include/module.modulemap"), "c")
    XCTAssertEqual(catalog.languageID(forPath: "include/container.ipp"), "cpp")
    XCTAssertEqual(catalog.languageID(forPath: "src/main.py"), "python")
    XCTAssertEqual(catalog.languageID(forPath: "include/value.hpp"), "cpp")
    XCTAssertEqual(catalog.languageID(forPath: "src/lib.rs"), "rust")
    XCTAssertEqual(catalog.languageID(forPath: "web/app.tsx"), "typescriptreact")
    XCTAssertEqual(catalog.languageID(forPath: "CMakeLists.txt"), "cmake")
    XCTAssertEqual(catalog.languageID(forPath: "Dockerfile"), "dockerfile")
    XCTAssertEqual(catalog.languageID(forPath: "unknown.binary"), "plaintext")
  }

  func testAliasesResolveToCanonicalLanguageIDs() {
    let catalog = EditorLanguageCatalog.standard
    XCTAssertEqual(catalog.canonicalLanguageID(for: "C++"), "cpp")
    XCTAssertEqual(catalog.canonicalLanguageID(for: "py"), "python")
    XCTAssertEqual(catalog.canonicalLanguageID(for: "bash"), "shellscript")
    XCTAssertEqual(catalog.canonicalLanguageID(for: "custom-language"), "custom-language")
  }

  func testCustomCatalogCanOverrideFilenameAndFallback() {
    let catalog = EditorLanguageCatalog(
      definitions: [
        .init(id: "special", fileExtensions: ["sp"], fileNames: ["specialfile"])
      ],
      fallbackLanguageID: "unknown"
    )
    XCTAssertEqual(catalog.languageID(forPath: "folder/SpecialFile"), "special")
    XCTAssertEqual(catalog.languageID(forPath: "file.sp"), "special")
    XCTAssertEqual(catalog.languageID(forPath: "file.txt"), "unknown")
  }
}
