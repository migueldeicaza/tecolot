// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NerdFontMetadataGen",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "NerdFontMetadataGen", path: "Sources")
    ]
)
