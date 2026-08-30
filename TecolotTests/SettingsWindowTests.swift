import AppKit
import Testing
@testable import Tecolot

@MainActor
struct SettingsWindowTests {
    private final class FocusedView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test func escapeClosesSettingsWithAControlAsFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let focusedView = FocusedView()
        window.contentView = focusedView
        window.makeFirstResponder(focusedView)

        let coordinator = SettingsEscapeKeyHandler.Coordinator()
        coordinator.window = window
        var didRequestClose = false
        coordinator.closeWindow = { _ in
            didRequestClose = true
        }
        coordinator.startMonitoring()
        defer {
            coordinator.stopMonitoring()
        }

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        )!
        NSApp.sendEvent(event)

        #expect(didRequestClose)
        #expect(window.firstResponder === focusedView)
    }
}
