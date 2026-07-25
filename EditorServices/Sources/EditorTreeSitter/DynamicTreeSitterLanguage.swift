import Foundation
import SwiftTreeSitter

#if os(macOS)
  import Darwin
#elseif os(Linux)
  import Glibc
#endif

#if os(macOS) || os(Linux)
public enum DynamicTreeSitterLanguageError: Error, Equatable, Sendable {
  case libraryNotFound(String)
  case symbolNotFound(String)
  case languageFunctionReturnedNull(String)
}

extension DynamicTreeSitterLanguageError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .libraryNotFound(let detail):
      return "The Tree-sitter grammar library could not be loaded: \(detail)"
    case .symbolNotFound(let symbol):
      return "The Tree-sitter grammar does not export the expected symbol: \(symbol)."
    case .languageFunctionReturnedNull(let symbol):
      return "The Tree-sitter language function returned null: \(symbol)."
    }
  }

  public var recoverySuggestion: String? {
    "Verify the library architecture, linked Tree-sitter ABI, and exported tree_sitter_<language> symbol."
  }
}

/// Loads any Tree-sitter grammar that exports a standard `tree_sitter_<language>` C function.
///
/// This is intended for desktop editors that distribute grammar dynamic libraries separately.
/// Mobile applications should link grammar packages statically and register their `Language`
/// values with ``TreeSitterLanguageRegistry``.
public final class DynamicTreeSitterLanguage: TreeSitterLanguageLifetime, @unchecked Sendable {
  public let libraryURL: URL
  public let symbol: String
  public let language: Language

  private let handle: UnsafeMutableRawPointer

  public init(libraryURL: URL, symbol: String) throws {
    self.libraryURL = libraryURL
    self.symbol = symbol
    guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
      let message = dlerror().map { String(cString: $0) } ?? libraryURL.path
      throw DynamicTreeSitterLanguageError.libraryNotFound(message)
    }
    guard let rawFunction = dlsym(handle, symbol) else {
      dlclose(handle)
      throw DynamicTreeSitterLanguageError.symbolNotFound(symbol)
    }
    typealias LanguageFunction = @convention(c) () -> OpaquePointer?
    let function = unsafeBitCast(rawFunction, to: LanguageFunction.self)
    guard let pointer = function() else {
      dlclose(handle)
      throw DynamicTreeSitterLanguageError.languageFunctionReturnedNull(symbol)
    }
    self.handle = handle
    self.language = Language(language: pointer)
  }

  deinit { dlclose(handle) }

  public func registration(
    id: String,
    languageIDs: Set<String>,
    fileExtensions: Set<String> = [],
    priority: Int = 0,
    queries: TreeSitterQuerySet = .init()
  ) -> TreeSitterLanguageRegistration {
    .init(
      id: id,
      languageIDs: languageIDs,
      fileExtensions: fileExtensions,
      priority: priority,
      language: language,
      queries: queries,
      lifetime: self
    )
  }
}
#endif
