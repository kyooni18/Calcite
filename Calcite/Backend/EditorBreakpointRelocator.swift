import Foundation

nonisolated enum EditorBreakpointRelocator {
  private struct Candidate {
    var line: Int
    var score: Int
    var distance: Int
  }

  static func relocate(
    _ records: [EditorStoredBreakpoint],
    in text: String,
    searchRadius: Int = 40
  ) -> [EditorStoredBreakpoint] {
    let lines = text.components(separatedBy: .newlines)
    guard !lines.isEmpty else {
      return records.map { record in
        var record = record
        record.resolvedLine = nil
        record.verificationMessage = "The document is empty."
        return record
      }
    }

    return records.map { original in
      var record = original
      guard record.isEnabled else {
        record.resolvedLine = nil
        record.verificationMessage = "Disabled"
        return record
      }

      if matches(record.lineTextHash, line: original.requestedLine, in: lines) {
        record.resolvedLine = original.requestedLine
        record.verificationMessage = nil
        return record
      }

      let lower = max(1, original.requestedLine - max(1, searchRadius))
      let upper = min(lines.count, original.requestedLine + max(1, searchRadius))
      var candidates: [Candidate] = []
      for line in lower...upper {
        var score = 0
        if matches(record.lineTextHash, line: line, in: lines) { score += 8 }
        if matches(record.leadingContextHash, line: line - 1, in: lines) { score += 3 }
        if matches(record.trailingContextHash, line: line + 1, in: lines) { score += 3 }
        guard score > 0 else { continue }
        candidates.append(
          Candidate(line: line, score: score, distance: abs(line - original.requestedLine))
        )
      }

      guard
        let best = candidates.sorted(by: {
          if $0.score != $1.score { return $0.score > $1.score }
          if $0.distance != $1.distance { return $0.distance < $1.distance }
          return $0.line < $1.line
        }).first,
        best.score >= 6
      else {
        record.resolvedLine = nil
        record.verificationMessage = "The original source context could not be found."
        return record
      }

      record.resolvedLine = best.line
      record.verificationMessage =
        best.line == original.requestedLine
        ? nil
        : "Moved from line \(original.requestedLine) to \(best.line)."
      return record
    }
  }

  private static func matches(_ expected: String?, line: Int, in lines: [String]) -> Bool {
    guard let expected, line > 0, line <= lines.count else { return false }
    return EditorSourceFingerprint.hash(lines[line - 1]) == expected
  }
}
