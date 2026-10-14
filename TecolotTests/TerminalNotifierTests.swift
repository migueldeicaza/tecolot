import AppKit
import Testing
import TecolotSessionDirectory
import UserNotifications
@testable import Tecolot

/// Keeps the notifications that tests cause, instead of showing them. Tests
/// look only at the notifications of their own pane, so suites that run at
/// the same time do not disturb each other.
@MainActor
enum TestNotifications {
    private static var requests: [UNNotificationRequest] = []

    static func install() {
        TerminalNotifier.shared.deliver = { requests.append($0) }
    }

    static func contents(for controller: TerminalSessionController) -> [UNNotificationContent] {
        requests.map(\.content).filter { $0.userInfo["pane"] as? String == controller.id.uuidString }
    }
}

@MainActor
struct TerminalNotifierTests {
    private func wait(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("timed out: \(what)")
    }

    @Test func localPanesPostNotificationsFromPrograms() async throws {
        TestNotifications.install()
        let controller = TerminalSessionController(startsProcess: false)
        let terminal = try #require(controller.makeTerminalView(document: TerminalDocument(content: "")) as? AppTerminalView)
        terminal.feed(text: "\u{1b}]777;notify;Build;Done\u{07}\u{1b}]9;Tests passed\u{07}\u{1b}]9;4;1;50\u{07}")
        try await wait("notifications") { TestNotifications.contents(for: controller).count == 2 }
        let contents = TestNotifications.contents(for: controller)
        #expect(contents.map(\.title) == ["Build", controller.panePresentation.title])
        #expect(contents.map(\.subtitle) == [controller.panePresentation.title, ""])
        #expect(contents.map(\.body) == ["Done", "Tests passed"])
    }

    @Test func notificationsFollowTheProfileAndARateLimit() {
        TestNotifications.install()
        let controller = TerminalSessionController(startsProcess: false)
        var profile = TerminalProfile(name: "Quiet")
        profile.allowsNotifications = false
        controller.applyProfile(profile)
        TerminalNotifier.shared.notify(title: "", body: "muted", from: controller)
        #expect(TestNotifications.contents(for: controller).isEmpty)

        profile.allowsNotifications = true
        controller.applyProfile(profile)
        let start = Date()
        for index in 0 ..< 8 {
            TerminalNotifier.shared.notify(title: "", body: "\(index)", from: controller,
                                           now: start.addingTimeInterval(Double(index)))
        }
        #expect(TestNotifications.contents(for: controller).count == TerminalNotifier.rateLimit)
        // After the window, the pane can post again.
        TerminalNotifier.shared.notify(title: "", body: "later", from: controller,
                                       now: start.addingTimeInterval(TerminalNotifier.rateWindow + 5))
        #expect(TestNotifications.contents(for: controller).last?.body == "later")
    }

    /// The rate limit forgets panes that posted nothing for a while, for
    /// example closed panes.
    @Test func theRateLimitForgetsQuietPanes() {
        let notifier = TerminalNotifier()
        notifier.deliver = { _ in }
        let later = Date().addingTimeInterval(3600)
        notifier.notify(title: "", body: "one", from: TerminalSessionController(startsProcess: false), now: later)
        #expect(notifier.rateLimitedSources == 1)
        notifier.notify(title: "", body: "two", from: TerminalSessionController(startsProcess: false),
                        now: later.addingTimeInterval(TerminalNotifier.rateWindow + 1))
        #expect(notifier.rateLimitedSources == 1)
    }

    /// A session that no client showed keeps its last notification in its
    /// record. The app shows each new one once, but not the ones that came
    /// before it started.
    @Test func detachedSessionsPostTheirNotifications() throws {
        var requests: [UNNotificationRequest] = []
        let notifier = TerminalNotifier()
        notifier.deliver = { requests.append($0) }
        var record = SessionRecord(id: "a1b2c3", pid: 1, shellPID: 2, protocolVersion: 1, build: "test",
                                   createdAt: Date(), executable: "/bin/zsh", workingDirectory: "/tmp",
                                   labels: [:], columns: 80, rows: 24)
        record.title = "make"
        record.notification = SessionNotification(serial: 1, title: "", body: "Before the app")
        var records = [record]
        let watcher = DetachedSessionNotifications(list: { records }, post: { notifier.notify($0, session: $1) })
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
