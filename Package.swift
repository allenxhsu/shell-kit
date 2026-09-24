// swift-tools-version: 6.0
//
// shell-kit — the Swift shell the toolkit's web apps run in on macOS. An app
// keeps its model, diagrams and editing in its web code; this package hosts
// that page in a WKWebView and adds what a browser tab cannot: documents, the
// menu bar, save panels, vector PDF export and pairing with the Portal.
//
// The sync-kit dependency is a sibling path, so a clone needs ../sync-kit
// beside it — the same assumption the apps already make when they vendor
// sync-kit's JavaScript.

import PackageDescription

let package = Package(
    name: "shell-kit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ToolkitShell", targets: ["ToolkitShell"]),
    ],
    dependencies: [
        // PairingFlow: the sign-in sheet, the connect link and the Keychain.
        .package(name: "SyncKit", path: "../sync-kit/swift"),
    ],
    targets: [
        // Language mode 5: AppKit's document and WebKit's delegate APIs still
        // carry isolation annotations that Swift 6 mode rejects in practice.
        .target(name: "ToolkitShell", dependencies: [.product(name: "SyncKit", package: "SyncKit")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ToolkitShellTests", dependencies: ["ToolkitShell"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // The sample app of README's "Adopting it", built by scripts/build-sample-app.sh
        // and paired against scripts/dev-portal.mjs. It is what proves the
        // whole path works without a real app in the loop.
        .executableTarget(name: "PairingSample", dependencies: ["ToolkitShell"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
