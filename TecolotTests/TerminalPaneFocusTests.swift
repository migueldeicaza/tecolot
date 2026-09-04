import AppKit
import Testing
@testable import Tecolot

@MainActor
struct TerminalPaneFocusTests {
    @Test func mouseClickFocusesTheClickedPane() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let firstController = try #require(workspace.focusedController)
        workspace.split(firstController, orientation: .vertical)
        let secondController = try #require(workspace.focusedController)
        let document = TerminalDocument(content: "")
        let hostView = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision, document: document)
        hostView.layoutSubtreeIfNeeded()

        let firstTerminal = try #require(firstController.terminal as? AppTerminalView)
        let secondTerminal = try #require(secondController.terminal as? AppTerminalView)
        #expect(window.makeFirstResponder(secondTerminal))
        secondController.didBecomeFocused()
        #expect(workspace.focusedController === secondController)

        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: firstTerminal.convert(NSPoint(x: 1, y: 1), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        firstTerminal.mouseDown(with: click)

        #expect(window.firstResponder === firstTerminal)
        #expect(workspace.focusedController === firstController)
        #expect(TerminalSessionRegistry.shared.controller(for: window) === firstController)
    }
}
