import AppKit
import Testing
@testable import Tecolot

@MainActor
struct SafeModeWindowTests {
    @Test func explanationAndKeyboardActionStayVisibleUntilTheGroupStarts() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let saved = RestoreTab(root: .pane(RestorePane(id: UUID(), kind: .local)))
        let tab = TerminalTab(
            dormant: RestoreStore.launchSpec(for: RestoredTab(tab: saved, panes: [:])),
            startsProcesses: false
        )
        let group = manager.newGroup(tab: tab)
        let owner = try #require(manager.openWindow(group: group, startsGroup: false) as? TerminalWindowController)
        let window = try #require(owner.window)
        defer { manager.closeGroup(group) }
        let content = try #require(window.contentView)
        let explanation = try #require(content.subviews.compactMap {
            $0 as? NSTextField
        }.first {
            $0.stringValue.contains("did not finish starting")
        })
        let button = try #require(content.subviews.compactMap {
            $0 as? NSButton
        }.first {
            $0.title == "Start Group"
        })
        #expect(explanation.stringValue.contains("Your groups are kept"))
        #expect(button.accessibilityLabel() == "Start Group")
        #expect(button.keyEquivalent == "\r")
        #expect(window.initialFirstResponder === button)
        #expect(tab.isDormant)
        for width in [420.0, 900.0] {
            window.setContentSize(NSSize(width: width, height: 360))
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()
            #expect(explanation.frame.height > 0)
            #expect(explanation.frame.maxY < button.frame.minY)
            #expect(content.bounds.contains(explanation.frame))
            #expect(content.bounds.contains(button.frame))
        }
        // Exercise the Return key equivalent without ordering the window in.
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        #expect(button.performKeyEquivalent(with: event))
        #expect(!tab.isDormant)
        #expect(explanation.superview == nil && button.superview == nil)
        #expect(window.initialFirstResponder !== button)
    }
}

@MainActor
struct TerminalWindowCommandTargetTests {
    @Test func dormantTerminalWindowRemainsANewItemTarget() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let tab = TerminalTab(dormant: LaunchSpec(), startsProcesses: false)
        let group = manager.newGroup(tab: tab)
        let owner = try #require(manager.openWindow(group: group, startsGroup: false) as? TerminalWindowController)
        let window = try #require(owner.window)
        defer { manager.closeGroup(group) }
        #expect(WindowOpener.frontTerminalWindow(in: [window]) === window)
        #expect(TerminalWindowCommandTarget.resolve(keyWindow: window, mainWindow: nil, manager: manager)?.terminal === owner)
        #expect(tab.loadedWorkspace == nil && tab.isDormant)
    }

    @Test func closeSelectedDormantTabAndLastWindowWithoutStarting() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let first = TerminalTab(dormant: LaunchSpec(), startsProcesses: false)
        let second = TerminalTab(dormant: LaunchSpec(), startsProcesses: false)
        let group = manager.newGroup(tab: first)
        manager.addTab(second, to: group)
        let owner = try #require(manager.openWindow(group: group, startsGroup: false) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        owner.requestCloseSelectedPane()
        #expect(group.tabs.count == 1 && group.selectedTab === first)
        #expect(manager.windows.count == 1)
        #expect(first.loadedWorkspace == nil && second.loadedWorkspace == nil)
        owner.requestCloseSelectedPane()
        #expect(manager.windows.isEmpty && manager.groups.isEmpty)
        #expect(first.loadedWorkspace == nil && second.loadedWorkspace == nil)
    }

    @Test func auxiliaryKeyWindowBlocksTheTerminalMainWindow() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        let auxiliary = NSWindow()
        let target = try #require(TerminalWindowCommandTarget.resolve(keyWindow: auxiliary, mainWindow: owner.window, manager: manager))
        #expect(target.window === auxiliary)
        #expect(target.terminal == nil)
    }

    @Test func terminalKeyWindowWinsAndMainWindowIsUsedOnlyWithoutAKeyWindow() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        let auxiliary = NSWindow()
        #expect(TerminalWindowCommandTarget.resolve(keyWindow: owner.window, mainWindow: auxiliary, manager: manager)?.terminal === owner)
        #expect(TerminalWindowCommandTarget.resolve(keyWindow: nil, mainWindow: owner.window, manager: manager)?.terminal === owner)
        #expect(TerminalWindowCommandTarget.resolve(keyWindow: nil, mainWindow: auxiliary, manager: manager)?.window === auxiliary)
        // An existing terminal elsewhere is never a command fallback.
        #expect(TerminalWindowCommandTarget.resolve(keyWindow: nil, mainWindow: nil, manager: manager) == nil)
    }
}

