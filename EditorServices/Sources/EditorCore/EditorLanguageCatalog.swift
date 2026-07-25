import Foundation

/// Describes a source language independently of any specific parser or language server.
public struct EditorLanguageDefinition: Hashable, Codable, Sendable {
  public var id: String
  public var aliases: Set<String>
  public var fileExtensions: Set<String>
  public var fileNames: Set<String>

  public init(
    id: String,
    aliases: Set<String> = [],
    fileExtensions: Set<String> = [],
    fileNames: Set<String> = []
  ) {
    self.id = Self.normalize(id)
    self.aliases = Set(aliases.map(Self.normalize).filter { !$0.isEmpty })
    self.fileExtensions = Set(
      fileExtensions.map {
        Self.normalize($0).trimmingCharacters(in: CharacterSet(charactersIn: "."))
      }.filter { !$0.isEmpty }
    )
    self.fileNames = Set(fileNames.map { $0.lowercased() }.filter { !$0.isEmpty })
  }

  public func recognizes(languageID: String) -> Bool {
    let value = Self.normalize(languageID)
    return value == id || aliases.contains(value)
  }

  private static func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

/// Maps filenames, extensions, and aliases to canonical Language Server Protocol language IDs.
public struct EditorLanguageCatalog: Hashable, Codable, Sendable {
  public var definitions: [EditorLanguageDefinition]
  public var fallbackLanguageID: String

  public init(
    definitions: [EditorLanguageDefinition],
    fallbackLanguageID: String = "plaintext"
  ) {
    self.definitions = definitions
    self.fallbackLanguageID = fallbackLanguageID
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  public func canonicalLanguageID(for languageID: String) -> String {
    let normalized = languageID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return definitions.first(where: { $0.recognizes(languageID: normalized) })?.id
      ?? (normalized.isEmpty ? fallbackLanguageID : normalized)
  }

  public func languageID(for url: URL) -> String {
    languageID(forPath: url.path)
  }

  public func languageID(forPath path: String) -> String {
    let fileName = (path as NSString).lastPathComponent.lowercased()
    if let definition = definitions.first(where: { $0.fileNames.contains(fileName) }) {
      return definition.id
    }

    let fileExtension = (path as NSString).pathExtension.lowercased()
    if let definition = definitions.first(where: { $0.fileExtensions.contains(fileExtension) }) {
      return definition.id
    }
    return fallbackLanguageID
  }

  /// A broad catalog of language IDs commonly used by LSP implementations and Tree-sitter grammars.
  public static let standard = EditorLanguageCatalog(definitions: [
    .init(id: "swift", fileExtensions: ["swift", "swiftinterface"]),
    .init(id: "c", fileExtensions: ["c", "h", "inc", "modulemap"]),
    .init(id: "cpp", aliases: ["c++"], fileExtensions: ["cc", "cpp", "cxx", "hpp", "hh", "hxx", "ipp", "tcc"]),
    .init(id: "objective-c", aliases: ["objectivec", "objc"], fileExtensions: ["m"]),
    .init(id: "objective-cpp", aliases: ["objective-c++", "objcpp"], fileExtensions: ["mm"]),
    .init(id: "python", aliases: ["py"], fileExtensions: ["py", "pyi", "pyw"]),
    .init(id: "rust", fileExtensions: ["rs"]),
    .init(id: "go", aliases: ["golang"], fileExtensions: ["go"]),
    .init(id: "java", fileExtensions: ["java"]),
    .init(id: "kotlin", fileExtensions: ["kt", "kts"]),
    .init(id: "javascript", aliases: ["js"], fileExtensions: ["js", "mjs", "cjs"]),
    .init(id: "javascriptreact", aliases: ["javascript-react", "jsx"], fileExtensions: ["jsx"]),
    .init(id: "typescript", aliases: ["ts"], fileExtensions: ["ts", "mts", "cts"]),
    .init(id: "typescriptreact", aliases: ["typescript-react", "tsx"], fileExtensions: ["tsx"]),
    .init(id: "csharp", aliases: ["c#", "cs"], fileExtensions: ["cs"]),
    .init(id: "fsharp", aliases: ["f#", "fs"], fileExtensions: ["fs", "fsx", "fsi"]),
    .init(id: "ruby", fileExtensions: ["rb", "rake"], fileNames: ["gemfile", "rakefile"]),
    .init(id: "php", fileExtensions: ["php", "phtml"]),
    .init(id: "lua", fileExtensions: ["lua"]),
    .init(id: "shellscript", aliases: ["shell", "bash", "sh", "zsh"], fileExtensions: ["sh", "bash", "zsh", "fish"], fileNames: [".bashrc", ".zshrc"]),
    .init(id: "json", fileExtensions: ["json"]),
    .init(id: "jsonc", fileExtensions: ["jsonc"]),
    .init(id: "yaml", aliases: ["yml"], fileExtensions: ["yaml", "yml"]),
    .init(id: "toml", fileExtensions: ["toml"]),
    .init(id: "xml", fileExtensions: ["xml", "xsd", "svg"]),
    .init(id: "html", fileExtensions: ["html", "htm"]),
    .init(id: "css", fileExtensions: ["css"]),
    .init(id: "scss", fileExtensions: ["scss"]),
    .init(id: "less", fileExtensions: ["less"]),
    .init(id: "markdown", aliases: ["md"], fileExtensions: ["md", "markdown", "mdx"]),
    .init(id: "sql", fileExtensions: ["sql"]),
    .init(id: "cmake", fileExtensions: ["cmake"], fileNames: ["cmakelists.txt"]),
    .init(id: "makefile", aliases: ["make"], fileNames: ["makefile", "gnumakefile"]),
    .init(id: "dockerfile", aliases: ["docker"], fileNames: ["dockerfile"]),
    .init(id: "haskell", fileExtensions: ["hs", "lhs"]),
    .init(id: "ocaml", fileExtensions: ["ml", "mli"]),
    .init(id: "elixir", fileExtensions: ["ex", "exs"]),
    .init(id: "erlang", fileExtensions: ["erl", "hrl"]),
    .init(id: "dart", fileExtensions: ["dart"]),
    .init(id: "r", fileExtensions: ["r", "rmd"]),
    .init(id: "julia", fileExtensions: ["jl"]),
    .init(id: "zig", fileExtensions: ["zig"]),
    .init(id: "nim", fileExtensions: ["nim", "nims"]),
    .init(id: "scala", fileExtensions: ["scala", "sc"]),
    .init(id: "clojure", fileExtensions: ["clj", "cljs", "cljc", "edn"]),
    .init(id: "terraform", aliases: ["hcl"], fileExtensions: ["tf", "tfvars", "hcl"]),
    .init(id: "protobuf", aliases: ["proto"], fileExtensions: ["proto"]),
    .init(id: "graphql", fileExtensions: ["graphql", "gql"]),
    .init(id: "vue", fileExtensions: ["vue"]),
    .init(id: "svelte", fileExtensions: ["svelte"]),
    .init(id: "metal", fileExtensions: ["metal"]),
    .init(id: "plaintext", aliases: ["text", "txt"], fileExtensions: ["txt"]),
  ])
}
