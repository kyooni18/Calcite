# Third-party source notices

This distribution vendors its SwiftPM dependencies so it can build without network access. Each dependency remains owned by its original authors and contributors, and each is distributed under its own license.

The complete license texts are preserved at these paths:

- `Vendor/DebugAdapterProtocol/LICENSE`
- `Vendor/FSEventsWrapper/LICENSE`
- `Vendor/JSONRPC/LICENSE`
- `Vendor/LanguageClient/LICENSE`
- `Vendor/LanguageServerProtocol/LICENSE`
- `Vendor/ProcessEnv/LICENSE`
- `Vendor/Queue/LICENSE`
- `Vendor/Semaphore/LICENSE`
- `Vendor/TreeSitter/LICENSE`
- `Vendor/TreeSitterSwift/LICENSE`
- `Vendor/swift-glob/LICENSE`
- `Vendor/swift-tree-sitter/LICENSE`

The vendored `swift-tree-sitter` source also contains its bundled Swift grammar license at:

- `Vendor/swift-tree-sitter/tree-sitter-swift/LICENSE`

The upstream package names, authors, roles, project links, dependency relationship, licenses, and local source paths are credited in the README section [Third-party packages and credits](README.md#third-party-packages-and-credits).

`Vendor/FSEventsWrapper/LICENSE` restores the upstream `License.txt` that was absent from the originally supplied dependency archive. It is the MIT license published by the upstream `Frizlab/FSEventsWrapper` project.

Some vendored sources and test helpers contain compatibility corrections described in `BUILD_STATUS.md`. Their package names, ownership, and license terms remain unchanged. Vendoring and modification do not imply endorsement by any upstream project.
