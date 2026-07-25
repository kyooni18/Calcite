import EditorCore
import Foundation

/// Selects the languages for which editor services should be prepared.
public enum EditorLanguageSelection: Hashable, Codable, Sendable {
  /// Inspect the opened project and enable only languages supported by its file tree.
  case automatic
  /// Inspect the project, force additional languages on, and suppress explicitly excluded languages.
  case automaticWithOverrides(included: Set<EditorLanguage>, excluded: Set<EditorLanguage>)
  /// Do not inspect the project. Use exactly the supplied languages.
  case manual(Set<EditorLanguage>)

  public static func automatic(
    including included: Set<EditorLanguage> = [],
    excluding excluded: Set<EditorLanguage> = []
  ) -> Self {
    if included.isEmpty && excluded.isEmpty { return .automatic }
    return .automaticWithOverrides(included: included, excluded: excluded)
  }

  public var isAutomatic: Bool {
    switch self {
    case .automatic, .automaticWithOverrides: return true
    case .manual: return false
    }
  }

  public var manualLanguages: Set<EditorLanguage>? {
    guard case .manual(let languages) = self else { return nil }
    return languages
  }
}

/// Limits and exclusions used while inspecting an opened project's file tree.
public struct EditorProjectInspectionConfiguration: Hashable, Codable, Sendable {
  public var excludedDirectoryNames: Set<String>
  public var excludedRelativePaths: Set<String>
  public var includeHiddenItems: Bool
  public var followSymbolicLinks: Bool
  public var inspectProjectMarkers: Bool
  public var maximumFileCount: Int
  public var maximumEvidencePathsPerLanguage: Int
  public var fallbackLanguages: Set<EditorLanguage>

  public init(
    excludedDirectoryNames: Set<String> = [
      ".git", ".hg", ".svn", ".build", ".swiftpm", ".gradle", ".idea", ".vscode",
      ".next", ".nuxt", ".svelte-kit", ".dart_tool", ".terraform", ".venv", "venv",
      "__pycache__", "DerivedData", "Pods", "Carthage", "node_modules", "Vendor",
      "vendor", "target", "dist", "build", "out", "coverage",
    ],
    excludedRelativePaths: Set<String> = [],
    includeHiddenItems: Bool = false,
    followSymbolicLinks: Bool = false,
    inspectProjectMarkers: Bool = true,
    maximumFileCount: Int = 100_000,
    maximumEvidencePathsPerLanguage: Int = 8,
    fallbackLanguages: Set<EditorLanguage> = []
  ) {
    self.excludedDirectoryNames = excludedDirectoryNames
    self.excludedRelativePaths = Set(excludedRelativePaths.map(Self.normalizeRelativePath))
    self.includeHiddenItems = includeHiddenItems
    self.followSymbolicLinks = followSymbolicLinks
    self.inspectProjectMarkers = inspectProjectMarkers
    self.maximumFileCount = max(1, maximumFileCount)
    self.maximumEvidencePathsPerLanguage = max(1, maximumEvidencePathsPerLanguage)
    self.fallbackLanguages = fallbackLanguages
  }

  private static func normalizeRelativePath(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "/")
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}

public enum EditorProjectLanguageEvidenceKind: String, Hashable, Codable, Sendable {
  case sourceFile
  case projectMarker
}

/// Evidence explaining why a language was selected for an opened project.
public struct EditorProjectLanguageEvidence: Hashable, Codable, Sendable, Identifiable {
  public var language: EditorLanguage
  public var sourceFileCount: Int
  public var projectMarkers: Set<String>
  public var samplePaths: [String]

  public init(
    language: EditorLanguage,
    sourceFileCount: Int = 0,
    projectMarkers: Set<String> = [],
    samplePaths: [String] = []
  ) {
    self.language = language
    self.sourceFileCount = max(0, sourceFileCount)
    self.projectMarkers = projectMarkers
    self.samplePaths = samplePaths
  }

  public var id: EditorLanguage { language }
  public var wasDetectedFromSourceFiles: Bool { sourceFileCount > 0 }
  public var wasDetectedFromProjectMarkers: Bool { !projectMarkers.isEmpty }
}

/// Result of inspecting an opened project's file tree.
public struct EditorProjectInspectionReport: Hashable, Codable, Sendable {
  public var workspaceURL: URL
  public var languages: Set<EditorLanguage>
  public var evidence: [EditorProjectLanguageEvidence]
  public var scannedFileCount: Int
  public var skippedDirectoryCount: Int
  public var wasTruncated: Bool

