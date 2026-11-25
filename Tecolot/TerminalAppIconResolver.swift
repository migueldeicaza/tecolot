import AppKit

/// Finds the icon of a command from its executable path. Terminal titles
/// are not command names, so the resolver does not use them.
@MainActor
final class TerminalAppIconResolver {
    static let shared = TerminalAppIconResolver()
    private var cache: [String: NSImage] = [:]

    nonisolated static func identity(forExecutablePath path: String?) -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent.lowercased()
        if name.range(of: #"^python3(?:\.[0-9]+)+$"#, options: .regularExpression) != nil {
            return "python3"
        }
        if name.range(of: #"^perl5(?:\.[0-9]+)*$"#, options: .regularExpression) != nil {
            return "perl"
        }
        if name.range(of: #"^php[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil {
            return "php"
        }
        if name.range(of: #"^ruby[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil {
            return "ruby"
        }
        if name == "claude.exe" || name == "claude-code" {
            return "claude"
        }
        if name == "codex.exe" || name.range(of: #"^codex-(?:darwin|aarch64|x86_64|arm64)"#, options: .regularExpression) != nil {
            return "codex"
        }
        if
            isClaudeVersionsDirectory(url.deletingLastPathComponent()),
            name.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil {
            return "claude"
        }
        return name
    }

    /// Whether `directory` is ~/.local/share/claude/versions. The check
    /// does not depend on the disk: it compares path components, because
    /// appendingPathComponent adds a trailing slash only when the directory
    /// exists, and it standardizes both paths in the same form, because
    /// standardizing removes /private only from paths that exist.
    nonisolated static func isClaudeVersionsDirectory(
        _ directory: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let versions = URL(fileURLWithPath: home.path).appendingPathComponent(".local/share/claude/versions")
        return URL(fileURLWithPath: directory.path).standardizedFileURL.pathComponents
            == URL(fileURLWithPath: versions.path).standardizedFileURL.pathComponents
    }

    nonisolated static func isRecognizedCommand(_ identity: String) -> Bool {
        brandAssetName(for: identity) != nil
            || ["ssh", "mosh", "lazygit", "codex", "claude", "agy"].contains(identity)
    }

    func icon(forExecutablePath path: String?) -> NSImage {
        let key = path ?? ""
        if let image = cache[key] {
            return image
        }
        let identity = Self.identity(forExecutablePath: path) ?? ""
        let image = (Self.prefersBrandIcon(identity) ? bundledBrandIcon(identity) : nil)
            ?? enclosingAppIcon(path)
            ?? installedAppIcon(identity)
            ?? bundledBrandIcon(identity)
            ?? symbolIcon(identity)
        cache[key] = image
        return image
    }

    /// Resolved tab tile artwork together with whether it came from an
    /// installed macOS application bundle (full-bleed app icon) rather than a
    /// compact brand glyph or SF Symbol.
    struct TabGlyph {
        let image: NSImage
        let isAppIcon: Bool
    }

    /// Prefers an installed macOS application icon for app-backed commands
    /// (such as Claude, Codex, and Antigravity), falling back to bundled brand
    /// artwork and finally an SF Symbol.
    func tabGlyph(for identity: String) -> NSImage {
        resolvedTabGlyph(for: identity).image
    }

    func resolvedTabGlyph(for identity: String) -> TabGlyph {
        if Self.prefersInstalledAppIcon(identity), let image = installedAppIcon(identity) {
            return TabGlyph(image: image, isAppIcon: true)
        }
        return TabGlyph(image: bundledBrandIcon(identity) ?? symbolIcon(identity), isAppIcon: false)
    }

    func resolvedTabIcon(forExecutablePath path: String?) -> TabGlyph {
        if let appIcon = enclosingAppIcon(path) {
            return TabGlyph(image: appIcon, isAppIcon: true)
        }
        let identity = Self.identity(forExecutablePath: path) ?? ""
        if Self.prefersInstalledAppIcon(identity), let appIcon = installedAppIcon(identity) {
            return TabGlyph(image: appIcon, isAppIcon: true)
        }
        return TabGlyph(image: icon(forExecutablePath: path), isAppIcon: false)
    }

    private func enclosingAppIcon(_ path: String?) -> NSImage? {
        guard let path, path.hasPrefix("/") else {
            return nil
        }
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while url.path != "/" {
            if
                url.pathExtension.lowercased() == "app",
                FileManager.default.fileExists(atPath: url.path) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private func installedAppIcon(_ identity: String) -> NSImage? {
        for bundle in Self.bundleIdentifiers(for: identity) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }

    nonisolated static func bundleIdentifiers(for identity: String) -> [String] {
        let bundles: [String: [String]] = [
            "codex": ["com.openai.codex", "com.openai.chat"],
            "claude": ["com.anthropic.claudefordesktop"],
            "claude-code": ["com.anthropic.claudefordesktop"],
            "agy": ["com.google.antigravity"],
            "python": ["org.python.IDLE"],
            "python3": ["org.python.IDLE"]
        ]
        return bundles[identity] ?? []
    }

    /// Commands whose installed macOS app icon is preferred over bundled brand
    /// artwork when available; bundled artwork acts as the fallback.
    nonisolated static func prefersInstalledAppIcon(_ identity: String) -> Bool {
        !bundleIdentifiers(for: identity).isEmpty && !["python", "python3"].contains(identity)
    }

    /// Only assets with an approved source and license can use these names.
    private func bundledBrandIcon(_ identity: String) -> NSImage? {
        guard let name = Self.brandAssetName(for: identity) else {
            return nil
        }
        return NSImage(named: name)
    }

    /// Commands that can run from inside a different app. For example,
    /// /usr/bin/git runs the git that is inside Xcode.app. For these
    /// commands, the brand icon has priority over the icon of that app.
    /// Add a command here when its icon shows the wrong app.
    static func prefersBrandIcon(_ identity: String) -> Bool {
        brandAssetName(for: identity) != nil && identity != "bun" && !prefersInstalledAppIcon(identity)
    }

    nonisolated static func brandAssetName(for identity: String) -> String? {
        let brand: String
        switch identity {
        case "bun", "git", "perl", "php", "ruby", "dotnet", "hermes", "opencode", "pi", "htop", "claude", "codex":
            brand = identity
        case "claude-code":
            brand = "claude"
        case "python", "python3", "ipython", "ipython3":
            brand = "python"
        case "node", "nodejs":
            brand = "node"
        default:
            return nil
        }
        return "TerminalBrand-" + brand
    }

    private func symbolIcon(_ identity: String) -> NSImage {
        let symbol = Self.fallbackSymbolName(for: identity)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: identity.isEmpty ? "Terminal" : identity)
            ?? NSApp.applicationIconImage
            ?? NSImage()
    }

    static func fallbackSymbolName(for identity: String) -> String {
        switch identity {
        case "ssh", "mosh":
            return "network"
        case "git", "lazygit":
            return "arrow.triangle.branch"
        case "node", "bun", "python", "python3":
            return "chevron.left.forwardslash.chevron.right"
        case "codex", "claude", "agy":
            return "sparkles"
        case "less", "more":
            return "doc.text"
        case "emacs":
            return "textformat"
        case "nvim", "vim":
            return "pencil.line"
        case "top":
            return "waveform.path.ecg"
        case "kubectl", "docker":
            return "shippingbox"
        default:
            return "terminal"
        }
    }
}
