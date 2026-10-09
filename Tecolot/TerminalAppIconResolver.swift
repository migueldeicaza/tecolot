import AppKit

/// Finds the icon of a command from its executable path. Terminal titles
/// are not command names, so the resolver does not use them.
@MainActor
final class TerminalAppIconResolver {
    static let shared = TerminalAppIconResolver()
    private var cache: [String: NSImage] = [:]

    nonisolated static func identity(forExecutablePath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent.lowercased()
        if name.range(of: #"^python3(?:\.[0-9]+)+$"#, options: .regularExpression) != nil {
            return "python3"
        }
        let claudeVersions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/claude/versions").standardizedFileURL
        if url.deletingLastPathComponent() == claudeVersions,
           name.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil {
            return "claude"
        }
        return name
    }

    nonisolated static func isRecognizedCommand(_ identity: String) -> Bool {
        ["ssh", "mosh", "git", "lazygit", "node", "bun", "python", "python3", "codex", "claude"].contains(identity)
    }

    func icon(forExecutablePath path: String?) -> NSImage {
        let key = path ?? ""
        if let image = cache[key] { return image }
        let identity = Self.identity(forExecutablePath: path) ?? ""
        let image = (Self.prefersBrandIcon(identity) ? bundledBrandIcon(identity) : nil)
            ?? enclosingAppIcon(path)
            ?? installedAppIcon(identity)
            ?? bundledBrandIcon(identity)
            ?? symbolIcon(identity)
        cache[key] = image
        return image
    }

    private func enclosingAppIcon(_ path: String?) -> NSImage? {
        guard let path, path.hasPrefix("/") else { return nil }
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension.lowercased() == "app",
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

    static func bundleIdentifiers(for identity: String) -> [String] {
        let bundles: [String: [String]] = [
            "codex": ["com.openai.codex"],
            "claude": ["com.anthropic.claudefordesktop"],
            "python": ["org.python.IDLE"],
            "python3": ["org.python.IDLE"]
        ]
        return bundles[identity] ?? []
    }

    /// Only assets with an approved source and license can use these names.
    private func bundledBrandIcon(_ identity: String) -> NSImage? {
        guard let name = Self.brandAssetName(for: identity) else { return nil }
        return NSImage(named: name)
    }

    /// Commands that can run from inside a different app. For example,
    /// /usr/bin/git runs the git that is inside Xcode.app. For these
    /// commands, the brand icon has priority over the icon of that app.
    /// Add a command here when its icon shows the wrong app.
    static func prefersBrandIcon(_ identity: String) -> Bool {
        identity == "git"
    }

    static func brandAssetName(for identity: String) -> String? {
        guard ["bun", "git"].contains(identity) else { return nil }
        return "TerminalBrand-" + identity
    }

    private func symbolIcon(_ identity: String) -> NSImage {
        let symbol = Self.fallbackSymbolName(for: identity)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: identity.isEmpty ? "Terminal" : identity)
            ?? NSApp.applicationIconImage
            ?? NSImage()
    }

    static func fallbackSymbolName(for identity: String) -> String {
        switch identity {
        case "ssh", "mosh": return "network"
        case "git", "lazygit": return "arrow.triangle.branch"
        case "node", "bun", "python", "python3": return "chevron.left.forwardslash.chevron.right"
        case "codex", "claude": return "sparkles"
        case "less", "more": return "doc.text"
        default: return "terminal"
        }
    }
}
