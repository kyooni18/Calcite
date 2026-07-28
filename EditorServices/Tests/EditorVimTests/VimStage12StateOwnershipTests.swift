@_spi(Calcite) @testable import EditorVim
import XCTest

final class VimStage12StateOwnershipTests: XCTestCase {
  func testSameBufferSharesUndoMarksAndRegistersButNotCursor() throws {
    let coordinator = VimSessionCoordinator()
    let buffer = VimBufferID(UUID())
    let firstWindow = VimWindowID(UUID())
    let secondWindow = VimWindowID(UUID())
    let first = coordinator.controller(
      for: firstWindow,
      displaying: buffer,
      text: "alpha beta\n",
      cursor: 0,
      name: "sample.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    let second = coordinator.controller(
      for: secondWindow,
      displaying: buffer,
      text: "alpha beta\n",
      cursor: 6,
      name: "sample.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )

    try first.engine.executeNotation("maw")
    XCTAssertEqual(first.engine.state.cursor, 6)
    XCTAssertEqual(second.engine.state.cursor, 6)

    try first.engine.executeNotation("yiw")
    XCTAssertEqual(second.engine.register(.unnamed), "beta")

    try first.engine.executeNotation("0x")
    XCTAssertEqual(first.engine.state.text, "lpha beta\n")
    _ = second.reconcileExternalText(first.engine.state.text)
    XCTAssertEqual(second.engine.state.cursor, 5)

    try second.engine.executeNotation("u")
    XCTAssertEqual(second.engine.state.text, "alpha beta\n")
    _ = first.reconcileExternalText(second.engine.state.text)
    XCTAssertEqual(first.engine.state.text, "alpha beta\n")

    try second.engine.executeNotation("`a")
    XCTAssertEqual(second.engine.state.cursor, 0)
    XCTAssertNotEqual(first.engine.state.cursor, second.engine.state.cursor)
  }

  func testSharedBufferPositionsAdjustOnlyOnceAcrossWindows() throws {
    let coordinator = VimSessionCoordinator()
    let buffer = VimBufferID(UUID())
    let first = coordinator.controller(
      for: VimWindowID(UUID()),
      displaying: buffer,
      text: "abcd\n",
      cursor: 2,
      name: "shared.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    let second = coordinator.controller(
      for: VimWindowID(UUID()),
      displaying: buffer,
      text: "abcd\n",
      cursor: 0,
      name: "shared.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    try first.engine.executeNotation("ma")

    _ = first.reconcileExternalText("Xabcd\n")
    _ = second.reconcileExternalText("Xabcd\n")
    try second.engine.executeNotation("`a")
    XCTAssertEqual(second.engine.state.cursor, 3)
  }

  func testGlobalHistoryAndMacrosCrossBuffersWhileMarksDoNot() throws {
    let coordinator = VimSessionCoordinator()
    let firstBuffer = VimBufferID(UUID())
    let secondBuffer = VimBufferID(UUID())
    let first = coordinator.controller(
      for: VimWindowID(UUID()),
      displaying: firstBuffer,
      text: "one\n",
      cursor: 0,
      name: "one.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2,
      history: VimHistorySnapshot(commands: ["set number"], searches: ["one"])
    )
    let second = coordinator.controller(
      for: VimWindowID(UUID()),
      displaying: secondBuffer,
      text: "two\n",
      cursor: 0,
      name: "two.txt",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )

    first.engine.setRegister(.named("a"), text: "shared")
    first.engine.setMacro("q", actions: [.move(.right)])
    try first.engine.executeNotation("ma")

    XCTAssertEqual(second.engine.register(.named("a")), "shared")
    XCTAssertEqual(second.engine.macro("q"), [.move(.right)])
    XCTAssertEqual(second.historySnapshot.commands, ["set number"])
    XCTAssertEqual(second.historySnapshot.searches, ["one"])

    second.engine.state.cursor = 2
    try second.engine.executeNotation("`a")
    XCTAssertEqual(second.engine.state.cursor, 2, "lowercase marks must remain buffer-local")
  }

  func testStableBufferNumbersAndWindowAlternateBuffer() {
    let coordinator = VimSessionCoordinator()
    let first = VimBufferID(UUID())
    let second = VimBufferID(UUID())
    let window = VimWindowID(UUID())
    let firstInfo = coordinator.registerBuffer(id: first, name: "one", text: "1")
    let secondInfo = coordinator.registerBuffer(id: second, name: "two", text: "2")
    XCTAssertEqual(firstInfo.number, 1)
    XCTAssertEqual(secondInfo.number, 2)
    XCTAssertEqual(coordinator.registerBuffer(id: first, name: "renamed", text: "1").number, 1)

    _ = coordinator.controller(
      for: window,
      displaying: first,
      text: "1",
      cursor: 0,
      name: "one",
      leader: "\\",
      localLeader: "\\",
      tabWidth: 2
    )
    XCTAssertTrue(coordinator.switchBuffer(in: window, to: second))
    XCTAssertEqual(coordinator.currentBuffer(for: window), second)
    XCTAssertEqual(coordinator.alternateBuffer(for: window), first)

    coordinator.wipeBuffer(first)
    let third = coordinator.registerBuffer(id: VimBufferID(UUID()), name: "three", text: "3")
    XCTAssertEqual(third.number, 3, "buffer numbers must not be reused")
  }

  func testBufferTabAndWindowCommandsRemainDistinct() throws {
    let engine = VimEngine(text: "text\n")
    XCTAssertEqual(
      try engine.execute(.ex("bnext")).hostRequests,
      [.custom("vim-buffer-next")]
    )
    XCTAssertEqual(
      try engine.execute(.ex("tabnext")).hostRequests,
      [.nextTab]
    )
    XCTAssertEqual(
      try engine.executeNotation("gt").hostRequests,
      [.nextTab]
    )
    XCTAssertEqual(
      try engine.executeNotation("gT").hostRequests,
      [.previousTab]
    )
    XCTAssertEqual(
      try engine.execute(.ex("close")).hostRequests,
      [.closeWindow]
    )
    XCTAssertEqual(
      try engine.executeNotation("<C-W>h").hostRequests,
      [.custom("vim-window-left:1")]
    )
    XCTAssertEqual(
      try engine.executeNotation("3<C-W>w").hostRequests,
      [.custom("vim-window-next:3")]
    )
    XCTAssertEqual(
      try engine.executeNotation("<C-^>").hostRequests,
      [.custom("vim-buffer-alternate")]
    )
  }

  func testHostContextCarriesSeparateBufferAndWindowIdentities() {
    let buffer = VimBufferID(UUID())
    let window = VimWindowID(UUID())
    let tabPage = VimTabPageID(UUID())
    let context = VimHostInvocationContext(
      bufferID: buffer,
      windowID: window,
      tabPageID: tabPage
    )
    XCTAssertEqual(context.bufferID, buffer)
    XCTAssertEqual(context.windowID, window)
    XCTAssertEqual(context.tabPageID, tabPage)
  }
}
