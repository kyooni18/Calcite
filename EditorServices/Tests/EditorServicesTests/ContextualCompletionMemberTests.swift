import XCTest

@testable import EditorServices

final class ContextualCompletionMemberTests: XCTestCase {
  func testClassMembersIncludeMethodsAndProperties() throws {
    let text = """
      final class Account {
        var displayName: String = ""
        func refreshProfile(force: Bool) {}
      }

      func use(account: Account) {
        account.
      }
      """

    let values = try completions(in: text, languageID: "swift", triggerCharacter: ".")
    XCTAssertEqual(values.first(where: { $0.label == "displayName" })?.kind, .property)
    XCTAssertEqual(values.first(where: { $0.label == "refreshProfile" })?.kind, .method)
    XCTAssertEqual(
      values.first(where: { $0.label == "refreshProfile" })?.insertTextFormat,
      .snippet
    )
  }

  func testStructMembersIncludeMethodsAndProperties() throws {
    let text = """
      struct Point {
        let x: Double
        let y: Double
        func distance() -> Double { 0 }
      }

      func use(point: Point) {
        point.
      }
      """

    let values = try completions(in: text, languageID: "swift", triggerCharacter: ".")
    XCTAssertEqual(values.first(where: { $0.label == "x" })?.kind, .property)
    XCTAssertEqual(values.first(where: { $0.label == "y" })?.kind, .property)
    XCTAssertEqual(values.first(where: { $0.label == "distance" })?.kind, .method)
  }

  func testEnumTypeAndInstanceExposeCorrectMembers() throws {
    let typeAccess = """
      enum Status {
        case ready
        case failed(reason: String)
        var isTerminal: Bool { false }
        func description() -> String { "" }
      }

      func use() {
        Status.
      }
      """
    let typeValues = try completions(
      in: typeAccess,
      languageID: "swift",
      triggerCharacter: "."
    )
    XCTAssertEqual(typeValues.first(where: { $0.label == "ready" })?.kind, .enumMember)
    XCTAssertEqual(typeValues.first(where: { $0.label == "failed" })?.kind, .enumMember)
    XCTAssertFalse(typeValues.contains { $0.label == "isTerminal" })

    let instanceAccess = """
      enum Status {
        case ready
        case failed(reason: String)
        var isTerminal: Bool { false }
        func description() -> String { "" }
      }

      func use(status: Status) {
        status.
      }
      """
    let instanceValues = try completions(
      in: instanceAccess,
      languageID: "swift",
      triggerCharacter: "."
    )
    XCTAssertEqual(instanceValues.first(where: { $0.label == "isTerminal" })?.kind, .property)
    XCTAssertEqual(instanceValues.first(where: { $0.label == "description" })?.kind, .method)
    XCTAssertFalse(instanceValues.contains { $0.label == "ready" })
  }

  func testTupleMembersIncludeLabelsAndPositions() throws {
    let text = """
      func use(point: (x: Int, y: Int)) {
        point.
      }
      """

    let values = try completions(in: text, languageID: "swift", triggerCharacter: ".")
    XCTAssertEqual(values.first(where: { $0.label == "x" })?.kind, .property)
    XCTAssertEqual(values.first(where: { $0.label == "y" })?.kind, .property)
    XCTAssertEqual(values.first(where: { $0.label == "0" })?.kind, .field)
    XCTAssertEqual(values.first(where: { $0.label == "1" })?.kind, .field)
  }

  func testStaticMembersAreSeparatedFromInstanceMembers() throws {
    let text = """
      final class Factory {
        static var shared: Factory { Factory() }
        static func make() -> Factory { Factory() }
        var identifier: String = ""
      }

      func use() {
        Factory.
      }
      """

    let values = try completions(in: text, languageID: "swift", triggerCharacter: ".")
    XCTAssertEqual(values.first(where: { $0.label == "shared" })?.kind, .property)
    XCTAssertEqual(values.first(where: { $0.label == "make" })?.kind, .method)
    XCTAssertFalse(values.contains { $0.label == "identifier" })
  }

