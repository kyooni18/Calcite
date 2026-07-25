import XCTest
@testable import EditorLSP
import LanguageServerProtocol

final class ProtocolModelRegressionTests: XCTestCase {
    func testInlayHintCapabilitiesRetainResolveSupport() throws {
        let resolve = InlayHintClientCapabilities.ResolveSupport(
            properties: ["tooltip", "textEdits"]
        )
        let hint = InlayHintClientCapabilities(
            dynamicRegistration: true,
            resolveSupport: resolve
        )
        let text = TextDocumentClientCapabilities(inlayHint: hint)

        XCTAssertEqual(hint.resolveSupport, resolve)
        XCTAssertEqual(text.inlayHint, hint)

        let encoded = try JSONEncoder().encode(text)
        let decoded = try JSONDecoder().decode(TextDocumentClientCapabilities.self, from: encoded)
        XCTAssertEqual(decoded.inlayHint?.resolveSupport?.properties, ["tooltip", "textEdits"])
    }

    func testInlayHintLabelPartUsesStandardsCompliantTooltipKey() throws {
        let part = InlayHintLabelPart(value: "value", tooltip: .optionA("details"))
        let data = try JSONEncoder().encode(part)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["tooltip"] as? String, "details")
        XCTAssertNil(object["tooltop"])

        let decoded = try JSONDecoder().decode(InlayHintLabelPart.self, from: data)
        if case .optionA(let tooltip)? = decoded.tooltip {
            XCTAssertEqual(tooltip, "details")
        } else {
            XCTFail("Expected string tooltip")
        }
    }

    func testLegacyWorkspaceChangesAreConvertedInStableURIOrder() throws {
        let a = URL(fileURLWithPath: "/tmp/A.swift")
        let b = URL(fileURLWithPath: "/tmp/B.swift")
        let range = LSPRange(startPair: (0, 0), endPair: (0, 0))
        let value = WorkspaceEdit(
            changes: [
                b.absoluteString: [.init(range: range, newText: "b")],
                a.absoluteString: [.init(range: range, newText: "a")]
            ],
            documentChanges: nil
        )

        let converted = try XCTUnwrap(LSPConversion.workspaceEdit(value))
        XCTAssertEqual(converted.documentEdits.map(\.uri), [a, b])
    }
}
