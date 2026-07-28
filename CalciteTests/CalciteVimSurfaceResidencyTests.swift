import Foundation
import XCTest

@testable import Calcite

final class CalciteVimSurfaceResidencyTests: XCTestCase {
  func testResidencyRemainsBoundedWithManyDocuments() {
    let documents = (0..<100).map { _ in UUID() }
    var resident: [UUID] = []
    let available = Set(documents)

    for document in documents {
      resident = CalciteVimSurfaceResidencyPolicy.updatedDocumentIDs(
        current: resident,
        active: document,
        available: available,
        limit: 3
      )
      XCTAssertLessThanOrEqual(resident.count, 3)
      XCTAssertEqual(resident.first, document)
    }

    XCTAssertEqual(resident, Array(documents.suffix(3).reversed()))
  }

  func testResidencyDropsClosedDocumentsAndKeepsMRUOrder() {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let fourth = UUID()

    let resident = CalciteVimSurfaceResidencyPolicy.updatedDocumentIDs(
      current: [third, second, first],
      active: fourth,
      available: [first, third, fourth],
      limit: 3
    )

    XCTAssertEqual(resident, [fourth, third, first])
  }
}
