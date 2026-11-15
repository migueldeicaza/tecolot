import AppKit
import Testing
import Synchronization
import TecolotSessionClient
@testable import Tecolot

@MainActor
private final class FocusReviewWindow: NSWindow {
    override var isKeyWindow: Bool {
        true
    }
}

/// Records actual subscriptions rather than adding instrumentation to RemoteHosts.
private nonisolated final class ReviewNotificationCenter: NotificationCenter, @unchecked Sendable {
    let subscriptions = Mutex<[Notification.Name]>([])
    override func addObserver(forName name: Notification.Name?, object obj: Any?, queue: OperationQueue?, using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        if let name {
            subscriptions.withLock {
                $0.append(name)
            }
        }
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
}

@MainActor
struct ReviewEfficiencyTests {
    @Test func processVisibilitySubscriptionsAreSharedAndWindowScoped() throws {
        let suite = "ProcessVisibility-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("horizontal", forKey: ProgramActivityPreferences.tabStyleKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = ReviewNotificationCenter()
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry(), notificationCenter: center)
        manager.makeWindow = { TerminalWindowController(group: $0, manager: manager, defaults: defaults) }
        let first = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        manager.addTab(TerminalTab(startsProcesses: false), to: first)
        let second = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let background = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let dormant = TerminalTab(dormant: LaunchSpec(), startsProcesses: false)
        _ = manager.newGroup(tab: dormant)
        let a = try #require(manager.openWindow(group: first) as? TerminalWindowController)
        let b = try #require(manager.openWindow(group: second) as? TerminalWindowController)
        manager.makeWindow = nil
        defer { for group in manager.groups { manager.closeGroup(group) } }
        let subscriptions = center.subscriptions.withLock { $0 }
        #expect(subscriptions.count == 5)
        #expect(Set(subscriptions) == Set(TerminalWindowManager.processVisibilityNotifications))
        func ids(_ workspaces: [TerminalPaneWorkspace]) -> Set<ObjectIdentifier> {
            Set(workspaces.map(ObjectIdentifier.init))
        }
        #expect(ids(manager.processInspectionWorkspaces(affectedWindow: a.window)) == ids(first.tabs.compactMap(\.loadedWorkspace)))
        #expect(ids(manager.processInspectionWorkspaces(affectedWindow: b.window)) == ids(second.tabs.compactMap(\.loadedWorkspace)))
        #expect(manager.processInspectionWorkspaces(affectedWindow: NSWindow()).isEmpty)
        #expect(ids(manager.processInspectionWorkspaces()) == ids((first.tabs + second.tabs).compactMap(\.loadedWorkspace)))
        #expect(!background.tabs[0].workspace.needsProcessInspection)
        // An occluded sidebar still has rows for other windows in its viewport.
        a.sidebar.isHidden = false
        a.sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        a.sidebar.reload()
        a.sidebar.layoutSubtreeIfNeeded()
        try #require(a.sidebar.tabsInViewport.contains { $0 === second.tabs[0] })
        #expect(ids(manager.processInspectionWorkspaces(affectedWindow: a.window)) == ids((first.tabs + second.tabs).compactMap(\.loadedWorkspace)))
        for participates in [false, true] {
            let bare = TerminalPaneWorkspace(startsProcesses: false, participatesInWindow: participates)
            defer { bare.terminateAll() }
            bare.updateProcessInspection()
            for name in subscriptions { center.post(name: name, object: a.window) }
            #expect(!bare.needsProcessInspection)
        }
        #expect(dormant.isDormant)
        #expect(center.subscriptions.withLock { $0.count } == 5)
    }

    @Test func groupCountStillRefreshesTheHorizontalCaption() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { for group in manager.groups { manager.closeGroup(group) } }
        let button = try #require(owner.tabBar.subviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "Go to Group"
        })
        #expect(button.title.isEmpty)
        let background = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        #expect(button.title == group.name)
        manager.closeGroup(background)
        #expect(button.title.isEmpty)
    }

    @Test func cachedRowsDoNotBecomeUnseenActivity() async {
        let controller = TerminalSessionController(startsProcess: false)
        let session = RemoteSession(socket: -1, clientName: "review", build: "test")
        let view = RemoteTerminalView(session: session, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.sessionController = controller
        defer { session.close()
            controller.terminate()
        }
        session.onChange?(.rows)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        #expect(!controller.programStatus.quiet)
        session.onChange?(.output)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        #expect(controller.programStatus.quiet)
    }

    @Test func onePaneActivityDoesNotReduceEveryOtherGroup() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        defer { for group in manager.groups {
            manager.closeGroup(group)
        } }
        for _ in 0..<12 {
            _ = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        }
        var reduced: [UUID] = []
        let center = ProgramActivityCenter(manager: manager, statusForTab: { tab in reduced.append(tab.id)
            return tab.status
        })
        center.update()
        reduced.removeAll()
        let pane = try #require(manager.groups[0].selectedTab?.workspace.focusedController)
        center.update(changedPane: pane)
        #expect(reduced == [manager.groups[0].selectedTab?.id].compactMap {
            $0
        })
    }

    @Test func unchangedIconPreferencesDoNotReinspectProcesses() {
        var preferences = PaneIconInspectionPreferences(iconCount: 3)
        var applied: [Int] = []
        for _ in 0..<30 {
            preferences.update(iconCount: 3) {
                applied.append(3)
            }
        }
        #expect(applied.isEmpty)
        preferences.update(iconCount: 0) {
            applied.append(0)
        }
        preferences.update(iconCount: 0) {
            applied.append(0)
        }
        preferences.update(iconCount: 5) {
            applied.append(5)
        }
        #expect(applied == [0, 5])
    }

    @Test func unchangedPaneVisibilityDoesNotResumePrompts() {
        var resumes: [Bool] = []
        let controller = TerminalSessionController(startsProcess: false, resumeRemotePrompts: {
            resumes.append(true)
        })
        defer { controller.terminate() }
        controller.setProgramStatusDrawingVisible(true)
        resumes.removeAll()
        for _ in 0..<30 {
            controller.setProgramStatusDrawingVisible(true)
        }
        #expect(resumes.isEmpty)
        controller.setProgramStatusDrawingVisible(false)
        controller.setProgramStatusDrawingVisible(true)
        #expect(resumes == [true])
    }

    @Test func unchangedRefreshDoesNotResumePromptsOrReloadSidebar() throws {
        let suite = "ReviewSidebar-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("vertical", forKey: ProgramActivityPreferences.tabStyleKey)
        defaults.set("left", forKey: SidebarPreferences.positionKey)
        defaults.set(false, forKey: SidebarPreferences.hiddenKey)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        var resumes: [Bool] = []
        var models: [String] = []
        let sidebar = SidebarTabBarView(frame: .zero, makeModel: { manager, group, filter in
            models.append(filter)
            return SidebarModel(manager: manager, current: group, filter: filter)
        })
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults, resumeRemotePrompts: {
                resumes.append(true)
            }, sidebar: sidebar)
        }
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        manager.makeWindow = nil
        defer { manager.closeGroup(group) }
        resumes.removeAll()
        let outline = owner.sidebar.outline
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        let header = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true))
        models.removeAll()
        for _ in 0..<30 {
            owner.show(group)
        }
        #expect(resumes.isEmpty)
        #expect(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) === header)
        #expect(models.isEmpty)
        owner.sidebar.reload()
        #expect(models == [""])
    }

    @Test func emptyRemoteRegistryIgnoresWindowUpdatesAndAvailabilityEvents() {
        #expect(!RemoteHosts.availabilityNotifications.contains(NSWindow.didUpdateNotification))
        #expect(RemoteHosts.availabilityNotifications.contains(.groupsDidChange))
        var queried: [UUID] = []
        #expect(RemotePromptVisibility.visibleLinks(Set<UUID>()) { id in queried.append(id)
            return []
        }.isEmpty)
        #expect(queried.isEmpty)
        let missing = UUID()
        #expect(RemotePromptVisibility.visibleLinks(Set([missing])) { id in queried.append(id)
            return []
        }.isEmpty)
        #expect(queried == [missing])
        let center = ReviewNotificationCenter()
        let hosts = RemoteHosts(notificationCenter: center)
        defer { hosts.shutdown() }
        let subscriptions = center.subscriptions.withLock {
            $0
        }
        #expect(!subscriptions.contains(NSWindow.didUpdateNotification))
        #expect(Set(RemoteHosts.availabilityNotifications).isSubset(of: Set(subscriptions)))
        #expect(Set(subscriptions).count == subscriptions.count)
        let window = NSWindow()
        for _ in 0..<30 {
            center.post(name: NSWindow.didUpdateNotification, object: window)
            hosts.resumePendingPrompts()
        }
    }

    @Test func unchangedWindowUpdatesDoNotRepeatFocusWork() async throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let pane = try #require(workspace.focusedController)
        let host = TerminalPaneHostView(workspace: workspace)
        let window = FocusReviewWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        defer { workspace.terminateAll() }
        window.contentView = host
        host.synchronize(revision: workspace.revision)
        let terminal = try #require(pane.terminal)
        pane.attach(to: terminal)
        #expect(window.makeFirstResponder(terminal))
        var focused: [ObjectIdentifier] = []
        let observer = NotificationCenter.default.addObserver(forName: .terminalFocusedPaneDidChange, object: window, queue: .main) { note in
            MainActor.assumeIsolated {
                if let object = note.object as AnyObject? {
                    focused.append(ObjectIdentifier(object))
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(focused == [ObjectIdentifier(window)])
        focused.removeAll()
        for _ in 0..<30 {
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        }
        #expect(focused.isEmpty)
        let field = NSTextField()
        host.addSubview(field)
        #expect(window.makeFirstResponder(field))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(window.makeFirstResponder(terminal))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(focused == [ObjectIdentifier(window)])
    }
}
