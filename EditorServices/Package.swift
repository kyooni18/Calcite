// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "EditorServices",
  platforms: [
    .macOS(.v13),
    .iOS(.v16),
    .macCatalyst(.v16),
  ],
  products: [
    .library(name: "EditorCore", targets: ["EditorCore"]),
    .library(name: "EditorWorkspace", targets: ["EditorWorkspace"]),
    .library(name: "EditorServiceKit", targets: ["EditorServiceKit"]),
    .library(name: "EditorDAP", targets: ["EditorDAP"]),
    .library(name: "EditorTreeSitter", targets: ["EditorTreeSitter"]),
    .library(name: "EditorLSP", targets: ["EditorLSP"]),
    .library(name: "EditorServices", targets: ["EditorServices"]),
    .library(name: "EditorVim", targets: ["EditorVim"]),
    .executable(name: "EditorServicesQuickstart", targets: ["EditorServicesQuickstart"]),
  ],
  dependencies: [
    .package(path: "Vendor/swift-tree-sitter"),
    .package(path: "Vendor/TreeSitterSwift"),
    .package(path: "Vendor/LanguageClient"),
    .package(path: "Vendor/LanguageServerProtocol"),
    .package(path: "Vendor/DebugAdapterProtocol"),
    .package(path: "Vendor/FSEventsWrapper"),
    .package(path: "Vendor/JSONRPC"),
    .package(path: "Vendor/ProcessEnv"),
  ],
  targets: [
    .target(name: "EditorCore"),
    .target(name: "EditorWorkspace", dependencies: ["EditorCore"]),
    .target(name: "EditorServiceKit", dependencies: ["EditorCore"]),
    .target(name: "EditorVim", dependencies: ["EditorCore"]),
    .target(
      name: "EditorDAP",
      dependencies: [
        "EditorCore",
        .product(name: "DebugAdapterProtocol", package: "DebugAdapterProtocol"),
      ]
    ),
    .target(
      name: "EditorTreeSitter",
      dependencies: [
        "EditorCore",
        .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
        .product(name: "TreeSitterSwift", package: "TreeSitterSwift"),
      ],
      resources: [.copy("Resources")]
    ),
    .target(
      name: "EditorLSP",
      dependencies: [
        "EditorCore",
        .product(name: "LanguageClient", package: "LanguageClient"),
        .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
        .product(name: "JSONRPC", package: "JSONRPC"),
        .product(name: "ProcessEnv", package: "ProcessEnv"),
      ]
    ),
    .target(
      name: "EditorServices",
      dependencies: [
        "EditorCore",
        "EditorWorkspace",
        "EditorServiceKit",
        "EditorVim",
        "EditorDAP",
        "EditorTreeSitter",
        "EditorLSP",
        .product(
          name: "FSEventsWrapper",
          package: "FSEventsWrapper",
          condition: .when(platforms: [.macOS])
        ),
      ]
    ),
    .executableTarget(
      name: "EditorServicesQuickstart",
      dependencies: ["EditorServices"],
      path: "Examples/Quickstart"
    ),
    .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
    .testTarget(name: "EditorWorkspaceTests", dependencies: ["EditorWorkspace"]),
    .testTarget(name: "EditorServiceKitTests", dependencies: ["EditorServiceKit"]),
    .testTarget(name: "EditorVimTests", dependencies: ["EditorVim"]),
    .testTarget(
      name: "EditorDAPTests",
      dependencies: [
        "EditorDAP", .product(name: "DebugAdapterProtocol", package: "DebugAdapterProtocol"),
      ]),
    .testTarget(
      name: "EditorTreeSitterTests",
      dependencies: [
        "EditorTreeSitter", .product(name: "TreeSitterSwift", package: "TreeSitterSwift"),
      ]
    ),
    .testTarget(
      name: "EditorLSPTests",
      dependencies: [
        "EditorLSP",
        .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
      ]
    ),
    .testTarget(name: "EditorServicesTests", dependencies: ["EditorServices"]),
  ]
)