@MainActor
struct TerminalWindowPreferencesTests {
    @Test func unrelatedDefaultsDoNotRefreshAndAppearanceValuesStayCurrent() async throws {
        let suite = "TecolotWindowPreferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TerminalWindowPreferences(defaults: defaults)
        var changes = 0
        preferences.onChange = {
            changes += 1
        }
        defaults.set("frame", forKey: "lastTerminalWindowFrame")
        defaults.set(false, forKey: TabSelectionCommands.useCommandDigitsForTabsKey)
        await nextTurn()
        #expect(changes == 0)
        defaults.set("compact", forKey: GlobalAppearanceSettings.paneStyleKey)
        await nextTurn()
        #expect(changes == 1)
        #expect(preferences.value.paneStyle == .compact)
        defaults.set("compact", forKey: GlobalAppearanceSettings.paneStyleKey)
        await nextTurn()
        #expect(changes == 1)
        defaults.set("wide", forKey: GlobalAppearanceSettings.terminalPaddingKey)
        await nextTurn()
        #expect(changes == 2)
        #expect(preferences.value.paneStyle == .compact)
        #expect(preferences.value.terminalPadding == .wide)
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

@MainActor
struct TerminalWindowTrafficLightTests {
    @Test func trafficLightsSurviveResizeAndTitlebarRelayouts() async throws {
        let suite = "TrafficLightsResize-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SidebarPreferences.setStyle(.above, defaults: defaults)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { manager.makeWindow = nil }
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        let window = try #require(owner.window)
        defer { manager.closeGroup(group) }
        window.setContentSize(NSSize(width: 820, height: 520))
        window.contentView?.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        await nextTurn()
        try check(window)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didExitFullScreenNotification] {
            // AppKit can restore the native button frames after content layout.
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(type)?.setFrameOrigin(.zero)
            }
            let notification = Notification(name: name, object: window)
            switch name {
            case NSWindow.didBecomeKeyNotification:
                owner.windowDidBecomeKey(notification)
            case NSWindow.didResignKeyNotification:
                owner.windowDidResignKey(notification)
            default:
                owner.windowDidExitFullScreen(notification)
            }
            window.layoutIfNeeded()
            await nextTurn()
            try check(window)
        }
        // Frame observation also repairs relayouts without a delegate event.
        window.standardWindowButton(.closeButton)?.setFrameOrigin(.zero)
        await nextTurn()
        try check(window)
    }

    @Test func fullScreenKeepsStandardWindowButtonsVisibleAndReclaimsTabBarSpace() async throws {
        let suite = "TrafficLightsFullScreen-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SidebarPreferences.setStyle(.above, defaults: defaults)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { manager.makeWindow = nil }
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        owner.appIsActive = { false }
        let window = try #require(owner.window)
        defer { manager.closeGroup(group) }
        window.setContentSize(NSSize(width: 1000, height: 640))
        window.contentView?.layoutSubtreeIfNeeded()
        await nextTurn()
        #expect(owner.tabBar.groupButton.frame.minX == 85)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)

        owner.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        #expect(owner.isFullScreen)
        #expect(!window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .visible)
        #expect(owner.tabBar.groupButton.frame.minX == 8)
        // Simulate AppKit positioning the buttons for the full-screen titlebar while entering.
        let fullScreenOrigin = NSPoint(x: 7, y: 6)
        window.standardWindowButton(.closeButton)?.setFrameOrigin(fullScreenOrigin)
        owner.positionTrafficLights()
        #expect(window.standardWindowButton(.closeButton)?.frame.origin == fullScreenOrigin)

        owner.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        await nextTurn()
        #expect(owner.isFullScreen)
        #expect(!window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .visible)
        let nativeFullScreenFrame = try #require(window.standardWindowButton(.closeButton)?.frame)
        owner.positionTrafficLights()
        await nextTurn()
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try #require(window.standardWindowButton(type))
            #expect(!button.isHidden)
        }
        #expect(window.standardWindowButton(.closeButton)?.frame == nativeFullScreenFrame)
        #expect(owner.tabBar.groupButton.frame.minX == 8)
        #expect(owner.tabBar.scroll.frame.minX == owner.tabBar.groupButton.frame.maxX + 8)

