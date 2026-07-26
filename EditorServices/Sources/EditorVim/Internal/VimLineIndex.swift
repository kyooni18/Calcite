import Foundation

/// Incrementally maintained UTF-16 line table used by motions and Ex ranges.
///
/// Replacements rescan only the affected line region and shift the untouched
/// suffix. A defensive full rebuild is used if an edit cannot be reconciled.
final class VimLineIndex {
  private var isValid = false
  private var starts: [Int] = [0]
  private var contentEnds: [Int] = [0]
  private var ends: [Int] = [0]
  private var indexedLength = 0

  var lineCount: Int { starts.count }

  func invalidate() {
    isValid = false
  }

  func synchronize(with text: String) {
    guard !isValid || indexedLength != text.utf16.count else { return }
    rebuild(with: text)
  }

  func apply(
    replacementRange: Range<Int>,
    removedText: String,
    insertedText: String,
    resultingText: String
  ) {
    guard isValid,
      replacementRange.lowerBound >= 0,
      replacementRange.upperBound >= replacementRange.lowerBound,
      replacementRange.upperBound <= indexedLength,
      replacementRange.count == removedText.utf16.count
    else {
      rebuild(with: resultingText)
      return
    }

    let oldLength = indexedLength
    let delta = insertedText.utf16.count - removedText.utf16.count
    guard oldLength + delta == resultingText.utf16.count else {
      rebuild(with: resultingText)
      return
    }

    let startLine = lineIndex(containing: replacementRange.lowerBound, textLength: oldLength)
    let upperProbe =
      replacementRange.isEmpty
      ? replacementRange.lowerBound
      : max(replacementRange.lowerBound, replacementRange.upperBound - 1)
    let endLine = lineIndex(containing: upperProbe, textLength: oldLength)

    // Include a stable line on both sides of the edit. A replacement can join
    // or split CRLF and can remove the terminator immediately before the edited
    // line, so retaining the directly adjacent prefix is not safe.
    let scanStartLine = max(0, startLine - 1)
    let suffixLine = min(starts.count, endLine + 3)
    let scanStart = starts[scanStartLine]
    let oldSuffixOffset = suffixLine < starts.count ? starts[suffixLine] : oldLength
    let newSuffixOffset = oldSuffixOffset + delta

    guard scanStart <= newSuffixOffset,
      newSuffixOffset >= 0,
      newSuffixOffset <= resultingText.utf16.count
    else {
      rebuild(with: resultingText)
      return
    }

    let oldStarts = starts
    let oldContentEnds = contentEnds
    let oldEnds = ends

    var rebuiltStarts = Array(oldStarts[..<scanStartLine])
    var rebuiltContentEnds = Array(oldContentEnds[..<scanStartLine])
    var rebuiltEnds = Array(oldEnds[..<scanStartLine])

    appendScannedLines(
      in: resultingText,
      range: scanStart..<newSuffixOffset,
      includeTrailingLogicalLine: suffixLine == oldStarts.count,
      starts: &rebuiltStarts,
      contentEnds: &rebuiltContentEnds,
      ends: &rebuiltEnds
    )

    if suffixLine < oldStarts.count {
      for index in suffixLine..<oldStarts.count {
        rebuiltStarts.append(oldStarts[index] + delta)
        rebuiltContentEnds.append(oldContentEnds[index] + delta)
        rebuiltEnds.append(oldEnds[index] + delta)
      }
    }

    guard
      validate(
        starts: rebuiltStarts,
        contentEnds: rebuiltContentEnds,
        ends: rebuiltEnds,
        textLength: resultingText.utf16.count
      )
    else {
      rebuild(with: resultingText)
      return
    }

    starts = rebuiltStarts
    contentEnds = rebuiltContentEnds
    ends = rebuiltEnds
    indexedLength = resultingText.utf16.count
    isValid = true
  }

  func lineStart(containing offset: Int, textLength: Int) -> Int {
    starts[lineIndex(containing: offset, textLength: textLength)]
  }

  func contentEnd(containing offset: Int, textLength: Int) -> Int {
    contentEnds[lineIndex(containing: offset, textLength: textLength)]
  }

  func endIncludingTerminator(containing offset: Int, textLength: Int) -> Int {
    ends[lineIndex(containing: offset, textLength: textLength)]
  }

  func offset(ofOneBasedLine number: Int) -> Int {
    guard !starts.isEmpty else { return 0 }
    let index = max(0, min(starts.count - 1, number - 1))
    return starts[index]
  }

  func oneBasedLine(containing offset: Int, textLength: Int) -> Int {
    lineIndex(containing: offset, textLength: textLength) + 1
  }

  private func rebuild(with text: String) {
    starts.removeAll(keepingCapacity: true)
    contentEnds.removeAll(keepingCapacity: true)
    ends.removeAll(keepingCapacity: true)
    appendScannedLines(
      in: text,
      range: 0..<text.utf16.count,
      includeTrailingLogicalLine: true,
      starts: &starts,
      contentEnds: &contentEnds,
      ends: &ends
    )
    if starts.isEmpty {
      starts = [0]
      contentEnds = [0]
      ends = [0]
    }
    indexedLength = text.utf16.count
    isValid = true
  }

  private func appendScannedLines(
    in text: String,
    range: Range<Int>,
    includeTrailingLogicalLine: Bool,
    starts outputStarts: inout [Int],
    contentEnds outputContentEnds: inout [Int],
    ends outputEnds: inout [Int]
  ) {
    let ns = text as NSString
    let lower = max(0, min(range.lowerBound, ns.length))
    let upper = max(lower, min(range.upperBound, ns.length))
    var lineStart = lower
    outputStarts.append(lineStart)
    var offset = lower

    while offset < upper {
      let value = ns.character(at: offset)
      if value == 10 {  // LF
        outputContentEnds.append(offset)
        outputEnds.append(offset + 1)
        offset += 1
        lineStart = offset
        if offset < upper || includeTrailingLogicalLine { outputStarts.append(lineStart) }
        continue
      }
      if value == 13 {  // CR or CRLF
        outputContentEnds.append(offset)
        var terminatorLength = 1
        if offset + 1 < upper, ns.character(at: offset + 1) == 10 {
          terminatorLength = 2
        }
        offset += terminatorLength
        outputEnds.append(offset)
        lineStart = offset
        if offset < upper || includeTrailingLogicalLine { outputStarts.append(lineStart) }
        continue
      }
      offset += 1
    }

    if outputContentEnds.count < outputStarts.count {
      outputContentEnds.append(upper)
      outputEnds.append(upper)
    }
  }

  private func validate(
    starts: [Int],
    contentEnds: [Int],
    ends: [Int],
    textLength: Int
  ) -> Bool {
    guard !starts.isEmpty,
      starts.count == contentEnds.count,
      starts.count == ends.count,
      starts[0] == 0
    else { return false }
    for index in starts.indices {
      guard starts[index] <= contentEnds[index],
        contentEnds[index] <= ends[index],
        ends[index] <= textLength
      else { return false }
      if index > 0, starts[index] < starts[index - 1] { return false }
    }
    return true
  }

  private func lineIndex(containing offset: Int, textLength: Int) -> Int {
    let target = max(0, min(offset, textLength))
    var lower = 0
    var upper = starts.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if starts[middle] <= target {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return max(0, lower - 1)
  }
}
