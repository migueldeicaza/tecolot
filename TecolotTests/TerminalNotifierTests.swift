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
    private func wait(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
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
