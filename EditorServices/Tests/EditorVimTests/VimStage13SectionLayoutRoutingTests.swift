import XCTest

@testable import EditorVim

final class VimStage13SectionLayoutRoutingTests: XCTestCase {
  func testSplitWithoutPathKeepsStructuredSplitRequest() throws {
    let engine = VimEngine(text: "text\n")

    XCTAssertEqual(
      try engine.execute(.ex("split")).hostRequests,
      [.split(horizontal: true)]
    )
    XCTAssertEqual(
      try engine.execute(.ex("vsplit")).hostRequests,
      [.split(horizontal: false)]
    )
  }

  func testSplitWithPathCarriesTargetToCalciteTopologyRouter() throws {
    let engine = VimEngine(text: "text\n")

    XCTAssertEqual(
      try engine.execute(.ex(#"split Sources/My\ File.swift"#)).hostRequests,
      [.custom("vim-window-split-horizontal:Sources/My File.swift")]
    )
    XCTAssertEqual(
      try engine.execute(.ex("vsplit README.md")).hostRequests,
      [.custom("vim-window-split-vertical:README.md")]
    )
    XCTAssertEqual(
      try engine.execute(.ex("new Notes.txt")).hostRequests,
      [.custom("vim-window-split-horizontal:Notes.txt")]
    )
    XCTAssertEqual(
      try engine.execute(.ex("vnew Notes.txt")).hostRequests,
      [.custom("vim-window-split-vertical:Notes.txt")]
    )
  }

  func testWindowKeyCommandsRemainTopologyRequests() throws {
    let engine = VimEngine(text: "text\n")

    XCTAssertEqual(
      try engine.executeNotation("<C-W>s").hostRequests,
      [.split(horizontal: true)]
    )
    XCTAssertEqual(
      try engine.executeNotation("<C-W>v").hostRequests,
      [.split(horizontal: false)]
    )
    XCTAssertEqual(
      try engine.executeNotation("<C-W>l").hostRequests,
      [.focusWindow(direction: .right, count: 1)]
    )
    XCTAssertEqual(
      try engine.execute(.ex("wincmd v")).hostRequests,
      [.custom("vim-wincmd:v")]
    )
  }
}
