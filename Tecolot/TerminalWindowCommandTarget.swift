import AppKit

/// Keyboard commands use the key window, or the main window when there is no key window.
/// An auxiliary key window prevents commands from reaching a terminal behind it.
@MainActor
struct TerminalWindowCommandTarget {
    let window: NSWindow
    let terminal: TerminalWindowController?

    static func resolve(
        keyWindow: NSWindow?,
        mainWindow: NSWindow?,
        manager: TerminalWindowManager? = nil
    ) -> Self? {
        guard let window = keyWindow ?? mainWindow else {
            return nil
        }
        return Self(window: window, terminal: (manager ?? .shared).controller(for: window))
    }
}
