@_spi(Calcite) import EditorVim
import Foundation
import XCTest

@testable import Calcite

@MainActor
final class CalciteVimStateRestorationTests: XCTestCase {
  func testTabRoundTripRestoresCachedVimStateBeforeEditorActivation() async throws {
    let harness = try makeHarness()
    defer { harness.cleanUp() }

    let backend = CalciteBackend(workspaceURL: harness.workspaceURL)
    let session = backend.makeWindowSession(defaults: harness.defaults)
    let lifecycle = await backend.start()
    guard lifecycle == .running else {
      return XCTFail("Workspace failed to start: \(lifecycle)")
    }

    guard let editor = await session.openDocument(at: harness.firstFileURL),
      let firstDocument = editor.document
    else {
      return XCTFail("The first document should open in an editor session.")
    }

    let firstController = session.vimSessionCoordinator.controller(
      for: VimWindowID(editor.id),
      displaying: VimBufferID(firstDocument.id),
      text: firstDocument.text,
      cursor: 0,
      name: firstDocument.url.path,
      leader: " ",
      localLeader: " ",
      tabWidth: 2
    )
    try firstController.engine.executeNotation("vll")
    let preservedState = firstController.engine.state
    let preservedSelection = firstController.engine.selectionSet
    let preservedPresentation = CalciteVimSelectionPresenter.presentation(
      for: preservedState,
      selectionSet: preservedSelection
    )

    guard let secondEditor = await session.openDocument(at: harness.secondFileURL),
      let secondDocument = secondEditor.document
    else {
      return XCTFail("The second document should open in the same editor session.")
    }
    XCTAssertEqual(secondEditor.id, editor.id)

    _ = session.vimSessionCoordinator.controller(
      for: VimWindowID(editor.id),
      displaying: VimBufferID(secondDocument.id),
      text: secondDocument.text,
      cursor: 1,
      name: secondDocument.url.path,
      leader: " ",
      localLeader: " ",
      tabWidth: 2
    )

    guard let restoredEditor = await session.openDocument(at: harness.firstFileURL) else {
      return XCTFail("The first document should reopen in the same editor session.")
    }

    XCTAssertEqual(restoredEditor.id, editor.id)
    XCTAssertEqual(restoredEditor.documentID, firstDocument.id)
    XCTAssertEqual(restoredEditor.selectedRange, preservedPresentation.primaryRange)
    XCTAssertEqual(firstController.engine.state, preservedState)
    XCTAssertEqual(firstController.engine.selectionSet, preservedSelection)

    _ = await backend.shutdown(saveChanges: false)
  }

  func testTabBoundaryDoesNotLetStalePresentationOverwriteEngineCursor() async throws {
    let harness = try makeHarness()
    defer { harness.cleanUp() }

    let backend = CalciteBackend(workspaceURL: harness.workspaceURL)
    let session = backend.makeWindowSession(defaults: harness.defaults)
    let lifecycle = await backend.start()
    guard lifecycle == .running else {
      return XCTFail("Workspace failed to start: \(lifecycle)")
    }

    guard let editor = await session.openDocument(at: harness.firstFileURL),
      let firstDocument = editor.document
    else {
      return XCTFail("The first document should open in an editor session.")
    }

    let firstController = session.vimSessionCoordinator.controller(
      for: VimWindowID(editor.id),
      displaying: VimBufferID(firstDocument.id),
      text: firstDocument.text,
      cursor: 0,
      name: firstDocument.url.path,
      leader: " ",
      localLeader: " ",
      tabWidth: 2
    )

    // A stale presentation mirror must not become authoritative at a tab
    // boundary. Pointer input has to enter through VimEngine first.
    editor.updateSelection(NSRange(location: 6, length: 0))
    XCTAssertEqual(firstController.engine.state.cursor, 0)

    _ = await session.openDocument(at: harness.secondFileURL)
    _ = await session.openDocument(at: harness.firstFileURL)

    XCTAssertEqual(firstController.engine.state.cursor, 0)
    XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))

    _ = await backend.shutdown(saveChanges: false)
  }

  func testPointerCursorAndFirstCommandSurviveNativeSurfaceTabRoundTrip() async throws {
    let harness = try makeHarness()
    defer { harness.cleanUp() }

    let backend = CalciteBackend(workspaceURL: harness.workspaceURL)
    let session = backend.makeWindowSession(defaults: harness.defaults)
    let lifecycle = await backend.start()
    guard lifecycle == .running else {
      return XCTFail("Workspace failed to start: \(lifecycle)")
    }

    guard let editor = await session.openDocument(at: harness.firstFileURL),
      let firstDocument = editor.document
    else {
      return XCTFail("The first document should open in an editor session.")
    }

    let firstController = session.vimSessionCoordinator.controller(
      for: VimWindowID(editor.id),
      displaying: VimBufferID(firstDocument.id),
      text: firstDocument.text,
      cursor: 0,
      name: firstDocument.url.path,
      leader: " ",
      localLeader: " ",
      tabWidth: 2
    )
    let clickedOffset = 6
    firstController.acceptHostCursorMove(toUTF16Offset: clickedOffset, source: .pointer)
    let clickedPresentation = CalciteVimSelectionPresenter.presentation(
      for: firstController.engine.state,
      selectionSet: firstController.engine.selectionSet
    )
    editor.updateSelection(clickedPresentation.primaryRange)

    guard let secondEditor = await session.openDocument(at: harness.secondFileURL) else {
      return XCTFail("The second document should open in the same editor session.")
    }
    XCTAssertEqual(secondEditor.id, editor.id)

    guard let restoredEditor = await session.openDocument(at: harness.firstFileURL) else {
      return XCTFail("The first document should reopen in the same editor session.")
    }

    let restoredController = session.vimSessionCoordinator.existingController(
      for: VimWindowID(editor.id),
      displaying: VimBufferID(firstDocument.id)
    )
    XCTAssertTrue(restoredController === firstController)
    XCTAssertEqual(firstController.engine.state.cursor, clickedOffset)
    XCTAssertEqual(restoredEditor.selectedRange, clickedPresentation.primaryRange)

    _ = try firstController.engine.executeNotation("x")
    XCTAssertEqual(firstController.engine.state.text, "alpha eta gamma\n")

    _ = await backend.shutdown(saveChanges: false)
  }

  private func makeHarness() throws -> Harness {
    let suiteName = "CalciteTests.VimStateRestoration.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(
      EditorInterface.calciteVim.rawValue,
      forKey: EditorInterfacePreferences.interfaceKey
    )

    let workspaceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(suiteName, isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspaceURL,
      withIntermediateDirectories: true
    )
    let firstFileURL = workspaceURL.appendingPathComponent("first.txt")
    let secondFileURL = workspaceURL.appendingPathComponent("second.txt")
    try "alpha beta gamma\n".write(to: firstFileURL, atomically: true, encoding: .utf8)
    try "second buffer\n".write(to: secondFileURL, atomically: true, encoding: .utf8)

    return Harness(
      workspaceURL: workspaceURL,
      firstFileURL: firstFileURL,
      secondFileURL: secondFileURL,
      defaults: defaults,
      suiteName: suiteName
    )
  }
}

@MainActor
private struct Harness {
  let workspaceURL: URL
  let firstFileURL: URL
  let secondFileURL: URL
  let defaults: UserDefaults
  let suiteName: String

  func cleanUp() {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: workspaceURL)
  }
}
