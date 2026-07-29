import Foundation
import XCTest

@testable import Calcite

final class CalciteStateStorageTests: XCTestCase {
  private struct Value: Codable, Equatable {
    var name: String
    var count: Int
  }

  func testAtomicStateStorageFallsBackToBackup() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteStateStorageTests-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("state.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    try CalciteStateStorage.save(Value(name: "first", count: 1), to: url)
    try CalciteStateStorage.save(Value(name: "second", count: 2), to: url)
    try Data("not-json".utf8).write(to: url, options: [.atomic])

    XCTAssertEqual(CalciteStateStorage.load(Value.self, from: url), Value(name: "first", count: 1))
  }
  func testCorruptedPrimaryAndBackupAreQuarantined() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteStateStorageTests-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("state.json")
    let backup = url.appendingPathExtension("backup")
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("bad-primary".utf8).write(to: url)
    try Data("bad-backup".utf8).write(to: backup)

    XCTAssertNil(CalciteStateStorage.load(Value.self, from: url))
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    let quarantine = directory.appendingPathComponent("Quarantine", isDirectory: true)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count, 2)
  }

  func testRemoveDeletesPrimaryAndBackup() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteStateStorageTests-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("state.json")
    let backup = url.appendingPathExtension("backup")
    defer { try? FileManager.default.removeItem(at: directory) }

    try CalciteStateStorage.save(Value(name: "first", count: 1), to: url)
    try CalciteStateStorage.save(Value(name: "second", count: 2), to: url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

    try CalciteStateStorage.remove(at: url)

    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
  }

}
