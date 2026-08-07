import Foundation
import XCTest

@testable import Calcite

final class WorkspaceViewportPersistenceTests: XCTestCase {
  func testViewportAnchorRoundTripsWithHorizontalAndVerticalScrollOffsets() throws {
    let documentID = UUID()
    let snapshot = WorkspaceEditorPresentationSnapshot(
      editorSessionID: UUID(),
      documentID: documentID,
      selectedRange: WorkspaceTextRangeSnapshot(NSRange(location: 42, length: 0)),
      horizontalScrollOffset: 731.5,
      verticalScrollOffset: 2_048.25,
      zoomScale: 1,
      viewportAnchor: WorkspaceEditorViewportAnchorSnapshot(
        characterOffset: 1_337,
        verticalOffset: 5.75
      ),
      documentPresentations: [
        WorkspaceDocumentPresentationSnapshot(
          documentID: documentID,
          selectedRange: WorkspaceTextRangeSnapshot(NSRange(location: 42, length: 0)),
          horizontalScrollOffset: 731.5,
          verticalScrollOffset: 2_048.25,
          zoomScale: 1,
          viewportAnchor: WorkspaceEditorViewportAnchorSnapshot(
            characterOffset: 1_337,
            verticalOffset: 5.75
          )
        )
      ]
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(WorkspaceEditorPresentationSnapshot.self, from: data)

    XCTAssertEqual(decoded.horizontalScrollOffset, 731.5, accuracy: 0.0001)
    XCTAssertEqual(decoded.verticalScrollOffset, 2_048.25, accuracy: 0.0001)
    XCTAssertEqual(decoded.viewportAnchor?.characterOffset, 1_337)
    XCTAssertEqual(decoded.viewportAnchor?.verticalOffset ?? 0, 5.75, accuracy: 0.0001)
    XCTAssertEqual(decoded.documentPresentations.first?.viewportAnchor?.characterOffset, 1_337)
  }

  func testLegacyEditorPresentationWithoutViewportAnchorStillDecodes() throws {
    let editorID = UUID()
    let documentID = UUID()
    let json = """
      {
        "editorSessionID":"\(editorID.uuidString)",
        "documentID":"\(documentID.uuidString)",
        "selectedRange":{"location":0,"length":0},
        "horizontalScrollOffset":512,
        "verticalScrollOffset":1024,
        "zoomScale":1,
        "documentPresentations":[]
      }
      """

    let decoded = try JSONDecoder().decode(
      WorkspaceEditorPresentationSnapshot.self,
      from: Data(json.utf8)
    )

    XCTAssertEqual(decoded.horizontalScrollOffset, 512, accuracy: 0.0001)
    XCTAssertEqual(decoded.verticalScrollOffset, 1024, accuracy: 0.0001)
    XCTAssertNil(decoded.viewportAnchor)
  }
}
