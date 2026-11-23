import AppKit
import Testing
@testable import Tecolot

@MainActor
struct TerminalAppIconResolverTests {
    @Test func versionedExecutablesUseKnownIdentities() {
        let versions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/claude/versions")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: versions.appendingPathComponent("2.1.294").path) == "claude")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/opt/bin/python3.13") == "python3")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/opt/bin/python3.13.1") == "python3")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/usr/bin/perl5.34") == "perl")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/opt/bin/php8.4") == "php")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/opt/bin/ruby3.3") == "ruby")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/tmp/2.1.294") == "2.1.294")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/tmp/claude/versions/2.1.294") == "2.1.294")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/opt/bin/python3.13-helper") == "python3.13-helper")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: versions.appendingPathComponent("unrelated").path) == "unrelated")
    }

    @Test func claudeVersionsMatchWhetherOrNotTheDirectoryExists() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon-resolver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let versions = home.appendingPathComponent(".local/share/claude/versions")
        let executable = URL(fileURLWithPath: versions.path + "/2.1.294")
        let other = URL(fileURLWithPath: home.path + "/.local/share/claude/other")
        #expect(TerminalAppIconResolver.isClaudeVersionsDirectory(executable.deletingLastPathComponent(), home: home))
        #expect(!TerminalAppIconResolver.isClaudeVersionsDirectory(other, home: home))
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        #expect(TerminalAppIconResolver.isClaudeVersionsDirectory(executable.deletingLastPathComponent(), home: home))
        #expect(TerminalAppIconResolver.isClaudeVersionsDirectory(URL(fileURLWithPath: versions.path + "/"), home: home))
        #expect(!TerminalAppIconResolver.isClaudeVersionsDirectory(other, home: home))
    }

    @Test func identityUsesExecutableBasename() {
        #expect(TerminalAppIconResolver.identity(forExecutablePath: nil) == nil)
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "") == nil)
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/opt/bin/Node") == "node")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/Applications/Example.app/Contents/MacOS/Example") == "example")
        #expect(TerminalAppIconResolver.identity(forExecutablePath: "/Users/example/.local/bin/agy") == "agy")
    }

    @Test func brandMappingUsesOnlyBundledArtwork() {
        #expect(TerminalAppIconResolver.brandAssetName(for: "bun") == "TerminalBrand-bun")
        #expect(TerminalAppIconResolver.brandAssetName(for: "git") == "TerminalBrand-git")
        #expect(TerminalAppIconResolver.brandAssetName(for: "lazygit") == nil)
        #expect(TerminalAppIconResolver.brandAssetName(for: "node") == "TerminalBrand-node")
        #expect(TerminalAppIconResolver.brandAssetName(for: "nodejs") == "TerminalBrand-node")
        #expect(TerminalAppIconResolver.brandAssetName(for: "python3") == "TerminalBrand-python")
        #expect(TerminalAppIconResolver.brandAssetName(for: "ipython") == "TerminalBrand-python")
        #expect(TerminalAppIconResolver.bundleIdentifiers(for: "claude") == ["com.anthropic.claudefordesktop"])
        #expect(TerminalAppIconResolver.bundleIdentifiers(for: "agy") == ["com.google.antigravity"])
        #expect(TerminalAppIconResolver.isRecognizedCommand("agy"))
        #expect(ProgramGlyphCatalog.entry(forExecutablePath: "/Users/example/.local/bin/agy").id == "agy")
        #expect(TerminalAppIconResolver.bundleIdentifiers(for: "git").isEmpty)
    }

    @Test func bundledBrandImagesLoadFromTheApp() throws {
        for command in ["bun", "git", "perl", "python", "php", "node", "ruby", "dotnet", "hermes", "opencode", "pi", "htop"] {
            let name = try #require(TerminalAppIconResolver.brandAssetName(for: command))
            let image = try #require(NSImage(named: name))
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
            #expect(image.isTemplate == ["pi", "htop"].contains(command))
        }
    }

    @Test func newProgramIconsAreSelectedByExecutableName() {
        for (executable, brand) in [
            ("perl5.34", "perl"),
            ("python3.14", "python"),
            ("php8.4", "php"),
            ("nodejs", "node"),
            ("ruby3.3", "ruby"),
            ("dotnet", "dotnet"),
            ("hermes", "hermes"),
            ("opencode", "opencode"),
            ("pi", "pi"),
            ("htop", "htop")
        ] {
            let path = "/opt/bin/" + executable
            let identity = TerminalAppIconResolver.identity(forExecutablePath: path) ?? ""
            #expect(TerminalAppIconResolver.isRecognizedCommand(identity))
            #expect(TerminalAppIconResolver.brandAssetName(for: identity) == "TerminalBrand-" + brand)
            #expect(TerminalAppIconResolver.prefersBrandIcon(identity))
            #expect(ProgramGlyphCatalog.entry(forExecutablePath: path).id == brand)
        }
    }

    @Test func antigravityUsesInstalledAppIconWhenAvailable() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity") else {
            return
        }
        let expectedSize = NSWorkspace.shared.icon(forFile: app.path).size
        let resolver = TerminalAppIconResolver()
        #expect(resolver.icon(forExecutablePath: "/Users/example/.local/bin/agy").size == expectedSize)
        #expect(resolver.tabGlyph(for: "agy").size == expectedSize)
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
