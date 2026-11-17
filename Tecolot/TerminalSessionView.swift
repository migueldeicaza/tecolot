//
//  TerminalSessionView.swift
//  Tecolot
//
//  Created by Miguel de Icaza on 8/5/25.
//

import AppKit
import Darwin
import Observation
import SwiftTerm
import SwiftUI
import TecolotSessionHost
import TecolotSessionClient
import TecolotSessionDirectory
import TecolotTransport
import TecolotWire
import UniformTypeIdentifiers

enum TerminalWindowTransparency {
    @MainActor
    static func apply(to window: NSWindow, isEnabled: Bool) {
        if isEnabled {
            guard window.isOpaque || window.backgroundColor != .clear else {
                return
            }
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            guard !window.isOpaque || window.backgroundColor == .clear else {
                return
            }
            window.isOpaque = true
            window.backgroundColor = nil
        }
    }
}

struct PanePresentation: Equatable {
    var title = "Terminal"
    var directory: String?
    var executablePath: String?
    var hasActivity = false
    var status = TabStatus.none
}

@Observable
final class TerminalSessionController: NSObject, LocalProcessTerminalViewDelegate {
    nonisolated static let useMetalRendererKey = "useMetalRenderer"
    nonisolated static let useMetalRendererDefault = true
    nonisolated static let copyOnSelectKey = "copyOnSelect"
    nonisolated static let copyOnSelectDefault = false

