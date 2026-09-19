import AppKit
import Testing
@testable import Tecolot

@MainActor
struct WindowSizingTests {
    @Test func profileGridControlsInitialContentSize() {
        var base = TerminalProfile(name: "Base")
        base.columns = 80
        base.rows = 25

        var wider = base
        wider.columns = 120

        var taller = base
        taller.rows = 40

        let baseSize = TerminalProfileWindowSizer.contentSize(for: base)
        let widerSize = TerminalProfileWindowSizer.contentSize(for: wider)
        let tallerSize = TerminalProfileWindowSizer.contentSize(for: taller)

        #expect(widerSize.width > baseSize.width)
        #expect(widerSize.height == baseSize.height)
        #expect(tallerSize.width == baseSize.width)
        #expect(tallerSize.height > baseSize.height)
    }

    @Test func profileContentSizeSetsTheWindowLayoutArea() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let requestedSize = NSSize(width: 640, height: 400)

        TerminalWindowSizeStore.shared.setProfileContentSize(requestedSize, on: window)

        #expect(abs(window.contentLayoutRect.width - requestedSize.width) < 0.5)
        #expect(abs(window.contentLayoutRect.height - requestedSize.height) < 0.5)
    }

    @Test func terminalContentSizeIncludesEachPaddingEdge() {
        let terminalSize = NSSize(width: 640, height: 400)
        let padding = TerminalViewPadding(top: 3, left: 5, bottom: 7, right: 11)

        let contentSize = TerminalSessionContainerView.contentSize(
            forTerminalSize: terminalSize,
            padding: padding
        )

        #expect(contentSize.width == 656)
        #expect(contentSize.height == 410)
    }
}