  public init(
    workspaceURL: URL,
    languages: Set<EditorLanguage>,
    evidence: [EditorProjectLanguageEvidence],
    scannedFileCount: Int,
    skippedDirectoryCount: Int,
    wasTruncated: Bool
  ) {
    self.workspaceURL = workspaceURL
    self.languages = languages
    self.evidence = evidence
    self.scannedFileCount = max(0, scannedFileCount)
    self.skippedDirectoryCount = max(0, skippedDirectoryCount)
    self.wasTruncated = wasTruncated
  }

  public func evidence(for language: EditorLanguage) -> EditorProjectLanguageEvidence? {
    evidence.first { $0.language == language }
  }
}

public enum EditorProjectInspectionError: Error, Hashable, Sendable {
  case workspaceDoesNotExist(URL)
  case workspaceIsNotDirectory(URL)
  case enumerationFailed(URL, String)
}

extension EditorProjectInspectionError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .workspaceDoesNotExist(let url):
      return "The project directory does not exist: \(url.path)"
    case .workspaceIsNotDirectory(let url):
      return "The opened project URL is not a directory: \(url.path)"
    case .enumerationFailed(let url, let reason):
      return "The project file tree could not be inspected at \(url.path): \(reason)"
    }
  }
}

/// Detects project languages without reading source contents or launching external services.
public enum EditorProjectInspector {
  public static func inspect(
    workspaceURL: URL,
    languageCatalog: EditorLanguageCatalog = .standard,
    configuration: EditorProjectInspectionConfiguration = .init()
  ) async throws -> EditorProjectInspectionReport {
    try await Task.detached(priority: .utility) {
      try inspectSynchronously(
        workspaceURL: workspaceURL,
        languageCatalog: languageCatalog,
        configuration: configuration
      )
    }.value
  }

  public static func inspectSynchronously(
    workspaceURL: URL,
    languageCatalog: EditorLanguageCatalog = .standard,
    configuration: EditorProjectInspectionConfiguration = .init()
  ) throws -> EditorProjectInspectionReport {
    let root = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
      throw EditorProjectInspectionError.workspaceDoesNotExist(root)
    }
    guard isDirectory.boolValue else {
      throw EditorProjectInspectionError.workspaceIsNotDirectory(root)
    }

    struct MutableEvidence {
      var sourceFileCount = 0
      var markers = Set<String>()
      var samplePaths: [String] = []
    }

    var evidence: [EditorLanguage: MutableEvidence] = [:]
    var scannedFileCount = 0
    var skippedDirectoryCount = 0
    var wasTruncated = false
    var pendingDirectories = [root]
    var visitedDirectories = Set<String>()

    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"

    func isContainedInWorkspace(_ url: URL) -> Bool {
      let path = url.standardizedFileURL.resolvingSymlinksInPath().path
      return path == root.path || path.hasPrefix(rootPath)
    }

    func relativePath(for url: URL) -> String {
      let path = url.standardizedFileURL.path
      guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
      return String(path.dropFirst(rootPath.count)).replacingOccurrences(of: "\\", with: "/")
    }

    func addSource(_ language: EditorLanguage, path: String) {
      var item = evidence[language, default: MutableEvidence()]
      item.sourceFileCount += 1
      if item.samplePaths.count < configuration.maximumEvidencePathsPerLanguage,
        !item.samplePaths.contains(path)
      {
        item.samplePaths.append(path)
      }
      evidence[language] = item
    }

    func addMarker(_ language: EditorLanguage, marker: String, path: String) {
      var item = evidence[language, default: MutableEvidence()]
      item.markers.insert(marker)
      if item.samplePaths.count < configuration.maximumEvidencePathsPerLanguage,
        !item.samplePaths.contains(path)
      {
        item.samplePaths.append(path)
      }
      evidence[language] = item
    }

    while let directory = pendingDirectories.popLast() {
      let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath().path
      guard visitedDirectories.insert(resolvedDirectory).inserted else { continue }

      let contents: [URL]
      do {
        contents = try FileManager.default.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
          options: configuration.includeHiddenItems ? [] : [.skipsHiddenFiles]
        )
      } catch {
        if directory == root {
          throw EditorProjectInspectionError.enumerationFailed(root, error.localizedDescription)
        }
        skippedDirectoryCount += 1
        continue
      }