    /// The "Copy on selection" setting. Panes read it at the end of each
    /// selection gesture, thus each writer of the key (Settings, Reset
    /// Preferences, Restore Backup) applies to open panes at once.
    nonisolated static func copyOnSelectEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: copyOnSelectKey) as? Bool ?? copyOnSelectDefault
    }
    nonisolated static let logHostOutputKey = "LogHostOutput"
    nonisolated static let logHostOutputDefault = false

    /// Stays the same when the pane is restored after a relaunch.
    let id: UUID
    let programStatus: PaneProgramStatus
    @ObservationIgnored private var notifiedProgramReports: [String: WireProgramStatus] = [:]
    @ObservationIgnored private var remoteOutputSerial: UInt64?
    @ObservationIgnored private let startsProcess: Bool
    @ObservationIgnored private var didStartProcess = false
    @ObservationIgnored private var isTerminated = false
    @ObservationIgnored private var pendingFocus = false
    @ObservationIgnored private var pendingStart = false
    @ObservationIgnored private var postedTitle: String = ""
    @ObservationIgnored private var displayedTerminalTitle: String = ""
    @ObservationIgnored private var titleUpdateTask: Task<Void, Never>?
    private var postedDirectory: String?
    @ObservationIgnored private var zoomGesture: NSMagnificationGestureRecognizer?
    @ObservationIgnored private var keyEventMonitor: Any?
    private var logging = TerminalSessionController.logHostOutputDefault

    @ObservationIgnored private(set) var terminal: LocalProcessTerminalView?
    /// The view of a persistent pane; its shell runs in tecolot-sessiond.
    @ObservationIgnored private(set) var persistentView: RemoteTerminalView?
    @ObservationIgnored private var wantsPersistentSession = false
    @ObservationIgnored private var attachSessionID: String?
    private(set) var remoteDestination: String?
    @ObservationIgnored private var hostLink: HostLink?
    @ObservationIgnored private let clientInstance = UUID().uuidString
    @ObservationIgnored private var remoteGeneration: UInt64 = 0
    @ObservationIgnored private var remoteOpening = false
    @ObservationIgnored private var remoteLinking = false
    /// A restored remote pane connects when its window shows, so that the
    /// tabs that are not selected do not sign in at launch.
    @ObservationIgnored private var connectsWhenVisible = false
    @ObservationIgnored private var visibilityObserver: NSObjectProtocol?
    /// The window that `visibilityObserver` observes.
    @ObservationIgnored private weak var visibilityWindow: NSWindow?
    /// The pane connects when its window shows.
    @ObservationIgnored private var waitsForVisibleWindow = false
    @ObservationIgnored private var remoteNotice: String?
    /// The remote session of this pane ended. The saved layout leaves the pane out.
    @ObservationIgnored private(set) var remoteSessionEnded = false
    @ObservationIgnored private var remoteOpenFailed = false
    /// The user did not let Tecolot install its helper on the host.
    @ObservationIgnored private var remoteInstallDeclined = false
    /// The link generation in which this pane already reopened a closed session connection.
    @ObservationIgnored private var remoteReopenedGeneration: UInt64?
    /// The persistent session that this pane shows, if any.
    @ObservationIgnored private(set) var persistentSessionID: String?
    /// Set when this pane detaches on purpose, so the closed connection is expected.
    @ObservationIgnored private var persistentDetached = false
    @ObservationIgnored weak var workspace: TerminalPaneWorkspace?
    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var didRequestFocus = false
    /// Reads notifications (OSC 9, OSC 777) from the local terminal.
    @ObservationIgnored private var oscObservation: TerminalOscObservation?

    /// The profile driving this session; replaced by applyProfile(_:)
    private(set) var profile = TerminalProfile(name: "Untitled")
    /// Per-tab theme override; nil follows the profile's theme
    var themeOverride: String?
    /// Drives the per-window theme picker popover
    var showThemePicker = false
    private(set) var displayedWindowTitle = "Tecolot"
    private(set) var panePresentation = PanePresentation()
    /// Metadata followed by the window structure, excluding high-frequency activity.
    private(set) var windowPresentation = PanePresentation()
    @ObservationIgnored var launchDirectory: String?
    @ObservationIgnored private var didResolveLaunch = false
    /// The directory reports of the shell, for restoration and new tabs.
    @ObservationIgnored var directoryTracker = PaneDirectoryTracker()
    /// The shell of a persistent pane, from the helper's session information.
    @ObservationIgnored var persistentShellPID: Int32 = 0
    /// A restored local pane waits for its saved text and directory before
    /// its shell starts.
    @ObservationIgnored var awaitingRestore = false
    /// The text that a restored pane shows before its shell starts: the saved
    /// scrollback and the separator line.
    @ObservationIgnored var replayText: String?
    /// A restored persistent pane whose session ended starts a new session
    /// from this.
    @ObservationIgnored var pendingSessionRestore: PaneRestoration?
    /// The saved state that a pane of a restored tab came from. A pane that
    /// never gets a view (a hidden pane of a tab that comes back zoomed)
    /// saves this state again at quit.
    @ObservationIgnored private(set) var presetRestoration: PaneRestoration?
    /// The saved text file of a restored local pane, until its shell starts.
    @ObservationIgnored var restoredTextFile: Data?
    var hasStartedShell: Bool {
        didStartProcess
    }
    /// The session of a restored remote pane. When it ended, the bridge
    /// starts a new session from its saved state.
    @ObservationIgnored var remoteRestoreSessionID: String?
    /// The rows that a restored remote pane shows until it attaches. The
    /// pane deletes the file when it attaches.
    @ObservationIgnored var restoredRowsURL: URL?
    /// The rows of `restoredRowsURL`, after the read.
    @ObservationIgnored var restoredRows: RemoteRowSnapshot?
    /// The ended session that the next new remote session starts from. It
    /// stays until the bridge creates that session, so that a retry after a
    /// failure also restores.
    @ObservationIgnored private(set) var remotePendingRestore: String?
    @ObservationIgnored private weak var observedWindow: NSWindow?
    @ObservationIgnored private var windowKeyObserver: NSObjectProtocol?
    @ObservationIgnored private var windowUpdateObserver: NSObjectProtocol?
    @ObservationIgnored private var previewBackgroundOpacity: Double?
    /// The font size that Bigger/Smaller Font chose for a persistent pane.
    /// It stays when the pane reconnects; a profile change resets it, as
    /// in a local pane.
    @ObservationIgnored private var persistentFontSize: CGFloat?
    private(set) var hasActivity = false

    /// The terminal view of this pane, local or persistent.
    var surface: (NSView & TerminalSurface)? {
        terminal ?? persistentView
    }

    /// True for a pane whose shell runs in a persistent session.
    var isPersistent: Bool {
        persistentView != nil || wantsPersistentSession
    }

    @ObservationIgnored private let resumeRemotePrompts: @MainActor () -> Void
    init(startsProcess: Bool = true, id: UUID = UUID(), resumeRemotePrompts: @escaping @MainActor () -> Void = {
        RemoteHosts.shared.resumePendingPrompts()
    }) {
        self.startsProcess = startsProcess
        self.id = id
        self.resumeRemotePrompts = resumeRemotePrompts
        programStatus = PaneProgramStatus(paneID: id)
        super.init()
        ProgramActivityCenter.shared.start()
        programStatus.onChange = { [weak self] in
            self?.programActivityChanged()
        }
    }

    deinit {
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
        }
        if let windowUpdateObserver {
            NotificationCenter.default.removeObserver(windowUpdateObserver)
        }
        if let visibilityObserver {
            NotificationCenter.default.removeObserver(visibilityObserver)
        }
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        titleUpdateTask?.cancel()
    }

    /// Resolves launch parameters once, before building the pane's view.
    @MainActor
    func resolveLaunchIfNeeded(spec: LaunchSpec = LaunchSpec()) {
        guard !didResolveLaunch else {
            return
        }
        didResolveLaunch = true
        if
            let profileID = spec.profileID,
            let storedProfile = AppModel.shared.profiles.profile(withID: profileID) {
            profile = storedProfile
        } else {
            profile = AppModel.shared.profiles.defaultProfile
        }
        themeOverride = spec.themeOverride
        launchDirectory = spec.workingDirectory
        wantsPersistentSession = Self.startsPersistentSession(spec: spec, profile: profile)
        attachSessionID = spec.attachSessionID
        remoteDestination = spec.remoteDestination
    }

    /// New Persistent Tab and Attach to Session always use the helper; other
    /// new panes follow the profile.
    static func startsPersistentSession(spec: LaunchSpec?, profile: TerminalProfile) -> Bool {
        spec?.remoteDestination != nil || spec?.persistent == true || spec?.attachSessionID != nil
            || profile.sessionPersistence == .persistent
    }

    /// Sets up a pane of a restored layout. The pane keeps its kind: a local
    /// shell, a persistent session, or a remote session.
    @MainActor
    func presetRestore(_ restoration: PaneRestoration) {
        guard !didResolveLaunch else {
            return
        }
        didResolveLaunch = true
        presetRestoration = restoration
        let pane = restoration.pane
        profile =
            pane.profileID.flatMap {
                AppModel.shared.profiles.profile(withID: $0)
            }
            ?? AppModel.shared.profiles.defaultProfile
        themeOverride = pane.themeOverride
        directoryTracker = PaneDirectoryTracker(launch: pane.directory?.path)
        remoteDestination = pane.kind == .remote ? pane.remoteDestination : nil
        if restoration.startsFresh {
            if pane.kind == .remote {
                // The helper resolves its own directory; never check it on the Mac.
                launchDirectory = pane.directory?.path
                wantsPersistentSession = true
                return
            }
            wantsPersistentSession = pane.kind != .local
            if wantsPersistentSession {
                pendingSessionRestore = restoration
            } else {
                beginLocalRestore(restoration)
            }
            return
        }
        switch pane.kind {
        case .remote:
            remoteDestination = pane.remoteDestination
            wantsPersistentSession = true
            if restoration.restoresEndedSession {
                remotePendingRestore = pane.sessionID
            } else {
                attachSessionID = pane.sessionID
                remoteRestoreSessionID = pane.sessionID
                restoredRowsURL = restoration.cacheURL
                connectsWhenVisible = true
            }
        case .persistent:
            wantsPersistentSession = true
            if restoration.sessionRunning, let sessionID = pane.sessionID {
                attachSessionID = sessionID
            } else {
                pendingSessionRestore = restoration
            }
        case .local:
            beginLocalRestore(restoration)
        }
    }

    @MainActor
    func prepareForSplit(from source: TerminalSessionController) {
        guard !didResolveLaunch else {
            return
        }
        didResolveLaunch = true
        profile = source.profile
        themeOverride = source.themeOverride
        remoteDestination = source.remoteDestination
        launchDirectory = source.currentWorkingDirectory
        wantsPersistentSession = source.isPersistent
    }

    var reservedPersistentSessionIDs: [String] {
        [
            persistentSessionID,
            attachSessionID,
            remoteRestoreSessionID,
            remotePendingRestore,
            pendingSessionRestore?.pane.sessionID
        ].compactMap {
            $0
        }
    }

    /// Startup is complete after replay and shell launch, or a reply after attach.
    /// Failed/declined connections have reached a stable, retryable pane state.
    var hasCompletedRestorationStartup: Bool {
        if !startsProcess || isTerminated {
            return true
        }
        if isPersistent {
            return persistentView.map {
                Self.persistentStartupHasCompleted($0.session.state)
            } == true
                || persistentView?.session.state.exitStatus != nil
                || remoteOpenFailed || remoteInstallDeclined
        }
        return didStartProcess && !awaitingRestore && replayText == nil
    }

    static func persistentStartupHasCompleted(_ state: RemoteSessionState) -> Bool {
        // Hello precedes Attach. Hidden panes may receive info without frames.
        state.connected && (state.lastFrameSequence > 0 || state.info != nil)
    }

    /// The last directory that the shell reported on the pane's host. A
    /// report from another host (the shell runs `ssh`) does not change it.
    var currentWorkingDirectory: String? {
        directoryTracker.restore?.path
    }

    /// The last directory report from any host, for the title.
    var displayedDirectory: String? {
        directoryTracker.latest?.path
    }

    /// A local OSC 7 directory that the titlebar can open in Finder.
    var titlebarWorkingDirectory: String? {
        remoteDestination == nil ? TerminalWorkingDirectory.path(from: postedDirectory) : nil
    }

    /// The theme currently in effect for this session
    @MainActor
    var effectiveTheme: TerminalTheme {
        AppModel.shared.themes.theme(
            named: themeOverride ?? profile.themeName(isDark: AppModel.shared.systemAppearance.isDark)
        )
    }

    /// Applies a new profile to the running session (colors, font, cursor,
    /// keyboard, scrollback); shell settings only affect future launches
    @MainActor
    func applyProfile(_ newProfile: TerminalProfile) {
        if profile.screenChecksumReports != newProfile.screenChecksumReports {
            persistentView?.session.setScreenChecksumReports(newProfile.screenChecksumReports)
        }
        profile = newProfile
        previewBackgroundOpacity = nil
        applyAppearance()
        updateWindowTitle()
    }

    /// Sets or clears (nil) the per-tab theme override and re-applies colors
    @MainActor
    func applyThemeOverride(_ name: String?) {
        themeOverride = name
        applyAppearance()
    }

    /// Saves this session's theme as the profile default for the current
    /// system appearance. The theme of the other mode does not change.
    @MainActor
    func useThemeForAllWindows(in profiles: ProfileStore) throws {
        var updatedProfile = profile
        updatedProfile.setThemeName(effectiveTheme.name, isDark: AppModel.shared.systemAppearance.isDark)
        try profiles.update(updatedProfile)
        // Clear the local theme only after the profile save succeeds.
        // Apply the new profile here, before SwiftUI processes the store change.
        themeOverride = nil
        applyProfile(updatedProfile)
    }

    @MainActor
    func applyAppearance() {
        applyAppearance(colorsOnly: false)
    }

    /// Applies only the theme colors and the opacity. Use it when only the
    /// theme changes, for example when the system changes between Light
    /// and Dark Mode. It does not send the cursor style of the profile, so
    /// a cursor style that a program set stays.
    @MainActor
    func applyThemeColors() {
        applyAppearance(colorsOnly: true)
    }

    @MainActor
    private func applyAppearance(colorsOnly: Bool) {
        if let persistentView {
            // A profile change resets Bigger/Smaller Font, as in a local pane.
            if !colorsOnly {
                persistentFontSize = nil
            }
            applyPersistentAppearance(to: persistentView, colorsOnly: colorsOnly)
            return
        }
        guard let terminal else {
            return
        }
        if effectiveBackgroundOpacity < 1.0 {
            updateWindowTransparency()
        }
        if colorsOnly {
            ProfileApplier.apply(
                theme: effectiveTheme,
                opacity: effectiveBackgroundOpacity,
                to: terminal
            )
        } else {
            var appearanceProfile = profile
            appearanceProfile.backgroundOpacity = effectiveBackgroundOpacity
            ProfileApplier.apply(
                profile: appearanceProfile,
                themeStore: AppModel.shared.themes,
                sessionThemeOverride: themeOverride,
                isDark: AppModel.shared.systemAppearance.isDark,
                to: terminal
            )
        }
        (terminal.superview as? TerminalSessionContainerView)?.updatePaddingColor()
        terminal.requestRedraw()
        if effectiveBackgroundOpacity >= 1.0 {
            updateWindowTransparency()
        }
        workspace?.hostView?.refreshAppearance()
    }

    /// Applies an unsaved opacity value while the Settings slider is active.
    /// A nil value restores the persisted profile value.
    @MainActor
    func previewBackgroundOpacity(_ opacity: Double?) {
        let oldOpacity = effectiveBackgroundOpacity
        previewBackgroundOpacity = opacity
        let newOpacity = effectiveBackgroundOpacity
        guard oldOpacity != newOpacity else {
            return
        }
        guard let surface else {
            updateWindowTransparency()
            return
        }

        // The window must support alpha before the terminal draws a translucent
        // frame. Restore an opaque window only after the terminal is opaque.
        if newOpacity < 1.0 {
            updateWindowTransparency()
        }
        if let terminal {
            terminal.backgroundOpacity = CGFloat(newOpacity)
        } else {
            persistentView?.backgroundOpacity = CGFloat(newOpacity)
        }
        (surface.superview as? TerminalSessionContainerView)?.updatePaddingColor()
        surface.requestRedraw()
        if newOpacity >= 1.0 {
            updateWindowTransparency()
        }
        workspace?.hostView?.refreshAppearance()
    }

    var effectiveBackgroundOpacity: Double {
        previewBackgroundOpacity ?? profile.backgroundOpacity
    }

    /// A translucent terminal background only composites when the hosting
    /// window is non-opaque; restore normal opacity otherwise
    @MainActor
    private func updateWindowTransparency() {
        if let workspace {
            workspace.updateWindowTransparency()
            return
        }
        guard let window = surface?.window else {
            return
        }
        TerminalWindowTransparency.apply(
            to: window,
            isEnabled: effectiveBackgroundOpacity < 1.0
        )
    }

    func attach(to terminal: LocalProcessTerminalView) {
        if self.terminal !== terminal {
            isConfigured = false
            didRequestFocus = false
        }
        self.terminal = terminal
        registerWindowIfAvailable()
        if !isConfigured {
            configureTerminal(terminal)
            isConfigured = true
        }
        scheduleStartIfNeeded()
        scheduleFocusIfNeeded()
    }

    @MainActor
    func makeTerminalView() -> NSView & TerminalSurface {
        if let terminal {
            terminal.removeFromSuperview()
            attach(to: terminal)
            return terminal
        }
        if let persistentView {
            persistentView.removeFromSuperview()
            attachPersistentView()
            return persistentView
        }

        resolveLaunchIfNeeded()
        if wantsPersistentSession, let view = makePersistentView() {
            return view
        }
        let options = ProfileApplier.terminalOptions(for: profile)
        let terminal = AppTerminalView(
            frame: .zero,
            font: ProfileApplier.font(for: profile),
            options: options
        )
        terminal.sessionController = self
        // Bundled Symbols Nerd Font supplies icons the profile font lacks.
        terminal.glyphFallbackProvider = NerdFontFallbackProvider.shared
        // SwiftTerm does not show notifications; the helper does the same
        // for persistent panes.
        oscObservation = terminal.observeOscEvents(codes: [9, 777, 133, 7501]) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, let terminal = self.terminal as? AppTerminalView else {
                    return
                }
                if event.code == 133, event.payload.first == 65 {
                    terminal.programStatusTracker.dropTransient()
                    if self.programStatus.uses7501 {
                        self.programStatus.receive(terminal.programStatusTracker.snapshot)
                    }
                    self.programStatus.dropTransient()
                } else if event.code == 7501 {
                    if
                        terminal.programStatusTracker.observeReport(
                            event.payload, records: terminal.programStatusRecords
                        ) {
                        self.programStatus.receive(terminal.programStatusTracker.snapshot)
                    }
                } else if event.code == 9, let progress = Self.oscProgress(event.payload) {
                    self.programStatus.receiveProgress(progress)
                } else if let message = NotificationMessage(oscCode: event.code, payload: event.payload) {
                    TerminalNotifier.shared.notify(title: message.title, body: message.body, from: self)
                }
            }
        }
        attach(to: terminal)
        if !startsProcess {
            restoreBufferIfNeeded(on: terminal)
        }
        return terminal
    }

    func didBecomeFocused() {
        guard let window = surface?.window else {
            return
        }
        workspace?.markFocused(self)
        if workspace?.participatesInWindow != false {
            TerminalSessionRegistry.shared.focus(controller: self, for: window)
        }
        if NSApp.isActive, window.isKeyWindow, surface?.isHiddenOrHasHiddenAncestor == false {
            markProgramActivitySeenIfVisible()
        }
        updateWindowTitle()
    }

    /// Brings the window of this pane to the front and focuses the pane.
    func reveal() {
        (workspace?.windowManager ?? .shared).reveal(self)
        guard let surface, let window = surface.window else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surface)
        didBecomeFocused()
    }

    func requestFocus() {
        didRequestFocus = false
        scheduleFocusIfNeeded()
    }

    func sizeChanged(source _: LocalProcessTerminalView, newCols _: Int, newRows _: Int) {
        // LocalProcessTerminalView updates the PTY. Do not resize the window here.
        // A live resize sends many grid changes. Update the title only when
        // it shows the grid size.
        if profile.titleComponents.contains(.dimensions) {
            updateWindowTitle()
        }
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        postedTitle = title
        scheduleTerminalTitleUpdate()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        postedDirectory = directory
        noteDirectoryReport(directory)
        updateWindowTitle()
    }

    // MARK: Kitty clipboard protocol, OSC 5522
    //
    // LocalProcessTerminalView forwards these TerminalViewDelegate hooks to
    // its processDelegate. The complete standard-clipboard service, together
    // with the policy in ProfileApplier.terminalOptions, makes DEC private
    // mode 5522 report as supported.

    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
        // macOS has no primary selection, so only the standard clipboard.
        [.standardRead, .standardWrite]
    }

    func kittyClipboardRequestPermission(
        source: TerminalView,
        request: KittyClipboardPermissionRequest
    ) -> KittyClipboardPermissionResult {
        let verb = request.direction == .read ? "read" : "write"
        let who = request.name.isEmpty ? "An unnamed program" : request.name
        let alert = NSAlert()
        alert.messageText = "Allow the program to \(verb) the clipboard?"
        // The name and the MIME list come from the program in the terminal.
        // Show them as data, never as instructions.
        alert.informativeText =
            "\(who) asks to \(verb) these clipboard types:\n\n"
                + request.mimeTypes.joined(separator: ", ")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        if request.canRememberPassword {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember for this session"
        }
        // The hook is synchronous, so the prompt is modal.
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .deny
        }
        let remember = request.canRememberPassword && alert.suppressionButton?.state == .on
        return .allow(rememberPassword: remember)
    }

    @ObservationIgnored private var lastVisualBell: TimeInterval?
    @ObservationIgnored private var lastBellStyle: BellStyle?

    /// Preserves local native bell visuals and the pre-M4 persistent bell policy.
    /// Sound and inactive-app attention share the per-tab limits with program status.
    func noteBell(now: Date = Date()) {
        let style = TerminalNotificationPreferences.bellStyle(defaults: TerminalNotifier.shared.defaults)
        let policy = ProgramActivityBell.policy(style: style, local: terminal != nil)
        if owningTab?.isMuted != true {
            if policy.sound {
                TerminalNotifier.shared.playBell(from: self, now: now)
            }
            if style != lastBellStyle {
                lastVisualBell = nil
                lastBellStyle = style
            }
            if
                policy.visual, let surface,
                lastVisualBell.map({
                    now.timeIntervalSince1970 - $0 >= 0.1
                }) ?? true {
                lastVisualBell = now.timeIntervalSince1970
                ProgramActivityBell.flash(on: surface, color: surface.nativeForegroundColor)
            }
            TerminalNotifier.shared.requestAttention(from: self, now: now)
        }
        programStatus.noteNotification(isSeen: isProgramActivityVisible)
    }

    /// Parses the OSC 9;4 legacy fallback without treating notifications as progress.
    static func oscProgress(_ payload: [UInt8]) -> WireProgress? {
        let parts = String(decoding: payload, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "4", let state = UInt8(parts[1]), state <= 3 else {
            return nil
        }
        let progress = parts.count > 2 ? UInt8(parts[2]).map {
            min(100, $0)
        } : nil
        return WireProgress(state: state, progress: progress)
    }

    var owningTab: TerminalTab? {
        workspace?.owningTab
    }

    var isProgramActivityVisible: Bool {
        NSApp.isActive && isProgramTabShown && surface?.window?.isKeyWindow == true
    }
    var isProgramTabShown: Bool {
        if let tab = owningTab, let group = tab.group {
            let manager = workspace?.windowManager ?? .shared
            return group.selection == tab.id && manager.window(showing: group) != nil
        }
        return surface?.isHiddenOrHasHiddenAncestor == false && surface?.window != nil
    }

    /// Marks reports seen only while the pane belongs to the active key tab.
    func markProgramActivitySeenIfVisible() {
        guard isProgramActivityVisible else {
            return
        }
        programStatus.markSeen()
        setHasActivity(false)
        updateWindowTitle()
    }

    /// Refreshes tab presentation and emits notifications for newly changed reports.
    func programActivityChanged() {
        markProgramActivitySeenIfVisible()
        updateWindowTitle()
        for record in programStatus.records {
            let previous = notifiedProgramReports[record.id]
            notifiedProgramReports[record.id] = record
            guard
                previous?.state != record.state || previous?.kind != record.kind || previous?.message != record.message
            else {
                continue
            }
            TerminalNotifier.shared.notifyProgramStatus(record, from: self)
        }
        let ids = Set(programStatus.records.map(\.id))
        notifiedProgramReports = notifiedProgramReports.filter {
            ids.contains($0.key)
        }
        NotificationCenter.default.post(name: .programActivityDidChange, object: self)
    }

    /// Wraps the native local store in the shared host policy before presentation.
    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        guard let view = terminal as? AppTerminalView else {
            return
        }
        view.programStatusTracker.receive(records, isReport: false)
        programStatus.receive(view.programStatusTracker.snapshot)
    }

    /// Applies the tracker reset serial so legacy progress can resume after RIS.
    func programStatusDidReset() {
        guard let view = terminal as? AppTerminalView else {
            return
        }
        programStatus.receive(view.programStatusTracker.snapshot)
    }

    /// Conditionally clears seen completion versions locally or on the helper.
    func noteProgramKeypress() {
        let removed = programStatus.keypress()
        guard !removed.isEmpty else {
            return
        }
        (terminal as? AppTerminalView)?.programStatusTracker.clearSeen(removed)
        persistentView?.session.clearSeenProgramStatus(removed)
    }

    @ObservationIgnored private var framesVisible: Bool?
    /// Suspends hidden-pane frames while preserving status and resuming eligible sign-in.
    func setProgramStatusDrawingVisible(_ visible: Bool) {
        if framesVisible != visible {
            framesVisible = visible
            persistentView?.session.setFramesEnabled(visible)
            if visible {
                resumeRemotePrompts()
                markProgramActivitySeenIfVisible()
            }
        }
    }

    /// Raises quiet attention according to tab visibility and key-window state.
    func noteOutputActivity() {
        let shown = isProgramTabShown
        let key = surface?.window?.isKeyWindow == true
        programStatus.noteOutput(tabShown: shown, windowKey: key)
        setHasActivity(programStatus.quiet)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        processTerminated(source: nil, exitCode: exitCode)
    }

    func processTerminated(source _: TerminalView?, exitCode: Int32?) {
        guard !isTerminated else {
            return
        }
        if let terminal {
            terminal.programStatusProcessExited()
            (terminal as? AppTerminalView)?.programStatusTracker.processExited()
        }
        programStatus.dropTransient()
        let exitedCleanly = (exitCode ?? 0) == 0
        switch profile.whenShellExits {
        case .closeWindow:
            closePaneOrWindow()
        case .closeIfExitedCleanly:
            if exitedCleanly {
                closePaneOrWindow()
            } else {
                showCompletionBanner(exitCode: exitCode)
            }
        case .keepOpen:
            showCompletionBanner(exitCode: exitCode)
        }
    }

    private func closePaneOrWindow() {
        if let workspace {
            if workspace.close(self) {
                return
            }
            // After a close, the card of this pane can stay in the window
            // while it shrinks. Close the window only for its last pane.
            guard workspace.contains(self) else {
                return
            }
        }
        let manager = workspace?.windowManager ?? .shared
        if
            let group = manager.group(containing: self),
            let tab = group.tabs.first(where: {
                $0.loadedWorkspace?.contains(self) == true
            }) {
            manager.closeTab(tab, in: group)
        }
    }

    private func showCompletionBanner(exitCode: Int32?) {
        let status = exitCode.map {
            String($0)
        } ?? "?"
        if let persistentView {
            persistentView.showBanner("Process completed — exit \(status)", actionTitle: "Close") { [weak self] in
                self?.persistentView?.session.detach()
                self?.closePaneOrWindow()
            }
            return
        }
        terminal?.feed(text: "\r\n\u{1b}[7m[Process completed — exit \(status)]\u{1b}[0m\r\n")
    }

    func exportBuffer() {
        if let persistentView {
            persistentView.bufferText { [weak self] text in
                self?.saveData {
                    Data(text.utf8)
                }
            }
            return
        }
        saveData {
            self.terminal?.getBufferAsData() ?? Data()
        }
    }

    func exportSelection() {
        if let persistentView {
            persistentView.selectedText { [weak self] text in
                guard let text else {
                    return
                }
                self?.saveData {
                    Data(text.utf8)
                }
            }
            return
        }
        saveData {
            guard let selection = self.terminal?.getSelection() else {
                return Data()
            }
            return selection.data(using: .utf8) ?? Data()
        }
    }

    func printBuffer() {
        if let persistentView {
            persistentView.bufferText { [weak self] text in
                self?.printText(text)
            }
            return
        }
        guard
            let data = terminal?.getBufferAsData(),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        printText(text)
    }

    private func printText(_ text: String) {
        let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        printView.string = text
        printView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        printView.isEditable = false
        printView.sizeToFit()
        let operation = NSPrintOperation(view: printView)
        operation.jobTitle = surface?.window?.title ?? "Tecolot Terminal"
        operation.run()
    }

    /// Scrolls to the closest shell prompt above the viewport. Prompt rows
    /// come from OSC 133 shell integration; SwiftTerm classifies the rows and
    /// leaves the navigation policy to the host.
    @discardableResult
    func scrollToPreviousPrompt() -> Bool {
        scrollToPrompt(searchingUpward: true)
    }

    /// Scrolls to the closest shell prompt below the viewport
    @discardableResult
    func scrollToNextPrompt() -> Bool {
        scrollToPrompt(searchingUpward: false)
    }

    private func scrollToPrompt(searchingUpward: Bool) -> Bool {
        if let persistentView {
            // The helper has the prompt marks; the scroll happens when it answers.
            persistentView.scrollToPrompt(upward: searchingUpward)
            return true
        }
        guard let view = terminal else {
            return false
        }
        let row =
            searchingUpward
                ? view.previousSemanticPromptRow()
                : view.nextSemanticPromptRow()
        guard let row else {
            return false
        }
        view.scrollTo(row: row)
        return true
    }

    func softReset() {
        if let persistentView {
            persistentView.session.reset(.soft)
            return
        }
        terminal?.softReset()
    }

    func hardReset() {
        if let persistentView {
            persistentView.session.reset(.hard)
            return
        }
        terminal?.resetToInitialState()
    }

    /// Clears the screen and the scrollback without sending data to the program.
    func clearToStart() {
        if let persistentView {
            persistentView.session.reset(.clearToStart)
            return
        }
        guard let terminal else {
            return
        }
        TerminalClearAction.perform(on: terminal)
    }

    /// Runs a Find menu action in this pane.
    func performFind(_ action: NSTextFinder.Action) {
        if let persistentView {
            persistentView.performFind(action)
            return
        }
        let item = NSMenuItem()
        item.tag = action.rawValue
        terminal?.performTextFinderAction(item)
    }

    /// Sends text to the program as if the user typed it.
    func sendLiteralText(_ text: String) {
        if let persistentView {
            guard persistentView.remoteInputEnabled else {
                return
            }
            persistentView.session.send(bytes: Array(text.utf8))
            return
        }
        terminal?.send(txt: text)
    }

    var allowMouseReporting: Bool {
        get { terminal?.allowMouseReporting ?? persistentView?.allowMouseReporting ?? false }
        set {
            if let persistentView {
                persistentView.allowMouseReporting = newValue
                return
            }
            terminal?.allowMouseReporting = newValue
        }
    }

    var optionAsMetaKey: Bool {
        get { terminal?.optionAsMetaKey ?? persistentView?.optionAsMetaKey ?? false }
        set {
            if let persistentView {
                persistentView.optionAsMetaKey = newValue
                return
            }
            terminal?.optionAsMetaKey = newValue
        }
    }

    var useMetalRenderer: Bool {
        get { persistentView?.isUsingMetalRenderer ?? terminal?.isUsingMetalRenderer ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: TerminalSessionController.useMetalRendererKey)
            TerminalSessionRegistry.shared.setUseMetalRenderer(newValue)
        }
    }

    /// The user completed a selection in a local pane. SwiftTerm's
    /// `copyOnSelect` stays `.off`; the setting is read here. A selection of
    /// only white space is not copied. `RemoteTerminalView` applies the same
    /// policy to a remote pane.
    func selectionFinished(source: TerminalView) {
        guard
            Self.copyOnSelectEnabled(), let text = source.getSelection(),
            !text.allSatisfy(\.isWhitespace) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func setUseMetalRenderer(_ enabled: Bool) {
        if let persistentView {
            do {
                try persistentView.setUseMetal(enabled)
            } catch {
                print("METAL TOGGLE FAILED: \(error)")
            }
            persistentView.requestRedraw()
            return
        }
        guard let terminal else {
            return
        }
        do {
            try terminal.setUseMetal(enabled)
        } catch {
            print("METAL TOGGLE FAILED: \(error)")
        }
        terminal.requestRedraw()
    }

    var usePerFrameMetalBuffering: Bool {
        get { (persistentView?.metalBufferingMode ?? terminal?.metalBufferingMode) == .perFrameAggregated }
        set {
            if let persistentView {
                persistentView.metalBufferingMode = newValue ? .perFrameAggregated : .perRowPersistent
                return
            }
            guard let terminal else {
                return
            }
            terminal.metalBufferingMode = newValue ? .perFrameAggregated : .perRowPersistent
            terminal.requestRedraw()
        }
    }

    var logHostOutput: Bool {
        get { logging }
        set {
            logging = newValue
            updateLogging()
        }
    }

    var selectionActive: Bool {
        surface?.selectionActive ?? false
    }

    /// The font of the pane's view, local or persistent.
    private var surfaceFont: NSFont? {
        terminal?.font ?? persistentView?.font
    }

    func biggerFont() {
        guard let size = surfaceFont?.pointSize, size < 72 else {
            return
        }
        setFontSize(size + 1)
    }

    func smallerFont() {
        guard let size = surfaceFont?.pointSize, size > 5 else {
            return
        }
        setFontSize(size - 1)
    }

    func defaultFontSize() {
        persistentFontSize = nil
        setFontSize(CGFloat(profile.fontSize))
    }

    /// Changes only the size, keeping the profile's font family. A
    /// persistent view sends its new grid size to the helper.
    private func setFontSize(_ size: CGFloat) {
        if let persistentView {
            persistentFontSize = size == CGFloat(profile.fontSize) ? nil : size
            persistentView.font = Self.font(persistentView.font, size: size)
            return
        }
        guard let terminal else {
            return
        }
        terminal.font = Self.font(terminal.font, size: size)
    }

    private static func font(_ font: NSFont, size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Ends a local shell. A persistent pane detaches instead: closing a pane
    /// or a window never ends a persistent session.
    func terminate() {
        guard !isTerminated else {
            return
        }
        isTerminated = true
        persistentDetached = true
        TerminalSessionRegistry.shared.unregister(controller: self)
        if let persistentView {
            stopWaitingForVisibleWindow()
            persistentView.session.detach()
            if let hostLink {
                Task { @MainActor in
                    RemoteHosts.shared.removeObserver(link: hostLink, observer: self.id)
                }
                self.hostLink = nil
            }
            return
        }
        terminal?.terminate()
    }

    /// Ends the persistent session that this pane shows after the user
    /// confirms.
    func terminateSession() {
        guard persistentView != nil else {
            return
        }
        let sessions = [SessionRef(id: persistentSessionID ?? "", destination: remoteDestination)]
        Task { @MainActor [weak self] in
            guard await SessionTermination.confirm(sessions, in: self?.surface?.window) else {
                return
            }
            self?.terminateSessionNow()
        }
    }

    /// Ends the persistent session that this pane shows.
    func terminateSessionNow() {
        persistentView?.session.terminate(signal: SIGHUP)
    }

    func requestClose() {
        guard let window = surface?.window else {
            return
        }
        // A pane that the workspace removed is closed already.
        if let workspace, !workspace.contains(self) {
            return
        }
        guard let workspace, workspace.paneCount > 1 else {
            if
                let owner = (workspace?.windowManager ?? .shared).controller(for: window),
                let tab = owner.group.selectedTab {
                owner.requestCloseTab(tab)
            }
            return
        }

        guard TerminalClosePolicy.requiresConfirmation(for: self) else {
            workspace.close(self)
            return
        }

        TabCloseConfirmation.present(required: true, title: "Close this pane?", in: window) { [weak self] in
            guard let self else {
                return
            }
            self.workspace?.close(self)
        }
    }

    @objc private func handleMagnify(_ sender: NSMagnificationGestureRecognizer) {
        if sender.magnification > 0 {
            biggerFont()
        } else {
            smallerFont()
        }
    }

    private func configureTerminal(_ terminal: LocalProcessTerminalView) {
        terminal.metalBufferingMode = .perFrameAggregated
        setUseMetalRenderer(UserDefaults.standard.object(forKey: TerminalSessionController.useMetalRendererKey) as? Bool ?? TerminalSessionController.useMetalRendererDefault)
        applyAppearance()
        terminal.processDelegate = self
        // Tecolot uses Command keys for its menus and profile bindings.
        // Let menu Copy run when text is selected. Otherwise, send Command-C
        // to programs that use the enhanced keyboard protocol.
        terminal.shouldSendCommandKeyToTerminal = { [weak terminal] event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard
                modifiers == [.command],
                event.charactersIgnoringModifiers?.lowercased() == "c"
            else {
                return false
            }
            return terminal?.selectionActive == false
        }

        if zoomGesture == nil {
            let gesture = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
            terminal.addGestureRecognizer(gesture)
            zoomGesture = gesture
        }

        if keyEventMonitor == nil {
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyBinding(event) == true ? nil : event
            }
        }

        logging = NSUserDefaultsController.shared.defaults.bool(forKey: TerminalSessionController.logHostOutputKey)
        updateLogging()
    }

    private func handleKeyBinding(_ event: NSEvent) -> Bool {
        guard
            let surface,
            event.window === surface.window,
            surface.window?.firstResponder === surface
        else {
            return false
        }

        noteProgramKeypress()
        if profile.hidePointerWhileTyping {
            NSCursor.setHiddenUntilMouseMoves(true)
        }

        let key = normalizedKey(for: event)
        let modifiers = terminalModifiers(for: event.modifierFlags)
        guard
            let keyBinding = profile.keyBindings.first(where: {
                $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key && $0.modifiers == modifiers
            })
        else {
            return false
        }

        switch keyBinding.action {
        case .sendText:
            sendBindingText(decodedKeyBindingText(keyBinding.value))
        case .sendEscapeSequence:
            sendBindingText("\u{1b}" + decodedKeyBindingText(keyBinding.value))
        case .scrollPageUp:
            scroll(by: -surface.gridDimensions.rows)
        case .scrollPageDown:
            scroll(by: surface.gridDimensions.rows)
        case .scrollLineUp:
            scroll(by: -1)
        case .scrollLineDown:
            scroll(by: 1)
        }
        return true
    }

    private func sendBindingText(_ text: String) {
        if let persistentView {
            guard persistentView.remoteInputEnabled else {
                return
            }
            persistentView.session.send(bytes: Array(text.utf8))
        } else {
            terminal?.send(txt: text)
        }
    }

    private func scroll(by rows: Int) {
        if let persistentView {
            persistentView.session.scroll(by: rows)
            return
        }
        guard let terminal else {
            return
        }
        let state = terminal.terminalStateSnapshot()
        terminal.scrollTo(row: max(0, state.viewportRow + rows))
    }

    private func terminalModifiers(for flags: NSEvent.ModifierFlags) -> TerminalKeyModifiers {
        var result: TerminalKeyModifiers = []
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            result.insert(.command)
        }
        if flags.contains(.shift) {
            result.insert(.shift)
        }
        if flags.contains(.option) {
            result.insert(.option)
        }
        if flags.contains(.control) {
            result.insert(.control)
        }
        return result
    }

    private func normalizedKey(for event: NSEvent) -> String {
        switch event.keyCode {
        case 122:
            return "f1"
        case 120:
            return "f2"
        case 99:
            return "f3"
        case 118:
            return "f4"
        case 96:
            return "f5"
        case 97:
            return "f6"
        case 98:
            return "f7"
        case 100:
            return "f8"
        case 101:
            return "f9"
        case 109:
            return "f10"
        case 103:
            return "f11"
        case 111:
            return "f12"
        case 105:
            return "f13"
        case 107:
            return "f14"
        case 113:
            return "f15"
        case 106:
            return "f16"
        case 64:
            return "f17"
        case 79:
            return "f18"
        case 80:
            return "f19"
        case 90:
            return "f20"
        case 36:
            return "return"
        case 48:
            return "tab"
        case 51:
            return "delete"
        case 53:
            return "escape"
        case 115:
            return "home"
        case 116:
            return "pageup"
        case 117:
            return "forwarddelete"
        case 119:
            return "end"
        case 121:
            return "pagedown"
        case 123:
            return "left"
        case 124:
            return "right"
        case 125:
            return "down"
        case 126:
            return "up"
        default:
            return event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
    }

    private func decodedKeyBindingText(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "e":
                result.append("\u{1b}")
            case "n":
                result.append("\n")
            case "r":
                result.append("\r")
            case "t":
                result.append("\t")
            case "\\":
                result.append("\\")
            default:
                result.append("\\")
                result.append(escaped)
            }
        }
        return result
    }

    private func scheduleFocusIfNeeded() {
        guard !didRequestFocus, !pendingFocus else {
            return
        }
        pendingFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.pendingFocus = false
            self.focusIfNeeded()
        }
    }

    /// Automatic focus requests preserve editors and keyboard navigation in window chrome.
    static func canAutomaticallyFocus(from responder: NSResponder?, in window: NSWindow) -> Bool {
        if let view = responder as? NSView, view.isHiddenOrHasHiddenAncestor {
            return true
        }
        return responder == nil || responder === window || responder is AppTerminalView || responder is RemoteTerminalView
    }

    private func focusIfNeeded() {
        guard !didRequestFocus, let terminal = surface else {
            return
        }
        guard let window = terminal.window, !terminal.isHiddenOrHasHiddenAncestor else {
            return
        }
        registerWindowIfAvailable()
        // A view update can request focus while the app is in the background.
        // Do not let an internal focus request activate the app or raise a window.
        guard NSApp.isActive, window.isKeyWindow else {
            return
        }
        guard Self.canAutomaticallyFocus(from: window.firstResponder, in: window) else {
            return
        }
        window.makeFirstResponder(terminal)
        didRequestFocus = true
        didBecomeFocused()
    }

    func surfaceDidMoveToWindow() {
        registerWindowIfAvailable()
        if surface?.window != nil {
            scheduleStartIfNeeded()
            scheduleFocusIfNeeded()
        }
    }

    private func registerWindowIfAvailable() {
        guard workspace?.participatesInWindow != false else {
            return
        }
        if observedWindow !== surface?.window {
            if let windowKeyObserver {
                NotificationCenter.default.removeObserver(windowKeyObserver)
            }
            if let windowUpdateObserver {
                NotificationCenter.default.removeObserver(windowUpdateObserver)
            }
            windowKeyObserver = nil
            windowUpdateObserver = nil
            observedWindow = nil
        }
        guard let window = surface?.window else {
            return
        }
        TerminalSessionRegistry.shared.register(controller: self, workspace: workspace, for: window)
        // RestoreStore brings the terminal windows back. AppKit restoration
        // would bring them back a second time, without their panes.
        window.isRestorable = false
        observeWindowKeyState(for: window)
        updateWindowTransparency()
    }

    @ObservationIgnored private var lastObservedResponder: ObjectIdentifier?
    private func observeWindowKeyState(for window: NSWindow) {
        guard observedWindow !== window else {
            return
        }
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
        }
        if let windowUpdateObserver {
            NotificationCenter.default.removeObserver(windowUpdateObserver)
        }
        observedWindow = window
        lastObservedResponder = nil
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor [weak self, weak window] in
                guard
                    let self, let window, self.observedWindow === window,
                    self.surface?.window === window,
                    self.surface?.isHiddenOrHasHiddenAncestor == false
                else {
                    return
                }
                self.setHasActivity(false)
            }
        }
        windowUpdateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            // didUpdate posts on nearly every pass of the event loop, once per
            // pane. Test the responder before spending a task on it.
            MainActor.assumeIsolated {
                guard let self, let window else {
                    return
                }
                let responder = window.firstResponder.map(ObjectIdentifier.init)
                let changed = self.lastObservedResponder != responder
                self.lastObservedResponder = responder
                guard changed, window.isKeyWindow, let surface = self.surface, window.firstResponder === surface else {
                    return
                }
                self.didBecomeFocused()
            }
        }
        if window.isKeyWindow, surface?.isHiddenOrHasHiddenAncestor == false {
            setHasActivity(false)
        }
    }

    private func setHasActivity(_ hasActivity: Bool) {
        guard self.hasActivity != hasActivity else {
            return
        }
        self.hasActivity = hasActivity
        updateWindowTitle()
    }

    func scheduleStartIfNeeded() {
        guard !isTerminated, startsProcess, !didStartProcess, !pendingStart, !awaitingRestore else {
            return
        }
        pendingStart = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.pendingStart = false
            self.startShellIfReady()
        }
    }

    private func startShellIfReady() {
        guard !isTerminated, !didStartProcess, !awaitingRestore, let terminal else {
            return
        }
        terminal.layoutSubtreeIfNeeded()
        let dimensions = terminal.terminalDimensions
        guard dimensions.cols > 2, dimensions.rows > 2 else {
            scheduleStartIfNeeded()
            return
        }
        didStartProcess = true
        restoredTextFile = nil

        restoreBufferIfNeeded(on: terminal)

        let params = ProfileApplier.launchParameters(for: profile, initialDirectory: launchDirectory)
        directoryTracker.launch = params.currentDirectory
        terminal.startProcess(
            executable: params.executable,
            args: params.args,
            environment: params.environment,
            execName: params.execName,
            currentDirectory: params.currentDirectory
        )
        terminal.sizeChanged(
            source: terminal,
            newCols: dimensions.cols,
            newRows: dimensions.rows
        )
    }

    private func restoreBufferIfNeeded(on terminal: LocalProcessTerminalView) {
        // A restored pane: the saved text, then the separator, then the shell.
        if let replayText {
            self.replayText = nil
            if (try? ScrollbackFile.validate(replayText)) != nil {
                terminal.feed(text: ScrollbackFile.terminalBytes(replayText))
            }
        }
    }

    private func scheduleTerminalTitleUpdate() {
        titleUpdateTask?.cancel()
        titleUpdateTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(75))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else {
                return
            }
            self.titleUpdateTask = nil
            self.displayedTerminalTitle = self.postedTitle
            self.updateWindowTitle()
        }
    }

    private func updateWindowTitle() {
        guard let terminal = surface else {
            return
        }
        let dimensions = terminal.gridDimensions
        var components: [String] = []

        func appendIfPresent(_ value: String?) {
            guard let value, !value.isEmpty else {
                return
            }
            components.append(value)
        }

        appendIfPresent(profile.titleOverride)
        if profile.titleComponents.contains(.activeTitle) {
            appendIfPresent(displayedTerminalTitle)
        }
        if profile.titleComponents.contains(.dimensions) {
            appendIfPresent("\(dimensions.cols) x \(dimensions.rows)")
        }
        if let directory = displayedDirectory {
            if profile.titleComponents.contains(.fullPath) {
                appendIfPresent(directory)
            } else if profile.titleComponents.contains(.workingDirectory) {
                appendIfPresent(URL(fileURLWithPath: directory).lastPathComponent)
            }
        }
        if profile.titleComponents.contains(.profileName) {
            appendIfPresent(profile.name)
        }

        let newTitle = components.joined(separator: " — ")
        var presentation = panePresentation
        presentation.title = newTitle.isEmpty ? "Terminal" : newTitle
        presentation.directory = displayedDirectory ?? launchDirectory
        presentation.hasActivity = programStatus.quiet
        presentation.status = programStatus.tabStatus
        if presentation != panePresentation {
            panePresentation = presentation
        }
        var metadata = presentation
        metadata.hasActivity = false
        metadata.status = .none
        if metadata != windowPresentation {
            windowPresentation = metadata
        }
        if let focused = workspace?.focusedController, focused !== self {
            focused.updateWindowTitle()
            return
        }
        let effectiveTitle = newTitle.isEmpty ? "Terminal" : newTitle
        if displayedWindowTitle != effectiveTitle {
            displayedWindowTitle = effectiveTitle
        }
    }

    func updatePaneExecutablePath(_ path: String?) {
        guard panePresentation.executablePath != path else {
            return
        }
        panePresentation.executablePath = path
        windowPresentation.executablePath = path
    }

    private func updateLogging() {
        NSUserDefaultsController.shared.defaults.set(logging, forKey: TerminalSessionController.logHostOutputKey)
        let path = logging ? "\(FileManager.default.homeDirectoryForCurrentUser.path)/Downloads/Logs" : nil
        terminal?.setHostLogging(directory: path)
    }

    private func saveData(_ getData: @escaping () -> Data) {
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        if #available(macOS 12.0, *) {
            savePanel.allowedContentTypes = [UTType.text, UTType.plainText]
        } else {
            savePanel.allowedFileTypes = ["txt"]
        }
        savePanel.title = "Export Buffer Contents As Text"
        savePanel.nameFieldStringValue = "TerminalCapture"

        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                do {
                    try getData().write(to: url)
                } catch let error as NSError {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }

}

