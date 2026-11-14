import AppKit
import Testing
@testable import Tecolot

@MainActor
@Suite(.serialized)
struct PaneHeaderPreferencesTests {
    @Test(arguments: ["above", "left", "right", "left-hidden", "right-hidden"], [true, false])
    func singleAndSplitCardsRespectTheHeaderPreference(style: String, enabled: Bool) async throws {
        let suite = "PaneHeaders-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(style == "above" ? "horizontal" : "vertical", forKey: ProgramActivityPreferences.tabStyleKey)
        defaults.set(style.hasPrefix("right") ? "right" : "left", forKey: SidebarPreferences.positionKey)
        defaults.set(style.hasSuffix("hidden"), forKey: SidebarPreferences.hiddenKey)
        defaults.set(enabled, forKey: GlobalAppearanceSettings.showPaneHeadersKey)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        let tab = TerminalTab(startsProcesses: false)
        let group = manager.newGroup(tab: tab)
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        manager.makeWindow = nil
        defer { manager.closeGroup(group) }
        let window = try #require(owner.window)
        window.setContentSize(NSSize(width: 1180, height: 760))
        let forced = style == "right" || style.hasSuffix("hidden")
        let pane = try #require(tab.workspace.focusedController)
        for count in [1, 2, 3, 4] {
            if count > 1 {
                tab.workspace.split(try #require(tab.workspace.focusedController), direction: count == 3 ? .down : .right)
                owner.show(group)
            }
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(tab.hostView.cardsEnabled)
            #expect(tab.hostView.visibleCards.count == count)
            #expect(owner.contentHeader.isHidden)
            for card in tab.hostView.visibleCards {
                #expect(card.header.isHidden == !(enabled || forced))
                #expect(card.header.frame.height == (enabled || forced ? 36 : 0))
                #expect(card.subviews.first?.layer?.cornerRadius == 10)
            }
        }
        defaults.set(!enabled, forKey: GlobalAppearanceSettings.showPaneHeadersKey)
        let surface = try #require(pane.surface)
        #expect(window.makeFirstResponder(surface))
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        try await Task.sleep(for: .milliseconds(50))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(tab.hostView.showsPaneHeaders == (!enabled || forced))
        #expect(tab.workspace.controllers.contains {
            $0 === pane
        })
        #expect(window.firstResponder === surface)
    }

    @Test func headerlessCompactKeepsTheFocusedPaneVisible() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        workspace.split(try #require(workspace.focusedController), direction: .right)
        let host = TerminalPaneHostView(workspace: workspace)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        host.synchronize(revision: workspace.revision, settings: .init(paneCardsEnabled: false, paneStyle: .compact))
        host.layoutSubtreeIfNeeded()
        #expect(host.visibleCards.allSatisfy {
            $0.header.isHidden
        })
        let focused = try #require(host.visibleCards.first {
            $0.controller.id == workspace.focusedControllerID
        })
        #expect(focused.outlineLayer.lineWidth == 2)
        #expect(focused.outlineLayer.strokeColor == NSColor.controlAccentColor.cgColor)
        #expect(focused.subviews.first?.layer?.cornerRadius == 0)
    }

    @Test func shippedHeaderPreferenceKeepsItsKeyAndValue() throws {
        let suite = "PaneHeaderStorage-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(GlobalAppearanceSettings(defaults: defaults).paneCardsEnabled)
        #expect(GlobalAppearanceSettings.showPaneHeadersKey == "paneCardsEnabled")
        defaults.set(false, forKey: "paneCardsEnabled")
        defaults.set("compact", forKey: GlobalAppearanceSettings.paneStyleKey)
        let value = GlobalAppearanceSettings(defaults: defaults)
        #expect(!value.paneCardsEnabled)
        #expect(value.paneStyle == .compact)
    }

    @Test func selectorDismissalSuppressesOnlyTheSamePointerEvent() {
        var dismissal = GroupSwitcherDismissal()
        #expect(!dismissal.suppresses(pointerTimestamp: 10))
        dismissal.record(pointerTimestamp: 10)
        #expect(dismissal.suppresses(pointerTimestamp: 10))
        #expect(!dismissal.suppresses(pointerTimestamp: 11))
        #expect(!dismissal.suppresses(pointerTimestamp: nil))
        dismissal.record(pointerTimestamp: nil)
        #expect(!dismissal.suppresses(pointerTimestamp: nil))
    }

    @Test(arguments: ["", "typed group"])
    func filterTextAndPlaceholderNeverOverlapTheMagnifier(_ text: String) throws {
        let panel = GroupSwitcherPanel()
        panel.configure(model: GroupSwitcherModel(groups: [.init(id: UUID(), name: "A")], filter: text))
        let cell = try #require(panel.filterField.cell as? GroupFilterCell)
        #expect(panel.filterField.isEditable)
        #expect(panel.filterField.isSelectable)
        let bounds = panel.filterField.bounds
        let icon = cell.searchButtonRect(forBounds: bounds)
        let title = cell.searchTextRect(forBounds: bounds)
        #expect(icon.minX == 9)
        #expect(title.minX == 33)
        #expect(title.minX - icon.maxX == 10)
        #expect(text.isEmpty || title.maxX < cell.cancelButtonRect(forBounds: bounds).minX)
        #expect((panel.filterField.placeholderAttributedString?.attribute(.baselineOffset, at: 0, effectiveRange: nil)) == nil)
        panel.orderBack(nil)
        defer { panel.orderOut(nil) }
        #expect(panel.makeFirstResponder(panel.filterField))
        let editor = try #require(panel.filterField.currentEditor())
        let editorRect = editor.convert(editor.bounds, to: panel.filterField)
        #expect(abs(editorRect.minX - title.minX) <= 1)
        #expect(abs(editorRect.minY - title.minY) <= 1)
    }

    @Test func popupSectionsHaveRealSeparatorViews() throws {
        let panel = GroupSwitcherPanel()
        panel.configure(model: GroupSwitcherModel(groups: [.init(id: UUID(), name: "A")], filter: ""))
        panel.contentView?.layoutSubtreeIfNeeded()
        let rows = (0..<panel.table.numberOfRows).compactMap {
            panel.table.rowView(atRow: $0, makeIfNecessary: true)
        }
        rows.forEach {
            $0.layoutSubtreeIfNeeded()
        }
        let lines = (rows.flatMap(\.subviews) + (panel.contentView?.subviews ?? [])).compactMap {
            $0 as? NSBox
        }.filter {
            !$0.isHidden
        }
        #expect(lines.count == 2)
        #expect(lines.contains {
            $0.frame.width == panel.contentView?.bounds.width
        })
    }

    @Test func groupSelectorUsesMeasuredTypographyAndLeadingInsets() throws {
        let bar = HorizontalTabBarView()
        let button = bar.groupButton
        let font = try #require(button.font)
        #expect(font.pointSize == 13)
        #expect(button.alignment == .left)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        let cell = try #require(button.cell as? GroupSelectorCell)
        #expect(cell.imageRect(forBounds: NSRect(x: 0, y: 0, width: 134, height: 36)).minX == 10.5)
        #expect(cell.titleRect(forBounds: NSRect(x: 0, y: 0, width: 134, height: 36)).minX == 36)
    }

    @Test func shortSelectorNamesPaintAtTheLeadingInsetRatherThanTheCenter() throws {
        let bar = HorizontalTabBarView()
        let button = bar.groupButton
        button.title = "M11"
        button.isBordered = false
        button.appearance = NSAppearance(named: .aqua)
        button.frame = NSRect(x: 0, y: 0, width: 105, height: 36)
        let bitmap = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / button.bounds.width
        let columns = (Int(34 * scale)..<bitmap.pixelsWide).filter { x in
            (Int(8 * scale)..<Int(28 * scale)).contains { y in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    return false
                }
                return color.alphaComponent > 0.5 && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.5
            }
        }
        let firstInk = CGFloat(try #require(columns.first)) / scale
        #expect((36...39).contains(firstInk))

    }
}
