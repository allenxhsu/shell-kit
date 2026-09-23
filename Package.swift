// swift-tools-version: 6.0
//
// shell-kit — the Swift shell the toolkit's web apps run in on macOS. An app
// keeps its model, diagrams and editing in its web code; this package hosts
// that page in a WKWebView and adds what a browser tab cannot: documents, the
// menu bar, save panels and vector PDF export.

import PackageDescription

let package = Package(
    name: "shell-kit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ToolkitShell", targets: ["ToolkitShell"]),
    ],
    targets: [
        // Language mode 5: AppKit's document and WebKit's delegate APIs still
        // carry isolation annotations that Swift 6 mode rejects in practice.
        .target(name: "ToolkitShell", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ToolkitShellTests", dependencies: ["ToolkitShell"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
