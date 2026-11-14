import AppKit
import Testing
@testable import Tecolot

@MainActor
@Suite(.serialized)
struct PaneCardSpacingTests {
    @Test(
        arguments: ["above", "left", "right", "left-hidden", "right-hidden"],
        ["2v", "2h", "3v", "3h", "3nested", "4v", "4h", "4grid", "4nested", "4zoom"]
    )
    func cardsMatchMeasuredRexInsetsAndDividerGaps(style: String, topology: String) throws {
        let suite = "PaneCardSpacing-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(style == "above" ? "horizontal" : "vertical", forKey: ProgramActivityPreferences.tabStyleKey)
        defaults.set(style.hasPrefix("right") ? "right" : "left", forKey: SidebarPreferences.positionKey)
        defaults.set(style.hasSuffix("hidden"), forKey: SidebarPreferences.hiddenKey)
        defaults.set(271, forKey: SidebarPreferences.widthKey)
        defaults.set("comfortable", forKey: GlobalAppearanceSettings.paneStyleKey)
        defaults.set(true, forKey: GlobalAppearanceSettings.showPaneHeadersKey)
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        let count = try #require(Int(topology.prefix(1)))
        let horizontal = topology.hasSuffix("h")
        workspace.split(first, orientation: horizontal ? .horizontal : .vertical)
        let second = try #require(workspace.focusedController)
        if topology.contains("nested") || topology.contains("grid") || topology.contains("zoom") {
            workspace.split(first, orientation: .horizontal)
            if count == 4 {
                workspace.split(second, orientation: topology.contains("nested") ? .vertical : .horizontal)
            }
        } else if count > 2 {
            for _ in 2..<count {
                workspace.split(try #require(workspace.focusedController), orientation: horizontal ? .horizontal : .vertical)
            }
        }
        if topology.contains("zoom") {
            workspace.toggleSplitZoom()
        }
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { manager.makeWindow = nil }
        let tab = TerminalTab(workspace: workspace)
        let group = manager.newGroup(tab: tab)
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        let window = try #require(owner.window)
        for size in [NSSize(width: 1180, height: 760), NSSize(width: 1080, height: 700)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            tab.hostView.layoutSubtreeIfNeeded()
            let root = try #require(window.contentView)
            // Rex starts cards at y=46 Above and y=8 beside or over a sidebar.
            let left: CGFloat = style == "left" ? 271 : 8
            let right: CGFloat = style == "right" ? 271 : 8
            let top: CGFloat = style == "above" ? 46 : 8
            let expected = NSRect(x: left, y: top, width: size.width - left - right, height: size.height - top - 8)
            let cards = descendants(tab.hostView).compactMap {
                $0 as? TerminalPaneCardView
            }
            #expect(cards.count == (topology.contains("zoom") ? 1 : count))
            let frames = cards.map {
                $0.convert($0.bounds, to: root)
            }
            let union = frames.reduce(NSRect.null) {
                $0.union($1)
            }
            #expect(abs(union.minX - expected.minX) < 0.1)
            #expect(abs(union.minY - expected.minY) < 0.1)
            #expect(abs(union.maxX - expected.maxX) < 0.1)
            #expect(abs(union.maxY - expected.maxY) < 0.1)
            for (index, frame) in frames.enumerated() {
                for other in frames.dropFirst(index + 1) {
                    #expect(frame.intersection(other).isEmpty)
                }
            }
            for split in descendants(tab.hostView).compactMap({
                $0 as? NSSplitView
            }) {
                #expect(split.dividerThickness == 8)
                let a = split.arrangedSubviews[0].frame
                let b = split.arrangedSubviews[1].frame
                #expect(abs((split.isVertical ? b.minX - a.maxX : b.minY - a.maxY) - 8) < 0.1)
                // Fractions may change during a drag, but the gap must not.
                let length = split.isVertical ? split.bounds.width : split.bounds.height
                split.setPosition((length - 8) * 0.6, ofDividerAt: 0)
                let movedA = split.arrangedSubviews[0].frame
                let movedB = split.arrangedSubviews[1].frame
                #expect(abs((split.isVertical ? movedB.minX - movedA.maxX : movedB.minY - movedA.maxY) - 8) < 0.1)
            }
        }
    }

    @Test func standaloneInsetsClampSmallBounds() {
        let bounds = NSRect(x: 0, y: 0, width: 100, height: 80)
        #expect(TerminalPaneCardInsets.window.frame(in: bounds) == bounds)
        #expect(TerminalPaneCardInsets.uniform(8).frame(in: bounds) == NSRect(x: 8, y: 8, width: 84, height: 64))
        let tiny = TerminalPaneCardInsets.uniform(8).frame(in: NSRect(x: 0, y: 0, width: 3, height: 2))
        #expect(tiny.width == 0 && tiny.height == 0)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
