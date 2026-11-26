//
//  TerminalPaneWorkspace.swift
//  Tecolot
//
//  Owns the pane tree for one tab. The AppKit host rebuilds only
//  the split-view containers when the tree changes. It reuses each terminal
//  view, so a split does not restart an existing process.
//

import AppKit
import Observation
import SwiftTerm
import TecolotSessionHost
import TecolotWire
import SwiftUI

nonisolated enum TerminalPaneSplit: String, Codable, Sendable {
    /// A vertical divider puts panes next to each other.
    case vertical
    /// A horizontal divider stacks panes.
    case horizontal
}

enum TerminalPaneDirection {
    case up
    case down
    case left
    case right
}

/// The change of the pane tree that the host animates at the next rebuild.
enum TerminalPaneTransition {
    /// A split added this pane. It grows from the edge in this direction.
    case added(UUID, TerminalPaneDirection)
    /// A close removed this pane. It shrinks to the edge in this direction.
    case removed(UUID, TerminalPaneDirection)
}

/// Ignores unrelated defaults notifications before starting process-inspection work.
nonisolated struct PaneIconInspectionPreferences {
    struct Value: Equatable {
        var iconCount: Int
        var tracking: Bool

        init(iconCount: Int, tracking: Bool) {
            self.iconCount = iconCount
            self.tracking = tracking
        }

        init(defaults: UserDefaults) {
            iconCount = TabStripPreferences.effectiveIconCount(defaults)
            tracking = TabStripPreferences.tracksRunningPrograms(defaults)
        }
    }

    private(set) var iconCount: Int
    /// General › "Track running programs".
    private(set) var tracking: Bool
    init(iconCount: Int, tracking: Bool) {
        self.iconCount = iconCount
        self.tracking = tracking
    }

    mutating func update(iconCount: Int, tracking: Bool, refresh: () -> Void) {
        guard self.iconCount != iconCount || self.tracking != tracking else {
            return
        }
        self.iconCount = iconCount
        self.tracking = tracking
        refresh()
    }
}

/// Multiple layout and visibility callbacks in one turn evaluate the final state once.
@MainActor
final class ProcessInspectionUpdates {
    private var pending: DispatchWorkItem?
    func request(_ evaluate: @escaping @MainActor () -> Void) {
        guard pending == nil else {
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.pending = nil
                evaluate()
            }
        }
        pending = work
        DispatchQueue.main.async(execute: work)
    }
    func cancel() {
        pending?.cancel()
        pending = nil
    }
    deinit { pending?.cancel() }
}

@Observable
final class TerminalPaneNode: Identifiable {
    enum Content {
        case terminal(TerminalSessionController)
        case split(TerminalPaneSplit, TerminalPaneNode, TerminalPaneNode)
    }

    let id = UUID()
    var content: Content

    init(content: Content) {
        self.content = content
    }
}

@Observable
@MainActor
final class TerminalPaneWorkspace {
    @ObservationIgnored weak var owningTab: TerminalTab?
    private(set) var root: TerminalPaneNode
    private(set) var revision = 0 {
        didSet { windowManager?.persistenceDidChange?(false) }
    }
    private(set) var focusHistory: [UUID] = []
    private(set) var creationOrder: [UUID] = []
    private(set) var focusedControllerID: UUID
    private(set) var zoomedControllerID: UUID?
    /// Previews draw real panes without participating in terminal window behavior.
    let participatesInWindow: Bool
    @ObservationIgnored private let startsProcesses: Bool
    @ObservationIgnored weak var hostView: TerminalPaneHostView?
    @ObservationIgnored weak var windowManager: TerminalWindowManager?
    /// The host reads and clears this value when it rebuilds the views.
    @ObservationIgnored var pendingTransition: TerminalPaneTransition?
    /// The host sets this value from SwiftUI. The title bar also reads it.
    @ObservationIgnored var appearanceSettings = GlobalAppearanceSettings()
    @ObservationIgnored private let processInspectionUpdates = ProcessInspectionUpdates()
    @ObservationIgnored private var processTask: Task<Void, Never>?
    /// Deadline of the current `processTask` sleep, or `nil` when no sleep is active.
    @ObservationIgnored private var processTaskWake: ContinuousClock.Instant?
    /// Identifies the current `processTask`. A cancelled task that continues
    /// for a short time does not change `processTaskWake`.
    @ObservationIgnored private var processTaskGeneration: UInt64 = 0
    @ObservationIgnored private var jobIconResolvers: [UUID: TerminalForegroundJobIconResolver] = [:]
    @ObservationIgnored private var iconPreferencesObserver: DefaultsValueObserver<PaneIconInspectionPreferences.Value>?
    @ObservationIgnored private var iconPreferences = PaneIconInspectionPreferences(
        iconCount: TabStripPreferences.effectiveIconCount(.standard),
        tracking: TabStripPreferences.tracksRunningPrograms(.standard)
    )

    init(spec: LaunchSpec = LaunchSpec(), startsProcesses: Bool = true, participatesInWindow: Bool = true) {
        self.participatesInWindow = participatesInWindow
        self.startsProcesses = startsProcesses
        let controller = TerminalSessionController(startsProcess: startsProcesses)
        root = TerminalPaneNode(content: .terminal(controller))
        focusedControllerID = controller.id
        focusHistory = [controller.id]
        creationOrder = [controller.id]
        controller.workspace = self
        launchSpec = spec
        if spec.restoredTab == nil {
            controller.resolveLaunchIfNeeded(spec: spec)
        }
        iconPreferencesObserver = DefaultsValueObserver(
            defaults: .standard, keys: [TabStripPreferences.iconCountKey, TabStripPreferences.trackRunningProgramsKey]
        ) {
            PaneIconInspectionPreferences.Value(defaults: $0)
        }
        iconPreferencesObserver?.onChange = { [weak self] value in
            guard let self else {
                return
            }
            self.iconPreferences.update(iconCount: value.iconCount, tracking: value.tracking) {
                self.updateProcessInspection()
            }
        }
    }

    deinit {
        processTask?.cancel()
    }

    @ObservationIgnored private var didConsiderPaneTree = false
    @ObservationIgnored private var launchSpec = LaunchSpec()
    @ObservationIgnored private var restoredDividerFractions: [UUID: CGFloat] = [:]

    /// Rebuilds the pane tree from a launch that carries a restored
    /// tab (restore on relaunch). Call before any pane view exists.
    /// Returns the saved divider fractions by split node.
    @discardableResult
    func adoptPaneTree() -> [UUID: CGFloat]? {
        guard !didConsiderPaneTree else {
            return nil
        }
        didConsiderPaneTree = true
        guard let restored = launchSpec.restoredTab else {
            return nil
        }
        var fractions: [UUID: CGFloat] = [:]
        var first: TerminalSessionController?
        func build(_ saved: RestorePaneNode) -> TerminalPaneNode {
            switch saved {
            case .pane(let pane):
                let controller = TerminalSessionController(startsProcess: startsProcesses, id: pane.id)
                controller.workspace = self
                controller.presetRestore(restored.panes[pane.id] ?? PaneRestoration(
                    pane: pane, savedAt: Date(), macRestarted: false, textURL: nil, sessionRunning: false
                ))
                if first == nil {
                    first = controller
                }
                return TerminalPaneNode(content: .terminal(controller))
            case .split(let orientation, let fraction, let firstChild, let secondChild):
                let node = TerminalPaneNode(content: .split(orientation, build(firstChild), build(secondChild)))
                if let fraction {
                    fractions[node.id] = CGFloat(fraction)
                }
                return node
            }
        }
        root = build(restored.tab.root)
        restoredDividerFractions = fractions
        creationOrder = controllers.map(\.id)
        let ids = Set(controllers.map(\.id))
        if let focused = restored.tab.focusedPaneID, ids.contains(focused) {
            focusedControllerID = focused
        } else if let first {
            focusedControllerID = first.id
        }
        focusHistory = [focusedControllerID]
        if let zoomed = restored.tab.zoomedPaneID, ids.contains(zoomed), ids.count > 1 {
            zoomedControllerID = zoomed
        }
        return fractions
    }

    /// Adopts the restored pane tree if needed, hands its divider fractions to
    /// the host view once, and clears the launch-time copy from the workspace.
    func takeRestoredDividerFractions() -> [UUID: CGFloat]? {
        adoptPaneTree()
        guard !restoredDividerFractions.isEmpty else {
            return nil
        }
        let fractions = restoredDividerFractions
        restoredDividerFractions.removeAll()
        return fractions
    }

