import EditorServices
import Foundation

#if os(macOS) || os(Linux)
func makeWorkspaceBackend(workspaceURL: URL) async throws -> MultiLanguageEditorBackend {
  let grammars = try TreeSitterLanguageRegistry(registrations: [
    TreeSitterLanguageRegistry.swiftRegistration()
  ])

  // Desktop option: load any grammar that exports the standard Tree-sitter C ABI.
  // The dynamic library and query files are supplied by your application.
  let pythonLibrary = try DynamicTreeSitterLanguage(
    libraryURL: workspaceURL.appendingPathComponent("Grammars/libtree-sitter-python.dylib"),
    symbol: "tree_sitter_python"
  )
  try grammars.register(
    pythonLibrary.registration(
      id: "tree-sitter-python",
      languageIDs: ["python"],
      fileExtensions: ["py", "pyi"],
      queries: try .load(
        highlightsURL: workspaceURL.appendingPathComponent("Queries/python/highlights.scm"),
        foldsURL: workspaceURL.appendingPathComponent("Queries/python/folds.scm")
      )
    )
  )

  return try await .makeMultiLanguage(
    configuration: .init(
      workspaceURL: workspaceURL,
      languageServers: [
        .swift(),
        .pyright(),
        .clangd(arguments: ["--background-index"]),
        .rustAnalyzer(),
        .gopls(),
        .typescript(),
        .eslint(),
      ],
      treeSitterRegistry: grammars,
      sourceWorkspaceMonitoringInterval: .seconds(1)
    )
  )
}
#endif

// Static grammar packages work on every supported platform:
//
// import SwiftTreeSitter
// import TreeSitterPython
//
// let python = TreeSitterLanguageRegistration(
//   id: "tree-sitter-python",
//   languageIDs: ["python"],
//   fileExtensions: ["py", "pyi"],
//   language: Language(language: tree_sitter_python()),
//   queries: try .load(highlightsURL: highlights, foldsURL: folds)
// )
