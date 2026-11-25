import AppKit

/// Keeps windowed titlebars transparent for custom chrome, while restoring the native titlebar in full screen.
@MainActor
enum TerminalWindowAppearance {
    static func apply(theme: TerminalTheme?, to window: NSWindow, isFullScreen: Bool? = nil) {
        window.appearance = theme.flatMap {
            NSAppearance(named: $0.isDark ? .darkAqua : .aqua)
        }
        let fullscreen = isFullScreen ?? window.styleMask.contains(.fullScreen)
        window.titlebarAppearsTransparent = !fullscreen
        window.titleVisibility = fullscreen ? .visible : .hidden
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