// MARK: - Persistent sessions

extension TerminalSessionController {
    /// Creates (or attaches to) the persistent session for this pane. Returns
    /// nil, and the pane falls back to a local shell, when that fails.
    @MainActor
    func makePersistentView() -> RemoteTerminalView? {
        if let remoteDestination {
            return makeHostPersistentView(destination: remoteDestination)
        }
        let font = ProfileApplier.font(for: profile)
        if let restoration = pendingSessionRestore {
            // The session ended (the Mac restarted). The pane shows at once;
            // the new session starts when its directory and text are ready.
            pendingSessionRestore = nil
            let view = RemoteTerminalView(session: makeRemoteSession(socket: -1), font: font)
            view.sessionController = self
            view.glyphFallbackProvider = NerdFontFallbackProvider.shared
            persistentView = view
            attachPersistentView()
            startReplacementSession(for: restoration)
            return view
        }
        guard let sessionID = attachSessionID else {
            // A new session: the helper can take seconds to start (or time
            // out). The pane shows at once and the session attaches when the
            // helper is ready.
            let view = RemoteTerminalView(session: makeRemoteSession(socket: -1), font: font)
            view.sessionController = self
            view.glyphFallbackProvider = NerdFontFallbackProvider.shared
            persistentView = view
            attachPersistentView()
            startNewSession()
            return view
        }
        do {
            let socket = try PersistentSessions.directory().connect(sessionID)
            let session = makeRemoteSession(socket: socket)
            let view = RemoteTerminalView(session: session, font: font)
            view.sessionController = self
            view.glyphFallbackProvider = NerdFontFallbackProvider.shared
            persistentView = view
            persistentSessionID = sessionID
            attachSessionID = nil
            session.start(
                size: WireGridSize(columns: profile.columns, rows: profile.rows),
                focused: false,
                scale: Int(((NSScreen.main?.backingScaleFactor ?? 2) * 100).rounded()),
                screenChecksumReports: profile.screenChecksumReports, framesEnabled: framesVisible != false
            )
            attachPersistentView()
            return view
        } catch {
            wantsPersistentSession = false
            let alert = NSAlert()
            alert.messageText = "Could not start a persistent session"
            alert.informativeText = error.localizedDescription
            DispatchQueue.main.async {
                alert.runModal()
            }
            return nil
        }
    }

