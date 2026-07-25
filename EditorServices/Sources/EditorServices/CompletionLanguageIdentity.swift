import EditorCore
import Foundation

/// Stable, language-aware identities used while merging fallback completion candidates.
///
/// Source languages are case-sensitive unless explicitly listed otherwise. Callable
/// candidates include their insertion signature so overloads are not collapsed into a
/// single item, while repeated declarations of the same signature still coalesce.
enum CompletionLanguageIdentity {
  private static let caseInsensitiveLanguages: Set<String> = [
    "html", "xml", "sql",
  ]

  static func isCaseSensitive(_ languageID: String) -> Bool {
    !caseInsensitiveLanguages.contains(
      CompletionStructuralAnalysis.normalizedLanguage(languageID)
    )
  }

  static func normalizedIdentifier(_ value: String, languageID: String) -> String {
    isCaseSensitive(languageID) ? value : value.lowercased()
  }

  static func projectSymbolKey(
    owner: String?,
    name: String,
    kind: CompletionKind,
    isStatic: Bool,
    insertion: String,
    languageID: String,
    declarationSignature: String? = nil
  ) -> String {
    let normalizedOwner = normalizedIdentifier(owner ?? "", languageID: languageID)
    let normalizedName = normalizedIdentifier(name, languageID: languageID)
    let signature =
      isCallable(kind)
      ? normalizedSignature(declarationSignature ?? insertion, languageID: languageID) : ""
    return "\(normalizedOwner)|\(normalizedName)|\(kind.rawValue)|\(isStatic)|\(signature)"
  }

  static func candidateKey(
    name: String,
    insertion: String,
    kind: CompletionKind,
    languageID: String,
    declarationSignature: String? = nil
  ) -> String {
    let normalizedName = normalizedIdentifier(name, languageID: languageID)
    let family = kindFamily(kind)
    let signature =
      isCallable(kind)
      ? normalizedSignature(declarationSignature ?? insertion, languageID: languageID) : ""
    return "\(normalizedName)|\(family)|\(signature)"
  }

  static func displaySignature(name: String, insertion: String) -> String? {
    guard isCallInsertion(insertion, name: name) else { return nil }
    var output = insertion
    output = output.replacingOccurrences(
      of: #"\$\{\d+:([^}]*)\}"#,
      with: "$1",
      options: .regularExpression
    )
    output = output.replacingOccurrences(
      of: #"\$\{\d+\}"#,
      with: "_",
      options: .regularExpression
    )
    output = output.replacingOccurrences(
      of: #"\$\d+"#,
      with: "_",
      options: .regularExpression
    )
    return output
  }

  static func isCallable(_ kind: CompletionKind) -> Bool {
    switch kind {
    case .method, .function, .constructor: return true
    default: return false
    }
  }

  private static func kindFamily(_ kind: CompletionKind) -> String {
    switch kind {
    case .method, .function, .constructor: return "callable"
    case .field, .property, .variable, .constant, .value: return "value"
    case .class, .interface, .enum, .struct, .typeParameter: return "type"
    default: return String(kind.rawValue)
    }
  }

  private static func normalizedSignature(_ insertion: String, languageID: String) -> String {
    let compact =
      insertion
      .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"\$\{\d+:"#, with: "${:", options: .regularExpression)
      .replacingOccurrences(of: #"\$\d+"#, with: "$_", options: .regularExpression)
    return isCaseSensitive(languageID) ? compact : compact.lowercased()
  }

  private static func isCallInsertion(_ insertion: String, name: String) -> Bool {
    insertion.hasPrefix(name + "(") || insertion.hasPrefix(name + " {")
  }
}
