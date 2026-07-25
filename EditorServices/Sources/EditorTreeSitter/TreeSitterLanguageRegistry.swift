import EditorCore
import Foundation
import SwiftTreeSitter
import TreeSitterSwift

/// Keeps a dynamically loaded Tree-sitter language library alive for as long as parsers use it.
public protocol TreeSitterLanguageLifetime: AnyObject, Sendable {}

/// Query sources associated with a Tree-sitter grammar.
public struct TreeSitterQuerySet: Hashable, Sendable {
  public var highlights: String?
  public var folds: String?

  public init(highlights: String? = nil, folds: String? = nil) {
    self.highlights = highlights
    self.folds = folds
  }

  public static func load(
    highlightsURL: URL? = nil,
    foldsURL: URL? = nil
  ) throws -> TreeSitterQuerySet {
    try .init(
      highlights: highlightsURL.map { try String(contentsOf: $0, encoding: .utf8) },
      folds: foldsURL.map { try String(contentsOf: $0, encoding: .utf8) }
    )
  }
}

/// A grammar, its selectors, and optional highlight/folding queries.
public struct TreeSitterLanguageRegistration: @unchecked Sendable {
  public var id: String
  public var languageIDs: Set<String>
  public var fileExtensions: Set<String>
  public var priority: Int
  public var language: Language
  public var queries: TreeSitterQuerySet
  public var lifetime: (any TreeSitterLanguageLifetime)?

  public init(
    id: String,
    languageIDs: Set<String>,
    fileExtensions: Set<String> = [],
    priority: Int = 0,
    language: Language,
    queries: TreeSitterQuerySet = .init(),
    lifetime: (any TreeSitterLanguageLifetime)? = nil
  ) {
    self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
    self.languageIDs = Set(languageIDs.map(Self.normalize).filter { !$0.isEmpty })
    self.fileExtensions = Set(
      fileExtensions.map {
        Self.normalize($0).trimmingCharacters(in: CharacterSet(charactersIn: "."))
      }.filter { !$0.isEmpty }
    )
    self.priority = priority
    self.language = language
    self.queries = queries
    self.lifetime = lifetime
  }

  public func matches(uri: URL, languageID: String) -> Bool {
    let normalizedLanguage = Self.normalize(languageID)
    let normalizedExtension = Self.normalize(uri.pathExtension)
    if languageIDs.isEmpty && fileExtensions.isEmpty { return true }
    if languageIDs.contains(normalizedLanguage) { return true }
    return fileExtensions.contains(normalizedExtension)
  }

  private static func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

public struct TreeSitterLanguageDescriptor: Hashable, Sendable {
  public var id: String
  public var languageIDs: Set<String>
  public var fileExtensions: Set<String>
  public var priority: Int
}

public enum TreeSitterLanguageRegistryError: Error, Equatable, Sendable {
  case invalidIdentifier
  case duplicateRegistration(String)
  case unknownRegistration(String)
}

/// Thread-safe registry used by the editor backend to select one parser per document.
///
/// Registrations can wrap any grammar that exposes the standard Tree-sitter C ABI. The registry
/// does not depend on a fixed list of language packages.
public final class TreeSitterLanguageRegistry: @unchecked Sendable {
  private struct StoredRegistration {
    var order: Int
    var value: TreeSitterLanguageRegistration
  }

  private let lock = NSLock()
  private var nextOrder = 0
  private var values: [StoredRegistration] = []

  public init(registrations: [TreeSitterLanguageRegistration] = []) throws {
    for registration in registrations { try register(registration) }
  }

  public func register(_ registration: TreeSitterLanguageRegistration) throws {
    guard !registration.id.isEmpty else { throw TreeSitterLanguageRegistryError.invalidIdentifier }
    lock.lock()
    defer { lock.unlock() }
    guard !values.contains(where: { $0.value.id == registration.id }) else {
      throw TreeSitterLanguageRegistryError.duplicateRegistration(registration.id)
    }
    values.append(.init(order: nextOrder, value: registration))
    nextOrder += 1
  }

  public func unregister(_ id: String) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let index = values.firstIndex(where: { $0.value.id == id }) else {
      throw TreeSitterLanguageRegistryError.unknownRegistration(id)
    }
    values.remove(at: index)
  }

  public func registrations() -> [TreeSitterLanguageDescriptor] {
    lock.lock()
    let snapshot = values
    lock.unlock()
    return snapshot.sorted(by: Self.precedes).map {
      .init(
        id: $0.value.id,
        languageIDs: $0.value.languageIDs,
        fileExtensions: $0.value.fileExtensions,
        priority: $0.value.priority
      )
    }
  }

  /// Returns the highest-priority grammar that would be selected for a document.
  public func matchingRegistration(
    uri: URL,
    languageID: String
  ) -> TreeSitterLanguageDescriptor? {
    lock.lock()
    let selected = values
      .filter { $0.value.matches(uri: uri, languageID: languageID) }
      .sorted(by: Self.precedes)
      .first?.value
    lock.unlock()
    return selected.map {
      .init(
        id: $0.id,
        languageIDs: $0.languageIDs,
        fileExtensions: $0.fileExtensions,
        priority: $0.priority
      )
    }
  }

  public func supports(uri: URL, languageID: String) -> Bool {
    matchingRegistration(uri: uri, languageID: languageID) != nil
  }

  public func makeService(uri: URL, languageID: String) throws -> TreeSitterSyntaxService? {
    lock.lock()
    let selected = values
      .filter { $0.value.matches(uri: uri, languageID: languageID) }
      .sorted(by: Self.precedes)
      .first?.value
    lock.unlock()
    guard let selected else { return nil }
    return try TreeSitterSyntaxService(
      language: selected.language,
      highlightQuery: selected.queries.highlights,
      foldQuery: selected.queries.folds,
      retainedLanguageLifetime: selected.lifetime
    )
  }

  public static func swiftRegistration(priority: Int = 0) throws -> TreeSitterLanguageRegistration {
    .init(
      id: "tree-sitter-swift",
      languageIDs: ["swift"],
      fileExtensions: ["swift"],
      priority: priority,
      language: Language(language: tree_sitter_swift()),
      queries: .init(
        highlights: try TreeSitterSyntaxService.bundledQuery(named: "swift-highlights"),
        folds: try TreeSitterSyntaxService.bundledQuery(named: "swift-folds")
      )
    )
  }

  private static func precedes(_ lhs: StoredRegistration, _ rhs: StoredRegistration) -> Bool {
    if lhs.value.priority != rhs.value.priority { return lhs.value.priority > rhs.value.priority }
    return lhs.order < rhs.order
  }
}
