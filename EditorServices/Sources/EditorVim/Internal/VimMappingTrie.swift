import Foundation

final class VimMappingTrie: @unchecked Sendable {
  final class Node {
    var mapping: VimResolvedMapping?
    var children: [VimInputToken: Node] = [:]
  }

  private(set) var root = Node()

  func replace(with mappings: [(tokens: [VimInputToken], mapping: VimResolvedMapping)]) {
    let replacement = Node()
    for mapping in mappings where !mapping.tokens.isEmpty {
      var node = replacement
      for token in mapping.tokens {
        if let existing = node.children[token] {
          node = existing
        } else {
          let child = Node()
          node.children[token] = child
          node = child
        }
      }
      node.mapping = mapping.mapping
    }
    root = replacement
  }

  func match(_ tokens: [VimInputToken]) -> (exact: VimResolvedMapping?, isPrefix: Bool) {
    var node = root
    for token in tokens {
      guard let next = node.children[token] else { return (nil, false) }
      node = next
    }
    return (node.mapping, !node.children.isEmpty)
  }

  func longestExactPrefix(
    in tokens: [VimInputToken]
  ) -> (length: Int, mapping: VimResolvedMapping)? {
    var node = root
    var best: (Int, VimResolvedMapping)?
    for (index, token) in tokens.enumerated() {
      guard let next = node.children[token] else { break }
      node = next
      if let mapping = node.mapping { best = (index + 1, mapping) }
    }
    return best
  }
}
