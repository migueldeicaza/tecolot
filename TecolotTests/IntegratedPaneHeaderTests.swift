import AppKit
import Testing
@testable import Tecolot

@MainActor
@Suite(.serialized)
struct IntegratedPaneHeaderTests {
    private func makeWindow(_ style: String, panes: Int, compact: Bool = false) throws -> (TerminalWindowManager, TerminalWindowController, TerminalTab, UserDefaults, String) {
        let suite = "IntegratedPaneHeader-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("vertical", forKey: "tabStyle")
        defaults.set(style.hasPrefix("left") ? "left" : "right", forKey: "sidebarPosition")
        defaults.set(style.hasSuffix("hidden"), forKey: "sidebarHidden")
        defaults.set(271, forKey: "sidebarWidth")
        defaults.set(compact ? "compact" : "comfortable", forKey: GlobalAppearanceSettings.paneStyleKey)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let tab = TerminalTab(startsProcesses: false)
        let first = try #require(tab.workspace.focusedController)
        if panes > 1 {
            tab.workspace.split(first, direction: .right)
        }
        if panes > 2 {
            tab.workspace.split(first, direction: .down)
        }
        if panes > 3 {
            tab.workspace.split(try #require(tab.workspace.controllers.last), direction: .down)
        }
        let group = manager.newGroup(tab: tab)
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        manager.makeWindow = nil
        owner.window?.setContentSize(NSSize(width: 1180, height: 760))
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        return (manager, owner, tab, defaults, suite)
    }

    @Test(arguments: ["right", "left-hidden", "right-hidden"], [1, 2, 3, 4])
    func headerVisibilityAndSidebarSpacing(style: String, panes: Int) throws {
        let (manager, owner, tab, defaults, suite) = try makeWindow(style, panes: panes)
        defer {
            manager.closeGroup(owner.group)
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(owner.contentHeader.isHidden)
        #expect(tab.hostView.frame.minY == 8)
        #expect(owner.trafficLightCardID != nil)
        if panes > 1 {
            for card in tab.hostView.visibleCards {
                #expect(card.header.frame.height == 36)
                #expect(card.subviews.first?.layer?.cornerRadius == 10)
                let clip = try #require(card.subviews.first?.layer?.mask as? CAShapeLayer)
                #expect(clip.path == card.layer?.shadowPath)
                #expect(clip.path == card.outlineLayer.path)
            }
        }
        if style == "right" {
            #expect(tab.hostView.frame.maxX == owner.sidebar.frame.minX)
            let cell = owner.sidebar.outline.frameOfCell(atColumn: 0, row: 1)
            #expect(cell.minX == 9)
        }
    }

    @Test(arguments: ["right", "left-hidden", "right-hidden"])
    func compactKeepsItsHeaderAndMetrics(_ style: String) throws {
        let (manager, owner, tab, defaults, suite) = try makeWindow(style, panes: 4, compact: true)
        defer {
            manager.closeGroup(owner.group)
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(!owner.contentHeader.isHidden)
        #expect(owner.trafficLightCardID == nil)
        for card in tab.hostView.visibleCards {
            #expect(card.header.frame.height == 32)
            #expect(card.subviews.first?.layer?.cornerRadius == 0)
        }
    }

    @Test func trafficLightsFollowTheTopLeftCardAcrossZoomClosingAndDividerChanges() async throws {
        let (manager, owner, tab, defaults, suite) = try makeWindow("right", panes: 1)
        defer {
            manager.closeGroup(owner.group)
            defaults.removePersistentDomain(forName: suite)
        }
        let workspace = tab.workspace
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let right = try #require(workspace.focusedController)
        try await settle(owner)
        #expect(owner.trafficLightCardID == first.id)
        workspace.split(first, direction: .down)
        let below = try #require(workspace.focusedController)
        try await settle(owner)
        #expect(owner.trafficLightCardID == first.id)
        workspace.split(right, direction: .down)
        try await settle(owner)
        #expect(owner.trafficLightCardID == first.id)
        workspace.markFocused(right)
        workspace.toggleSplitZoom()
        try await settle(owner)
        #expect(owner.trafficLightCardID == right.id)
        workspace.clearSplitZoom()
        try await settle(owner)
        #expect(owner.trafficLightCardID == first.id)
        #expect(workspace.close(first))
        try await settle(owner)
        #expect(owner.trafficLightCardID == below.id)
        let split = try #require(descendants(tab.hostView).compactMap {
            $0 as? NSSplitView
        }.first)
        split.setPosition(300, ofDividerAt: 0)
        #expect(owner.trafficLightCardID == below.id)
        let card = try #require(tab.hostView.visibleCards.first {
            $0.controller.id == below.id
        })
        #expect(card.windowLeadingInset == 76)
        #expect(card.header.movesWindow)
    }

    @Test(arguments: [false, true])
    func windowBackdropAndAllChromeShareOneColor(dark: Bool) throws {
        let (manager, owner, tab, defaults, suite) = try makeWindow("right", panes: 4)
        defer {
            manager.closeGroup(owner.group)
            defaults.removePersistentDomain(forName: suite)
        }
        let pane = try #require(tab.workspace.focusedController)
        pane.themeOverride = dark ? "Terminal Basic Dark" : "Terminal Basic"
        owner.refreshSidebarPreferences()
        owner.show(owner.group)
        let paint = try #require(owner.chromeBackdrop.paintColor)
        #expect(NSColor(cgColor: paint) == owner.chromeColor)
        #expect(owner.tabBar.usesSharedBackdrop && owner.sidebar.usesSharedBackdrop)
        #expect(owner.tabBar.layer?.backgroundColor == nil)
        #expect(owner.sidebar.layer?.backgroundColor == nil)
        #expect(owner.contentHeader.layer?.backgroundColor == nil)
        #expect(tab.hostView.usesWindowBackdrop)
        #expect(PaneCardGeometry.radius == 10)
        #expect(GlobalAppearanceSettings.PaneStyle.comfortable.headerHeight == 36)
        #expect(GlobalAppearanceSettings.PaneStyle.compact.headerHeight == 32)
    }

    @Test(arguments: ["left", "right"])
    func sidebarSpacingComesFromTheRowInsets(_ style: String) throws {
        let (manager, owner, tab, defaults, suite) = try makeWindow(style, panes: 4)
        defer {
            manager.closeGroup(owner.group)
            defaults.removePersistentDomain(forName: suite)
        }
        let root = try #require(owner.window?.contentView)
        let frames = tab.hostView.visibleCards.map {
            $0.convert($0.bounds, to: root)
        }
        let union = frames.reduce(NSRect.null) {
            $0.union($1)
        }
        #expect(style == "right" ? union.maxX == owner.sidebar.frame.minX : union.minX == owner.sidebar.frame.maxX)
        let outline = owner.sidebar.outline
        let frame = outline.frameOfCell(atColumn: 0, row: 1)
        #expect(frame.minX == 9 && frame.maxX == 262)
        let cell = try #require(outline.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let item = try #require(descendants(cell).compactMap {
            $0 as? TabItemView
        }.first)
        let glyph = item.icon
        let glyphFrame = glyph.convert(glyph.bounds, to: owner.sidebar)
        #expect(abs(glyphFrame.minX - 18) < 0.1)
    }

    @Test func outlinesFollowTabVisibilityWithoutClippingAtDividerEdges() async throws {
        let (manager, owner, tab, defaults, suite) = try makeWindow("right", panes: 4)
        defer {
            manager.closeGroup(owner.group)
            defaults.removePersistentDomain(forName: suite)
        }
        let card = try #require(tab.hostView.visibleCards.first)
        let canvas = try #require(card.outlineLayer.superlayer)
        #expect(canvas !== card.layer)
        #expect(canvas.sublayers?.count == 4)
        let replacement = TerminalTab(startsProcesses: false)
        manager.addTab(replacement, to: owner.group)
        manager.select(replacement, in: owner.group)
        try await settle(owner)
        #expect(canvas.sublayers?.count == 1)
        #expect(card.outlineLayer.superlayer === card.layer)
        card.refreshAppearance()
        card.layoutSubtreeIfNeeded()
        #expect(card.outlineLayer.superlayer === card.layer)
        manager.select(tab, in: owner.group)
        try await settle(owner)
        #expect(card.outlineLayer.superlayer === canvas)
        #expect(canvas.sublayers?.count == 4)
    }

    @Test func integratedHeaderCapturesTheNativeTitlebarPointerBeforeMouseDown() throws {
        let (manager, owner, tab, defaults, suite) = try makeWindow("right", panes: 4)
        defer {
            manager.closeGroup(owner.group)
            defaults.removePersistentDomain(forName: suite)
        }
        let window = try #require(owner.window as? TerminalWindow)
        let card = try #require(tab.hostView.visibleCards.first {
            $0.controller.id == owner.trafficLightCardID
        })
        window.updateTabPointer(at: card.header.convert(NSPoint(x: 300, y: 18), to: nil))
        #expect(!window.isMovable)
        window.updateTabPointer(at: card.content.convert(NSPoint(x: 100, y: 100), to: nil))
        #expect(window.isMovable)
    }

    @Test func integratedHeaderDoubleClickReachesTheSystemZoomAction() async throws {
        let (manager, owner, tab, defaults, suite) = try makeWindow("right", panes: 4)
        let standard = UserDefaults.standard
        let domain = try #require(Bundle.main.bundleIdentifier)
        let oldAction = standard.persistentDomain(forName: domain)?["AppleActionOnDoubleClick"]
        defer {
            if let oldAction {
                standard.set(oldAction, forKey: "AppleActionOnDoubleClick")
            } else {
                standard.removeObject(forKey: "AppleActionOnDoubleClick")
            }
            manager.closeGroup(owner.group)
            defaults.removePersistentDomain(forName: suite)
        }
        standard.set("Maximize", forKey: "AppleActionOnDoubleClick")
        let window = try #require(owner.window)
        window.orderBack(nil)
        try await settle(owner)
        let card = try #require(tab.hostView.visibleCards.first {
            $0.controller.id == owner.trafficLightCardID
        })
        let location = card.header.convert(NSPoint(x: 300, y: 18), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1
        ))
        let before = window.frame
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(350))
        #expect(window.frame != before)
    }

    @Test func transparentCardsDoNotCompositeTheChromeBehindTheirFill() throws {
        let (manager, owner, tab, defaults, suite) = try makeWindow("right", panes: 4)
        defer {
            manager.closeGroup(owner.group)
            defaults.removePersistentDomain(forName: suite)
        }
        let pane = try #require(tab.workspace.focusedController)
        var profile = pane.profile
        profile.backgroundOpacity = 0.5
        pane.applyProfile(profile)
        owner.show(owner.group)
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(owner.window?.isOpaque == false)
        #expect(owner.chromeBackdrop.paintColor?.alpha == 0.5)
        #expect(owner.chromeBackdrop.excludedCardFrames.count == 1)
        let card = try #require(tab.hostView.visibleCards.first {
            $0.controller.id == pane.id
        })
        #expect(card.subviews.first?.layer?.backgroundColor == NSColor.clear.cgColor)
    }

    private func settle(_ owner: TerminalWindowController) async throws {
        try await Task.sleep(for: .milliseconds(30))
        owner.window?.contentView?.needsLayout = true
        owner.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
