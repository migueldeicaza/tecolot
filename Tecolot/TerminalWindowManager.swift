import AppKit
import Observation

/// The window side of the group model. Tests use a window with no AppKit views.
@MainActor
protocol TerminalGroupWindow: AnyObject {
    var id: UUID { get }
    var group: TerminalTabGroup { get }
    func show(_ group: TerminalTabGroup)
    func activate()
    func closeWindow()
}

@Observable
@MainActor
final class TerminalWindowManager {
    static let shared = TerminalWindowManager()
    private(set) var groups: [TerminalTabGroup] = []
    @ObservationIgnored private(set) var windows: [any TerminalGroupWindow] = []
    @ObservationIgnored private var windowGroups: [UUID: UUID] = [:]
    private struct WindowPresentation: Equatable {
        let groupID: UUID
        let tabs: [UUID]
        let selection: UUID?
        let name: String
        let dormant: [Bool]
        init(_ group: TerminalTabGroup) {
            groupID = group.id
            tabs = group.tabs.map(\.id)
            selection = group.selection
            name = group.name
            dormant = group.tabs.map(\.isDormant)
        }
    }
    @ObservationIgnored private var windowPresentations: [UUID: WindowPresentation] = [:]
    @ObservationIgnored var persistenceDidChange: ((Bool) -> Void)?
    @ObservationIgnored var makeWindow: ((TerminalTabGroup) -> any TerminalGroupWindow)?
    @ObservationIgnored private let registry: TerminalSessionRegistry
    @ObservationIgnored private let nameGenerator: GroupNameGenerator
    @ObservationIgnored private let windowSizeStore: TerminalWindowSizeStore

    init(registry: TerminalSessionRegistry? = nil, nameGenerator: GroupNameGenerator = GroupNameGenerator(), windowSizeStore: TerminalWindowSizeStore? = nil) {
        self.registry = registry ?? .shared
        self.nameGenerator = nameGenerator
        self.windowSizeStore = windowSizeStore ?? .shared
    }

    var backgroundGroups: [TerminalTabGroup] {
        groups.filter {
            !windowGroups.values.contains($0.id)
        }
    }

    var mostRecentBackgroundGroup: TerminalTabGroup? {
        backgroundGroups.filter {
            $0.lastShownAt != nil
        }
        .max {
            ($0.lastShownAt ?? .distantPast) < ($1.lastShownAt ?? .distantPast)
        }
    }

    func window(showing group: TerminalTabGroup) -> (any TerminalGroupWindow)? {
        windows.first {
            windowGroups[$0.id] == group.id
        }
    }

    func controller(for window: NSWindow?) -> TerminalWindowController? {
        windows.compactMap {
            $0 as? TerminalWindowController
        }.first {
            $0.window === window
        }
    }

    func group(containing controller: TerminalSessionController) -> TerminalTabGroup? {
        controller.workspace?.owningTab?.group
    }

    /// A user move creates a visible destination, including a single-tab source.
    func moveToNewGroup(_ tab: TerminalTab) {
        let group = newGroup(tab: tab)
        openWindow(group: group).activate()
    }

    @discardableResult
    func newGroup(in window: (any TerminalGroupWindow)? = nil, tab: TerminalTab? = nil) -> TerminalTabGroup {
        let tab = tab ?? TerminalTab()
        let source = groups.first {
            $0.tabs.contains(where: {
                $0 === tab
            })
        }
        if let source {
            remove(tab, from: source)
            if let owner = self.window(showing: source) {
                mount(source, in: owner)
            }
        }
        let group = TerminalTabGroup(name: nameGenerator.generate(existingNames: groups.map(\.name)), tabs: [tab])
        groups.append(group)
        if let window {
            _ = show(group, in: window)
        }
        if let source {
            finishRemovingTab(from: source)
        }
        changed()
        return group
    }

    @discardableResult
    func openWindow(group: TerminalTabGroup, startsGroup: Bool = true, initialFrame: TerminalWindowInitialFrame = .saved) -> any TerminalGroupWindow {
        if let existing = window(showing: group) {
            if startsGroup, group.tabs.contains(where: \.isDormant) {
                start(group)
                mount(group, in: existing)
                changed()
            }
            existing.activate()
            return existing
        }
        if startsGroup {
            start(group)
        }
        let cascade = controller(for: NSApp.keyWindow)?.window ?? controller(for: NSApp.mainWindow)?.window
        let window = makeWindow?(group) ?? TerminalWindowController(group: group, manager: self)
        if let owner = window as? TerminalWindowController, let native = owner.window {
            let profile = group.selectedTab?.loadedWorkspace?.focusedController?.profile
                ?? AppModel.shared.resolveProfile(for: group.selectedTab?.savedSpec)
            windowSizeStore.prepare(native, profile: profile, style: owner.sidebarPreferences, policy: initialFrame, cascadeFrom: cascade)
            native.contentView?.layoutSubtreeIfNeeded()
        }
        windows.append(window)
        windowGroups[window.id] = group.id
        windowPresentations[window.id] = WindowPresentation(group)
        group.lastShownAt = Date()
        changed()
        return window
    }

