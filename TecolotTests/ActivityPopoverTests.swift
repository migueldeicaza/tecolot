import AppKit
import Testing
import TecolotWire
@testable import Tecolot

@MainActor
@Suite(.serialized)
struct ActivityPopoverTests {
    private func entry(_ title: String, state: ProgramStatusState = .working, group: UUID = UUID(), tab: UUID = UUID()) -> ActivityEntry {
        let record = TabStatus.Record(paneID: UUID(), value: WireProgramStatus(state: state, app: "review-tool", message: "Checking café output", reportTime: 1), unseen: true)
        return ActivityEntry(tabID: tab, groupID: group, title: title, subtitle: "Checking café output", source: "Build group › \(title) › remote pane", status: TabStatus.reduce([record]))
    }

    @Test func filterMatchesWordsAcrossAllVisibleAndAccessibleFields() {
        let value = entry("Compile")
        #expect(value.matches("COMPILE"))
        #expect(value.matches("cafe build"))
        #expect(value.matches("remote review-tool"))
        #expect(value.matches("  \n\t"))
        #expect(!value.matches("compile missing"))
        #expect(!value.matches("different"))
    }

    @Test func emptyStateIsCenteredAboveAnInsetFilter() {
        let layout = ActivityPopoverLayout(sectionCounts: [])
        #expect(layout.height == 141)
        #expect(layout.emptyFrame.midX == 150)
        #expect(layout.emptyFrame.midY == layout.listFrame.midY)
        #expect(layout.emptyFrame.minX == 21 && layout.emptyFrame.maxX == 279)
        #expect(layout.filterFrame == NSRect(x: 5, y: 106, width: 290, height: 30))
        #expect(layout.filterFrame.maxY == layout.height - 5)
        #expect(layout.emptyFrame.maxY < layout.filterFrame.minY)
    }

    @Test func populatedGeometryFollowsSectionsAndCapsTheScrollArea() {
        #expect(ActivityPopoverLayout(sectionCounts: [1]).height == 116)
        #expect(ActivityPopoverLayout(sectionCounts: [2]).height == 162)
        #expect(ActivityPopoverLayout(sectionCounts: [1, 1]).height == 194)
        let crowded = ActivityPopoverLayout(sectionCounts: [20, 10])
        #expect(crowded.height == 536)
        #expect(crowded.listHeight > crowded.listFrame.height)
        #expect(crowded.filterFrame.maxY == crowded.height - 5)
    }

    @Test func filterEditingRetainsArrowReturnAndEscapeRouting() throws {
        let suite = "ActivityKeys-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("horizontal", forKey: ProgramActivityPreferences.tabStyleKey)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        let first = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: first) as? TerminalWindowController)
        manager.makeWindow = nil
        let targetTab = TerminalTab(startsProcesses: false)
        let target = manager.newGroup(tab: targetTab)
        let popup = ActivityPopover()
        defer {
            popup.dismiss()
            manager.closeGroup(target)
            manager.closeGroup(first)
        }
        let anchor = owner.tabBar.activityButton
        owner.window?.orderBack(nil)
        popup.toggle(relativeTo: anchor, owner: owner)
        popup.configure(entries: [entry("Alpha", group: first.id, tab: first.tabs[0].id), entry("Beta", group: target.id, tab: targetTab.id)])
        let window = try #require(popup.filterField.window)
        #expect(window.makeFirstResponder(popup.filterField))
        let editor = try #require(popup.filterField.currentEditor() as? NSTextView)
        func key(_ code: UInt16, _ text: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        #expect(ActivityNavigation.acceptsKeyEvent(try key(125, ""), popoverWindow: window, ownerWindow: owner.window))
        #expect(popup.handleKey(try key(125, "")))
        #expect(popup.selectedIndex == 1)
        #expect(window.firstResponder === editor)
        #expect(!popup.handleKey(try key(0, "a")))
        popup.filterField.stringValue = "Beta"
        popup.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: popup.filterField))
        #expect(popup.selectedIndex == 0)
        #expect(popup.handleKey(try key(53, "\u{1b}")))
        #expect(popup.isShown)
        #expect(popup.filterField.stringValue.isEmpty)
        #expect(popup.handleKey(try key(125, "")))
        #expect(popup.handleKey(try key(36, "\r")))
        #expect(!popup.isShown)
        #expect(owner.group === target)
        #expect(!anchor.isChromeActive)
    }

    @Test func activityToggleRestoresTheOpenerOnEveryDismissal() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        let anchor = ChromeIconButton(treatment: .toolbar)
        anchor.frame = NSRect(x: 100, y: 100, width: 35, height: 32)
        anchor.setAccessibilityLabel("Activity")
        owner.window?.contentView?.addSubview(anchor)
        owner.window?.orderBack(nil)
        let popup = ActivityPopover()
        defer {
            popup.dismiss()
            manager.closeGroup(group)
        }
        popup.toggle(relativeTo: anchor, owner: owner)
        #expect(popup.isShown && anchor.isChromeActive)
        popup.toggle(relativeTo: anchor, owner: owner)
        #expect(!popup.isShown && !anchor.isChromeActive)
        popup.toggle(relativeTo: anchor, owner: owner)
        popup.dismiss()
        #expect(!popup.isShown && !anchor.isChromeActive)
        #expect(anchor.accessibilityLabel() == "Activity")
        #expect(anchor.highlightDiameter == 32)
    }

    @Test func bothCustomPanelsMaskTheirBehindWindowBlur() throws {
        let popup = ActivityPopover()
        popup.loadViewIfNeeded()
        #expect(popup.view.layer?.cornerRadius == ActivityPopoverLayout.radius)
        #expect(popup.view.layer?.masksToBounds == true)
        if #available(macOS 26, *) {
            let glass = try #require(popup.view.subviews.compactMap {
                $0 as? NSGlassEffectView
            }.first)
            #expect(glass.cornerRadius == ActivityPopoverLayout.radius)
            #expect(glass.contentView != nil)
        }
        let switcher = GroupSwitcherPanel()
        let groups = try #require(switcher.contentView as? NSVisualEffectView)
        var materials = [groups]
        if
            let fallback = popup.view.subviews.compactMap({
                $0 as? NSVisualEffectView
            }).first {
            materials.append(fallback)
        }
        for material in materials {
            let mask = try #require(material.maskImage)
            let data = try #require(mask.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
            #expect(try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).alphaComponent == 1)
            #expect(mask.resizingMode == .stretch)
            #expect(mask.capInsets.left > 0)
        }
    }
}
