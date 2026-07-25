import XCTest

@testable import EditorServices

final class CompletionLanguageStrategyTests: XCTestCase {
  func testRegistrySeparatesMajorLanguageFamilies() {
    XCTAssertTrue(
      CompletionLanguageStrategyRegistry.strategy(for: "rust")
        is RustCompletionLanguageStrategy
    )
    XCTAssertTrue(
      CompletionLanguageStrategyRegistry.strategy(for: "swift")
        is SwiftCompletionLanguageStrategy
    )
    XCTAssertTrue(
      CompletionLanguageStrategyRegistry.strategy(for: "python")
        is PythonCompletionLanguageStrategy
    )
    XCTAssertTrue(
      CompletionLanguageStrategyRegistry.strategy(for: "typescript")
        is JavaScriptCompletionLanguageStrategy
    )
    XCTAssertTrue(
      CompletionLanguageStrategyRegistry.strategy(for: "go")
        is GoCompletionLanguageStrategy
    )
    XCTAssertTrue(
      CompletionLanguageStrategyRegistry.strategy(for: "lua")
        is LuaCompletionLanguageStrategy
    )
    XCTAssertTrue(
      CompletionLanguageStrategyRegistry.strategy(for: "cpp")
        is CFamilyCompletionLanguageStrategy
    )
  }

  func testRustStructLiteralCompletesMissingFieldsWithVisibleValues() throws {
    let marked = """
      struct User {
        name: String,
        age: u32,
      }

      fn make(name: String) -> User {
        User {
          __CURSOR__
        }
      }
      """
    let values = try completions(in: marked, languageID: "rust")
    let name = try XCTUnwrap(values.first { $0.label == "name" })
    let age = try XCTUnwrap(values.first { $0.label == "age" })
    XCTAssertEqual(name.kind, .field)
    XCTAssertEqual(name.insertText, "name: name")
    XCTAssertEqual(age.insertText, "age: 0")
    XCTAssertLessThan(
      values.firstIndex(where: { $0.label == "name" })!,
      values.firstIndex(where: { $0.kind == .keyword }) ?? values.endIndex
    )
  }

  func testSwiftInitializerCompletesLabelsUsingLanguageSyntax() throws {
    let marked = """
      struct User {
        let name: String
        let age: Int
      }

      func make(name: String) -> User {
        User(__CURSOR__)
      }
      """
    let values = try completions(in: marked, languageID: "swift")
    XCTAssertEqual(values.first(where: { $0.label == "name" })?.insertText, "name: name")
    XCTAssertEqual(values.first(where: { $0.label == "age" })?.insertText, "age: 0")
  }

  func testTypeScriptObjectLiteralCompletesInterfaceProperties() throws {
    let marked = """
      interface User {
        name: string;
        active: boolean;
      }

      const name: string = "Ada";
      const user: User = {
        __CURSOR__
      };
      """
    let values = try completions(in: marked, languageID: "typescript")
    XCTAssertEqual(values.first(where: { $0.label == "name" })?.insertText, "name: name")
    XCTAssertEqual(values.first(where: { $0.label == "active" })?.insertText, "active: false")
  }

  func testGoCompositeLiteralCompletesFieldsAndUsesMatchingParameter() throws {
    let marked = """
      package example

      type User struct {
        Name string
        Age int
      }

      func makeUser(name string) User {
        return User{
          __CURSOR__
        }
      }
      """
    let values = try completions(in: marked, languageID: "go")
    XCTAssertEqual(values.first(where: { $0.label == "Name" })?.insertText, "Name: name")
    XCTAssertEqual(values.first(where: { $0.label == "Age" })?.insertText, "Age: 0")
  }

  func testLuaTypedTableCompletesAnnotatedFields() throws {
    let marked = """
      ---@class User
      ---@field name string
      ---@field active boolean

      local name: string = "Ada"
      ---@type User
      local user = {
        __CURSOR__
      }
      """
    let values = try completions(in: marked, languageID: "lua")
    XCTAssertEqual(values.first(where: { $0.label == "name" })?.insertText, "name = name")
    XCTAssertEqual(values.first(where: { $0.label == "active" })?.insertText, "active = false")
  }