    /// Starts the helper of a new session for the pane's profile.
    @MainActor
    private func startNewSession() {
        guard let helperPath = PersistentSessions.helperPath else {
            showReplacementError(PersistentSessionError.helperMissing)
            return
        }
        let launch = PersistentSessions.makeLaunch(
            profile: profile, workingDirectory: launchDirectory,
            columns: profile.columns, rows: profile.rows,
            cellWidth: 0, cellHeight: 0
        )
        createSession(launch, helperPath: helperPath)
    }

    /// Starts a helper for `launch` off the main thread, then shows its
    /// session in this pane. When the pane closes before the helper is
    /// ready, the new session ends. `created` runs before the attach.
    @MainActor
    @discardableResult
    func createSession(
        _ launch: SessionLaunch, helperPath: String,
        created: @escaping @MainActor () -> Void = {}
    ) -> Task<Void, Never> {
        Task { [weak self] in
            let result: Result<SessionRecord, Error>
            do {
                let directory = try PersistentSessions.directory()
                result = await Task.detached(priority: .userInitiated) {
                    Result {
                        try directory.create(launch, helperPath: helperPath)
                    }
                }.value
            } catch {
                result = .failure(error)
            }
            guard let self, !self.persistentDetached else {
                if case .success(let record) = result {
                    try? PersistentSessions.directory().terminate(record.id)
                }
                return
            }
            switch result {
            case .success(let record):
                created()
                self.attachReplacementSession(record.id)
            case .failure(let error):
                self.showReplacementError(error)
            }
        }
    }

