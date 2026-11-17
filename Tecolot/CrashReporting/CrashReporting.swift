//
//  CrashReporting.swift
//  Tecolot
//
//  Tecolot does not capture crashes itself. When Tecolot crashes, macOS
//  writes a crash report (`.ips`) in ~/Library/Logs/DiagnosticReports.
//  Tecolot lists its own reports in Settings and shows a notice at the next
//  launch. Nothing goes over the network unless the user submits a report
//  (CrashReportSubmitter).
//
import AppKit
import Foundation
import os
import SwiftUI

@MainActor
enum CrashReporting {
    nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot",
        category: "CrashReports"
    )

    /// The reports of this app. Debug and Release builds have different
    /// bundle identifiers, so each build lists only its own reports.
    nonisolated static var store: CrashReportStore {
        CrashReportStore(
            directories: CrashReportStore.systemDirectories(),
            processName: processName,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot"
        )
    }

    /// Tecolot's own records, for example which reports the user submitted:
    /// `~/Library/Application Support/<bundle id>/CrashReports`.
    nonisolated static var stateDirectory: URL {
        RestoreStore.applicationSupport.appendingPathComponent("CrashReports", isDirectory: true)
    }

    /// Sends reports when the user clicks Submit. Nil when the build has no
    /// DSN. Debug builds have none, so their reports cannot reach Sentry.
    nonisolated static var submitter: CrashReportSubmitter? {
        guard let dsn = SentryDSN.fromBundle() else { return nil }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return CrashReportSubmitter(dsn: dsn, clientVersion: version)
    }

    /// macOS names a report `<process name>-<date>.ips`.
    private nonisolated static var processName: String {
        Bundle.main.executableURL?.lastPathComponent
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
            ?? "Tecolot"
    }

    /// Shows the notice when a report is new. Call this after launch.
    static func finishLaunch() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        #if DEBUG
        CrashTestTrigger.scheduleIfRequested()
        #endif

        let store = Self.store
        Task.detached(priority: .utility) {
            let listing: CrashReportListing
            do {
                listing = try store.list()
            } catch {
                logger.error("Could not read crash reports: \(error.localizedDescription, privacy: .public)")
                return
            }
            await MainActor.run {
                let seen = CrashReportSeenState(defaults: UserDefaults.standard)
                guard seen.hasBaseline else {
                    // The first launch of a version with this feature. Record
                    // the reports now, also when there are none, so that the
                    // next crash shows a notice. Do not show a notice for
                    // crashes from before this version.
                    seen.markSeen(listing)
                    return
                }
                let unseen = seen.unseen(in: listing)
                guard !unseen.isEmpty else { return }
                CrashReportNotice.shared.show(listing: listing, unseenCount: unseen.count)
            }
        }
    }
}

// MARK: - Settings navigation

/// Opens the Settings window at a given page from code outside a scene.
@Observable
@MainActor
final class SettingsNavigator {
    static let shared = SettingsNavigator()
    static let windowID = "settings"

    /// The page that the Settings window shows next.
    var pendingDestination: SettingsDestination?
    /// The setting that the Settings window shows next.
    var pendingSetting: SettingID?
    @ObservationIgnored var openWindow: OpenWindowAction?

    private init() {}

    func show(_ destination: SettingsDestination) {
        pendingDestination = destination
        openSettings()
    }

    /// Opens Settings at one setting and puts the spotlight on its row.
    func show(setting: SettingID) {
        pendingSetting = setting
        openSettings()
    }

    private func openSettings() {
        if let openWindow {
            openWindow(id: Self.windowID)
        } else if let (menu, index) = Self.settingsMenuItem() {
            // SettingsCommands did not give its action yet. Use its menu
            // item, which opens the same window.
            menu.performActionForItem(at: index)
        } else {
            // No window opens. Do not leave the page for the next ⌘,.
            pendingDestination = nil
            pendingSetting = nil
            CrashReporting.logger.error("Could not open Settings.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The "Settings…" item (⌘,) in the app menu.
    private static func settingsMenuItem() -> (NSMenu, Int)? {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return nil }
        let index = appMenu.items.firstIndex { item in
            item.keyEquivalent == "," && item.keyEquivalentModifierMask == .command && item.isEnabled
        }
        return index.map { (appMenu, $0) }
    }
}

// MARK: - Notice

/// A small panel that tells the user about a new crash report. It does not
/// take focus and does not block windows or document restoration.
@MainActor
final class CrashReportNotice: NSObject, NSWindowDelegate {
    static let shared = CrashReportNotice()

    private var panel: NSPanel?
    private var listing: CrashReportListing?

    func show(listing: CrashReportListing, unseenCount: Int) {
        guard panel == nil else { return }
        self.listing = listing
        let content = CrashReportNoticeView(
            count: unseenCount,
            open: { [weak self] in
                self?.close()
                SettingsNavigator.shared.show(.crashReports)
            },
            dismiss: { [weak self] in
                self?.close()
            }
        )
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        // Show the notice on the Space the user is on, also over a
        // full-screen window.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.delegate = self
        panel.setAccessibilityLabel("Crash report notice")

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - size.width - 20,
                y: frame.maxY - size.height - 20
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Closes the notice. `windowWillClose` marks the reports as seen.
    func close() {
        panel?.close()
    }

    /// Each way to close the notice (its buttons, the close button, or the
    /// Settings page) marks its reports as seen, so the notice does not show
    /// again at the next launch for the same reports.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPanel, closing === panel else { return }
        if var listing {
            // Add these IDs. Do not remove IDs that a newer listing added.
            listing.isComplete = false
            CrashReportSeenState(defaults: UserDefaults.standard).markSeen(listing)
        }
        listing = nil
        panel = nil
    }
}

private struct CrashReportNoticeView: View {
    let count: Int
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Tecolot quit unexpectedly")
                    .font(.headline)
                Text(count == 1
                     ? "macOS saved a crash report on this Mac. Tecolot did not send it."
                     : "macOS saved \(count) crash reports on this Mac. Tecolot did not send them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Dismiss", action: dismiss)
                    Button("Show Crash Reports", action: open)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

// MARK: - Test trigger

#if DEBUG
/// Crashes a Debug build on request, for the crash reporting checks. Set
/// `TECOLOT_CRASH_TEST` to `main` or `worker`. Start the app outside the
/// debugger, because macOS does not write a report when a debugger catches
/// the crash. Release builds do not contain this code.
nonisolated enum CrashTestTrigger {
    static let environmentKey = "TECOLOT_CRASH_TEST"

    nonisolated static var mode: String? {
        ProcessInfo.processInfo.environment[environmentKey]
    }

    @MainActor
    static func scheduleIfRequested() {
        switch mode {
        case "main":
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                crash()
            }
        case "worker":
            let thread = Thread {
                Thread.sleep(forTimeInterval: 2)
                crash()
            }
            thread.name = "Tecolot crash test"
            thread.start()
        default:
            break
        }
    }

    @inline(never)
    nonisolated private static func crash() {
        let values: [Int] = []
        let index = Int(ProcessInfo.processInfo.processIdentifier) >= 0 ? 1 : 0
        _ = values[index]
    }
}
#endif
