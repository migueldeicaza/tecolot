import AppKit
import SwiftTerm
import Synchronization
import Testing
import TecolotWire
import UserNotifications
@testable import Tecolot

@MainActor
struct ProgramActivityTests {
    private func store() -> ProgramActivitySeenStore {
        ProgramActivitySeenStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("M4-seen-\(UUID())")
        )
    }
    private func record(_ state: ProgramStatusState, id: String = "", time: UInt64 = 1, message: String? = nil)
    -> WireProgramStatus {
        WireProgramStatus(id: id, state: state, message: message, reportTime: time)
    }

    /// Every row and every cross-pane pairing of the §11.7 reduction table.
    @Test(arguments: ProgramStatusState.allCases, ProgramStatusState.allCases)
    func reduction(lhs: ProgramStatusState, rhs: ProgramStatusState) {
        let left = TabStatus.Record(paneID: UUID(), value: record(lhs, time: 10), unseen: true)
        let right = TabStatus.Record(paneID: UUID(), value: record(rhs, time: 20), unseen: true)
        let result = TabStatus.reduce([left, right])
        #expect(result.state == (lhs.priority > rhs.priority ? lhs : rhs))
        if lhs == rhs {
            #expect(result.winner?.paneID == right.paneID)
        }
        #expect(TabStatus.reduce([]) == .none)
    }

    @Test func badgePriorityIncludesSeenAndMutedRecords() {
        let pane = UUID()
        let values = [record(.blocked, id: "permission"), record(.error, id: "error"), record(.done, id: "done")]
        let records = values.map {
            TabStatus.Record(paneID: pane, value: $0, unseen: true)
        }
        #expect(TabStatus.reduce(records, quiet: true, notified: true).badge == .blocked)
        #expect(TabStatus.reduce(Array(records.dropFirst()), quiet: true, notified: true).badge == .error)
        #expect(TabStatus.reduce(Array(records.dropFirst(2)), quiet: true, notified: true).badge == .done)
        #expect(TabStatus.reduce([], quiet: true, notified: true).badge == .notified)
        #expect(TabStatus.reduce([], quiet: true).badge == .quiet)
        var seenBlocked = records
        seenBlocked[0].unseen = false
        let result = TabStatus.reduce(seenBlocked)
        #expect(result.state == .blocked && result.badge == .error)
        #expect(TabStatus.reduce(records, muted: true).badge == nil)
        #expect(TabStatus.reduce(records, muted: true).blocked.isEmpty)
        #expect(TabStatus.reduce(records, disabledStates: [.blocked, .error]).badge == .done)
        #expect(
            TabStatus.dockCount([result, TabStatus.reduce(records), .none, TabStatus.reduce([], notified: true)]) == 2
        )
    }

    @Test(arguments: ProgramStatusState.allCases)
    func lifetime(state: ProgramStatusState) {
        var now = 10.0
        let status = PaneProgramStatus(paneID: UUID(), seen: store(), now: {
            now
        }, schedules: false)
        status.receive(ProgramStatusMessage(records: [record(state)]))
        now += 0.3
        status.flush()
        #expect(status.records.count == 1)
        status.keypress()  // unseen completions survive
        #expect(status.records.count == 1)
        status.dropTransient()  // both process exit and new prompt use this rule
        #expect(status.records.count == (state.isCompletion ? 1 : 0))
        if state.isCompletion {
            status.markSeen()
            #expect(status.records.count == 1)
            #expect(status.tabStatus.badge == nil)
            status.keypress()
            #expect(status.records.isEmpty)
        }
    }

    @Test func seenStoreKeysPersistWithoutCollisions() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M4-seen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = UUID(), b = UUID()
        let first = ProgramActivitySeenStore(directory: directory)
        let value = record(.done, id: "a/b", time: 101)
        first.markSeen(pane: a, records: [value])
        #expect(first.flush())
        let reloaded = ProgramActivitySeenStore(directory: directory)
        #expect(reloaded.isSeen(pane: a, record: value))
        #expect(!reloaded.isSeen(pane: b, record: value))
        #expect(!reloaded.isSeen(pane: a, record: record(.done, id: "a/b", time: 102)))
        #expect(!reloaded.isSeen(pane: a, record: record(.done, id: "a", time: 101)))
    }

    @Test func blockedProgressDoesNotRearmButANewMessageDoes() {
        var now = 1.0
        let status = PaneProgramStatus(paneID: UUID(), seen: store(), now: {
            now
        }, schedules: false)
        var value = record(.blocked, message: "Allow?")
        status.receive(ProgramStatusMessage(records: [value]))
        now += 0.3
        status.flush()
        status.markSeen()
        value.progress = 50
        value.reportTime = 2
        status.receive(ProgramStatusMessage(records: [value]))
        #expect(status.tabStatus.badge == nil)
        value.message = "Another permission?"
        value.reportTime = 3
        status.receive(ProgramStatusMessage(records: [value]))
        #expect(status.tabStatus.badge == .blocked)
    }

    @Test func fallbackAndReset() {
        var now = 1.0
        let status = PaneProgramStatus(paneID: UUID(), seen: store(), now: {
            now
        }, schedules: false)
        for (code, expected, progress) in [
            (UInt8(1), ProgramStatusState.working, 40), (3, .working, -1), (2, .error, -1),
        ] {
            status.receiveProgress(WireProgress(state: code, progress: 40))
            now += 0.3
            status.flush()
            #expect(status.records.first?.state == expected)
            #expect(status.records.first?.progress == (progress < 0 ? nil : progress))
        }
        status.receiveProgress(WireProgress(state: 0, progress: nil))
        #expect(status.records.isEmpty)
        status.receive(ProgramStatusMessage(records: [record(.done)]))
        now += 0.3
        status.flush()
        status.receiveProgress(WireProgress(state: 1, progress: 20))
        #expect(status.records.first?.state == .done)
        status.receive(ProgramStatusMessage(records: [], uses7501: true))
        #expect(status.records.isEmpty)
        status.receiveProgress(WireProgress(state: 1, progress: 20))
        now += 0.3
        status.flush()
        #expect(status.records.isEmpty)
        status.receive(ProgramStatusMessage(records: [], uses7501: false, resetSerial: 1))
        status.receiveProgress(WireProgress(state: 1, progress: 20))
        now += 0.3
        status.flush()
        #expect(status.records.first?.progress == 20)
    }

    @Test func remoteFallbackUsesHostReportTimeAndKeepsSeenStateDuringOutput() {
        var now = 1.0
        let status = PaneProgramStatus(paneID: UUID(), seen: store(), now: {
            now
        }, schedules: false)
        var snapshot = ProgramStatusMessage(
            records: [], uses7501: false, progress: WireProgress(state: 2, progress: nil)
        )
        snapshot.progressReportTime = 123
        status.receive(snapshot)
        now += 0.3
        status.flush()
        #expect(status.records.first?.reportTime == 123)
        status.markSeen()
        snapshot.outputSerial = 2
        status.receive(snapshot)
        now += 0.3
        status.flush()
        #expect(status.tabStatus.badge == nil)
        status.dropTransient()
        #expect(status.records.first?.state == .error)
        status.keypress()
        status.receive(snapshot)
        #expect(status.records.isEmpty)
        snapshot.progressReportTime = 124
        status.receive(snapshot)
        now += 0.3
        status.flush()
        #expect(status.tabStatus.badge == .error)
    }

    @Test func reattachedSessionStartsANewOutputActivityBaseline() {
        let controller = TerminalSessionController(startsProcess: false)
        defer { controller.terminate() }
        var snapshot = ProgramStatusMessage(records: [])
        snapshot.outputSerial = 10
        controller.handlePersistentEvent(.programStatus(snapshot))
        #expect(!controller.programStatus.quiet)
        let replacement = controller.makeRemoteSession(socket: -1)
        defer { replacement.close() }
        // Output while the old connection was visible is part of the new attach baseline.
        snapshot.outputSerial = 20
        controller.handlePersistentEvent(.programStatus(snapshot))
        #expect(!controller.programStatus.quiet)
        snapshot.outputSerial = 21
        controller.handlePersistentEvent(.programStatus(snapshot))
        #expect(controller.programStatus.quiet)
    }

    @Test func flapCoalescerWithFakeClock() {
        var coalescer = ProgramStatusCoalescer()
        coalescer.submit([record(.working)], at: 0)
        coalescer.advance(to: 0.299)
        #expect(coalescer.records.isEmpty)
        coalescer.advance(to: 0.3)
        #expect(coalescer.records.first?.state == .working)
        coalescer.submit([record(.blocked)], at: 1)
        coalescer.submit([record(.error)], at: 1.2)
        coalescer.advance(to: 1.3)
        #expect(coalescer.records.first?.state == .working)
        coalescer.advance(to: 1.5)
        #expect(coalescer.records.first?.state == .error)
        coalescer.submit([record(.done, id: "child")], at: 2)
        coalescer.submit([record(.done, id: "child", time: 3)], at: 2.2)
        coalescer.advance(to: 2.3)
        #expect(coalescer.records.first?.reportTime == 3)
        coalescer.submit([], at: 2.4)
        #expect(coalescer.records.isEmpty)
    }

    @Test func quietUsesTabVisibilityAndWindowKeyState() {
        for shown in [true, false] {
            for key in [true, false] {
                #expect(PaneProgramStatus.isQuiet(tabShown: shown, windowKey: key) == (!shown || !key))
            }
        }
    }

    @Test func notificationAndSoundLimitsUseIndependentTabClocks() {
        var limiter = ProgramActivityRateLimiter()
        let tab = UUID(), other = UUID()
        func admit(tab: UUID, sound: Bool, now: TimeInterval) -> Bool {
            limiter.admit(tab: tab, sound: sound, now: now)
        }
        #expect(admit(tab: tab, sound: false, now: 10))
        #expect(admit(tab: tab, sound: true, now: 10))
        #expect(!admit(tab: tab, sound: false, now: 11.999))
        #expect(!admit(tab: tab, sound: true, now: 11.999))
        #expect(admit(tab: other, sound: false, now: 11))
        #expect(admit(tab: tab, sound: false, now: 12))
        #expect(admit(tab: tab, sound: true, now: 12))
    }

    @Test func sanitizingAndAccessibleBadgeKinds() {
        let formatting =
            "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}"
        #expect(ProgramStatusText.sanitize("A" + formatting + "\u{1B}\n\u{7F}\u{85}B") == "AB")
        #expect(ProgramStatusText.sanitize(String(repeating: "é", count: 2000)).utf8.count == 2048)
        for (kind, symbol, label) in [
            ("permission", "hand.raised.fill", "Needs permission"), ("question", "questionmark", "Needs an answer"),
            ("auth", "key.fill", "Needs authentication"),
        ] {
            let value = WireProgramStatus(state: .blocked, kind: kind, message: "Run tests?")
            let status = TabStatus.reduce([.init(paneID: UUID(), value: value, unseen: true)])
            #expect(status.badgeSymbol == symbol)
            #expect(status.accessibilityValue == label + ": Run tests?")
        }
    }

    @Test func tickerRotatesPaneWinnersAndCarriesTheirApps() {
        let first = UUID(), second = UUID()
        let records = [
            TabStatus.Record(
                paneID: first,
                value: WireProgramStatus(id: "old", state: .blocked, app: "claude-code", message: "Old", reportTime: 1),
                unseen: true
            ),
            TabStatus.Record(
                paneID: first,
                value: WireProgramStatus(id: "new", state: .blocked, app: "claude-code", message: "New", reportTime: 3),
                unseen: true
            ),
            TabStatus.Record(
                paneID: second, value: WireProgramStatus(state: .blocked, message: "Other pane", reportTime: 2),
                unseen: true
            ),
        ]
        let status = TabStatus.reduce(records)
        #expect(status.blocked.map {
            $0.value.message
        } == ["New", "Other pane"])
        #expect(status.app == "claude-code")
    }

    @Test func seenFileAndPreferencesOnlyInvalidateForTheirOwnChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M4-file-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: "M4-preferences-\(UUID())"))
        let settings = ProgramActivitySettings(defaults: defaults)
        let original = settings.value
        let changes = Mutex(0)
        let observer = NotificationCenter.default.addObserver(
            forName: .programActivityPreferencesDidChange, object: settings, queue: nil
        ) { _ in
            changes.withLock {
                $0 += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let seen = ProgramActivitySeenStore(directory: directory)
        seen.markSeen(pane: UUID(), records: [record(.done)])
        #expect(seen.revision == 1)
        #expect(seen.flush())
        settings.refresh()
        #expect(settings.value == original)
        defaults.set("unrelated", forKey: "unrelated")
        settings.refresh()
        #expect(settings.value == original)
        #expect(changes.withLock {
            $0
        } == 0)
        defaults.set(false, forKey: ProgramActivityPreferences.colorKey)
        settings.refresh()
        #expect(!settings.value.color)
        #expect(changes.withLock {
            $0
        } == 1)
        settings.refresh()
        #expect(changes.withLock {
            $0
        } == 1)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("seen.json").path))
    }

    @Test func seenWritesDebounceAndMigrateTheOldDefaultsKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M4-migrate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try #require(UserDefaults(suiteName: "M4-old-seen-\(UUID())"))
        let pane = UUID()
        let value = record(.done, id: "build", time: 100)
        let key = ProgramActivitySeenStore.key(pane: pane, record: value.id)
        defaults.set(
            try JSONEncoder().encode([key: value.reportTime]), forKey: ProgramActivitySeenStore.legacyDefaultsKey
        )
        let seen = ProgramActivitySeenStore(directory: directory, debounceInterval: 0.05, legacyDefaults: defaults)
        #expect(seen.isSeen(pane: pane, record: value))
        #expect(defaults.object(forKey: ProgramActivitySeenStore.legacyDefaultsKey) == nil)
        let next = record(.done, id: "build", time: 101)
        seen.markSeen(pane: pane, records: [next])
        let final = record(.done, id: "build", time: 102)
        seen.markSeen(pane: pane, records: [final])
        let before = ProgramActivitySeenStore(directory: directory)
        #expect(before.isSeen(pane: pane, record: value))
        try await Task.sleep(for: .milliseconds(150))
        let reloaded = ProgramActivitySeenStore(directory: directory)
        #expect(reloaded.isSeen(pane: pane, record: final))
        #expect(!reloaded.isSeen(pane: pane, record: next))
        #expect(defaults.object(forKey: ProgramActivitySeenStore.legacyDefaultsKey) == nil)
    }

    @Test func promptAvailabilityRequiresActiveAppAndVisibleObserverOnSameLink() {
        let activity = RemoteAppActivity()
        let first = NSObject(), second = NSObject()
        let firstID = ObjectIdentifier(first), secondID = ObjectIdentifier(second)
        activity.setVisibleLinks([firstID])  // Includes a Sessions window observer.
        #expect(!activity.canPrompt(link: firstID))
        activity.set(true)
        #expect(activity.canPrompt(link: firstID))
        #expect(!activity.canPrompt(link: secondID))  // Background-group panes.
        activity.setVisibleLinks([firstID, secondID])  // Group shown.
        #expect(activity.canPrompt(link: secondID))
        activity.set(false)
        #expect(!activity.canPrompt(link: secondID))
    }

    @Test(arguments: BellStyle.allCases.map(\.tagName))
    func bellStylesPreserveLocalAndPersistentPolicy(name: String) throws {
        let style = try #require(BellStyle(tagName: name))
        let local = ProgramActivityBell.policy(style: style, local: true)
        #expect(local.sound == (style == .sound || style == .soundAndVisual))
        #expect(local.visual == (style == .visual || style == .soundAndVisual))
        let persistent = ProgramActivityBell.policy(style: style, local: false)
        #expect(persistent.sound == (style != .none))
        #expect(!persistent.visual)
    }

    @Test func attentionAndSoundHaveIndependentTwoSecondWindows() {
        let notifier = TerminalNotifier()
        let controller = TerminalSessionController(startsProcess: false)
        defer { controller.terminate() }
        var sounds = 0, bounces = 0
        notifier.sound = {
            sounds += 1
        }
        notifier.attention = {
            bounces += 1
        }
        let start = Date(timeIntervalSince1970: 100)
        for delta in [0.0, 0.5, 1.999, 2.0] {
            let now = start.addingTimeInterval(delta)
            notifier.playBell(from: controller, now: now)
            notifier.requestAttention(from: controller, now: now, appActive: false)
        }
        #expect(sounds == 2 && bounces == 2)
        notifier.requestAttention(from: controller, now: start.addingTimeInterval(4), appActive: true)
        #expect(bounces == 2)
    }

    @Test func activityKeysDismissAndArrowSelectionClamps() throws {
        func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
                )
            )
        }
        #expect(ActivityNavigation.isDismissKey(try key(47, characters: ".", modifiers: .command)))
        #expect(ActivityNavigation.isDismissKey(try key(53, characters: "\u{1b}")))
        #expect(!ActivityNavigation.isDismissKey(try key(36, characters: "\r")))
        #expect(ActivityNavigation.moved(0, count: 3, down: true) == 1)
        #expect(ActivityNavigation.moved(2, count: 3, down: true) == 2)
        #expect(ActivityNavigation.moved(0, count: 3, down: false) == 0)
        #expect(ActivityNavigation.moved(0, count: 0, down: true) == 0)
    }

    @Test func activityAcceptsKeysFromItsOwnerAndPopoverOnly() throws {
        let owner = NSWindow()
        let popover = NSWindow()
        let other = NSWindow()
        func event(_ window: NSWindow) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
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
        }
        #expect(ActivityNavigation.acceptsKeyEvent(try event(owner), popoverWindow: popover, ownerWindow: owner))
        #expect(ActivityNavigation.acceptsKeyEvent(try event(popover), popoverWindow: popover, ownerWindow: owner))
        #expect(!ActivityNavigation.acceptsKeyEvent(try event(other), popoverWindow: popover, ownerWindow: owner))
    }

    @Test func localBellUsesGlobalStyleAndFlashesOnce() throws {
        let domain = "program-activity-bell-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let oldDefaults = TerminalNotifier.shared.defaults
        TerminalNotifier.shared.defaults = defaults
        defer {
            TerminalNotifier.shared.defaults = oldDefaults
            defaults.removePersistentDomain(forName: domain)
        }
        let controller = TerminalSessionController(startsProcess: false)
        let view = try #require(controller.makeTerminalView() as? AppTerminalView)
        let oldSound = TerminalNotifier.shared.sound
        let oldAttention = TerminalNotifier.shared.attention
        var sounds = 0
        TerminalNotifier.shared.sound = {
            sounds += 1
        }
        TerminalNotifier.shared.attention = {}
        defer {
            TerminalNotifier.shared.sound = oldSound
            TerminalNotifier.shared.attention = oldAttention
            controller.terminate()
        }
        view.wantsLayer = true
        let layer = try #require(view.layer)
        let before = layer.sublayers?.count ?? 0
        // Global changes apply to this open view without applying its profile again.
        defaults.set(BellStyle.visual.tagName, forKey: TerminalNotificationPreferences.bellStyleKey)
        controller.noteBell(now: Date(timeIntervalSince1970: 10))
        #expect((layer.sublayers?.count ?? 0) == before + 1)
        controller.noteBell(now: Date(timeIntervalSince1970: 10.05))
        #expect((layer.sublayers?.count ?? 0) == before + 1)  // Native 100 ms debounce.
        #expect(sounds == 0)
        defaults.set(BellStyle.none.tagName, forKey: TerminalNotificationPreferences.bellStyleKey)
        controller.noteBell(now: Date(timeIntervalSince1970: 11))
        #expect((layer.sublayers?.count ?? 0) == before + 1 && sounds == 0)
        defaults.set(BellStyle.soundAndVisual.tagName, forKey: TerminalNotificationPreferences.bellStyleKey)
        controller.noteBell(now: Date(timeIntervalSince1970: 12))
        #expect((layer.sublayers?.count ?? 0) == before + 2 && sounds == 1)
    }

    @Test func muteSuppressesAttentionAndSoundAcrossPanes() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let tab = TerminalTab(startsProcesses: false)
        let group = manager.newGroup(tab: tab)
        defer { manager.closeGroup(group) }
        let first = try #require(tab.workspace.focusedController)
        tab.workspace.split(first, orientation: .horizontal)
        let second = try #require(tab.workspace.controllers.last)
        let notifier = TerminalNotifier()
        var bounces = 0, sounds = 0
        notifier.attention = {
            bounces += 1
        }
        notifier.sound = {
            sounds += 1
        }
        let time = Date(timeIntervalSince1970: 100)
        for pane in [first, second] {
            notifier.playBell(from: pane, now: time)
            notifier.requestAttention(from: pane, now: time, appActive: false)
        }
        #expect(bounces == 1 && sounds == 1)
        tab.isMuted = true
        notifier.playBell(from: second, now: time.addingTimeInterval(2))
        notifier.requestAttention(from: second, now: time.addingTimeInterval(2), appActive: false)
        #expect(bounces == 1 && sounds == 1)
    }

    @Test func dormantTabsHaveNoStatus() {
        let tab = TerminalTab(dormant: LaunchSpec(), startsProcesses: false)
        #expect(tab.status == .none && tab.isDormant)
    }
}

