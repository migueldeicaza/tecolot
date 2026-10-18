//
//  RestoreStore.swift
//  Tecolot
//
//  Brings back the windows, tabs, splits, directories and text of the panes
//  when Tecolot starts again (spec-restoration.md).
//
//  The store saves only when the app quits; it never saves while the user
//  works. A launch reads the files one time and deletes them at once:
//
//      ~/Library/Application Support/<bundle>/Restore/
//          windows.json            the layout (RestoreState)
//          panes/<pane-id>.text    the scrollback of a local pane
//
//  A persistent session keeps its own text: the helper saves it when the
//  system ends it (DurableSessionState, in Application Support/<bundle>/Sessions/).
//
//  Tecolot does not use AppKit state restoration for terminal windows, so
//  the system settings "Close windows when quitting an application" and
//  "Reopen windows when logging back in" do not apply.
//

import AppKit
import Foundation
import SwiftTerm
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
        case .pane(let pane): return [pane]
        case .split(_, _, let first, let second): return first.panes + second.panes
        }
    }

    /// The tree without the panes that `keep` rejects, or nil when no pane is left.
    func filter(_ keep: (RestorePane) -> Bool) -> RestorePaneNode? {
        switch self {
        case .pane(let pane): return keep(pane) ? self : nil
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
    static func split(_ orientation: TerminalPaneSplit, fraction: Double?,
                      _ first: RestorePaneNode?, _ second: RestorePaneNode?) -> RestorePaneNode? {
        switch (first, second) {
        case (let left?, let right?): return .split(orientation, fraction: fraction, first: left, second: right)
        case (let left?, nil): return left
        case (nil, let right?): return right
        case (nil, nil): return nil
        }
    }
}

nonisolated struct RestoreTab: Codable, Hashable, Sendable {
    var id = UUID()
    /// The tab name (spec-titlebar-tabs.md). Nil until tabs have names.
    var name: String?
    var focusedPaneID: UUID?
    var zoomedPaneID: UUID?
    var root: RestorePaneNode
}

nonisolated struct RestoreWindow: Codable, Hashable, Sendable {
    var frame: String
    /// The name of the screen that showed the window.
    var screen: String?
    var isFullScreen = false
    var selectedTabIndex: Int
    var tabs: [RestoreTab]
}

nonisolated struct RestoreState: Codable, Hashable, Sendable {
    var version = RestoreStateMigrator.version
    /// The boot of the Mac at the save. A different boot at the next launch
    /// means that the Mac restarted.
    var bootID: String?
    var savedAt: Date
    var windows: [RestoreWindow]
}

nonisolated struct RestoreStateMigrator: VersionedDocumentMigrator {
    static let version = 1
    let currentVersion = RestoreStateMigrator.version

    func sourceVersion(in data: Data) throws -> Int {
        try PersistenceVersionProbe.optionalVersion(in: data) ?? 0
    }

    func decode(_ data: Data, from sourceVersion: Int) throws -> RestoreState {
        guard sourceVersion == 1 else {
            throw VersionedPersistenceError.invalidDocument("Unsupported window-restoration schema.")
        }
        var state = try Self.decoder.decode(RestoreState.self, from: data)
        // A file that was changed by hand can repeat a pane ID.
        var seen = Set<UUID>()
        state.windows = state.windows.filter { !$0.tabs.isEmpty }.map { window in
            var window = window
            for index in window.tabs.indices {
                window.tabs[index].root = window.tabs[index].root.uniquingPaneIDs(&seen)
            }
            window.selectedTabIndex = min(max(window.selectedTabIndex, 0), window.tabs.count - 1)
            return window
        }
        return state
    }

    func validate(_ state: RestoreState) throws {}

    func encodeCurrent(_ state: RestoreState) throws -> Data {
        var state = state
        state.version = currentVersion
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
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

    var reason: RestoreSeparator.Reason { macRestarted ? .macRestarted : .appQuit }
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
        isEnabled: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil)

    /// The longest time that the save at quit can delay the quit.
    static let saveTimeLimit: TimeInterval = 3

    let directory: URL
    let isEnabled: Bool
    /// The panes' durable session states (local helpers write them).
    var sessionStates: DurableStateDirectory { sessionStatesOverride ?? Self.localSessionStates }
    private let sessionStatesOverride: DurableStateDirectory?
    /// False until the startup restore ran. Before it, the open windows are
    /// not the saved layout, and a quit must not replace the saved files.
    private(set) var isReady = false
    private let queue = DispatchQueue(label: "tecolot.restore", qos: .userInitiated)

    init(directory: URL, isEnabled: Bool = true, sessionStates: DurableStateDirectory? = nil) {
        self.directory = directory
        self.isEnabled = isEnabled
        sessionStatesOverride = sessionStates
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

    var windowsURL: URL { directory.appendingPathComponent("windows.json") }
    var panesURL: URL { directory.appendingPathComponent("panes", isDirectory: true) }
    nonisolated static func textURL(in panes: URL, for id: UUID) -> URL {
        panes.appendingPathComponent("\(id.uuidString).text")
    }

    /// The old layout store's file (persistent panes only).
    var legacyLayoutURL: URL {
        directory.deletingLastPathComponent().appendingPathComponent("persistent-layout.json")
    }

    // MARK: Saving

    /// Saves all windows: the layout on the main thread, the scrollback
    /// copies in one terminal lock transaction for each pane. The files are
    /// encoded and written on a background queue; `completion` runs on the
    /// main thread when they are written, or after `saveTimeLimit`.
    func saveForTermination(completion: @escaping @MainActor () -> Void) {
        guard isEnabled, isReady else { completion(); return }
        let (state, texts) = capture(limit: Self.restoredRowsLimit)
        let directory = directory
        let windowsURL = windowsURL
        let panesURL = panesURL
        let done = DispatchGroup()
        done.enter()
        queue.async {
            Self.write(state, texts: texts, directory: directory, windowsURL: windowsURL, panesURL: panesURL)
            done.leave()
        }
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            completion()
        }
        done.notify(queue: .main) { MainActor.assumeIsolated { finish() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveTimeLimit) { MainActor.assumeIsolated { finish() } }
    }

    /// A window of a saved terminal-session file. AppKit restores it as a
    /// document; this store leaves it out.
    static func isFileDocumentWindow(_ window: NSWindow) -> Bool {
        NSDocumentController.shared.document(for: window)?.fileURL != nil
    }

    /// The layout of the open windows, and the text of their local panes.
    /// Leaves out the windows of saved documents.
    func capture(limit: Int) -> (RestoreState, [ScrollbackSnapshot.Pending]) {
        var state = RestoreState(bootID: BootIdentifier.current(), savedAt: Date(), windows: [])
        var texts: [ScrollbackSnapshot.Pending] = []
        var visitedTabGroups = Set<ObjectIdentifier>()
        let registry = TerminalSessionRegistry.shared
        let isTerminalWindow = { (window: NSWindow) -> Bool in
            guard registry.workspace(for: window) != nil else { return false }
            // A document can get its file after the window registered (Save As).
            let isDocument = Self.isFileDocumentWindow(window)
            window.isRestorable = isDocument
            return !isDocument
        }
        // Back to front: the restore opens them in this order.
        for window in NSApp.orderedWindows.reversed() + NSApp.windows where isTerminalWindow(window) {
            let tabWindows: [NSWindow]
            let selectedWindow: NSWindow
            if let tabGroup = window.tabGroup {
                guard visitedTabGroups.insert(ObjectIdentifier(tabGroup)).inserted else { continue }
                tabWindows = tabGroup.windows.filter(isTerminalWindow)
                selectedWindow = tabGroup.selectedWindow.flatMap { tabWindows.contains($0) ? $0 : nil } ?? window
            } else {
                guard visitedTabGroups.insert(ObjectIdentifier(window)).inserted else { continue }
                tabWindows = [window]
                selectedWindow = window
            }
            var tabs: [RestoreTab] = []
            var selected = 0
            for tabWindow in tabWindows {
                guard let workspace = registry.workspace(for: tabWindow),
                      let root = Self.capture(workspace.root, hostView: workspace.hostView, limit: limit, texts: &texts)
                else { continue }
                let ids = Set(root.panes.map(\.id))
                if tabWindow === selectedWindow { selected = tabs.count }
                tabs.append(RestoreTab(focusedPaneID: workspace.focusedController.map(\.id).flatMap { ids.contains($0) ? $0 : nil },
                                       zoomedPaneID: workspace.zoomedControllerID.flatMap { ids.contains($0) ? $0 : nil },
                                       root: root))
            }
            guard !tabs.isEmpty else { continue }
            state.windows.append(RestoreWindow(frame: NSStringFromRect(selectedWindow.frame),
                                               screen: selectedWindow.screen?.localizedName,
                                               isFullScreen: selectedWindow.styleMask.contains(.fullScreen),
                                               selectedTabIndex: selected, tabs: tabs))
        }
        return (state, texts)
    }

    /// The tree of a tab. Leaves out the panes whose session ended.
    static func capture(_ node: TerminalPaneNode, hostView: TerminalPaneHostView?, limit: Int,
                        texts: inout [ScrollbackSnapshot.Pending]) -> RestorePaneNode? {
        switch node.content {
        case .terminal(let controller):
            guard let pane = controller.restorePane() else { return nil }
            if pane.kind == .local, let text = controller.copyScrollback(limit: limit) { texts.append(text) }
            return .pane(pane)
        case .split(let orientation, let first, let second):
            let fraction = hostView?.dividerFraction(for: node.id).map(Double.init)
            return RestorePaneNode.split(orientation, fraction: fraction,
                                         capture(first, hostView: hostView, limit: limit, texts: &texts),
                                         capture(second, hostView: hostView, limit: limit, texts: &texts))
        }
    }

    nonisolated static func write(_ state: RestoreState, texts: [ScrollbackSnapshot.Pending], directory: URL,
                                  windowsURL: URL, panesURL: URL) {
        do {
            try? FileManager.default.removeItem(at: panesURL)
            try DurableStateDirectory.makePrivateDirectory(directory)
            guard !state.windows.isEmpty else {
                try? FileManager.default.removeItem(at: windowsURL)
                return
            }
            if !texts.isEmpty { try DurableStateDirectory.makePrivateDirectory(panesURL) }
            for text in texts {
                guard let data = text.encode(savedAt: state.savedAt) else { continue }
                try DurableStateDirectory.writePrivate(data, to: textURL(in: panesURL, for: text.paneID))
            }
            // The layout goes last: without it, a launch restores nothing.
            try DurableStateDirectory.writePrivate(try RestoreStateMigrator().encodeCurrent(state), to: windowsURL)
        } catch {
            NSLog("Tecolot: could not save the windows for the next launch: \(error)")
        }
    }

    // MARK: Restoring

    /// Reads the saved windows and deletes the file at once: a crash during
    /// the restore must not restore the same windows two times. Reads the
    /// old layout store's file when there is no new file.
    func takeSavedState() -> RestoreState? {
        defer { try? FileManager.default.removeItem(at: windowsURL) }
        if let data = try? Data(contentsOf: windowsURL) {
            let migrator = RestoreStateMigrator()
            do {
                return try migrator.decode(data, from: try migrator.sourceVersion(in: data))
            } catch {
                AppModel.shared.issueCenter.report(PersistenceIssue(
                    domain: .windowRestoration, sourceURL: windowsURL, kind: .invalidFormat,
                    message: error.localizedDescription, supportedVersion: RestoreStateMigrator.version))
                return nil
            }
        }
        guard let data = try? Data(contentsOf: legacyLayoutURL) else { return nil }
        try? FileManager.default.removeItem(at: legacyLayoutURL)
        return (try? JSONDecoder().decode(LegacyLayout.self, from: data))?.restoreState
    }

    /// Opens the saved windows. Returns true when it opened a window.
    func restore() -> Bool {
        isReady = true
        guard isEnabled else { return false }
        // Deletes the saved sessions that are older than seven days.
        let states = sessionStates
        Task.detached(priority: .utility) { _ = states.list() }
        guard let state = takeSavedState() else {
            removeUnusedPaneFiles(keeping: [])
            return false
        }
        let currentBoot = BootIdentifier.current()
        let macRestarted = state.bootID != nil && currentBoot != nil && state.bootID != currentBoot
        // A window can show a session before the restore (a notification
        // attached it). Its saved pane does not come back a second time.
        let shown = TerminalSessionRegistry.shared.shownPersistentSessionIDs()
        let running = Set(PersistentSessions.list().filter { !$0.exited }.map(\.id))
        var used = Set<UUID>()
        var opened = false
        for var window in state.windows {
            window.tabs = window.tabs.compactMap { tab in
                guard let root = tab.root.filter({ pane in
                    pane.kind != .persistent || !(pane.sessionID.map(shown.contains) ?? false)
                }) else { return nil }
                var tab = tab
                tab.root = root
                return tab
            }
            guard !window.tabs.isEmpty else { continue }
            window.selectedTabIndex = min(window.selectedTabIndex, window.tabs.count - 1)
            let tabs = window.tabs.map { tab in
                RestoredTab(tab: tab, panes: Dictionary(tab.root.panes.map { pane in
                    used.insert(pane.id)
                    return (pane.id, PaneRestoration(
                        pane: pane, savedAt: state.savedAt, macRestarted: macRestarted,
                        textURL: pane.kind == .local ? Self.textURL(in: panesURL, for: pane.id) : nil,
                        sessionRunning: pane.sessionID.map(running.contains) ?? false))
                }, uniquingKeysWith: { first, _ in first }))
            }
            if open(window, tabs: tabs) { opened = true }
        }
        removeUnusedPaneFiles(keeping: used)
        return opened
    }

    private func open(_ saved: RestoreWindow, tabs: [RestoredTab]) -> Bool {
        guard let firstTab = tabs.first,
              let first = WindowOpener.openWindow(spec: Self.launchSpec(for: firstTab),
                                                  initialFrame: .windowGroup(NSRectFromString(saved.frame)))
        else { return false }
        var windows = [first]
        for tab in tabs.dropFirst() {
            // Each tab joins after the last one, so the order stays the same.
            if let window = WindowOpener.openTab(spec: Self.launchSpec(for: tab), targetWindow: windows.last) {
                windows.append(window)
            }
        }
        if windows.indices.contains(saved.selectedTabIndex) {
            windows[saved.selectedTabIndex].makeKeyAndOrderFront(nil)
        }
        if saved.isFullScreen {
            DispatchQueue.main.async { [weak first] in
                guard let first, !first.styleMask.contains(.fullScreen) else { return }
                first.toggleFullScreen(nil)
            }
        }
        return true
    }

    static func launchSpec(for tab: RestoredTab) -> LaunchSpec {
        var spec = LaunchSpec()
        spec.profileID = tab.tab.root.panes.first?.profileID
        spec.restoredTab = tab
        return spec
    }

    /// Deletes the files in `panes/` that no restored pane reads. The panes
    /// delete their own file after the replay.
    private func removeUnusedPaneFiles(keeping used: Set<UUID>) {
        let panesURL = panesURL
        let kept = Set(used.map { Self.textURL(in: panesURL, for: $0).lastPathComponent })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: panesURL.path) else { return }
        for name in names where !kept.contains(name) {
            try? FileManager.default.removeItem(at: panesURL.appendingPathComponent(name))
        }
    }

    /// Reads and deletes the scrollback file of a local pane. Runs on a
    /// background task. A file that does not decode is deleted and reported.
    nonisolated static func takeText(at url: URL) -> (header: ScrollbackHeader, text: String)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        do {
            return try ScrollbackFile.decode(data)
        } catch {
            let message = "\(error)"
            Task { @MainActor in
                AppModel.shared.issueCenter.report(PersistenceIssue(
                    domain: .windowRestoration, sourceURL: url, kind: .invalidFormat, message: message,
                    supportedVersion: ScrollbackHeader.currentVersion))
            }
            return nil
        }
    }

    // MARK: Ended sessions

    /// A tab that starts a new persistent session from an ended one, with
    /// its directory and text (the Restore action of the Sessions window).
    static func launchSpec(restoring state: DurableSessionState) -> LaunchSpec {
        let profileID = state.launch.labels["profileID"].flatMap(UUID.init(uuidString:))
        let pane = RestorePane(id: UUID(), kind: .persistent, profileID: profileID, directory: state.directory,
                               sessionID: state.id, title: state.title,
                               alternateScreenProgram: state.alternateScreenProgram)
        let restoration = PaneRestoration(pane: pane, savedAt: state.savedAt, macRestarted: false,
                                          textURL: nil, sessionRunning: false)
        return launchSpec(for: RestoredTab(tab: RestoreTab(focusedPaneID: pane.id, root: .pane(pane)),
                                           panes: [pane.id: restoration]))
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
                return .pane(RestorePane(id: UUID(), kind: kind, profileID: pane.profileID,
                                         themeOverride: pane.themeOverride,
                                         directory: pane.workingDirectory.map { PaneDirectory(path: $0, source: .osc7) },
                                         sessionID: pane.sessionID, remoteDestination: pane.remoteDestination))
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
        RestoreState(bootID: nil, savedAt: Date(), windows: windows.filter { !$0.tabs.isEmpty }.map { window in
            RestoreWindow(frame: window.frame, selectedTabIndex: min(max(window.selectedTabIndex, 0), window.tabs.count - 1),
                          tabs: window.tabs.map { RestoreTab(root: $0.root.restoreNode) })
        })
    }
}
