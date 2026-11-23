import AppKit
import Observation
import SwiftTerm
import Synchronization
import Testing
@testable import Tecolot

@MainActor
struct DefaultsFanoutTests {
    private func nextTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @Test func tabTitlesUseAnObservedCacheWithoutReadingDefaults() async throws {
        let suite = "TabTitleCache-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: TabStripPreferences.preferGeneratedTitlesKey)
        var reads = 0
        let preference = DefaultsValueObserver(defaults: defaults, keys: [TabStripPreferences.preferGeneratedTitlesKey]) {
            reads += 1
            return $0.object(forKey: TabStripPreferences.preferGeneratedTitlesKey) as? Bool ?? true
        }
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let tab = TerminalTab(workspace: workspace, titlePreference: preference)
        defer { workspace.terminateAll() }
        let pane = try #require(workspace.focusedController)
        let terminal = try #require(pane.makeTerminalView() as? AppTerminalView)
        var profile = TerminalProfile(name: "Tab title cache")
        profile.titleComponents = [.activeTitle]
        pane.applyProfile(profile)
        pane.setTerminalTitle(source: terminal, title: "Custom shell title")
        for _ in 0..<100 where pane.panePresentation.title != "Custom shell title" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tab.titleParts.primary == "Custom shell title")
        let changes = Mutex(0)
        withObservationTracking {
            _ = tab.title
        } onChange: {
            changes.withLock {
                $0 += 1
            }
        }
        for _ in 0..<100 {
            _ = tab.title
        }
        defaults.set("frame", forKey: "lastTerminalWindowFrame")
        await nextTurn()
        #expect(reads == 1)
        defaults.set(true, forKey: TabStripPreferences.preferGeneratedTitlesKey)
        await nextTurn()
        #expect(preference.value)
        #expect(changes.withLock {
            $0
        } == 1)
        #expect(tab.titleParts.primary != "Custom shell title")
        let readsAfterChange = reads
        for _ in 0..<100 {
            _ = tab.titleParts
        }
        #expect(reads == readsAfterChange)
        defaults.set(false, forKey: TabStripPreferences.preferGeneratedTitlesKey)
        await nextTurn()
        #expect(tab.titleParts.primary == "Custom shell title")
    }

    /// The title cache registers before any window's tab bar, and defaults
    /// notify the latest observer first, so the tab bar's own refresh reads
    /// the old cached value. The window must refresh again when the cache
    /// updates.
    @Test func horizontalTabTitlesFollowTheGeneratedTitlePreference() async throws {
        let suite = "TabTitleOrdering-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: TabStripPreferences.preferGeneratedTitlesKey)
        let preference = DefaultsValueObserver(defaults: defaults, keys: [TabStripPreferences.preferGeneratedTitlesKey]) {
            $0.object(forKey: TabStripPreferences.preferGeneratedTitlesKey) as? Bool ?? true
        }
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let tab = TerminalTab(workspace: workspace, titlePreference: preference)
        let pane = try #require(workspace.focusedController)
        let terminal = try #require(pane.makeTerminalView() as? AppTerminalView)
        var profile = TerminalProfile(name: "Tab title ordering")
        profile.titleComponents = [.activeTitle]
        pane.applyProfile(profile)
        pane.setTerminalTitle(source: terminal, title: "Custom shell title")
        for _ in 0..<100 where pane.panePresentation.title != "Custom shell title" {
            try await Task.sleep(for: .milliseconds(10))
        }
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        let group = manager.newGroup(tab: tab)
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        func cells(in view: NSView) -> [TabItemView] {
            view.subviews.flatMap {
                ($0 as? TabItemView).map {
                    [$0]
                } ?? cells(in: $0)
            }
        }
        func shownTitle() -> String? {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            return cells(in: owner.tabBar).first {
                $0.tab === tab
            }?.titleField.stringValue
        }
        #expect(shownTitle() == "Custom shell title")
        defaults.set(true, forKey: TabStripPreferences.preferGeneratedTitlesKey)
        for _ in 0..<200 where shownTitle() != tab.title || shownTitle() == "Custom shell title" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tab.title != "Custom shell title")
        #expect(shownTitle() == tab.title)
        defaults.set(false, forKey: TabStripPreferences.preferGeneratedTitlesKey)
        for _ in 0..<200 where shownTitle() != "Custom shell title" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(shownTitle() == "Custom shell title")
    }

    @Test func frameWritesDoNotReadPreferencesAndObserversRelease() async throws {
        let suite = "DefaultsFanout-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reads = 0
        var changes = 0
        var observers: [DefaultsValueObserver<Int>] = (0..<12).map { _ in
            let observer = DefaultsValueObserver(defaults: defaults, keys: [TabStripPreferences.iconCountKey]) {
                reads += 1
                return $0.integer(forKey: TabStripPreferences.iconCountKey)
            }
            observer.onChange = { _ in
                changes += 1
            }
            return observer
        }
        weak var released = observers.first
        reads = 0
        for index in 0..<30 {
            defaults.set("frame \(index)", forKey: "lastTerminalWindowFrame")
            defaults.set("size \(index)", forKey: "lastTerminalWindowFrameSize")
        }
        await nextTurn()
        #expect(reads == 0)
        #expect(changes == 0)
        defaults.set(4, forKey: TabStripPreferences.iconCountKey)
        await nextTurn()
        #expect(changes == 12)
        defaults.set(4, forKey: TabStripPreferences.iconCountKey)
        await nextTurn()
        #expect(changes == 12)
        // Teardown with callbacks pending must neither retain nor call the owner.
        defaults.set(5, forKey: TabStripPreferences.iconCountKey)
        observers.removeAll()
        #expect(released == nil)
        await nextTurn()
        #expect(changes == 12)
        defaults.set(1, forKey: TabStripPreferences.iconCountKey)
    }

    @Test func everyActivityKeyUpdatesBothSnapshots() async throws {
        let suite = "ActivityKeys-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ProgramActivitySettings(defaults: defaults)
        let second = ProgramActivitySettings(defaults: defaults)
        var previous = first.value
        for key in ProgramActivityPreferences.observedKeys {
            if key == ProgramActivityPreferences.tickerSpeedKey {
                defaults.set(55.0, forKey: key)
            } else {
                defaults.set(key == ProgramActivityPreferences.soundsKey, forKey: key)
            }
            await nextTurn()
            #expect(first.value != previous, "Missing activity key: \(key)")
            #expect(first.value == second.value)
            previous = first.value
        }
    }

    @Test func everySidebarKeyUpdatesSnapshot() async throws {
        let suite = "SidebarKeys-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let observer = DefaultsValueObserver(defaults: defaults, keys: SidebarPreferences.observedKeys, read: SidebarPreferences.init(defaults:))
        var changes = 0
        observer.onChange = { _ in
            changes += 1
        }
        let edits: [(String, Any)] = [
            (ProgramActivityPreferences.tabStyleKey, "vertical"),
            (SidebarPreferences.positionKey, "right"), (SidebarPreferences.hiddenKey, true),
            (SidebarPreferences.widthKey, 300.0), (SidebarPreferences.systemSizeKey, 1),
            (SidebarPreferences.textSizeKey, 18.0), (SidebarPreferences.preserveWidthKey, false),
            (SidebarPreferences.gestureKey, "none")
        ]
        #expect(Set(edits.map(\.0)) == Set(SidebarPreferences.observedKeys))
        for (index, edit) in edits.enumerated() {
            defaults.set(edit.1, forKey: edit.0)
            await nextTurn()
            #expect(changes == index + 1, "Missing sidebar key: \(edit.0)")
        }
    }

    @Test func everyTabStripKeyUpdatesSnapshot() async throws {
        let suite = "TabStripKeys-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let observer = DefaultsValueObserver(defaults: defaults, keys: TabStripPreferences.observedKeys, read: TabStripPreferences.init(defaults:))
        var changes = 0
        observer.onChange = { _ in
            changes += 1
        }
        let edits: [(String, Any)] = [
            (TabStripPreferences.iconCountKey, 5), (TabStripPreferences.colorModeKey, "never"),
            (TabStripPreferences.fillKey, true), (TabStripPreferences.animationStyleKey, "off"),
            (TabStripPreferences.preferGeneratedTitlesKey, false),
            // Off hides the icons: the icon count in the snapshot changes.
            (TabStripPreferences.trackRunningProgramsKey, false)
        ]
        #expect(Set(edits.map(\.0)) == Set(TabStripPreferences.observedKeys))
        for (index, edit) in edits.enumerated() {
            defaults.set(edit.1, forKey: edit.0)
            await nextTurn()
            #expect(changes == index + 1, "Missing tab strip key: \(edit.0)")
        }
    }

    @Test func externalDefaultsWriteUpdatesObservers() async throws {
        let suite = "ExternalDefaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ProgramActivitySettings(defaults: defaults)
        let second = ProgramActivitySettings(defaults: defaults)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", suite, ProgramActivityPreferences.colorKey, "-bool", "NO"]
        try process.run()
        // Let Foundation process cross-process defaults changes on the run loop.
        for _ in 0..<100 where first.value.color || second.value.color {
            try await Task.sleep(for: .milliseconds(50))
        }
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!first.value.color)
        #expect(!second.value.color)
    }

    @Test func frameBurstCoalescesAndLifecycleFlushesFinalFrame() async throws {
        let suite = "FrameBurst-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var saves = 0
        let store = TerminalWindowSizeStore(defaults: defaults, saveInterval: 0.05, didSave: {
            saves += 1
        })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        store.configure(window, restoresFrame: false)
        for index in 0..<30 {
            window.setFrameOrigin(NSPoint(x: 100 + index, y: 100))
            NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        }
        #expect(saves == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(saves == 1)
        #expect(defaults.string(forKey: "lastTerminalWindowFrame") == NSStringFromRect(window.frame))
        for (index, name) in [NSWindow.didEndLiveResizeNotification, NSApplication.willTerminateNotification, NSWindow.willCloseNotification].enumerated() {
            window.setFrameOrigin(NSPoint(x: 150 + index, y: 100))
            NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
            NotificationCenter.default.post(name: name, object: window)
            #expect(saves == index + 2)
            #expect(defaults.string(forKey: "lastTerminalWindowFrame") == NSStringFromRect(window.frame))
            #expect(defaults.string(forKey: "lastTerminalWindowFrameSize") == NSStringFromSize(window.frame.size))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(saves == 4)
    }
}
