import AppKit
import Testing
import TecolotSessionDirectory
import TecolotSessionClient
import TecolotWire
@testable import Tecolot

@MainActor
private final class ReviewWindow: TerminalGroupWindow {
    let id = UUID()
    var group: TerminalTabGroup
    init(_ group: TerminalTabGroup) {
        self.group = group
    }
    func show(_ group: TerminalTabGroup) {
        self.group = group
        for tab in group.tabs where !tab.isDormant {
            _ = tab.hostView
        }
    }
    func activate() {}
    func closeWindow() {}
}

@MainActor
@Suite(.serialized)
struct Round17ReviewTests {
    private func fixture() -> (TerminalWindowManager, TerminalSessionRegistry) {
        let registry = TerminalSessionRegistry()
        let manager = TerminalWindowManager(registry: registry)
        manager.makeWindow = {
            ReviewWindow($0)
        }
        return (manager, registry)
    }
    private func dormant(kind: RestorePaneKind = .persistent, destination: String? = nil, session: String? = "owned") -> TerminalTab {
        let pane = RestorePane(id: UUID(), kind: kind, directory: PaneDirectory(path: "/remote/work", source: .osc7), sessionID: session, remoteDestination: destination)
        let saved = RestoreTab(focusedPaneID: pane.id, root: .pane(pane))
        let restore = PaneRestoration(pane: pane, savedAt: Date(), macRestarted: false, textURL: nil, sessionRunning: true)
        return TerminalTab(dormant: RestoreStore.launchSpec(for: RestoredTab(tab: saved, panes: [pane.id: restore])), startsProcesses: false)
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

    @Test func dormantSessionLookupLoadsOnlyItsOwnerAndReservesIDs() throws {
        let (manager, registry) = fixture()
        defer { stop(manager) }
        let local = dormant()
        let remote = dormant(kind: .remote, destination: "test-host")
        let localGroup = manager.newGroup(tab: local)
        let remoteGroup = manager.newGroup(tab: remote)
        #expect(registry.persistentSessionIDsInUse() == ["owned"])
        #expect(registry.persistentSessionIDsInUse(destination: "test-host") == ["owned"])
        #expect(registry.controller(showingPersistentSession: "owned", loadDormant: false) == nil)
        #expect(registry.controller(showingPersistentSession: "missing") == nil)
        #expect(local.isDormant && remote.isDormant)
        let found = try #require(registry.controller(showingPersistentSession: "owned", destination: "test-host"))
        #expect(!remote.isDormant && local.isDormant)
        #expect(found.workspace?.owningTab === remote)
        #expect(found.id == remoteGroup.tabs[0].workspace.controllers[0].id)
        #expect(localGroup.tabs[0].isDormant)
        #expect(registry.controller(showingPersistentSession: "owned", destination: "test-host") === found)
    }

    @Test func soleTabTearOffDoesNotCloseOrStartAnyGroup() {
        let (manager, _) = fixture()
        defer { stop(manager) }
        let background = manager.newGroup(tab: dormant())
        background.lastShownAt = Date()
        let only = TerminalTab(startsProcesses: false)
        let source = manager.newGroup(tab: only)
        let owner = manager.openWindow(group: source)
        #expect(manager.moveToNewWindow(only, from: source) == nil)
        #expect(manager.groups.count == 2 && manager.windows.count == 1)
        #expect(owner.group === source && source.tabs.first === only)
        #expect(background.tabs[0].isDormant)
    }

    @Test func splitInheritsRemoteDirectoryAndHost() throws {
        let source = TerminalSessionController(startsProcess: false)
        source.resolveLaunchIfNeeded(spec: LaunchSpec(remoteDestination: "test-host"))
        source.noteDirectoryReport("file://test-host/remote/with%20spaces")
        let split = TerminalSessionController(startsProcess: false)
        split.prepareForSplit(from: source)
        #expect(split.remoteDestination == "test-host")
        #expect(split.launchDirectory == "/remote/with spaces")
        #expect(split.profile.id == source.profile.id)
    }

    @Test(arguments: ["merge", "tearOff", "move", "newGroup"])
    func everyImmediateSaveDuringTransfersContainsAllLiveTabs(operation: String) throws {
        let (manager, _) = fixture()
        defer { stop(manager) }
        let a = manager.newGroup(tab: dormant())
        let first = manager.openWindow(group: a, startsGroup: false)
        let b = manager.newGroup(tab: dormant())
        let second = manager.openWindow(group: b, startsGroup: false)
        if operation == "tearOff" {
            manager.addTab(dormant(), to: a)
        }
        let expected = Set(manager.groups.flatMap(\.tabs).map(\.id))
        let store = RestoreStore(directory: URL(fileURLWithPath: "/tmp/unused-m17"), manager: manager)
        var snapshots: [Set<UUID>] = []
        manager.persistenceDidChange = { immediate in
            if immediate {
                snapshots.append(Set(store.capture(limit: 0).0.groups.flatMap(\.tabs).map(\.id)))
            }
        }
        switch operation {
        case "merge":
            manager.mergeAllWindows(into: first)
        case "tearOff":
            _ = manager.moveToNewWindow(a.tabs[0], from: a)
        case "move":
            manager.move(a.tabs[0], from: a, to: b)
        default:
            manager.moveToNewGroup(a.tabs[0])
        }
        _ = second
        for saved in snapshots {
            #expect(saved == expected)
        }
        #expect(Set(manager.groups.flatMap(\.tabs).map(\.id)) == expected)
    }

    @Test func duplicateKeepsRemoteHostDirectoryAndSelectedIdentityAfterAnOmittedTab() throws {
        let (manager, _) = fixture()
        defer { stop(manager) }
        // A local controller with no terminal cannot be captured.
        let omitted = TerminalTab(startsProcesses: false)
        let source = manager.newGroup(tab: omitted)
        let chosen = dormant(kind: .remote, destination: "test-host")
        manager.addTab(chosen, to: source)
        manager.addTab(dormant(), to: source)
        source.selection = chosen.id
        let copy = try #require(manager.duplicate(source, showInWindow: false))
        #expect(copy.tabs.count == 2)
        let selected = try #require(copy.selectedTab?.savedSpec?.restoredTab?.tab.root.panes.first)
        #expect(selected.kind == .remote)
        #expect(selected.remoteDestination == "test-host")
        #expect(selected.directory?.path == "/remote/work")
        #expect(selected.sessionID == nil)
        let restoration = try #require(copy.selectedTab?.savedSpec?.restoredTab?.panes[selected.id])
        let controller = TerminalSessionController(startsProcess: false)
        controller.presetRestore(restoration)
        #expect(controller.remoteDestination == "test-host")
        #expect(controller.launchDirectory == "/remote/work")
    }
}

@MainActor
@Suite(.serialized)
struct Round17StartupAndEfficiencyTests {
    @Test(arguments: ["ready", "timeout", "quit"])
    func launchGuardSurvivesAsyncStartupAndAllLayoutSaves(until: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m17-guard-\(UUID())")
        let suite = "m17-guard-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            ReviewWindow($0)
        }
        var ready = false
        let store = RestoreStore(directory: root, runningSessions: {
            []
        }, manager: manager, defaults: defaults, issueCenter: PersistenceIssueCenter(), startsProcesses: false, startupTimeout: until == "timeout" ? 0.05 : 60, startupReady: { _ in
            ready
        })
        defer {
            manager.persistenceDidChange = nil
            for group in manager.groups {
                manager.closeGroup(group)
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let pane = RestorePane(id: UUID(), kind: .local)
        let group = RestoreGroup(name: "Restored", tabs: [RestoreTab(root: .pane(pane))])
        let state = RestoreState(bootID: nil, savedAt: Date(), groups: [group], windows: [RestoreWindow(groupID: group.id, frame: "{{0, 0}, {800, 600}}")], windowGroupsMigrated: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try RestoreStateMigrator().encodeCurrent(state).write(to: store.windowsURL)
        #expect(store.restore())
        #expect(store.takeSavedState()?.launching == true)
        store.stateDidChange(immediately: true)
        await store.waitForWrites()
        #expect(store.takeSavedState()?.launching == true)
        if until == "quit" {
            await withCheckedContinuation { continuation in
                store.saveForTermination {
                    continuation.resume()
                }
            }
            #expect(store.takeSavedState()?.cleanShutdown == true)
        } else {
            if until == "ready" {
                ready = true
            }
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(10))
                await store.waitForWrites()
                if store.takeSavedState()?.launching == false {
                    break
                }
            }
        }
        #expect(store.takeSavedState()?.launching == false)
    }

