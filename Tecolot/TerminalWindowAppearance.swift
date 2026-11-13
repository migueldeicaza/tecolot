import AppKit

/// Native chrome stays transparent; the custom strip paints its background.
@MainActor
enum TerminalWindowAppearance {
    static func apply(theme: TerminalTheme?, to window: NSWindow) {
        window.appearance = theme.flatMap {
            NSAppearance(named: $0.isDark ? .darkAqua : .aqua)
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
    }

    static func background(theme: TerminalTheme?, opacity: Double) -> NSColor {
        guard let theme else {
            return .windowBackgroundColor
        }
        return NSColor(
            srgbRed: CGFloat(theme.background.red) / 65_535,
            green: CGFloat(theme.background.green) / 65_535,
            blue: CGFloat(theme.background.blue) / 65_535,
            alpha: opacity
        )
    }
}