    /// Creates the pane before SSH resolves, so connection errors stay in the pane.
    @MainActor
    private func makeHostPersistentView(destination: String) -> RemoteTerminalView {
        let session = makeRemoteSession(socket: -1)
        let view = RemoteTerminalView(session: session, font: ProfileApplier.font(for: profile))
        view.sessionController = self
        view.remoteDestination = destination
        view.remoteInputEnabled = false
        view.glyphFallbackProvider = NerdFontFallbackProvider.shared
        persistentView = view
        persistentSessionID = attachSessionID
        attachPersistentView()
        updateRemoteBanner(state: .resolving)
        showRestoredRows()
        if connectsWhenVisible {
            connectRemoteHostWhenVisible()
        } else {
            connectRemoteHost()
        }
        return view
    }

    /// Connects when the pane's window shows (spec-restoration.md section 9).
    @MainActor
    private func connectRemoteHostWhenVisible() {
        connectsWhenVisible = false
        waitsForVisibleWindow = true
        connectIfWindowVisible()
    }

    /// Connects a pane that waits for its window, when the window shows.
    /// The view calls it also when it moves to another window. Only the
    /// pane's window is observed.
    @MainActor
    func connectIfWindowVisible() {
        guard waitsForVisibleWindow else {
            return
        }
        let window = persistentView?.window
        if let window, window.occlusionState.contains(.visible) {
            stopWaitingForVisibleWindow()
            connectRemoteHost()
            return
        }
        guard window !== visibilityWindow || visibilityObserver == nil else {
            return
        }
        removeVisibilityObserver()
        guard let window else {
            return
        }
        visibilityWindow = window
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.connectIfWindowVisible()
            }
        }
    }

    @MainActor
    private func stopWaitingForVisibleWindow() {
        waitsForVisibleWindow = false
        removeVisibilityObserver()
    }

    @MainActor
    private func removeVisibilityObserver() {
        if let visibilityObserver {
            NotificationCenter.default.removeObserver(visibilityObserver)
        }
        visibilityObserver = nil
        visibilityWindow = nil
    }

    /// Shows the new session that replaces an ended one in this pane.
    @MainActor
    func attachReplacementSession(_ id: String) {
        guard let view = persistentView, !persistentDetached else {
            return
        }
        do {
            let socket = try PersistentSessions.directory().connect(id)
            let session = makeRemoteSession(socket: socket)
            view.replaceSession(session)
            persistentSessionID = id
            // A view that is not laid out yet starts with the profile's size.
            let grid = view.wireGridSize
            let size =
                grid.columns > 1 && grid.rows > 1 ? grid : WireGridSize(columns: profile.columns, rows: profile.rows)
            session.start(
                size: size, focused: view.hasFocus, scale: view.displayScale,
                screenChecksumReports: profile.screenChecksumReports, framesEnabled: framesVisible != false
            )
            // The new session needs the theme; the view keeps its other settings.
            applyPersistentAppearance(to: view, colorsOnly: true)
        } catch {
            showReplacementError(error)
        }
    }

    @MainActor
    func showReplacementError(_ error: Error) {
        guard !persistentDetached else {
            return
        }
        persistentView?.showBanner(
            "Could not start a persistent session: \(error.localizedDescription)",
            actionTitle: "Close"
        ) { [weak self] in
            self?.closePaneOrWindow()
        }
    }

    @MainActor
    private func connectRemoteHost() {
        guard let destination = remoteDestination, !persistentDetached, !remoteLinking else {
            return
        }
        remoteLinking = true
        RemoteHosts.shared.link(destination: destination) { [weak self] result in
            guard let self else {
                return
            }
            self.remoteLinking = false
            guard !self.persistentDetached else {
                return
            }
            switch result {
            case .success(let link):
                self.hostLink = link
                // The state callback can open the pane first; openRemotePane opens it only once.
                RemoteHosts.shared.observe(
                    link: link, observer: self.id,
                    state: { [weak self] state in
                        self?.remoteLinkChanged(state)
                    },
                    notice: { [weak self, weak link] notice in
                        self?.remoteNotice = notice
                        if let link {
                            self?.updateRemoteBanner(state: link.state)
                        }
                    }, window: { [weak self] in
                        self?.surface?.window
                    },
                    install: { [weak self] prompt in
                        self?.showRemoteInstall(prompt)
                    }
                )
                self.openRemotePane(link: link, sessionID: self.persistentSessionID)
            case .failure(let error):
                self.showRemoteError(error)
            }
        }
    }

    /// `restoring` names the ended session that a restored pane showed: the
    /// bridge starts the new session from its saved state.
    @MainActor
    private func openRemotePane(link: HostLink, sessionID: String?, restoring: String? = nil) {
        guard let view = persistentView, !persistentDetached, !remoteOpening, !remoteSessionEnded else {
            return
        }
        remoteOpening = true
        remoteOpenFailed = false
        let restoring = restoring ?? (sessionID == nil ? remotePendingRestore : nil)
        var launch = PersistentSessions.makeRemoteLaunch(
            profile: profile, destination: remoteDestination ?? link.destination,
            workingDirectory: restoring != nil ? directoryTracker.launch : launchDirectory
        )
        launch.restoreSessionID = restoring
        let socket = link.openPane(
            sessionID: sessionID, launch: sessionID == nil ? launch : nil,
            created: { [weak self] id in
                // Keep the ID also when the attach fails, so that a retry does not create another session.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.persistentDetached else {
                        return
                    }
                    self.persistentSessionID = id
                    self.attachSessionID = nil
                    self.remotePendingRestore = nil
                }
            }
        ) { [weak self, weak link] result in
            let generation = link?.connectionGeneration ?? 0
            DispatchQueue.main.async { [weak self, weak link] in
                guard let self, let link, !self.persistentDetached else {
                    return
                }
                self.remoteOpening = false
                switch result {
                case .success(let id):
                    self.persistentSessionID = id
                    self.attachSessionID = nil
                    self.remoteRestoreSessionID = nil
                    self.removeRestoredRows()
                    self.remoteGeneration = generation
                    self.remoteLinkChanged(link.state)
                case .failure(let error):
                    if case .unsupported = link.state {
                        // The state banner tells why. A retry cannot help.
                        self.updateRemoteBanner(state: link.state)
                    } else if let sessionID, case .connected = link.state {
                        link.listSessions { [weak self] records in
                            DispatchQueue.main.async { [weak self] in
                                guard let self, !self.persistentDetached else {
                                    return
                                }
                                if
                                    case .success(let records) = records,
                                    !records.contains(where: {
                                        $0.id == sessionID
                                    }),
                                    self.remoteRestoreSessionID == sessionID {
                                    // A restored pane whose session ended (the host
                                    // restarted): start a new session in its place.
                                    self.remoteRestoreSessionID = nil
                                    self.remotePendingRestore = sessionID
                                    self.persistentSessionID = nil
                                    self.openRemotePane(link: link, sessionID: nil)
                                } else if
                                    case .success(let records) = records,
                                    !records.contains(where: {
                                        $0.id == sessionID
                                    }) {
                                    self.remoteSessionEnded = true
                                    self.persistentView?.remoteInputEnabled = false
                                    self.persistentView?.showBanner("The session ended.", actionTitle: "Close") {
                                        [weak self] in
                                        self?.closePaneOrWindow()
                                    }
                                } else {
                                    self.showRemoteError(error)
                                }
                            }
                        }
                    } else {
                        self.showRemoteError(error)
                    }
                }
            }
        }
        guard socket >= 0 else {
            remoteOpening = false
            return
        }
        let session = makeRemoteSession(socket: socket)
        // Before the start: the preload must come before the first frame.
        preloadRestoredRows(in: session)
        view.replaceSession(session)
        view.remoteInputEnabled = false
        updateRemoteBanner(state: link.state)
        session.start(
            size: view.wireGridSize, focused: view.hasFocus, scale: view.displayScale,
            screenChecksumReports: profile.screenChecksumReports, framesEnabled: framesVisible != false
        )
        applyPersistentAppearance(to: view, colorsOnly: true)
    }

    @MainActor
    private func remoteLinkChanged(_ state: HostLinkState) {
        guard !persistentDetached, !remoteSessionEnded, persistentView?.session.state.exitStatus == nil else {
            return
        }
        updateRemoteBanner(state: state)
        if
            case .connected(_, let generation) = state, let link = hostLink,
            generation > remoteGeneration, !remoteOpening {
            openRemotePane(link: link, sessionID: persistentSessionID)
        }
    }

    /// Shows the install question above the terminal, or removes it.
    @MainActor
    private func showRemoteInstall(_ prompt: RemoteInstallPrompt?) {
        guard let container = persistentView?.superview as? TerminalSessionContainerView else {
            return
        }
        if let prompt {
            if (container.topBanner as? RemoteInstallBanner)?.prompt == prompt {
                return
            }
            let banner = RemoteInstallBanner(
                prompt: prompt,
                isActive: { [weak self] in
                    guard let view = self?.persistentView else {
                        return false
                    }
                    return view.window?.firstResponder === view
                },
                answer: { [weak self] accepted in
                    if !accepted {
                        self?.remoteInstallDeclined = true
                    }
                    RemoteHosts.shared.answerInstall(id: prompt.id, accepted: accepted)
                }
            )
            container.setTopBanner(banner)
        } else if container.topBanner is RemoteInstallBanner {
            container.setTopBanner(nil)
        }
        if let hostLink {
            updateRemoteBanner(state: hostLink.state)
        }
    }

    private var isShowingRemoteInstall: Bool {
        (persistentView?.superview as? TerminalSessionContainerView)?.topBanner is RemoteInstallBanner
    }

    /// After Not Now, the pane tells that no session started.
    @MainActor
    private func showRemoteInstallDeclined() {
        persistentView?.showBanner(
            "Helper not installed. The session was not started.", actionTitle: "Retry",
            action: { [weak self] in
                self?.reconnectPersistentSession()
            }, secondaryActionTitle: "Close",
            secondaryAction: { [weak self] in
                self?.closePaneOrWindow()
            }
        )
    }

    @MainActor
    private func updateRemoteBanner(state: HostLinkState) {
        guard
            let view = persistentView, let destination = remoteDestination, !remoteSessionEnded,
            view.session.state.exitStatus == nil
        else {
            return
        }
        if case .connected = state {
            if remoteOpenFailed {
                return
            }
            view.remoteInputEnabled = !remoteOpening && view.session.state.connected
        } else {
            view.remoteInputEnabled = false
        }
        if isShowingRemoteInstall {
            // The question above the terminal tells what happens.
            view.hideBanner()
        } else if remoteInstallDeclined, case .failed = state {
            showRemoteInstallDeclined()
        } else if let remoteNotice {
            view.showBanner(remoteNotice, actionTitle: "Cancel") { [weak self] in
                self?.closePaneOrWindow()
            }
        } else if let content = RemoteBannerContent.make(state: state, destination: destination) {
            view.showBanner(
                content.text, actionTitle: content.primary?.title,
                action: content.primary.map { button in
                    { [weak self] in
                        self?.performRemoteAction(button.action)
                    }
                },
                secondaryActionTitle: content.secondary?.title,
                secondaryAction: content.secondary.map { button in
                    { [weak self] in
                        self?.performRemoteAction(button.action)
                    }
                }
            )
        } else {
            view.hideBanner()
        }
    }

    @MainActor
    func refreshRemoteConnectionDisplay() {
        if let hostLink, remoteDestination != nil {
            updateRemoteBanner(state: hostLink.state)
        }
    }

    @MainActor
    private func performRemoteAction(_ action: RemoteBannerAction) {
        switch action {
        case .close:
            closePaneOrWindow()
        case .reconnect, .signIn, .retry:
            reconnectPersistentSession()
        }
    }

    @MainActor
    private func showRemoteError(_ error: Error) {
        remoteOpenFailed = true
        persistentView?.remoteInputEnabled = false
        if remoteInstallDeclined {
            showRemoteInstallDeclined()
            return
        }
        persistentView?.showBanner(
            (error as? SSHError)?.message ?? String(describing: error), actionTitle: "Retry",
            action: { [weak self] in
                self?.reconnectPersistentSession()
            }, secondaryActionTitle: "Close",
            secondaryAction: { [weak self] in
                self?.closePaneOrWindow()
            }
        )
    }

    func makeRemoteSession(socket: Int32) -> RemoteSession {
        // The first snapshot of a new attachment includes output already seen on the old connection.
        remoteOutputSerial = nil
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let session = RemoteSession(
            socket: socket, clientName: "Tecolot", build: version, clientInstance: clientInstance
        )
        session.onEvent = { [weak self, weak session] event in
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, self.persistentView?.session === session else {
                    return
                }
                self.handlePersistentEvent(event)
            }
        }
        return session
    }

    /// Connects again to the session after the connection dropped.
    @MainActor
    func reconnectPersistentSession() {
        if remoteDestination != nil {
            remoteInstallDeclined = false
            guard let hostLink else {
                connectRemoteHost()
                return
            }
            if case .connected = hostLink.state {
                openRemotePane(link: hostLink, sessionID: persistentSessionID)
            } else {
                hostLink.reconnectNow()
            }
            return
        }
        guard let persistentView, let sessionID = persistentSessionID else {
            return
        }
        do {
            let socket = try PersistentSessions.directory().connect(sessionID)
            let session = makeRemoteSession(socket: socket)
            persistentView.replaceSession(session)
            session.start(
                size: persistentView.wireGridSize, focused: persistentView.hasFocus,
                scale: persistentView.displayScale, screenChecksumReports: profile.screenChecksumReports,
                framesEnabled: framesVisible != false
            )
            applyPersistentAppearance(to: persistentView, colorsOnly: true)
        } catch {
            persistentView.showBanner("The session is no longer running.", actionTitle: "Close") { [weak self] in
                self?.closePaneOrWindow()
            }
        }
    }

    @MainActor
    func attachPersistentView() {
        guard let persistentView else {
            return
        }
        registerWindowIfAvailable()
        if !isConfigured {
            isConfigured = true
            // The same renderer settings as local panes (configureTerminal).
            persistentView.metalBufferingMode = .perFrameAggregated
            setUseMetalRenderer(UserDefaults.standard.object(forKey: TerminalSessionController.useMetalRendererKey) as? Bool ?? TerminalSessionController.useMetalRendererDefault)
                applyAppearance()
            persistentView.shouldSendCommandKeyToTerminal = { [weak persistentView] event in
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                guard
                    modifiers == [.command],
                    event.charactersIgnoringModifiers?.lowercased() == "c"
                else {
                    return false
                }
                return persistentView?.selectionActive == false
            }
            if zoomGesture == nil {
                let gesture = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
                persistentView.addGestureRecognizer(gesture)
                zoomGesture = gesture
            }
            if keyEventMonitor == nil {
                keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handleKeyBinding(event) == true ? nil : event
                }
            }
        }
        scheduleFocusIfNeeded()
    }

    @MainActor
    /// `colorsOnly` keeps the font and the keyboard settings, for example
    /// the Option-as-Meta choice of the Terminal menu.
    func applyPersistentAppearance(to view: RemoteTerminalView, colorsOnly: Bool = false) {
        let theme = effectiveTheme
        if theme.isValid {
            let ansi = theme.ansi.map(\.terminalColor)
            // The view applies the default colors that a program set, reverse
            // video, and the opacity over these.
            view.setThemeColors(
                foreground: theme.foreground.terminalColor,
                background: theme.background.terminalColor,
                cursor: ProfileApplier.nativeColor(theme.effectiveCursor),
                opacity: CGFloat(effectiveBackgroundOpacity)
            )
            view.caretTextColor = ProfileApplier.nativeColor(theme.effectiveCursorText)
            var selection = theme.foreground
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                selection = theme.effectiveSelectionBackground
            }
            view.selectedTextBackgroundColor = ProfileApplier.nativeColor(selection)
            view.selectedTextForegroundColor = ProfileApplier.nativeColor(theme.effectiveSelectionText)
            view.source.theme = (ansi, theme.foreground.terminalColor, theme.background.terminalColor)
            let rgb: (SwiftTerm.Color) -> WireRGB = { color in
                WireRGB(red: color.red, green: color.green, blue: color.blue)
            }
            // The helper answers color queries (OSC 4/10/11) from this theme.
            view.session.setTheme(
                SetThemeMessage(
                    palette: ansi.map(rgb),
                    foreground: rgb(theme.foreground.terminalColor),
                    background: rgb(theme.background.terminalColor),
                    cursor: theme.cursor.map {
                        rgb($0.terminalColor)
                    }
                )
            )
        }
        if !colorsOnly {
            let font = ProfileApplier.font(for: profile)
            view.font = persistentFontSize.map {
                Self.font(font, size: $0)
            } ?? font
            view.fontSmoothing = profile.fontSmoothing
            view.useBrightColors = profile.useBrightColorsForBold
            view.optionAsMetaKey = profile.optionAsMetaKey
            view.backspaceSendsControlH = profile.backspaceSendsControlH
            view.allowsOsc8Links = profile.linkOsc8
        }
        (view.superview as? TerminalSessionContainerView)?.updatePaddingColor()
        view.requestRedraw()
        updateWindowTransparency()
        workspace?.hostView?.refreshAppearance()
    }

    @MainActor
    func handlePersistentEvent(_ event: RemoteSessionEvent) {
        switch event {
        case .title(let title):
            postedTitle = title
            scheduleTerminalTitleUpdate()
        case .iconTitle:
            break
        case .directory(let directory):
            postedDirectory = directory.isEmpty ? nil : directory
            noteDirectoryReport(postedDirectory)
            updateWindowTitle()
        case .bell:
            noteBell()
        case .clipboardCopy(let data):
            // OSC 52 writes, as the local view does by default.
            if let text = String(data: Data(data), encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case .clipboardReadRequest(let request, _):
            // Programs cannot read the clipboard, as with the local view.
            persistentView?.session.replyClipboard(request: request, data: nil)
        case .exited(let code):
            if remoteDestination != nil {
                remoteSessionEnded = true
                persistentView?.remoteInputEnabled = false
            }
            processTerminated(source: nil, exitCode: code)
        case .info(let info):
            persistentShellPID = info.shellPID
            updatePaneExecutablePath(info.foreground?.path)
        case .programStatus(let snapshot):
            if let previous = remoteOutputSerial, previous != snapshot.outputSerial {
                noteOutputActivity()
            }
            remoteOutputSerial = snapshot.outputSerial
            programStatus.receive(snapshot)
        case .progress(let progress):
            if persistentView?.session.state.helperCapabilities.contains(.programStatus) != true {
                programStatus.receiveProgress(progress)
            }
            let state = Terminal.ProgressReportState(rawValue: Int(progress.state)) ?? .remove
            // A report that came before this pane attached shows for the
            // time that is left.
            persistentView?.showProgress(
                Terminal.ProgressReport(state: state, progress: progress.progress),
                duration: 15 - Double(progress.age) / 1000
            )
        case .notification(let title, let body):
            TerminalNotifier.shared.notify(title: title, body: body, from: self)
        case .closed:
            guard
                !persistentDetached, let persistentView,
                persistentView.session.state.exitStatus == nil
            else {
                return
            }
            if remoteDestination != nil {
                guard let hostLink else {
                    return
                }
                updateRemoteBanner(state: hostLink.state)
                // A link drop reaches the pane before the link state changes;
                // the reconnect then reopens the pane. When the link stays up,
                // the session closed only this connection: reopen it once.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard
                        let self, let link = self.hostLink, !self.persistentDetached,
                        !self.remoteSessionEnded, !self.remoteOpening,
                        self.persistentView?.session.state.connected == false,
                        case .connected(_, let current) = link.state,
                        current == self.remoteGeneration
                    else {
                        return
                    }
                    if self.remoteReopenedGeneration == current {
                        self.showRemoteError(SSHError(kind: .other, message: "Disconnected from the session."))
                    } else {
                        self.remoteReopenedGeneration = current
                        self.openRemotePane(link: link, sessionID: self.persistentSessionID)
                    }
                }
                return
            }
            let alive =
                persistentSessionID.map { id in
                    PersistentSessions.list().contains {
                        $0.id == id && !$0.exited
                    }
                } ?? false
            if alive {
                persistentView.showBanner("Disconnected from the session.", actionTitle: "Reconnect") { [weak self] in
                    self?.reconnectPersistentSession()
                }
            } else {
                persistentView.showBanner("The session helper stopped.", actionTitle: "Close") { [weak self] in
                    self?.closePaneOrWindow()
                }
            }
        case .error(let error):
            // A helper from an older version cannot turn off DECRQCRA, so
            // programs in the session can still read the screen.
            if
                error.failedKind == .setScreenChecksumReports, error.code == .unsupported,
                !profile.screenChecksumReports {
                persistentView?.showBanner(
                    "This session's helper is older and still lets programs read the screen contents. "
                        + "Start a new session to apply the setting."
                )
            }
        }
    }
}

