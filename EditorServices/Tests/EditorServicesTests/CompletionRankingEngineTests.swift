import XCTest

@testable import EditorServices

final class CompletionRankingEngineTests: XCTestCase {
  func testMemberAccessRanksMethodsAndPropertiesBeforeUnrelatedConstants() throws {
    let text = """
      let value = Service()
      value.refresh()
      value.
      """
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let candidates = [
      Completion(label: "AAAAConstant", kind: .constant, sortText: "0000"),
      Completion(label: "UnrelatedType", kind: .class, sortText: "0001"),
      Completion(label: "refresh", kind: .method, sortText: "9999"),
      Completion(label: "status", kind: .property, sortText: "9998"),
    ]

    let ranked = try CompletionRankingEngine.rank(
      candidates,
      snapshot: snapshot,
      position: position,
      invocation: .triggerCharacter("."),
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )

    XCTAssertEqual(ranked.map(\.label).prefix(2), ["refresh", "status"])
    XCTAssertEqual(ranked.map(\.sortText), ["000000", "000001", "000002", "000003"])
  }

  func testDeclarationNameContextPrefersVariables() throws {
    let text = "let us"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let candidates = [
      Completion(label: "useNetwork", kind: .method),
      Completion(label: "userCount", kind: .variable),
      Completion(label: "User", kind: .struct),
    ]

    let ranked = try CompletionRankingEngine.rank(
      candidates,
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )

    XCTAssertEqual(ranked.first?.label, "userCount")
  }

  func testTypePositionPrefersTypesOverValues() throws {
    let text = "let item: Us"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let candidates = [
      Completion(label: "userState", kind: .variable),
      Completion(label: "useService", kind: .method),
      Completion(label: "UserService", kind: .struct),
    ]

    let ranked = try CompletionRankingEngine.rank(
      candidates,
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )

    XCTAssertEqual(ranked.first?.label, "UserService")
  }

  func testOrdinaryExpressionDemotesTypesAndLanguageKeywords() throws {
    let text = "consume(value) + st"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let candidates = [
      Completion(label: "storageType", kind: .struct, sortText: "0000"),
      Completion(label: "static", kind: .keyword, sortText: "0001"),
      Completion(label: "start", kind: .method, sortText: "9999"),
      Completion(label: "storedValue", kind: .variable, sortText: "9998"),
    ]

    let ranked = try CompletionRankingEngine.rank(
      candidates,
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )

    XCTAssertEqual(Array(ranked.map(\.label).prefix(2)), ["storedValue", "start"])
    XCTAssertEqual(ranked.last?.label, "static")
  }

  func testTypeAndKeywordAdjustmentsRemainContextSensitive() throws {
    let typeText = "let item: Us"
    let typeSnapshot = TextSnapshot(text: typeText)
    let typePosition = try typeSnapshot.position(atUTF16Offset: typeText.utf16.count)
    let typeRanked = try CompletionRankingEngine.rank(
      [
        Completion(label: "userState", kind: .variable),
        Completion(label: "UserService", kind: .struct),
        Completion(label: "some", kind: .keyword),
      ],
      snapshot: typeSnapshot,
      position: typePosition,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )

    XCTAssertEqual(typeRanked.first?.label, "UserService")

    let statementText = "gu"
    let statementSnapshot = TextSnapshot(text: statementText)
    let statementPosition = try statementSnapshot.position(
      atUTF16Offset: statementText.utf16.count
    )
    let statementRanked = try CompletionRankingEngine.rank(
      [
        Completion(label: "Guide", kind: .struct),
        Completion(label: "guard", kind: .keyword),
        Completion(
          label: "guard statement",
          kind: .snippet,
          insertTextFormat: .snippet
        ),
      ],
      snapshot: statementSnapshot,
      position: statementPosition,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )

    XCTAssertEqual(statementRanked.first?.kind, .snippet)
    XCTAssertEqual(statementRanked.last?.kind, .struct)
  }

