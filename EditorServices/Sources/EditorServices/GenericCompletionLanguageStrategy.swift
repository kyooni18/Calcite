import EditorCore
import Foundation

struct GenericCompletionLanguageStrategy: CompletionLanguageStrategy {
  let languageIDs: Set<String> = [
    "generic", "ruby", "shell", "haskell", "sql", "yaml", "toml", "json", "css",
    "html", "markdown",
  ]

  func initializerContext(in text: String, caretUTF16Offset: Int) -> CompletionInitializerContext? {
    nil
  }

  func visibleBindings(
    in text: String,
    caretUTF16Offset: Int,
    lexicalTypes: [String: String]
  ) -> [CompletionVisibleBinding] {
    CompletionSyntaxUtilities.sortedBindings(
      lexicalTypes.reduce(into: [String: CompletionVisibleBinding]()) { result, item in
        result[item.key.lowercased()] = CompletionVisibleBinding(
          name: item.key,
          typeName: canonicalType(item.value)
        )
      }
    )
  }

  func canonicalType(_ raw: String?) -> String? {
    CompletionSyntaxUtilities.canonicalNominalType(raw)
  }

  func defaultExpression(for rawType: String?) -> String { "" }

  func initializerInsertion(memberName: String, defaultExpression: String?) -> String {
    memberName
  }
}
