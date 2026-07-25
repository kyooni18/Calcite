import XCTest

@testable import EditorCore
@testable import EditorTreeSitter

final class TreeSitterSyntaxServiceTests: XCTestCase {
  func testParsesSwiftAndReturnsRoot() async throws {
    let service = try TreeSitterSyntaxService.swift()
    try await service.open(snapshot: TextSnapshot(text: "struct Box { let value: Int }"))
    let expression = await service.rootSExpression()
    XCTAssertNotNil(expression)
    XCTAssertTrue(expression?.contains("source_file") == true)
  }

  func testHighlightsKeywordsTypesAndProperties() async throws {
    let service = try TreeSitterSyntaxService.swift()
    try await service.open(snapshot: TextSnapshot(text: "struct Box { let value: Int }"))
    let highlights = try await service.highlights(in: nil)
    XCTAssertFalse(highlights.isEmpty)
    XCTAssertTrue(
      highlights.contains { $0.capture.contains("keyword") || $0.capture.contains("type") })
  }

  func testHighlightRangeFiltering() async throws {
    let text = "let first = 1\nlet second = 2"
    let service = try TreeSitterSyntaxService.swift()
    try await service.open(snapshot: TextSnapshot(text: text))
    let range = EditorTextRange(start: .zero, end: .init(line: 0, utf16Column: 13))
    let highlights = try await service.highlights(in: range)
    XCTAssertTrue(highlights.allSatisfy { $0.range.start.line == 0 })
  }

  func testIncrementalUnicodeEditIsTransactional() async throws {
    let service = try TreeSitterSyntaxService.swift()
    var buffer = TextBuffer(text: "let 이름 = \"😀\"\n")
    try await service.open(snapshot: buffer.snapshot)
    let change = try buffer.apply(
      .init(
        range: .init(start: .init(line: 0, utf16Column: 4), end: .init(line: 0, utf16Column: 6)),
        replacement: "값"
      ))
    try await service.apply(change: change)
    let changed = await service.changedRanges()
    let expression = await service.rootSExpression()
    XCTAssertFalse(changed.isEmpty)
    XCTAssertTrue(expression?.contains("source_file") == true)
  }

  func testStaleChangeRejectedWithoutReplacingTree() async throws {
    let service = try TreeSitterSyntaxService.swift()
    try await service.open(snapshot: TextSnapshot(text: "let a = 1", version: 2))
    var buffer = TextBuffer(text: "let a = 1", version: 1)
    let change = try buffer.apply(
      .init(
        range: .init(start: .init(line: 0, utf16Column: 4), end: .init(line: 0, utf16Column: 5)),
        replacement: "b"))
    do {
      try await service.apply(change: change)
      XCTFail()
    } catch {
      XCTAssertEqual(
        error as? TreeSitterServiceError, .staleChange(expectedVersion: 2, receivedVersion: 1))
    }
    let expression = await service.rootSExpression()
    XCTAssertNotNil(expression)
  }

  func testFoldingRangesIncludeMultilineBodies() async throws {
    let service = try TreeSitterSyntaxService.swift()
    try await service.open(
      snapshot: TextSnapshot(text: "struct Box {\n  func value() -> Int {\n    1\n  }\n}\n"))
    let folds = try await service.foldingRanges()
    XCTAssertGreaterThanOrEqual(folds.count, 2)
    XCTAssertTrue(folds.allSatisfy { $0.range.start.line < $0.range.end.line })
  }

  func testCloseClearsTree() async throws {
    let service = try TreeSitterSyntaxService.swift()
    try await service.open(snapshot: TextSnapshot(text: "let x = 1"))
    try await service.close()
    let expression = await service.rootSExpression()
    XCTAssertNil(expression)
  }

  func testKeywordCompletionPrefix() {
    let provider = SwiftKeywordCompletionProvider()
    let items = provider.completions(prefix: "str")
    XCTAssertEqual(items.map(\.label), ["struct"])
    XCTAssertTrue(provider.completions().count > 50)
  }
}

private actor EmptySyntaxProvider: SyntaxProviding {
  func open(snapshot: TextSnapshot) {}
  func apply(change: AppliedTextEdit) {}
  func highlights(in range: EditorTextRange?) -> [Highlight] { [] }
}

private actor RustMisclassifyingSyntaxProvider: SyntaxProviding {
  private var snapshot = TextSnapshot(text: "")

  func open(snapshot: TextSnapshot) { self.snapshot = snapshot }
  func apply(change: AppliedTextEdit) { snapshot = change.newSnapshot }
  func highlights(in range: EditorTextRange?) -> [Highlight] {
    let end = (try? snapshot.position(atUTF16Offset: snapshot.utf16Count)) ?? .zero
    return [Highlight(range: .init(start: .zero, end: end), capture: "comment")]
  }
}

private actor FailingSyntaxProvider: SyntaxProviding {
  enum Failure: Error { case unavailable }

  func open(snapshot: TextSnapshot) throws { throw Failure.unavailable }
  func apply(change: AppliedTextEdit) throws { throw Failure.unavailable }
  func highlights(in range: EditorTextRange?) throws -> [Highlight] { throw Failure.unavailable }
}

