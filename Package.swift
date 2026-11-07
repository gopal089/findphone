// swift-tools-version:5.9
// The line above tells Swift Package Manager which manifest format this file uses.

import PackageDescription

let package = Package(
    name: "findphone",
    // The tool runs on macOS 13 (Ventura) or later.
    platforms: [.macOS(.v13)],
    targets: [
        // A command-line program built from Sources/findphone.
        // It uses only Apple system frameworks (Foundation and CoreBluetooth),
        // so there are no external dependencies.
        .executableTarget(
            name: "findphone",
            path: "Sources/findphone"
        )
    ]
)
