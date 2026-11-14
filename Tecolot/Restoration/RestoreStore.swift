//
//  RestoreStore.swift
//  Tecolot
//
//  Brings back the windows, tabs, splits, directories and text of the panes
//  when Tecolot starts again (spec-restoration.md).
//
//  Group layout is saved as it changes. Scrollback is copied only at quit.
//  Application Support/<bundle>/Restore/windows.json owns groups and their
//  window mapping; panes/<pane-id>.text and .cache hold quit-time text.
//  Terminal windows do not use AppKit state restoration.
//

import AppKit
import Foundation
import Observation
import SwiftTerm
import TecolotSessionClient
import TecolotSessionDirectory

nonisolated enum RestorePaneKind: String, Codable, Hashable, Sendable {
    /// A shell of the app. It ends when the app quits.
    case local
    /// A persistent session on this Mac.
    case persistent
    /// A persistent session on a remote host.
    case remote
}

nonisolated struct RestorePane: Codable, Hashable, Sendable {
    /// Names the scrollback file of the pane.
    var id: UUID
    var kind: RestorePaneKind
    var profileID: UUID?
    var themeOverride: String?
    var directory: PaneDirectory?
    var sessionID: String?
    var remoteDestination: String?
    var title: String?
    /// The full-screen program that showed the alternate screen at the save.
    var alternateScreenProgram: String?
}

/// A split tree, like TerminalPaneNode.
nonisolated indirect enum RestorePaneNode: Codable, Hashable, Sendable {
    case pane(RestorePane)
    /// `fraction` is the size of the first child over the available length.
    case split(TerminalPaneSplit, fraction: Double?, first: RestorePaneNode, second: RestorePaneNode)

    var panes: [RestorePane] {
        switch self {
        case .pane(let pane):
            return [pane]
        case .split(_, _, let first, let second):
            return first.panes + second.panes
        }
    }

    /// The tree without the panes that `keep` rejects, or nil when no pane is left.
    func filter(_ keep: (RestorePane) -> Bool) -> RestorePaneNode? {
        switch self {
        case .pane(let pane):
            return keep(pane) ? self : nil
        case .split(let orientation, let fraction, let first, let second):
            return Self.split(orientation, fraction: fraction, first.filter(keep), second.filter(keep))
        }
    }

    /// The tree with a new ID for each pane whose ID is in `seen`. Adds the IDs to `seen`.
    func uniquingPaneIDs(_ seen: inout Set<UUID>) -> RestorePaneNode {
        switch self {
        case .pane(var pane):
            if !seen.insert(pane.id).inserted {
                pane.id = UUID()
                seen.insert(pane.id)
            }
            return .pane(pane)
        case .split(let orientation, let fraction, let first, let second):
            let first = first.uniquingPaneIDs(&seen)
            return .split(orientation, fraction: fraction, first: first, second: second.uniquingPaneIDs(&seen))
        }
    }

    /// A split of the children that are left. A split with one child left becomes that child.
    static func split(
        _ orientation: TerminalPaneSplit,
        fraction: Double?,
        _ first: RestorePaneNode?,
        _ second: RestorePaneNode?
    ) -> RestorePaneNode? {
        switch (first, second) {
        case (let left?, let right?):
            return .split(orientation, fraction: fraction, first: left, second: right)
        case (let left?, nil):
            return left
        case (nil, let right?):
            return right
        case (nil, nil):
            return nil
        }
    }
}

nonisolated struct RestoreTab: Codable, Hashable, Sendable {
    var id = UUID()
    /// A user-supplied tab name.
    var name: String?
    var focusedPaneID: UUID?
    var zoomedPaneID: UUID?
    var root: RestorePaneNode
    /// Decoded for compatibility with old state; ignored when opening a tab.
    var fileURL: URL?
    /// True when its quit-time files were never consumed in the saved run.
    var wasDormant: Bool?
}

nonisolated struct RestoreGroup: Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var isNameCustom = false
    var isCollapsed = false
    var selectedTabIndex = 0
    var tabs: [RestoreTab]
    var lastShownAt: Date?
}

nonisolated struct RestoreWindow: Codable, Hashable, Sendable {
    var groupID: UUID
    var frame: String
    /// The name of the screen that showed the window.
    var screen: String?
    var isFullScreen = false
}

nonisolated struct RestoreState: Codable, Hashable, Sendable {
    var version = RestoreStateMigrator.version
    /// A different boot means that the Mac restarted.
    var bootID: String?
    var savedAt: Date
    var groups: [RestoreGroup] = []
    var windows: [RestoreWindow]
    var windowGroupsMigrated = false
    var cleanShutdown = false
    var launching = false
}

/// The shipped window-only schema, also used by the older layout importer.
nonisolated struct RestoreWindowV1: Codable {
    var frame: String
    var screen: String?
    var isFullScreen = false
    var selectedTabIndex: Int
    var tabs: [RestoreTab]
}