      for value in contents {
        let relative = relativePath(for: value)
        let values: URLResourceValues
        do {
          values = try value.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
          ])
        } catch {
          continue
        }

        let isSymbolicLink = values.isSymbolicLink == true
        let effectiveValues: URLResourceValues
        if isSymbolicLink && configuration.followSymbolicLinks {
          let resolved = value.standardizedFileURL.resolvingSymlinksInPath()
          guard isContainedInWorkspace(resolved) else {
            skippedDirectoryCount += 1
            continue
          }
          do {
            effectiveValues = try resolved.resourceValues(forKeys: [
              .isDirectoryKey, .isRegularFileKey,
            ])
          } catch {
            continue
          }
        } else {
          effectiveValues = values
        }

        if effectiveValues.isDirectory == true {
          let name = value.lastPathComponent
          let normalized = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          let hidden = name.hasPrefix(".") && !configuration.includeHiddenItems
          let explicitlyExcluded = configuration.excludedRelativePaths.contains(normalized)
          let excluded =
            hidden || explicitlyExcluded
            || configuration.excludedDirectoryNames.contains(name)
          if excluded || (isSymbolicLink && !configuration.followSymbolicLinks) {
            skippedDirectoryCount += 1
          } else {
            pendingDirectories.append(value)
          }
          continue
        }

        if isSymbolicLink && !configuration.followSymbolicLinks { continue }
        guard effectiveValues.isRegularFile == true else { continue }

        if scannedFileCount >= configuration.maximumFileCount {
          wasTruncated = true
          pendingDirectories.removeAll()
          break
        }
        scannedFileCount += 1

        let languageID = languageCatalog.languageID(forPath: relative)
        if let language = EditorLanguage(languageID: languageID) {
          addSource(language, path: relative)
        }

        guard configuration.inspectProjectMarkers else { continue }
        for marker in ProjectMarker.languages(forRelativePath: relative) {
          addMarker(marker.language, marker: marker.name, path: relative)
        }
      }
    }

    var languages = Set(evidence.keys)
    if languages.isEmpty { languages = configuration.fallbackLanguages }
    for language in configuration.fallbackLanguages where evidence[language] == nil {
      evidence[language] = MutableEvidence()
    }

    let values = evidence.map { language, item in
      EditorProjectLanguageEvidence(
        language: language,
        sourceFileCount: item.sourceFileCount,
        projectMarkers: item.markers,
        samplePaths: item.samplePaths.sorted()
      )
    }.sorted { $0.language.rawValue < $1.language.rawValue }

    return .init(
      workspaceURL: root,
      languages: languages,
      evidence: values,
      scannedFileCount: min(scannedFileCount, configuration.maximumFileCount),
      skippedDirectoryCount: skippedDirectoryCount,
      wasTruncated: wasTruncated
    )
  }
}

extension EditorLanguage {
  public var displayName: String {
    switch self {
    case .swift: return "Swift"
    case .c: return "C"
    case .cpp: return "C++"
    case .objectiveC: return "Objective-C"
    case .objectiveCPP: return "Objective-C++"
    case .python: return "Python"
    case .rust: return "Rust"
    case .go: return "Go"
    case .java: return "Java"
    case .kotlin: return "Kotlin"
    case .javascript: return "JavaScript"
    case .typescript: return "TypeScript"
    case .html: return "HTML"
    case .css: return "CSS"
    case .json: return "JSON"
    case .yaml: return "YAML"
    case .shellscript: return "Shell"
    case .lua: return "Lua"
    case .ruby: return "Ruby"
    case .php: return "PHP"
    case .csharp: return "C#"
    case .fsharp: return "F#"
    case .haskell: return "Haskell"
    case .ocaml: return "OCaml"
    case .scala: return "Scala"
    case .clojure: return "Clojure"
    case .elixir: return "Elixir"
    case .erlang: return "Erlang"
    case .dart: return "Dart"
    case .nim: return "Nim"
    case .markdown: return "Markdown"
    case .xml: return "XML"
    case .sql: return "SQL"
    case .dockerfile: return "Dockerfile"
    case .protobuf: return "Protocol Buffers"
    case .graphql: return "GraphQL"
    case .vue: return "Vue"
    case .svelte: return "Svelte"
    case .zig: return "Zig"
    case .terraform: return "Terraform"
    }
  }

