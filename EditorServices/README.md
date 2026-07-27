# EditorServices

`EditorServices` is the local Swift package behind Calcite's editor backend. It is vendored for offline builds and provides:

- UTF-16-safe document storage and transactional edits
- Project-wide source storage, file operations, monitoring, search, and archive/restore
- Tree-sitter syntax highlighting with lexical fallback
- LSP completion, diagnostics, hover, navigation, formatting, rename, code actions, semantic tokens, and inlay hints
- DAP and LLDB-DAP sessions
- Context-aware completion ranking
- Read-only dependency and external-library indexing
- Build discovery and process execution
- Vim command handling

## Requirements

- Swift 6.0 or newer
- macOS 13 or newer for local LSP/DAP process launching
- iOS 16 or newer for the library layers; iOS callers must inject a remote language service

## Add the package

```swift
.package(path: "../EditorServices")
```

```swift
.product(name: "EditorServices", package: "EditorServices")
```

```swift
import EditorServices
```

## Create a backend

```swift
import EditorServices
import Foundation

let workspace = URL(fileURLWithPath: "/path/to/project", isDirectory: true)
let backend = try await SwiftEditorBackend.makeSwift(workspaceURL: workspace)

let file = workspace.appendingPathComponent("Sources/App/main.swift")
try await backend.openFile(at: file)

let highlights = try await backend.highlights(in: file)
let completions = try await backend.completions(
  in: file,
  at: TextPosition(line: 3, utf16Column: 12)
)
```

All public text positions use zero-based lines and UTF-16 columns.

```swift
try await backend.applyUTF16Edit(
  editedNSRange,
  replacement: replacementString,
  to: file
)
```

Save and close through the backend so the document store and language services remain synchronized.

```swift
try await backend.saveFile(at: file)
try await backend.closeFile(at: file)
try await backend.shutdown()
```

## External libraries

External sources are indexed as read-only completion context and never become editable project files.

Automatic discovery includes:

- SwiftPM `.build/checkouts`
- Xcode `DerivedData/*/SourcePackages/checkouts`, filtered by `Package.resolved`
- SwiftPM and Cargo local path dependencies, resolved relative to each nested manifest
- Cargo registry crates from every discovered `Cargo.lock` graph, including transitive dependencies
- Cargo Git checkouts
- Node dependencies from root and nested `package.json` workspaces
- Python virtual environments, user site-packages, and `PYTHONPATH`
- Go module cache entries from root and nested `go.mod` files
- CocoaPods, Carthage, common vendor folders, and compiler include paths

Swift interfaces, C/C++ headers, Rust sources, Python stubs, and other source/interface formats are included by default.

```swift
var configuration = SwiftEditorBackendConfiguration(workspaceURL: workspace)
configuration.sourceWorkspaceConfiguration.externalSourceIndex = .init(
  explicitRootURLs: [workspace.appendingPathComponent("SDK")],
  includesTestsAndExamples: false,
  maximumFileCount: 32_000
)

let backend = try await SwiftEditorBackend.makeSwift(configuration: configuration)
let report = await backend.refreshExternalSourceIndex()
```

Set `externalSourceIndex` to `nil`, or set `isEnabled` to `false`, to disable dependency indexing.

For nonstandard source roots, set `CALCITE_EXTERNAL_SOURCE_ROOTS` or `EDITOR_EXTERNAL_SOURCE_ROOTS` to a colon-separated list.

## Build execution

`EditorBuildDiscovery` detects SwiftPM, Xcode, Cargo, Node, CMake, Gradle, Go, Python, and supported single-file tasks.

`EditorBuildRunner` prepares a GUI-safe process environment. It searches explicit executable overrides, the supplied `PATH`, and common user toolchain locations such as:

- `$CARGO_HOME/bin` and `~/.cargo/bin`
- Homebrew
- mise and asdf shims
- Swiftly
- `~/.local/bin` and `~/bin`
- Nix profiles

An executable can be overridden with variables such as `CARGO_PATH`, `SOURCEKIT_LSP_PATH`, or the corresponding uppercase executable name.

```swift
let plan = EditorBuildDiscovery.inspect(workspaceURL: workspace)
if let command = plan.command(for: .check) {
  let runner = EditorBuildRunner()
  let events = try await runner.run(command)
  for await event in events {
    // Render output and diagnostics.
  }
}
```

## Completion

The fallback completion index includes project and external declarations. A language-neutral pipeline merges LSP, workspace, and dependency candidates, while language strategies supply syntax-specific behavior for Rust, Swift, Python, JavaScript/TypeScript, Go, Lua, and the C family.

Ranking considers the typed prefix, syntax context, expected type, current scope, receiver type, static versus instance access, parameters, local variables, inheritance, imports, project proximity, LSP ordering, and prior accepted completions. Member access prioritizes callable methods, return-type compatibility can outrank unrelated members, and overloads remain distinct even when their insertion placeholders share the same names. Typed initializer contexts suggest missing fields plus compatible visible values using each language's native syntax.

Completion results may contain snippets, a primary edit, and additional edits. Apply the returned edits instead of inserting only the visible label.

## Modules

- `EditorCore`: text, document, theme, and shared protocols
- `EditorWorkspace`: project source storage and file operations
- `EditorServiceKit`: deterministic language-service routing
- `EditorLSP`: language-server transport and document service
- `EditorTreeSitter`: syntax services and grammar registry
- `EditorDAP`: debug adapter transport and sessions
- `EditorVim`: Vim state and commands
- `EditorServices`: unified backend, completion, build, environment, and project integration

## Verification

```sh
cd EditorServices
swift test
swift-format lint --recursive --strict Sources/EditorVim Tests/EditorVimTests Package.swift
./Scripts/check-vim-api.sh
```

<<<<<<< HEAD
The Vim suite includes 500 committed differential fixtures generated from system Vim, branch-preserving undo history, semantic repeat/macro coverage, exact incremental edit batches, and a 10,000-edit randomized UTF-16 line-index stress test. Regenerate fixtures with `Scripts/generate-vim-differential-fixtures.py` when intentionally changing compatibility behavior. See [`VIM_ENGINE_IMPROVEMENTS.md`](VIM_ENGINE_IMPROVEMENTS.md) for the current Stage 4 architecture and validation details.
=======
The Vim suite includes committed differential fixtures generated from system Vim. Regenerate them with `Scripts/generate-vim-differential-fixtures.py` when intentionally changing compatibility behavior. See [`VIM_ENGINE_IMPROVEMENTS.md`](VIM_ENGINE_IMPROVEMENTS.md) for the current architecture and validation details.
>>>>>>> 0130b0923308e9a17b7c12b9edcd0615c0d3c883

The repository keeps focused project tests. Historical status reports and overlapping integration suites are intentionally omitted.

## Third-party software

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). Vendored license files remain authoritative.
