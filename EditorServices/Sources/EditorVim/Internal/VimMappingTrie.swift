import Foundation

final class VimMappingTrie: @unchecked Sendable {
  final class Node {
    var invocation: VimInvocation?
    var children: [String: Node] = [:]
  }

  private(set) var root = Node()

  func replace(with mappings: [(tokens: [String], invocation: VimInvocation)]) {
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
      node.invocation = mapping.invocation
    }
    root = replacement
  }

  func match(_ tokens: [String]) -> (exact: VimInvocation?, isPrefix: Bool) {
    var node = root
    for token in tokens {
      guard let next = node.children[token] else { return (nil, false) }
      node = next
    }
    return (node.invocation, !node.children.isEmpty)
  }

  func longestExactPrefix(in tokens: [String]) -> (length: Int, invocation: VimInvocation)? {
    var node = root
    var best: (Int, VimInvocation)?
    for (index, token) in tokens.enumerated() {
      guard let next = node.children[token] else { break }
      node = next
      if let invocation = node.invocation { best = (index + 1, invocation) }
    }
    return best
  }
}