    /// Refuses a second view; navigation is responsible for activating its owner.
    @discardableResult
    func show(_ group: TerminalTabGroup, in window: any TerminalGroupWindow) -> Bool {
        guard
            groups.contains(where: {
                $0 === group
            }),
            windows.contains(where: {
                $0.id == window.id
            }),
            self.window(showing: group).map({
                $0.id == window.id
            }) ?? true else {
            return false
        }
        start(group)
        windowGroups[window.id] = group.id
        group.lastShownAt = Date()
        mount(group, in: window)
        changed()
        return true
    }

    func navigate(to group: TerminalTabGroup, tab: TerminalTab? = nil, in preferred: (any TerminalGroupWindow)? = nil) {
        if
            let tab, group.tabs.contains(where: {
                $0 === tab
            }) {
            group.selection = tab.id
        }
        if let owner = window(showing: group) {
            start(group)
            group.lastShownAt = Date()
            mount(group, in: owner)
            owner.activate()
        } else if let preferred, show(group, in: preferred) {
            preferred.activate()
        } else {
            openWindow(group: group).activate()
        }
        changed()
    }

    func reveal(_ controller: TerminalSessionController) {
        guard
            let group = group(containing: controller),
            let tab = group.tabs.first(where: {
                $0.loadedWorkspace?.contains(controller) == true
            }) else {
            return
        }
        navigate(to: group, tab: tab, in: self.controller(for: WindowOpener.frontTerminalWindow()))
        tab.workspace.zoomSelectedSplit(controller)
        controller.requestFocus()
    }

    func addTab(_ tab: TerminalTab, to group: TerminalTabGroup) {
        guard
            groups.contains(where: {
                $0 === group
            }) else {
            return
        }
        if
            let source = groups.first(where: {
                $0.tabs.contains(where: {
                    $0 === tab
                })
            }) {
            if source === group {
                select(tab, in: group)
            } else {
                move(tab, from: source, to: group)
            }
            return
        }
        group.tabs.append(tab)
        group.selection = tab.id
        changed()
    }

    func select(_ tab: TerminalTab, in group: TerminalTabGroup) {
        guard
            group.tabs.contains(where: {
                $0 === tab
            }) else {
            return
        }
        group.selection = tab.id
        if window(showing: group) != nil {
            start(group)
        }
        changed()
        tab.loadedWorkspace?.focusedController?.requestFocus()
    }

    func selectTab(at index: Int, in group: TerminalTabGroup) {
        guard group.tabs.indices.contains(index) else {
            return
        }
        select(group.tabs[index], in: group)
    }

    func cycleTab(_ offset: Int, in group: TerminalTabGroup) {
        guard !group.tabs.isEmpty else {
            return
        }
        let index = group.tabs.firstIndex {
            $0.id == group.selection
        } ?? 0
        selectTab(at: (index + offset + group.tabs.count) % group.tabs.count, in: group)
    }

    func cycleGroup(_ offset: Int, from window: any TerminalGroupWindow) {
        guard
            !groups.isEmpty, let index = groups.firstIndex(where: {
                $0 === window.group
            }) else {
            return
        }
        navigate(to: groups[(index + offset + groups.count) % groups.count], in: window)
    }

    func setCollapsed(_ collapsed: Bool, group: TerminalTabGroup) {
        group.isCollapsed = collapsed
        changed()
    }

    func collapseOthers(_ group: TerminalTabGroup) {
        for other in groups {
            other.isCollapsed = other !== group
        }
        changed()
    }

    func moveGroup(_ group: TerminalTabGroup, offset: Int) {
        guard
            let index = groups.firstIndex(where: {
                $0 === group
            }), groups.indices.contains(index + offset) else {
            return
        }
        groups.swapAt(index, index + offset)
        changed()
    }

    func rename(_ group: TerminalTabGroup, to name: String) {
        group.rename(name, among: groups, generator: nameGenerator)
        changed()
    }

    func closeTab(_ tab: TerminalTab, in group: TerminalTabGroup) {
        guard
            group.tabs.contains(where: {
                $0 === tab
            }) else {
            return
        }
        remove(tab, from: group)
        tab.loadedWorkspace?.terminateAll()
        finishRemovingTab(from: group)
    }

    private func fallbackGroup(excluding excluded: TerminalTabGroup? = nil) -> TerminalTabGroup? {
        backgroundGroups.filter {
            $0 !== excluded && $0.lastShownAt != nil && !$0.tabs.contains(where: \.isDormant)
        }.max {
            ($0.lastShownAt ?? .distantPast) < ($1.lastShownAt ?? .distantPast)
        }
    }

