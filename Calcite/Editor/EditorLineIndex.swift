import Foundation

/// Stores UTF-16 line starts so cursor-to-line lookups stay logarithmic.
/// Edits rescan only the surrounding lines and shift the untouched suffix.
struct EditorLineIndex: Sendable {
  private(set) var lineStarts: [Int]
  private(set) var utf16Length: Int

  init(text: String) {
    let source = text as NSString
    self.utf16Length = source.length
    self.lineStarts = Self.makeLineStarts(
      in: source,
      range: NSRange(location: 0, length: source.length)
    )
  }

  var lineCount: Int { max(1, lineStarts.count) }

  func lineNumber(atUTF16Offset rawOffset: Int) -> Int {
    let offset = min(max(rawOffset, 0), utf16Length)
    var low = 0
    var high = lineStarts.count
    while low < high {
      let middle = (low + high) / 2
      if lineStarts[middle] <= offset {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return max(1, low)
  }

  func columnNumber(atUTF16Offset rawOffset: Int) -> Int {
    let offset = min(max(rawOffset, 0), utf16Length)
    let index = lineIndex(containing: offset)
    return max(1, offset - lineStarts[index] + 1)
  }

  mutating func replace(
    range rawRange: NSRange,
    replacement: String,
    resultingText: String
  ) {
    let newSource = resultingText as NSString
    let location = min(max(rawRange.location, 0), utf16Length)
    let range = NSRange(
      location: location,
      length: min(max(rawRange.length, 0), utf16Length - location)
    )
    let replacementSource = replacement as NSString
    let expectedLength = utf16Length - range.length + replacementSource.length
    let insertedRange = NSRange(location: location, length: replacementSource.length)
    let replacementAppearsAtExpectedOffset =
      NSMaxRange(insertedRange) <= newSource.length
      && newSource.substring(with: insertedRange) == replacement
    guard
      expectedLength == newSource.length,
      !lineStarts.isEmpty,
      replacementAppearsAtExpectedOffset
    else {
      // Foundation can normalize edits whose UTF-16 offsets split a surrogate pair.
      // The resulting replacement may then move to a neighboring boundary, so the
      // incremental assumptions no longer hold.
      rebuild(with: resultingText)
      return
    }

    // Include neighboring lines so edits that create or split CRLF pairs cannot
    // invalidate a boundary immediately outside the replaced range.
    let scanStartOffset = max(0, range.location - 1)
    let scanEndOffset = min(utf16Length, NSMaxRange(range) + 1)
    let firstLineIndex = lineIndex(containing: scanStartOffset)
    let lastTouchedLineIndex = lineIndex(containing: scanEndOffset)
    let suffixLineIndex = min(lineStarts.count, lastTouchedLineIndex + 2)
    let oldSegmentStart = lineStarts[firstLineIndex]
    let oldSegmentEnd =
      suffixLineIndex < lineStarts.count
      ? lineStarts[suffixLineIndex]
      : utf16Length
    let delta = newSource.length - utf16Length
    let newSegmentEnd = min(max(oldSegmentStart, oldSegmentEnd + delta), newSource.length)

    var updated = Array(lineStarts[..<firstLineIndex])
    updated.append(
      contentsOf: Self.makeLineStarts(
        in: newSource,
        range: NSRange(location: oldSegmentStart, length: newSegmentEnd - oldSegmentStart),
        includeTerminalEmptyLine: newSegmentEnd == newSource.length
      )
    )

    if oldSegmentEnd < utf16Length {
      for start in lineStarts where start >= oldSegmentEnd {
        let shifted = start + delta
        if updated.last != shifted { updated.append(shifted) }
      }
    }

    if updated.isEmpty || updated[0] != 0 { updated.insert(0, at: 0) }
    lineStarts = updated
    utf16Length = newSource.length
  }

  mutating func rebuild(with text: String) {
    let source = text as NSString
    utf16Length = source.length
    lineStarts = Self.makeLineStarts(
      in: source,
      range: NSRange(location: 0, length: source.length),
      includeTerminalEmptyLine: true
    )
  }

  private func lineIndex(containing rawOffset: Int) -> Int {
    let offset = min(max(rawOffset, 0), utf16Length)
    var low = 0
    var high = lineStarts.count
    while low < high {
      let middle = (low + high) / 2
      if lineStarts[middle] <= offset {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return max(0, low - 1)
  }

  private static func makeLineStarts(
    in source: NSString,
    range: NSRange,
    includeTerminalEmptyLine: Bool = true
  ) -> [Int] {
    let lowerBound = min(max(range.location, 0), source.length)
    let upperBound = min(max(NSMaxRange(range), lowerBound), source.length)
    var starts: [Int] = [lowerBound]
    var cursor = lowerBound

    while cursor < upperBound {
      let value = source.character(at: cursor)
      let breakEnd: Int?
      switch value {
      case 0x000D:  // CR or CRLF
        if cursor + 1 < source.length, source.character(at: cursor + 1) == 0x000A {
          breakEnd = cursor + 2
        } else {
          breakEnd = cursor + 1
        }
      case 0x000A, 0x0085, 0x2028, 0x2029:
        breakEnd = cursor + 1
      default:
        breakEnd = nil
      }

      guard let breakEnd else {
        cursor += 1
        continue
      }
      guard breakEnd <= upperBound else { break }
      if breakEnd < upperBound || (includeTerminalEmptyLine && breakEnd == upperBound) {
        if starts.last != breakEnd { starts.append(breakEnd) }
      }
      cursor = breakEnd
    }
    return starts
  }
}