  func testGoAndLuaExternalMethodsRemainTypedMembers() throws {
    let goValues = try externalCompletions(
      markedText: """
        package main
        func run() {
          client := Client{}
          client.__CURSOR__
        }
        """,
      languageID: "go",
      externalText: """
        package dependency
        type Client struct { Status bool }
        func (client *Client) Refresh() {}
        func (client Client) IsReady() bool { return client.Status }
        """,
      externalExtension: "go"
    )
    XCTAssertEqual(goValues.first(where: { $0.label == "Refresh" })?.kind, .method)
    XCTAssertEqual(goValues.first(where: { $0.label == "IsReady" })?.kind, .method)
    XCTAssertEqual(goValues.first(where: { $0.label == "Status" })?.kind, .field)

    let luaValues = try externalCompletions(
      markedText: """
        ---@type Client
        local client = Client.new()
        client.__CURSOR__
        """,
      languageID: "lua",
      externalText: """
        ---@class Client
        ---@field status boolean
        local Client = {}
        function Client:refresh() end
        function Client:is_ready() return self.status end
        function Client.new() return setmetatable({}, { __index = Client }) end
        """,
      externalExtension: "lua"
    )
    XCTAssertEqual(luaValues.first(where: { $0.label == "refresh" })?.kind, .method)
    XCTAssertEqual(luaValues.first(where: { $0.label == "is_ready" })?.kind, .method)
    XCTAssertEqual(luaValues.first(where: { $0.label == "status" })?.kind, .property)
  }

  func testPythonStrategyRecognizesKeywordArgumentValueContext() {
    let text = "User(name="
    let strategy = PythonCompletionLanguageStrategy()
    let context = strategy.initializerContext(in: text, caretUTF16Offset: text.utf16.count)
    XCTAssertEqual(context?.typeName, "User")
    XCTAssertEqual(context?.position, .memberValue(memberName: "name"))
  }

  func testMethodPriorityAppliesAcrossLanguageStrategies() throws {
    for languageID in ["rust", "swift", "python", "typescript", "go", "lua", "cpp"] {
      let text = "value."
      let snapshot = TextSnapshot(text: text)
      let position = try snapshot.position(atUTF16Offset: text.utf16.count)
      let ranked = try CompletionRankingEngine.rank(
        [
          Completion(label: "value", kind: .field),
          Completion(label: "validate", kind: .method),
          Completion(label: "Variant", kind: .struct),
        ],
        snapshot: snapshot,
        position: position,
        invocation: .triggerCharacter("."),
        languageID: languageID,
        usageHistory: .init(),
        limit: 20
      )
      XCTAssertEqual(ranked.first?.label, "validate", "Failed for \(languageID)")
    }
  }

  func testExternalRustLibraryMethodsRemainAvailableForQualifiedConstructors() throws {
    let marker = "__CURSOR__"
    let marked = """
      use dep::Client;

      fn run() {
        let client = dep::Client::new();
        client.__CURSOR__
      }
      """
    let markerRange = (marked as NSString).range(of: marker)
    let text = marked.replacingOccurrences(of: marker, with: "")
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: markerRange.location)
    let externalText = """
      pub struct Client {
        pub status: bool,
      }

      impl Client {
        pub fn new() -> Self { Self { status: true } }
        pub fn refresh(&self) {}
        pub fn is_ready(&self) -> bool { self.status }
      }
      """
    let externalURL = URL(fileURLWithPath: "/tmp/cargo/dep/src/lib.rs")
    let external = ExternalIndexedSourceFile(
      file: SourceCodeFile(
        id: SourceFileID(),
        name: "lib.rs",
        relativePath: "Libraries/dep/lib.rs",
        url: externalURL,
        languageID: "rust",
        content: externalText,
        version: 0,
        savedVersion: 0,
        encoding: .utf8,
        lineEnding: .lineFeed,
        state: .clean,
        diskFingerprint: nil
      ),
      packageName: "dep"
    )
    var provider = ContextualCompletionProvider()
    let values = try provider.completions(
      snapshot: snapshot,
      uri: URL(fileURLWithPath: "/tmp/project/src/main.rs"),
      languageID: "rust",
      position: position,
      triggerCharacter: ".",
      workspaceFiles: [],
      externalFiles: [external],
      externalGeneration: 1,
      limit: 100
    ).completions

