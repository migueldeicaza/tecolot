import AppKit
import Testing
@testable import Tecolot

@MainActor
struct TerminalPaneZoomTests {
    @Test func zoomToggleKeepsThePaneTreeAndTerminalViews() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, orientation: .vertical)
        let second = try #require(workspace.focusedController)
        let document = TerminalDocument(content: "")
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.synchronize(revision: workspace.revision, document: document)
        host.layoutSubtreeIfNeeded()

        let firstTerminal = try #require(first.terminal)
        let secondTerminal = try #require(second.terminal)
        let splitView = try #require(host.subviews.first as? NSSplitView)
        splitView.setPosition(180, ofDividerAt: 0)
        splitView.adjustSubviews()
        let firstWidth = splitView.arrangedSubviews[0].frame.width

        workspace.toggleSplitZoom()
        host.synchronize(revision: workspace.revision, document: document)
        #expect(workspace.zoomedControllerID == second.id)
        #expect(workspace.paneCount == 2)
        #expect(host.subviews.first is TerminalSessionContainerView)
        #expect(first.terminal === firstTerminal)
        #expect(second.terminal === secondTerminal)

        workspace.toggleSplitZoom()
        host.synchronize(revision: workspace.revision, document: document)
        host.layoutSubtreeIfNeeded()
        let restoredSplit = try #require(host.subviews.first as? NSSplitView)
        #expect(workspace.zoomedControllerID == nil)
        #expect(abs(restoredSplit.arrangedSubviews[0].frame.width - firstWidth) < 2)
        #expect(first.terminal === firstTerminal)
        #expect(second.terminal === secondTerminal)
    }

    @Test func navigationAndChangesKeepZoomOnTheVisiblePane() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, orientation: .vertical)
        let second = try #require(workspace.focusedController)

        workspace.toggleSplitZoom()
        workspace.selectPreviousSplit()
        #expect(workspace.zoomedControllerID == first.id)
        #expect(workspace.focusedController === first)

        workspace.split(first, orientation: .horizontal)
        let third = try #require(workspace.focusedController)
        #expect(workspace.zoomedControllerID == third.id)
        #expect(workspace.paneCount == 3)

        workspace.close(third)
        #expect(workspace.zoomedControllerID == nil)
        #expect(workspace.paneCount == 2)
        #expect(workspace.controllers.contains { $0 === second })
    }

    @Test func tabIndicatorClearsZoomWhenClicked() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, orientation: .vertical)
        workspace.toggleSplitZoom()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        TerminalSplitZoomTitlebar.configure(window, workspace: workspace)
        let button = try #require(window.tab.accessoryView as? NSButton)
        #expect(!button.isHidden)
        button.performClick(nil)
        #expect(workspace.zoomedControllerID == nil)

        TerminalSplitZoomTitlebar.configure(window, workspace: workspace)
        #expect(button.isHidden)
    }

    @Test func closingAPaneKeepsTheSurvivingSplitPosition() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, orientation: .vertical)
        let second = try #require(workspace.focusedController)
        workspace.split(second, orientation: .horizontal)
        let document = TerminalDocument(content: "")
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.synchronize(revision: workspace.revision, document: document)
        host.layoutSubtreeIfNeeded()

        let outer = try #require(host.subviews.first as? NSSplitView)
        let inner = try #require(outer.arrangedSubviews[1] as? NSSplitView)
        outer.setPosition(120, ofDividerAt: 0)
        inner.setPosition(320, ofDividerAt: 0)
        outer.adjustSubviews()
        inner.adjustSubviews()
        let originalFraction = inner.arrangedSubviews[0].frame.height
            / (inner.bounds.height - inner.dividerThickness)

        workspace.close(first)
        host.synchronize(revision: workspace.revision, document: document)
        host.layoutSubtreeIfNeeded()
        let surviving = try #require(host.subviews.first as? NSSplitView)
        let restoredFraction = surviving.arrangedSubviews[0].frame.height
            / (surviving.bounds.height - surviving.dividerThickness)
        #expect(abs(restoredFraction - originalFraction) < 0.02)
    }

    @Test func closingTheOtherPaneClearsZoomWhenOnePaneRemains() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, orientation: .vertical)
        let second = try #require(workspace.focusedController)
        workspace.markFocused(first)
        workspace.toggleSplitZoom()
        #expect(workspace.zoomedControllerID == first.id)

        workspace.close(second)
        #expect(workspace.paneCount == 1)
        #expect(workspace.zoomedControllerID == nil)

        workspace.split(first, orientation: .horizontal)
        #expect(workspace.zoomedControllerID == nil)
    }
}
