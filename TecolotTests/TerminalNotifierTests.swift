import AppKit
import Testing
import TecolotSessionDirectory
import TecolotWire
import UserNotifications
@testable import Tecolot

/// Keeps the notifications that tests cause, instead of showing them. Tests
/// look only at the notifications of their own pane, so suites that run at
/// the same time do not disturb each other.
@MainActor
enum TestNotifications {
    private static var requests: [UNNotificationRequest] = []
    private static var defaultsInUse = false

    /// Async tests share the notifier; keep their defaults overrides from overlapping.
    static func useDefaults(_ defaults: UserDefaults) async throws -> UserDefaults {
        while defaultsInUse {
            try await Task.sleep(for: .milliseconds(10))
        }
        defaultsInUse = true
        let previous = TerminalNotifier.shared.defaults
        TerminalNotifier.shared.defaults = defaults
        return previous
    }

    static func restoreDefaults(_ defaults: UserDefaults) {
        TerminalNotifier.shared.defaults = defaults
        defaultsInUse = false
    }

    static func install() {
        TerminalNotifier.shared.deliver = {
            requests.append($0)
        }
    }

    static func contents(for controller: TerminalSessionController) -> [UNNotificationContent] {
        requests.map(\.content).filter {
            $0.userInfo["pane"] as? String == controller.id.uuidString
        }
    }
}

@MainActor
struct TerminalNotifierTests {
    // The full suite runs many main-actor tests in parallel, so a callback
    // can take several seconds to get its turn.
    private func wait(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("timed out: \(what)")
    }

    @Test func localPanesPostNotificationsFromPrograms() async throws {
        let domain = "terminal-notifier-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let oldDefaults = try await TestNotifications.useDefaults(defaults)
        defer {
            TestNotifications.restoreDefaults(oldDefaults)
            defaults.removePersistentDomain(forName: domain)
        }
        TestNotifications.install()
        let controller = TerminalSessionController(startsProcess: false)
        let terminal = try #require(controller.makeTerminalView() as? AppTerminalView)
        terminal.feed(text: "\u{1b}]777;notify;Build;Done\u{07}\u{1b}]9;Tests passed\u{07}\u{1b}]9;4;1;50\u{07}")
        try await wait("notifications") {
            TestNotifications.contents(for: controller).count == 2
        }
        let contents = TestNotifications.contents(for: controller)
        #expect(contents.map(\.title) == ["Build", controller.panePresentation.title])
        #expect(contents.map(\.subtitle) == [controller.panePresentation.title, ""])
        #expect(contents.map(\.body) == ["Done", "Tests passed"])
    }

    @Test(arguments: [false, true])
    func disabledOrMutedNotificationsDoNotRaiseAttention(muted: Bool) async throws {
        let domain = "terminal-notifier-attention-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(muted, forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey)
        let oldDefaults = try await TestNotifications.useDefaults(defaults)
        TestNotifications.install()
        let tab = TerminalTab(startsProcesses: false)
        let workspace = tab.workspace
        defer {
            tab.loadedWorkspace?.terminateAll()
            TestNotifications.restoreDefaults(oldDefaults)
            defaults.removePersistentDomain(forName: domain)
        }
        tab.isMuted = muted
        let controller = try #require(workspace.focusedController)
        TerminalNotifier.shared.notify(title: "Build", body: "Direct", from: controller)
        #expect(!controller.programStatus.notified)
        controller.programStatus.markSeen()
        controller.handlePersistentEvent(.notification(title: "Build", body: "Persistent"))
        #expect(!controller.programStatus.notified)
        controller.programStatus.markSeen()
        let terminal = try #require(controller.makeTerminalView() as? AppTerminalView)
        // The progress report follows both notification callbacks on the OSC stream.
        terminal.feed(text: "\u{1b}]9;Done\u{07}\u{1b}]777;notify;Build;Done\u{07}\u{1b}]9;4;1;50\u{07}")
        try await wait("OSC callbacks") { controller.programStatus.records.first?.progress == 50 }
        #expect(!controller.programStatus.notified)
        #expect(TestNotifications.contents(for: controller).isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func rejectedNotificationsDoNotConsumeOtherLimiters(programStatus: Bool, rejectTab: Bool) throws {
        let domain = "terminal-notifier-limits-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey)
        defaults.set(true, forKey: ProgramActivityPreferences.notificationsKey)
        defaults.set(false, forKey: ProgramActivityPreferences.soundsKey)
        let notifier = TerminalNotifier()
        notifier.defaults = defaults
        var bodies: [String] = []
        notifier.deliver = { bodies.append($0.content.body) }
        let tab = TerminalTab(startsProcesses: false)
        let workspace = tab.workspace
        defer { workspace.terminateAll() }
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let second = try #require(workspace.focusedController)
        func notify(_ pane: TerminalSessionController, _ body: String, at time: Double) {
            let now = Date(timeIntervalSince1970: 100 + time)
            if programStatus {
                notifier.notifyProgramStatus(WireProgramStatus(state: .done, message: body, reportTime: 1), from: pane, now: now, appActive: false)
            } else {
                notifier.notify(title: "", body: body, from: pane, now: now)
            }
        }
        if rejectTab {
            notify(first, "First", at: 0)
            for index in 0..<TerminalNotifier.rateLimit {
                notify(second, "Rejected", at: 1 + Double(index) / 10)
            }
            notify(second, "Allowed", at: 2)
            #expect(bodies == ["First", "Allowed"])
        } else {
            for index in 0..<TerminalNotifier.rateLimit {
                notify(first, "First", at: Double(index * 2))
            }
            notify(first, "Rejected", at: 10)
            notify(second, "Allowed", at: 10.1)
            #expect(bodies.count == TerminalNotifier.rateLimit + 1)
            #expect(bodies.last == "Allowed")
        }
    }