  func testInheritedMembersAreIncluded() throws {
    let text = """
      class BaseController {
        var state: Int = 0
        func reset() {}
      }

      final class ChildController: BaseController {}

      func use(controller: ChildController) {
        controller.
      }
      """

    let values = try completions(in: text, languageID: "swift", triggerCharacter: ".")
    XCTAssertEqual(values.first(where: { $0.label == "state" })?.kind, .property)
    XCTAssertEqual(values.first(where: { $0.label == "reset" })?.kind, .method)
  }

  func testInferredTupleMembersAreIncluded() throws {
    let text = """
      func use() {
        let result = (value: 42, message: "ok")
        result.
      }
      """

    let values = try completions(in: text, languageID: "swift", triggerCharacter: ".")
    XCTAssertEqual(values.first(where: { $0.label == "value" })?.kind, .property)
    XCTAssertEqual(values.first(where: { $0.label == "message" })?.kind, .property)
    XCTAssertNotNil(values.first(where: { $0.label == "0" }))
    XCTAssertNotNil(values.first(where: { $0.label == "1" }))
  }

  func testRustTupleStructMembersAreIncluded() throws {
    let text = """
      struct Color(u8, u8, u8);

      fn use(color: Color) {
        color.
      }
      """

    let values = try completions(in: text, languageID: "rust", triggerCharacter: ".")
    XCTAssertEqual(values.first(where: { $0.label == "0" })?.kind, .field)
    XCTAssertEqual(values.first(where: { $0.label == "1" })?.kind, .field)
    XCTAssertEqual(values.first(where: { $0.label == "2" })?.kind, .field)
  }

  func testProtocolAndExtensionMembersAreIncluded() throws {
    let text = """
      protocol Worker {
        var status: String { get }
        func run()
      }

      extension Worker {
        func stop() {}
      }

      func use(worker: any Worker) {
        worker.
      }
      """

    let values = try completions(in: text, languageID: "swift", triggerCharacter: ".")
    XCTAssertEqual(values.first(where: { $0.label == "status" })?.kind, .property)
    XCTAssertEqual(values.first(where: { $0.label == "run" })?.kind, .method)
    XCTAssertEqual(values.first(where: { $0.label == "stop" })?.kind, .method)
  }

  func testNestedParameterTypesProduceCompleteMethodSnippet() throws {
    let text = """
      struct Loader {
        func load(
          completion: (Result<String, Error>) -> Void,
          userID: String
        ) {}
      }

      func use(loader: Loader) {
        loader.lo
      }
      """
    let snapshot = TextSnapshot(text: text)
    let memberPrefix = (text as NSString).range(of: "loader.lo")
    let position = try snapshot.position(atUTF16Offset: NSMaxRange(memberPrefix))
    var provider = ContextualCompletionProvider()
    let result = try provider.completions(
      snapshot: snapshot,
      uri: URL(fileURLWithPath: "/tmp/Test.swift"),
      languageID: "swift",
      position: position,
      triggerCharacter: nil,
      workspaceFiles: [],
      limit: 100
    )

    let method = try XCTUnwrap(result.completions.first { $0.label == "load" })
    XCTAssertTrue(method.insertText?.contains("${1:completion}") == true)
    XCTAssertTrue(method.insertText?.contains("${2:userID}") == true)
  }

  func testSingleFieldRustTupleStructIncludesZeroMember() throws {
    let text = """
      struct Wrapper(u8);

      fn use(wrapper: Wrapper) {
        wrapper.
      }
      """

    let values = try completions(in: text, languageID: "rust", triggerCharacter: ".")
    XCTAssertEqual(values.first(where: { $0.label == "0" })?.kind, .field)
  }