    func closeGroup(_ group: TerminalTabGroup) {
        guard
            groups.contains(where: {
                $0 === group
            }) else {
            return
        }
        let owner = window(showing: group)
        if let owner {
            windowGroups.removeValue(forKey: owner.id)
        }
        groups.removeAll {
            $0 === group
        }
        for tab in group.tabs {
            tab.loadedWorkspace?.terminateAll()
        }
        if let owner {
            if let fallback = fallbackGroup() {
                _ = show(fallback, in: owner)
            } else {
                closeWindow(owner)
            }
        }
        changed()
    }

    /// Closing a window unmounts views and keeps its group running.
    func closeWindow(_ window: any TerminalGroupWindow) {
        guard
            windows.contains(where: {
                $0.id == window.id
            }) else {
            return
        }
        for tab in window.group.tabs {
            tab.loadedWorkspace?.controllers.forEach {
                $0.setProgramStatusDrawingVisible(false)
            }
        }
        windowGroups.removeValue(forKey: window.id)
        windows.removeAll {
            $0.id == window.id
        }
        windowPresentations.removeValue(forKey: window.id)
        window.closeWindow()
        changed()
        persistenceDidChange?(true)
    }

    func reorder(_ tab: TerminalTab, in group: TerminalTabGroup, insertion: Int) {
        guard
            let source = group.tabs.firstIndex(where: {
                $0 === tab
            }) else {
            return
        }
        let destination = TabStripLayout.reorderIndex(source: source, insertion: insertion, count: group.tabs.count)
        guard source != destination else {
            return
        }
        group.tabs.remove(at: source)
        group.tabs.insert(tab, at: destination)
        changed()
    }

    func move(_ tab: TerminalTab, from source: TerminalTabGroup, to target: TerminalTabGroup, insertion: Int? = nil) {
        guard
            source !== target, source.tabs.contains(where: {
                $0 === tab
            }),
            groups.contains(where: {
                $0 === target
            }) else {
            return
        }
        remove(tab, from: source)
        target.tabs.insert(tab, at: max(0, min(target.tabs.count, insertion ?? target.tabs.count)))
        target.selection = tab.id
        // Reparent from the source before mounting in the destination window.
        if let owner = window(showing: source) {
            mount(source, in: owner)
        }
        if source.tabs.isEmpty {
            // A move must not start a dormant destination as the source fallback.
            let owner = window(showing: source)
            if let owner {
                windowGroups.removeValue(forKey: owner.id)
            }
            groups.removeAll {
                $0 === source
            }
            if let owner {
                if
                    let fallback = fallbackGroup(excluding: target) {
                    _ = show(fallback, in: owner)
                } else {
                    closeWindow(owner)
                }
            }
            changed()
        } else {
            finishRemovingTab(from: source)
        }
    }

    @discardableResult
    func moveToNewWindow(_ tab: TerminalTab, from source: TerminalTabGroup, activate: Bool = true) -> (any TerminalGroupWindow)? {
        guard
            source.tabs.count > 1, source.tabs.contains(where: {
                $0 === tab
            }) else {
            return nil
        }
        let sourceFrame = (window(showing: source) as? TerminalWindowController)?.window?.frame
        remove(tab, from: source)
        let target = newGroup(tab: tab)
        if let owner = window(showing: source) {
            mount(source, in: owner)
        }
        let window = openWindow(group: target, initialFrame: sourceFrame.map {
            .cascaded($0)
        } ?? .saved)
        finishRemovingTab(from: source)
        if activate {
            window.activate()
        }
        return window
    }

    func mergeAllWindows(into destination: any TerminalGroupWindow) {
        let sources = windows.filter {
            $0.id != destination.id
        }
        for source in sources {
            let group = source.group
            let tabs = group.tabs
            group.tabs = []
            mount(group, in: source)
            destination.group.tabs.append(contentsOf: tabs)
            groups.removeAll {
                $0 === group
            }
            // Every forced save sees the transferred tabs in their new owner.
            closeWindow(source)
        }
        changed()
    }

    private func remove(_ tab: TerminalTab, from group: TerminalTabGroup) {
        let index = group.tabs.firstIndex {
            $0 === tab
        } ?? 0
        group.tabs.removeAll {
            $0 === tab
        }
        if group.selection == tab.id {
            group.selection = group.tabs.isEmpty ? nil : group.tabs[min(index, group.tabs.count - 1)].id
        }
    }

    private func finishRemovingTab(from group: TerminalTabGroup) {
        if group.tabs.isEmpty {
            closeGroup(group)
        } else {
            changed()
        }
    }

