// swift-tools-version:5.5

import PackageDescription

let package = Package(
	name: "DebugAdapterProtocol",
	platforms: [.macOS(.v10_12), .iOS(.v10), .tvOS(.v10), .watchOS(.v3)],
	products: [
		.library(
		name: "DebugAdapterProtocol",
		targets: ["DebugAdapterProtocol"]),
	],
	dependencies: [
		.package(path: "../JSONRPC"),
	],
	targets: [
		.target(
			name: "DebugAdapterProtocol",
			dependencies: [.product(name: "JSONRPC", package: "JSONRPC")]),
		.testTarget(
			name: "DebugAdapterProtocolTests",
			dependencies: ["DebugAdapterProtocol"]),
	]
)
