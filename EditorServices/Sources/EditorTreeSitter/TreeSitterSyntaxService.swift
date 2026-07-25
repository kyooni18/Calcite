import Foundation
import EditorCore
import SwiftTreeSitter
import TreeSitterSwift

public enum TreeSitterServiceError: Error, Equatable, Sendable {
    case parseFailed
    case staleChange(expectedVersion: Int, receivedVersion: Int)
    case documentTooLarge
    case treeCopyFailed
    case missingSwiftHighlightQuery
    case missingSwiftFoldQuery
}

public actor TreeSitterSyntaxService: SyntaxProviding {
    private let parser: Parser
    private let highlightQuery: Query?
    private let foldQuery: Query?
    private var tree: MutableTree?
    private var snapshot = TextSnapshot(text: "")
    private var changedTextRanges: [EditorTextRange] = []
    private let retainedLanguageLifetime: (any TreeSitterLanguageLifetime)?

    public init(
        language: Language,
        highlightQuery: String? = nil,
        foldQuery: String? = nil,
        retainedLanguageLifetime: (any TreeSitterLanguageLifetime)? = nil
    ) throws {
        let parser = Parser()
        try parser.setLanguage(language)
        self.parser = parser
        self.highlightQuery = try highlightQuery.map { try Query(language: language, data: Data($0.utf8)) }
        self.foldQuery = try foldQuery.map { try Query(language: language, data: Data($0.utf8)) }
        self.retainedLanguageLifetime = retainedLanguageLifetime
    }

    public static func swift(
        highlightQuery: String? = nil,
        foldQuery: String? = nil
    ) throws -> TreeSitterSyntaxService {
        let language = Language(language: tree_sitter_swift())
        let highlights = try highlightQuery ?? resource(named: "swift-highlights", error: .missingSwiftHighlightQuery)
        let folds = try foldQuery ?? resource(named: "swift-folds", error: .missingSwiftFoldQuery)
        return try TreeSitterSyntaxService(language: language, highlightQuery: highlights, foldQuery: folds)
    }

    public static func bundledQuery(named name: String) throws -> String {
        let error: TreeSitterServiceError = name.contains("fold") ? .missingSwiftFoldQuery : .missingSwiftHighlightQuery
        return try resource(named: name, error: error)
    }

    private static func resource(named name: String, error: TreeSitterServiceError) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "scm") else { throw error }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func open(snapshot: TextSnapshot) async throws {
        guard let parsed = parser.parse(snapshot.text) else { throw TreeSitterServiceError.parseFailed }
        self.tree = parsed
        self.snapshot = snapshot
        self.changedTextRanges = snapshot.utf16Count == 0 ? [] : [
            EditorTextRange(start: .zero, end: try snapshot.position(atUTF16Offset: snapshot.utf16Count))
        ]
    }

    public func apply(change: AppliedTextEdit) async throws {
        guard change.oldSnapshot.version == snapshot.version else {
            throw TreeSitterServiceError.staleChange(expectedVersion: snapshot.version, receivedVersion: change.oldSnapshot.version)
        }
        guard let oldTree = tree else {
            try await open(snapshot: change.newSnapshot)
            return
        }
        guard let editedTree = oldTree.mutableCopy() else { throw TreeSitterServiceError.treeCopyFailed }
        editedTree.edit(try makeInputEdit(change))
        guard let newTree = parser.parse(tree: editedTree, string: change.newSnapshot.text) else {
            throw TreeSitterServiceError.parseFailed
        }

        var ranges: [EditorTextRange] = []
        for changed in editedTree.changedRanges(from: newTree) {
            let lower = Int(changed.bytes.lowerBound) / 2
            let upper = Int(changed.bytes.upperBound) / 2
            guard lower <= change.newSnapshot.utf16Count, upper <= change.newSnapshot.utf16Count else { continue }
            ranges.append(EditorTextRange(
                start: try change.newSnapshot.position(atUTF16Offset: lower),
                end: try change.newSnapshot.position(atUTF16Offset: upper)
            ))
        }
        let replacementEndOffset = try change.newSnapshot.utf16Offset(of: change.edit.range.start) + change.edit.replacement.utf16.count
        let editedRange = EditorTextRange(
            start: change.edit.range.start,
            end: try change.newSnapshot.position(atUTF16Offset: replacementEndOffset)
        )
        ranges.append(editedRange)
        self.tree = newTree
        self.snapshot = change.newSnapshot
        self.changedTextRanges = Array(Set(ranges)).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    public func highlights(in range: EditorTextRange? = nil) async throws -> [Highlight] {
        guard let tree, let query = highlightQuery else { return [] }
        let requested = try range.map { try snapshot.nsRange(for: $0) }
        var values = Set<Highlight>()
        let cursor = query.execute(in: tree)
        while let capture = cursor.nextCapture() {
            guard let name = capture.name else { continue }
            let utf16 = capture.range
            guard utf16.location >= 0, utf16.length >= 0, NSMaxRange(utf16) <= snapshot.utf16Count else { continue }
            if let requested, NSIntersectionRange(requested, utf16).length == 0, requested.length > 0, utf16.length > 0 { continue }
            let textRange = EditorTextRange(
                start: try snapshot.position(atUTF16Offset: utf16.location),
                end: try snapshot.position(atUTF16Offset: NSMaxRange(utf16))
            )
            values.insert(Highlight(range: textRange, capture: name))
        }
        return values.sorted { ($0.range.start, $0.range.end, $0.capture) < ($1.range.start, $1.range.end, $1.capture) }
    }

    public func foldingRanges() async throws -> [FoldingRange] {
        guard let tree, let query = foldQuery else { return [] }
        var values = Set<FoldingRange>()
        let cursor = query.execute(in: tree)
        while let capture = cursor.nextCapture() {
            let utf16 = capture.range
            guard utf16.location >= 0, utf16.length >= 0, NSMaxRange(utf16) <= snapshot.utf16Count else { continue }
            let start = try snapshot.position(atUTF16Offset: utf16.location)
            let end = try snapshot.position(atUTF16Offset: NSMaxRange(utf16))
            guard start.line < end.line else { continue }
            let kind: FoldingRangeKind? = capture.node.nodeType?.contains("comment") == true ? .comment : nil
            values.insert(FoldingRange(range: EditorTextRange(start: start, end: end), kind: kind))
        }
        return values.sorted { ($0.range.start, $0.range.end) < ($1.range.start, $1.range.end) }
    }

    public func close() async throws {
        tree = nil
        snapshot = TextSnapshot(text: "")
        changedTextRanges = []
    }

    public func changedRanges() -> [EditorTextRange] { changedTextRanges }
    public func rootSExpression() -> String? { tree?.rootNode?.sExpressionString }

    private func makeInputEdit(_ change: AppliedTextEdit) throws -> InputEdit {
        let old = change.oldSnapshot
        let new = change.newSnapshot
        let start = change.edit.range.start
        let oldEnd = change.edit.range.end
        let startOffset = try old.utf16Offset(of: start)
        let oldEndOffset = try old.utf16Offset(of: oldEnd)
        let newEndOffset = startOffset + change.edit.replacement.utf16.count
        let newEnd = try new.position(atUTF16Offset: newEndOffset)
        return InputEdit(
            startByte: try checkedByte(startOffset),
            oldEndByte: try checkedByte(oldEndOffset),
            newEndByte: try checkedByte(newEndOffset),
            startPoint: Point(row: start.line, column: try checkedColumn(start.utf16Column)),
            oldEndPoint: Point(row: oldEnd.line, column: try checkedColumn(oldEnd.utf16Column)),
            newEndPoint: Point(row: newEnd.line, column: try checkedColumn(newEnd.utf16Column))
        )
    }

    private func checkedByte(_ utf16Offset: Int) throws -> UInt32 {
        let (value, overflow) = utf16Offset.multipliedReportingOverflow(by: 2)
        guard !overflow, value >= 0, value <= Int(UInt32.max) else { throw TreeSitterServiceError.documentTooLarge }
        return UInt32(value)
    }

    private func checkedColumn(_ utf16Column: Int) throws -> Int {
        let (value, overflow) = utf16Column.multipliedReportingOverflow(by: 2)
        guard !overflow, value >= 0, value <= Int(UInt32.max) else {
            throw TreeSitterServiceError.documentTooLarge
        }
        return value
    }
}
