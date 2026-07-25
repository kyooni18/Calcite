import Foundation

public struct TextBuffer: Sendable {
    public private(set) var text: String
    public private(set) var version: Int

    public init(text: String = "", version: Int = 0) {
        self.text = text
        self.version = version
    }

    public var snapshot: TextSnapshot { TextSnapshot(text: text, version: version) }

    public func utf16Offset(of position: TextPosition) throws -> Int {
        try snapshot.utf16Offset(of: position)
    }

    public func position(atUTF16Offset offset: Int) throws -> TextPosition {
        try snapshot.position(atUTF16Offset: offset)
    }

    @discardableResult
    public mutating func apply(_ edit: TextEdit) throws -> AppliedTextEdit {
        let oldSnapshot = snapshot
        let nsRange = try oldSnapshot.nsRange(for: edit.range)
        let (nextVersion, overflowed) = version.addingReportingOverflow(1)
        guard !overflowed else { throw TextBufferError.versionOverflow }
        let updatedText = (text as NSString).replacingCharacters(in: nsRange, with: edit.replacement)
        text = updatedText
        version = nextVersion
        return AppliedTextEdit(
            edit: edit,
            oldSnapshot: oldSnapshot,
            newSnapshot: snapshot,
            oldUTF16Range: nsRange
        )
    }

    @discardableResult
    public mutating func apply(_ edits: [TextEdit]) throws -> [AppliedTextEdit] {
        let sorted = edits.enumerated().sorted { lhs, rhs in
            if lhs.element.range.start != rhs.element.range.start {
                return lhs.element.range.start > rhs.element.range.start
            }
            if lhs.element.range.end != rhs.element.range.end {
                return lhs.element.range.end > rhs.element.range.end
            }
            // Apply equal-position insertions in reverse caller order so the
            // resulting text preserves the caller's original order.
            return lhs.offset > rhs.offset
        }
        for pair in zip(sorted, sorted.dropFirst()) {
            if pair.1.element.range.end > pair.0.element.range.start {
                throw TextBufferError.overlappingEdits
            }
        }

        var working = self
        var applied: [AppliedTextEdit] = []
        applied.reserveCapacity(sorted.count)
        for item in sorted { applied.append(try working.apply(item.element)) }
        self = working
        return applied
    }
}