        owner.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification, object: window))
        #expect(!owner.isFullScreen)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(owner.tabBar.groupButton.frame.minX == 85)

        owner.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        window.layoutIfNeeded()
        await nextTurn()
        #expect(!owner.isFullScreen)
        #expect(owner.tabBar.groupButton.frame.minX == 85)
        try check(window)
    }

    @Test func fullScreenReclaimsTrafficLightSpaceInSidebarAndHeaderLayouts() async throws {
        let suite = "FullScreenChrome-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SidebarPreferences.setStyle(.left, defaults: defaults)
        defaults.set(200, forKey: SidebarPreferences.widthKey)
        defaults.set(false, forKey: SidebarPreferences.hiddenKey)
        defaults.set("comfortable", forKey: GlobalAppearanceSettings.paneStyleKey)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { manager.makeWindow = nil }
        let tab = TerminalTab(startsProcesses: false)
        let group = manager.newGroup(tab: tab)
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        owner.appIsActive = { false }
        let window = try #require(owner.window)
        let content = try #require(window.contentView)
        defer { manager.closeGroup(group) }
        window.setContentSize(NSSize(width: 1180, height: 760))
        content.layoutSubtreeIfNeeded()

        // Left sidebar at narrow width (200): windowed clears traffic lights and collapses buttons.
        #expect(owner.sidebar.toggle.frame.minX == 92)
        #expect(content.convert(owner.sidebar.toggle.bounds, from: owner.sidebar.toggle).minX == 92)
        #expect(owner.sidebar.activity.isHidden)

        owner.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        #expect(owner.sidebar.toggle.frame.minX == 12)
        #expect(content.convert(owner.sidebar.toggle.bounds, from: owner.sidebar.toggle).minX == 12)
        #expect(!owner.sidebar.activity.isHidden)

        // Comfortable hidden left sidebar: integrated card header and pane controls keep the toggle aligned at x=12.
        defaults.set(true, forKey: SidebarPreferences.hiddenKey)
        owner.refreshSidebarPreferences()
        content.layoutSubtreeIfNeeded()
        #expect(owner.paneHeaderControls.toggle.frame.minX == 4)
        #expect(content.convert(owner.paneHeaderControls.toggle.bounds, from: owner.paneHeaderControls.toggle).minX == 12)
        #expect(tab.hostView.visibleCards.first?.windowLeadingInset == 36)

        owner.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        content.layoutSubtreeIfNeeded()
        #expect(owner.paneHeaderControls.toggle.frame.minX == 84)
        #expect(content.convert(owner.paneHeaderControls.toggle.bounds, from: owner.paneHeaderControls.toggle).minX == 92)
        #expect(tab.hostView.visibleCards.first?.windowLeadingInset == 116)

        // Compact hidden left sidebar (ContentHeaderView with toggle).
        defaults.set("compact", forKey: GlobalAppearanceSettings.paneStyleKey)
        await nextTurn()
        content.layoutSubtreeIfNeeded()
        #expect(!owner.contentHeader.isHidden)
        #expect(owner.contentHeader.toggle.frame.minX == 84)
        #expect(content.convert(owner.contentHeader.toggle.bounds, from: owner.contentHeader.toggle).minX == 92)
        #expect(owner.contentHeader.glyph.frame.minX == 120)

        owner.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        #expect(owner.contentHeader.toggle.frame.minX == 4)
        #expect(content.convert(owner.contentHeader.toggle.bounds, from: owner.contentHeader.toggle).minX == 12)
        #expect(owner.contentHeader.glyph.frame.minX == 40)

        // Compact right sidebar (ContentHeaderView without toggle).
        SidebarPreferences.setStyle(.right, defaults: defaults)
        defaults.set(false, forKey: SidebarPreferences.hiddenKey)
        owner.refreshSidebarPreferences()
        content.layoutSubtreeIfNeeded()
        #expect(owner.contentHeader.glyph.frame.minX == 10)

        owner.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        content.layoutSubtreeIfNeeded()
        #expect(owner.contentHeader.glyph.frame.minX == 82)
    }

    private func check(_ window: NSWindow) throws {
        let content = try #require(window.contentView)
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            let button = try #require(window.standardWindowButton(type))
            let frame = content.convert(button.bounds, from: button)
            #expect(abs(frame.minX - (15 + CGFloat(index) * 23)) < 0.1)
            #expect(abs(frame.midY - 23) < 0.1)
        }
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

@MainActor
struct TerminalTabSelectionAppearanceTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func selectionSurfaceIsSharedAndTitleUsesRegularSystemFont(appearance: NSAppearance.Name) throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        let bar = owner.tabBar
        bar.appearance = NSAppearance(named: appearance)
        manager.addTab(TerminalTab(startsProcesses: false), to: group)
        bar.layoutSubtreeIfNeeded()
        #expect(bar.cells.count == 2)
        #expect(bar.selectionSurface.superview === bar.scroll.documentView)
        #expect(bar.cells.allSatisfy {
            $0.titleField.font == NSFont.systemFont(ofSize: 13)
        })
        #expect(bar.cells.allSatisfy {
            $0.accessibilityRole() == .radioButton
        })
        #expect(bar.cells[1].isAccessibilitySelected())
        #expect(!bar.cells[0].isAccessibilitySelected())
        #expect(bar.selectionSurface.layer?.backgroundColor?.alpha == 1)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func tabHoverPreservesTranslucentChromeAlpha(appearance: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: appearance))
        let chrome = TabStripChrome(theme: nil, opacity: 1, key: true, appearance: appearance)
        let tab = TerminalTab(startsProcesses: false)
        let cell = TabItemView(tab: tab, controller: nil)
        cell.appearance = appearance
        cell.configure(selected: false, key: true, chrome: chrome, preferences: TabStripPreferences())
        let alpha = try #require(cell.hoverView.layer?.backgroundColor?.alpha)
        #expect(alpha > 0 && alpha < 0.2)
        #expect(abs(alpha - chrome.hover.alphaComponent) < 0.001)
    }

    @Test func quitAlertUsesSingularAndPlural() {
        #expect(TerminalClosePolicy.quitMessage(runningPaneCount: 1) == "1 local pane asks for confirmation before closing.")
        #expect(TerminalClosePolicy.quitMessage(runningPaneCount: 2) == "2 local panes ask for confirmation before closing.")
    }
}
