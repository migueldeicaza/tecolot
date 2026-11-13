import AppKit
import Testing
@testable import Tecolot

@MainActor
struct WindowSizingTests {
    @Test func profileGridControlsInitialContentSize() {
        var base = TerminalProfile(name: "Base")
        base.columns = 80
        base.rows = 25

        var wider = base
        wider.columns = 120

        var taller = base
        taller.rows = 40

        let baseSize = TerminalProfileWindowSizer.contentSize(for: base)
        let widerSize = TerminalProfileWindowSizer.contentSize(for: wider)
        let tallerSize = TerminalProfileWindowSizer.contentSize(for: taller)

        #expect(widerSize.width > baseSize.width)
        #expect(widerSize.height == baseSize.height)
        #expect(tallerSize.width == baseSize.width)
        #expect(tallerSize.height > baseSize.height)
    }

    @Test func profileContentSizeSetsTheWindowLayoutArea() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let requestedSize = NSSize(width: 640, height: 400)

        TerminalWindowSizeStore.shared.setProfileContentSize(requestedSize, on: window)

        #expect(abs(window.contentLayoutRect.width - requestedSize.width) < 0.5)
        #expect(abs(window.contentLayoutRect.height - requestedSize.height) < 0.5)
    }
}

@MainActor
struct ManagerWindowSizingTests {
    private func setup() -> (TerminalWindowManager, TerminalWindowSizeStore, UserDefaults, String) {
        let suite = "review-window-size-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = TerminalWindowSizeStore(defaults: defaults)
        return (TerminalWindowManager(registry: TerminalSessionRegistry(), windowSizeStore: store), store, defaults, suite)
    }

    @Test func everyManagerWindowUsesSavedSizeAndPosition() throws {
        let (manager, _, defaults, suite) = setup()
        defer {
            for group in manager.groups {
                manager.closeGroup(group)
            }
            defaults.removePersistentDomain(forName: suite)
        }
        let frame = NSRect(x: 120, y: 130, width: 740, height: 510)
        defaults.set(NSStringFromRect(frame), forKey: "lastTerminalWindowFrame")
        // Startup, Dock reopen and These Groups all use this entry point.
        for _ in 0..<3 {
            let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
            let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
            #expect(owner.window?.frame == frame)
        }
    }

    @Test func duplicateAndMoveInheritSourceSizeAndCascade() throws {
        let (manager, _, defaults, suite) = setup()
        defer {
            for group in manager.groups {
                manager.closeGroup(group)
            }
            defaults.removePersistentDomain(forName: suite)
        }
        let source = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let second = TerminalTab(startsProcesses: false)
        manager.addTab(second, to: source)
        let owner = try #require(manager.openWindow(group: source) as? TerminalWindowController)
        let frame = NSRect(x: 130, y: 180, width: 680, height: 450)
        owner.window?.setFrame(frame, display: false)
        let copy = manager.duplicate(source)
        let copiedWindow = try #require(manager.window(showing: copy) as? TerminalWindowController)
        #expect(copiedWindow.window?.frame == frame.offsetBy(dx: 20, dy: -20))
        manager.moveToNewWindow(second, from: source)
        let moved = try #require(manager.groups.first {
            $0.tabs.contains {
                $0 === second
            }
        })
        let movedWindow = try #require(manager.window(showing: moved) as? TerminalWindowController)
        #expect(movedWindow.window?.frame == frame.offsetBy(dx: 20, dy: -20))
    }

    @Test func profileSizingAccountsForFullSizeChromeAndCascade() throws {
        let (manager, store, defaults, suite) = setup()
        defer {
            for group in manager.groups {
                manager.closeGroup(group)
            }
            defaults.removePersistentDomain(forName: suite)
        }
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        let window = try #require(owner.window)
        let source = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 600, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        var profile = TerminalProfile(name: "Small")
        profile.columns = 70
        profile.rows = 18
        defaults.set("horizontal", forKey: "tabStyle")
        let preferences = SidebarPreferences(defaults: defaults)
        let terminal = TerminalProfileWindowSizer.contentSize(for: profile)
        store.prepare(window, profile: profile, style: preferences, policy: .profile, cascadeFrom: source)
        #expect(abs((window.contentView?.bounds.width ?? 0) - terminal.width - 16) < 0.5)
        #expect(abs((window.contentView?.bounds.height ?? 0) - terminal.height - 90) < 0.5)
        #expect(abs(window.frame.minX - source.frame.minX - 20) < 0.5)
        #expect(abs(window.frame.maxY - source.frame.maxY + 20) < 0.5)
    }
}
