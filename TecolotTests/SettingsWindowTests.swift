import AppKit
import Testing
@testable import Tecolot

@MainActor
struct SettingsWindowTests {
    private final class FocusedView: NSView {
        override var acceptsFirstResponder: Bool {
            true
        }
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

        let coordinator = SettingsKeyHandler.Coordinator()
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

    private func keyDown(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// Sends Escape to a window whose first responder is the editor of a
    /// search field or of a plain text field. Returns true when Settings
    /// asked to close.
    private func escapeCloses(fromFieldOfType type: NSTextField.Type, text: String) -> Bool {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let field = type.init(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        field.stringValue = text
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)

        let coordinator = SettingsKeyHandler.Coordinator()
        coordinator.window = window
        var closed = false
        coordinator.closeWindow = { _ in
            closed = true
        }
        coordinator.startMonitoring()
        defer {
            coordinator.stopMonitoring()
        }
        NSApp.sendEvent(keyDown("\u{1B}", keyCode: 53, modifiers: [], in: window))
        return closed
    }

    @Test func escapeClosesSettingsFromAnEmptySearchField() {
        #expect(escapeCloses(fromFieldOfType: NSSearchField.self, text: ""))
    }

    @Test func escapeLeavesATypedQueryToTheSearchField() {
        #expect(!escapeCloses(fromFieldOfType: NSSearchField.self, text: "font"))
    }

    @Test func escapeLeavesOtherTextFieldsAlone() {
        #expect(!escapeCloses(fromFieldOfType: NSTextField.self, text: ""))
        #expect(!escapeCloses(fromFieldOfType: NSTextField.self, text: "font"))
    }

    @Test func commandFStartsASearchOnlyInTheSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let other = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        other.isReleasedWhenClosed = false
        let coordinator = SettingsKeyHandler.Coordinator()
        coordinator.window = window
        var focused = 0
        var closed = false
        coordinator.focusSearch = {
            focused += 1
        }
        coordinator.closeWindow = { _ in
            closed = true
        }
        coordinator.startMonitoring()
        defer {
            coordinator.stopMonitoring()
        }
        NSApp.sendEvent(keyDown("f", keyCode: 3, modifiers: .command, in: other))
        #expect(focused == 0)
        NSApp.sendEvent(keyDown("f", keyCode: 3, modifiers: [.command, .shift], in: window))
        #expect(focused == 0)
        NSApp.sendEvent(keyDown("f", keyCode: 3, modifiers: .command, in: window))
        #expect(focused == 1)
        NSApp.sendEvent(keyDown("F", keyCode: 3, modifiers: [.command, .capsLock], in: window))
        #expect(focused == 2)
        #expect(!closed)
    }

    @Test func closingTheWindowTellsTheSettingsView() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let observer = SettingsWindowCloseObserver.ObserverView()
        var closes = 0
        observer.windowWillClose = {
            closes += 1
        }
        window.contentView?.addSubview(observer)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(closes == 1)
    }
}
