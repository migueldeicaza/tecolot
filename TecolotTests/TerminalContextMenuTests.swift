import AppKit
import SwiftTerm
import Testing
@testable import Tecolot

@MainActor
struct TerminalContextMenuTests {
    @Test(arguments: [false, true], [false, true])
    func clipboardItemsAndDividerFollowAvailableContent(hasSelection: Bool, hasPaste: Bool) {
        let terminal = AppTerminalView(frame: .zero, font: nil, options: .default)
        terminal.feed(text: "selected text")
        if hasSelection { terminal.selectAll() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(hasPaste ? "paste text" : "", forType: .string)

        let menu = terminal.makeContextMenu(pasteboard: pasteboard)
        var expected: [String] = []
        if hasSelection { expected.append("Copy") }
        if hasPaste { expected.append("Paste") }
        if hasSelection || hasPaste { expected.append("|") }
        expected += ["Split Right", "Split Left", "Split Down", "Split Up", "|", "Reset Terminal"]
        #expect(menu.items.map { $0.isSeparatorItem ? "|" : $0.title } == expected)
        #expect(menu.allowsContextMenuPlugIns)
        #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.target === terminal })
    }

    @Test(arguments: [9, 1000, 1002, 1003])
    func menuFollowsMouseReportingMode(mode: Int) throws {
        let terminal = AppTerminalView(frame: .zero, font: nil, options: .default)
        let rightClick = try mouseEvent(.rightMouseDown)
        let controlClick = try mouseEvent(.leftMouseDown, modifiers: .control)
        #expect(terminal.menu(for: rightClick) != nil)
        #expect(terminal.menu(for: controlClick) != nil)
        #expect(terminal.menu(for: try mouseEvent(.leftMouseDown)) == nil)

        terminal.feed(text: "\u{1b}[?\(mode)h")
        #expect(terminal.menu(for: rightClick) == nil)
        #expect(terminal.menu(for: controlClick) == nil)
        terminal.allowMouseReporting = false
        #expect(terminal.menu(for: rightClick) != nil)
        #expect(terminal.menu(for: controlClick) != nil)
        terminal.allowMouseReporting = true
        #expect(terminal.menu(for: rightClick) == nil)
        terminal.feed(text: "\u{1b}[?\(mode)l")
        #expect(terminal.menu(for: rightClick) != nil)
    }

    @Test(arguments: [false, true])
    func rightClickStillSendsMouseReports(onLink: Bool) async throws {
        let terminal = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: nil, options: .default)
        let window = makeWindow(content: terminal)
        let receiver = ContextMenuInputReceiver()
        terminal.terminalDelegate = receiver
        if onLink {
            terminal.feed(text: "\u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\")
        }
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let point = NSPoint(x: 1, y: terminal.bounds.maxY - 1)
        let modifiers: NSEvent.ModifierFlags = onLink ? .command : []
        terminal.rightMouseDown(with: try mouseEvent(.rightMouseDown, modifiers: modifiers, window: window, point: point))
        terminal.rightMouseUp(with: try mouseEvent(.rightMouseUp, modifiers: modifiers, window: window, point: point))

        let deadline = ContinuousClock.now + .seconds(5)
        let expected = "\u{1b}[<2;1;1M\u{1b}[<2;1;1m"
        while receiver.text != expected && ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(receiver.text == expected)
        #expect(receiver.openedLinks.isEmpty)
        #expect(window.firstResponder === terminal)
    }

    @Test func menuFocusesTheClickedPaneAndActionsTargetIt() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, orientation: .vertical)
        let second = try #require(workspace.focusedController)
        let document = TerminalDocument(content: "")
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = makeWindow(content: host)
        host.synchronize(revision: workspace.revision, document: document)
        host.layoutSubtreeIfNeeded()
        let terminal = try #require(first.terminal as? AppTerminalView)
        #expect(window.makeFirstResponder(second.terminal))
        second.didBecomeFocused()

        let menu = try #require(terminal.menu(for: try mouseEvent(.rightMouseDown, window: window)))
        #expect(window.firstResponder === terminal)
        #expect(workspace.focusedController === first)
        #expect(TerminalSessionRegistry.shared.controller(for: window) === first)
        let item = try #require(menu.items.first { $0.title == "Split Left" })
        #expect(terminal.validateUserInterfaceItem(item))
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(workspace.paneCount == 3)
        #expect(workspace.controllers.last === second)
        #expect(workspace.controllers[1] === first)
        #expect(workspace.focusedController === workspace.controllers.first)
    }

    @Test func resetRestoresMouseModeAndClearsTheScreen() throws {
        let terminal = AppTerminalView(frame: .zero, font: nil, options: .default)
        terminal.feed(text: "text\u{1b}[?1000h")
        let menu = terminal.makeContextMenu()
        let item = try #require(menu.items.first { $0.title == "Reset Terminal" })
        #expect(terminal.validateUserInterfaceItem(item))
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(terminal.currentMouseMode == .off)
        #expect(terminal.menu(for: try mouseEvent(.rightMouseDown)) != nil)
        #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = content
        return window
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = [],
        window: NSWindow? = nil, point: NSPoint = .zero
    ) throws -> NSEvent {
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        // NSEvent.mouseEvent sets buttonNumber to zero for every event type.
        if type == .rightMouseDown || type == .rightMouseUp {
            let cgEvent = try #require(event.cgEvent)
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 1)
            let rightEvent = try #require(NSEvent(cgEvent: cgEvent))
            #expect(rightEvent.buttonNumber == 1)
            return rightEvent
        }
        return event
    }
}

@MainActor
private final class ContextMenuInputReceiver: TerminalViewDelegate {
    private var data: [UInt8] = []
    var text: String { String(decoding: data, as: UTF8.self) }
    var openedLinks: [String] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { self.data.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        openedLinks.append(link)
    }
}

@MainActor
struct TerminalPaneSplitDirectionTests {
    @Test(arguments: [TerminalPaneDirection.right, .left, .down, .up])
    func newPaneAppearsOnTheRequestedSide(direction: TerminalPaneDirection) throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let existing = try #require(workspace.focusedController)
        let document = TerminalDocument(content: "")
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.synchronize(revision: workspace.revision, document: document)
        workspace.split(existing, direction: direction)
        let added = try #require(workspace.focusedController)
        host.synchronize(revision: workspace.revision, document: document)
        host.layoutSubtreeIfNeeded()
        let existingView = try #require(existing.terminal?.superview)
        let addedView = try #require(added.terminal?.superview)
        let existingFrame = existingView.convert(existingView.bounds, to: host)
        let addedFrame = addedView.convert(addedView.bounds, to: host)
        switch direction {
        case .right: #expect(addedFrame.minX > existingFrame.minX)
        case .left: #expect(addedFrame.minX < existingFrame.minX)
        case .down: #expect(addedFrame.minY < existingFrame.minY)
        case .up: #expect(addedFrame.minY > existingFrame.minY)
        }
        #expect(added.profile == existing.profile)
        #expect(added.themeOverride == existing.themeOverride)
    }
}