nonisolated struct RestoreStateMigrator: VersionedDocumentMigrator {
    static let version = 2
    let currentVersion = RestoreStateMigrator.version

    func sourceVersion(in data: Data) throws -> Int {
        try PersistenceVersionProbe.optionalVersion(in: data) ?? 0
    }

    nonisolated static func migrate(windows: [RestoreWindowV1], bootID: String?, savedAt: Date) -> RestoreState {
        var state = RestoreState(bootID: bootID, savedAt: savedAt, windows: [], cleanShutdown: true)
        let generator = GroupNameGenerator()
        for window in windows where !window.tabs.isEmpty {
            let group = RestoreGroup(
                name: generator.generate(existingNames: state.groups.map(\.name)),
                selectedTabIndex: window.selectedTabIndex,
                tabs: window.tabs,
                lastShownAt: savedAt
            )
            state.groups.append(group)
            state.windows.append(RestoreWindow(
                groupID: group.id,
                frame: window.frame,
                screen: window.screen,
                isFullScreen: window.isFullScreen
            ))
        }
        return state
    }

    nonisolated func decode(_ data: Data, from sourceVersion: Int) throws -> RestoreState {
        var state: RestoreState
        switch sourceVersion {
        case 1:
            struct V1: Decodable {
                var bootID: String?
                var savedAt: Date
                var windows: [RestoreWindowV1]
            }
            let old = try Self.decoder.decode(V1.self, from: data)
            state = Self.migrate(windows: old.windows, bootID: old.bootID, savedAt: old.savedAt)
        case 2:
            state = try Self.decoder.decode(RestoreState.self, from: data)
        default:
            throw VersionedPersistenceError.invalidDocument("Unsupported group-restoration schema.")
        }
        var seen = Set<UUID>()
        var groupIDs = Set<UUID>()
        var tabIDs = Set<UUID>()
        state.groups = state.groups.filter {
            !$0.tabs.isEmpty
        }.map { group in
            var group = group
            if !groupIDs.insert(group.id).inserted {
                group.id = UUID()
                groupIDs.insert(group.id)
            }
            for index in group.tabs.indices {
                if !tabIDs.insert(group.tabs[index].id).inserted {
                    group.tabs[index].id = UUID()
                    tabIDs.insert(group.tabs[index].id)
                }
                group.tabs[index].root = group.tabs[index].root.uniquingPaneIDs(&seen)
                group.tabs[index].fileURL = nil
            }
            group.selectedTabIndex = min(max(group.selectedTabIndex, 0), group.tabs.count - 1)
            return group
        }
        var shown = Set<UUID>()
        state.windows = state.windows.filter {
            groupIDs.contains($0.groupID) && shown.insert($0.groupID).inserted
        }
        return state
    }

    nonisolated func validate(_ state: RestoreState) throws {}

    nonisolated func encodeCurrent(_ state: RestoreState) throws -> Data {
        var state = state
        state.version = currentVersion
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The rows of a remote pane, for its cache file.
nonisolated struct RemoteRowCopy: Sendable {
    enum Rows: Sendable {
        /// The rows that the pane shows.
        case captured(RemoteRowSnapshot.Pending)
        /// The file from the last save, for a pane that did not attach.
        case saved(URL)
    }

    let paneID: UUID
    let rows: Rows
}

/// What one pane gets from the restore.
struct PaneRestoration {
    var pane: RestorePane
    var savedAt: Date
    /// The Mac restarted after the save.
    var macRestarted: Bool
    /// The scrollback file of a local pane; it can be missing.
    var textURL: URL?
    /// The helper of a persistent pane still runs: attach to it.
    var sessionRunning: Bool
    /// The saved rows of a remote pane; the file can be missing.
    var cacheURL: URL? = nil
    /// The pane's session ended, and the user restores it from the Sessions
    /// window: a remote pane starts a new session from the saved state at
    /// once, without trying to attach first.
    var restoresEndedSession = false
    var restoresScrollback = true
    var startsFresh = false

    var reason: RestoreSeparator.Reason {
        macRestarted ? .macRestarted : .appQuit
    }
}

/// A tab to rebuild, with what each of its panes gets.
struct RestoredTab {
    var tab: RestoreTab
    var panes: [UUID: PaneRestoration]
}

@MainActor
final class RestoreStore {
    /// The app's store. Tests never read or write the app's files.
    static let shared = RestoreStore(
        directory: RestoreStore.defaultDirectory,
        isEnabled: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    )

    /// The longest time that the save at quit can delay the quit.
    static let saveTimeLimit: TimeInterval = 3

    let directory: URL
    private let enabled: Bool
    let defaults: UserDefaults
    var isEnabled: Bool {
        enabled && !defaults.bool(forKey: Self.disableKey)
    }
    static let disableKey = "TecolotDisableGroupRestore"
    let manager: TerminalWindowManager
    let issueCenter: PersistenceIssueCenter
    private var pendingSave: DispatchWorkItem?
    private(set) var observationGeneration = 0
    private var isRestoring = false
    private var isTerminating = false
    private var launchInProgress = false
    private var startupTask: Task<Void, Never>?
    private let startupTimeout: TimeInterval
    private let startupReady: @MainActor (TerminalSessionController) -> Bool
    private var canWrite = true
    private let stateWriter: @Sendable (RestoreState, URL) throws -> Void
    var windowGroupsMigrated = false
    let startsProcesses: Bool
    private let debounceInterval: TimeInterval
    private var backupDirectory: URL {
        directory.deletingLastPathComponent().appendingPathComponent("Backups")
    }

    /// The panes' durable session states (local helpers write them).
    var sessionStates: DurableStateDirectory {
        sessionStatesOverride ?? Self.localSessionStates
    }
    private let sessionStatesOverride: DurableStateDirectory?
    private let runningSessions: @MainActor () -> Set<String>
    /// False until the startup restore ran. Before it, the open windows are
    /// not the saved layout, and a quit must not replace the saved files.
    private(set) var isReady = false
    private let queue = DispatchQueue(label: "tecolot.restore", qos: .userInitiated)

    init(
        directory: URL,
        isEnabled: Bool = true,
        sessionStates: DurableStateDirectory? = nil,
        runningSessions: @escaping @MainActor () -> Set<String> = {
            Set(PersistentSessions.list().filter {
                !$0.exited
            }.map(\.id))
        },
        manager: TerminalWindowManager? = nil,
        defaults: UserDefaults = .standard,
        issueCenter: PersistenceIssueCenter? = nil,
        debounceInterval: TimeInterval = 1,
        startsProcesses: Bool = true,
        startupTimeout: TimeInterval = 15,
        startupReady: @escaping @MainActor (TerminalSessionController) -> Bool = {
            $0.hasCompletedRestorationStartup
        },
        stateWriter: @escaping @Sendable (RestoreState, URL) throws -> Void = RestoreStore.writeLayout
    ) {
        self.directory = directory
        enabled = isEnabled
        self.defaults = defaults
        self.manager = manager ?? .shared
        self.issueCenter = issueCenter ?? AppModel.shared.issueCenter
        self.debounceInterval = debounceInterval
        self.startsProcesses = startsProcesses
        self.startupTimeout = startupTimeout
        self.startupReady = startupReady
        self.stateWriter = stateWriter
        sessionStatesOverride = sessionStates
        self.runningSessions = runningSessions
    }

    deinit {
        pendingSave?.cancel()
        startupTask?.cancel()
    }

    nonisolated static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot")
    }

    nonisolated static var defaultDirectory: URL {
        applicationSupport.appendingPathComponent("Restore", isDirectory: true)
    }

    /// Where local helpers save their sessions when the system ends them.
    /// TECOLOT_STATE_DIR replaces it, as TECOLOT_RUNTIME_DIR replaces the
    /// runtime directory (for tests).
    nonisolated static var localSessionStates: DurableStateDirectory {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TECOLOT_STATE_DIR"], !path.isEmpty {
            return DurableStateDirectory(url: URL(fileURLWithPath: path, isDirectory: true))
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            return DurableStateDirectory(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("tecolot-test-states-\(getpid())", isDirectory: true))
        }
        return DurableStateDirectory(url: applicationSupport.appendingPathComponent("Sessions", isDirectory: true))
    }

    nonisolated static var restoredRowsLimit: Int {
        min(max(UserDefaults.standard.object(forKey: "restoredRowsLimit") as? Int ?? 1_000, 0), 100_000)
    }

    var windowsURL: URL {
        directory.appendingPathComponent("windows.json")
    }
    var panesURL: URL {
        directory.appendingPathComponent("panes", isDirectory: true)
    }
    nonisolated static func textURL(in panes: URL, for id: UUID) -> URL {
        panes.appendingPathComponent("\(id.uuidString).text")
    }
    nonisolated static func cacheURL(in panes: URL, for id: UUID) -> URL {
        panes.appendingPathComponent("\(id.uuidString).cache")
    }

    /// The old layout store's file (persistent panes only).
    var legacyLayoutURL: URL {
        directory.deletingLastPathComponent().appendingPathComponent("persistent-layout.json")
    }

    // MARK: Saving

    /// Deletes the saved rows of a remote pane that attached. It runs on the
    /// queue of the save at quit, so that it cannot delete a newer file.
    func removeRows(at url: URL) {
        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A barrier for tests and callers that need the durable layout on disk.
    func waitForWrites() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    /// Coalesces layout changes on the main actor, then writes on the store queue.
    /// Closing a window flushes the background mapping immediately.
    func stateDidChange(immediately: Bool = false) {
        guard isEnabled, isReady, canWrite, !isRestoring, !isTerminating else {
            return
        }
        pendingSave?.cancel()
        if immediately {
            saveLayout()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.saveLayout()
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func saveLayout() {
        guard isEnabled, canWrite, !isTerminating else {
            return
        }
        pendingSave = nil
        let state = capture(limit: 0).0
        enqueue(state)
    }

    private func enqueue(_ state: RestoreState) {
        let url = windowsURL
        let directory = directory
        let stateWriter = stateWriter
        queue.async {
            do {
                try DurableStateDirectory.makePrivateDirectory(directory)
                try stateWriter(state, url)
            } catch {
                Self.reportWriteFailure(url, error: error)
            }
        }
    }

    /// Observes persisted model fields, including edits made while no window
    /// shows a group. PTY output and process polling do not schedule writes.
    private func observeState() {
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking {
            for group in manager.groups {
                _ = group.name
                _ = group.isNameCustom
                _ = group.isCollapsed
                _ = group.selection
                _ = group.lastShownAt
                for tab in group.tabs {
                    _ = tab.customName
                    if let workspace = tab.loadedWorkspace {
                        _ = workspace.revision
                        _ = workspace.focusedControllerID
                        _ = workspace.zoomedControllerID
                        for pane in workspace.controllers {
                            _ = pane.profile
                            _ = pane.themeOverride
                        }
                    }
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.observationGeneration else {
                    return
                }
                self.stateDidChange()
                self.observeState()
            }
        }
    }

    /// Scrollback is captured only at quit. All groups and their window mapping
    /// are saved regardless of macOS window preferences or the quit event.
    func saveForTermination(completion: @escaping @MainActor () -> Void) {
        guard isEnabled, isReady, canWrite else {
            completion()
            return
        }
        isTerminating = true
        startupTask?.cancel()
        startupTask = nil
        launchInProgress = false
        pendingSave?.cancel()
        pendingSave = nil
        var (state, texts, caches) = capture(limit: Self.restoredRowsLimit)
        state.cleanShutdown = true
        let directory = directory
        let windowsURL = windowsURL
        let panesURL = panesURL
        let done = DispatchGroup()
        done.enter()
        let stateWriter = stateWriter
        queue.async {
            Self.write(state, texts: texts, caches: caches, directory: directory, windowsURL: windowsURL, panesURL: panesURL, stateWriter: stateWriter)
            done.leave()
        }
        var finished = false
        let finish = {
            guard !finished else {
                return
            }
            finished = true
            completion()
        }
        done.notify(queue: .main) {
            MainActor.assumeIsolated {
                finish()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveTimeLimit) {
            MainActor.assumeIsolated {
                finish()
            }
        }
    }

    /// Captures every group in manager order, including tabs that have no
    /// workspace yet. Only windows carry frames; background groups do not.
    func capture(limit: Int, manager: TerminalWindowManager? = nil) -> (RestoreState, [ScrollbackSnapshot.Pending], [RemoteRowCopy]) {
        let manager = manager ?? self.manager
        var state = RestoreState(
            bootID: BootIdentifier.current(),
            savedAt: Date(),
            windows: [],
            windowGroupsMigrated: windowGroupsMigrated,
            launching: launchInProgress
        )
        var texts: [ScrollbackSnapshot.Pending] = []
        var caches: [RemoteRowCopy] = []
        for group in manager.groups {
            var tabs: [RestoreTab] = []
            var selected = 0
            for tab in group.tabs {
                guard let saved = Self.capture(tab, limit: limit, texts: &texts, caches: &caches) else {
                    continue
                }
                if tab.id == group.selection {
                    selected = tabs.count
                }
                tabs.append(saved)
            }
            guard !tabs.isEmpty else {
                continue
            }
            state.groups.append(RestoreGroup(
                id: group.id,
                name: group.name,
                isNameCustom: group.isNameCustom,
                isCollapsed: group.isCollapsed,
                selectedTabIndex: selected,
                tabs: tabs,
                lastShownAt: group.lastShownAt
            ))
        }
        let ids = Set(state.groups.map(\.id))
        state.windows = manager.shownWindows().compactMap { window, group in
            guard ids.contains(group.id) else {
                return nil
            }
            return RestoreWindow(
                groupID: group.id,
                frame: NSStringFromRect((window.windowController as? TerminalWindowController)?.restorationFrame ?? window.frame),
                screen: window.screen?.localizedName,
                isFullScreen: window.styleMask.contains(.fullScreen)
            )
        }
        return (state, texts, caches)
    }

    static func capture(
        _ tab: TerminalTab,
        limit: Int = 0,
        texts: inout [ScrollbackSnapshot.Pending],
        caches: inout [RemoteRowCopy]
    ) -> RestoreTab? {
        guard let workspace = tab.loadedWorkspace else {
            var saved = tab.savedSpec?.restoredTab?.tab
            saved?.name = tab.customName
            saved?.wasDormant = true
            return saved
        }
        guard let root = capture(workspace.root, hostView: workspace.hostView, limit: limit, texts: &texts, caches: &caches)
        else {
            return nil
        }
        let ids = Set(root.panes.map(\.id))
        return RestoreTab(
            id: tab.id,
            name: tab.customName,
            focusedPaneID: workspace.focusedController.map(\.id).flatMap {
                ids.contains($0) ? $0 : nil
            },
            zoomedPaneID: workspace.zoomedControllerID.flatMap {
                ids.contains($0) ? $0 : nil
            },
            root: root,
            wasDormant: false
        )
    }

    /// The tree of a tab. Leaves out the panes whose session ended.
    static func capture(
        _ node: TerminalPaneNode,
        hostView: TerminalPaneHostView?,
        limit: Int,
        texts: inout [ScrollbackSnapshot.Pending],
        caches: inout [RemoteRowCopy]
    ) -> RestorePaneNode? {
        switch node.content {
        case .terminal(let controller):
            guard let pane = controller.restorePane() else {
                return nil
            }
            switch pane.kind {
            case .local:
                if limit > 0, let text = controller.copyScrollback(limit: limit) {
                    texts.append(text)
                }
            case .remote:
                if limit > 0, let rows = controller.copyRemoteRows(limit: limit) {
                    caches.append(rows)
                }
            case .persistent:
                break
            }
            return .pane(pane)
        case .split(let orientation, let first, let second):
            let fraction = hostView?.dividerFraction(for: node.id).map(Double.init)
            return RestorePaneNode.split(
                orientation,
                fraction: fraction,
                capture(first, hostView: hostView, limit: limit, texts: &texts, caches: &caches),
                capture(second, hostView: hostView, limit: limit, texts: &texts, caches: &caches)
            )
        }
    }

    /// Writes the durable layout after any pane files have reached disk.
    nonisolated static func writeLayout(_ state: RestoreState, to url: URL) throws {
        try DurableStateDirectory.writePrivate(try RestoreStateMigrator().encodeCurrent(state), to: url)
    }

    nonisolated static func write(
        _ state: RestoreState,
        texts: [ScrollbackSnapshot.Pending],
        caches: [RemoteRowCopy] = [],
        directory: URL,
        windowsURL: URL,
        panesURL: URL,
        stateWriter: @Sendable (RestoreState, URL) throws -> Void = RestoreStore.writeLayout
    ) {
        do {
            // Preserve row files of panes that have not attached, before pruning.
            let savedRows = caches.reduce(into: [UUID: Data]()) { saved, cache in
                if case .saved(let url) = cache.rows {
                    saved[cache.paneID] = try? Data(contentsOf: url)
                }
            }
            try DurableStateDirectory.makePrivateDirectory(directory)
            // Dormant panes keep their unread quit-time files. Remove only
            // files belonging to panes that no longer exist.
            let kept = Set(state.groups.flatMap(\.tabs).flatMap(\.root.panes).flatMap {
                [textURL(in: panesURL, for: $0.id).lastPathComponent, cacheURL(in: panesURL, for: $0.id).lastPathComponent]
            })
            for name in (try? FileManager.default.contentsOfDirectory(atPath: panesURL.path)) ?? [] where !kept.contains(name) {
                try? FileManager.default.removeItem(at: panesURL.appendingPathComponent(name))
            }
            if !texts.isEmpty || !caches.isEmpty {
                try DurableStateDirectory.makePrivateDirectory(panesURL)
            }
            for text in texts {
                guard let data = text.encode(savedAt: state.savedAt) else {
                    continue
                }
                try DurableStateDirectory.writePrivate(data, to: textURL(in: panesURL, for: text.paneID))
            }
            for cache in caches {
                let data: Data
                switch cache.rows {
                case .captured(let rows):
                    data = rows.encode(savedAt: state.savedAt)
                case .saved:
                    guard let saved = savedRows[cache.paneID] else {
                        continue
                    }
                    data = saved
                }
                try DurableStateDirectory.writePrivate(data, to: cacheURL(in: panesURL, for: cache.paneID))
            }
            // The layout goes last: without it, a launch restores nothing.
            try stateWriter(state, windowsURL)
        } catch {
            reportWriteFailure(windowsURL, error: error)
        }
    }

    // MARK: Restoring

    func retryRestorationRecovery() {
        guard isEnabled else {
            return
        }
        guard var state = takeSavedState(), canWrite else {
            return
        }
        isReady = true
        isRestoring = true
        defer { isRestoring = false }
        let safeMode = state.launching
        let restoresText = state.cleanShutdown && !safeMode
        state.launching = true
        state.cleanShutdown = false
        guard writeLaunchState(state) else {
            return
        }
        _ = finishRestore(state, safeMode: safeMode, restoresText: restoresText)
    }

    /// Loads without consuming the workspace. Unknown newer or damaged files
    /// stay untouched and block writes until Data Recovery resolves the issue.
    func takeSavedState() -> RestoreState? {
        let result = VersionedFileLoader.load(
            from: windowsURL,
            domain: .windowRestoration,
            backupRoot: backupDirectory,
            migrator: RestoreStateMigrator()
        )
        if let issue = result.issue {
            canWrite = false
            issueCenter.report(issue)
            return nil
        }
        canWrite = true
        issueCenter.resolve(domain: .windowRestoration, sourceURL: windowsURL)
        if let state = result.value {
            return state
        }
        guard
            let data = try? Data(contentsOf: legacyLayoutURL),
            let old = try? JSONDecoder().decode(LegacyLayout.self, from: data) else {
            return nil
        }
        do {
            _ = try PersistenceBackups.createIfNeeded(
                for: legacyLayoutURL,
                domain: .windowRestoration,
                sourceVersion: 1,
                root: backupDirectory
            )
            let state = old.restoreState
            try DurableStateDirectory.makePrivateDirectory(directory)
            try DurableStateDirectory.writePrivate(try RestoreStateMigrator().encodeCurrent(state), to: windowsURL)
            try FileManager.default.removeItem(at: legacyLayoutURL)
            return state
        } catch {
            canWrite = false
            Self.reportWriteFailure(windowsURL, error: error)
            return nil
        }
    }

    /// Writes the launch guard before creating any workspace. The guard is
    /// cleared only after every group and window was restored successfully.
    func restore() -> Bool {
        isReady = true
        guard isEnabled else {
            return false
        }
        isRestoring = true
        defer { isRestoring = false }
        var state = takeSavedState() ?? RestoreState(bootID: nil, savedAt: Date(), windows: [])
        guard canWrite else {
            return false
        }
        let safeMode = state.launching
        let restoresText = state.cleanShutdown && !safeMode
        state.launching = true
        state.cleanShutdown = false
        // This synchronous queue barrier must finish before shells can start.
        guard writeLaunchState(state) else {
            return false
        }
        guard migrateWindowGroups(in: &state) else {
            // A failed legacy import does not prevent restoring existing groups.
            return finishRestore(state, safeMode: safeMode, restoresText: restoresText)
        }
        return finishRestore(state, safeMode: safeMode, restoresText: restoresText)
    }

    func writeLaunchState(_ state: RestoreState) -> Bool {
        do {
            let data = try RestoreStateMigrator().encodeCurrent(state)
            let directory = directory
            let url = windowsURL
            try queue.sync {
                try DurableStateDirectory.makePrivateDirectory(directory)
                try DurableStateDirectory.writePrivate(data, to: url)
            }
            return true
        } catch {
            canWrite = false
            Self.reportWriteFailure(windowsURL, error: error)
            return false
        }
    }

    private func finishRestore(_ state: RestoreState, safeMode: Bool, restoresText: Bool) -> Bool {
        windowGroupsMigrated = state.windowGroupsMigrated
        let currentBoot = BootIdentifier.current()
        let restarted = state.bootID != nil && currentBoot != nil && state.bootID != currentBoot
        let shown = TerminalSessionRegistry.shared.shownPersistentSessionIDs()
        let running = runningSessions()
        var referenced = Set<String>()
        for group in state.groups {
            for pane in group.tabs.flatMap({
                $0.root.panes
            }) where pane.kind == .persistent {
                if let id = pane.sessionID {
                    referenced.insert(id)
                }
            }
        }
        for group in manager.groups {
            for tab in group.tabs {
                let panes: [RestorePane]
                if let saved = tab.savedSpec?.restoredTab?.tab {
                    panes = saved.root.panes
                } else {
                    panes = tab.loadedWorkspace?.controllers.compactMap {
                        $0.restorePane()
                    } ?? []
                }
                for pane in panes where pane.kind == .persistent {
                    if let id = pane.sessionID {
                        referenced.insert(id)
                    }
                }
            }
        }
        _ = sessionStates.list(protecting: referenced.union(running).union(shown))
        var used = Set<UUID>()
        var recovered: [TerminalTabGroup] = []
        for saved in state.groups {
            guard
                let saved = Self.removingShownSessions(from: saved, shown: shown),
                !manager.groups.contains(where: {
                    $0.id == saved.id
                }) else {
                continue
            }
            let tabs = saved.tabs.map { tab in
                let keepsText = restoresText || (tab.wasDormant ?? !state.windows.contains {
                    $0.groupID == saved.id
                })
                let restored = RestoredTab(tab: tab, panes: Dictionary(uniqueKeysWithValues: tab.root.panes.map { pane in
                    if keepsText {
                        used.insert(pane.id)
                    }
                    return (pane.id, PaneRestoration(
                        pane: pane,
                        savedAt: state.savedAt,
                        macRestarted: restarted,
                        textURL: keepsText && pane.kind == .local ? Self.textURL(in: panesURL, for: pane.id) : nil,
                        sessionRunning: pane.sessionID.map(running.contains) ?? false,
                        cacheURL: keepsText && pane.kind == .remote ? Self.cacheURL(in: panesURL, for: pane.id) : nil,
                        restoresScrollback: keepsText
                    ))
                }))
                return TerminalTab(dormant: Self.launchSpec(for: restored), startsProcesses: startsProcesses)
            }
            let group = TerminalTabGroup(id: saved.id, name: saved.name, isNameCustom: saved.isNameCustom, tabs: tabs)
            group.isCollapsed = saved.isCollapsed
            group.selection = tabs[saved.selectedTabIndex].id
            group.lastShownAt = saved.lastShownAt
            manager.addRestoredGroup(group)
            recovered.append(group)
        }
        if safeMode {
            if
                let group = recovered.max(by: {
                    ($0.lastShownAt ?? .distantPast) < ($1.lastShownAt ?? .distantPast)
                }) {
                open(group, saved: state.windows.first, startsGroup: false)
            }
        } else {
            for window in state.windows {
                if
                    let group = recovered.first(where: {
                        $0.id == window.groupID
                    }) {
                    open(group, saved: window)
                }
            }
        }
        for group in manager.groups {
            for tab in group.tabs where tab.isDormant {
                let panes = tab.savedSpec?.restoredTab?.panes ?? [:]
                for pane in panes.values where pane.textURL != nil || pane.cacheURL != nil {
                    used.insert(pane.pane.id)
                }
            }
        }
        removeUnusedPaneFiles(keeping: used)
        manager.persistenceDidChange = { [weak self] immediate in
            self?.stateDidChange(immediately: immediate)
        }
        observeState()
        // Dormant background groups have no asynchronous startup to guard.
        let panes = recovered.flatMap(\.tabs).compactMap(\.loadedWorkspace).flatMap(\.controllers)
        startupTask?.cancel()
        launchInProgress = !panes.isEmpty
        _ = writeLaunchState(capture(limit: 0).0)
        if launchInProgress {
            let deadline = ContinuousClock.now + .seconds(startupTimeout)
            startupTask = Task { @MainActor [weak self] in
                // Always cross the async startup boundary, even in model tests.
                await Task.yield()
                while !Task.isCancelled {
                    guard self?.finishStartupIfReady(panes, deadline: deadline) == false else {
                        return
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        return
                    }
                }
            }
        }
        return !manager.windows.isEmpty
    }

    /// Called between suspensions so the task does not retain its store while waiting.
    private func finishStartupIfReady(_ panes: [TerminalSessionController], deadline: ContinuousClock.Instant) -> Bool {
        guard !isTerminating else {
            return true
        }
        guard panes.allSatisfy(startupReady) || ContinuousClock.now >= deadline else {
            return false
        }
        launchInProgress = false
        startupTask = nil
        stateDidChange(immediately: true)
        return true
    }

    /// Removes persistent sessions that were attached before launch restoration.
    static func removingShownSessions(from group: RestoreGroup, shown: Set<String>) -> RestoreGroup? {
        var group = group
        var kept: [RestoreTab] = []
        var selected = 0
        for (index, tab) in group.tabs.enumerated() {
            guard
                let root = tab.root.filter({ pane in
                    pane.kind != .persistent || !(pane.sessionID.map(shown.contains) ?? false)
                }) else {
                continue
            }
            if index <= group.selectedTabIndex {
                selected = kept.count
            }
            var tab = tab
            tab.root = root
            kept.append(tab)
        }
        guard !kept.isEmpty else {
            return nil
        }
        group.tabs = kept
        group.selectedTabIndex = selected
        return group
    }

    private func open(_ group: TerminalTabGroup, saved: RestoreWindow?, startsGroup: Bool = true) {
        let owner = manager.openWindow(
            group: group,
            startsGroup: startsGroup,
            initialFrame: saved.map {
                .windowGroup(NSRectFromString($0.frame))
            } ?? .saved
        )
        guard let controller = owner as? TerminalWindowController, let window = controller.window else {
            return
        }
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        if saved?.isFullScreen == true && startsGroup {
            DispatchQueue.main.async { [weak window] in
                window?.toggleFullScreen(nil)
            }
        }
    }

    private nonisolated static func reportWriteFailure(_ url: URL, error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            AppModel.shared.issueCenter.report(PersistenceIssue(
                domain: .windowRestoration,
                sourceURL: url,
                kind: .writeFailed,
                message: message
            ))
        }
    }

    static func launchSpec(for tab: RestoredTab) -> LaunchSpec {
        var spec = LaunchSpec()
        spec.profileID = tab.tab.root.panes.first?.profileID
        spec.restoredTab = tab
        spec.activate = false
        return spec
    }

    /// Deletes the files in `panes/` that no restored pane reads. The panes
    /// delete their own file after the replay.
    private func removeUnusedPaneFiles(keeping used: Set<UUID>) {
        let panesURL = panesURL
        let kept = Set(used.flatMap { [
            Self.textURL(in: panesURL, for: $0).lastPathComponent,
            Self.cacheURL(in: panesURL, for: $0).lastPathComponent
        ] })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: panesURL.path) else {
            return
        }
        for name in names where !kept.contains(name) {
            try? FileManager.default.removeItem(at: panesURL.appendingPathComponent(name))
        }
    }

    /// Reads and deletes the scrollback file of a local pane. Runs on a
    /// background task. A file that does not decode is deleted and reported.
    nonisolated static func takeText(at url: URL) -> (header: ScrollbackHeader, text: String)? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        do {
            return try ScrollbackFile.decode(data)
        } catch {
            reportInvalidFile(url, error: error, supportedVersion: ScrollbackHeader.currentVersion)
            return nil
        }
    }

    /// Reads the saved rows of a remote pane. Runs on a background task.
    /// The pane deletes the file when it attaches. A file that does not
    /// decode is deleted and reported.
    nonisolated static func readRows(at url: URL) -> RemoteRowSnapshot? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            return try RemoteRowSnapshot.decode(data)
        } catch {
            try? FileManager.default.removeItem(at: url)
            reportInvalidFile(url, error: error, supportedVersion: RemoteRowSnapshot.currentVersion)
            return nil
        }
    }

    /// Reports a pane file that does not decode. The caller deleted it.
    private nonisolated static func reportInvalidFile(_ url: URL, error: Error, supportedVersion: Int) {
        let message = "\(error)"
        Task { @MainActor in
            AppModel.shared.issueCenter.report(PersistenceIssue(
                domain: .windowRestoration, sourceURL: url, kind: .invalidFormat, message: message,
                supportedVersion: supportedVersion
            ))
        }
    }

    // MARK: Ended sessions

    /// A tab that starts a new persistent session from an ended one, with
    /// its directory and text (the Restore action of the Sessions window).
    /// `destination` is the host of a remote session; its bridge reads the
    /// saved state.
    static func launchSpec(restoring state: DurableSessionState, destination: String? = nil) -> LaunchSpec {
        let profileID = state.launch.labels["profileID"].flatMap(UUID.init(uuidString:))
        let pane = RestorePane(
            id: UUID(),
            kind: destination == nil ? .persistent : .remote,
            profileID: profileID,
            directory: state.directory,
            sessionID: state.id,
            remoteDestination: destination,
            title: state.title,
            alternateScreenProgram: state.alternateScreenProgram
        )
        let restoration = PaneRestoration(
            pane: pane,
            savedAt: state.savedAt,
            macRestarted: false,
            textURL: nil,
            sessionRunning: false,
            restoresEndedSession: true
        )
        return launchSpec(for: RestoredTab(
            tab: RestoreTab(focusedPaneID: pane.id, root: .pane(pane)),
            panes: [pane.id: restoration]
        ))
    }
}

