import Foundation
import XCTest

@testable import Calcite

@MainActor
final class MainSectionalLayoutProfileTests: XCTestCase {
  func testSplitGeometrySurvivesFastPanelVisibilityChangesAndReload() {
    let harness = makeHarness()
    defer { harness.cleanUp() }
    guard let split = harness.controller.root.splitNodes.first else {
      return XCTFail("The standard layout should contain a split.")
    }
    let childIDs = split.children.map(\.id)

    harness.controller.updateSplitFractions(
      splitID: split.id,
      visibleChildIDs: childIDs,
      fractions: [0.73, 0.27]
    )
    if let panelID = split.children.last?.id {
      harness.controller.setSectionVisibility(id: panelID, visible: false)
      harness.controller.setSectionVisibility(id: panelID, visible: true)
    }

    assertEqualFractions(
      harness.controller.splitFractions(
        for: split.id,
        visibleChildIDs: childIDs,
        defaultSecondaryFraction: nil
      ),
      [0.73, 0.27],
      accuracy: 0.0001
    )

    let reopened = MainSectionalLayoutController(
      workspaceURL: harness.workspaceURL,
      defaults: harness.defaults,
      includesSidebarByDefault: false
    )
    assertEqualFractions(
      reopened.splitFractions(
        for: split.id,
        visibleChildIDs: childIDs,
        defaultSecondaryFraction: nil
      ),
      [0.73, 0.27],
      accuracy: 0.0001
    )
  }

  func testCustomProfileRestoresTopologyAndDividerGeometry() {
    let harness = makeHarness()
    defer { harness.cleanUp() }
    guard let split = harness.controller.root.splitNodes.first else {
      return XCTFail("The standard layout should contain a split.")
    }
    let childIDs = split.children.map(\.id)
    harness.controller.updateSplitFractions(
      splitID: split.id,
      visibleChildIDs: childIDs,
      fractions: [0.64, 0.36]
    )
    let profileID = harness.controller.saveCurrentLayoutProfile(named: "Focused Debug")
    let savedRoot = harness.controller.root

    harness.controller.applyPreset(.sideBySide)
    XCTAssertNotEqual(harness.controller.root, savedRoot)

    harness.controller.applyLayoutProfile(id: profileID)
    XCTAssertEqual(harness.controller.root, savedRoot)
    assertEqualFractions(
      harness.controller.splitFractions(
        for: split.id,
        visibleChildIDs: childIDs,
        defaultSecondaryFraction: nil
      ),
      [0.64, 0.36],
      accuracy: 0.0001
    )
  }

  func testWrappingASectionInANestedSplitPreservesParentFraction() {
    let harness = makeHarness()
    defer { harness.cleanUp() }
    guard let rootSplit = harness.controller.root.splitNodes.first,
      let editorSection = rootSplit.children.first
    else { return XCTFail("The standard layout should contain editor and panel children.") }
    harness.controller.updateSplitFractions(
      splitID: rootSplit.id,
      visibleChildIDs: rootSplit.children.map(\.id),
      fractions: [0.68, 0.32]
    )

    harness.controller.splitSection(
      id: editorSection.id,
      axis: .horizontal,
      newKind: .editor
    )

    guard let updatedRoot = harness.controller.root.splitNodes.first else {
      return XCTFail("The root split should remain present.")
    }
    assertEqualFractions(
      harness.controller.splitFractions(
        for: updatedRoot.id,
        visibleChildIDs: updatedRoot.children.map(\.id),
        defaultSecondaryFraction: nil
      ),
      [0.68, 0.32],
      accuracy: 0.0001
    )
  }

  func testSameAxisInsertionSplitsOnlyTheEditedSectionsShare() {
    let harness = makeHarness()
    defer { harness.cleanUp() }
    guard let rootSplit = harness.controller.root.splitNodes.first,
      let editorSection = rootSplit.children.first
    else { return XCTFail("The standard layout should contain editor and panel children.") }
    harness.controller.updateSplitFractions(
      splitID: rootSplit.id,
      visibleChildIDs: rootSplit.children.map(\.id),
      fractions: [0.7, 0.3]
    )

    harness.controller.splitSection(
      id: editorSection.id,
      axis: .vertical,
      newKind: .editor
    )

    guard let updatedRoot = harness.controller.root.splitNodes.first else {
      return XCTFail("The root split should remain present.")
    }
    XCTAssertEqual(updatedRoot.children.count, 3)
    assertEqualFractions(
      harness.controller.splitFractions(
        for: updatedRoot.id,
        visibleChildIDs: updatedRoot.children.map(\.id),
        defaultSecondaryFraction: nil
      ),
      [0.35, 0.35, 0.3],
      accuracy: 0.0001
    )
  }

  func testGeometryNormalizationRejectsInvalidFractions() {
    let first = UUID()
    let second = UUID()
    var geometry = MainSectionSplitGeometry(splitID: UUID())

    geometry.update(childIDs: [first, second], fractions: [.infinity, -1])

    assertEqualFractions(
      geometry.resolvedFractions(for: [first, second], fallback: [0.8, 0.2]),
      [0.5, 0.5],
      accuracy: 0.0001
    )
  }

  func testDividerResizeParticipatesInLayoutUndoAndRedo() {
    let harness = makeHarness()
    defer { harness.cleanUp() }
    guard let split = harness.controller.root.splitNodes.first else {
      return XCTFail("The standard layout should contain a split.")
    }
    let childIDs = split.children.map(\.id)

    harness.controller.updateSplitFractions(
      splitID: split.id,
      visibleChildIDs: childIDs,
      fractions: [0.6, 0.4]
    )
    harness.controller.undo()
    assertEqualFractions(
      harness.controller.splitFractions(
        for: split.id,
        visibleChildIDs: childIDs,
        defaultSecondaryFraction: nil
      ),
      [0.78, 0.22],
      accuracy: 0.0001
    )

    harness.controller.redo()
    assertEqualFractions(
      harness.controller.splitFractions(
        for: split.id,
        visibleChildIDs: childIDs,
        defaultSecondaryFraction: nil
      ),
      [0.6, 0.4],
      accuracy: 0.0001
    )
  }

  private func makeHarness() -> LayoutProfileHarness {
    let suiteName = "CalciteTests.LayoutProfiles.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let workspaceURL = URL(fileURLWithPath: "/tmp/\(suiteName)")
    return LayoutProfileHarness(
      controller: MainSectionalLayoutController(
        workspaceURL: workspaceURL,
        defaults: defaults,
        includesSidebarByDefault: false
      ),
      workspaceURL: workspaceURL,
      defaults: defaults,
      suiteName: suiteName
    )
  }
}

@MainActor
private struct LayoutProfileHarness {
  let controller: MainSectionalLayoutController
  let workspaceURL: URL
  let defaults: UserDefaults
  let suiteName: String

  func cleanUp() {
    defaults.removePersistentDomain(forName: suiteName)
  }
}

private extension XCTestCase {
  func assertEqualFractions(
    _ lhs: [Double],
    _ rhs: [Double],
    accuracy: Double,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (left, right) in zip(lhs, rhs) {
      XCTAssertEqual(left, right, accuracy: accuracy, file: file, line: line)
    }
  }
}
