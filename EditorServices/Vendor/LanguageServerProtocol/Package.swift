// swift-tools-version: 5.8

import PackageDescription

let package = Package(
	name: "LanguageServerProtocol",
	platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6)],
	products: [
		.library(name: "LanguageServerProtocol", targets: ["LanguageServerProtocol"]),
	],
	dependencies: [
		.package(path: "../JSONRPC"),

	],
	targets: [
		.target(
			name: "LanguageServerProtocol",
			dependencies: [.product(name: "JSONRPC", package: "JSONRPC")]),
		.testTarget(
			name: "LanguageServerProtocolTests",
			dependencies: ["LanguageServerProtocol"]),
	]
)

let swiftSettings: [SwiftSetting] = [
	.enableExperimentalFeature("StrictConcurrency")
]

for target in package.targets {
	var settings = target.swiftSettings ?? []
	settings.append(contentsOf: swiftSettings)
	target.swiftSettings = settings
}
