import EditorCore

public struct SwiftKeywordCompletionProvider: Sendable {
    public static let keywords: [String] = [
        "actor", "any", "associatedtype", "async", "await", "break", "case", "catch", "class",
        "continue", "convenience", "copy", "default", "defer", "deinit", "didSet", "do", "dynamic",
        "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func",
        "get", "guard", "if", "import", "indirect", "infix", "init", "inout", "internal", "is",
        "isolated", "lazy", "let", "macro", "mutating", "nil", "nonisolated", "open", "operator",
        "override", "package", "postfix", "precedencegroup", "prefix", "private", "protocol", "public",
        "repeat", "required", "rethrows", "return", "self", "set", "some", "static", "struct",
        "subscript", "super", "switch", "throws", "true", "try", "typealias", "unowned", "var",
        "weak", "where", "while", "willSet", "yield"
    ]

    public init() {}

    public func completions(prefix: String = "") -> [Completion] {
        Self.keywords.lazy
            .filter { prefix.isEmpty || $0.hasPrefix(prefix) }
            .map { Completion(label: $0, kind: .keyword, insertText: $0) }
    }
}
