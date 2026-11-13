import AppKit

extension Notification.Name {
    static let programActivityDidChange = Notification.Name("ProgramActivityDidChange")
}

/// Aggregation includes live groups even when no window mounts their views.
@MainActor
final class ProgramActivityCenter {
    static let shared = ProgramActivityCenter()
    private var observers: [NSObjectProtocol] = []
    private var updating = false
    private let manager: TerminalWindowManager
    private var tabsByWorkspace: [ObjectIdentifier: TerminalTab] = [:]
    private var statuses: [UUID: TabStatus] = [:]
    private let statusForTab: @MainActor (TerminalTab) -> TabStatus

    init(manager: TerminalWindowManager? = nil, statusForTab: @escaping @MainActor (TerminalTab) -> TabStatus = {
        $0.status
    }) {
        self.manager = manager ?? .shared
        self.statusForTab = statusForTab
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    /// Observes activity, visibility and actual status preference changes across all windows.
    func start() {
        guard observers.isEmpty else {
            return
        }
        _ = ProgramActivitySettings.shared.value
        for name in [
            Notification.Name.programActivityDidChange, .groupsDidChange,
            NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification,
            .programActivityPreferencesDidChange,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self else {
                            return
                        }
                        if note.name == .groupsDidChange, let owner = note.object as? TerminalWindowManager, owner !== self.manager {
                            return
                        }
                        self.update(changedPane: note.name == .programActivityDidChange ? note.object as? TerminalSessionController : nil)
                    }
                }
            )
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    _ = ProgramActivitySeenStore.shared.flush()
                }
            }
        )
    }
    /// Marks visible reports seen and replaces the Dock count with unseen program tabs.
    func update(changedPane: TerminalSessionController? = nil) {
        guard !updating else {
            return
        }
        updating = true
        defer { updating = false }
        if let pane = changedPane, let workspace = pane.workspace, let tab = tabsByWorkspace[ObjectIdentifier(workspace)] {
            pane.markProgramActivitySeenIfVisible()
            statuses[tab.id] = statusForTab(tab)
        } else {
            tabsByWorkspace.removeAll(keepingCapacity: true)
            statuses.removeAll(keepingCapacity: true)
            for group in manager.groups {
                for tab in group.tabs {
                    if let workspace = tab.loadedWorkspace {
                        tabsByWorkspace[ObjectIdentifier(workspace)] = tab
                        for pane in workspace.controllers {
                            pane.markProgramActivitySeenIfVisible()
                        }
                    }
                    statuses[tab.id] = statusForTab(tab)
                }
            }
        }
        let count = ProgramActivitySettings.shared.value.dock ? TabStatus.dockCount(Array(statuses.values)) : 0
        let label = count == 0 ? nil : String(count)
        if NSApp.dockTile.badgeLabel != label {
            NSApp.dockTile.badgeLabel = label
        }
    }
}

/// Independent clocks for notification and sound. A denied attempt does not
/// move the window; muted tabs and disabled states never consume a slot.
nonisolated struct ProgramActivityRateLimiter {
    private var notifications: [UUID: TimeInterval] = [:]
    private var sounds: [UUID: TimeInterval] = [:]
    private var attention: [UUID: TimeInterval] = [:]

    /// Attention has its own window so a sound does not suppress the Dock bounce.
    mutating func admitAttention(tab: UUID, now: TimeInterval) -> Bool {
        attention = attention.filter {
            now - $0.value < 2
        }
        guard attention[tab] == nil else {
            return false
        }
        attention[tab] = now
        return true
    }

    /// Admits one notification or one sound per tab in each two-second window.
    mutating func admit(tab: UUID, sound: Bool, now: TimeInterval) -> Bool {
        var values = sound ? sounds : notifications
        values = values.filter {
            now - $0.value < 2
        }
        guard values[tab] == nil else {
            return false
        }
        values[tab] = now
        if sound {
            sounds = values
        } else {
            notifications = values
        }
        return true
    }
}
