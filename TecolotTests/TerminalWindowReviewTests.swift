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
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
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
            $0.titleField.font == NSFont.systemFont(ofSize: 14)
        })
        #expect(bar.cells.allSatisfy {
            $0.accessibilityRole() == .radioButton
        })
        #expect(bar.cells[1].isAccessibilitySelected())
        #expect(!bar.cells[0].isAccessibilitySelected())
        #expect(bar.selectionSurface.layer?.backgroundColor?.alpha == 1)
    }

    @Test func quitAlertUsesSingularAndPlural() {
        #expect(TerminalClosePolicy.quitMessage(runningPaneCount: 1) == "1 local pane asks for confirmation before closing.")
        #expect(TerminalClosePolicy.quitMessage(runningPaneCount: 2) == "2 local panes ask for confirmation before closing.")
    }
}