    @Test func persistentStartupWaitsForAReplyAfterAttachIncludingHiddenPanes() {
        var state = RemoteSession(socket: -1, clientName: "test", build: "test").state
        #expect(!TerminalSessionController.persistentStartupHasCompleted(state))
        state.connected = true
        // A Hello reply alone does not prove that Attach or replay has run.
        #expect(!TerminalSessionController.persistentStartupHasCompleted(state))
        state.lastFrameSequence = 1
        #expect(TerminalSessionController.persistentStartupHasCompleted(state))
        state.lastFrameSequence = 0
        state.info = SessionInfoMessage(shellPID: 42, shellName: "zsh", foreground: nil, hasChildren: false)
        #expect(TerminalSessionController.persistentStartupHasCompleted(state))
    }

    @Test func processInspectionCoalescesVisibilityAndLayoutRequests() async {
        let updates = ProcessInspectionUpdates()
        var evaluations = 0
        for _ in 0..<50 {
            updates.request {
                evaluations += 1
            }
        }
        #expect(evaluations == 0)
        await withCheckedContinuation { c in
            DispatchQueue.main.async {
                c.resume()
            }
        }
        #expect(evaluations == 1)
        updates.request {
            evaluations += 1
        }
        await withCheckedContinuation { c in
            DispatchQueue.main.async {
                c.resume()
            }
        }
        #expect(evaluations == 2)
        updates.request {
            evaluations += 1
        }
        updates.cancel()
        await withCheckedContinuation { c in
            DispatchQueue.main.async {
                c.resume()
            }
        }
        #expect(evaluations == 2)
    }

