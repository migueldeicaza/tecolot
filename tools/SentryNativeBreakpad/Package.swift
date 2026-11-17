// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The published XCFramework. Do not replace the asset at this URL. A new
// build gets a new release tag, a new URL, and a new checksum.
let sentryNativeURL = "https://github.com/migueldeicaza/tecolot/releases/download/sentry-native-0.17.6/CSentryNative-0.17.6-macos.xcframework.zip"
let sentryNativeChecksum = "954d314ce44d87dbacbfd1cb1c515612fc8d78851fc4d1a7fdca03ec6a632c03"

// Maintainers can set SENTRY_NATIVE_LOCAL=1 to use the XCFramework that
// `make sentry-native` builds in Artifacts/.
let useLocalBuild = ProcessInfo.processInfo.environment["SENTRY_NATIVE_LOCAL"] == "1"

let sentryNativeTarget: Target = useLocalBuild
    ? .binaryTarget(name: "CSentryNative", path: "Artifacts/CSentryNative.xcframework")
    : .binaryTarget(name: "CSentryNative", url: sentryNativeURL, checksum: sentryNativeChecksum)

let package = Package(
    name: "SentryNativeBreakpad",
    platforms: [.macOS("15.5")],
    products: [
        .library(name: "SentryNativeBreakpad", targets: ["SentryNativeBreakpad"])
    ],
    targets: [
        sentryNativeTarget,
        .target(
            name: "SentryNativeBreakpad",
            dependencies: ["CSentryNative"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation")
            ]
        )
    ]
)
