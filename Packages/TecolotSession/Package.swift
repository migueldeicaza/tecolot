// swift-tools-version:6.2
//
// Persistent terminal sessions for Tecolot.
//
// The SwiftTerm revision below must stay equal to the revision pinned in
// Tecolot.xcodeproj (XCRemoteSwiftPackageReference "SwiftTerm"). Xcode resolves
// a single SwiftTerm checkout for the app and this package.
import PackageDescription

let package = Package(
    name: "TecolotSession",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TecolotWire", targets: ["TecolotWire"]),
        .library(name: "TecolotTransport", targets: ["TecolotTransport"]),
        .library(name: "TecolotSessionDirectory", targets: ["TecolotSessionDirectory"]),
        .library(name: "TecolotSessionHost", targets: ["TecolotSessionHost"]),
        .library(name: "TecolotSessionDaemon", targets: ["TecolotSessionDaemon"]),
        .library(name: "TecolotSessionClient", targets: ["TecolotSessionClient"]),
        .executable(name: "tecolot-sessiond", targets: ["tecolot-sessiond"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm",
                 revision: "dae4c177faf8ee83fd1929a508401de8b75f407a"),
    ],
    targets: [
        // Wire format: framing, primitive codec, messages and the row codec.
        // Standard library only, so that it builds everywhere the helper runs.
        .target(name: "TecolotWire"),
        .testTarget(name: "TecolotWireTests", dependencies: ["TecolotWire"]),

        // Unix sockets, the runtime directory and framed message channels.
        .target(name: "TecolotTransport", dependencies: ["TecolotWire"]),
        .testTarget(name: "TecolotTransportTests", dependencies: ["TecolotTransport"]),

        // Session records, launch descriptions and the per-user session directory.
        // No SwiftTerm: the app uses it in-process.
        .target(name: "TecolotSessionDirectory", dependencies: ["TecolotWire", "TecolotTransport"]),

        // The headless session: PTY, SwiftTerm Terminal, row versions and frames.
        .target(name: "TecolotSessionHost", dependencies: [
            "TecolotWire", "TecolotTransport", "TecolotSessionDirectory",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .testTarget(name: "TecolotSessionHostTests", dependencies: [
            "TecolotSessionHost", "TecolotSessionDirectory", "TecolotWire", "TecolotTransport",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),

        // The helper process: serve one session, and the directory commands.
        .target(name: "TecolotSessionDaemon", dependencies: [
            "TecolotSessionHost", "TecolotSessionDirectory", "TecolotTransport", "TecolotWire",
        ]),
        .executableTarget(name: "tecolot-sessiond", dependencies: ["TecolotSessionDaemon"]),

        // Development tool: keystroke-to-screen latency of each pane path.
        // Run with `swift run -c release tecolot-latency`.
        .executableTarget(name: "tecolot-latency", dependencies: [
            "TecolotSessionHost", "TecolotSessionClient", "TecolotSessionDirectory",
            "TecolotTransport", "TecolotWire",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),

        // The client: connection, state, row cache, viewport and prefetch.
        // No SwiftTerm and no AppKit; the app turns cached rows into lines.
        .target(name: "TecolotSessionClient", dependencies: ["TecolotWire", "TecolotTransport"]),
        .testTarget(name: "TecolotSessionClientTests", dependencies: [
            "TecolotSessionClient", "TecolotSessionHost", "TecolotSessionDirectory", "TecolotWire", "TecolotTransport",
        ]),
        .testTarget(name: "TecolotSessionDaemonTests", dependencies: [
            "TecolotSessionDaemon", "TecolotSessionDirectory", "TecolotTransport", "TecolotWire",
            // Built so that the tests can start the real helper.
            "tecolot-sessiond",
        ]),
    ],
    swiftLanguageModes: [.v6]
)