    @Test func restoredAndCascadedWindowFramesDoNotMeasureAThrowawayTerminal() throws {
        let suite = "m17-sizing-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var measurements = 0
        let store = TerminalWindowSizeStore(defaults: defaults, profileContentSize: { _ in
            measurements += 1
            return NSSize(width: 600, height: 400)
        })
        let frame = NSRect(x: 100, y: 100, width: 700, height: 500)
        let profile = TerminalProfile(name: "Test")
        let style = SidebarPreferences(defaults: defaults)
        for policy in [TerminalWindowInitialFrame.windowGroup(frame), .cascaded(frame)] {
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            store.prepare(window, profile: profile, style: style, policy: policy, cascadeFrom: nil)
        }
        #expect(measurements == 0)
        defaults.set(NSStringFromRect(frame), forKey: "lastTerminalWindowFrame")
        let saved = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        store.prepare(saved, profile: profile, style: style, policy: .saved, cascadeFrom: nil)
        #expect(measurements == 0)
        let fresh = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        store.prepare(fresh, profile: profile, style: style, policy: .profile, cascadeFrom: nil)
        #expect(measurements == 1)
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["TECOLOT_KEYBOARD_SHEET_TEST"] == "1",
        "Run this foreground sheet test in isolation with TEST_RUNNER_TECOLOT_KEYBOARD_SHEET_TEST=1"
    ))
    func closeConfirmationReturnAndEscapeReachTheProductionSheet() async throws {
        let parent = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        parent.orderBack(nil)
        var confirmed = false
        defer {
            if let sheet = parent.attachedSheet {
                NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertSecondButtonReturn.rawValue)
            }
            parent.orderOut(nil)
        }
        for (code, text) in [(UInt16(53), "\u{1b}"), (UInt16(36), "\r")] {
            TabCloseConfirmation.present(required: true, title: "Keyboard regression", in: parent) {
                confirmed = true
            }
            let sheet = try #require(parent.attachedSheet)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            NSApp.postEvent(event, atStart: false)
            let deadline = ContinuousClock.now + .seconds(8)
            while (parent.attachedSheet != nil || code == 36 && !confirmed) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(parent.attachedSheet == nil)
            #expect(confirmed == (code == 36))
        }
    }

    @Test func confirmationReturnEscapeAndModifiersStayScopedToTheAlert() throws {
        let alert = NSAlert()
        alert.addButton(withTitle: "Close").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        alert.window.orderBack(nil)
        defer { alert.window.orderOut(nil) }
        func key(_ code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow? = nil) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: (window ?? alert.window).windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        #expect(ConfirmationKeyboard.button(for: try key(36, "\r"), in: alert) === alert.buttons[0])
        #expect(ConfirmationKeyboard.button(for: try key(76, "\u{3}"), in: alert) === alert.buttons[0])
        #expect(ConfirmationKeyboard.button(for: try key(53, "\u{1b}"), in: alert) === alert.buttons[1])
        #expect(ConfirmationKeyboard.button(for: try key(36, "\r", modifiers: .command), in: alert) == nil)
        let other = NSWindow()
        #expect(ConfirmationKeyboard.button(for: try key(36, "\r", in: other), in: alert) == nil)
        alert.buttons[0].isEnabled = false
        #expect(ConfirmationKeyboard.button(for: try key(36, "\r"), in: alert) == nil)
    }
}