final class TerminalSessionContainerView: NSView {
    static func contentSize(forTerminalSize terminalSize: NSSize, padding: CGFloat, top: CGFloat) -> NSSize {
        NSSize(
            width: terminalSize.width + padding * 2,
            height: terminalSize.height + top + padding
        )
    }

    let terminal: NSView & TerminalSurface
    private let topPaddingView = NSView()
    private let leftPaddingView = NSView()
    private let rightPaddingView = NSView()
    private let bottomPaddingView = NSView()
    private let resizeFeedbackView = TerminalResizeFeedbackView()
    private var resizeObservers = [NSObjectProtocol]()
    private var isShowingResizeFeedback = false
    private var paddingConstraints: [NSLayoutConstraint] = []
    private var terminalTopConstraint: NSLayoutConstraint!
    private var topBannerConstraints: [NSLayoutConstraint] = []
    /// A bar above the terminal, for example the question before a helper
    /// install. The terminal moves down below it.
    private(set) var topBanner: NSView?
    /// The space on the left, right and bottom sides of the terminal.
    private(set) var padding: CGFloat
    /// The space above the terminal.
    private(set) var topPadding: CGFloat

    init(terminal: NSView & TerminalSurface, padding: CGFloat = 2, top: CGFloat = 2) {
        self.terminal = terminal
        self.padding = padding
        topPadding = top
        super.init(frame: NSRect(x: 0, y: 0, width: padding * 2, height: top + padding))

        terminal.translatesAutoresizingMaskIntoConstraints = false
        let paddingViews = [topPaddingView, leftPaddingView, rightPaddingView, bottomPaddingView]
        for view in paddingViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.wantsLayer = true
            addSubview(view)
        }