  func testPreviouslyAppliedCompletionReceivesAdaptiveBoost() throws {
    let text = "va"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let preferred = Completion(label: "valueFromCache", kind: .variable)
    let other = Completion(label: "valueFromDisk", kind: .variable)
    var history = CompletionUsageHistory()
    history.record(other, languageID: "swift")
    history.record(other, languageID: "swift")

    let ranked = try CompletionRankingEngine.rank(
      [preferred, other],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: history,
      limit: 20
    )

    XCTAssertEqual(ranked.first?.label, "valueFromDisk")
  }
  func testSmallVisibleLimitStillFindsCallableBehindManyConstants() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("Rank.swift")
    let constants = (0..<80).map { "let alphabeticalConstant\($0) = \($0)" }
      .joined(separator: "\n")
    let text = """
      func performAction() {}
      \(constants)
      let object = NSObject()
      object.
      """
    try text.write(to: file, atomically: true, encoding: .utf8)

    let backend = SwiftEditorBackend(
      workspaceURL: root,
      languageID: "swift",
      completionStrategy: .mergeKeywordsAndFallbackOnError,
      completionLimit: 3
    )
    try await backend.openFile(at: file)
    let snapshot = try await backend.snapshot(of: file)
    let position = try snapshot.position(atUTF16Offset: snapshot.utf16Count)
    let values = try await backend.completions(
      in: file,
      at: position,
      invocation: .triggerCharacter(".")
    )

