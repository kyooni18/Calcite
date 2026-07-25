import EditorServices
import Foundation

/// Source-only composition example. Supply concrete services from your application.
func makeModularBackend(
  workspaceURL: URL,
  swiftService: any LanguageIntelligenceProviding,
  linterService: any LanguageIntelligenceProviding
) async throws -> SwiftEditorBackend {
  try await EditorBackendBuilder(
    workspaceURL: workspaceURL,
    syntaxFactory: { try TreeSitterSyntaxService.swift() }
  )
  .addingLanguageService(
    .init(
      id: "swift-primary",
      service: swiftService,
      role: .primary,
      priority: 100,
      selector: .init(languageIDs: ["swift"], fileExtensions: ["swift"])
    )
  )
  .addingLanguageService(
    .init(
      id: "swift-linter",
      service: linterService,
      role: .supplemental,
      selector: .init(fileExtensions: ["swift"])
    )
  )
  .build()
}

func installMarkdownPlugin(
  in backend: SwiftEditorBackend,
  service: any LanguageIntelligenceProviding
) async throws {
  guard let router = backend.languageServiceRouter else { return }
  try await router.register(
    .init(
      id: "markdown",
      service: service,
      selector: .init(languageIDs: ["markdown"], fileExtensions: ["md", "markdown"])
    )
  )
}