  func testNestedFunctionParameterTypesDoNotHideLaterParameters() throws {
    let text = """
      func load(
        completion: (Result<String, Error>) -> Void,
        userID: String
      ) {
        user
      }
      """
    let snapshot = TextSnapshot(text: text)
    let offset = (text as NSString).range(of: "user\n").location + 4
    let position = try snapshot.position(atUTF16Offset: offset)
    var provider = ContextualCompletionProvider()
    let result = try provider.completions(
      snapshot: snapshot,
      uri: URL(fileURLWithPath: "/tmp/Test.swift"),
      languageID: "swift",
      position: position,
      triggerCharacter: nil,
      workspaceFiles: [],
      limit: 100
    )

    XCTAssertEqual(
      result.completions.first(where: { $0.label == "userID" })?.detail,
      "Function parameter"
    )
  }

  func testExplicitCompletionWithoutPrefixIncludesFunctionParameters() throws {
    let marker = "__CURSOR__"
    let markedText = """
      func render(userID: String, retryCount: Int) {
        __CURSOR__
      }
      """
    let markerRange = (markedText as NSString).range(of: marker)
    let text = markedText.replacingOccurrences(of: marker, with: "")
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: markerRange.location)
    var provider = ContextualCompletionProvider()
    let result = try provider.completions(
      snapshot: snapshot,
      uri: URL(fileURLWithPath: "/tmp/Test.swift"),
      languageID: "swift",
      position: position,
      triggerCharacter: nil,
      allowEmptyPrefix: true,
      workspaceFiles: [],
      limit: 100
    )

    XCTAssertEqual(
      result.completions.first(where: { $0.label == "userID" })?.detail,
      "Function parameter"
    )
    XCTAssertEqual(
      result.completions.first(where: { $0.label == "retryCount" })?.detail,
      "Function parameter"
    )
  }

  func testFunctionParametersAreExplicitCompletionCandidates() throws {
    let text = """
      func render(userID: String, retryCount: Int) {
        use
      }
      """
    let snapshot = TextSnapshot(text: text)
    let offset = (text as NSString).range(of: "use\n").location + 3
    let position = try snapshot.position(atUTF16Offset: offset)
    var provider = ContextualCompletionProvider()
    let result = try provider.completions(
      snapshot: snapshot,
      uri: URL(fileURLWithPath: "/tmp/Test.swift"),
      languageID: "swift",
      position: position,
      triggerCharacter: nil,
      workspaceFiles: [],
      limit: 100
    )

    let parameter = try XCTUnwrap(result.completions.first { $0.label == "userID" })
    XCTAssertEqual(parameter.kind, .variable)
    XCTAssertEqual(parameter.detail, "Function parameter")
    XCTAssertEqual(parameter.insertText, "userID")
  }

  func testTypedFunctionParameterResolvesItsMembers() throws {
    let text = """
      struct User {
        var name: String
        func rename(to newName: String) {}
      }

      func update(user: User) {
        user.re
      }
      """
    let snapshot = TextSnapshot(text: text)
    let memberPrefix = (text as NSString).range(of: "user.re")
    let position = try snapshot.position(atUTF16Offset: NSMaxRange(memberPrefix))
    var provider = ContextualCompletionProvider()
    let result = try provider.completions(
      snapshot: snapshot,
      uri: URL(fileURLWithPath: "/tmp/Test.swift"),
      languageID: "swift",
      position: position,
      triggerCharacter: nil,
      workspaceFiles: [],
      limit: 100
    )

    let method = try XCTUnwrap(result.completions.first { $0.label == "rename" })
    XCTAssertEqual(method.kind, .method)
    XCTAssertEqual(method.insertTextFormat, .snippet)
    XCTAssertFalse(result.completions.contains { $0.label == "retryCount" })
  }

  private func completions(
    in text: String,
    languageID: String,
    triggerCharacter: String?
  ) throws -> [Completion] {
    let snapshot = TextSnapshot(text: text)
    let dot = (text as NSString).range(of: ".", options: .backwards)
    let position = try snapshot.position(atUTF16Offset: NSMaxRange(dot))
    var provider = ContextualCompletionProvider()
    return try provider.completions(
      snapshot: snapshot,
      uri: URL(fileURLWithPath: "/tmp/Test.swift"),
      languageID: languageID,
      position: position,
      triggerCharacter: triggerCharacter,
      workspaceFiles: [],
      limit: 100
    ).completions
  }
}