    var controllers: [TerminalSessionController] {
        collectControllers(in: root)
    }

    var focusedController: TerminalSessionController? {
        controllers.first {
            $0.id == focusedControllerID
        } ?? controllers.first
    }

    var paneCount: Int {
        controllers.count
    }

    func markFocused(_ controller: TerminalSessionController) {
        guard contains(controller) else {
            return
        }
        if focusHistory.first != controller.id {
            focusHistory.removeAll {
                $0 == controller.id
            }
            focusHistory.insert(controller.id, at: 0)
        }
        if focusedControllerID != controller.id {
            focusedControllerID = controller.id
        }
    }

    func split(_ controller: TerminalSessionController, orientation: TerminalPaneSplit) {
        split(controller, direction: orientation == .vertical ? .right : .down)
    }

    func split(_ controller: TerminalSessionController, direction: TerminalPaneDirection) {
        guard let node = findNode(for: controller, in: root) else {
            return
        }

        let newController = TerminalSessionController(startsProcess: startsProcesses)
        newController.prepareForSplit(from: controller)
        newController.workspace = self

        let existingNode = TerminalPaneNode(content: .terminal(controller))
        let newNode = TerminalPaneNode(content: .terminal(newController))
        switch direction {
        case .right:
            node.content = .split(.vertical, existingNode, newNode)
        case .left:
            node.content = .split(.vertical, newNode, existingNode)
        case .down:
            node.content = .split(.horizontal, existingNode, newNode)
        case .up:
            node.content = .split(.horizontal, newNode, existingNode)
        }
        creationOrder.append(newController.id)
        markFocused(newController)
        if zoomedControllerID != nil {
            zoomedControllerID = newController.id
            pendingTransition = nil
        } else {
            pendingTransition = .added(newController.id, direction)
        }
        bumpRevision()
    }

    func toggleSplitZoom() {
        guard paneCount > 1, let focused = focusedController else {
            return
        }
        zoomedControllerID = zoomedControllerID == focused.id ? nil : focused.id
        bumpRevision()
    }

    func clearSplitZoom() {
        guard zoomedControllerID != nil else {
            return
        }
        zoomedControllerID = nil
        bumpRevision()
    }

    func zoomSelectedSplit(_ controller: TerminalSessionController) {
        guard
            zoomedControllerID != nil, contains(controller),
            zoomedControllerID != controller.id else {
            return
        }
        zoomedControllerID = controller.id
        bumpRevision()
    }

    func selectPreviousSplit() {
        selectSplit(offset: -1)
    }

    func selectNextSplit() {
        selectSplit(offset: 1)
    }

    func selectSplit(in direction: TerminalPaneDirection) {
        hostView?.selectSplit(in: direction)
    }

    func equalizeSplits() {
        guard zoomedControllerID == nil else {
            return
        }
        hostView?.equalizeSplits()
    }

    func moveDivider(in direction: TerminalPaneDirection) {
        guard zoomedControllerID == nil else {
            return
        }
        hostView?.moveDivider(in: direction)
    }

    /// Removes a pane. Returns false when it is the only pane in the window.
    @discardableResult
    func close(_ controller: TerminalSessionController) -> Bool {
        // A pane can close two times, for example when the user closes it
        // and then its process exits. The second close does nothing.
        guard paneCount > 1, contains(controller) else {
            return false
        }
        let closingFocused = focusedController === controller
        let successor = closingFocused ? successorAfterClosing(controller) : nil
        let edge = zoomedControllerID == nil && hostView?.transitionsAllowed == true
            ? removalEdge(for: controller, in: root) : nil
        if edge != nil {
            hostView?.prepareRemovalTransition(for: controller)
        }
        guard remove(controller, from: root) else {
            if edge != nil {
                hostView?.cancelTransition()
            }
            return false
        }
        focusHistory.removeAll {
            $0 == controller.id
        }
        creationOrder.removeAll {
            $0 == controller.id
        }
        pendingTransition = edge.map {
            .removed(controller.id, $0)
        }
        controller.terminate()
        if zoomedControllerID == controller.id || paneCount == 1 {
            zoomedControllerID = nil
        }
        if closingFocused, let fallback = successor ?? controllers.first {
            markFocused(fallback)
            fallback.requestFocus()
        }
        bumpRevision()
        return true
    }

    func terminateAll() {
        processInspectionUpdates.cancel()
        processTask?.cancel()
        processTask = nil
        processTaskWake = nil
        for controller in controllers {
            controller.terminate()
        }
    }

    func updateWindowTransparency() {
        guard participatesInWindow, let window = controllers.compactMap(\.surface?.window).first else {
            return
        }
        TerminalWindowTransparency.apply(
            to: window,
            isEnabled: controllers.contains {
                $0.effectiveBackgroundOpacity < 1.0
            }
                || hostView?.showsDesktopBlur == true
        )
    }

