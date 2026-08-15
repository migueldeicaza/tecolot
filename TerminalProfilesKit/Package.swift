// swift-tools-version: 5.9

import PackageDescription

// TerminalProfilesKit: themes + profiles for a SwiftTerm-based terminal app.
//
// This package intentionally lives inside the app tree: it makes no public
// API stability promises while the model evolves. Feel free to copy or
// vendor it into your own SwiftTerm host.
let package = Package(
    name: "TerminalProfilesKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "TerminalProfilesKit", targets: ["TerminalProfilesKit"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm",
            branch: "new-io-perf-glyph-cache"
        )
    ],
    targets: [
        .target(
            name: "TerminalProfilesKit",
            dependencies: ["SwiftTerm"],
            resources: [
                .copy("Resources/Themes"),
                .copy("Resources/shell-integration")
            ]
        ),
        .testTarget(
            name: "TerminalProfilesKitTests",
            dependencies: ["TerminalProfilesKit"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
