//
//  CrashReporting.swift
//  Tecolot
//
//  Starts local crash capture before the app model and terminal sessions.
//  Sentry Native with Breakpad writes a pending report when the app crashes.
//  On the next launch, the SDK gives it to a local transport, which saves it
//  in Application Support. Nothing goes over the network unless the user
//  submits a report in Settings (CrashReportSubmitter).
//
import AppKit
import Darwin
import Foundation
import os
import SentryNativeBreakpad
import SwiftUI

@MainActor
enum CrashReporting {
    nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot",
        category: "CrashReports"
    )

    /// The directories for this process. Debug and Release builds use their
    /// own bundle identifiers, so their reports stay separate.
    nonisolated static let locations = CrashReportLocations(bundleIdentifier: storageIdentifier)

    nonisolated static var store: CrashReportStore {
        CrashReportStore(directory: locations.reportsDirectory)
    }

    /// Sends reports when the user clicks Submit. Nil when the build has no
    /// DSN. Debug builds have none, so their reports cannot reach Sentry.
    nonisolated static var submitter: CrashReportSubmitter? {
        #if DEBUG
        if CrashTestTrigger.isTestRun { return nil }
        #endif
        guard let dsn = SentryDSN.fromBundle() else { return nil }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return CrashReportSubmitter(dsn: dsn, clientVersion: version)
    }

    /// Why capture is off, when `start()` failed.
    private(set) static var startupError: String?
    private static var didStart = false

    /// Starts capture. Call this once before `AppModel.shared`. A failure is
    /// logged and does not stop the launch.
    static func start() {
        guard !didStart else { return }
        didStart = true
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }

        let locations = Self.locations
        let store = Self.store
        do {
            try CrashReportStore.createPrivateDirectory(locations.databaseDirectory)
            let metadata = CrashReportMetadata.current()
            try LocalCrashReporter.start(LocalCrashReporter.Configuration(
                databaseURL: locations.databaseDirectory,
                release: metadata.release,
                tags: metadata.tags
            ) { envelope in
                // The SDK calls this during sentry_init, on a normal thread,
                // for crashes from earlier runs. It deletes its pending copy
                // after this returns, so a failure here loses the report.
                do {
                    let saved = try store.save(envelope: envelope.data, eventID: envelope.eventID)
                    if saved {
                        logger.notice("Saved a crash report from an earlier run.")
                    }
                } catch {
                    logger.error("Could not save a crash report: \(error.localizedDescription, privacy: .public)")
                }
            })
            // Breakpad set a task exception port. Do not pass it to shells.
            ChildExceptionPorts.installResetInForkedChildren()
        } catch {
            startupError = String(describing: error)
            logger.error("Crash capture is off: \(String(describing: error), privacy: .public)")
        }

        #if DEBUG
        CrashTestTrigger.scheduleIfRequested()
        #endif
    }

    /// Closes the SDK during a normal quit.
    static func stop() {
        LocalCrashReporter.close()
    }

    /// Applies retention on a worker, then shows the notice when a report is
    /// new. Call this after launch.
    static func finishLaunch() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        let store = Self.store
        Task.detached(priority: .utility) {
            let listing: CrashReportListing
            do {
                try store.applyRetention()
                listing = try store.list()
            } catch {
                logger.error("Could not read crash reports: \(error.localizedDescription, privacy: .public)")
                return
            }
            await MainActor.run {
                let unseen = CrashReportSeenState(defaults: UserDefaults.standard).unseen(in: listing)
                guard !unseen.isEmpty else { return }
                CrashReportNotice.shared.show(listing: listing, unseenCount: unseen.count)
            }
        }
    }

    private nonisolated static var storageIdentifier: String {
        let identifier = Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot"
        #if DEBUG
        // The crash test uses its own directories, so it cannot change the
        // reports of a normal Debug run.
        if CrashTestTrigger.isTestRun {
            return identifier + ".crashtest"
        }
        #endif
        return identifier
    }
}