    @Test func repeatedOSCNotificationsKeepTheTwoSecondDropPolicy() throws {
        let domain = "terminal-notifier-repeat-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey)
        let notifier = TerminalNotifier()
        notifier.defaults = defaults
        var requests: [UNNotificationRequest] = []
        notifier.deliver = { requests.append($0) }
        let tab = TerminalTab(startsProcesses: false)
        let pane = try #require(tab.workspace.focusedController)
        defer { tab.workspace.terminateAll() }
        let now = Date(timeIntervalSince1970: 100)
        notifier.notify(title: "", body: "First", from: pane, now: now)
        notifier.notify(title: "", body: "Second", from: pane, now: now.addingTimeInterval(1))
        #expect(requests.map(\.content.body) == ["First"])
        #expect(requests.first?.content.sound != nil)
    }

    @Test func paneRateRejectionDoesNotSpendAnotherPanesTabSlot() throws {
        let domain = "terminal-notifier-pane-limit-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey)
        let notifier = TerminalNotifier()
        notifier.defaults = defaults
        var bodies: [String] = []
        notifier.deliver = { bodies.append($0.content.body) }
        let tab = TerminalTab(startsProcesses: false)
        let workspace = tab.workspace
        defer { tab.loadedWorkspace?.terminateAll() }
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let second = try #require(workspace.focusedController)
        let start = Date(timeIntervalSince1970: 100)
        for index in 0..<TerminalNotifier.rateLimit {
            notifier.notify(title: "", body: "Allowed", from: first, now: start.addingTimeInterval(Double(index * 2)))
        }
        try #require(bodies.count == TerminalNotifier.rateLimit)
        notifier.notify(title: "", body: "Pane rejected", from: first, now: start.addingTimeInterval(10))
        notifier.notify(title: "", body: "Other pane", from: second, now: start.addingTimeInterval(10.1))
        #expect(bodies.count == TerminalNotifier.rateLimit + 1)
        #expect(bodies.last == "Other pane")
        #expect(!bodies.contains("Pane rejected"))
    }

    @Test func notificationsFollowGlobalPreferencesAndARateLimit() throws {
        let domain = "terminal-notifier-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        TestNotifications.install()
        let notifier = TerminalNotifier()
        notifier.defaults = defaults
        notifier.deliver = TerminalNotifier.shared.deliver
        let controller = TerminalSessionController(startsProcess: false)
        defer { controller.terminate() }
        defaults.set(false, forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey)
        notifier.notify(title: "", body: "muted", from: controller)
        #expect(TestNotifications.contents(for: controller).isEmpty)

        defaults.set(true, forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey)
        let start = Date()
        for index in 0 ..< 8 {
            notifier.notify(
                title: "",
                body: "\(index)",
                from: controller,
                now: start.addingTimeInterval(Double(index))
            )
        }
        #expect(TestNotifications.contents(for: controller).count == TerminalNotifier.rateLimit)
        // After the window, the pane can post again.
        notifier.notify(
            title: "",
            body: "later",
            from: controller,
            now: start.addingTimeInterval(TerminalNotifier.rateWindow + 5)
        )
        #expect(TestNotifications.contents(for: controller).last?.body == "later")
    }

