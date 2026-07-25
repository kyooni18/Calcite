import XCTest
@testable import EditorCore
@testable import EditorWorkspace

final class SourceWorkspaceLanguageCatalogTests: XCTestCase {
  func testCustomCatalogDrivesWorkspaceScan() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "content".write(
      to: root.appendingPathComponent("sample.custom"),
      atomically: true,
      encoding: .utf8
    )
    let catalog = EditorLanguageCatalog(
      definitions: [.init(id: "custom-language", fileExtensions: ["custom"])]
    )
    let workspace = SourceWorkspace(
      rootURL: root,
      configuration: .init(
        includedFileExtensions: ["custom"],
        languageCatalog: catalog
      )
    )
    _ = try await workspace.scan()
    let file = try await workspace.file(relativePath: "sample.custom")
    XCTAssertEqual(file.languageID, "custom-language")
  }

  func testLegacyConfigurationDecodingDefaultsLanguageCatalog() throws {
    let data = Data(#"""
{
      "includedFileExtensions":["swift"],
      "excludedDirectoryNames":[".git"],
      "excludedFileNames":[],
      "includeHiddenItems":false,
      "followSymbolicLinks":false,
      "maximumFileSize":1024
}
"""#.utf8)
    let decoded = try JSONDecoder().decode(SourceWorkspaceConfiguration.self, from: data)
    XCTAssertEqual(decoded.languageCatalog.languageID(forPath: "main.py"), "python")
    XCTAssertEqual(decoded.maximumFileSize, 1024)
  }
}