    /// Visible headers and tab icons need fresh jobs, including zoom-hidden panes.
    /// Dormant and background groups keep cached identities without polling.
    var needsProcessInspection: Bool {
        guard
            !NSApp.isHidden, let tab = owningTab, let group = tab.group,
            let manager = windowManager,
            let owner = manager.window(showing: group) as? TerminalWindowController else {
            return false
        }
        if
            let window = owner.window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible),
            group.selection == tab.id, hostView?.cardsEnabled == true, hostView?.showsPaneHeaders == true {
            return true
        }
        guard iconPreferences.iconCount > 0 else {
            return false
        }
        return manager.windows.compactMap {
            $0 as? TerminalWindowController
        }.contains {
            $0.tabBar.hasVisibleCell(for: tab) || $0.sidebar.hasVisibleCell(for: tab)
        }
    }

    func updateProcessInspection() {
        processInspectionUpdates.request { [weak self] in
            self?.evaluateProcessInspection()
        }
    }

    /// True when a visible header or tab icon needs the foreground program.
    private var wantsProgramInfo: Bool {
        needsProcessInspection && TabStripPreferences.inspectsProcesses(
            tracking: iconPreferences.tracking,
            paneCards: hostView.map {
                $0.cardsEnabled && $0.showsPaneHeaders
            } ?? appearanceSettings.paneCardsEnabled,
            iconCount: iconPreferences.iconCount
        )
    }

    private func evaluateProcessInspection() {
        let wanted = wantsProgramInfo
        // Persistent and remote panes: the helper probes after activity.
        // Without visible icons, it uses the slower delay for the busy check
        // and the Sessions window.
        let mode: InfoReportMode = !iconPreferences.tracking ? .off : (wanted ? .live : .background)
        for controller in controllers {
            controller.setRemoteInfoMode(mode)
            if !iconPreferences.tracking {
                controller.updatePaneExecutablePath(nil)
            }
        }
        guard wanted else {
            processTask?.cancel()
            processTask = nil
            processTaskWake = nil
            jobIconResolvers.removeAll()
            return
        }
        scheduleProcessInspectionIfNeeded(probeActiveImmediately: true)
    }

    nonisolated static func localProcessSchedule(
        wantsProgramInfo: Bool,
        panes: [(schedule: ForegroundPollGate.Schedule, hasExecutablePath: Bool)]
    ) -> ForegroundPollGate.Schedule {
        guard wantsProgramInfo else {
            return .idle
        }
        var next: ForegroundPollGate.Schedule = .idle
        for pane in panes {
            switch pane.schedule {
            case .immediate:
                return .immediate
            case .active:
                next = .active
            case .fallback:
                if !pane.hasExecutablePath {
                    next = .active
                } else if next == .idle {
                    next = .fallback
                }
            case .idle:
                if !pane.hasExecutablePath {
                    next = .active
                }
            }
        }
        return next
    }

    nonisolated static func wakeDeadline(
        for schedule: ForegroundPollGate.Schedule,
        now: ContinuousClock.Instant
    ) -> ContinuousClock.Instant? {
        switch schedule {
        case .idle:
            return nil
        case .immediate:
            return now
        case .active:
            return now + .seconds(1)
        case .fallback:
            return now + .seconds(5)
        }
    }

    /// Returns the wake deadline to start or restart the probe task, or `nil`
    /// when the current task should continue unchanged.
    nonisolated static func nextTaskStartWake(
        schedule: ForegroundPollGate.Schedule,
        hasTask: Bool,
        currentWake: ContinuousClock.Instant?,
        probeActiveImmediately: Bool,
        now: ContinuousClock.Instant
    ) -> ContinuousClock.Instant? {
        guard let deadline = wakeDeadline(for: schedule, now: now) else {
            return nil
        }
        if !hasTask {
            return probeActiveImmediately ? now : deadline
        }
        guard let currentWake, deadline < currentWake else {
            return nil
        }
        return deadline
    }

    private func nextLocalProcessSchedule() -> ForegroundPollGate.Schedule {
        let localPanes = controllers.compactMap {
            controller -> (schedule: ForegroundPollGate.Schedule, hasExecutablePath: Bool)? in
            guard
                controller.persistentView == nil,
                let process = controller.terminal?.process, process.running else {
                return nil
            }
            return (controller.foregroundPollGate.schedule, controller.panePresentation.executablePath != nil)
        }
        return Self.localProcessSchedule(wantsProgramInfo: wantsProgramInfo, panes: localPanes)
    }

    /// Starts or shortens the probe task for local pane activity. Skips the
    /// schedule check when a task runs a probe or already wakes in 1 s or less.
    func noteLocalProcessActivity(immediate: Bool) {
        if processTask != nil, !immediate {
            guard let wake = processTaskWake, wake > ContinuousClock.now + .seconds(1) else {
                return
            }
        }
        scheduleProcessInspectionIfNeeded()
    }

    func scheduleProcessInspectionIfNeeded(probeActiveImmediately: Bool = false) {
        guard wantsProgramInfo else {
            return
        }
        let now = ContinuousClock.now
        guard
            let firstWake = Self.nextTaskStartWake(
                schedule: nextLocalProcessSchedule(),
                hasTask: processTask != nil,
                currentWake: processTaskWake,
                probeActiveImmediately: probeActiveImmediately,
                now: now
            ) else {
            return
        }
        startProcessTask(firstWake: firstWake, now: now)
    }

    private func startProcessTask(firstWake: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) {
        processTask?.cancel()
        processTaskGeneration &+= 1
        let generation = processTaskGeneration
        let initialWake: ContinuousClock.Instant? = firstWake > now ? firstWake : nil
        processTaskWake = initialWake
        processTask = Task { [weak self] in
            var nextWake = initialWake
            while !Task.isCancelled {
                if let wake = nextWake {
                    self?.setProcessTaskWake(wake, generation: generation)
                    do {
                        try await Task.sleep(until: wake, clock: .continuous)
                    } catch {
                        return
                    }
                    // A cancel can come after the sleep ends and before the task continues.
                    guard !Task.isCancelled else {
                        return
                    }
                    self?.setProcessTaskWake(nil, generation: generation)
                }
                guard let self else {
                    return
                }
                let probed = await self.inspectForegroundProcesses()
                guard !Task.isCancelled, self.processTaskGeneration == generation else {
                    return
                }
                let schedule = self.nextLocalProcessSchedule()
                let loopNow = ContinuousClock.now
                switch schedule {
                case .idle:
                    self.processTask = nil
                    self.processTaskWake = nil
                    return
                case .immediate:
                    // If no probe ran, sleep before the next probe.
                    nextWake = probed ? nil : loopNow + .seconds(1)
                case .active, .fallback:
                    nextWake = Self.wakeDeadline(for: schedule, now: loopNow)
                }
            }
        }
    }

    private func setProcessTaskWake(_ wake: ContinuousClock.Instant?, generation: UInt64) {
        if processTaskGeneration == generation {
            processTaskWake = wake
        }
    }

    @discardableResult
    private func inspectForegroundProcesses() async -> Bool {
        guard wantsProgramInfo else {
            return false
        }
        // Recheck after each suspension; no process syscalls for hidden groups.
        let panes = controllers
        let probes = panes.map {
            controller -> (descriptor: Int32, shellPID: Int32, token: ForegroundPollGate.ProbeToken)? in
            guard
                controller.persistentView == nil,
                let process = controller.terminal?.process, process.running else {
                return nil
            }
            // Quiet panes keep the last executable path until new output or input.
            guard controller.panePresentation.executablePath == nil || controller.foregroundPollGate.shouldProbe else {
                return nil
            }
            return (process.childfd, process.shellPid, controller.foregroundPollGate.beginProbe())
        }
        guard probes.contains(where: { $0 != nil }) else {
            return false
        }
        let targets = probes.map { probe in
            probe.map { (descriptor: $0.descriptor, shellPID: $0.shellPID) }
        }
        let results = await Task.detached(priority: .utility) {
            let inspector = SystemTerminalProcessInspector()
            return targets.map {
                target -> (snapshot: TerminalForegroundJobSnapshot?, pendingExec: Bool) in
                guard
                    let target,
                    let group = inspector.foregroundProcessGroup(for: target.descriptor) else {
                    return (nil, false)
                }
                let processes = inspector.foregroundProcesses(in: group)
                guard inspector.foregroundProcessGroup(for: target.descriptor) == group else {
                    return (nil, false)
                }
                // Check every member in the foreground group so a held exec in a
                // later pipeline stage (for example `cat x | ./tool`) is found too.
                var pendingExec = false
                if group != target.shellPID, !processes.isEmpty {
                    let shellPath = inspector.executablePath(for: target.shellPID)
                    if let shellPath, !shellPath.isEmpty {
                        pendingExec = processes.contains { member in
                            let match = member.didExec != true && member.executablePath == shellPath
                            return ForegroundPollGate.isPendingExec(
                                shellPID: target.shellPID,
                                shellPath: shellPath,
                                leaderPID: member.processID,
                                leaderPath: member.executablePath,
                                leaderHasChildren: match && inspector.hasChildren(member.processID),
                                leaderDidExec: member.didExec
                            )
                        }
                    }
                }
                return (.init(processGroup: group, processes: processes), pendingExec)
            }
        }.value
        guard !Task.isCancelled, needsProcessInspection else {
            return true
        }
        let liveIDs = Set(controllers.map(\.id))
        jobIconResolvers = jobIconResolvers.filter {
            liveIDs.contains($0.key)
        }
        for (controller, (probe, result)) in zip(panes, zip(probes, results)) {
            guard let probe else {
                continue
            }
            // A pane can start a new process while the check runs.
            guard liveIDs.contains(controller.id) else {
                continue
            }
            // A persistent or remote pane has no local process: the helper
            // reports its foreground program (SessionInfo).
            guard controller.persistentView == nil else {
                continue
            }
            let currentProcess = controller.terminal?.process
            let currentDescriptor = currentProcess?.running == true ? currentProcess?.childfd : nil
            guard probe.descriptor == currentDescriptor else {
                continue
            }
            // A probe cancelled before this line does not settle the gate.
            // A probe from before a process restart can pass the descriptor
            // check when the new PTY gets the same descriptor number. Then
            // `record` rejects the token, and the result is stale.
            guard controller.foregroundPollGate.record(probe.token, pendingExec: result.pendingExec) else {
                continue
            }
            var resolver = jobIconResolvers[controller.id] ?? TerminalForegroundJobIconResolver()
            let path = resolver.executablePath(for: result.snapshot, descriptor: probe.descriptor)
            jobIconResolvers[controller.id] = resolver
            controller.updatePaneExecutablePath(path)
        }
        return true
    }

    func contains(_ controller: TerminalSessionController) -> Bool {
        controllers.contains {
            $0 === controller
        }
    }

    private func bumpRevision() {
        hostView?.snapshotDividerPositionsIfSynchronized()
        revision += 1
    }

    private func selectSplit(offset: Int) {
        let controllers = controllers
        guard
            controllers.count > 1,
            let currentIndex = controllers.firstIndex(where: {
                $0.id == focusedControllerID
            }) else {
            return
        }
        let nextIndex = (currentIndex + offset + controllers.count) % controllers.count
        let next = controllers[nextIndex]
        markFocused(next)
        if zoomedControllerID != nil {
            zoomedControllerID = next.id
            bumpRevision()
        }
        next.requestFocus()
    }

    private func collectControllers(in node: TerminalPaneNode) -> [TerminalSessionController] {
        switch node.content {
        case .terminal(let controller):
            return [controller]
        case .split(_, let first, let second):
            return collectControllers(in: first) + collectControllers(in: second)
        }
    }

    private func findNode(
        for controller: TerminalSessionController,
        in node: TerminalPaneNode
    ) -> TerminalPaneNode? {
        switch node.content {
        case .terminal(let candidate):
            return candidate === controller ? node : nil
        case .split(_, let first, let second):
            return findNode(for: controller, in: first) ?? findNode(for: controller, in: second)
        }
    }

    private func remove(
        _ controller: TerminalSessionController,
        from node: TerminalPaneNode
    ) -> Bool {
        guard case .split(_, let first, let second) = node.content else {
            return false
        }

        if isTerminal(controller, in: first) {
            promote(second, into: node)
            return true
        }
        if isTerminal(controller, in: second) {
            promote(first, into: node)
            return true
        }
        return remove(controller, from: first) || remove(controller, from: second)
    }

    /// Picks the closest pane visually before the closing pane, preferring its
    /// own split axis first and falling back to panes after it when none precede it.
    private func successorAfterClosing(_ controller: TerminalSessionController) -> TerminalSessionController? {
        var frames: [(controller: TerminalSessionController, rect: CGRect)] = []
        layoutFrames(in: root, rect: CGRect(x: 0, y: 0, width: 1, height: 1), frames: &frames)
        let sourceFrame = frames.first {
            $0.controller === controller
        }?.rect
        guard let source = sourceFrame else {
            return nil
        }
        let candidates = frames.filter {
            $0.controller !== controller
        }
        let directions: [TerminalPaneDirection] = parentSplitOrientation(for: controller, in: root) == .horizontal
            ? [.up, .left, .down, .right]
            : [.left, .up, .right, .down]
        for direction in directions {
            if
                let match = Self.closestPane(
                    in: direction,
                    from: source,
                    among: candidates,
                    tolerance: 1e-5,
                    primaryQuantum: 1e-5,
                    tieBreak: .closeSuccessor
                ) {
                return match
            }
        }
        return nil
    }

    private func layoutFrames(
        in node: TerminalPaneNode,
        rect: CGRect,
        frames: inout [(controller: TerminalSessionController, rect: CGRect)]
    ) {
        switch node.content {
        case .terminal(let controller):
            frames.append((controller, rect))
        case .split(let orientation, let first, let second):
            let rawFraction = (hostView != nil
                ? hostView?.layoutDividerFraction(for: node.id)
                : restoredDividerFractions[node.id]) ?? 0.5
            let fraction = rawFraction.isFinite ? min(max(rawFraction, 0), 1) : 0.5
            switch orientation {
            case .vertical:
                let splitX = rect.minX + rect.width * fraction
                let firstRect = CGRect(x: rect.minX, y: rect.minY, width: splitX - rect.minX, height: rect.height)
                let secondRect = CGRect(x: splitX, y: rect.minY, width: rect.maxX - splitX, height: rect.height)
                layoutFrames(in: first, rect: firstRect, frames: &frames)
                layoutFrames(in: second, rect: secondRect, frames: &frames)
            case .horizontal:
                let splitY = rect.minY + rect.height * (1 - fraction)
                let firstRect = CGRect(x: rect.minX, y: splitY, width: rect.width, height: rect.maxY - splitY)
                let secondRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: splitY - rect.minY)
                layoutFrames(in: first, rect: firstRect, frames: &frames)
                layoutFrames(in: second, rect: secondRect, frames: &frames)
            }
        }
    }

    private func parentSplitOrientation(
        for controller: TerminalSessionController,
        in node: TerminalPaneNode
    ) -> TerminalPaneSplit? {
        guard case .split(let orientation, let first, let second) = node.content else {
            return nil
        }
        if isTerminal(controller, in: first) || isTerminal(controller, in: second) {
            return orientation
        }
        return parentSplitOrientation(for: controller, in: first)
            ?? parentSplitOrientation(for: controller, in: second)
    }

    enum PaneNeighborTieBreak {
        /// Prefer the pane immediately preceding in visual reading order for
        /// "before" directions (bottom/right), and top/left for "after" directions.
        case closeSuccessor
        /// Prefer top/left (tree order) on ties.
        case navigation
    }

    private struct PaneNeighborRank: Comparable {
        let primary: Int64
        let secondary: Int64
        let tieBreaker: CGFloat

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.primary != rhs.primary {
                return lhs.primary < rhs.primary
            }
            if lhs.secondary != rhs.secondary {
                return lhs.secondary < rhs.secondary
            }
            return lhs.tieBreaker < rhs.tieBreaker
        }
    }

    /// Finds the closest visible pane in `direction` from `source`.
    /// Shared by close-successor selection and directional keyboard navigation.
    static func closestPane(
        in direction: TerminalPaneDirection,
        from source: CGRect,
        among candidates: [(controller: TerminalSessionController, rect: CGRect)],
        tolerance: CGFloat,
        primaryQuantum: CGFloat,
        tieBreak: PaneNeighborTieBreak
    ) -> TerminalSessionController? {
        let matching = candidates.filter {
            isInDirection($0.rect, from: source, direction: direction, tolerance: tolerance)
        }
        guard
            let minPrimary = matching.map({
                primaryDistance(of: $0.rect, from: source, direction: direction)
            }).min() else {
            return nil
        }
        return matching.min { lhs, rhs in
            neighborRank(
                of: lhs.rect,
                from: source,
                direction: direction,
                minPrimary: minPrimary,
                primaryQuantum: primaryQuantum,
                secondaryQuantum: tolerance,
                tieBreak: tieBreak
            )
                < neighborRank(
                    of: rhs.rect,
                    from: source,
                    direction: direction,
                    minPrimary: minPrimary,
                    primaryQuantum: primaryQuantum,
                    secondaryQuantum: tolerance,
                    tieBreak: tieBreak
                )
        }?.controller
    }

    private static func isInDirection(
        _ candidate: CGRect,
        from source: CGRect,
        direction: TerminalPaneDirection,
        tolerance: CGFloat
    ) -> Bool {
        guard candidate.width > tolerance, candidate.height > tolerance else {
            return false
        }
        switch direction {
        case .up:
            return candidate.minY >= source.maxY - tolerance
                && candidate.maxX > source.minX + tolerance
                && candidate.minX < source.maxX - tolerance
        case .down:
            return candidate.maxY <= source.minY + tolerance
                && candidate.maxX > source.minX + tolerance
                && candidate.minX < source.maxX - tolerance
        case .left:
            return candidate.maxX <= source.minX + tolerance
                && candidate.maxY > source.minY + tolerance
                && candidate.minY < source.maxY - tolerance
        case .right:
            return candidate.minX >= source.maxX - tolerance
                && candidate.maxY > source.minY + tolerance
                && candidate.minY < source.maxY - tolerance
        }
    }

    private static func primaryDistance(
        of candidate: CGRect,
        from source: CGRect,
        direction: TerminalPaneDirection
    ) -> CGFloat {
        switch direction {
        case .up:
            max(0, candidate.minY - source.maxY)
        case .down:
            max(0, source.minY - candidate.maxY)
        case .left:
            max(0, source.minX - candidate.maxX)
        case .right:
            max(0, candidate.minX - source.maxX)
        }
    }

    private static func neighborRank(
        of candidate: CGRect,
        from source: CGRect,
        direction: TerminalPaneDirection,
        minPrimary: CGFloat,
        primaryQuantum: CGFloat,
        secondaryQuantum: CGFloat,
        tieBreak: PaneNeighborTieBreak
    ) -> PaneNeighborRank {
        let primary = max(0, primaryDistance(of: candidate, from: source, direction: direction) - minPrimary)
        let secondary: CGFloat
        let tieBreaker: CGFloat
        switch direction {
        case .up:
            secondary = abs(candidate.midX - source.midX)
            tieBreaker = tieBreak == .closeSuccessor ? -candidate.minX : candidate.minX
        case .down:
            secondary = abs(candidate.midX - source.midX)
            tieBreaker = candidate.minX
        case .left:
            secondary = abs(candidate.midY - source.midY)
            tieBreaker = tieBreak == .closeSuccessor ? candidate.maxY : -candidate.maxY
        case .right:
            secondary = abs(candidate.midY - source.midY)
            tieBreaker = -candidate.maxY
        }
        return PaneNeighborRank(
            primary: quantized(primary, quantum: primaryQuantum),
            secondary: quantized(secondary, quantum: secondaryQuantum),
            tieBreaker: tieBreaker
        )
    }

    private static func quantized(_ value: CGFloat, quantum: CGFloat) -> Int64 {
        guard value.isFinite, quantum > 0 else {
            return .max
        }
        let scaled = (value / quantum).rounded()
        if scaled >= CGFloat(Int64.max) {
            return .max
        }
        if scaled <= CGFloat(Int64.min) {
            return .min
        }
        return Int64(scaled)
    }

    /// The outer edge of the pane in its parent split: the edge away from
    /// the sibling that takes its space.
    private func removalEdge(
        for controller: TerminalSessionController,
        in node: TerminalPaneNode
    ) -> TerminalPaneDirection? {
        guard case .split(let orientation, let first, let second) = node.content else {
            return nil
        }
        if isTerminal(controller, in: first) {
            return orientation == .vertical ? .left : .up
        }
        if isTerminal(controller, in: second) {
            return orientation == .vertical ? .right : .down
        }
        return removalEdge(for: controller, in: first) ?? removalEdge(for: controller, in: second)
    }

    private func promote(_ survivor: TerminalPaneNode, into node: TerminalPaneNode) {
        if case .split = survivor.content {
            if let fraction = restoredDividerFractions.removeValue(forKey: survivor.id) {
                restoredDividerFractions[node.id] = fraction
            } else {
                restoredDividerFractions.removeValue(forKey: node.id)
            }
            hostView?.transferDividerPosition(from: survivor.id, to: node.id)
        } else {
            restoredDividerFractions.removeValue(forKey: node.id)
            hostView?.invalidateDividerPosition(for: node.id)
        }
        node.content = survivor.content
    }

    private func isTerminal(
        _ controller: TerminalSessionController,
        in node: TerminalPaneNode
    ) -> Bool {
        guard case .terminal(let candidate) = node.content else {
            return false
        }
        return candidate === controller
    }
}

