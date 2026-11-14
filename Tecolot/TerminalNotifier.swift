//
//  TerminalNotifier.swift
//  Tecolot
//
//  Shows the desktop notifications that programs ask for with OSC 9 or
//  OSC 777, for local and persistent panes, and for persistent sessions that
//  no pane shows.
//

import AppKit
import TecolotSessionDirectory
@preconcurrency import UserNotifications
import TecolotWire

@MainActor
final class TerminalNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TerminalNotifier()

    /// At most this many notifications from one pane (or session) in
    /// `rateWindow`.
    static let rateLimit = 5
    static let rateWindow: TimeInterval = 30

    /// Shows the notification. Tests replace it so that they do not post real
    /// notifications.
    var deliver: (UNNotificationRequest) -> Void = TerminalNotifier.deliverToNotificationCenter

    /// Panes that posted notifications, so that a click can show the pane.
    private var panes: [String: WeakController] = [:]
    /// When each pane or session posted its recent notifications.
    private var recent: [String: [Date]] = [:]
    private var tabLimits = ProgramActivityRateLimiter()
    var sound: () -> Void = {
        NSSound.beep()
    }
    var attention: () -> Void = {
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Retains the inactive-app Dock bounce independently of the badge count.
    func requestAttention(from controller: TerminalSessionController, now: Date = Date(), appActive: Bool? = nil) {
        guard !(appActive ?? NSApp.isActive), controller.owningTab?.isMuted != true else {
            return
        }
        let tab = controller.owningTab?.id ?? controller.id
        if tabLimits.admitAttention(tab: tab, now: now.timeIntervalSince1970) {
            attention()
        }
    }

    /// The number of panes and sessions that the rate limit remembers.
    var rateLimitedSources: Int {
        recent.count
    }

    private struct WeakController {
        weak var controller: TerminalSessionController?
    }

    /// Shows a notification for a program in `controller`, unless the profile
    /// turned them off, the user looks at that pane now, or the pane sent too
    /// many.
    func notify(title: String, body: String, from controller: TerminalSessionController, now: Date = Date()) {
        controller.programStatus.noteNotification(isSeen: controller.isProgramActivityVisible)
        guard
            controller.profile.allowsNotifications, controller.owningTab?.isMuted != true,
            !Self.isInFront(controller)
        else {
            return
        }
        if let tab = controller.owningTab {
            guard tabLimits.admit(tab: tab.id, sound: false, now: now.timeIntervalSince1970) else {
                return
            }
        }
        let key = controller.id.uuidString
        guard admit(key, now: now) else {
            return
        }
        let content = Self.content(title: title, body: body, source: controller.panePresentation.title, group: controller.owningTab?.group?.name)
        if
            let tab = controller.owningTab,
            !tabLimits.admit(tab: tab.id, sound: true, now: now.timeIntervalSince1970) {
            content.sound = nil
        }
        content.userInfo = ["pane": key]
        content.threadIdentifier = key
        panes = panes.filter {
            $0.value.controller != nil
        }
        panes[key] = WeakController(controller: controller)
        deliver(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Builds a sanitized source path so a notification identifies its window, group, tab and pane.
    static func source(of controller: TerminalSessionController) -> String {
        guard let tab = controller.owningTab else {
            return ProgramStatusText.sanitize(controller.panePresentation.title, limit: 192)
        }
        let manager = controller.workspace?.windowManager ?? .shared
        let group = manager.group(containing: controller)?.name ?? "Group"
        let window =
            manager.group(containing: controller).flatMap {
                manager.window(showing: $0) as? TerminalWindowController
            }?
            .window?.title ?? "Background group"
        return [window, group, tab.title, controller.panePresentation.title]
            .map {
                ProgramStatusText.sanitize($0, limit: 192)
            }.joined(separator: " › ")
    }

    /// Applies profile, state, seen and per-tab limits before notifying about a report.
    func notifyProgramStatus(
        _ record: WireProgramStatus, from controller: TerminalSessionController, now: Date = Date(), appActive: Bool? = nil
    ) {
        let preferences = ProgramActivitySettings.shared.value
        guard
            [.blocked, .error, .done].contains(record.state),
            !preferences.disabledStates.contains(record.state), controller.owningTab?.isMuted != true,
            !controller.isProgramActivityVisible,
            !controller.programStatus.seen.isSeen(pane: controller.id, record: record)
        else {
            return
        }
        if record.state == .blocked {
            requestAttention(from: controller, now: now)
        }
        guard controller.profile.allowsNotifications else {
            return
        }
        let tab = controller.owningTab?.id ?? controller.id
        let status = TabStatus.reduce([TabStatus.Record(paneID: controller.id, value: record, unseen: true)])
        if
            preferences.notifications, !(appActive ?? NSApp.isActive),
            tabLimits.admit(tab: tab, sound: false, now: now.timeIntervalSince1970),
            admit(controller.id.uuidString, now: now) {
            let key = controller.id.uuidString
            let heading = status.accessibilityValue.components(separatedBy: ": ").first ?? "Program activity"
            let content = Self.content(
                title: heading, body: record.message ?? record.title ?? "", source: controller.panePresentation.title, group: controller.owningTab?.group?.name
            )
            content.userInfo = ["pane": key]
            content.threadIdentifier = tab.uuidString
            content.sound = nil
            if preferences.sounds, tabLimits.admit(tab: tab, sound: true, now: now.timeIntervalSince1970) {
                content.sound = .default
            }
            panes[key] = WeakController(controller: controller)
            deliver(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } else if preferences.sounds, tabLimits.admit(tab: tab, sound: true, now: now.timeIntervalSince1970) {
            sound()
        }
    }

    /// Plays one permitted bell sound per tab in a two-second window.
    func playBell(from controller: TerminalSessionController, now: Date = Date()) {
        guard controller.owningTab?.isMuted != true else {
            return
        }
        let tab = controller.owningTab?.id ?? controller.id
        if tabLimits.admit(tab: tab, sound: true, now: now.timeIntervalSince1970) {
            sound()
        }
    }

    /// Shows a notification that a session got while no client was attached
    /// (the helper keeps it in the session record). A click shows the
    /// session.
    func notify(_ notification: SessionNotification, session record: SessionRecord, now: Date = Date()) {
        if let controller = TerminalSessionRegistry.shared.controller(showingPersistentSession: record.id) {
            notify(title: notification.title, body: notification.body, from: controller, now: now)
            return
        }
        guard Self.profile(for: record).allowsNotifications, admit("session " + record.id, now: now) else {
            return
        }
        let row = SessionBrowserRow(record: record, status: .detached, shownHere: false)
        let content = Self.content(
            title: notification.title, body: notification.body,
            source: record.title.isEmpty ? row.command : record.title
        )
        content.userInfo = ["session": record.id]
        content.threadIdentifier = record.id
        deliver(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Records a notification of `key` at `now`, unless it posted
    /// `rateLimit` in the last `rateWindow`. Forgets the panes and sessions
    /// that posted nothing in that time (for example closed panes).
    private func admit(_ key: String, now: Date) -> Bool {
        recent = recent.compactMapValues { times in
            let current = times.filter {
                now.timeIntervalSince($0) < Self.rateWindow
            }
            return current.isEmpty ? nil : current
        }
        var times = recent[key] ?? []
        guard times.count < Self.rateLimit else {
            return false
        }
        times.append(now)
        recent[key] = times
        return true
    }

    /// Without a title, the pane (or session) is the title; with one, it is
    /// the subtitle.
    private static func content(title: String, body: String, source: String, group: String? = nil) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = ProgramStatusText.sanitize(title.isEmpty ? source : title, limit: 192)
        if let group {
            content.subtitle = ProgramStatusText.sanitize(group, limit: 192)
        } else if !title.isEmpty {
            content.subtitle = ProgramStatusText.sanitize(source, limit: 192)
        }
        content.body = ProgramStatusText.sanitize(body)
        content.sound = .default
        return content
    }

    private static func profile(for record: SessionRecord) -> TerminalProfile {
        let profiles = AppModel.shared.profiles
        return record.labels["profileID"].flatMap(UUID.init(uuidString:)).flatMap(profiles.profile(withID:))
            ?? profiles.defaultProfile
    }

    /// True when the pane is the focused pane of the key window of the
    /// active app.
    static func isInFront(_ controller: TerminalSessionController) -> Bool {
        guard NSApp.isActive, let window = controller.surface?.window, window.isKeyWindow else {
            return false
        }
        return TerminalSessionRegistry.shared.controller(for: window) === controller
    }

    static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound, .badge]
    private var requestedBadgeAuthorization = false

    /// Request the added badge option even for an earlier alert/sound-only grant.
    /// macOS may leave it disabled; Notifications settings exposes the user's switch.
    func requestBadgeAuthorization() {
        guard !requestedBadgeAuthorization else {
            return
        }
        requestedBadgeAuthorization = true
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: Self.authorizationOptions) { _, _ in
            DispatchQueue.main.async {
                NSApp.dockTile.display()
            }
        }
    }

    private static func deliverToNotificationCenter(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        center.delegate = TerminalNotifier.shared
        // The first notification asks the user for permission.
        center.requestAuthorization(options: Self.authorizationOptions) { granted, _ in
            guard granted else {
                return
            }
            center.add(request)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async
    -> UNNotificationPresentationOptions {
        // Posted only for panes that are not in front, so show it even when
        // Tecolot is the active app.
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let pane = userInfo["pane"] as? String
        let session = userInfo["session"] as? String
        await MainActor.run {
            if let pane {
                show(pane: pane)
            }
            if let session {
                show(session: session)
            }
        }
    }

    /// Shows the pane that posted a notification.
    func show(pane key: String) {
        panes[key]?.controller?.reveal()
    }

    /// Shows the pane of a session, or attaches to it in a new tab.
    func show(session id: String) {
        guard let record = try? PersistentSessions.directory().readRecord(id) else {
            return
        }
        SessionBrowserModel.show(record)
    }
}

/// Watches the session directory, and shows the notifications that sessions
/// got while no client was attached.
@MainActor
final class DetachedSessionNotifications {
    static let shared = DetachedSessionNotifications()

    private let list: @MainActor () -> [SessionRecord]
    private let post: @MainActor (SessionNotification, SessionRecord) -> Void
    /// The serial of the last notification of each session.
    private var seen: [String: UInt64] = [:]
    private var source: DispatchSourceFileSystemObject?
    private var checkScheduled = false

    init(
        list: @escaping @MainActor () -> [SessionRecord] = {
            PersistentSessions.list()
        },
        post: @escaping @MainActor (SessionNotification, SessionRecord) -> Void = {
            TerminalNotifier.shared.notify($0, session: $1)
        }
    ) {
        self.list = list
        self.post = post
    }

    /// Starts to watch. The notifications that sessions have now came
    /// before the app started: they do not show.
    func start() {
        guard source == nil, let url = try? PersistentSessions.directory().url else {
            return
        }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleCheck()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        markSeen()
        source.resume()
        self.source = source
    }

    /// Records the notifications that the sessions have now, without
    /// showing them.
    func markSeen() {
        for record in list() {
            if let notification = record.notification {
                seen[record.id] = notification.serial
            }
        }
    }

    /// Shows the notifications that came since the last check.
    func check() {
        let records = list()
        for record in records {
            guard let notification = record.notification, notification.serial > seen[record.id] ?? 0 else {
                continue
            }
            seen[record.id] = notification.serial
            post(notification, record)
        }
        let ids = Set(records.map(\.id))
        seen = seen.filter {
            ids.contains($0.key)
        }
    }

    /// A record write is a burst of directory events: check once after it.
    private func scheduleCheck() {
        guard !checkScheduled else {
            return
        }
        checkScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                self?.checkScheduled = false
                self?.check()
            }
        }
    }
}