    XCTAssertEqual(values.first?.label, "performAction")
    XCTAssertEqual(values.count, 3)
    try await backend.shutdown()
  }

  func testCurrentClassMemberOutranksUnrelatedProjectSymbols() throws {
    let text = """
      final class Cache {
        func refresh() {}
        func run() {
          ref
        }
      }
      """
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(
      atUTF16Offset: (text as NSString).range(of: "ref").location + 3)
    let current = URL(fileURLWithPath: "/tmp/Cache.swift")
    let symbols = [
      ProjectCompletionSymbol(
        name: "refresh", insertion: "refresh()", format: .snippet, kind: .method,
        fileName: "Cache.swift", url: current, occurrences: 1, ownerType: "Cache",
        isStatic: false, isDeclaration: false, fileRole: .implementation
      ),
      ProjectCompletionSymbol(
        name: "referenceGlobal", insertion: "referenceGlobal", format: .plainText,
        kind: .variable, fileName: "Globals.swift", url: URL(fileURLWithPath: "/tmp/Globals.swift"),
        occurrences: 1, ownerType: nil, isStatic: false, isDeclaration: false,
        fileRole: .implementation
      ),
    ]
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "referenceGlobal", kind: .variable),
        Completion(label: "refresh", kind: .method),
        Completion(label: "ReferenceType", kind: .class),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20,
      currentURI: current,
      projectSymbols: symbols
    )
    XCTAssertEqual(ranked.first?.label, "refresh")
  }

  func testTypedReceiverPrefersMembersOwnedByItsType() throws {
    let text = """
      let service: Service = Service()
      service.re
      """
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let current = URL(fileURLWithPath: "/tmp/main.swift")
    let symbols = [
      ProjectCompletionSymbol(
        name: "reload", insertion: "reload()", format: .snippet, kind: .method,
        fileName: "Service.swift", url: URL(fileURLWithPath: "/tmp/Service.swift"),
        occurrences: 1, ownerType: "Service", isStatic: false, isDeclaration: false,
        fileRole: .implementation
      ),
      ProjectCompletionSymbol(
        name: "reset", insertion: "reset()", format: .snippet, kind: .method,
        fileName: "Other.swift", url: URL(fileURLWithPath: "/tmp/Other.swift"),
        occurrences: 1, ownerType: "Other", isStatic: false, isDeclaration: false,
        fileRole: .implementation
      ),
    ]
    let ranked = try CompletionRankingEngine.rank(
      [Completion(label: "reset", kind: .method), Completion(label: "reload", kind: .method)],
      snapshot: snapshot,
      position: position,
      invocation: .triggerCharacter("."),
      languageID: "swift",
      usageHistory: .init(),
      limit: 20,
      currentURI: current,
      projectSymbols: symbols
    )
    XCTAssertEqual(ranked.first?.label, "reload")
  }

  func testTypeReceiverPrefersStaticMembers() throws {
    let text = "Service.ma"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let current = URL(fileURLWithPath: "/tmp/main.swift")
    let symbols = [
      ProjectCompletionSymbol(
        name: "make", insertion: "make()", format: .snippet, kind: .method,
        fileName: "Service.swift", url: URL(fileURLWithPath: "/tmp/Service.swift"),
        occurrences: 1, ownerType: "Service", isStatic: true, isDeclaration: false,
        fileRole: .implementation
      ),
      ProjectCompletionSymbol(
        name: "mapValues", insertion: "mapValues()", format: .snippet, kind: .method,
        fileName: "Service.swift", url: URL(fileURLWithPath: "/tmp/Service.swift"),
        occurrences: 1, ownerType: "Service", isStatic: false, isDeclaration: false,
        fileRole: .implementation
      ),
    ]
    let ranked = try CompletionRankingEngine.rank(
      [Completion(label: "mapValues", kind: .method), Completion(label: "make", kind: .method)],
      snapshot: snapshot,
      position: position,
      invocation: .triggerCharacter("."),
      languageID: "swift",
      usageHistory: .init(),
      limit: 20,
      currentURI: current,
      projectSymbols: symbols
    )
    XCTAssertEqual(ranked.first?.label, "make")
  }

  func testHeaderClassContextPrefersOwnDeclarations() throws {
    let text = """
      class Widget {
      public:
        ren
      };
      """
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(
      atUTF16Offset: (text as NSString).range(of: "ren").location + 3)
    let header = URL(fileURLWithPath: "/tmp/Widget.hpp")
    let symbols = [
      ProjectCompletionSymbol(
        name: "render", insertion: "render()", format: .snippet, kind: .method,
        fileName: "Widget.hpp", url: header, occurrences: 1, ownerType: "Widget",
        isStatic: false, isDeclaration: true, fileRole: .header
      ),
      ProjectCompletionSymbol(
        name: "renderGlobal", insertion: "renderGlobal()", format: .snippet, kind: .function,
        fileName: "Render.hpp", url: URL(fileURLWithPath: "/tmp/Render.hpp"),
        occurrences: 1, ownerType: nil, isStatic: false, isDeclaration: true,
        fileRole: .header
      ),
    ]
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "renderGlobal", kind: .function),
        Completion(label: "render", kind: .method),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "cpp",
      usageHistory: .init(),
      limit: 20,
      currentURI: header,
      projectSymbols: symbols
    )
    XCTAssertEqual(ranked.first?.label, "render")
  }

  func testCPlusPlusHeaderScannerPreservesMemberOwnershipAndStaticness() throws {
    let url = URL(fileURLWithPath: "/tmp/Widget.hpp")
    let symbols = ProjectDeclarationScanner.scan(
      text: """
        class Widget {
        public:
          Widget();
          static Widget make();
          void render() const;
          int count;
        };
        """,
      languageID: "cpp",
      fileName: "Widget.hpp",
      url: url
    )
    XCTAssertEqual(symbols.first(where: { $0.name == "render" })?.kind, .method)
    XCTAssertEqual(symbols.first(where: { $0.name == "render" })?.ownerType, "Widget")
    XCTAssertNotNil(symbols.first(where: { $0.name == "Widget" && $0.kind == .constructor }))
    XCTAssertEqual(symbols.first(where: { $0.name == "make" })?.isStatic, true)
    XCTAssertEqual(symbols.first(where: { $0.name == "count" })?.kind, .field)
    XCTAssertTrue(symbols.filter { $0.ownerType == "Widget" }.allSatisfy(\.isDeclaration))
  }

  func testOverrideContextPrefersInheritedClassMethod() throws {
    let text = """
      class Child: Parent {
        override func re
      }
      """
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(
      atUTF16Offset: (text as NSString).range(of: "re\n").location + 2)
    let current = URL(fileURLWithPath: "/tmp/Child.swift")
    let symbols = [
      ProjectCompletionSymbol(
        name: "render", insertion: "render()", format: .snippet, kind: .method,
        fileName: "Parent.swift", url: URL(fileURLWithPath: "/tmp/Parent.swift"),
        occurrences: 1, ownerType: "Parent", isStatic: false, isDeclaration: true,
        fileRole: .implementation
      ),
      ProjectCompletionSymbol(
        name: "reset", insertion: "reset()", format: .snippet, kind: .method,
        fileName: "Other.swift", url: URL(fileURLWithPath: "/tmp/Other.swift"),
        occurrences: 1, ownerType: "Other", isStatic: false, isDeclaration: true,
        fileRole: .implementation
      ),
    ]
    let ranked = try CompletionRankingEngine.rank(
      [Completion(label: "reset", kind: .method), Completion(label: "render", kind: .method)],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20,
      currentURI: current,
      projectSymbols: symbols
    )
    XCTAssertEqual(ranked.first?.label, "render")
  }

  func testQualifiedMethodDefinitionDoesNotTreatTypeAsStaticReceiver() throws {
    let text = "void Widget::re"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let current = URL(fileURLWithPath: "/tmp/Widget.cpp")
    let symbols = [
      ProjectCompletionSymbol(
        name: "reset", insertion: "reset()", format: .snippet, kind: .method,
        fileName: "Widget.hpp", url: URL(fileURLWithPath: "/tmp/Widget.hpp"),
        occurrences: 1, ownerType: "Widget", isStatic: true, isDeclaration: true,
        fileRole: .header
      ),
      ProjectCompletionSymbol(
        name: "render", insertion: "render()", format: .snippet, kind: .method,
        fileName: "Widget.hpp", url: URL(fileURLWithPath: "/tmp/Widget.hpp"),
        occurrences: 1, ownerType: "Widget", isStatic: false, isDeclaration: true,
        fileRole: .header
      ),
    ]
    let ranked = try CompletionRankingEngine.rank(
      [Completion(label: "reset", kind: .method), Completion(label: "render", kind: .method)],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "cpp",
      usageHistory: .init(),
      limit: 20,
      currentURI: current,
      projectSymbols: symbols
    )
    XCTAssertEqual(ranked.first?.label, "render")
  }

  func testCompactWordBoundaryMatchOutranksSparseSubsequence() throws {
    let text = "lup"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "lookup", kind: .method),
        Completion(label: "loadUserProfile", kind: .method),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "loadUserProfile")
  }

  func testAutomaticCompletionStronglyDemotesNonMatchingServerItems() throws {
    let text = "service.ref"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "status", kind: .property, sortText: "0000", serviceIdentifier: "lsp"),
        Completion(label: "refresh", kind: .method, sortText: "9999", serviceIdentifier: "lsp"),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .triggerCharacter("."),
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "refresh")
  }

  func testServerSortTextActsAsPriorWhenSignalsAreOtherwiseEqual() throws {
    let text = "val"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "valueZulu", kind: .variable, sortText: "9000", serviceIdentifier: "lsp"),
        Completion(label: "valueBeta", kind: .variable, sortText: "0001", serviceIdentifier: "lsp"),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .explicit,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "valueBeta")
  }

  func testDeprecatedCandidateIsPenalizedEvenWithBetterServerSortText() throws {
    let text = "loa"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(
          label: "loadLegacy", kind: .method, detail: "Deprecated method", sortText: "0000",
          serviceIdentifier: "lsp"
        ),
        Completion(label: "loadCurrent", kind: .method, sortText: "9999", serviceIdentifier: "lsp"),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "loadCurrent")
  }

  func testArgumentContextPrefersValuesOverTypesAndKeywords() throws {
    let text = "send(us"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "UserService", kind: .struct),
        Completion(label: "using", kind: .keyword),
        Completion(label: "user", kind: .variable),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "user")
  }

  func testConditionContextDemotesTypeNames() throws {
    let text = "if is"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "Issue", kind: .struct),
        Completion(label: "isReady", kind: .variable),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "isReady")
  }

  func testPatternContextPrefersEnumMembers() throws {
    let text = "case re"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "render", kind: .method),
        Completion(label: "ready", kind: .enumMember),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "ready")
  }

  func testAttributeContextPrefersAttributeLikeCandidates() throws {
    let text = "@ava"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "avatar", kind: .variable),
        Completion(label: "available", kind: .keyword),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "available")
  }

  func testDictionaryColonIsNotMisclassifiedAsTypePosition() throws {
    let text = "let values = [\"key\": va"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "ValueType", kind: .struct),
        Completion(label: "value", kind: .variable),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "value")
  }

  func testFunctionParameterAnnotationIsRecognizedAsTypePosition() throws {
    let text = "func use(value: Us"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "user", kind: .variable),
        Completion(label: "UserService", kind: .struct),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "UserService")
  }

  func testFilterTextParticipatesInNameMatching() throws {
    let text = "map"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "transform(_:)", kind: .method, filterText: "map"),
        Completion(label: "mappedValue", kind: .variable),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .explicit,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "transform(_:)")
  }

  func testAcronymToWordBoundaryIsRecognized() {
    let match = CompletionNameMatcher.match("URLSession", prefix: "us")
    XCTAssertEqual(match?.tier, .wordBoundary)
  }

  func testUnicodeIdentifierMatchingPreservesCharacterIndices() {
    let match = CompletionNameMatcher.match("caféValue", prefix: "cafe")
    XCTAssertEqual(match?.tier, .caseInsensitivePrefix)
    XCTAssertGreaterThan(match?.score ?? 0, 1_000)
  }

  func testNearbyIdentifierWordsProvideContextualTieBreak() throws {
    let text = """
      let userProfile = loadProfile()
      consume(userProfile)
      re
      """
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "refreshCache", kind: .method),
        Completion(label: "reloadProfile", kind: .method),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "reloadProfile")
  }

  func testFunctionParameterNameContextPrefersValueIdentifiers() throws {
    let text = "func send(us"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "UserService", kind: .struct),
        Completion(label: "user", kind: .variable),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "user")
  }

  func testCurrentDocumentCandidateCanOutrankServerSortPrior() throws {
    let text = "val"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(
          label: "valueRemote", kind: .variable, detail: "SDK", sortText: "0000",
          serviceIdentifier: "lsp"
        ),
        Completion(
          label: "valueLocal", kind: .variable, detail: "Current document",
          serviceIdentifier: "editor-context"
        ),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .explicit,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "valueLocal")
  }

  func testReturnExpressionUsesEnclosingFunctionReturnType() throws {
    let text = """
      func loadUser() -> User {
        return us
      }
      """
    let snapshot = TextSnapshot(text: text)
    let offset = (text as NSString).range(of: "us\n").location + 2
    let position = try snapshot.position(atUTF16Offset: offset)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "userCount", kind: .variable, detail: "Int"),
        Completion(label: "userFromCache", kind: .variable, detail: "User"),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "userFromCache")
  }

  func testExpectedTypeDoesNotMatchLongerTypeNameSubstring() throws {
    let text = "let value: User = us"
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "userSettings", kind: .variable, detail: "UserSettings"),
        Completion(label: "user", kind: .variable, detail: "User"),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "user")
  }

  func testOptionalReturnTypeUsesCanonicalExpectedTypeToken() throws {
    let text = """
      func loadUser() -> User? {
        return us
      }
      """
    let snapshot = TextSnapshot(text: text)
    let offset = (text as NSString).range(of: "us\n").location + 2
    let position = try snapshot.position(atUTF16Offset: offset)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "userCount", kind: .variable, detail: "Int"),
        Completion(label: "userFromCache", kind: .variable, detail: "User"),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "userFromCache")
  }

  func testOpaqueSwiftReturnTypeUsesUnderlyingProtocolToken() throws {
    let text = """
      func makeSource() -> some DataSource {
        return da
      }
      """
    let snapshot = TextSnapshot(text: text)
    let offset = (text as NSString).range(of: "da\n").location + 2
    let position = try snapshot.position(atUTF16Offset: offset)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "dataCount", kind: .variable, detail: "Int"),
        Completion(label: "dataSource", kind: .variable, detail: "DataSource"),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .automatic,
      languageID: "swift",
      usageHistory: .init(),
      limit: 20
    )
    XCTAssertEqual(ranked.first?.label, "dataSource")
  }

  func testExpectedTypeOutranksAnUnrelatedMemberMethod() throws {
    let text = """
      let value: Vec<Int> = Vec()
      let count: usize = value.
      """
    let snapshot = TextSnapshot(text: text)
    let position = try snapshot.position(atUTF16Offset: text.utf16.count)
    let ranked = try CompletionRankingEngine.rank(
      [
        Completion(label: "clear", kind: .method, detail: "Method • Vec • clear() • -> ()"),
        Completion(label: "len", kind: .method, detail: "Method • Vec • len() • -> usize"),
      ],
      snapshot: snapshot,
      position: position,
      invocation: .triggerCharacter("."),
      languageID: "rust",
      usageHistory: .init(),
      limit: 20
    )

    XCTAssertEqual(ranked.first?.label, "len")
  }

}
