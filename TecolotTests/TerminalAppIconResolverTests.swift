import AppKit
import Testing
@testable import Tecolot

@MainActor
struct TerminalAppIconResolverTests {
    @Test func identityUsesExecutableBasename() {
        #expect(TerminalAppIconResolver.identity(forExecutablePath: nil) == nil)
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "") == nil)
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/opt/bin/Node") == "node")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/Applications/Example.app/Contents/MacOS/Example") == "example")
    }

    @Test func brandMappingUsesOnlyBundledArtwork() {
        #expect(TerminalAppIconResolver.brandAssetName(for: "bun") == "TerminalBrand-bun")
        #expect(TerminalAppIconResolver.brandAssetName(for: "git") == "TerminalBrand-git")
        #expect(TerminalAppIconResolver.brandAssetName(for: "lazygit") == nil)
        #expect(TerminalAppIconResolver.brandAssetName(for: "node") == nil)
        #expect(TerminalAppIconResolver.bundleIdentifiers(for: "claude") == ["com.anthropic.claudefordesktop"])
        #expect(TerminalAppIconResolver.bundleIdentifiers(for: "git").isEmpty)
    }

    @Test func bundledBrandImagesLoadFromTheApp() throws {
        for command in ["bun", "git"] {
            let name = try #require(TerminalAppIconResolver.brandAssetName(for: command))
            let image = try #require(NSImage(named: name))
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
            #expect(!image.isTemplate)
        }
    }

    @Test func executableInsideAppUsesAppIcon() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = directory.appendingPathComponent("IconTest.app")
        let executable = app.appendingPathComponent("Contents/MacOS/bun")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: executable)
        let expected = NSWorkspace.shared.icon(forFile: app.path)
        let actual = TerminalAppIconResolver().icon(forExecutablePath: executable.path)
        #expect(actual.tiffRepresentation == expected.tiffRepresentation)
    }

    @Test func gitInsideAnAppUsesTheGitIcon() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = directory.appendingPathComponent("Xcode.app/Contents/Developer/usr/bin/git")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: executable)
        let expected = try #require(NSImage(named: "TerminalBrand-git"))
        let actual = TerminalAppIconResolver().icon(forExecutablePath: executable.path)
        #expect(actual.tiffRepresentation == expected.tiffRepresentation)
        #expect(TerminalAppIconResolver.prefersBrandIcon("git"))
        #expect(!TerminalAppIconResolver.prefersBrandIcon("bun"))
    }

    @Test func fallbackCoversShellsRemoteCommandsAndUnknownProcesses() {
        for command in ["bash", "zsh", "fish", "nu", "elvish", "unknown", ""] {
            #expect(TerminalAppIconResolver.fallbackSymbolName(for: command) == "terminal")
        }
        #expect(TerminalAppIconResolver.fallbackSymbolName(for: "ssh") == "network")
        #expect(TerminalAppIconResolver.fallbackSymbolName(for: "python3") == "chevron.left.forwardslash.chevron.right")
        let resolver = TerminalAppIconResolver()
        let icon = resolver.icon(forExecutablePath: "/missing/unknown-command")
        #expect(icon.size.width > 0)
        #expect(resolver.icon(forExecutablePath: "/missing/unknown-command") === icon)
    }
}
