import XCTest
@testable import Calcite

@MainActor
final class MainSectionalLayoutRegressionTests: XCTestCase {
  func testSplitGeometryPersistsAcrossControllerRecreation() {
    let suiteName = "CalciteTests.layout.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let workspaceURL = URL(fileURLWithPath: "/tmp/CalciteTests/\(UUID().uuidString)")

    let controller = MainSectionalLayoutController(
      workspaceURL: workspaceURL,
      defaults: defaults,
      includesSidebarByDefault: true
    )
    guard let split = controller.root.splitNodes.first, split.children.count == 2 else {
      return XCTFail("Expected a two-child split in the standard layout")
    }

    let childIDs = split.children.map(\.id)
    controller.updateSplitFractions(
      splitID: split.id,
      visibleChildIDs: childIDs,
      fractions: [0.31, 0.69]
    )

    let restored = MainSectionalLayoutController(
      workspaceURL: workspaceURL,
      defaults: defaults,
      includesSidebarByDefault: true
    )
    guard let restoredSplit = restored.root.splitNodes.first(where: { $0.id == split.id }) else {
      return XCTFail("Expected the persisted split to be restored")
    }
    let restoredFractions = restored.splitFractions(
      for: restoredSplit.id,
      visibleChildIDs: restoredSplit.children.map(\.id),
      defaultSecondaryFraction: nil
    )

    XCTAssertEqual(restoredFractions[0], 0.31, accuracy: 0.0001)
    XCTAssertEqual(restoredFractions[1], 0.69, accuracy: 0.0001)
  }

  func testSplittingEditorPreservesNeighboringPanelShare() {
    let suiteName = "CalciteTests.layout.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let workspaceURL = URL(fileURLWithPath: "/tmp/CalciteTests/\(UUID().uuidString)")

    let controller = MainSectionalLayoutController(
      workspaceURL: workspaceURL,
      defaults: defaults,
      includesSidebarByDefault: true
    )
    guard
      let workbenchSplit = controller.root.splitNodes.first(where: { split in
        split.splitAxis == .vertical
          && split.children.count == 2
          && split.children[0].contains(kind: .editor)
          && split.children[1].sectionKinds.contains(where: \.isBottomPanelKind)
      }),
      let editorSectionID = workbenchSplit.children[0].sectionNodes.first(where: {
        $0.contains(kind: .editor)
      })?.id
    else {
      return XCTFail("Expected the standard editor and bottom-panel split")
    }

    controller.updateSplitFractions(
      splitID: workbenchSplit.id,
      visibleChildIDs: workbenchSplit.children.map(\.id),
      fractions: [0.72, 0.28]
    )
    let previousSectionIDs = Set(controller.root.sectionNodes.map(\.id))

    controller.splitSection(
      id: editorSectionID,
      axis: .horizontal,
      newKind: .editor
    )

    guard let updatedSplit = controller.root.splitNodes.first(where: { $0.id == workbenchSplit.id })
    else {
      return XCTFail("Expected the surrounding split identity to remain stable")
    }
    var fractions = controller.splitFractions(
      for: updatedSplit.id,
      visibleChildIDs: updatedSplit.children.map(\.id),
      defaultSecondaryFraction: nil
    )
    XCTAssertEqual(fractions[0], 0.72, accuracy: 0.0001)
    XCTAssertEqual(fractions[1], 0.28, accuracy: 0.0001)

    guard let insertedSectionID = Set(controller.root.sectionNodes.map(\.id))
      .subtracting(previousSectionIDs)
      .first
    else {
      return XCTFail("Expected a newly inserted editor section")
    }
    controller.removeSection(id: insertedSectionID)

    guard let collapsedSplit = controller.root.splitNodes.first(where: { $0.id == workbenchSplit.id })
    else {
      return XCTFail("Expected the surrounding split after closing the inserted section")
    }
    fractions = controller.splitFractions(
      for: collapsedSplit.id,
      visibleChildIDs: collapsedSplit.children.map(\.id),
      defaultSecondaryFraction: nil
    )
    XCTAssertEqual(fractions[0], 0.72, accuracy: 0.0001)
    XCTAssertEqual(fractions[1], 0.28, accuracy: 0.0001)
  }
}
