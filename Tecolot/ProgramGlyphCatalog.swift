import AppKit

/// Tecolot's supported program tiles. The command aliases are ordinary names
/// for these programs; this table does not import another terminal's catalog.
nonisolated enum ProgramGlyphCatalog {
    struct Entry: Equatable {
        let id: String
        let displayName: String
        let background: UInt32
        var foreground: UInt32 = 0xF3F6FC
        var aliases: [String] = []
    }

    /// A small hand-picked Tecolot palette: charcoal, blue, teal, amber,
    /// violet and rose. These colors are independent of the reference app.
    private enum Palette {
        static let charcoal: UInt32 = 0x363636
        static let blue: UInt32 = 0x426C9A
        static let teal: UInt32 = 0x376E74
        static let amber: UInt32 = 0x8C682D
        static let violet: UInt32 = 0x665B8F
        static let rose: UInt32 = 0x92536D
    }

    static let terminal = Entry(id: "terminal", displayName: "Terminal", background: Palette.charcoal)
    static let grayBackground: UInt32 = 0xC8CED6
    static let grayForeground: UInt32 = 0x5E6876

    /// Every id has an existing brand asset, app-icon mapping or specific
    /// SF Symbol in TerminalAppIconResolver. Other executables use Terminal.
    static let entries: [Entry] = [
        terminal,
        Entry(id: "ssh", displayName: "SSH", background: Palette.teal),
        Entry(id: "mosh", displayName: "Mosh", background: Palette.teal),
        Entry(id: "git", displayName: "Git", background: Palette.rose),
        Entry(id: "lazygit", displayName: "Lazygit", background: Palette.rose),
        Entry(id: "perl", displayName: "Perl", background: Palette.blue),
        Entry(id: "node", displayName: "Node.js", background: Palette.teal, aliases: ["nodejs"]),
        Entry(id: "bun", displayName: "Bun", background: Palette.amber, aliases: ["bunx"]),
        Entry(
            id: "python",
            displayName: "Python",
            background: Palette.blue,
            aliases: ["python3", "ipython", "ipython3"]
        ),
        Entry(id: "php", displayName: "PHP", background: Palette.violet),
        Entry(id: "ruby", displayName: "Ruby", background: Palette.rose),
        Entry(id: "dotnet", displayName: ".NET", background: Palette.violet),
        Entry(id: "hermes", displayName: "Hermes", background: Palette.amber),
        Entry(id: "opencode", displayName: "OpenCode", background: Palette.charcoal),
        Entry(id: "pi", displayName: "Pi", background: Palette.teal),
        Entry(id: "htop", displayName: "htop", background: Palette.teal),
        Entry(id: "codex", displayName: "Codex", background: Palette.teal),
        Entry(id: "claude", displayName: "Claude Code", background: Palette.rose, aliases: ["claude-code"]),
        Entry(id: "agy", displayName: "Antigravity", background: Palette.blue),
        Entry(id: "less", displayName: "less", background: Palette.blue),
        Entry(id: "more", displayName: "more", background: Palette.blue),
        Entry(id: "emacs", displayName: "Emacs", background: Palette.violet, aliases: ["emacsclient"]),
        Entry(id: "nvim", displayName: "Neovim", background: Palette.teal, aliases: ["neovim"]),
        Entry(id: "vim", displayName: "Vim", background: Palette.teal, aliases: ["vi", "view", "vimdiff"]),
        Entry(id: "top", displayName: "top", background: Palette.blue),
        Entry(id: "kubectl", displayName: "Kubernetes", background: Palette.blue),
        Entry(id: "docker", displayName: "Docker", background: Palette.blue)
    ]

    static func entry(forExecutablePath path: String?) -> Entry {
        guard let name = TerminalAppIconResolver.identity(forExecutablePath: path) else {
            return terminal
        }
        return entries.first {
            $0.id == name || $0.aliases.contains(name)
        } ?? terminal
    }

    @MainActor static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255,
            alpha: 1
        )
    }
}