extension TreeSitterSyntaxServiceTests {
  func testLexicalFallbackHighlightsTypeScriptWithoutExternalGrammar() async throws {
    let service = LexicalSyntaxService(languageID: "typescript")
    let snapshot = TextSnapshot(
      text: "interface User { name: string }\nconst user = makeUser(42) // value\n"
    )
    await service.open(snapshot: snapshot)

    let highlights = try await service.highlights(in: nil)
    XCTAssertTrue(highlights.contains { $0.capture == "keyword" })
    XCTAssertTrue(highlights.contains { $0.capture == "type" })
    XCTAssertTrue(highlights.contains { $0.capture == "function.call" })
    XCTAssertTrue(highlights.contains { $0.capture == "number" })
    XCTAssertTrue(highlights.contains { $0.capture == "comment" })
    XCTAssertTrue(
      highlights.allSatisfy {
        guard let range = try? snapshot.nsRange(for: $0.range) else { return false }
        return range.location >= 0 && NSMaxRange(range) <= snapshot.utf16Count
      }
    )
  }

  func testLexicalFallbackKeepsUTF16RangesValidAroundEmoji() async throws {
    let service = LexicalSyntaxService(languageID: "swift")
    let snapshot = TextSnapshot(text: "let emoji = \"😀\"\nfunc value() -> Int { 42 }\n")
    await service.open(snapshot: snapshot)

    let highlights = try await service.highlights(in: nil)
    XCTAssertFalse(highlights.isEmpty)
    for highlight in highlights {
      let range = try snapshot.nsRange(for: highlight.range)
      XCTAssertLessThanOrEqual(NSMaxRange(range), snapshot.utf16Count)
    }
  }

  func testResilientSyntaxProviderFallsBackAfterPrimaryFailure() async throws {
    let service = ResilientSyntaxService(
      primary: FailingSyntaxProvider(),
      languageID: "python"
    )
    let snapshot = TextSnapshot(text: "def greet(name):\n    return \"Hello\"\n")
    try await service.open(snapshot: snapshot)

    let highlights = try await service.highlights(in: nil)
    XCTAssertTrue(highlights.contains { $0.capture == "keyword" })
    XCTAssertTrue(highlights.contains { $0.capture == "function" })
    XCTAssertTrue(highlights.contains { $0.capture == "string" })
  }
  func testRustLifetimesDoNotConsumeFollowingCodeAsStringOrComment() async throws {
    let service = LexicalSyntaxService(languageID: "rust")
    let snapshot = TextSnapshot(
      text:
        "fn borrow<'a>(value: &'a str) -> &'static str { loop_label: loop { break loop_label; } }"
    )
    await service.open(snapshot: snapshot)

    let highlights = try await service.highlights(in: nil)
    let lifetimeTexts = highlights.compactMap { highlight -> String? in
      guard highlight.capture == "type.parameter",
        let range = try? snapshot.nsRange(for: highlight.range)
      else { return nil }
      return (snapshot.text as NSString).substring(with: range)
    }
    XCTAssertTrue(lifetimeTexts.contains("'a"))
    XCTAssertTrue(lifetimeTexts.contains("'static"))
    XCTAssertFalse(
      highlights.contains { highlight in
        guard highlight.capture == "string" || highlight.capture == "comment",
          let range = try? snapshot.nsRange(for: highlight.range)
        else { return false }
        return (snapshot.text as NSString).substring(with: range).contains("'static")
      })
  }

  func testRustLifetimeOverridesMisclassifiedStructuralComment() async throws {
    let service = ResilientSyntaxService(
      primary: RustMisclassifyingSyntaxProvider(),
      languageID: "rust"
    )
    let snapshot = TextSnapshot(text: "fn value() -> &'static str { \"ok\" }")
    try await service.open(snapshot: snapshot)

    let highlights = try await service.highlights(in: nil)
    let lifetime = try XCTUnwrap(highlights.first { $0.capture == "type.parameter" })
    let lifetimeRange = try snapshot.nsRange(for: lifetime.range)
    XCTAssertEqual((snapshot.text as NSString).substring(with: lifetimeRange), "'static")
    XCTAssertFalse(
      highlights.contains { highlight in
        guard highlight.capture.contains("comment"),
          let range = try? snapshot.nsRange(for: highlight.range)
        else { return false }
        return NSIntersectionRange(range, lifetimeRange).length > 0
      })
  }

  func testResilientSyntaxProviderFallsBackWhenPrimaryReturnsNoCaptures() async throws {
    let service = ResilientSyntaxService(
      primary: EmptySyntaxProvider(),
      languageID: "rust"
    )
    let snapshot = TextSnapshot(text: "fn main() { let value: i32 = 42; }\n")
    try await service.open(snapshot: snapshot)

    let highlights = try await service.highlights(in: nil)
    XCTAssertTrue(highlights.contains { $0.capture == "keyword" })
    XCTAssertTrue(highlights.contains { $0.capture == "function" })
    XCTAssertTrue(highlights.contains { $0.capture == "number" })
  }

}
