import AppKit
import Observation
import Synchronization
import Testing
import TecolotSessionDirectory
import TecolotWire
import UserNotifications
@testable import Tecolot

@MainActor
@Suite(.serialized)
struct Round15RegressionTests {
    private func fixture(style: String = "horizontal") throws -> (TerminalWindowManager, TerminalTabGroup, TerminalWindowController, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "m15-\(UUID())"))
        defaults.set(style, forKey: ProgramActivityPreferences.tabStyleKey)
        defaults.set(false, forKey: SidebarPreferences.hiddenKey)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        return (manager, group, owner, defaults)
    }
    private func stop(_ manager: TerminalWindowManager) {
        for group in manager.groups {
            manager.closeGroup(group)
        }
    }
    private func publish(_ state: ProgramStatusState, to pane: TerminalSessionController, progress: Int? = nil) async throws {
        pane.programStatus.receive(ProgramStatusMessage(records: [WireProgramStatus(state: state, progress: progress, reportTime: 1)]))
        try await Task.sleep(for: .milliseconds(350))
        pane.programStatus.flush()
    }

    @Test func moveToNewGroupMenuShowsDestinationForLastTab() throws {
        let (manager, group, owner, _) = try fixture()
        defer { stop(manager) }
        let tab = try #require(group.selectedTab)
        let cell = try #require(owner.tabBar.cells.first)
        let menu = try #require(cell.menu(for: NSEvent()))
        let item = try #require(menu.items.first {
            $0.title == "Move to Group"
        }?.submenu?.items.first {
            $0.title == "New Group"
        })
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        let destination = try #require(manager.groups.first {
            $0.tabs.contains {
                $0 === tab
            }
        })
        #expect(manager.window(showing: destination) != nil)
        #expect(destination.lastShownAt != nil)
        #expect(tab.hostView.window != nil)
    }

    @Test func owningTabExistsBeforeMountAndFollowsMoves() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        defer { stop(manager) }
        let tab = TerminalTab(startsProcesses: false)
        let pane = try #require(tab.workspace.focusedController)
        #expect(pane.owningTab === tab)
        let source = manager.newGroup(tab: tab)
        let target = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        manager.move(tab, from: source, to: target)
        #expect(pane.owningTab === tab)
        #expect(manager.group(containing: pane) === target)
        manager.moveToNewWindow(tab, from: target)
        #expect(pane.owningTab === tab)
        #expect(manager.group(containing: pane)?.selectedTab === tab)
    }

    @Test func aboveAXTabOrderIsVisualAndCloseIsEnabledOffHover() throws {
        let (manager, group, owner, _) = try fixture()
        defer { stop(manager) }
        manager.addTab(TerminalTab(startsProcesses: false), to: group)
        let track = try #require(owner.tabBar.scroll.documentView)
        let children = track.accessibilityChildren()?.compactMap {
            $0 as? TabItemView
        } ?? []
        #expect(children.map(\.tab.id) == group.tabs.map(\.id))
        for cell in owner.tabBar.cells {
            let close = try #require(cell.accessibilityChildren()?.first as? NSAccessibilityElement)
            #expect(close.accessibilityLabel() == "Close Tab")
            #expect(close.isAccessibilityEnabled())
        }
    }

    @Test func selectorAXRowsHaveMenuLabelsAndPressAndConfirmDismisses() throws {
        let (manager, _, owner, _) = try fixture()
        defer { stop(manager) }
        let panel = GroupSwitcherPanel()
        owner.groupPresenter = panel
        owner.showGroups()
        defer { panel.orderOut(nil) }
        let items = panel.table.accessibilityChildren()?.compactMap {
            $0 as? NSAccessibilityElement
        } ?? []
        #expect(!items.isEmpty)
        #expect(items.allSatisfy {
            $0.accessibilityRole() == .menuItem && !($0.accessibilityLabel() ?? "").isEmpty
        })
        #expect(panel.filterField.accessibilityPerformConfirm())
        #expect(!panel.isVisible)
    }

    @Test func paneHeaderAXGroupsStatusAndUnfocusedActions() async throws {
        let (manager, group, _, _) = try fixture()
        defer { stop(manager) }
        let tab = try #require(group.selectedTab)
        let pane = try #require(tab.workspace.focusedController)
        tab.workspace.split(pane, direction: .right)
        let card = try #require(tab.hostView.visibleCards.first {
            $0.controller === pane
        })
        try await publish(.blocked, to: pane)
        card.refreshAppearance()
        #expect(card.header.isAccessibilityElement())
        #expect(card.header.accessibilityRole() == .group)
        #expect(card.header.accessibilityValue() as? String == "Needs you")
        #expect((card.header.accessibilityCustomActions()?.map(\.name) ?? []).contains("Split Right"))
        #expect((card.header.accessibilityCustomActions()?.map(\.name) ?? []).contains("Close Pane"))
    }

    @Test func sidebarAXHasOneTabRowCollapsedStatusAndActivityCount() async throws {
        let (manager, group, owner, _) = try fixture(style: "vertical")
        defer { stop(manager) }
        let pane = try #require(group.selectedTab?.workspace.focusedController)
        try await publish(.blocked, to: pane)
        owner.sidebar.reload()
        let children = owner.sidebar.outline.accessibilityChildren() ?? []
        let tabs = children.compactMap {
            $0 as? TabItemView
        }
        #expect(tabs.count == 1)
        #expect(tabs.first?.accessibilityChildren()?.count == 1)
        manager.setCollapsed(true, group: group)
        owner.sidebar.reload()
        let header = try #require(owner.sidebar.outline.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(header.accessibilityValue() as? String == "Needs you")
        #expect(owner.sidebar.activity.accessibilityLabel() == "Activity")
        #expect(owner.sidebar.activity.accessibilityValue() as? String == "1 tab with unseen activity")
    }

    @Test func tabAXValueIncludesProgress() {
        let status = TabStatus.reduce([.init(paneID: UUID(), value: WireProgramStatus(state: .working, progress: 42), unseen: true)])
        #expect(status.accessibilityValue == "Working, 42%")
    }

    @Test func osc9UsesPaneTitleAndGroupSubtitle() throws {
        let (manager, group, _, _) = try fixture()
        defer { stop(manager) }
        group.name = "Builds"
        let pane = try #require(group.selectedTab?.workspace.focusedController)
        let notifier = TerminalNotifier()
        var contents: [UNNotificationContent] = []
        notifier.deliver = {
            contents.append($0.content)
        }
        notifier.notify(title: "", body: "Ready", from: pane)
        let content = try #require(contents.first)
        #expect(content.title == pane.panePresentation.title)
        #expect(content.subtitle == "Builds")
        #expect(content.body == "Ready")
    }

    @Test func workingAndIdleDoNotUseNotificationBudgetOrSound() throws {
        let pane = TerminalSessionController(startsProcess: false)
        let notifier = TerminalNotifier()
        var sounds = 0
        var requests: [UNNotificationRequest] = []
        notifier.sound = {
            sounds += 1
        }
        notifier.deliver = {
            requests.append($0)
        }
        let start = Date()
        for index in 0..<8 {
            notifier.notifyProgramStatus(WireProgramStatus(state: index.isMultiple(of: 2) ? .working : .idle, reportTime: UInt64(index + 1)), from: pane, now: start.addingTimeInterval(Double(index * 3)), appActive: false)
        }
        #expect(notifier.rateLimitedSources == 0)
        #expect(sounds == 0)
        #expect(requests.isEmpty)
        notifier.notifyProgramStatus(WireProgramStatus(state: .blocked, message: "Allow?", reportTime: 9), from: pane, now: start.addingTimeInterval(25), appActive: false)
        #expect(requests.count == 1)
        #expect(requests.first?.content.title == "Needs you")
    }

    @Test func fullScreenCaptureRetainsWindowedFrame() throws {
        let (manager, _, owner, _) = try fixture()
        defer { stop(manager) }
        let window = try #require(owner.window)
        let before = NSRect(x: 100, y: 120, width: 700, height: 500)
        window.setFrame(before, display: false)
        let selector = NSSelectorFromString("windowWillEnterFullScreen:")
        if owner.responds(to: selector) {
            owner.perform(selector, with: Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        }
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m15-frame-\(UUID())")
        let store = RestoreStore(directory: root, manager: manager, startsProcesses: false)
        #expect(store.capture(limit: 0).0.windows.first?.frame == NSStringFromRect(before))
    }
}

