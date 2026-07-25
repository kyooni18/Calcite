import Foundation

enum ProjectLanguage: String, CaseIterable, Identifiable {
  case swift = "Swift"
  case python = "Python"
  case rust = "Rust"
  case go = "Go"
  case c = "C"
  case cpp = "C++"
  case javascript = "JavaScript"
  case typescript = "TypeScript"

  var id: String { rawValue }

  var detail: String {
    switch self {
    case .swift: "Swift Package"
    case .python: "Python script"
    case .rust: "Cargo binary"
    case .go: "Go module"
    case .c: "C source and Makefile"
    case .cpp: "C++ source and Makefile"
    case .javascript: "Node.js script"
    case .typescript: "TypeScript starter"
    }
  }
}

enum ProjectTemplateError: LocalizedError {
  case invalidName
  case alreadyExists(URL)

  var errorDescription: String? {
    switch self {
    case .invalidName:
      "Enter a project name without path separators, control characters, or reserved names."
    case .alreadyExists(let url):
      "A project already exists at \(url.path). Choose another name or location."
    }
  }
}

private struct ProjectTemplateIdentity {
  let directoryName: String
  let packageName: String
  let swiftTargetName: String
  let executableName: String

  init(name: String) throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidDirectoryName(trimmed) else { throw ProjectTemplateError.invalidName }

    let slug = Self.portableSlug(from: trimmed)
    directoryName = trimmed
    packageName = slug
    executableName = slug
    swiftTargetName = Self.swiftIdentifier(from: slug)
  }

  private static func isValidDirectoryName(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 120, name != ".", name != ".." else { return false }
    guard name == name.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
    guard !name.hasPrefix("."), !name.hasSuffix("."), !name.hasSuffix(" ") else { return false }
    guard !name.contains("/"), !name.contains("\\"), !name.contains(":") else { return false }
    return !name.unicodeScalars.contains { scalar in
      CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0
    }
  }

  private static func portableSlug(from name: String) -> String {
    let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
    let folded = latin.folding(
      options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    var result = ""
    var previousWasSeparator = false

    for scalar in folded.unicodeScalars {
      let isASCIIAlphaNumeric =
        (scalar.value >= 48 && scalar.value <= 57)
        || (scalar.value >= 65 && scalar.value <= 90)
        || (scalar.value >= 97 && scalar.value <= 122)
      if isASCIIAlphaNumeric {
        result.unicodeScalars.append(scalar)
        previousWasSeparator = false
      } else if !result.isEmpty, !previousWasSeparator {
        result.append("-")
        previousWasSeparator = true
      }
    }

    result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if result.isEmpty { result = "app" }
    if result.first?.isNumber == true { result = "app-\(result)" }
    let shortened = String(result.prefix(64))
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return shortened.isEmpty ? "app" : shortened
  }

  private static func swiftIdentifier(from slug: String) -> String {
    let words = slug.split(separator: "-")
    var identifier = words.map { word in
      guard let first = word.first else { return "" }
      return String(first).uppercased() + word.dropFirst()
    }.joined()
    if identifier.isEmpty { identifier = "App" }
    if identifier.first?.isNumber == true { identifier = "App\(identifier)" }
    return identifier
  }
}

enum ProjectTemplate {
  static func create(named name: String, language: ProjectLanguage, in parent: URL) throws -> URL {
    let identity = try ProjectTemplateIdentity(name: name)
    let root = parent.appendingPathComponent(identity.directoryName, isDirectory: true)
      .standardizedFileURL

    let parentPath = parent.standardizedFileURL.path
    let rootParentPath = root.deletingLastPathComponent().standardizedFileURL.path
    guard rootParentPath == parentPath else { throw ProjectTemplateError.invalidName }
    guard !FileManager.default.fileExists(atPath: root.path) else {
      throw ProjectTemplateError.alreadyExists(root)
    }

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    do {
      for (path, contents) in files(for: language, identity: identity) {
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { throw ProjectTemplateError.invalidName }
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
      }
      return root
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  private static func files(
    for language: ProjectLanguage,
    identity: ProjectTemplateIdentity
  ) -> [(String, String)] {
    let package = identity.packageName
    let target = identity.swiftTargetName
    let executable = identity.executableName

    switch language {
    case .swift:
      return [
        (
          "Package.swift",
          "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"\(package)\", targets: [.executableTarget(name: \"\(target)\")])\n"
        ),
        ("Sources/\(target)/main.swift", "print(\"Hello, world!\")\n"),
      ]
    case .python:
      return [
        (
          "main.py",
          "def main():\n    print(\"Hello, world!\")\n\nif __name__ == \"__main__\":\n    main()\n"
        )
      ]
    case .rust:
      return [
        (
          "Cargo.toml",
          "[package]\nname = \"\(package)\"\nversion = \"0.1.0\"\nedition = \"2024\"\n"
        ),
        ("src/main.rs", "fn main() {\n    println!(\"Hello, world!\");\n}\n"),
      ]
    case .go:
      return [
        ("go.mod", "module example.com/\(package)\n\ngo 1.24\n"),
        (
          "main.go",
          "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"Hello, world!\")\n}\n"
        ),
      ]
    case .c:
      return [
        (
          "main.c",
          "#include <stdio.h>\n\nint main(void) {\n  puts(\"Hello, world!\");\n  return 0;\n}\n"
        ),
        ("Makefile", "all:\n\tcc main.c -o \(executable)\n"),
      ]
    case .cpp:
      return [
        (
          "main.cpp",
          "#include <iostream>\n\nint main() {\n  std::cout << \"Hello, world!\\n\";\n}\n"
        ),
        ("Makefile", "all:\n\tc++ main.cpp -o \(executable)\n"),
      ]
    case .javascript:
      return [
        (
          "package.json",
          "{\n  \"name\": \"\(package)\",\n  \"private\": true,\n  \"type\": \"module\"\n}\n"
        ),
        ("index.js", "console.log(\"Hello, world!\");\n"),
      ]
    case .typescript:
      return [
        (
          "package.json",
          "{\n  \"name\": \"\(package)\",\n  \"private\": true,\n  \"scripts\": { \"start\": \"tsx src/index.ts\" }\n}\n"
        ),
        ("src/index.ts", "console.log(\"Hello, world!\");\n"),
      ]
    }
  }
}
