import Foundation

/// The document information available when selecting a syntax provider.
public struct EditorSyntaxServiceContext: Hashable, Sendable {
  public var uri: URL
  public var languageID: String

  public init(uri: URL, languageID: String) {
    self.uri = uri
    self.languageID = languageID
  }
}