@MainActor
@Suite(.serialized)
struct Round15PolicyRegressionTests {
    @Test func endingTwoSessionsAcceptsOwnPaneRemovalButRejectsUserChanges() async throws {
        let first = SessionRef(id: "a1", destination: nil), second = SessionRef(id: "a2", destination: nil)
        func pane(_ session: SessionRef) -> GroupSessionEnder.Pane {
            .init(id: UUID(), label: session.id, kind: .persistent, session: session, local: nil, info: nil, program: nil)
        }
        let initial = [pane(first), pane(second)]
        let plan = await GroupSessionEnder.plan(initial) { _ in
            (nil, nil)
        }
        var current = initial
        var ended: [SessionRef] = []
        var closed = false
        try await GroupSessionEnder.perform(plan, confirm: { _ in
            .endSessions
        }, end: { session in
            ended.append(session)
            current.removeAll {
                $0.session == session
            }
        }, validate: { ending in
            guard GroupSessionEnder.matches(initial, current: current, ending: ending) else {
                throw GroupSessionEnder.Failure.groupChanged
            }
        }, close: {
            closed = true
        })
        #expect(ended == [first, second] && closed)
        #expect(!GroupSessionEnder.matches(initial, current: [initial[1]], ending: []))
        #expect(!GroupSessionEnder.matches(initial, current: Array(initial.reversed()), ending: []))
        #expect(!GroupSessionEnder.matches(initial, current: initial + [pane(first)], ending: [first]))
        var moved = initial
        moved[0].tabID = UUID()
        #expect(!GroupSessionEnder.matches(initial, current: moved, ending: []))
        var changedBeforeConfirm = false
        do {
            try await GroupSessionEnder.perform(plan, confirm: { _ in changedBeforeConfirm = true
                return .endSessions
            }, end: { _ in
                Issue.record("must not end stale plan")
            }, validate: { _ in
                if changedBeforeConfirm {
                    throw GroupSessionEnder.Failure.groupChanged
                }
            }, close: {
                Issue.record("must not close stale plan")
            })
            Issue.record("expected groupChanged")
        } catch GroupSessionEnder.Failure.groupChanged {}
    }