struct TerminalPaneContainer: NSViewRepresentable {
    let workspace: TerminalPaneWorkspace
    let revision: Int
    var appearanceSettings = GlobalAppearanceSettings()

    func makeNSView(context: Context) -> TerminalPaneHostView {
        let view = TerminalPaneHostView(workspace: workspace)
        view.synchronize(revision: revision, settings: appearanceSettings)
        return view
    }

    func updateNSView(_ nsView: TerminalPaneHostView, context: Context) {
        nsView.synchronize(revision: revision, settings: appearanceSettings)
    }
}

#Preview("Terminal Pane") {
    @Previewable @State var workspace = TerminalPaneWorkspace(startsProcesses: false)

    TerminalPaneContainer(
        workspace: workspace,
        revision: workspace.revision
    )
    .frame(width: 720, height: 420)
}

final class TerminalPaneHostView: NSView, NSSplitViewDelegate {
    /// Window hosts complete only missing chrome margins; standalone hosts inset every edge.
    var windowCardInsets: TerminalPaneCardInsets? {
        didSet {
            guard oldValue != windowCardInsets else {
                return
            }
            updateCardMetrics()
            needsLayout = true
        }
    }
    /// Window hosts paint one backdrop behind chrome and panes, avoiding doubled opacity.
    var usesWindowBackdrop = false {
        didSet {
            if oldValue != usesWindowBackdrop {
                refreshBackdrop()
            }
        }
    }
    var onCardLayout: ((TerminalPaneHostView) -> Void)?
    /// Comfortable Right/hidden layouts use pane headers as their window titlebar.
    var requiresWindowHeader = false {
        didSet {
            if oldValue != requiresWindowHeader {
                refreshAppearance()
                needsLayout = true
            }
        }
    }
    var showsPaneHeaders: Bool {
        workspace.appearanceSettings.paneCardsEnabled || requiresWindowHeader
    }
    var windowShowsDesktopBlur = false
    let workspace: TerminalPaneWorkspace
    private let backdropView = TerminalWorkspaceBackdropView(frame: .zero)
    /// False when the settings turn off the cards, when the window has one
    /// pane, or when the window is too small for the card decorations.
    private(set) var cardsEnabled = false
    /// The pane style of the views on screen. The settings can change
    /// before the views apply it.
    private(set) var appliedPaneStyle = GlobalAppearanceSettings.PaneStyle.comfortable
    private var appearanceObserver: NSObjectProtocol?
    private var systemColorsObserver: NSObjectProtocol?
    private var displayedRevision = -1
    private var isRebuilding = false
    private var paneViews: [UUID: TerminalPaneCardView] = [:]
    private var splitViews: [UUID: TerminalWorkspaceSplitView] = [:]
    private var dividerFractions: [UUID: CGFloat] = [:]
    /// Live divider fractions snapshotted before a same-turn mutation, including
    /// 0 and 1 for collapsed panes. Used only by close-successor geometry.
    private var geometryDividerFractions: [UUID: CGFloat] = [:]
    private var pendingDividerTransfers: [(from: UUID?, to: UUID)] = []
    private var unzoomedPaneFrames: [UUID: CGRect] = [:]
    private var needsDividerRestore = false
    /// The view of the pane tree.
    private var rootView: NSView?
    /// Shows the card of a closed pane while it shrinks. It is above the
    /// pane tree and takes no clicks.
    private let transitionOverlay = TerminalTransitionOverlayView(frame: .zero)
    /// The card frames in host coordinates before a close. The workspace
    /// records them before it changes the tree.
    private var preparedStartFrames: [UUID: CGRect]?
    private var preparedClosedCard: TerminalPaneCardView?
    /// The transition that starts when the host draws. AppKit attaches the
    /// layers of new views to the layer tree in the display pass, after the
    /// layout pass that makes the views. An animation on a layer that is not
    /// attached has no effect.
    private var scheduledTransition: (transition: TerminalPaneTransition, startFrames: [UUID: CGRect])?
    /// The cards that a transition animates now.
    private var animatingCards: [TerminalPaneCardView] = []
    /// The card of the closed pane, in the overlay, until it has shrunk.
    private var closedCard: TerminalPaneCardView?
    private var transitionGeneration = 0
    static let transitionDuration: CFTimeInterval = 0.22

