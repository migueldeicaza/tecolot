//
//  PersistentLayoutStore.swift
//  Tecolot
//
//  Remembers the windows, tabs and split layouts that show persistent
//  sessions, so that the next launch can show them again.
//
//  The layout is saved shortly after the panes change, and once more when
//  the app quits (before the windows close). A crash keeps the last save.
//  When the user closes a window, the next save no longer has it.
//

import AppKit
import Foundation
import TecolotSessionDirectory

/// One pane: a persistent session, or a local shell to start again.
struct SavedPane: Codable, Hashable {
    /// The persistent session; nil for a local pane.
    var sessionID: String?
    var profileID: UUID?
    var themeOverride: String?
    var workingDirectory: String?
}

/// A pane tree, like TerminalPaneNode.
indirect enum SavedPaneNode: Codable, Hashable {
    case pane(SavedPane)
    /// `fraction` is the size of the first child over the available length.
    case split(TerminalPaneSplit, fraction: Double?, first: SavedPaneNode, second: SavedPaneNode)

    var panes: [SavedPane] {
        switch self {
        case .pane(let pane): return [pane]
        case .split(_, _, let first, let second): return first.panes + second.panes
        }
    }

    /// Removes the panes whose persistent session no longer runs. A split
    /// with one child left becomes that child.
    func pruned(liveSessions: Set<String>) -> SavedPaneNode? {
        switch self {
        case .pane(let pane):
            if let id = pane.sessionID, !liveSessions.contains(id) { return nil }
            return self
        case .split(let orientation, let fraction, let first, let second):
            switch (first.pruned(liveSessions: liveSessions), second.pruned(liveSessions: liveSessions)) {
            case (let left?, let right?): return .split(orientation, fraction: fraction, first: left, second: right)
            case (let left?, nil): return left
            case (nil, let right?): return right
            case (nil, nil): return nil
            }
        }
    }
}

struct SavedPaneTree: Codable, Hashable {
    var root: SavedPaneNode

    var hasPersistentPane: Bool { root.panes.contains { $0.sessionID != nil } }
}

struct SavedLayoutWindow: Codable, Hashable {
    var frame: String
    var tabs: [SavedPaneTree]
    var selectedTabIndex: Int
}

struct SavedLayout: Codable, Hashable {
    var version = 1
    var windows: [SavedLayoutWindow] = []

    /// The layout without ended sessions; tabs and windows that have no
    /// running persistent session left are dropped.
    func pruned(liveSessions: Set<String>) -> SavedLayout {
        var result = SavedLayout(version: version)
        for window in windows {
            var tabs: [SavedPaneTree] = []
            var selected = 0
            for (index, tab) in window.tabs.enumerated() {
                guard let root = tab.root.pruned(liveSessions: liveSessions) else { continue }
                let tree = SavedPaneTree(root: root)
                guard tree.hasPersistentPane else { continue }
                if index == window.selectedTabIndex { selected = tabs.count }
                tabs.append(tree)
            }
            if !tabs.isEmpty {
                result.windows.append(SavedLayoutWindow(frame: window.frame, tabs: tabs, selectedTabIndex: selected))
            }
        }
        return result
    }
}

@MainActor
final class PersistentLayoutStore {
    /// The app's store. Tests never write the app's saved layout.
    static let shared = PersistentLayoutStore(
        autosaves: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil)

    private let url: URL
    private let autosaves: Bool
    private var saveScheduled = false
    /// Set when the app quits: the last save already has every window.
    private var isTerminating = false
    /// False until the startup restore ran. Before it, the open windows are
    /// not the saved layout yet, and saving them would replace it (for
    /// example when the app quits before it ever became active).
    private(set) var isReady = false
    private var windowObserver: NSObjectProtocol?