@MainActor
struct ProgramActivityIntegrationTests {
    /// Other main-actor tests must not consume the terminal delegate's delivery budget.
    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<800 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }
    @Test func localDelegateFallbackRISAndScreenSwitch() async throws {
        let domain = "program-activity-delegate-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(false, forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey)
        let oldDefaults = try await TestNotifications.useDefaults(defaults)
        TestNotifications.install()
        defer {
            TestNotifications.restoreDefaults(oldDefaults)
            defaults.removePersistentDomain(forName: domain)
        }
        let controller = TerminalSessionController(startsProcess: false)
        let view = try #require(controller.makeTerminalView() as? AppTerminalView)
        defer { controller.terminate() }
        view.feed(text: "\u{1b}]9;4;1;40\u{7}")
        try await wait {
            controller.programStatus.records.first?.progress == 40
        }
        view.feed(text: "\u{1b}]7501;state=working\u{7}")
        try await wait {
            controller.programStatus.uses7501 && controller.programStatus.records.first?.progress == nil
        }
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1049l")
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.programStatus.records.first?.state == .working)
        view.feed(text: "\u{1b}]133;A\u{7}\u{1b}]7501;state=working:msg=TmV3IHdvcms=\u{7}")
        try await wait {
            controller.programStatus.records.first?.message == "New work"
        }
        view.feed(text: "\u{1b}]133;A\u{7}\u{1b}]7501;state=paused\u{7}")
        try await wait {
            controller.programStatus.records.isEmpty
        }
        view.feed(text: "\u{1b}c")
        try await wait {
            controller.programStatus.records.isEmpty && !controller.programStatus.uses7501
        }
        view.feed(text: "\u{1b}]9;4;1;60\u{7}")
        try await wait {
            controller.programStatus.records.first?.progress == 60
        }
        view.feed(text: "\u{1b}]9;4;2\u{7}")
        try await wait {
            controller.programStatus.records.first?.state == .error
        }
        view.feed(text: "\u{1b}]133;A\u{7}")
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.programStatus.records.first?.state == .error)
    }

    @Test func tabLimitSourceMuteAndGlobalOptOut() throws {
        let domain = "program-activity-notifications-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let tab = TerminalTab(startsProcesses: false), group = manager.newGroup(tab: tab)
        defer { manager.closeGroup(group) }
        manager.rename(group, to: "Activity test group")
        let first = try #require(tab.workspace.focusedController)
        tab.workspace.split(first, orientation: .horizontal)
        let second = try #require(tab.workspace.controllers.last)
        let notifier = TerminalNotifier()
        notifier.defaults = defaults
        var contents: [UNNotificationContent] = []
        notifier.deliver = {
            contents.append($0.content)
        }
        let now = Date(timeIntervalSince1970: 100)
        notifier.notify(title: "Build", body: "Done\u{202E}", from: first, now: now)
        notifier.notify(title: "Build", body: "Other pane", from: second, now: now.addingTimeInterval(1.99))
        #expect(contents.count == 1)
        #expect(contents.first?.body == "Done")
        #expect(contents.first?.subtitle.contains("Activity test group") == true)
        notifier.notify(title: "Build", body: "Later", from: second, now: now.addingTimeInterval(2))
        #expect(contents.count == 2)
        tab.isMuted = true
        notifier.notify(title: "Build", body: "Muted", from: first, now: now.addingTimeInterval(4))
        #expect(contents.count == 2)
        tab.isMuted = false
        defaults.set(false, forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey)
        notifier.notify(title: "Build", body: "Opt out", from: first, now: now.addingTimeInterval(6))
        #expect(contents.count == 2)
    }

    @Test func announcementTickerUsesTitleFontForMeasurementAndScrolling() throws {
        let clip = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 18))
        clip.wantsLayer = true
        let title = NSTextField(labelWithString: "Tab")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        clip.addSubview(title)
        let mask = CAGradientLayer()
        let ticker = TabAnnouncementTicker(clip: clip, title: title, mask: mask)

        // Long enough to scroll at 13pt inside 60pt clip.
        ticker.configure(messages: ["Waiting for approval from user"], speed: 40, reduceMotion: false)
        let scrollingLabel = try #require(clip.subviews.compactMap { $0 as? NSTextField }.first { $0 !== title })
        let attributedFont = scrollingLabel.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(attributedFont == title.font)
        #expect(scrollingLabel.layer?.animation(forKey: "scroll") != nil)

        // Message that fits at 13pt (width ~54pt) inside 57pt clip, but would exceed 57pt at 14pt (~59pt).
        let fitMessage = "Approve it"
        let width13 = (fitMessage as NSString).size(withAttributes: [.font: title.font!]).width
        let width14 = (fitMessage as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
        clip.frame.size.width = ceil((width13 + width14) / 2)
        ticker.configure(messages: [fitMessage], speed: 40, reduceMotion: false)
        let staticLabel = try #require(clip.subviews.compactMap { $0 as? NSTextField }.first { $0 !== title })
        #expect(staticLabel.font == title.font)
        #expect(staticLabel.layer?.animation(forKey: "scroll") == nil)
    }
}
