@_spi(Calcite) @testable import EditorVim
import XCTest

final class VimStage16EngineOwnershipTests: XCTestCase {
  func testRecreatingInputAdapterPreservesEngineOwnedPendingState() throws {
    let engine = VimEngine(text: "alpha\n")
    let first = VimKeymapController(engine: engine)
    let mappings = [
      VimKeyMappingV2(
        sequence: "jk",
        command: "<Esc>",
        modes: [.insert],
        inputDomain: .command
      )
    ]
    _ = first.applyConfiguration(
      signature: "stage16",
      leader: " ",
      localLeader: " ",
      tabWidth: 2,
      startInInsertMode: true,
      inputPolicy: .physicalUS,
      languageMap: ["ㅓ": "j"],
      mappings: mappings
    )
    let pending = try first.handle(token: "j")
    XCTAssertTrue(pending.awaitingMoreInput)
    XCTAssertEqual(first.pendingNotation, "j")

    let recreated = VimKeymapController(engine: engine)

    XCTAssertEqual(recreated.pendingNotation, "j")
    XCTAssertTrue(recreated.interactionSnapshot.pendingCommand.isMappingPrefix)
    XCTAssertEqual(recreated.inputPolicy, .physicalUS)
    XCTAssertFalse(
      recreated.applyConfiguration(
        signature: "stage16",
        leader: " ",
        localLeader: " ",
        tabWidth: 2,
        startInInsertMode: true,
        inputPolicy: .physicalUS,
        languageMap: ["ㅓ": "j"],
        mappings: mappings
      )
    )
    XCTAssertEqual(recreated.pendingNotation, "j")
  }

  func testPromptCompositionMessageAndPresentationBelongToEngine() throws {
    let engine = VimEngine(text: "alpha\n")
    let first = VimKeymapController(engine: engine)
    _ = try first.handle(token: ":")
    _ = try first.handle(event: .compositionStarted)
    _ = try first.handle(event: .compositionUpdated("set nu", selectedRange: 6..<6))
    first.present(
      message: VimMessage(
        text: "working",
        code: "STAGE16",
        lifetime: .persistent
      )
    )
    engine.updateWindowPresentation(
      inputSourceIdentifier: "com.apple.inputmethod.Korean.2SetKorean",
      updatesInputSource: true,
      horizontalScrollOffset: 21,
      verticalScrollOffset: 144,
      zoomScale: 1.4
    )

    let recreated = VimKeymapController(engine: engine)
    let interaction = recreated.interactionSnapshot
    let presentation = engine.windowPresentationState

    XCTAssertEqual(interaction.commandLine?.text, "")
    XCTAssertEqual(interaction.commandLine?.markedText, "set nu")
    XCTAssertEqual(interaction.message?.code, "STAGE16")
    XCTAssertTrue(recreated.isComposingText)
    XCTAssertEqual(presentation.inputSourceIdentifier, "com.apple.inputmethod.Korean.2SetKorean")
    XCTAssertEqual(presentation.horizontalScrollOffset, 21)
    XCTAssertEqual(presentation.verticalScrollOffset, 144)
    XCTAssertEqual(presentation.zoomScale, 1.4)
  }

  func testRetainedControllerCanExistBeforeWindowActivation() {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let retainedBuffer = VimBufferID(UUID())
    let activeBuffer = VimBufferID(UUID())

    _ = coordinator.controller(
      for: window,
      displaying: retainedBuffer,
      text: "retained\n",
      cursor: 4,
      name: "retained.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      attachment: .retain
    )
    XCTAssertNil(coordinator.currentBuffer(for: window))
    XCTAssertNil(coordinator.alternateBuffer(for: window))

    _ = coordinator.controller(
      for: window,
      displaying: activeBuffer,
      text: "active\n",
      cursor: 0,
      name: "active.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      attachment: .activate
    )
    XCTAssertEqual(coordinator.currentBuffer(for: window), activeBuffer)
    XCTAssertNil(coordinator.alternateBuffer(for: window))
  }

  func testDetachBufferRepairsWindowRelationshipWithoutDestroyingOtherState() throws {
    let coordinator = VimSessionCoordinator()
    let window = VimWindowID(UUID())
    let firstID = VimBufferID(UUID())
    let secondID = VimBufferID(UUID())
    let first = coordinator.controller(
      for: window,
      displaying: firstID,
      text: "first\n",
      cursor: 0,
      name: "first.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    let second = coordinator.controller(
      for: window,
      displaying: secondID,
      text: "second\n",
      cursor: 2,
      name: "second.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    _ = try second.handle(token: "d")

    coordinator.detachBuffer(secondID, from: window)

    XCTAssertEqual(coordinator.currentBuffer(for: window), firstID)
    XCTAssertNil(coordinator.alternateBuffer(for: window))
    XCTAssertTrue(coordinator.existingController(for: window, displaying: firstID) === first)
    XCTAssertNil(coordinator.existingController(for: window, displaying: secondID))
  }

  func testMappingTimeoutRunsWithoutNativeSurfaceOwnership() async throws {
    let controller = VimKeymapController(engine: VimEngine(text: ""))
    _ = controller.applyConfiguration(
      signature: "timeout",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      startInInsertMode: true,
      inputPolicy: .automatic,
      languageMap: [:],
      mappings: [
        VimKeyMappingV2(sequence: "jk", command: "<Esc>", modes: [.insert])
      ]
    )
    let pending = try controller.handle(token: "j")
    XCTAssertTrue(pending.awaitingMoreInput)

    let notification = expectation(description: "engine-owned timeout")
    controller.scheduleMappingTimeout(milliseconds: 5) {
      notification.fulfill()
    }
    await fulfillment(of: [notification], timeout: 1)

    let results = controller.consumePendingAsynchronousResults()
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(controller.engine.state.text, "j")
    XCTAssertEqual(controller.engine.state.mode, .insert)
  }
}