    init(url: URL = PersistentLayoutStore.defaultURL, autosaves: Bool = true) {
        self.url = url
        self.autosaves = autosaves
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSave() }
        }
    }

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot")
            .appendingPathComponent("persistent-layout.json")
    }

    // MARK: Saving

    /// Allows saves without a restore (the startup found nothing to restore).
    func markReady() {
        isReady = true
    }

    /// Saves after the panes settle.
    func scheduleSave() {
        guard autosaves, isReady, !isTerminating, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            saveScheduled = false
            guard !isTerminating else { return }
            save(capture())
        }
    }

    /// Saves the layout of the open windows now and stops later saves.
    /// Call when the app is about to quit, before its windows close.
    func saveForTermination() {
        guard autosaves, isReady else { return }
        save(capture())
        isTerminating = true
    }

    func save(_ layout: SavedLayout) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if layout.windows.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(layout).write(to: url, options: .atomic)
        } catch {
            NSLog("Tecolot: could not save the persistent layout: \(error)")
        }
    }

    func load() -> SavedLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedLayout.self, from: data)
    }

    /// The windows and tabs that show at least one persistent pane.
    func capture() -> SavedLayout {
        var layout = SavedLayout()
        var visitedTabGroups = Set<ObjectIdentifier>()
        let registry = TerminalSessionRegistry.shared
        for window in NSApp.windows where registry.workspace(for: window) != nil {
            let tabWindows: [NSWindow]
            let selectedWindow: NSWindow
            if let tabGroup = window.tabGroup {
                guard visitedTabGroups.insert(ObjectIdentifier(tabGroup)).inserted else { continue }
                tabWindows = tabGroup.windows.filter { registry.workspace(for: $0) != nil }
                selectedWindow = tabGroup.selectedWindow ?? window
            } else {
                tabWindows = [window]
                selectedWindow = window
            }
            var tabs: [SavedPaneTree] = []
            var selected = 0
            for tabWindow in tabWindows {
                guard let workspace = registry.workspace(for: tabWindow) else { continue }
                let tree = SavedPaneTree(root: Self.capture(workspace.root, hostView: workspace.hostView))
                guard tree.hasPersistentPane else { continue }
                if tabWindow === selectedWindow { selected = tabs.count }
                tabs.append(tree)
            }
            guard !tabs.isEmpty else { continue }
            layout.windows.append(SavedLayoutWindow(frame: NSStringFromRect(selectedWindow.frame),
                                                    tabs: tabs, selectedTabIndex: selected))
        }
        return layout
    }

    static func capture(_ node: TerminalPaneNode, hostView: TerminalPaneHostView?) -> SavedPaneNode {
        switch node.content {
        case .terminal(let controller):
            return .pane(SavedPane(sessionID: controller.persistentSessionID,
                                   profileID: controller.profile.id,
                                   themeOverride: controller.themeOverride,
                                   workingDirectory: controller.currentWorkingDirectory))
        case .split(let orientation, let first, let second):
            let fraction = hostView?.dividerFraction(for: node.id).map(Double.init)
            return .split(orientation, fraction: fraction,
                          first: capture(first, hostView: hostView),
                          second: capture(second, hostView: hostView))
        }
    }

    // MARK: Restoring

    /// Opens the saved windows whose sessions still run and no window shows
    /// yet. Returns true when it opened a window.
    func restore() -> Bool {
        isReady = true
        guard let saved = load() else { return false }
        let registry = TerminalSessionRegistry.shared
        let shown = Set(NSApp.windows.flatMap { registry.controllers(for: $0) }.compactMap(\.persistentSessionID))
        let live = Set(PersistentSessions.list().filter { !$0.exited }.map(\.id)).subtracting(shown)
        let layout = saved.pruned(liveSessions: live)
        var opened = false
        for savedWindow in layout.windows {
            guard let firstTab = savedWindow.tabs.first,
                  let firstWindow = WindowOpener.openWindow(
                    spec: Self.launchSpec(for: firstTab),
                    initialFrame: .windowGroup(NSRectFromString(savedWindow.frame))) else { continue }
            opened = true
            var windows = [firstWindow]
            for tab in savedWindow.tabs.dropFirst() {
                if let window = WindowOpener.openTab(spec: Self.launchSpec(for: tab), targetWindow: firstWindow) {
                    windows.append(window)
                }
            }
            if windows.indices.contains(savedWindow.selectedTabIndex) {
                windows[savedWindow.selectedTabIndex].makeKeyAndOrderFront(nil)
            }
        }
        return opened
    }

    static func launchSpec(for tree: SavedPaneTree) -> LaunchSpec {
        var spec = LaunchSpec()
        spec.profileID = tree.root.panes.first?.profileID
        spec.paneTree = tree
        return spec
    }
}