        addSubview(terminal)
        resizeFeedbackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resizeFeedbackView)
        paddingConstraints = [
            topPaddingView.heightAnchor.constraint(equalToConstant: top),
            leftPaddingView.widthAnchor.constraint(equalToConstant: padding),
            rightPaddingView.widthAnchor.constraint(equalToConstant: padding),
            bottomPaddingView.heightAnchor.constraint(equalToConstant: padding),
        ]
        terminalTopConstraint = terminal.topAnchor.constraint(equalTo: topPaddingView.bottomAnchor)
        NSLayoutConstraint.activate([
            terminalTopConstraint,
            terminal.leadingAnchor.constraint(equalTo: leftPaddingView.trailingAnchor),
            terminal.trailingAnchor.constraint(equalTo: rightPaddingView.leadingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomPaddingView.topAnchor),

            topPaddingView.topAnchor.constraint(equalTo: topAnchor),
            topPaddingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            topPaddingView.trailingAnchor.constraint(equalTo: trailingAnchor),

            leftPaddingView.topAnchor.constraint(equalTo: topPaddingView.bottomAnchor),
            leftPaddingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftPaddingView.bottomAnchor.constraint(equalTo: bottomPaddingView.topAnchor),

            rightPaddingView.topAnchor.constraint(equalTo: topPaddingView.bottomAnchor),
            rightPaddingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightPaddingView.bottomAnchor.constraint(equalTo: bottomPaddingView.topAnchor),

            bottomPaddingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomPaddingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomPaddingView.bottomAnchor.constraint(equalTo: bottomAnchor),

            resizeFeedbackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            resizeFeedbackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        NSLayoutConstraint.activate(paddingConstraints)
        updatePaddingColor()
    }

    deinit {
        resizeObservers.forEach(NotificationCenter.default.removeObserver)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        var size = terminal.intrinsicContentSize
        if size.width >= 0 {
            size.width += padding * 2
        }
        if size.height >= 0 {
            size.height += topPadding + padding
        }
        return size
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        resizeObservers.forEach(NotificationCenter.default.removeObserver)
        resizeObservers.removeAll()

        guard let newWindow else {
            return
        }
        observeLiveResize(of: newWindow)
    }

    override func layout() {
        super.layout()
        guard isShowingResizeFeedback else {
            return
        }
        updateResizeFeedback()
    }

    func setTopBanner(_ banner: NSView?) {
        guard banner !== topBanner else {
            return
        }
        NSLayoutConstraint.deactivate(topBannerConstraints)
        topBannerConstraints.removeAll()
        topBanner?.removeFromSuperview()
        topBanner = banner
        guard let banner else {
            terminalTopConstraint.isActive = true
            needsLayout = true
            return
        }
        terminalTopConstraint.isActive = false
        banner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(banner)
        topBannerConstraints = [
            banner.topAnchor.constraint(equalTo: topPaddingView.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: banner.bottomAnchor),
        ]
        NSLayoutConstraint.activate(topBannerConstraints)
        needsLayout = true
    }

    func updatePaddingColor() {
        let color = terminal.nativeBackgroundColor.cgColor
        topPaddingView.layer?.backgroundColor = color
        leftPaddingView.layer?.backgroundColor = color
        rightPaddingView.layer?.backgroundColor = color
        bottomPaddingView.layer?.backgroundColor = color
    }

    func setPadding(_ padding: CGFloat, top: CGFloat) {
        guard self.padding != padding || topPadding != top else {
            return
        }
        self.padding = padding
        topPadding = top
        for constraint in paddingConstraints {
            constraint.constant = constraint.firstItem === topPaddingView ? top : padding
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func observeLiveResize(of window: NSWindow) {
        let center = NotificationCenter.default
        resizeObservers = [
            center.addObserver(
                forName: NSWindow.willStartLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.beginResizeFeedback()
            },
            center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.updateResizeFeedback()
            },
            center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.hideResizeFeedback()
            },
        ]
    }

    private func beginResizeFeedback() {
        isShowingResizeFeedback = true
        updateResizeFeedback()
    }

    private func updateResizeFeedback() {
        guard isShowingResizeFeedback else {
            return
        }
        terminal.layoutSubtreeIfNeeded()
        let dimensions = terminal.gridDimensions
        resizeFeedbackView.show(columns: dimensions.cols, rows: dimensions.rows)
    }

    private func hideResizeFeedback() {
        isShowingResizeFeedback = false
        resizeFeedbackView.isHidden = true
    }
}

