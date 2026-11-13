import AppKit
import Testing
@testable import Tecolot

@MainActor
struct TerminalWindowAppearanceTests {
    @Test func themedChromePaintsTheStripAndLeavesTheTitlebarTransparent() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let strip = HorizontalTabBarView()
        TerminalWindowAppearance.apply(theme: .fallback, to: window)
        strip.apply(theme: .fallback, opacity: 0.8)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(strip.layer?.backgroundColor == TabStripChrome(theme: .fallback, opacity: 0.8, key: false, appearance: strip.effectiveAppearance).bar.cgColor)
        #expect(window.appearance != nil)
    }

    @Test func removingTheThemeRestoresSystemChromeColors() {
        let window = NSWindow()
        let strip = HorizontalTabBarView()
        TerminalWindowAppearance.apply(theme: .fallback, to: window)
        strip.apply(theme: .fallback, opacity: 1)
        TerminalWindowAppearance.apply(theme: nil, to: window)
        strip.apply(theme: nil, opacity: 1)
        #expect(window.appearance == nil)
        #expect(window.titlebarAppearsTransparent)
        #expect(strip.layer?.backgroundColor == TabStripChrome(theme: nil, opacity: 1, key: false, appearance: strip.effectiveAppearance).bar.cgColor)
    }
}