    @Test func seenEncodingIsDebouncedAndQuitFlushPersistsLatestSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m15-seen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let encodedOnMain = Mutex<[Bool]>([])
        let store = ProgramActivitySeenStore(directory: root, debounceInterval: 0.05, willEncode: {
            encodedOnMain.withLock {
                $0.append(Thread.isMainThread)
            }
        })
        let pane = UUID()
        for time in 1...30 {
            store.markSeen(pane: pane, records: [.init(state: .done, reportTime: UInt64(time))])
        }
        #expect(encodedOnMain.withLock {
            $0.isEmpty
        })
        try await Task.sleep(for: .milliseconds(200))
        #expect(encodedOnMain.withLock {
            $0
        } == [false])
        let final = WireProgramStatus(state: .done, reportTime: 31)
        store.markSeen(pane: pane, records: [final])
        #expect(store.flush())
        #expect(ProgramActivitySeenStore(directory: root).isSeen(pane: pane, record: final))
        try await Task.sleep(for: .milliseconds(100))
        #expect(encodedOnMain.withLock {
            $0.count
        } == 2)
    }

    @Test func launchPrunesUnreferencedExpiredStatesAndProtectsDormantAndRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m15-prune-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let states = DurableStateDirectory(url: root.appendingPathComponent("Sessions"))
        for id in ["a1", "a2", "a3", "a4"] {
            try states.write(DurableSessionState(id: id, launch: SessionLaunch(executable: "/bin/sh", environment: []), savedAt: Date().addingTimeInterval(-8 * 86400)), scrollback: nil)
        }
        let defaults = try #require(UserDefaults(suiteName: "m15-prune-\(UUID())"))
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        defer { for group in manager.groups {
            manager.closeGroup(group)
        } }
        func dormant(_ session: String) -> TerminalTab {
            let tab = RestoreTab(root: .pane(RestorePane(id: UUID(), kind: .persistent, sessionID: session)))
            return TerminalTab(dormant: RestoreStore.launchSpec(for: RestoredTab(tab: tab, panes: [:])), startsProcesses: false)
        }
        _ = manager.newGroup(tab: dormant("a1"))
        let saved = RestoreState(bootID: nil, savedAt: Date(), groups: [RestoreGroup(name: "Dormant", tabs: [RestoreTab(root: .pane(RestorePane(id: UUID(), kind: .persistent, sessionID: "a2")))])], windows: [])
        let store = RestoreStore(directory: root.appendingPathComponent("Restore"), sessionStates: states, runningSessions: {
            ["a3"]
        }, manager: manager, defaults: defaults, startsProcesses: false)
        try DurableStateDirectory.makePrivateDirectory(store.directory)
        try DurableStateDirectory.writePrivate(try RestoreStateMigrator().encodeCurrent(saved), to: store.windowsURL)
        _ = store.restore()
        #expect(states.read("a4") == nil)
        for id in ["a1", "a2", "a3"] {
            #expect(states.read(id) != nil)
        }
    }

    @Test func notificationAuthorizationIncludesBadgesForExistingGrants() {
        #expect(TerminalNotifier.authorizationOptions.contains(.badge))
        #expect(TerminalNotifier.authorizationOptions.contains(.alert))
        #expect(TerminalNotifier.authorizationOptions.contains(.sound))
    }

    @Test func liveAccessibilityDisplayNotificationRefreshesExistingWindow() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        let count = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: .programActivityDidChange, object: owner, queue: .main) { _ in
            count.withLock {
                $0 += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(count.withLock {
            $0
        } == 1)
    }

    @Test func progressUpdatesCellWithoutInvalidatingWindowMetadata() async throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let tab = TerminalTab(startsProcesses: false)
        let group = manager.newGroup(tab: tab)
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        let pane = try #require(tab.workspace.focusedController)
        _ = pane.makeTerminalView()
        let changes = Mutex(0)
        withObservationTracking {
            _ = pane.windowPresentation
        } onChange: {
            changes.withLock {
                $0 += 1
            }
        }
        pane.programStatus.receive(ProgramStatusMessage(records: [.init(state: .working, progress: 42, reportTime: 1)]))
        try await Task.sleep(for: .milliseconds(350))
        pane.programStatus.flush()
        #expect(changes.withLock {
            $0
        } == 0)
        #expect(owner.tabBar.cells.first?.accessibilityValue() as? String == "Working, 42%")
        pane.updatePaneExecutablePath("/usr/bin/make")
        #expect(changes.withLock {
            $0
        } == 1)
        #expect(owner.window?.title.contains(group.name) == true)
    }

    @Test func dormantAndBackgroundWorkspacesDoNotPollProcesses() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let tab = TerminalTab(startsProcesses: false)
        let group = manager.newGroup(tab: tab)
        defer { manager.closeGroup(group) }
        #expect(!tab.workspace.needsProcessInspection)
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        #expect(owner.window?.isVisible == false)
        #expect(!tab.workspace.needsProcessInspection)
        manager.closeWindow(owner)
        #expect(!tab.workspace.needsProcessInspection)
    }

    @Test(arguments: [AskBeforeClosing.never, .always])
    func tabGroupAndQuitHonorProfileForBusyAndIdleShells(preference: AskBeforeClosing) async throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let tab = TerminalTab(startsProcesses: true)
        let group = manager.newGroup(tab: tab)
        defer { manager.closeGroup(group) }
        let pane = try #require(tab.workspace.focusedController)
        var profile = TerminalProfile(name: "m15-close")
        profile.sessionPersistence = .standard
        profile.askBeforeClosing = preference
        profile.shell = preference == .never ? .command("sleep 60 & wait", runInShell: true) : .command("/bin/sh", runInShell: false)
        pane.applyProfile(profile)
        let terminal = try #require(pane.makeTerminalView() as? AppTerminalView)
        for _ in 0..<100 {
            if terminal.process.running && (preference == .always || TerminalClosePolicy.state(for: pane).childProcesses > 0) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = TerminalClosePolicy.state(for: pane)
        #expect(state.running)
        if preference == .never {
            #expect(state.childProcesses > 0)
        }
        let expected = preference == .always
        #expect(TerminalClosePolicy.requiresConfirmation(for: pane) == expected) // tab
        #expect(GroupCloseConfirmation.requiresConfirmation(group) == expected)
        #expect((TerminalClosePolicy.confirmationCount(in: [pane]) > 0) == expected) // quit
    }
}

extension Round15PolicyRegressionTests {
    @Test func restoredFullScreenCallbackRestoresActiveWindowCommandTarget() async throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        let window = try #require(owner.window)
        defer { manager.closeGroup(group) }
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<100 where !NSApp.isActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(NSApp.isActive)
        window.orderFront(nil)
        window.resignKey()
        owner.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        #expect(window.isKeyWindow)
        #expect(TerminalWindowCommandTarget.resolve(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow, manager: manager)?.terminal === owner)
        let item = NSMenuItem(title: "stale title", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        #expect(window.validateMenuItem(item))
        #expect(item.title == "Enter Full Screen")
    }
}