// MARK: - The old layout store

/// `persistent-layout.json` of the layout store that this store replaces.
/// Read one time, then deleted.
private nonisolated struct LegacyLayout: Decodable {
    struct Pane: Decodable {
        var sessionID: String?
        var profileID: UUID?
        var themeOverride: String?
        var workingDirectory: String?
        var remoteDestination: String?
    }

    indirect enum Node: Decodable {
        case pane(Pane)
        case split(TerminalPaneSplit, fraction: Double?, first: Node, second: Node)

        var restoreNode: RestorePaneNode {
            switch self {
            case .pane(let pane):
                let kind: RestorePaneKind = pane.remoteDestination != nil ? .remote
                    : pane.sessionID != nil ? .persistent : .local
                return .pane(RestorePane(
                    id: UUID(),
                    kind: kind,
                    profileID: pane.profileID,
                    themeOverride: pane.themeOverride,
                    directory: pane.workingDirectory.map {
                        PaneDirectory(path: $0, source: .osc7)
                    },
                    sessionID: pane.sessionID,
                    remoteDestination: pane.remoteDestination
                ))
            case .split(let orientation, let fraction, let first, let second):
                return .split(orientation, fraction: fraction, first: first.restoreNode, second: second.restoreNode)
            }
        }
    }

    struct Tree: Decodable { var root: Node }

    struct Window: Decodable {
        var frame: String
        var tabs: [Tree]
        var selectedTabIndex: Int
    }

    var windows: [Window]

    var restoreState: RestoreState {
        RestoreStateMigrator.migrate(windows: windows.filter {
            !$0.tabs.isEmpty
        }.map { window in
            RestoreWindowV1(
                frame: window.frame,
                selectedTabIndex: min(max(window.selectedTabIndex, 0), window.tabs.count - 1),
                tabs: window.tabs.map {
                    RestoreTab(root: $0.root.restoreNode)
                }
            )
        }, bootID: nil, savedAt: Date())
    }
}