    init(workspace: TerminalPaneWorkspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        // The transitions convert rectangles through the layer tree.
        wantsLayer = true
        clipsToBounds = false
        workspace.hostView = self
        if let fractions = workspace.takeRestoredDividerFractions() {
            dividerFractions = fractions
            needsDividerRestore = !fractions.isEmpty
        }
        addSubview(backdropView)
        transitionOverlay.autoresizingMask = [.width, .height]
        addSubview(transitionOverlay)
        appearanceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAppearance()
            }
        }
        systemColorsObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAppearance()
            }
        }
        observeFocus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let systemColorsObserver {
            NotificationCenter.default.removeObserver(systemColorsObserver)
        }
        if let appearanceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appearanceObserver)
        }
    }

    var showsDesktopBlur: Bool {
        usesWindowBackdrop ? windowShowsDesktopBlur : backdropView.showsDesktopBlur
    }

    func synchronize(
        revision: Int,
        settings: GlobalAppearanceSettings = GlobalAppearanceSettings()
    ) {
        let settingsChanged = workspace.appearanceSettings != settings
        workspace.appearanceSettings = settings
        if displayedRevision != revision {
            displayedRevision = revision
            // Rebuild first. The new card metrics then apply only to the new
            // tree, and each terminal gets one resize.
            rebuild()
        } else if settingsChanged {
            refreshAppearance()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size {
            stopTransitionAnimations()
        }
        super.setFrameSize(newSize)
        // A smaller window can have no space for the card decorations.
        updateCardMetrics()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        // The display pass has attached the layers of the new cards.
        if let scheduled = scheduledTransition {
            scheduledTransition = nil
            runTransition(scheduled.transition, from: scheduled.startFrames)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        workspace.updateProcessInspection()
    }

    override func layout() {
        super.layout()
        backdropView.frame = bounds
        transitionOverlay.frame = bounds
        rootView?.frame = contentFrame
        if needsDividerRestore, !bounds.isEmpty {
            needsDividerRestore = false
            restoreDividerPositions(in: workspace.root)
        }
        rootView?.layoutSubtreeIfNeeded()
        onCardLayout?(self)
    }

    /// Only the visible tree participates, so zoom and pane removal update window controls.
    var visibleCards: [TerminalPaneCardView] {
        Array(paneViews.values)
    }

    private var contentFrame: NSRect {
        guard cardsEnabled else {
            return bounds
        }
        return cardInsets.frame(in: bounds)
    }

    private var cardInsets: TerminalPaneCardInsets {
        windowCardInsets ?? .uniform(paneStyle.spacing)
    }

    /// Applies the settings, the theme colors and the accessibility options
    /// to the backdrop and to all cards. Each card compares its state and
    /// does no work when nothing changed.
    func refreshAppearance() {
        // A new terminal applies its profile while rebuild() makes it. The
        // tree is not complete at that time, so rebuild() calls this method
        // when it is done.
        guard !isRebuilding else {
            return
        }
        updateCardMetrics()
        refreshBackdrop()
        for card in paneViews.values {
            card.showsHeader = showsPaneHeaders
            card.refreshAppearance()
        }
        workspace.updateWindowTransparency()
        workspace.updateProcessInspection()
    }

    private func refreshBackdrop() {
        let theme = workspace.focusedController?.effectiveTheme ?? .fallback
        backdropView.update(
            visible: !usesWindowBackdrop && cardsEnabled && appliedPaneStyle.showsDecorations,
            backdrop: workspace.appearanceSettings.paneCardsBackdrop,
            appearance: ResolvedWorkspaceAppearance(theme: theme),
            opacity: workspace.controllers.map(\.effectiveBackgroundOpacity).min() ?? 1
        )
    }

    /// The backdrop uses the theme of the focused pane. The cards observe
    /// the focus themselves.
    private func observeFocus() {
        withObservationTracking {
            _ = workspace.focusedControllerID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.refreshBackdrop()
                self.observeFocus()
            }
        }
    }

    /// Keeps single and split panes decorated whenever their minimum content fits.
    private func wantsCards() -> Bool {
        guard workspace.paneCount > 0 else {
            return false
        }
        // The host has no size before its first layout. Use the settings
        // until then, so that a new tree does not change its metrics twice.
        guard !bounds.isEmpty else {
            return true
        }
        let minimum = minimumContentSize(cards: true)
        let insets = cardInsets
        return minimum.width + insets.left + insets.right <= bounds.width
            && minimum.height + insets.top + insets.bottom <= bounds.height
    }

    /// The pane style in the settings.
    private var paneStyle: GlobalAppearanceSettings.PaneStyle {
        workspace.appearanceSettings.paneStyle
    }

    private func updateCardMetrics() {
        let wanted = wantsCards()
        let style = paneStyle
        guard wanted != cardsEnabled || style != appliedPaneStyle else {
            return
        }
        // The frames change, so the animations have the wrong end values.
        stopTransitionAnimations()
        saveDividerPositions()
        cardsEnabled = wanted
        appliedPaneStyle = style
        for split in splitViews.values {
            split.cardsEnabled = wanted
            split.paneStyle = style
        }
        for card in paneViews.values {
            card.cardsEnabled = wanted
            card.showsHeader = showsPaneHeaders
        }
        refreshBackdrop()
        workspace.updateWindowTransparency()
        needsDividerRestore = true
        needsLayout = true
    }

    private func rebuild() {
        isRebuilding = true
        let transition = workspace.pendingTransition
        workspace.pendingTransition = nil
        // The rebuild discards the cards, so do not restore their appearance.
        stopTransitionAnimations(restoresCards: false)
        let startFrames = transition != nil && transitionsAllowed
            ? (preparedStartFrames ?? currentCardFrames()) : nil
        let closing = preparedClosedCard
        preparedStartFrames = nil
        preparedClosedCard = nil
        saveDividerPositions()
        geometryDividerFractions.removeAll()
        for transfer in pendingDividerTransfers {
            if let from = transfer.from {
                dividerFractions[transfer.to] = dividerFractions.removeValue(forKey: from)
            } else {
                dividerFractions.removeValue(forKey: transfer.to)
            }
        }
        pendingDividerTransfers.removeAll()
        let activeSplitIDs = splitNodeIDs(in: workspace.root)
        dividerFractions = dividerFractions.filter {
            activeSplitIDs.contains($0.key)
        }
        if workspace.zoomedControllerID != nil, !paneViews.isEmpty, !splitViews.isEmpty {
            unzoomedPaneFrames = currentCardFrames()
        }
        // Removing a focused terminal does not always make AppKit resign it.
        // Clear the first responder first so the old pane sends focus-out.
        if
            let terminal = window?.firstResponder as? NSView,
            terminal is AppTerminalView || terminal is RemoteTerminalView,
            terminal.isDescendant(of: self) {
            window?.makeFirstResponder(nil)
        }
        // Move the card of the closed pane to the overlay. Do not call
        // removeFromSuperview() first: addSubview() alone keeps the terminal
        // in the window, so that the card continues to show its content.
        if case .removed(let id, _)? = transition, let closing, let frame = startFrames?[id] {
            closing.frame = frame
            closing.autoresizingMask = []
            transitionOverlay.addSubview(closing)
            closedCard = closing
        }
        rootView?.removeFromSuperview()
        paneViews.removeAll()
        splitViews.removeAll()
        // Set the metrics before the new views exist. The old tree then keeps
        // its metrics, and the new tree gets its final layout at once.
        cardsEnabled = wantsCards()
        appliedPaneStyle = paneStyle
        let newRoot: NSView
        if
            let zoomedID = workspace.zoomedControllerID,
            let controller = workspace.controllers.first(where: {
                $0.id == zoomedID
            }) {
            newRoot = makeTerminalView(for: controller)
        } else {
            newRoot = makeView(for: workspace.root)
            needsDividerRestore = !dividerFractions.isEmpty
            unzoomedPaneFrames.removeAll()
        }
        newRoot.frame = contentFrame
        newRoot.autoresizingMask = [.width, .height]
        addSubview(newRoot, positioned: .above, relativeTo: backdropView)
        rootView = newRoot
        isRebuilding = false
        refreshAppearance()
        if needsDividerRestore, !bounds.isEmpty {
            newRoot.layoutSubtreeIfNeeded()
            restoreDividerPositions(in: workspace.root)
            needsDividerRestore = false
        }
        if let transition, let startFrames {
            // SwiftUI calls this method in the layout pass. Start the
            // animations in the display pass that follows.
            scheduledTransition = (transition, startFrames)
            needsDisplay = true
            // If the window does not draw in this cycle, do not keep the
            // card of the closed pane.
            let generation = transitionGeneration
            DispatchQueue.main.async { [weak self] in
                guard
                    let self, self.transitionGeneration == generation,
                    self.scheduledTransition != nil else {
                    return
                }
                self.stopTransitionAnimations()
            }
        }

        // Reattaching a terminal view clears AppKit's first responder. Ask
        // for focus after the new split hierarchy is in the window.
        workspace.focusedController?.requestFocus()
    }

    // MARK: Transitions

    /// Records the card frames before the workspace removes a pane. The
    /// next rebuild animates from these frames.
    func prepareRemovalTransition(for controller: TerminalSessionController) {
        stopTransitionAnimations()
        preparedStartFrames = currentCardFrames()
        preparedClosedCard = paneViews[controller.id]
    }

    /// Forgets a prepared transition and stops the current transition.
    func cancelTransition() {
        preparedStartFrames = nil
        preparedClosedCard = nil
        stopTransitionAnimations()
    }

    /// True from the rebuild that starts a transition until the transition
    /// ends.
    var isRunningTransition: Bool {
        scheduledTransition != nil || !animatingCards.isEmpty || closedCard != nil
    }

    /// False when nobody can see the animation: the window is not on the
    /// screen (for example, a tab that is not selected), a pane is zoomed,
    /// or Reduce Motion is on.
    var transitionsAllowed: Bool {
        guard let window, window.isVisible, window.occlusionState.contains(.visible) else {
            return false
        }
        return !bounds.isEmpty && workspace.zoomedControllerID == nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func currentCardFrames() -> [UUID: CGRect] {
        paneViews.mapValues {
            $0.convert($0.bounds, to: self)
        }
    }

    /// The zero-size rectangle at one edge of a rectangle, in host
    /// coordinates. The host is not flipped, thus "up" is the maximum Y.
    static func edgeRect(of rect: CGRect, at edge: TerminalPaneDirection) -> CGRect {
        switch edge {
        case .right:
            CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
        case .left:
            CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
        case .up:
            CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: 0)
        case .down:
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0)
        }
    }

    /// Animates the cards from their earlier frames to their frames in the
    /// new tree. Only the layers move: each terminal has its final size
    /// before the animation starts, so the shell gets one resize.
    private func runTransition(_ transition: TerminalPaneTransition, from startFrames: [UUID: CGRect]) {
        var moves: [(card: TerminalPaneCardView, from: CGRect, to: CGRect)] = []
        for (id, card) in paneViews {
            let final = card.convert(card.bounds, to: self)
            let start: CGRect
            if case .added(let addedID, let edge) = transition, addedID == id {
                start = Self.edgeRect(of: final, at: edge)
            } else if let old = startFrames[id] {
                start = old
            } else {
                continue
            }
            if start != final {
                moves.append((card, start, final))
            }
        }
        if case .removed(let id, let edge) = transition, let closedCard, let old = startFrames[id] {
            moves.append((closedCard, old, Self.edgeRect(of: old, at: edge)))
        }
        guard !moves.isEmpty else {
            stopTransitionAnimations()
            return
        }
        transitionGeneration += 1
        let generation = transitionGeneration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for move in moves {
            move.card.beginTransition()
        }
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                self?.finishTransition(generation)
            }
        }
        for move in moves {
            animate(move.card, from: move.from, to: move.to, holdsEnd: move.card === closedCard)
            if move.card !== closedCard {
                animatingCards.append(move.card)
            }
        }
        CATransaction.commit()
    }

    /// Adds the animations of one card. The rectangles are in host
    /// coordinates. The content stays at the size of the view, and its top
    /// left corner stays at the top left corner of the card.
    private func animate(_ card: TerminalPaneCardView, from start: CGRect, to end: CGRect, holdsEnd: Bool) {
        guard
            let layer = card.layer, let from = layerRect(start, for: card),
            let to = layerRect(end, for: card) else {
            return
        }
        let size = card.bounds.size
        let anchor = layer.anchorPoint
        func position(_ rect: CGRect) -> CGPoint {
            CGPoint(x: rect.minX + anchor.x * rect.width, y: rect.minY + anchor.y * rect.height)
        }
        func bounds(_ rect: CGRect) -> CGRect {
            CGRect(x: 0, y: card.isFlipped ? 0 : size.height - rect.height, width: rect.width, height: rect.height)
        }
        let timing = CAMediaTimingFunction(name: .easeOut)
        for (key, fromValue, toValue) in [
            ("position", NSValue(point: position(from)), NSValue(point: position(to))),
            ("bounds", NSValue(rect: bounds(from)), NSValue(rect: bounds(to)))
        ] {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = fromValue
            animation.toValue = toValue
            animation.duration = Self.transitionDuration
            animation.timingFunction = timing
            if holdsEnd {
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
            }
            layer.add(animation, forKey: "paneTransition." + key)
        }
    }

    /// Converts a rectangle in host coordinates to the coordinates of the
    /// frame of the card layer. A view without a layer (NSSplitView) puts
    /// the layers of its subviews in the layer of the nearest ancestor that
    /// has a layer. AppKit can attach the layer later, so do not use the
    /// superlayer. The ancestor layer uses the coordinates of its view.
    func layerRect(_ rect: CGRect, for card: NSView) -> CGRect? {
        var ancestor = card.superview
        while let view = ancestor, view.layer == nil {
            ancestor = view.superview
        }
        guard let ancestor else {
            return nil
        }
        return convert(rect, to: ancestor)
    }

    private func finishTransition(_ generation: Int) {
        guard generation == transitionGeneration else {
            return
        }
        stopTransitionAnimations()
    }

    /// Stops the scheduled transition and the animations. The cards go to
    /// their final frames, and the card of the closed pane goes away.
    private func stopTransitionAnimations(restoresCards: Bool = true) {
        transitionGeneration += 1
        scheduledTransition = nil
        for card in animatingCards {
            card.layer?.removeAnimation(forKey: "paneTransition.position")
            card.layer?.removeAnimation(forKey: "paneTransition.bounds")
            if restoresCards {
                card.endTransition()
            }
        }
        animatingCards.removeAll()
        if let closedCard {
            closedCard.layer?.removeAllAnimations()
            closedCard.removeFromSuperview()
            self.closedCard = nil
        }
    }

    func selectSplit(in direction: TerminalPaneDirection) {
        guard
            let focused = workspace.focusedController,
            let source = paneViews[focused.id] else {
            return
        }

        let sourceFrame = unzoomedPaneFrames[focused.id] ?? source.convert(source.bounds, to: self)
        let candidates = workspace.controllers.compactMap { controller -> (TerminalSessionController, CGRect)? in
            guard controller !== focused else {
                return nil
            }
            if let frame = unzoomedPaneFrames[controller.id] {
                return (controller, frame)
            }
            guard let pane = paneViews[controller.id] else {
                return nil
            }
            return (controller, pane.convert(pane.bounds, to: self))
        }
        guard
            let target = TerminalPaneWorkspace.closestPane(
                in: direction,
                from: sourceFrame,
                among: candidates,
                tolerance: 0.5,
                primaryQuantum: 2,
                tieBreak: .navigation
            ) else {
            if
                workspace.zoomedControllerID != nil, splitViews.isEmpty,
                unzoomedPaneFrames.count < workspace.paneCount {
                switch direction {
                case .up, .left:
                    workspace.selectPreviousSplit()
                case .down, .right:
                    workspace.selectNextSplit()
                }
            }
            return
        }
        workspace.markFocused(target)
        workspace.zoomSelectedSplit(target)
        target.requestFocus()
    }

    func equalizeSplits() {
        stopTransitionAnimations()
        equalizeSplits(in: rootView)
    }

    func moveDivider(in direction: TerminalPaneDirection) {
        guard
            let focused = workspace.focusedController,
            let pane = paneViews[focused.id],
            let splitView = nearestSplitView(for: pane, direction: direction) else {
            return
        }
        stopTransitionAnimations()

        let movesAlongHorizontalAxis = direction == .left || direction == .right
        let cellSize = terminalCellSize(for: focused, horizontal: movesAlongHorizontalAxis)
        let delta: CGFloat
        switch direction {
        case .up:
            delta = -cellSize
        case .down:
            delta = cellSize
        case .left:
            delta = -cellSize
        case .right:
            delta = cellSize
        }
        // Do not move the divider when the two panes do not fit.
        guard let limits = dividerLimits(in: splitView) else {
            return
        }

        let firstPane = splitView.arrangedSubviews[0]
        let position = movesAlongHorizontalAxis ? firstPane.frame.width : firstPane.frame.height
        splitView.setPosition(min(max(position + delta, limits.lowerBound), limits.upperBound), ofDividerAt: 0)
        splitView.adjustSubviews()
    }

    private func makeView(for node: TerminalPaneNode) -> NSView {
        switch node.content {
        case .terminal(let controller):
            return makeTerminalView(for: controller)
        case .split(let orientation, let first, let second):
            let splitView = TerminalWorkspaceSplitView(frame: .zero)
            splitView.paneNode = node
            splitView.cardsEnabled = cardsEnabled
            splitView.paneStyle = appliedPaneStyle
            splitView.isVertical = orientation == .vertical
            splitView.dividerStyle = .thin
            splitView.delegate = self
            splitView.addArrangedSubview(makeView(for: first))
            splitView.addArrangedSubview(makeView(for: second))
            splitViews[node.id] = splitView
            return splitView
        }
    }

    private func makeTerminalView(for controller: TerminalSessionController) -> NSView {
        // The container supplies the terminal's Auto Layout constraints.
        // NSSplitView must size the container, not the terminal itself.
        let view = TerminalSessionContainerView(
            terminal: controller.makeTerminalView(),
            padding: terminalPadding.points,
            top: terminalPadding.topPoints(cardsEnabled: cardsEnabled)
        )
        let card = TerminalPaneCardView(controller: controller, content: view, cardsEnabled: cardsEnabled)
        card.showsHeader = showsPaneHeaders
        paneViews[controller.id] = card
        return card
    }

    private func liveDividerFraction(in splitView: NSSplitView) -> CGFloat? {
        guard splitView.arrangedSubviews.count == 2 else {
            return nil
        }
        let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let available = length - splitView.dividerThickness
        guard available > 0 else {
            return nil
        }
        let first = splitView.arrangedSubviews[0]
        let second = splitView.arrangedSubviews[1]
        let firstLength = splitView.isVertical ? first.frame.width : first.frame.height
        let secondLength = splitView.isVertical ? second.frame.width : second.frame.height
        // A split view whose subviews have no layout yet keeps its earlier fraction.
        guard firstLength > 0 || secondLength > 0 else {
            return nil
        }
        return min(max(firstLength / available, 0), 1)
    }

    private func saveDividerPositions() {
        for (id, splitView) in splitViews {
            // A first pane with no length can be a layout in progress, so it
            // keeps its earlier fraction. Only the geometry query reads it as 0.
            guard let fraction = liveDividerFraction(in: splitView), fraction > 0 else {
                continue
            }
            dividerFractions[id] = fraction
        }
    }

    func snapshotDividerPositionsIfSynchronized() {
        guard displayedRevision == workspace.revision else {
            return
        }
        saveDividerPositions()
        if !splitViews.isEmpty {
            geometryDividerFractions.removeAll()
            for (id, splitView) in splitViews {
                if let fraction = liveDividerFraction(in: splitView) {
                    geometryDividerFractions[id] = fraction
                }
            }
        }
    }

    private func resolvedTransferID(for id: UUID) -> UUID? {
        var resolvedID: UUID? = id
        for transfer in pendingDividerTransfers.reversed() where transfer.to == resolvedID {
            resolvedID = transfer.from
        }
        return resolvedID
    }

    /// The size of the first pane of a split over the available length, for
    /// persistence and restoration. Keeps the saved fraction when a split view
    /// has no positive first-pane length yet (for example during layout).
    func dividerFraction(for id: UUID) -> CGFloat? {
        if displayedRevision != workspace.revision {
            guard let resolvedID = resolvedTransferID(for: id) else {
                return nil
            }
            return dividerFractions[resolvedID]
        }
        if let splitView = splitViews[id], let live = liveDividerFraction(in: splitView), live > 0 {
            return live
        }
        return dividerFractions[id]
    }

    /// The current visual fraction of a split for pane-closing geometry.
    /// Unlike `dividerFraction(for:)`, preserves 0 and 1 for collapsed panes
    /// across same-turn closes.
    func layoutDividerFraction(for id: UUID) -> CGFloat? {
        if displayedRevision != workspace.revision {
            guard let resolvedID = resolvedTransferID(for: id) else {
                return nil
            }
            return geometryDividerFractions[resolvedID] ?? dividerFractions[resolvedID]
        }
        if let splitView = splitViews[id], let live = liveDividerFraction(in: splitView) {
            return live
        }
        return dividerFractions[id]
    }

    func transferDividerPosition(from oldID: UUID, to newID: UUID) {
        snapshotDividerPositionsIfSynchronized()
        pendingDividerTransfers.append((from: oldID, to: newID))
    }

    func invalidateDividerPosition(for id: UUID) {
        snapshotDividerPositionsIfSynchronized()
        pendingDividerTransfers.append((from: nil, to: id))
    }

    private func splitNodeIDs(in node: TerminalPaneNode) -> Set<UUID> {
        guard case .split(_, let first, let second) = node.content else {
            return []
        }
        return Set([node.id]).union(splitNodeIDs(in: first)).union(splitNodeIDs(in: second))
    }

    private func restoreDividerPositions(in node: TerminalPaneNode) {
        guard
            case .split(_, let first, let second) = node.content,
            let splitView = splitViews[node.id] else {
            return
        }
        splitView.layoutSubtreeIfNeeded()
        if let fraction = dividerFractions[node.id] {
            let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            let available = length - splitView.dividerThickness
            if available > 0 {
                splitView.setPosition(available * fraction, ofDividerAt: 0)
            }
        }
        restoreDividerPositions(in: first)
        restoreDividerPositions(in: second)
    }

    private func equalizeSplits(in view: NSView?) {
        guard let view else {
            return
        }
        if let splitView = view as? NSSplitView, splitView.arrangedSubviews.count == 2 {
            let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            splitView.setPosition((length - splitView.dividerThickness) / 2, ofDividerAt: 0)
            splitView.adjustSubviews()
        }
        for subview in view.subviews {
            equalizeSplits(in: subview)
        }
    }

    private func nearestSplitView(for pane: NSView, direction: TerminalPaneDirection) -> NSSplitView? {
        let wantsVertical = direction == .left || direction == .right
        var view = pane.superview
        while let current = view {
            if let splitView = current as? NSSplitView, splitView.isVertical == wantsVertical {
                return splitView
            }
            view = current.superview
        }
        return nil
    }

    private func terminalCellSize(for controller: TerminalSessionController, horizontal: Bool) -> CGFloat {
        guard let terminal = controller.surface else {
            return 1
        }
        let dimensions = terminal.gridDimensions
        let units = horizontal ? dimensions.cols : dimensions.rows
        let length = horizontal ? terminal.bounds.width : terminal.bounds.height
        guard units > 0, length > 0 else {
            return 1
        }
        return length / CGFloat(units)
    }

    /// The smallest size that keeps one cell of each visible terminal.
    private func minimumContentSize(cards: Bool) -> NSSize {
        if
            let zoomedID = workspace.zoomedControllerID,
            let controller = workspace.controllers.first(where: {
                $0.id == zoomedID
            }) {
            return minimumPaneSize(for: controller, cards: cards)
        }
        return minimumSize(of: workspace.root, cards: cards)
    }

    private func minimumSize(of node: TerminalPaneNode, cards: Bool) -> NSSize {
        switch node.content {
        case .terminal(let controller):
            return minimumPaneSize(for: controller, cards: cards)
        case .split(let orientation, let first, let second):
            let firstSize = minimumSize(of: first, cards: cards)
            let secondSize = minimumSize(of: second, cards: cards)
            let divider = TerminalWorkspaceSplitView.dividerThickness(cardsEnabled: cards, style: paneStyle)
            if orientation == .vertical {
                return NSSize(
                    width: firstSize.width + divider + secondSize.width,
                    height: max(firstSize.height, secondSize.height)
                )
            }
            return NSSize(
                width: max(firstSize.width, secondSize.width),
                height: firstSize.height + divider + secondSize.height
            )
        }
    }

    /// The space on each side of each terminal, from the settings.
    private var terminalPadding: GlobalAppearanceSettings.TerminalPadding {
        workspace.appearanceSettings.terminalPadding
    }

    private func minimumPaneSize(for controller: TerminalSessionController, cards: Bool) -> NSSize {
        let padding = terminalPadding.points
        let top = terminalPadding.topPoints(cardsEnabled: cards && showsPaneHeaders)
        let width = terminalCellSize(for: controller, horizontal: true) + padding * 2
        let height = terminalCellSize(for: controller, horizontal: false) + top + padding
        guard cards && showsPaneHeaders else {
            return NSSize(width: width, height: height)
        }
        // The title bar needs space for the icon and some of the title.
        return NSSize(width: max(width, 72), height: height + paneStyle.headerHeight)
    }

    /// The divider positions that keep the minimum size of the two sides.
    /// The value is nil when the split view is smaller than the two minimum
    /// sizes. Then the divider does not snap to a calculated position.
    private func dividerLimits(in splitView: NSSplitView) -> ClosedRange<CGFloat>? {
        guard
            let node = (splitView as? TerminalWorkspaceSplitView)?.paneNode,
            case .split(_, let first, let second) = node.content else {
            return nil
        }
        let horizontal = splitView.isVertical
        let length = horizontal ? splitView.bounds.width : splitView.bounds.height
        let firstSize = minimumSize(of: first, cards: cardsEnabled)
        let secondSize = minimumSize(of: second, cards: cardsEnabled)
        let lowerBound = horizontal ? firstSize.width : firstSize.height
        let upperBound = length - splitView.dividerThickness - (horizontal ? secondSize.width : secondSize.height)
        return lowerBound <= upperBound ? lowerBound...upperBound : nil
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        if !isRebuilding {
            onCardLayout?(self)
        }
        workspace.windowManager?.persistenceDidChange?(false)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard let limits = dividerLimits(in: splitView) else {
            return proposedMinimumPosition
        }
        return min(max(proposedMinimumPosition, limits.lowerBound), limits.upperBound)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard let limits = dividerLimits(in: splitView) else {
            return proposedMaximumPosition
        }
        return max(min(proposedMaximumPosition, limits.upperBound), limits.lowerBound)
    }
}

/// Shows the card of a closed pane while it shrinks. The closed pane must
/// not get clicks or focus, so this view and its subviews take no clicks.
final class TerminalTransitionOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
