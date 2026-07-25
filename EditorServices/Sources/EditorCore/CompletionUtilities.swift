public enum CompletionUtilities {
    public static func merge(
        preferred: [Completion],
        fallback: [Completion],
        limit: Int = 100
    ) -> [Completion] {
        guard limit > 0 else { return [] }
        var identities = Set<String>()
        var output: [Completion] = []
        output.reserveCapacity(min(limit, preferred.count + fallback.count))

        for item in preferred + fallback {
            let identity = item.primaryEdit?.replacement ?? item.insertText ?? item.label
            guard identities.insert(identity).inserted else { continue }
            output.append(item)
            if output.count == limit { break }
        }
        return output
    }
}