    XCTAssertEqual(values.first(where: { $0.label == "refresh" })?.kind, .method)
    XCTAssertEqual(values.first(where: { $0.label == "is_ready" })?.kind, .method)
    XCTAssertEqual(values.first(where: { $0.label == "status" })?.kind, .field)
    XCTAssertTrue(values.first(where: { $0.label == "refresh" })?.detail?.contains("dep") == true)
  }

  func testExternalLibraryMembersRemainAvailableAcrossLanguageStrategies() throws {
    let fixtures:
      [(
        languageID: String, source: String, library: String, extensionName: String,
        expected: [(String, CompletionKind)]
      )] = [
        (
          "swift",
          """
          let client = Client()
          client.__CURSOR__
          """,
          """
          public struct Client {
            public var status: Bool
            public init() { status = true }
            public func refresh() {}
            public func isReady() -> Bool { status }
          }
          """,
          "swift",
          [("refresh", .method), ("isReady", .method), ("status", .property)]
        ),
        (
          "typescript",
          """
          const client = new Client();
          client.__CURSOR__
          """,
          """
          export class Client {
            status: boolean = true;
            refresh(): void {}
            isReady(): boolean { return this.status; }
          }
          """,
          "ts",
          [("refresh", .method), ("isReady", .method), ("status", .property)]
        ),
        (
          "python",
          """
          client = Client()
          client.__CURSOR__
          """,
          """
          class Client:
              status: bool = True
              def refresh(self):
                  pass
              def is_ready(self) -> bool:
                  return self.status
          """,
          "py",
          [("refresh", .method), ("is_ready", .method), ("status", .property)]
        ),
        (
          "cpp",
          """
          Client client;
          client.__CURSOR__
          """,
          """
          class Client {
          public:
            bool status;
            void refresh();
            bool is_ready() const;
          };
          """,
          "hpp",
          [("refresh", .method), ("is_ready", .method), ("status", .field)]
        ),
      ]

    for fixture in fixtures {
      let values = try externalCompletions(
        markedText: fixture.source,
        languageID: fixture.languageID,
        externalText: fixture.library,
        externalExtension: fixture.extensionName
      )
      for (label, kind) in fixture.expected {
        XCTAssertEqual(
          values.first(where: { $0.label == label })?.kind,
          kind,
          "Missing \(label) for \(fixture.languageID): \(values.prefix(20).map(\.label))"
        )
      }
      let firstMethod = values.firstIndex(where: { $0.kind == .method })
      let firstField = values.firstIndex(where: { $0.kind == .field || $0.kind == .property })
      if let firstMethod, let firstField {
        XCTAssertLessThan(
          firstMethod, firstField, "Methods should lead members for \(fixture.languageID)")
      }
    }
  }

  private func externalCompletions(
    markedText: String,
    languageID: String,
    externalText: String,
    externalExtension: String
  ) throws -> [Completion] {
    let marker = "__CURSOR__"
    let markerRange = (markedText as NSString).range(of: marker)
    XCTAssertNotEqual(markerRange.location, NSNotFound)
    let text = markedText.replacingOccurrences(of: marker, with: "")
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: markerRange.location)
    let externalURL = URL(fileURLWithPath: "/tmp/libraries/dependency/Client.\(externalExtension)")
    let external = ExternalIndexedSourceFile(
      file: SourceCodeFile(
        id: SourceFileID(),
        name: externalURL.lastPathComponent,
        relativePath: "Libraries/dependency/\(externalURL.lastPathComponent)",
        url: externalURL,
        languageID: languageID,
        content: externalText,
        version: 0,
        savedVersion: 0,
        encoding: .utf8,
        lineEnding: .lineFeed,
        state: .clean,
        diskFingerprint: nil
      ),
      packageName: "dependency"
    )
    var provider = ContextualCompletionProvider()
    return try provider.completions(
      snapshot: snapshot,
      uri: URL(fileURLWithPath: "/tmp/project/main.\(externalExtension)"),
      languageID: languageID,
      position: position,
      triggerCharacter: ".",
      workspaceFiles: [],
      externalFiles: [external],
      externalGeneration: 1,
      limit: 100
    ).completions
  }

  private func completions(in markedText: String, languageID: String) throws -> [Completion] {
    let marker = "__CURSOR__"
    let markerRange = (markedText as NSString).range(of: marker)
    XCTAssertNotEqual(markerRange.location, NSNotFound)
    let text = markedText.replacingOccurrences(of: marker, with: "")
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: markerRange.location)
    var provider = ContextualCompletionProvider()
    return try provider.completions(
      snapshot: snapshot,
      uri: URL(fileURLWithPath: "/tmp/Test.\(languageID)"),
      languageID: languageID,
      position: position,
      triggerCharacter: nil,
      allowEmptyPrefix: true,
      workspaceFiles: [],
      limit: 100
    ).completions
  }
}