/// The only fields that Tecolot adds to a crash event. It reads no terminal
/// or window state.
nonisolated struct CrashReportMetadata: Equatable {
    var release: String
    var tags: [String: String]

    static func current(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        defaults: any CrashReportPreferences = UserDefaults.standard
    ) -> CrashReportMetadata {
        let identifier = bundle.bundleIdentifier ?? "com.tirania.Tecolot"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = processInfo.operatingSystemVersion
        // The startup preference. Each terminal can change it later, and the
        // crash callback does not read live terminals.
        let usesMetal = defaults.object(forKey: "useMetalRenderer") as? Bool ?? true

        return CrashReportMetadata(
            release: "\(identifier)@\(version)+\(build)",
            tags: [
                CrashReportTag.appVersion: version,
                CrashReportTag.buildNumber: build,
                CrashReportTag.bundleIdentifier: identifier,
                CrashReportTag.architecture: architecture,
                CrashReportTag.macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                CrashReportTag.renderer: usesMetal ? "metal" : "coregraphics"
            ]
        )
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

// MARK: - Child processes

/// Breakpad sets a Mach exception port on the Tecolot task. A forked child
/// inherits it, also across `execve`. Then the kernel sends each exception
/// of a shell or a program in a terminal to Tecolot first, Tecolot leaks
/// port rights for each one, and a faulting child waits when Tecolot hangs.
///
/// SwiftTerm starts terminal processes with `forkpty` and `execve`. A
/// `pthread_atfork` child handler runs in the child after the fork and
/// before the exec, and resets the exception ports to none. The parent
/// keeps its ports, so Tecolot's own crashes are still captured. Tecolot
/// does not start processes with `posix_spawn` or `Process`; code that adds
/// such a call must set `posix_spawnattr_setexceptionports_np`.
nonisolated enum ChildExceptionPorts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false

    /// The exceptions that Breakpad handles (`s_exception_mask` in its
    /// exception_handler.cc). Swift does not import `EXC_MASK_ALL`, and one
    /// invalid bit would make the whole call fail. It is computed, not a
    /// lazy `static let`, because a first lazy initialization in a forked
    /// child is not safe.
    static var breakpadMask: exception_mask_t {
        exception_mask_t(
            EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_BREAKPOINT
        )
    }

    /// Sets the exception ports of the current task for Breakpad's
    /// exceptions to none. Returns the kernel result.
    @discardableResult
    static func resetCurrentTask() -> kern_return_t {
        task_set_exception_ports(
            mach_task_self_,
            breakpadMask,
            mach_port_t(MACH_PORT_NULL),
            exception_behavior_t(EXCEPTION_DEFAULT),
            thread_state_flavor_t(THREAD_STATE_NONE)
        )
    }

    static func installResetInForkedChildren() {
        lock.withLock {
            guard !installed else { return }
            installed = true
            // The handler runs in the child, which has one thread. It makes
            // one Mach call and does not allocate.
            pthread_atfork(nil, nil) {
                ChildExceptionPorts.resetCurrentTask()
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
    @ObservationIgnored var openWindow: OpenWindowAction?

    private init() {}

    func show(_ destination: SettingsDestination) {
        pendingDestination = destination
        if let openWindow {
            openWindow(id: Self.windowID)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Notice

/// A small panel that tells the user about a new crash report. It does not
/// take focus and does not block windows or document restoration.
@MainActor
final class CrashReportNotice {
    static let shared = CrashReportNotice()

    private var panel: NSPanel?

    func show(listing: CrashReportListing, unseenCount: Int) {
        guard panel == nil else { return }
        let content = CrashReportNoticeView(
            count: unseenCount,
            open: { [weak self] in
                self?.close()
                SettingsNavigator.shared.show(.crashReports)
            },
            dismiss: { [weak self] in
                // The user saw the notice. Do not show it again at the next
                // launch for the same reports.
                CrashReportSeenState(defaults: UserDefaults.standard).markSeen(listing)
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

    func close() {
        panel?.close()
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
                     ? "Tecolot saved a crash report on this Mac. It did not send it."
                     : "Tecolot saved \(count) crash reports on this Mac. It did not send them.")
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
/// `TECOLOT_CRASH_TEST` to `main` or `worker` to crash, or to `restart` to
/// start without a crash. Each value uses the `.crashtest` directories.
/// Release builds do not contain this code.
nonisolated enum CrashTestTrigger {
    static let environmentKey = "TECOLOT_CRASH_TEST"

    nonisolated static var mode: String? {
        ProcessInfo.processInfo.environment[environmentKey]
    }

    nonisolated static var isTestRun: Bool {
        mode != nil
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
