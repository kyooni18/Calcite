import EditorCore
import Foundation

enum CompletionMatchTier: Int, Sendable {
  case subsequence
  case contiguousSubstring
  case wordBoundary
  case caseInsensitivePrefix
  case prefix
  case caseInsensitiveExact
  case exact
  case neutral
}

struct CompletionNameMatch: Sendable {
  var score: Int
  var tier: CompletionMatchTier
}

/// Shared low-latency matcher for both local candidate generation and final ranking.
///
/// The score rewards exact/prefix matches first, then compact word-boundary and contiguous
/// matches. Sparse subsequences remain available for explicit completion but receive gap and
/// late-start penalties so unrelated alphabetic matches do not crowd the top of the list.
enum CompletionNameMatcher {
  private static let matchingLocale = Locale(identifier: "en_US_POSIX")

  static func bestMatch(for completion: Completion, prefix: String) -> CompletionNameMatch? {
    var values: [String] = []
    if let filterText = completion.filterText, !filterText.isEmpty { values.append(filterText) }
    values.append(completion.label)
    if let replacement = completion.primaryEdit?.replacement, !replacement.isEmpty {
      values.append(replacement)
    } else if let insertText = completion.insertText, !insertText.isEmpty {
      values.append(insertText)
    }

    var seen = Set<String>()
    return values.compactMap { value -> CompletionNameMatch? in
      guard seen.insert(value).inserted else { return nil }
      return match(value, prefix: prefix)
    }.max { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score < rhs.score }
      return lhs.tier.rawValue < rhs.tier.rawValue
    }
  }

  static func score(_ candidate: String, prefix: String) -> Int? {
    match(candidate, prefix: prefix)?.score
  }

  static func match(_ candidate: String, prefix: String) -> CompletionNameMatch? {
    guard !candidate.isEmpty else { return nil }
    guard !prefix.isEmpty else {
      return CompletionNameMatch(score: 520, tier: .neutral)
    }

    if candidate == prefix {
      return CompletionNameMatch(score: 2_250, tier: .exact)
    }
    if candidate.compare(
      prefix, options: [.caseInsensitive, .diacriticInsensitive], locale: matchingLocale)
      == .orderedSame
    {
      return CompletionNameMatch(
        score: 2_150,
        tier: .caseInsensitiveExact
      )
    }

    let lengthPenalty = min(180, max(0, candidate.count - prefix.count) * 3)
    if candidate.hasPrefix(prefix) {
      return CompletionNameMatch(
        score: 1_980 - lengthPenalty,
        tier: .prefix
      )
    }
    if candidate.range(
      of: prefix,
      options: [.anchored, .caseInsensitive, .diacriticInsensitive],
      locale: matchingLocale
    ) != nil {
      return CompletionNameMatch(
        score: 1_850 - lengthPenalty,
        tier: .caseInsensitivePrefix
      )
    }

    let candidateCharacters = Array(candidate)
    let candidateFolded = candidateCharacters.map(Self.folded)
    let prefixCharacters = Array(prefix)
    let prefixFolded = prefixCharacters.map(Self.folded)

    if let range = candidate.range(
      of: prefix, options: [.caseInsensitive, .diacriticInsensitive], locale: matchingLocale)
    {
      let start = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
      let score = 1_260 - min(360, start * 24) - min(160, lengthPenalty)
      return CompletionNameMatch(
        score: score,
        tier: .contiguousSubstring
      )
    }

    guard let positions = subsequencePositions(prefixFolded, in: candidateFolded) else {
      return nil
    }

    var boundaryMatches = 0
    var contiguousPairs = 0
    var exactCaseMatches = 0
    for (prefixIndex, candidateIndex) in positions.enumerated() {
      if isBoundary(at: candidateIndex, in: candidateCharacters) { boundaryMatches += 1 }
      if prefixIndex > 0, candidateIndex == positions[prefixIndex - 1] + 1 {
        contiguousPairs += 1
      }
      if prefixIndex < prefixCharacters.count,
        candidateCharacters[candidateIndex] == prefixCharacters[prefixIndex]
      {
        exactCaseMatches += 1
      }
    }

    let start = positions.first ?? 0
    let span = (positions.last ?? start) - start + 1
    let gaps = max(0, span - prefixFolded.count)
    let trailingNoise = max(0, candidateCharacters.count - prefixCharacters.count)
    let allBoundary = boundaryMatches == prefixFolded.count

    var score = 720
    score += boundaryMatches * 105
    score += contiguousPairs * 58
    score += exactCaseMatches * 5
    score -= min(420, start * 22)
    score -= min(360, gaps * 20)
    score -= min(140, trailingNoise * 2)
    if positions.first == 0 { score += 90 }
    if allBoundary { score += 150 }

    guard score > 120 else { return nil }
    return CompletionNameMatch(
      score: score,
      tier: allBoundary ? .wordBoundary : .subsequence
    )
  }

  private static func folded(_ character: Character) -> String {
    String(character).folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: matchingLocale)
  }

  private static func subsequencePositions(
    _ pattern: [String],
    in candidate: [String]
  ) -> [Int]? {
    var positions: [Int] = []
    positions.reserveCapacity(pattern.count)
    var searchStart = 0
    for character in pattern {
      guard searchStart < candidate.count,
        let found = candidate[searchStart...].firstIndex(of: character)
      else { return nil }
      positions.append(found)
      searchStart = found + 1
    }
    return positions
  }

  private static func isBoundary(at index: Int, in characters: [Character]) -> Bool {
    guard index > 0 else { return true }
    let previous = characters[index - 1]
    let current = characters[index]
    if !previous.isLetter && !previous.isNumber { return true }
    if (previous.isLowercase || previous.isNumber) && current.isUppercase { return true }
    if previous.isUppercase, current.isUppercase,
      index + 1 < characters.count, characters[index + 1].isLowercase
    {
      return true
    }
    return false
  }
}

enum CompletionIdentifierTokenizer {
  static func words(in value: String) -> [String] {
    let characters = Array(value)
    guard !characters.isEmpty else { return [] }

    var words: [String] = []
    var current = ""
    for index in characters.indices {
      let character = characters[index]
      guard character.isLetter || character.isNumber else {
        if current.count > 1 { words.append(current.lowercased()) }
        current = ""
        continue
      }

      let previous =
        index > characters.startIndex ? characters[characters.index(before: index)] : nil
      let nextIndex = characters.index(after: index)
      let next = nextIndex < characters.endIndex ? characters[nextIndex] : nil
      let startsNewWord =
        !current.isEmpty
        && ((previous?.isLowercase == true || previous?.isNumber == true) && character.isUppercase
          || previous?.isUppercase == true && character.isUppercase && next?.isLowercase == true)
      if startsNewWord {
        if current.count > 1 { words.append(current.lowercased()) }
        current = String(character)
      } else {
        current.append(character)
      }
    }
    if current.count > 1 { words.append(current.lowercased()) }

    let compact = characters.filter { $0.isLetter || $0.isNumber }.map(String.init).joined()
      .lowercased()
    if compact.count > 1 { words.append(compact) }

    var seen = Set<String>()
    return words.filter { seen.insert($0).inserted }
  }
}
