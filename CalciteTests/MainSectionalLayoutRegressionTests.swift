import AppKit
import SwiftUI
import XCTest

@testable import Calcite

@MainActor
final class MainSectionalLayoutRegressionTests: XCTestCase {
  func testSplitGeometryPersistsAcrossControllerRecreation() {
    withController { controller, workspaceURL, defaults in
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
  }

  func testSplittingEditorPreservesNeighboringPanelShare() {
    withController { controller, _, _ in
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

      guard
        let updatedSplit = controller.root.splitNodes.first(where: { $0.id == workbenchSplit.id })
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

      guard
        let insertedSectionID = Set(controller.root.sectionNodes.map(\.id))
          .subtracting(previousSectionIDs)
          .first
      else {
        return XCTFail("Expected a newly inserted editor section")
      }
      controller.removeSection(id: insertedSectionID)

      guard
        let collapsedSplit = controller.root.splitNodes.first(where: { $0.id == workbenchSplit.id })
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

  func testTemporarilyHiddenChildRecoversItsPreviousFraction() {
    withController { controller, _, _ in
      guard let split = controller.root.splitNodes.first(where: { $0.children.count == 2 }),
        let hiddenSectionID = split.children[0].sectionNodes.first?.id
      else {
        return XCTFail("Expected a hideable child in the standard layout")
      }
      let childIDs = split.children.map(\.id)
      controller.updateSplitFractions(
        splitID: split.id,
        visibleChildIDs: childIDs,
        fractions: [0.24, 0.76]
      )

      controller.setSectionVisible(false, for: hiddenSectionID)
      let visibleIDs =
        controller.root.splitNodes
        .first(where: { $0.id == split.id })?
        .children.filter(\.hasVisibleContent).map(\.id) ?? []
      XCTAssertEqual(visibleIDs.count, 1)
      XCTAssertEqual(
        controller.splitFractions(
          for: split.id,
          visibleChildIDs: visibleIDs,
          defaultSecondaryFraction: nil
        ),
        [1]
      )

      controller.setSectionVisible(true, for: hiddenSectionID)
      let restoredSplit = try! XCTUnwrap(
        controller.root.splitNodes.first(where: { $0.id == split.id })
      )
      let restored = controller.splitFractions(
        for: split.id,
        visibleChildIDs: restoredSplit.children.map(\.id),
        defaultSecondaryFraction: nil
      )
      XCTAssertEqual(restored[0], 0.24, accuracy: 0.0001)
      XCTAssertEqual(restored[1], 0.76, accuracy: 0.0001)
    }
  }

  func testInvalidFractionsAreSanitizedInsteadOfPersisted() {
    withController { controller, _, _ in
      guard let split = controller.root.splitNodes.first(where: { $0.children.count == 2 }) else {
        return XCTFail("Expected a two-child split")
      }
      let childIDs = split.children.map(\.id)
      controller.updateSplitFractions(
        splitID: split.id,
        visibleChildIDs: childIDs,
        fractions: [.nan, -4]
      )
      let resolved = controller.splitFractions(
        for: split.id,
        visibleChildIDs: childIDs,
        defaultSecondaryFraction: nil
      )
      XCTAssertEqual(resolved[0], 0.5, accuracy: 0.0001)
      XCTAssertEqual(resolved[1], 0.5, accuracy: 0.0001)
    }
  }

  func testActiveSectionAndSnapshotRestoreAcrossControllerRecreation() {
    withController { controller, workspaceURL, defaults in
      guard let target = controller.root.visibleSectionIDs.last else {
        return XCTFail("Expected a visible section")
      }
      controller.activateSection(target)
      let snapshot = controller.captureSnapshot()

      let restored = MainSectionalLayoutController(
        workspaceURL: workspaceURL,
        defaults: defaults,
        includesSidebarByDefault: true
      )
      XCTAssertEqual(restored.activeSectionID, target)

      restored.reset()
      restored.restoreSnapshot(snapshot)
      XCTAssertEqual(restored.captureSnapshot(), snapshot)
    }
  }

  func testCanonicalWorkspacePathSharesPersistedLayout() throws {
    let suiteName = "CalciteTests.layout.canonical.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteTests")
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let target = root.appendingPathComponent("Workspace", isDirectory: true)
    let alias = root.appendingPathComponent("WorkspaceAlias", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    defer { try? FileManager.default.removeItem(at: root) }

    let controller = MainSectionalLayoutController(
      workspaceURL: alias,
      defaults: defaults,
      includesSidebarByDefault: true
    )
    guard let split = controller.root.splitNodes.first, split.children.count == 2 else {
      return XCTFail("Expected a two-child split")
    }
    controller.updateSplitFractions(
      splitID: split.id,
      visibleChildIDs: split.children.map(\.id),
      fractions: [0.37, 0.63]
    )

    let restored = MainSectionalLayoutController(
      workspaceURL: target,
      defaults: defaults,
      includesSidebarByDefault: true
    )
    let restoredSplit = try XCTUnwrap(
      restored.root.splitNodes.first(where: { $0.id == split.id })
    )
    let fractions = restored.splitFractions(
      for: restoredSplit.id,
      visibleChildIDs: restoredSplit.children.map(\.id),
      defaultSecondaryFraction: nil
    )
    XCTAssertEqual(fractions[0], 0.37, accuracy: 0.0001)
    XCTAssertEqual(fractions[1], 0.63, accuracy: 0.0001)
  }

  func testVisibilitySpecificGeometryDoesNotOverwriteFullConfiguration() {
    withController { controller, _, _ in
      guard let split = controller.root.splitNodes.first(where: { $0.children.count == 2 }) else {
        return XCTFail("Expected a two-child split")
      }
      let childIDs = split.children.map(\.id)
      let fullConfiguration = "full"
      let compactConfiguration = "compact"

      controller.updateSplitFractions(
        splitID: split.id,
        visibleChildIDs: childIDs,
        configurationID: fullConfiguration,
        fractions: [0.30, 0.70]
      )
      controller.updateSplitFractions(
        splitID: split.id,
        visibleChildIDs: childIDs,
        configurationID: compactConfiguration,
        fractions: [0.08, 0.92]
      )

      let full = controller.splitFractions(
        for: split.id,
        visibleChildIDs: childIDs,
        configurationID: fullConfiguration,
        defaultSecondaryFraction: nil
      )
      let compact = controller.splitFractions(
        for: split.id,
        visibleChildIDs: childIDs,
        configurationID: compactConfiguration,
        defaultSecondaryFraction: nil
      )
      XCTAssertEqual(full[0], 0.30, accuracy: 0.0001)
      XCTAssertEqual(full[1], 0.70, accuracy: 0.0001)
      XCTAssertEqual(compact[0], 0.08, accuracy: 0.0001)
      XCTAssertEqual(compact[1], 0.92, accuracy: 0.0001)
    }
  }

  func testEachCompletedGeometryCommitIsOneUndoTransaction() {
    withController { controller, _, _ in
      guard let split = controller.root.splitNodes.first(where: { $0.children.count == 2 }) else {
        return XCTFail("Expected a two-child split")
      }
      let childIDs = split.children.map(\.id)
      controller.updateSplitFractions(
        splitID: split.id,
        visibleChildIDs: childIDs,
        fractions: [0.35, 0.65]
      )
      controller.updateSplitFractions(
        splitID: split.id,
        visibleChildIDs: childIDs,
        fractions: [0.42, 0.58]
      )

      controller.undo()
      var fractions = controller.splitFractions(
        for: split.id,
        visibleChildIDs: childIDs,
        defaultSecondaryFraction: nil
      )
      XCTAssertEqual(fractions[0], 0.35, accuracy: 0.0001)
      XCTAssertEqual(fractions[1], 0.65, accuracy: 0.0001)

      controller.redo()
      fractions = controller.splitFractions(
        for: split.id,
        visibleChildIDs: childIDs,
        defaultSecondaryFraction: nil
      )
      XCTAssertEqual(fractions[0], 0.42, accuracy: 0.0001)
      XCTAssertEqual(fractions[1], 0.58, accuracy: 0.0001)
    }
  }

  func testWindowSnapshotRestoreDoesNotReplaceWorkspaceFallback() {
    withController { controller, workspaceURL, defaults in
      guard let split = controller.root.splitNodes.first(where: { $0.children.count == 2 }) else {
        return XCTFail("Expected a two-child split")
      }
      let childIDs = split.children.map(\.id)

      controller.updateSplitFractions(
        splitID: split.id,
        visibleChildIDs: childIDs,
        fractions: [0.31, 0.69]
      )
      let workspaceFallback = controller.captureSnapshot()

      controller.updateSplitFractions(
        splitID: split.id,
        visibleChildIDs: childIDs,
        fractions: [0.44, 0.56]
      )
      let windowSnapshot = controller.captureSnapshot()

      controller.restoreSnapshot(workspaceFallback)
      controller.restoreSnapshot(windowSnapshot, persistWorkspaceFallback: false)
      controller.updateSplitFractions(
        splitID: split.id,
        visibleChildIDs: childIDs,
        fractions: [0.48, 0.52]
      )

      let currentWindowFractions = controller.splitFractions(
        for: split.id,
        visibleChildIDs: childIDs,
        defaultSecondaryFraction: nil
      )
      XCTAssertEqual(currentWindowFractions[0], 0.48, accuracy: 0.0001)

      let newWindow = MainSectionalLayoutController(
        workspaceURL: workspaceURL,
        defaults: defaults,
        includesSidebarByDefault: true
      )
      let fallbackFractions = newWindow.splitFractions(
        for: split.id,
        visibleChildIDs: childIDs,
        defaultSecondaryFraction: nil
      )
      XCTAssertEqual(fallbackFractions[0], 0.31, accuracy: 0.0001)
      XCTAssertEqual(fallbackFractions[1], 0.69, accuracy: 0.0001)
    }
  }

  func testGeometryStressKeepsEveryConfigurationFiniteAndNormalized() {
    let splitID = UUID()
    let childIDs = [UUID(), UUID(), UUID()]
    var geometry = MainSectionSplitGeometry(splitID: splitID)

    for index in 0..<500 {
      let a = Double((index * 17) % 97 + 1)
      let b = Double((index * 31) % 89 + 1)
      let c = Double((index * 47) % 83 + 1)
      let configuration = "state-\(index % 7)"
      geometry.update(
        childIDs: childIDs,
        fractions: [a, b, c],
        configurationID: configuration
      )
      let resolved = geometry.resolvedFractions(
        for: childIDs,
        configurationID: configuration,
        fallback: [1, 1, 1]
      )
      XCTAssertTrue(resolved.allSatisfy { $0.isFinite && $0 > 0 })
      XCTAssertEqual(resolved.reduce(0, +), 1, accuracy: 0.000_001)
    }
  }

  func testOwnedSplitIgnoresUnrelatedSwiftUIUpdates() {
    let stableID = UUID()
    let split = MainSectionOwnedNSSplitView(
      frame: NSRect(x: 0, y: 0, width: 1_000, height: 700)
    )
    let children = makeOwnedSplitChildren()
    split.configure(
      splitID: stableID,
      axis: .horizontal,
      configurationID: "visible",
      children: children,
      preferredFractions: [0.30, 0.70],
      onPreferredFractionsChanged: { _ in }
    )
    split.layoutSubtreeIfNeeded()

    split.setPosition(420, ofDividerAt: 0)
    let before = split.arrangedSubviews[0].frame.width

    // This is equivalent to SwiftUI re-evaluating the representable because editor/terminal state
    // changed. Identical model geometry must not be pushed back into NSSplitView.
    split.configure(
      splitID: stableID,
      axis: .horizontal,
      configurationID: "visible",
      children: children,
      preferredFractions: [0.30, 0.70],
      onPreferredFractionsChanged: { _ in }
    )
    split.layoutSubtreeIfNeeded()

    XCTAssertEqual(split.arrangedSubviews[0].frame.width, before, accuracy: 1)
  }

  func testOwnedSplitConfigurationChangeRestoresEvenWhenFractionsAreNumericallyEqual() {
    let splitID = UUID()
    let split = MainSectionOwnedNSSplitView(
      frame: NSRect(x: 0, y: 0, width: 1_000, height: 700)
    )
    let children = makeOwnedSplitChildren()
    split.configure(
      splitID: splitID,
      axis: .horizontal,
      configurationID: "full",
      children: children,
      preferredFractions: [0.30, 0.70],
      onPreferredFractionsChanged: { _ in }
    )
    split.layoutSubtreeIfNeeded()

    split.setPosition(80, ofDividerAt: 0)
    XCTAssertLessThan(split.arrangedSubviews[0].frame.width, 150)

    split.configure(
      splitID: splitID,
      axis: .horizontal,
      configurationID: "shown-again",
      children: children,
      preferredFractions: [0.30, 0.70],
      onPreferredFractionsChanged: { _ in }
    )
    split.layoutSubtreeIfNeeded()

    XCTAssertEqual(split.arrangedSubviews[0].frame.width, 300, accuracy: 4)
  }

  func testOwnedSplitPreservesSurvivingHostingViewAcrossVisibilityTopologyChange() {
    let splitID = UUID()
    let split = MainSectionOwnedNSSplitView(
      frame: NSRect(x: 0, y: 0, width: 1_000, height: 700)
    )
    let children = makeOwnedSplitChildren()
    split.configure(
      splitID: splitID,
      axis: .horizontal,
      configurationID: "both",
      children: children,
      preferredFractions: [0.30, 0.70],
      onPreferredFractionsChanged: { _ in }
    )
    split.layoutSubtreeIfNeeded()
    let survivingView = split.arrangedSubviews[1]

    split.configure(
      splitID: splitID,
      axis: .horizontal,
      configurationID: "editor-only",
      children: [children[1]],
      preferredFractions: [1],
      onPreferredFractionsChanged: { _ in }
    )
    split.layoutSubtreeIfNeeded()
    XCTAssertTrue(split.arrangedSubviews[0] === survivingView)

    split.configure(
      splitID: splitID,
      axis: .horizontal,
      configurationID: "both-again",
      children: children,
      preferredFractions: [0.30, 0.70],
      onPreferredFractionsChanged: { _ in }
    )
    split.layoutSubtreeIfNeeded()
    XCTAssertTrue(split.arrangedSubviews[1] === survivingView)
  }

  func testOwnedSplitEnforcesMinimumPaneThickness() {
    let split = MainSectionOwnedNSSplitView(
      frame: NSRect(x: 0, y: 0, width: 1_000, height: 700)
    )
    let children = makeOwnedSplitChildren()
    split.configure(
      splitID: UUID(),
      axis: .horizontal,
      configurationID: "visible",
      children: children,
      preferredFractions: [0.30, 0.70],
      onPreferredFractionsChanged: { _ in }
    )
    split.layoutSubtreeIfNeeded()

    split.setPosition(10, ofDividerAt: 0)
    XCTAssertGreaterThanOrEqual(split.arrangedSubviews[0].frame.width, 79)

    split.setPosition(990, ofDividerAt: 0)
    XCTAssertGreaterThanOrEqual(split.arrangedSubviews[1].frame.width, 199)
  }

  func testOwnedSplitRestoresPreferredGeometryAfterTemporaryResizeClamp() {
    let split = MainSectionOwnedNSSplitView(
      frame: NSRect(x: 0, y: 0, width: 1_000, height: 700)
    )
    let children = makeOwnedSplitChildren()
    split.configure(
      splitID: UUID(),
      axis: .horizontal,
      configurationID: "visible",
      children: children,
      preferredFractions: [0.30, 0.70],
      onPreferredFractionsChanged: { _ in }
    )
    split.layoutSubtreeIfNeeded()
    let preferredWidth = split.arrangedSubviews[0].frame.width

    split.frame.size.width = 340
    split.needsLayout = true
    split.layoutSubtreeIfNeeded()
    XCTAssertLessThan(split.arrangedSubviews[0].frame.width, preferredWidth)

    split.frame.size.width = 1_000
    split.needsLayout = true
    split.layoutSubtreeIfNeeded()
    split.restorePreferredGeometryAfterResizeIfPossible()
    split.layoutSubtreeIfNeeded()
    XCTAssertEqual(split.arrangedSubviews[0].frame.width, preferredWidth, accuracy: 4)
  }

  func testOwnedSplitWindowResizeNeverCommitsPreferredGeometry() {
    var commitCount = 0
    let split = MainSectionOwnedNSSplitView(
      frame: NSRect(x: 0, y: 0, width: 1_000, height: 700)
    )
    let children = makeOwnedSplitChildren()
    split.configure(
      splitID: UUID(),
      axis: .horizontal,
      configurationID: "visible",
      children: children,
      preferredFractions: [0.28, 0.72],
      onPreferredFractionsChanged: { _ in commitCount += 1 }
    )
    split.layoutSubtreeIfNeeded()

    for width in stride(from: 980, through: 520, by: -20) {
      split.frame.size.width = CGFloat(width)
      split.needsLayout = true
      split.layoutSubtreeIfNeeded()
    }
    for width in stride(from: 540, through: 1_000, by: 20) {
      split.frame.size.width = CGFloat(width)
      split.needsLayout = true
      split.layoutSubtreeIfNeeded()
    }

    XCTAssertEqual(commitCount, 0)
  }

  private func makeOwnedSplitChildren() -> [MainSectionOwnedSplitChild] {
    [
      MainSectionOwnedSplitChild(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        content: AnyView(Color.clear),
        minimumThickness: 80,
        holdingPriority: NSLayoutConstraint.Priority(rawValue: 350)
      ),
      MainSectionOwnedSplitChild(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
        content: AnyView(Color.clear),
        minimumThickness: 200,
        holdingPriority: NSLayoutConstraint.Priority(rawValue: 250)
      ),
    ]
  }

  private func withController(
    _ body: (
      MainSectionalLayoutController,
      URL,
      UserDefaults
    ) -> Void
  ) {
    let suiteName = "CalciteTests.layout.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let workspaceURL = URL(fileURLWithPath: "/tmp/CalciteTests/\(UUID().uuidString)")
    let controller = MainSectionalLayoutController(
      workspaceURL: workspaceURL,
      defaults: defaults,
      includesSidebarByDefault: true
    )
    body(controller, workspaceURL, defaults)
  }
}