  /// Maps canonical and aliased LSP language IDs to the high-level language enum.
  public init?(languageID: String) {
    switch EditorLanguageCatalog.standard.canonicalLanguageID(for: languageID) {
    case "swift": self = .swift
    case "c": self = .c
    case "cpp": self = .cpp
    case "objective-c": self = .objectiveC
    case "objective-cpp": self = .objectiveCPP
    case "python": self = .python
    case "rust": self = .rust
    case "go": self = .go
    case "java": self = .java
    case "kotlin": self = .kotlin
    case "javascript", "javascriptreact": self = .javascript
    case "typescript", "typescriptreact": self = .typescript
    case "html": self = .html
    case "css", "scss", "less": self = .css
    case "json", "jsonc": self = .json
    case "yaml": self = .yaml
    case "shellscript": self = .shellscript
    case "lua": self = .lua
    case "ruby": self = .ruby
    case "php": self = .php
    case "csharp": self = .csharp
    case "fsharp": self = .fsharp
    case "haskell": self = .haskell
    case "ocaml": self = .ocaml
    case "scala": self = .scala
    case "clojure": self = .clojure
    case "elixir": self = .elixir
    case "erlang": self = .erlang
    case "dart": self = .dart
    case "nim": self = .nim
    case "markdown": self = .markdown
    case "xml": self = .xml
    case "sql": self = .sql
    case "dockerfile": self = .dockerfile
    case "protobuf": self = .protobuf
    case "graphql": self = .graphql
    case "vue": self = .vue
    case "svelte": self = .svelte
    case "zig": self = .zig
    case "terraform": self = .terraform
    default: return nil
    }
  }
}

private enum ProjectMarker {
  struct Match {
    var language: EditorLanguage
    var name: String
  }

  static func languages(forRelativePath relativePath: String) -> [Match] {
    let path = relativePath.replacingOccurrences(of: "\\", with: "/")
    let name = (path as NSString).lastPathComponent.lowercased()
    let lowerPath = path.lowercased()

    switch name {
    case "package.swift": return [.init(language: .swift, name: "Package.swift")]
    case "cargo.toml": return [.init(language: .rust, name: "Cargo.toml")]
    case "rust-project.json": return [.init(language: .rust, name: "rust-project.json")]
    case "go.mod", "go.work": return [.init(language: .go, name: name)]
    case "pom.xml": return [.init(language: .java, name: "pom.xml")]
    case "build.gradle", "settings.gradle":
      return [.init(language: .java, name: name)]
    case "build.gradle.kts", "settings.gradle.kts":
      return [
        .init(language: .kotlin, name: name),
        .init(language: .java, name: name),
      ]
    case "package.json": return [.init(language: .javascript, name: "package.json")]
    case "deno.json", "deno.jsonc":
      return [
        .init(language: .typescript, name: name),
        .init(language: .javascript, name: name),
      ]
    case "pyproject.toml", "requirements.txt", "pipfile", "setup.py":
      return [.init(language: .python, name: name)]
    case "gemfile": return [.init(language: .ruby, name: "Gemfile")]
    case "composer.json": return [.init(language: .php, name: "composer.json")]
    case "mix.exs": return [.init(language: .elixir, name: "mix.exs")]
    case "rebar.config", "rebar.lock": return [.init(language: .erlang, name: name)]
    case "pubspec.yaml": return [.init(language: .dart, name: "pubspec.yaml")]
    case "build.zig", "build.zig.zon": return [.init(language: .zig, name: name)]
    case "project.clj", "deps.edn": return [.init(language: .clojure, name: name)]
    case "build.sbt": return [.init(language: .scala, name: "build.sbt")]
    case "dune-project", "dune-workspace": return [.init(language: .ocaml, name: name)]
    case "stack.yaml", "cabal.project": return [.init(language: .haskell, name: name)]
    case "cmakelists.txt":
      return [
        .init(language: .c, name: "CMakeLists.txt"),
        .init(language: .cpp, name: "CMakeLists.txt"),
      ]
    default:
      if name.hasPrefix("tsconfig") && name.hasSuffix(".json") {
        return [.init(language: .typescript, name: name)]
      }
      if name.hasSuffix(".csproj") || name.hasSuffix(".sln") {
        return [.init(language: .csharp, name: name)]
      }
      if name.hasSuffix(".fsproj") {
        return [.init(language: .fsharp, name: name)]
      }
      if name.hasSuffix(".cabal") {
        return [.init(language: .haskell, name: name)]
      }
      if lowerPath.hasSuffix("/.xcodeproj/project.pbxproj") {
        return [.init(language: .swift, name: "Xcode project")]
      }
      return []
    }
  }
}

extension EditorLanguage: Identifiable {
  public var id: String { rawValue }
}