    /// The rate limit forgets panes that posted nothing for a while, for
    /// example closed panes.
    @Test func theRateLimitForgetsQuietPanes() throws {
        let domain = "terminal-notifier-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let notifier = TerminalNotifier()
        notifier.defaults = defaults
        notifier.deliver = { _ in }
        let later = Date().addingTimeInterval(3600)
        notifier.notify(title: "", body: "one", from: TerminalSessionController(startsProcess: false), now: later)
        #expect(notifier.rateLimitedSources == 1)
        notifier.notify(
            title: "",
            body: "two",
            from: TerminalSessionController(startsProcess: false),
            now: later.addingTimeInterval(TerminalNotifier.rateWindow + 1)
        )
        #expect(notifier.rateLimitedSources == 1)
    }

    /// A session that no client showed keeps its last notification in its
    /// record. The app shows each new one once, but not the ones that came
    /// before it started.
    @Test func detachedSessionsPostTheirNotifications() throws {
        let domain = "terminal-notifier-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var requests: [UNNotificationRequest] = []
        let notifier = TerminalNotifier()
        notifier.defaults = defaults
        notifier.deliver = {
            requests.append($0)
        }
        var record = SessionRecord(
            id: "a1b2c3",
            pid: 1,
            shellPID: 2,
            protocolVersion: 1,
            build: "test",
            createdAt: Date(),
            executable: "/bin/zsh",
            workingDirectory: "/tmp",
            labels: [:],
            columns: 80,
            rows: 24
        )
        record.title = "make"
        record.notification = SessionNotification(serial: 1, title: "", body: "Before the app")
        var records = [record]
        let watcher = DetachedSessionNotifications(list: {
            records
        }, post: {
            notifier.notify($0, session: $1)
        })
        watcher.markSeen()
        watcher.check()
        #expect(requests.isEmpty)

        records[0].notification = SessionNotification(serial: 2, title: "Build", body: "Done")
        watcher.check()
        watcher.check()
        #expect(requests.count == 1)
        let content = try #require(requests.first?.content)
        #expect(content.title == "Build")
        #expect(content.subtitle == "make")
        #expect(content.body == "Done")
        #expect(content.userInfo["session"] as? String == "a1b2c3")

        // A new session shows its first notification.
        var second = record
        second.id = "d4e5f6"
        second.title = ""
        second.notification = SessionNotification(serial: 1, title: "", body: "Tests passed")
        records.append(second)
        watcher.check()
        #expect(requests.count == 2)
        #expect(requests.last?.content.title == "zsh")

        defaults.set(false, forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey)
        notifier.notify(SessionNotification(serial: 3, title: "", body: "Disabled"), session: second)
        #expect(requests.count == 2)
        defaults.set(true, forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey)
        notifier.notify(SessionNotification(serial: 4, title: "", body: "Enabled again"), session: second)
        #expect(requests.count == 3)
    }

    @Test func programStatusNotificationsIgnoreTheProgramNotificationSwitch() throws {
        let domain = "terminal-notifier-status-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(false, forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey)
        let notifier = TerminalNotifier()
        notifier.defaults = defaults
        var requests: [UNNotificationRequest] = []
        notifier.deliver = { requests.append($0) }
        let controller = TerminalSessionController(startsProcess: false)
        defer { controller.terminate() }

        defaults.set(true, forKey: ProgramActivityPreferences.notificationsKey)
        defaults.set(true, forKey: ProgramActivityPreferences.soundsKey)
        defaults.set(true, forKey: ProgramActivityPreferences.stateKey(.done))

        notifier.notifyProgramStatus(
            WireProgramStatus(state: .done, message: "Finished", reportTime: 1), from: controller, appActive: false
        )
        #expect(requests.count == 1)
        #expect(requests.first?.content.body == "Finished")
        #expect(requests.first?.content.sound != nil)
    }

    @Test func profilesKeepTheNotificationSetting() throws {
        let older = try JSONDecoder().decode(TerminalProfile.self, from: Data(#"{"name": "Older"}"#.utf8))
        #expect(older.allowsNotifications)
        var profile = TerminalProfile(name: "Quiet")
        profile.allowsNotifications = false
        let decoded = try JSONDecoder().decode(TerminalProfile.self, from: JSONEncoder().encode(profile))
        #expect(!decoded.allowsNotifications)
    }
}
