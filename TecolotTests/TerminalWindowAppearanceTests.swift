import AppKit
import Testing
@testable import Tecolot

@MainActor
struct TerminalWindowAppearanceTests {
    @Test func themedChromeColorsNativeTitlebarWithoutAddingDragOverlay() async throws {
        let window = makeWindow()

        TerminalWindowAppearance.apply(theme: .fallback, to: window)
        await nextMainQueueTurn()

        let frameView = try #require(window.contentView?.superview)
        #expect(try themedChromeView(in: frameView).layer?.backgroundColor != nil)
        #expect(!descendants(in: frameView).contains {
            $0.identifier?.rawValue == "TerminalWindowDragHandle"
        })
    }

    @Test func removingTheThemeRestoresTheNativeTitlebarBackground() async throws {
        let window = makeWindow()

        TerminalWindowAppearance.apply(theme: .fallback, to: window)
        await nextMainQueueTurn()
        TerminalWindowAppearance.apply(theme: nil, to: window)
        await nextMainQueueTurn()

        let frameView = try #require(window.contentView?.superview)
        #expect(try themedChromeView(in: frameView).layer?.backgroundColor == nil)
        #expect(!descendants(in: frameView).contains {
            $0.className == "NSTitlebarBackgroundView" && $0.isHidden
        })
    }

    /// The titlebar view that `applyBackground` paints, which differs by OS:
    /// macOS 26 colors the inner `NSTitlebarView`, earlier releases color the
    /// container and make the native titlebar transparent.
    private func themedChromeView(in frameView: NSView) throws -> NSView {
        let className = if #available(macOS 26.0, *) {
            "NSTitlebarView"
        } else {
            "NSTitlebarContainerView"
        }
        return try #require(descendants(in: frameView).first { $0.className == className })
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.toolbar = NSToolbar(identifier: "TestToolbar")
        window.contentView = NSView()
        window.layoutIfNeeded()
        return window
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