    /// Refreshes chrome only when the selected tab's panes changed. Hidden panes
    /// apply their appearance directly; tab labels observe presentation changes.
    /// System appearance also affects native chrome and dormant-group placeholders.
    func refreshWindows(affectedControllers: Set<UUID>, systemAppearanceChanged: Bool = false) {
        for window in windows {
            let hasChangedPane = window.group.selectedTab?.loadedWorkspace?.controllers.contains {
                affectedControllers.contains($0.id)
            } == true
            if systemAppearanceChanged || hasChangedPane {
                mount(window.group, in: window, force: true)
            }
        }
    }

    private func mount(_ group: TerminalTabGroup, in window: any TerminalGroupWindow, force: Bool = false) {
        let next = WindowPresentation(group)
        guard force || windowPresentations[window.id] != next else {
            return
        }
        windowPresentations[window.id] = next
        window.show(group)
    }

    private func changed() {
        for group in groups {
            for tab in group.tabs {
                tab.loadedWorkspace?.windowManager = self
            }
        }
        persistenceDidChange?(false)
        registry.synchronize(groups: groups, manager: self)
        for window in windows {
            mount(window.group, in: window)
        }
        NotificationCenter.default.post(name: .groupsDidChange, object: self)
        NotificationCenter.default.post(name: .terminalFocusedPaneDidChange, object: nil)
        for tab in groups.flatMap(\.tabs) {
            tab.loadedWorkspace?.updateProcessInspection()
        }
    }

    func addRestoredGroup(_ group: TerminalTabGroup) {
        groups.append(group)
        changed()
    }

    private func start(_ group: TerminalTabGroup) {
        for tab in group.tabs {
            tab.start()
            tab.loadedWorkspace?.windowManager = self
        }
    }

    /// Duplicate descriptions, never attachments. Remote panes start fresh
    /// sessions on the same host; local persistent panes also get new sessions.
    @discardableResult
    func duplicate(_ group: TerminalTabGroup, showInWindow: Bool = true) -> TerminalTabGroup? {
        var texts: [ScrollbackSnapshot.Pending] = []
        var caches: [RemoteRowCopy] = []
        var selectedCopyID: UUID?
        let tabs = group.tabs.compactMap { tab -> TerminalTab? in
            guard var saved = RestoreStore.capture(tab, texts: &texts, caches: &caches) else {
                return nil
            }
            saved.id = UUID()
            if tab.id == group.selection {
                selectedCopyID = saved.id
            }
            var ids: [UUID: UUID] = [:]
            func copy(_ node: RestorePaneNode) -> RestorePaneNode {
                switch node {
                case .pane(var pane):
                    let id = UUID()
                    ids[pane.id] = id
                    pane.id = id
                    pane.sessionID = nil
                    pane.title = nil
                    pane.alternateScreenProgram = nil
                    return .pane(pane)
                case .split(let orientation, let fraction, let first, let second):
                    return .split(orientation, fraction: fraction, first: copy(first), second: copy(second))
                }
            }
            saved.root = copy(saved.root)
            saved.focusedPaneID = saved.focusedPaneID.flatMap {
                ids[$0]
            }
            saved.zoomedPaneID = saved.zoomedPaneID.flatMap {
                ids[$0]
            }
            saved.fileURL = nil
            return TerminalTab(dormant: RestoreStore.launchSpec(for: RestoredTab(tab: saved, panes: Dictionary(uniqueKeysWithValues: saved.root.panes.map {
                ($0.id, PaneRestoration(
                    pane: $0,
                    savedAt: Date(),
                    macRestarted: false,
                    textURL: nil,
                    sessionRunning: false,
                    startsFresh: true
                ))
            }))))
        }
        guard !tabs.isEmpty else {
            if showInWindow {
                NSSound.beep()
            }
            return nil
        }
        let duplicate = TerminalTabGroup(name: nameGenerator.generate(existingNames: groups.map(\.name)), tabs: tabs)
        if let selectedCopyID {
            duplicate.selection = selectedCopyID
        }
        groups.append(duplicate)
        changed()
        if showInWindow {
            let sourceFrame = (window(showing: group) as? TerminalWindowController)?.window?.frame
            openWindow(group: duplicate, initialFrame: sourceFrame.map {
                .cascaded($0)
            } ?? .saved).activate()
        }
        return duplicate
    }

    /// Back-to-front shown windows for group persistence.
    func shownWindows() -> [(window: NSWindow, group: TerminalTabGroup)] {
        let ordered = NSApp.orderedWindows.reversed() + NSApp.windows
        var seen = Set<UUID>()
        return ordered.compactMap { window in
            guard let controller = controller(for: window), seen.insert(controller.id).inserted else {
                return nil
            }
            return (window, controller.group)
        }
    }
}

extension Notification.Name {
    static let groupsDidChange = Notification.Name("TerminalGroupsDidChange")
}
