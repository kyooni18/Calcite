import XCTest

@testable import Calcite

@MainActor
final class MainSectionalVimTopologyTests: XCTestCase {
  func testVisibleVimWindowsExcludeUtilityOnlySections() {
    let firstEditor = MainSectionLayoutNode.section(.editor)
    let terminal = MainSectionLayoutNode.section(.terminal)
    let secondEditor = MainSectionLayoutNode.section(.workspace)
    let root = MainSectionLayoutNode.split(
      .horizontal,
      children: [firstEditor, terminal, secondEditor]
    )

    XCTAssertEqual(
      root.visibleVimEditorSectionIDs,
      [firstEditor.id, secondEditor.id]
    )
  }

  func testDirectionalNavigationUsesNestedSectionLayoutTopology() {
    let left = MainSectionLayoutNode.section(.editor)
    let upperRight = MainSectionLayoutNode.section(.editor)
    let utility = MainSectionLayoutNode.section(.problems)
    let lowerRight = MainSectionLayoutNode.section(.workspace)
    let right = MainSectionLayoutNode.split(
      .vertical,
      children: [upperRight, utility, lowerRight]
    )
    let root = MainSectionLayoutNode.split(.horizontal, children: [left, right])

    XCTAssertEqual(
      root.neighboringVimEditorSectionID(from: left.id, direction: .right),
      upperRight.id
    )
    XCTAssertEqual(
      root.neighboringVimEditorSectionID(from: upperRight.id, direction: .down),
      lowerRight.id
    )
    XCTAssertEqual(
      root.neighboringVimEditorSectionID(from: lowerRight.id, direction: .up),
      upperRight.id
    )
    XCTAssertEqual(
      root.neighboringVimEditorSectionID(from: upperRight.id, direction: .left),
      left.id
    )
  }

  func testVimSplitReturnsPersistentSectionAndEditorTabIdentities() {
    let harness = makeController()
    defer { harness.cleanUp() }
    guard let source = harness.controller.root.visibleVimEditorSectionIDs.first else {
      return XCTFail("The standard layout should contain an editor section.")
    }

    guard
      let created = harness.controller.splitVimEditorSection(
        id: source,
        axis: .horizontal
      )
    else { return XCTFail("The editor section should be splittable.") }

    XCTAssertEqual(harness.controller.activeSectionID, created.sectionID)
    XCTAssertEqual(
      harness.controller.root.vimEditorTabID(in: created.sectionID),
      created.editorTabID
    )
    XCTAssertNotNil(harness.controller.root.sectionNode(id: source))
  }

  func testVimWindowCycleSkipsTerminalAndProblemsSections() {
    let harness = makeController()
    defer { harness.cleanUp() }
    guard let first = harness.controller.root.visibleVimEditorSectionIDs.first,
      let second = harness.controller.splitVimEditorSection(id: first, axis: .horizontal)
    else { return XCTFail("The test layout should contain two editor windows.") }

    harness.controller.presentTab(.problems)
    _ = harness.controller.activateVimEditorSection(first)

    XCTAssertEqual(
      harness.controller.navigateVimEditorSection(forward: true),
      second.sectionID
    )
    XCTAssertEqual(
      harness.controller.navigateVimEditorSection(forward: true),
      first
    )
  }

  private func makeController() -> ControllerHarness {
    let suiteName = "CalciteTests.MainSectionalVimTopology.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let controller = MainSectionalLayoutController(
      workspaceURL: URL(fileURLWithPath: "/tmp/\(suiteName)"),
      defaults: defaults,
      includesSidebarByDefault: false
    )
    return ControllerHarness(
      controller: controller,
      defaults: defaults,
      suiteName: suiteName
    )
  }
}

@MainActor
private struct ControllerHarness {
  let controller: MainSectionalLayoutController
  let defaults: UserDefaults
  let suiteName: String

  func cleanUp() {
    defaults.removePersistentDomain(forName: suiteName)
  }
}