private final class TerminalResizeFeedbackView: NSVisualEffectView {
    private let dimensionsLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        isHidden = true

        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        dimensionsLabel.textColor = .labelColor
        dimensionsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dimensionsLabel)
        NSLayoutConstraint.activate([
            dimensionsLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dimensionsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            dimensionsLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            dimensionsLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(columns: Int, rows: Int) {
        dimensionsLabel.stringValue = "\(columns) x \(rows)"
        isHidden = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct TerminalSessionView: NSViewRepresentable {
    var controller: TerminalSessionController

    func makeNSView(context: Context) -> TerminalSessionContainerView {
        let padding = GlobalAppearanceSettings.storedTerminalPadding
        return TerminalSessionContainerView(
            terminal: controller.makeTerminalView(),
            padding: padding.points,
            top: padding.topPoints(cardsEnabled: false)
        )
    }

    func updateNSView(_ nsView: TerminalSessionContainerView, context: Context) {
        if let local = nsView.terminal as? LocalProcessTerminalView {
            controller.attach(to: local)
        }
        nsView.updatePaddingColor()
    }

    static func dismantleNSView(_ nsView: TerminalSessionContainerView, coordinator: ()) {
        guard
            let controller = (nsView.terminal as? AppTerminalView)?.sessionController
            ?? (nsView.terminal as? RemoteTerminalView)?.sessionController,
            let window = nsView.window
        else {
            return
        }
        TerminalSessionRegistry.shared.unregister(controller: controller, from: window)
    }
}

#Preview("Terminal Session"){
    @Previewable @State var controller = TerminalSessionController(startsProcess: false)

    TerminalSessionView(
        controller: controller
    )
    .frame(width: 720, height: 420)
}

@MainActor
final class TerminalSessionRegistry {
    static let shared = TerminalSessionRegistry()
    private struct Key: Hashable {
        let groupID: UUID
        let tabID: UUID
    }
    private struct Entry {
        weak var group: TerminalTabGroup?
        weak var tab: TerminalTab?
    }
    private struct UnownedPane {
        weak var controller: TerminalSessionController?
    }
    private var entries: [Key: Entry] = [:]
    // Standalone pane hosts (previews and tests) have no group yet.
    private var unownedPanes: [UUID: UnownedPane] = [:]

    private weak var windowManager: TerminalWindowManager?

    func synchronize(groups: [TerminalTabGroup], manager: TerminalWindowManager) {
        windowManager = manager
        for group in groups {
            for tab in group.tabs {
                entries[Key(groupID: group.id, tabID: tab.id)] = Entry(group: group, tab: tab)
            }
        }
        let keys = Set(groups.flatMap { group in
            group.tabs.map {
                Key(groupID: group.id, tabID: $0.id)
            }
        })
        entries = entries.filter {
            keys.contains($0.key)
        }
    }

    func register(controller: TerminalSessionController, workspace: TerminalPaneWorkspace?, for window: NSWindow) {
        unownedPanes = unownedPanes.filter {
            $0.value.controller != nil
        }
        if
            !entries.values.contains(where: {
                $0.tab?.loadedWorkspace?.contains(controller) == true
            }) {
            unownedPanes[controller.id] = UnownedPane(controller: controller)
        }
    }

    func unregister(controller: TerminalSessionController, from window: NSWindow? = nil) {
        unownedPanes.removeValue(forKey: controller.id)
    }

    func controllers(in group: TerminalTabGroup) -> [TerminalSessionController] {
        group.tabs.filter {
            entries[Key(groupID: group.id, tabID: $0.id)]?.tab === $0
        }
        .flatMap {
            $0.loadedWorkspace?.controllers ?? []
        }
    }

    var allControllers: [TerminalSessionController] {
        var ids = Set<UUID>()
        return
            (entries.values.filter {
                $0.group != nil
            }.compactMap(\.tab).flatMap {
                $0.loadedWorkspace?.controllers ?? []
            }
                + unownedPanes.values.compactMap(\.controller)).filter {
                ids.insert($0.id).inserted
            }
    }

    func controller(for window: NSWindow?) -> TerminalSessionController? {
        guard let window else {
            return nil
        }
        if let owner = window.windowController as? TerminalWindowController, owner.isManaged {
            return owner.group.selectedTab?.loadedWorkspace?.focusedController
        }
        let panes = controllers(for: window)
        return panes.first {
            $0.surface === window.firstResponder
        }
            ?? panes.first?.workspace?.focusedController ?? panes.first
    }

    func controllers(for window: NSWindow?) -> [TerminalSessionController] {
        guard let window else {
            return []
        }
        if let owner = window.windowController as? TerminalWindowController, owner.isManaged {
            return controllers(in: owner.group)
        }
        return allControllers.filter {
            $0.surface?.window === window
        }
    }

    func focus(controller: TerminalSessionController, for window: NSWindow) {
        controller.workspace?.markFocused(controller)
        NotificationCenter.default.post(name: .terminalFocusedPaneDidChange, object: window)
    }

    func setUseMetalRenderer(_ enabled: Bool) {
        for controller in allControllers {
            controller.setUseMetalRenderer(enabled)
        }
    }

    func previewBackgroundOpacity(_ opacity: Double?, forProfileID profileID: UUID) {
        for controller in allControllers where controller.profile.id == profileID {
            controller.previewBackgroundOpacity(opacity)
        }
    }

    func workspace(for window: NSWindow?) -> TerminalPaneWorkspace? {
        controller(for: window)?.workspace
    }

    /// The persistent sessions that panes of this app show on this host,
    /// including panes in background groups.
    func shownPersistentSessionIDs(destination: String? = nil) -> Set<String> {
        Set(allControllers.filter {
            $0.remoteDestination == destination
        }.compactMap(\.persistentSessionID))
    }

    /// The sessions that panes show, and the sessions that restored panes
    /// will use: a pane that waits for its window has not attached yet, and
    /// a pane whose session ended starts again from its saved state.
    /// Includes panes in background groups.
    func persistentSessionIDsInUse(destination: String? = nil) -> Set<String> {
        let live = allControllers.filter {
            $0.remoteDestination == destination
        }
        .flatMap(\.reservedPersistentSessionIDs)
        let dormant = entries.values.flatMap { entry in
            entry.tab?.savedSpec?.restoredTab?.tab.root.panes.filter {
                $0.kind != .local && $0.remoteDestination == destination
            }.compactMap(\.sessionID) ?? []
        }
        return Set(live + dormant)
    }

    /// Resolves an explicit Show/notification action, including a dormant owner.
    /// Loading its existing tab prevents a second attachment in a new tab.
    func controller(showingPersistentSession id: String, destination: String? = nil, loadDormant: Bool = true) -> TerminalSessionController? {
        if
            let controller = allControllers.first(where: {
                $0.reservedPersistentSessionIDs.contains(id) && $0.remoteDestination == destination
            }) {
            return controller
        }
        guard loadDormant else {
            return nil
        }
        for entry in entries.values {
            guard
                let tab = entry.tab, let group = entry.group,
                let pane = tab.savedSpec?.restoredTab?.tab.root.panes.first(where: {
                    $0.kind != .local && $0.sessionID == id && $0.remoteDestination == destination
                }) else {
                continue
            }
            windowManager?.navigate(to: group, tab: tab, in: windowManager?.controller(for: WindowOpener.frontTerminalWindow()))
            _ = tab.hostView
            tab.loadedWorkspace?.windowManager = windowManager
            return tab.loadedWorkspace?.controllers.first {
                $0.id == pane.id
            }
        }
        return nil
    }

}

extension Notification.Name {
    static let terminalFocusedPaneDidChange = Notification.Name("TerminalFocusedPaneDidChange")
}

@Observable
final class TerminalCommandState {
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    var controller: TerminalSessionController?
    var window: NSWindow?

    init() {
        startObserving()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func startObserving() {
        let center = NotificationCenter.default
        let update: () -> Void = { [weak self] in
            guard let self else {
                return
            }
            let target = TerminalWindowCommandTarget.resolve(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow)
            self.window = target?.window
            self.controller = TerminalSessionRegistry.shared.controller(for: target?.window)
        }

        for name in [
            Notification.Name.terminalFocusedPaneDidChange,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                update()
            })
        }
        update()
    }
}
