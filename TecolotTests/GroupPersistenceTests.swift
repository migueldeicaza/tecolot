import AppKit
import Testing
import Synchronization
import TecolotSessionDirectory
@testable import Tecolot

/// Records durable layout writes through the store's writer dependency.
private nonisolated final class RecordedRestoreWrites: Sendable {
    let values = Mutex<[RestoreState]>([])
    var states: [RestoreState] {
        values.withLock {
            $0
        }
    }
    func write(_ state: RestoreState, to url: URL) throws {
        try RestoreStore.writeLayout(state, to: url)
        values.withLock {
            $0.append(state)
        }
    }
}

/// Model windows materialize views with process startup disabled by the store.
@MainActor
private final class RestoreModelWindow: TerminalGroupWindow {
    let id = UUID()
    var group: TerminalTabGroup
    init(_ group: TerminalTabGroup) {
        self.group = group
        mount()
    }
    func show(_ group: TerminalTabGroup) {
        self.group = group
        mount()
    }
    private func mount() {
        for tab in group.tabs where !tab.isDormant {
            _ = tab.hostView
        }
    }
    func activate() {}
    func closeWindow() {}
}

@MainActor
@Suite(.serialized)
struct GroupPersistenceTests {
    /// Waits for actual durable writes instead of racing a fixed main-queue sleep.
    private func waitForWrites(_ store: RestoreStore, recorded: RecordedRestoreWrites, count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<500 {
            await store.waitForWrites()
            if recorded.states.count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(recorded.states.count >= count, sourceLocation: sourceLocation)
    }
    private func group(_ name: String, kind: RestorePaneKind = .local, shown: Date? = nil) -> RestoreGroup {
        let pane = RestorePane(
            id: UUID(),
            kind: kind,
            profileID: UUID(),
            themeOverride: "test-theme",
            directory: PaneDirectory(path: "/tmp", source: .osc7),
            sessionID: kind == .local ? nil : "saved-session",
            remoteDestination: kind == .remote ? "nobody@invalid.example" : nil
        )
        return RestoreGroup(
            name: name,
            isNameCustom: true,
            tabs: [RestoreTab(name: "Build", focusedPaneID: pane.id, root: .pane(pane))],
            lastShownAt: shown
        )
    }

    private func fixture(writes: RecordedRestoreWrites? = nil) -> (URL, UserDefaults, TerminalWindowManager, TerminalSessionRegistry, RestoreStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("group-tests-\(UUID())")
        let defaults = UserDefaults(suiteName: "group-tests-\(UUID())")!
        let registry = TerminalSessionRegistry()
        let manager = TerminalWindowManager(registry: registry)
        manager.makeWindow = {
            RestoreModelWindow($0)
        }
        let store = RestoreStore(
            directory: root.appendingPathComponent("Restore"),
            manager: manager,
            defaults: defaults,
            issueCenter: PersistenceIssueCenter(),
            debounceInterval: 0.05,
            startsProcesses: false,
            stateWriter: { state, url in
                if let writes {
                    try writes.write(state, to: url)
                } else {
                    try RestoreStore.writeLayout(state, to: url)
                }
            }
        )
        return (root, defaults, manager, registry, store)
    }

    private func write(_ state: RestoreState, to store: RestoreStore) throws {
        try DurableStateDirectory.makePrivateDirectory(store.directory)
        try DurableStateDirectory.writePrivate(try RestoreStateMigrator().encodeCurrent(state), to: store.windowsURL)
    }

    private func stop(_ manager: TerminalWindowManager) {
        manager.persistenceDidChange = nil
        for window in manager.windows {
            manager.closeWindow(window)
        }
        for group in manager.groups {
            manager.closeGroup(group)
        }
    }

    @Test func versionOneMigratesWindowsNamesMappingSelectionAndPaneIDs() throws {
        struct V1: Encodable {
            let version = 1
            let bootID = "boot"
            let savedAt = Date(timeIntervalSince1970: 100)
            let windows: [RestoreWindowV1]
        }
        let tabs = [group("a").tabs[0], group("b").tabs[0]]
        let old = V1(windows: (0..<40).map {
            RestoreWindowV1(
                frame: "{{\($0), 0}, {800, 600}}",
                screen: "Display",
                isFullScreen: $0 == 0,
                selectedTabIndex: 1,
                tabs: tabs.map { tab in
                    var tab = tab
                    tab.id = UUID()
                    var seen = Set(tab.root.panes.map(\.id))
                    tab.root = tab.root.uniquingPaneIDs(&seen)
                    return tab
                }
            )
        })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let state = try RestoreStateMigrator().decode(encoder.encode(old), from: 1)
        #expect(state.version == 2)
        #expect(state.groups.count == 40)
        #expect(Set(state.groups.map {
            $0.name.lowercased()
        }).count == 40)
        #expect(state.groups.allSatisfy {
            !$0.isNameCustom && $0.selectedTabIndex == 1
        })
        #expect(state.windows.map(\.groupID) == state.groups.map(\.id))
        #expect(state.windows.map(\.frame) == old.windows.map(\.frame))
        #expect(state.groups.flatMap(\.tabs).flatMap(\.root.panes).map(\.id)
            == old.windows.flatMap(\.tabs).flatMap(\.root.panes).map(\.id))
        #expect(state.windows[0].isFullScreen)
        #expect(state.cleanShutdown)
    }

    @Test func versionTwoRoundTripsShownBackgroundOrderNamesAndDates() throws {
        let first = group("Custom", shown: Date(timeIntervalSince1970: 200))
        var background = group("amber-finch", shown: Date(timeIntervalSince1970: 100))
        background.isNameCustom = false
        background.isCollapsed = true
        let state = RestoreState(
            bootID: "boot",
            savedAt: Date(timeIntervalSince1970: 300),
            groups: [first, background],
            windows: [RestoreWindow(groupID: first.id, frame: "{{1, 2}, {800, 600}}", screen: "Display")],
            windowGroupsMigrated: true,
            cleanShutdown: true
        )
        let migrator = RestoreStateMigrator()
        #expect(try migrator.decode(migrator.encodeCurrent(state), from: 2) == state)
    }

    @Test func windowGroupsImportIsDormantUniqueMappedArchivedAndRunsOnce() throws {
        let (root, defaults, manager, _, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        try DurableStateDirectory.makePrivateDirectory(root)
        let tab = SavedTerminalTab(profileID: UUID(), workingDirectory: "/tmp", themeOverride: "Ocean")
        let window = SavedTerminalWindow(frame: "{{0, 0}, {800, 600}}", tabs: [tab, tab], selectedTabIndex: 1)
        let old = SavedWindowGroup(name: "Work", windows: [window, window])
        let single = SavedWindowGroup(name: "Personal", windows: [window])
        let source = root.appendingPathComponent("window-groups.json")
        try WindowGroupsMigrator().encodeCurrent([old, single]).write(to: source)
        defaults.set("windowGroup", forKey: StartupGroups.startupModeKey)
        defaults.set(old.id.uuidString, forKey: StartupGroups.startupWindowGroupIDKey)
        var state = RestoreState(bootID: nil, savedAt: Date(), groups: [group("WORK")], windows: [])
        #expect(store.migrateWindowGroups(in: &state))
        #expect(state.groups.map(\.name) == ["WORK", "Work 2", "Work 2 2", "Personal"])
        #expect(state.groups.dropFirst().allSatisfy {
            $0.isNameCustom && $0.selectedTabIndex == 1
        })
        #expect(defaults.string(forKey: StartupGroups.startupModeKey) == "groups")
        #expect(defaults.stringArray(forKey: StartupGroups.startupGroupIDsKey) == state.groups[1...2].map {
            $0.id.uuidString
        })
        let pane = state.groups[1].tabs[0].root.panes[0]
        #expect(pane.profileID == tab.profileID && pane.directory?.path == tab.workingDirectory && pane.themeOverride == "Ocean")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups/windowGroups/window-groups.json.v1.backup").path))
        let ids = state.groups.map(\.id)
        #expect(store.migrateWindowGroups(in: &state))
        #expect(state.groups.map(\.id) == ids)
        // Keep a shown group so the importer results remain in the background.
        state.windows = [RestoreWindow(groupID: state.groups[0].id, frame: "{{0, 0}, {800, 600}}")]
        try write(state, to: store)
        #expect(store.restore())
        #expect(manager.backgroundGroups.count == 3)
        #expect(manager.backgroundGroups.flatMap(\.tabs).allSatisfy {
            $0.isDormant
        })
    }

    @Test func firstImportShowsAllChosenStartupGroups() throws {
        let (root, defaults, manager, _, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        try DurableStateDirectory.makePrivateDirectory(root)
        let tab = SavedTerminalTab(workingDirectory: "/tmp")
        let window = SavedTerminalWindow(frame: "{{0, 0}, {800, 600}}", tabs: [tab], selectedTabIndex: 0)
        let old = SavedWindowGroup(name: "Startup", windows: [window, window])
        let other = SavedWindowGroup(name: "Background", windows: [window])
        try WindowGroupsMigrator().encodeCurrent([old, other]).write(to: root.appendingPathComponent("window-groups.json"))
        defaults.set("windowGroup", forKey: StartupGroups.startupModeKey)
        defaults.set(old.id.uuidString, forKey: StartupGroups.startupWindowGroupIDKey)
        #expect(!store.restore())
        #expect(manager.groups.flatMap(\.tabs).allSatisfy {
            $0.isDormant
        })
        manager.openStartupWindows(defaults: defaults) { _ in
            Issue.record("Expected the chosen groups")
        }
        #expect(manager.windows.map {
            $0.group.name
        } == ["Startup", "Startup 2"])
        #expect(manager.backgroundGroups.map(\.name) == ["Background"])
        #expect(manager.backgroundGroups[0].tabs[0].isDormant)
    }

    @Test func failedLegacyImportReportsRecoveryAndLeavesSource() throws {
        let (root, _, manager, _, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        try DurableStateDirectory.makePrivateDirectory(root)
        let source = root.appendingPathComponent("window-groups.json")
        try Data("broken".utf8).write(to: source)
        var state = RestoreState(bootID: nil, savedAt: Date(), windows: [])
        #expect(!store.migrateWindowGroups(in: &state))
        #expect(!state.windowGroupsMigrated)
        #expect(store.issueCenter.issues.contains {
            $0.domain == .windowGroups
        })
        #expect(try Data(contentsOf: source) == Data("broken".utf8))
    }

    @Test(arguments: [false, true]) func cleanRestoreIgnoresSystemWindowSetting(_ closesWindows: Bool) async throws {
        let (root, defaults, manager, registry, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(closesWindows, forKey: "NSQuitAlwaysKeepsWindows")
        let a = group("Shown"), b = group("Background")
        var state = RestoreState(
            bootID: nil,
            savedAt: Date(timeIntervalSince1970: 100),
            groups: [a, b],
            windows: [RestoreWindow(groupID: a.id, frame: "{{10, 20}, {800, 600}}")],
            windowGroupsMigrated: true,
            cleanShutdown: true
        )
        try write(state, to: store)
        #expect(store.restore())
        #expect(manager.groups.map(\.id) == [a.id, b.id])
        #expect(manager.windows.map {
            $0.group.id
        } == [a.id])
        #expect(manager.groups[1].tabs[0].isDormant)
        #expect(manager.groups[1].tabs[0].savedSpec?.restoredTab?.panes[b.tabs[0].root.panes[0].id]?.textURL != nil)
        #expect(registry.allControllers.count == 1)
        await withCheckedContinuation { continuation in
            store.saveForTermination {
                continuation.resume()
            }
        }
        state = try #require(store.takeSavedState())
        #expect(state.cleanShutdown && !state.launching && state.groups.count == 2)
    }

    @Test(arguments: [false, true])
    func uncleanExitKeepsDormantTextButDiscardsPreviouslyLiveText(legacy: Bool) throws {
        let (root, _, manager, _, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        var shown = group("Shown"), dormant = group("Dormant"), remote = group("Remote", kind: .remote), backgroundLive = group("Previously live")
        shown.tabs[0].wasDormant = false
        dormant.tabs[0].wasDormant = legacy ? nil : true
        remote.tabs[0].wasDormant = legacy ? nil : true
        backgroundLive.tabs[0].wasDormant = false
        let groups = [shown, dormant, remote, backgroundLive]
        try write(RestoreState(
            bootID: nil,
            savedAt: Date(),
            groups: groups,
            windows: [RestoreWindow(groupID: shown.id, frame: "{{0, 0}, {800, 600}}")],
            windowGroupsMigrated: true
        ), to: store)
        try DurableStateDirectory.makePrivateDirectory(store.panesURL)
        var files: [UUID: [URL]] = [:]
        for group in groups {
            let pane = group.tabs[0].root.panes[0]
            let urls = [RestoreStore.textURL(in: store.panesURL, for: pane.id), RestoreStore.cacheURL(in: store.panesURL, for: pane.id)]
            for url in urls {
                try Data("quit-time text".utf8).write(to: url)
            }
            files[pane.id] = urls
        }
        #expect(store.restore())
        for (index, saved) in groups.enumerated() {
            let paneID = saved.tabs[0].root.panes[0].id
            for url in files[paneID]! {
                #expect(FileManager.default.fileExists(atPath: url.path) == (index == 1 || index == 2))
            }
            if index == 1 || index == 2 {
                let pane = try #require(manager.groups[index].tabs[0].savedSpec?.restoredTab?.panes[paneID])
                #expect(pane.restoresScrollback)
                #expect(pane.textURL != nil || pane.cacheURL != nil)
            }
        }
        #expect(store.takeSavedState()?.groups[1].tabs[0].wasDormant == true)
    }

    @Test func retryMergesRecoveredGroupsBeforeSavingAndKeepsStartupGroup() throws {
        let (root, _, manager, _, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        try DurableStateDirectory.makePrivateDirectory(store.directory)
        try Data("broken json".utf8).write(to: store.windowsURL)
        #expect(!store.restore())
        let startup = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        _ = manager.openWindow(group: startup)
        let recovered = group("Recovered"), background = group("Background")
        try write(RestoreState(
            bootID: nil,
            savedAt: Date(),
            groups: [recovered, background],
            windows: [RestoreWindow(groupID: recovered.id, frame: "{{80, 80}, {700, 500}}")],
            windowGroupsMigrated: true,
            cleanShutdown: true
        ), to: store)
        store.retryRestorationRecovery()
        #expect(Set(manager.groups.map(\.id)) == Set([startup.id, recovered.id, background.id]))
        #expect(manager.windows.map {
            $0.group.id
        }.contains(recovered.id))
        #expect(manager.groups.first {
            $0.id == background.id
        }?.tabs[0].isDormant == true)
        #expect(Set(store.takeSavedState()?.groups.map(\.id) ?? []) == Set(manager.groups.map(\.id)))
    }

    @Test func framePersistenceCallbacksDoNotRearmWholeTreeObservation() async throws {
        let (root, _, manager, _, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        try write(RestoreState(bootID: nil, savedAt: Date(), groups: [group("Saved")], windows: [], windowGroupsMigrated: true), to: store)
        #expect(!store.restore())
        let armed = store.observationGeneration
        for _ in 0..<50 {
            manager.persistenceDidChange?(false)
        }
        #expect(store.observationGeneration == armed)
        manager.groups[0].name = "Renamed"
        for _ in 0..<20 where store.observationGeneration == armed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.observationGeneration > armed)
        store.stateDidChange(immediately: true)
        await store.waitForWrites()
        #expect(store.takeSavedState()?.groups[0].name == "Renamed")
    }

    @Test func crashDuringLaunchKeepsEveryGroupDormantAndOneWindowUntilExplicitShow() throws {
        let (root, _, manager, registry, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        let a = group("a"), b = group("b", kind: .remote)
        try write(RestoreState(bootID: nil, savedAt: Date(), groups: [a, b], windows: [
            RestoreWindow(groupID: a.id, frame: "{{0, 0}, {800, 600}}"),
            RestoreWindow(groupID: b.id, frame: "{{10, 20}, {800, 600}}")
        ], windowGroupsMigrated: true, launching: true), to: store)
        #expect(store.restore())
        #expect(manager.windows.count == 1)
        #expect(manager.groups.flatMap(\.tabs).allSatisfy {
            $0.isDormant
        })
        #expect(registry.allControllers.isEmpty)
        #expect(store.takeSavedState()?.launching == false)
        let window = try #require(manager.windows.first)
        #expect(manager.show(manager.groups[0], in: window))
        #expect(!manager.groups[0].tabs[0].isDormant)
    }

    @Test func hiddenDefaultRestoresAndSavesNothing() async throws {
        let writes = RecordedRestoreWrites()
        let (root, defaults, manager, _, store) = fixture(writes: writes)
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        let state = RestoreState(bootID: nil, savedAt: Date(), groups: [group("keep")], windows: [])
        try write(state, to: store)
        let original = try Data(contentsOf: store.windowsURL)
        defaults.set(true, forKey: RestoreStore.disableKey)
        #expect(!store.restore())
        #expect(manager.groups.isEmpty)
        manager.newGroup(tab: TerminalTab(startsProcesses: false))
        store.stateDidChange(immediately: true)
        await withCheckedContinuation { continuation in
            store.saveForTermination {
                continuation.resume()
            }
        }
        #expect(try Data(contentsOf: store.windowsURL) == original)
        #expect(writes.states.count == 0)
    }

    @Test func dormantTabsStartOnlyOnShowAndCloseWithoutStarting() throws {
        let (root, _, manager, registry, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        let a = group("Shown"), b = group("Start"), c = group("Remote", kind: .remote), d = group("Persistent", kind: .persistent)
        try write(RestoreState(bootID: nil, savedAt: Date(), groups: [a, b, c, d], windows: [
            RestoreWindow(groupID: a.id, frame: "{{0, 0}, {800, 600}}")
        ], windowGroupsMigrated: true), to: store)
        #expect(store.restore())
        let dormant = manager.groups[2].tabs[0]
        #expect(dormant.loadedWorkspace == nil)
        #expect(!GroupCloseConfirmation.requiresConfirmation(manager.groups[2]))
        #expect(registry.allControllers.count == 1)
        let dormantPersistent = manager.groups[3].tabs[0]
        manager.closeGroup(manager.groups[3])
        #expect(dormantPersistent.loadedWorkspace == nil)
        manager.closeGroup(manager.groups[2])
        #expect(dormant.loadedWorkspace == nil)
        let started = manager.groups[1]
        manager.navigate(to: started, in: manager.windows[0])
        #expect(!started.tabs[0].isDormant)
        #expect(registry.allControllers.count == 2)
        #expect(TerminalClosePolicy.runningTaskCount(in: registry.allControllers) == 0)
        let workspace = started.tabs[0].loadedWorkspace
        manager.navigate(to: started)
        #expect(started.tabs[0].loadedWorkspace === workspace)
    }

    @Test func noSavedWindowsShowsMostRecentBackgroundAndDockUsesSameOrder() throws {
        let (root, defaults, manager, _, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        let a = group("Old", shown: Date(timeIntervalSince1970: 1)), b = group("Recent", shown: Date(timeIntervalSince1970: 2))
        let neverShown = group("Never shown")
        try write(RestoreState(bootID: nil, savedAt: Date(), groups: [a, b, neverShown], windows: [], windowGroupsMigrated: true), to: store)
        #expect(!store.restore())
        manager.openStartupWindows(defaults: defaults) { _ in
            Issue.record("Expected a previous group")
        }
        #expect(manager.windows.first?.group.id == b.id)
        manager.closeWindow(manager.windows[0])
        #expect(manager.mostRecentBackgroundGroup?.id == b.id)
        manager.reopenWindow { _ in
            Issue.record("Expected Dock reopen to use the recent group")
        }
        #expect(manager.windows.first?.group.id == b.id)
        #expect(manager.groups[2].lastShownAt == nil && manager.groups[2].tabs[0].isDormant)
    }

    @Test func chosenStartupGroupsOutrankHistoryAndSkipDeletedIDs() throws {
        let (root, defaults, manager, _, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        let recent = group("Recent", shown: Date()), a = group("Chosen A"), b = group("Chosen B")
        try write(RestoreState(bootID: nil, savedAt: Date(), groups: [recent, a, b], windows: [], windowGroupsMigrated: true), to: store)
        defaults.set("groups", forKey: StartupGroups.startupModeKey)
        defaults.set([b.id.uuidString, UUID().uuidString, a.id.uuidString], forKey: StartupGroups.startupGroupIDsKey)
        #expect(!store.restore())
        manager.openStartupWindows(defaults: defaults) { _ in
            Issue.record("Expected the chosen groups")
        }
        #expect(manager.windows.map {
            $0.group.id
        } == [a.id, b.id])
        #expect(manager.backgroundGroups.map(\.id) == [recent.id])
        #expect(manager.backgroundGroups[0].tabs[0].isDormant)
    }

    @Test(arguments: ["default", "profile", "groups"])
    func startupUsesHistoryWhenNoChosenGroupSurvives(_ mode: String) throws {
        let (root, defaults, manager, _, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        let old = group("Old", shown: Date(timeIntervalSince1970: 1))
        let recent = group("Recent", shown: Date(timeIntervalSince1970: 2)), never = group("Never")
        try write(RestoreState(bootID: nil, savedAt: Date(), groups: [old, recent, never], windows: [], windowGroupsMigrated: true), to: store)
        defaults.set(mode, forKey: StartupGroups.startupModeKey)
        defaults.set(UUID().uuidString, forKey: StartupGroups.startupProfileIDKey)
        defaults.set([UUID().uuidString], forKey: StartupGroups.startupGroupIDsKey)
        #expect(!store.restore())
        manager.openStartupWindows(defaults: defaults) { _ in
            Issue.record("History must precede a new window")
        }
        #expect(manager.windows.map {
            $0.group.id
        } == [recent.id])
        #expect(manager.groups[2].lastShownAt == nil && manager.groups[2].tabs[0].isDormant)
    }

    @Test(arguments: ["default", "profile", "groups"])
    func migratedNeverShownGroupsDoNotReplaceANewStartupWindowOrDockWindow(_ mode: String) throws {
        let (root, defaults, manager, _, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        try DurableStateDirectory.makePrivateDirectory(root)
        let window = SavedTerminalWindow(
            frame: "{{0, 0}, {800, 600}}",
            tabs: [SavedTerminalTab(workingDirectory: "/tmp")],
            selectedTabIndex: 0
        )
        let old = SavedWindowGroup(name: "Template", windows: [window])
        try WindowGroupsMigrator().encodeCurrent([old]).write(to: root.appendingPathComponent("window-groups.json"))
        let profileID = UUID()
        defaults.set(mode, forKey: StartupGroups.startupModeKey)
        defaults.set(profileID.uuidString, forKey: StartupGroups.startupProfileIDKey)
        defaults.set([UUID().uuidString], forKey: StartupGroups.startupGroupIDsKey)
        #expect(!store.restore())
        #expect(manager.mostRecentBackgroundGroup == nil)
        var opened: [LaunchSpec] = []
        manager.openStartupWindows(defaults: defaults) {
            opened.append($0)
        }
        #expect(opened.count == 1)
        #expect(opened.first?.profileID == (mode == "profile" ? profileID : nil))
        #expect(opened.first?.activate == false)
        manager.reopenWindow {
            opened.append($0)
        }
        #expect(opened.count == 2)
        #expect(opened[1].profileID == nil)
        #expect(manager.groups[0].lastShownAt == nil && manager.groups[0].tabs[0].isDormant)
        #expect(manager.windows.isEmpty)
    }

    @Test(arguments: [false, true]) func dormantWorkspaceConstructionAlwaysReturnsTheSameWorkspace(_ startExplicitly: Bool) {
        let tab = TerminalTab(dormant: LaunchSpec(workingDirectory: "/tmp"), startsProcesses: false)
        #expect(tab.isDormant && tab.loadedWorkspace == nil && tab.savedSpec != nil)
        if startExplicitly {
            tab.start()
        }
        let workspace = tab.workspace
        #expect(!tab.isDormant && tab.savedSpec == nil)
        #expect(tab.loadedWorkspace === workspace)
        tab.start()
        #expect(tab.workspace === workspace)
        #expect(workspace.focusedController?.terminal == nil)
        workspace.terminateAll()
    }

    @Test(arguments: [false, true])
    func quitSupersedesPendingDebounceAndFinishesAfterAlreadyQueuedLayouts(_ queueLayoutBeforeQuit: Bool) async throws {
        let writes = RecordedRestoreWrites()
        let (root, _, manager, _, store) = fixture(writes: writes)
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        try write(RestoreState(
            bootID: nil,
            savedAt: Date(),
            groups: [group("Before")],
            windows: [],
            windowGroupsMigrated: true
        ), to: store)
        #expect(!store.restore())
        manager.rename(manager.groups[0], to: "At quit")
        if queueLayoutBeforeQuit {
            store.stateDidChange(immediately: true)
        }
        await store.waitForWrites()
        #expect(writes.states.count == (queueLayoutBeforeQuit ? 1 : 0))
        await withCheckedContinuation { continuation in
            store.saveForTermination {
                continuation.resume()
            }
        }
        let final = try #require(store.takeSavedState())
        let bytes = try Data(contentsOf: store.windowsURL)
        #expect(final.cleanShutdown && final.groups[0].name == "At quit")
        #expect(writes.states.count == (queueLayoutBeforeQuit ? 2 : 1))
        // Let the original debounce deadline and deferred observation callbacks
        // run, including a late change that must not replace the final save.
        manager.rename(manager.groups[0], to: "After quit")
        store.stateDidChange(immediately: true)
        try await Task.sleep(for: .milliseconds(180))
        await store.waitForWrites()
        #expect(writes.states.count == (queueLayoutBeforeQuit ? 2 : 1))
        #expect(try Data(contentsOf: store.windowsURL) == bytes)
        #expect(store.takeSavedState()?.cleanShutdown == true)
    }

    @Test func changesDebounceAndLaterChangeWritesAgain() async throws {
        let writes = RecordedRestoreWrites()
        let (root, _, manager, _, store) = fixture(writes: writes)
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        let a = group("Shown"), b = group("Background")
        try write(RestoreState(bootID: nil, savedAt: Date(), groups: [a, b], windows: [
            RestoreWindow(groupID: a.id, frame: "{{0, 0}, {800, 600}}")
        ], windowGroupsMigrated: true), to: store)
        #expect(store.restore())
        for index in 0..<8 {
            manager.rename(manager.groups[1], to: "change \(index)")
        }
        try await waitForWrites(store, recorded: writes, count: 1)
        #expect(writes.states.count == 1)
        #expect(store.takeSavedState()?.groups[1].name == "change 7")
        manager.groups[1].isCollapsed = true
        try await waitForWrites(store, recorded: writes, count: 2)
        #expect(writes.states.count == 2)
        #expect(store.takeSavedState()?.groups[1].isCollapsed == true)
    }

    @Test func duplicateKeepsStructureButUsesNewIDsNameAndFreshSessions() throws {
        let (_, _, manager, _, _) = fixture()
        let first = group("source", kind: .remote).tabs[0].root.panes[0]
        let second = group("persistent", kind: .persistent).tabs[0].root.panes[0]
        let saved = RestoreTab(
            name: "Build",
            focusedPaneID: second.id,
            zoomedPaneID: first.id,
            root: .split(.vertical, fraction: 0.3, first: .pane(first), second: .pane(second))
        )
        let tab = TerminalTab(dormant: RestoreStore.launchSpec(for: RestoredTab(tab: saved, panes: [:])))
        let source = manager.newGroup(tab: tab)
        defer { stop(manager) }
        let copy = manager.duplicate(source, showInWindow: false)
        let duplicate = try #require(copy.tabs[0].savedSpec?.restoredTab)
        #expect(tab.isDormant && copy.tabs[0].isDormant)
        #expect(copy.id != source.id && copy.name != source.name && !copy.isNameCustom)
        #expect(copy.tabs[0].id != tab.id && duplicate.tab.name == "Build")
        #expect(Set(duplicate.tab.root.panes.map(\.id)).isDisjoint(with: saved.root.panes.map(\.id)))
        #expect(duplicate.tab.root.panes.map(\.kind) == [.remote, .persistent])
        #expect(duplicate.tab.root.panes.allSatisfy {
            $0.sessionID == nil
        })
        #expect(duplicate.tab.root.panes.map(\.remoteDestination) == saved.root.panes.map(\.remoteDestination))
        #expect(duplicate.tab.root.panes.map(\.profileID) == saved.root.panes.map(\.profileID))
        #expect(duplicate.tab.root.panes.map(\.directory) == saved.root.panes.map(\.directory))
        #expect(duplicate.tab.root.panes.map(\.themeOverride) == saved.root.panes.map(\.themeOverride))
        #expect(duplicate.panes.values.allSatisfy {
            $0.startsFresh
        })
        guard case .split(.vertical, 0.3, _, _) = duplicate.tab.root else {
            Issue.record("Lost split structure")
            return
        }
        #expect(duplicate.tab.focusedPaneID == duplicate.tab.root.panes[1].id)
        #expect(duplicate.tab.zoomedPaneID == duplicate.tab.root.panes[0].id)
    }

    @Test(arguments: ["corrupt", "newer"]) func unreadableSchemasArePreservedAndBlockSaving(_ mode: String) async throws {
        let (root, _, manager, _, store) = fixture()
        defer { stop(manager)
            try? FileManager.default.removeItem(at: root)
        }
        try DurableStateDirectory.makePrivateDirectory(store.directory)
        let data = Data((mode == "corrupt" ? "bad" : "{\"version\":99}").utf8)
        try data.write(to: store.windowsURL)
        #expect(!store.restore())
        manager.newGroup(tab: TerminalTab(startsProcesses: false))
        store.stateDidChange(immediately: true)
        await withCheckedContinuation { continuation in
            store.saveForTermination {
                continuation.resume()
            }
        }
        #expect(try Data(contentsOf: store.windowsURL) == data)
        #expect(store.issueCenter.issues.first?.kind == (mode == "newer" ? .unsupportedVersion : .invalidFormat))
    }
}
