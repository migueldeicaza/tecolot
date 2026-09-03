import AppKit
import Testing
@testable import Tecolot

@MainActor
struct TerminalWindowAppearanceTests {
    @Test func themedChromeColorsNativeTitlebarWithoutAddingDragOverlay() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.toolbar = NSToolbar(identifier: "TestToolbar")
        window.contentView = NSView()
        window.layoutIfNeeded()

        TerminalWindowAppearance.apply(theme: .fallback, to: window)
        await nextMainQueueTurn()

        let frameView = try #require(window.contentView?.superview)
        let titlebarView = try #require(descendants(in: frameView).first {
            $0.className == "NSTitlebarView"
        })
        #expect(titlebarView.layer?.backgroundColor != nil)
        #expect(!descendants(in: frameView).contains {
            $0.identifier?.rawValue == "TerminalWindowDragHandle"
        })
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
