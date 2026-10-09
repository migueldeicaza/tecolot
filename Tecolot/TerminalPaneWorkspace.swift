//
//  TerminalPaneWorkspace.swift
//  Tecolot
//
//  Owns the pane tree for one document window. The AppKit host rebuilds only
//  the split-view containers when the tree changes. It reuses each terminal
//  view, so a split does not restart an existing process.
//

import AppKit
import Observation
import SwiftTerm
import SwiftUI

enum TerminalPaneSplit: String, Codable, Sendable {
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
    private(set) var root: TerminalPaneNode
    private(set) var revision = 0
    private(set) var focusedControllerID: UUID
    private(set) var zoomedControllerID: UUID?
    @ObservationIgnored private let startsProcesses: Bool
    @ObservationIgnored weak var hostView: TerminalPaneHostView?
    /// The host sets this value from SwiftUI. The title bar also reads it.
    @ObservationIgnored var appearanceSettings = GlobalAppearanceSettings()
    @ObservationIgnored private var processTask: Task<Void, Never>?
    @ObservationIgnored private var jobIconResolvers: [UUID: TerminalForegroundJobIconResolver] = [:]

    init(startsProcesses: Bool = true) {
        self.startsProcesses = startsProcesses
        let controller = TerminalSessionController(startsProcess: startsProcesses)
        root = TerminalPaneNode(content: .terminal(controller))
        focusedControllerID = controller.id
        controller.workspace = self
    }

    var controllers: [TerminalSessionController] {
        collectControllers(in: root)
    }

    var focusedController: TerminalSessionController? {
        controllers.first { $0.id == focusedControllerID } ?? controllers.first
    }

    var paneCount: Int {
        controllers.count
    }

    func markFocused(_ controller: TerminalSessionController) {
        guard contains(controller) else { return }
        if focusedControllerID != controller.id {
            focusedControllerID = controller.id
        }
    }

    func split(_ controller: TerminalSessionController, orientation: TerminalPaneSplit) {
        split(controller, direction: orientation == .vertical ? .right : .down)
    }

    func split(_ controller: TerminalSessionController, direction: TerminalPaneDirection) {
        guard let node = findNode(for: controller, in: root) else { return }

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
        focusedControllerID = newController.id
        if zoomedControllerID != nil {
            zoomedControllerID = newController.id
        }
        revision += 1
    }

    func toggleSplitZoom() {
        guard paneCount > 1, let focused = focusedController else { return }
        zoomedControllerID = zoomedControllerID == focused.id ? nil : focused.id
        revision += 1
    }

    func clearSplitZoom() {
        guard zoomedControllerID != nil else { return }
        zoomedControllerID = nil
        revision += 1
    }

    func zoomSelectedSplit(_ controller: TerminalSessionController) {
        guard zoomedControllerID != nil, contains(controller),
              zoomedControllerID != controller.id else { return }
        zoomedControllerID = controller.id
        revision += 1
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
        guard zoomedControllerID == nil else { return }
        hostView?.equalizeSplits()
    }

    func moveDivider(in direction: TerminalPaneDirection) {
        guard zoomedControllerID == nil else { return }
        hostView?.moveDivider(in: direction)
    }

    /// Removes a pane. Returns false when it is the only pane in the window.
    @discardableResult
    func close(_ controller: TerminalSessionController) -> Bool {
        guard paneCount > 1, remove(controller, from: root) else { return false }
        controller.terminate()
        if zoomedControllerID == controller.id || paneCount == 1 {
            zoomedControllerID = nil
        }
        if focusedControllerID == controller.id, let fallback = controllers.first {
            focusedControllerID = fallback.id
            fallback.requestFocus()
        }
        revision += 1
        return true
    }

    func terminateAll() {
        processTask?.cancel()
        processTask = nil
        for controller in controllers {
            controller.terminate()
        }
    }

    func updateWindowTransparency() {
        guard let window = controllers.compactMap(\.terminal?.window).first else { return }
        TerminalWindowTransparency.apply(
            to: window,
            isEnabled: controllers.contains { $0.effectiveBackgroundOpacity < 1.0 }
                || hostView?.showsDesktopBlur == true
        )
    }

    /// Starts or stops the foreground process check. The tab bar shows the
    /// icons of all panes, also panes that a zoom hides and panes in tabs
    /// that are not selected. Thus the workspace examines all panes, not
    /// only the panes that have a card on screen.
    func updateProcessInspection() {
        guard appearanceSettings.paneCardsEnabled, hostView?.window != nil else {
            processTask?.cancel()
            processTask = nil
            jobIconResolvers.removeAll()
            return
        }
        guard processTask == nil else { return }
        processTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    await self.inspectForegroundProcesses()
                }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    private func inspectForegroundProcesses() async {
        guard appearanceSettings.paneCardsEnabled, let window = hostView?.window else { return }
        // A tab that is not selected has a window that is not visible, but
        // the tab bar shows its icons. Use the window of the selected tab.
        let shownWindow = window.tabGroup?.selectedWindow ?? window
        guard shownWindow.isVisible, shownWindow.occlusionState.contains(.visible) else { return }
        let panes = controllers
        let descriptors = panes.map { controller -> Int32? in
            guard let process = controller.terminal?.process, process.running else { return nil }
            return process.childfd
        }
        let snapshots = await Task.detached(priority: .utility) {
            let inspector = SystemTerminalProcessInspector()
            return descriptors.map { descriptor -> TerminalForegroundJobSnapshot? in
                guard let descriptor,
                      let group = inspector.foregroundProcessGroup(for: descriptor) else { return nil }
                let processes = inspector.foregroundProcesses(in: group)
                guard inspector.foregroundProcessGroup(for: descriptor) == group else { return nil }
                return .init(processGroup: group, processes: processes)
            }
        }.value
        guard !Task.isCancelled, appearanceSettings.paneCardsEnabled else { return }
        let liveIDs = Set(controllers.map(\.id))
        jobIconResolvers = jobIconResolvers.filter { liveIDs.contains($0.key) }
        for (controller, (descriptor, snapshot)) in zip(panes, zip(descriptors, snapshots)) {
            // A pane can start a new process while the check runs.
            guard liveIDs.contains(controller.id) else { continue }
            let currentProcess = controller.terminal?.process
            let currentDescriptor = currentProcess?.running == true ? currentProcess?.childfd : nil
            guard descriptor == currentDescriptor else { continue }
            var resolver = jobIconResolvers[controller.id] ?? TerminalForegroundJobIconResolver()
            let path = resolver.executablePath(for: snapshot, descriptor: descriptor)
            jobIconResolvers[controller.id] = resolver
            controller.updatePaneExecutablePath(path)
        }
    }

    private func contains(_ controller: TerminalSessionController) -> Bool {
        controllers.contains { $0 === controller }
    }

    private func selectSplit(offset: Int) {
        let controllers = controllers
        guard controllers.count > 1,
              let currentIndex = controllers.firstIndex(where: { $0.id == focusedControllerID }) else {
            return
        }
        let nextIndex = (currentIndex + offset + controllers.count) % controllers.count
        let next = controllers[nextIndex]
        focusedControllerID = next.id
        if zoomedControllerID != nil {
            zoomedControllerID = next.id
            revision += 1
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
        guard case .split(_, let first, let second) = node.content else { return false }

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

    private func promote(_ survivor: TerminalPaneNode, into node: TerminalPaneNode) {
        if case .split = survivor.content {
            hostView?.transferDividerPosition(from: survivor.id, to: node.id)
        }
        node.content = survivor.content
    }

    private func isTerminal(
        _ controller: TerminalSessionController,
        in node: TerminalPaneNode
    ) -> Bool {
        guard case .terminal(let candidate) = node.content else { return false }
        return candidate === controller
    }
}

struct TerminalPaneContainer: NSViewRepresentable {
    let workspace: TerminalPaneWorkspace
    let document: TerminalDocument
    let revision: Int
    var appearanceSettings = GlobalAppearanceSettings()

    func makeNSView(context: Context) -> TerminalPaneHostView {
        let view = TerminalPaneHostView(workspace: workspace, document: document)
        view.synchronize(revision: revision, document: document, settings: appearanceSettings)
        return view
    }

    func updateNSView(_ nsView: TerminalPaneHostView, context: Context) {
        nsView.synchronize(revision: revision, document: document, settings: appearanceSettings)
    }

    static func dismantleNSView(_ nsView: TerminalPaneHostView, coordinator: ()) {
        nsView.workspace.terminateAll()
    }
}

#Preview("Terminal Pane") {
    @Previewable @State var workspace = TerminalPaneWorkspace(startsProcesses: false)

    TerminalPaneContainer(
        workspace: workspace,
        document: TerminalDocument(
            content: "miguel@mac tecolot % ls\nREADME.md  Tecolot  TecolotTests\n"
        ),
        revision: workspace.revision
    )
    .frame(width: 720, height: 420)
}

final class TerminalPaneHostView: NSView, NSSplitViewDelegate {
    let workspace: TerminalPaneWorkspace
    private var document: TerminalDocument
    private let backdropView = TerminalWorkspaceBackdropView(frame: .zero)
    /// False when the settings turn off the cards, when the window has one
    /// pane, or when the window is too small for the card decorations.
    private(set) var cardsEnabled = false
    private var appearanceObserver: NSObjectProtocol?
    private var displayedRevision = -1
    private var isRebuilding = false
    private var paneViews: [UUID: TerminalPaneCardView] = [:]
    private var splitViews: [UUID: TerminalWorkspaceSplitView] = [:]
    private var dividerFractions: [UUID: CGFloat] = [:]
    private var pendingDividerTransfers: [(from: UUID, to: UUID)] = []
    private var unzoomedPaneFrames: [UUID: CGRect] = [:]
    private var needsDividerRestore = false

    init(workspace: TerminalPaneWorkspace, document: TerminalDocument) {
        self.workspace = workspace
        self.document = document
        super.init(frame: .zero)
        workspace.hostView = self
        addSubview(backdropView)
        appearanceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAppearance() }
        }
        observeFocus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let appearanceObserver { NSWorkspace.shared.notificationCenter.removeObserver(appearanceObserver) }
    }

    var showsDesktopBlur: Bool { backdropView.showsDesktopBlur }

    func synchronize(revision: Int, document: TerminalDocument,
                     settings: GlobalAppearanceSettings = GlobalAppearanceSettings()) {
        self.document = document
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
        super.setFrameSize(newSize)
        // A smaller window can have no space for the card decorations.
        updateCardMetrics()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        workspace.updateProcessInspection()
    }

    override func layout() {
        super.layout()
        backdropView.frame = bounds
        rootView?.frame = contentFrame
        if needsDividerRestore, !bounds.isEmpty {
            needsDividerRestore = false
            restoreDividerPositions(in: workspace.root)
        }
    }

    private var rootView: NSView? {
        subviews.first { $0 !== backdropView }
    }

    private var contentFrame: NSRect {
        guard cardsEnabled else { return bounds }
        let spacing = GlobalAppearanceSettings.cardSpacing
        return bounds.insetBy(dx: min(spacing, bounds.width / 2), dy: min(spacing, bounds.height / 2))
    }

    /// Applies the settings, the theme colors and the accessibility options
    /// to the backdrop and to all cards. Each card compares its state and
    /// does no work when nothing changed.
    func refreshAppearance() {
        // A new terminal applies its profile while rebuild() makes it. The
        // tree is not complete at that time, so rebuild() calls this method
        // when it is done.
        guard !isRebuilding else { return }
        updateCardMetrics()
        refreshBackdrop()
        for card in paneViews.values { card.refreshAppearance() }
        workspace.updateWindowTransparency()
        workspace.updateProcessInspection()
    }

    private func refreshBackdrop() {
        let theme = workspace.focusedController?.effectiveTheme ?? .fallback
        backdropView.update(
            visible: cardsEnabled,
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
                guard let self else { return }
                self.refreshBackdrop()
                self.observeFocus()
            }
        }
    }

    /// Shows the cards only when the settings enable them, the window has
    /// more than one pane, and each visible pane has space for its title bar
    /// and one terminal cell.
    private func wantsCards() -> Bool {
        guard workspace.appearanceSettings.paneCardsEnabled, workspace.paneCount > 1 else { return false }
        // The host has no size before its first layout. Use the settings
        // until then, so that a new tree does not change its metrics twice.
        guard !bounds.isEmpty else { return true }
        let spacing = GlobalAppearanceSettings.cardSpacing * 2
        let minimum = minimumContentSize(cards: true)
        return minimum.width + spacing <= bounds.width && minimum.height + spacing <= bounds.height
    }

    private func updateCardMetrics() {
        let wanted = wantsCards()
        guard wanted != cardsEnabled else { return }
        saveDividerPositions()
        cardsEnabled = wanted
        for split in splitViews.values { split.cardsEnabled = wanted }
        for card in paneViews.values { card.cardsEnabled = wanted }
        refreshBackdrop()
        workspace.updateWindowTransparency()
        needsDividerRestore = true
        needsLayout = true
    }

    private func rebuild() {
        isRebuilding = true
        saveDividerPositions()
        for transfer in pendingDividerTransfers {
            dividerFractions[transfer.to] = dividerFractions.removeValue(forKey: transfer.from)
        }
        pendingDividerTransfers.removeAll()
        let activeSplitIDs = splitNodeIDs(in: workspace.root)
        dividerFractions = dividerFractions.filter { activeSplitIDs.contains($0.key) }
        if workspace.zoomedControllerID != nil, !paneViews.isEmpty, !splitViews.isEmpty {
            unzoomedPaneFrames = paneViews.mapValues { $0.convert($0.bounds, to: self) }
        }
        // Removing a focused terminal does not always make AppKit resign it.
        // Clear the first responder first so the old pane sends focus-out.
        if let terminal = window?.firstResponder as? AppTerminalView,
           terminal.isDescendant(of: self) {
            window?.makeFirstResponder(nil)
        }
        rootView?.removeFromSuperview()
        paneViews.removeAll()
        splitViews.removeAll()
        // Set the metrics before the new views exist. The old tree then keeps
        // its metrics, and the new tree gets its final layout at once.
        cardsEnabled = wantsCards()
        let rootView: NSView
        if let zoomedID = workspace.zoomedControllerID,
           let controller = workspace.controllers.first(where: { $0.id == zoomedID }) {
            rootView = makeTerminalView(for: controller)
        } else {
            rootView = makeView(for: workspace.root)
            needsDividerRestore = !dividerFractions.isEmpty
            unzoomedPaneFrames.removeAll()
        }
        rootView.frame = contentFrame
        rootView.autoresizingMask = [.width, .height]
        addSubview(rootView, positioned: .above, relativeTo: backdropView)
        isRebuilding = false
        refreshAppearance()
        if needsDividerRestore, !bounds.isEmpty {
            rootView.layoutSubtreeIfNeeded()
            restoreDividerPositions(in: workspace.root)
            needsDividerRestore = false
        }

        // Reattaching a terminal view clears AppKit's first responder. Ask
        // for focus after the new split hierarchy is in the window.
        workspace.focusedController?.requestFocus()
    }

    func selectSplit(in direction: TerminalPaneDirection) {
        guard let focused = workspace.focusedController,
              let source = paneViews[focused.id] else { return }

        let sourceFrame = unzoomedPaneFrames[focused.id] ?? source.convert(source.bounds, to: self)
        let candidates = workspace.controllers.compactMap { controller -> (TerminalSessionController, CGRect)? in
            guard controller !== focused else { return nil }
            if let frame = unzoomedPaneFrames[controller.id] {
                return (controller, frame)
            }
            guard let pane = paneViews[controller.id] else { return nil }
            return (controller, pane.convert(pane.bounds, to: self))
        }
        guard let target = candidates
            .filter({ isInDirection($0.1, from: sourceFrame, direction: direction) })
            .min(by: { directionScore($0.1, from: sourceFrame, direction: direction)
                < directionScore($1.1, from: sourceFrame, direction: direction) })?.0 else {
            if workspace.zoomedControllerID != nil, splitViews.isEmpty,
               unzoomedPaneFrames.count < workspace.paneCount {
                switch direction {
                case .up, .left: workspace.selectPreviousSplit()
                case .down, .right: workspace.selectNextSplit()
                }
            }
            return
        }
        workspace.markFocused(target)
        workspace.zoomSelectedSplit(target)
        target.requestFocus()
    }

    func equalizeSplits() {
        equalizeSplits(in: rootView)
    }

    func moveDivider(in direction: TerminalPaneDirection) {
        guard let focused = workspace.focusedController,
              let pane = paneViews[focused.id],
              let splitView = nearestSplitView(for: pane, direction: direction) else {
            return
        }

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
        guard let limits = dividerLimits(in: splitView) else { return }

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
            terminal: controller.makeTerminalView(document: document)
        )
        let card = TerminalPaneCardView(controller: controller, content: view, cardsEnabled: cardsEnabled)
        paneViews[controller.id] = card
        return card
    }

    private func saveDividerPositions() {
        for (id, splitView) in splitViews where splitView.arrangedSubviews.count == 2 {
            let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            let available = length - splitView.dividerThickness
            guard available > 0 else { continue }
            let first = splitView.arrangedSubviews[0]
            let firstLength = splitView.isVertical ? first.frame.width : first.frame.height
            // A split view that has no layout yet keeps its earlier fraction.
            guard firstLength > 0 else { continue }
            dividerFractions[id] = firstLength / available
        }
    }

    func transferDividerPosition(from oldID: UUID, to newID: UUID) {
        pendingDividerTransfers.append((from: oldID, to: newID))
    }

    private func splitNodeIDs(in node: TerminalPaneNode) -> Set<UUID> {
        guard case .split(_, let first, let second) = node.content else { return [] }
        return Set([node.id]).union(splitNodeIDs(in: first)).union(splitNodeIDs(in: second))
    }

    private func restoreDividerPositions(in node: TerminalPaneNode) {
        guard case .split(_, let first, let second) = node.content,
              let splitView = splitViews[node.id] else { return }
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

    private func isInDirection(
        _ candidate: CGRect,
        from source: CGRect,
        direction: TerminalPaneDirection
    ) -> Bool {
        switch direction {
        case .up:
            return candidate.minY >= source.maxY && candidate.maxX > source.minX && candidate.minX < source.maxX
        case .down:
            return candidate.maxY <= source.minY && candidate.maxX > source.minX && candidate.minX < source.maxX
        case .left:
            return candidate.maxX <= source.minX && candidate.maxY > source.minY && candidate.minY < source.maxY
        case .right:
            return candidate.minX >= source.maxX && candidate.maxY > source.minY && candidate.minY < source.maxY
        }
    }

    private func directionScore(
        _ candidate: CGRect,
        from source: CGRect,
        direction: TerminalPaneDirection
    ) -> CGFloat {
        switch direction {
        case .up:
            return candidate.minY - source.maxY + abs(candidate.midX - source.midX)
        case .down:
            return source.minY - candidate.maxY + abs(candidate.midX - source.midX)
        case .left:
            return source.minX - candidate.maxX + abs(candidate.midY - source.midY)
        case .right:
            return candidate.minX - source.maxX + abs(candidate.midY - source.midY)
        }
    }

    private func equalizeSplits(in view: NSView?) {
        guard let view else { return }
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
        guard let terminal = controller.terminal else { return 1 }
        let dimensions = terminal.terminalDimensions
        let units = horizontal ? dimensions.cols : dimensions.rows
        let length = horizontal ? terminal.bounds.width : terminal.bounds.height
        guard units > 0, length > 0 else { return 1 }
        return length / CGFloat(units)
    }

    /// The smallest size that keeps one cell of each visible terminal.
    private func minimumContentSize(cards: Bool) -> NSSize {
        if let zoomedID = workspace.zoomedControllerID,
           let controller = workspace.controllers.first(where: { $0.id == zoomedID }) {
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
            let divider = TerminalWorkspaceSplitView.dividerThickness(cardsEnabled: cards)
            if orientation == .vertical {
                return NSSize(width: firstSize.width + divider + secondSize.width,
                              height: max(firstSize.height, secondSize.height))
            }
            return NSSize(width: max(firstSize.width, secondSize.width),
                          height: firstSize.height + divider + secondSize.height)
        }
    }

    private func minimumPaneSize(for controller: TerminalSessionController, cards: Bool) -> NSSize {
        let width = terminalCellSize(for: controller, horizontal: true) + 4
        let height = terminalCellSize(for: controller, horizontal: false) + 4
        guard cards else { return NSSize(width: width, height: height) }
        // The title bar needs space for the icon and some of the title.
        return NSSize(width: max(width, 72), height: height + GlobalAppearanceSettings.cardTitlebarHeight)
    }

    /// The divider positions that keep the minimum size of the two sides.
    /// The value is nil when the split view is smaller than the two minimum
    /// sizes. Then the divider does not snap to a calculated position.
    private func dividerLimits(in splitView: NSSplitView) -> ClosedRange<CGFloat>? {
        guard let node = (splitView as? TerminalWorkspaceSplitView)?.paneNode,
              case .split(_, let first, let second) = node.content else { return nil }
        let horizontal = splitView.isVertical
        let length = horizontal ? splitView.bounds.width : splitView.bounds.height
        let firstSize = minimumSize(of: first, cards: cardsEnabled)
        let secondSize = minimumSize(of: second, cards: cardsEnabled)
        let lowerBound = horizontal ? firstSize.width : firstSize.height
        let upperBound = length - splitView.dividerThickness - (horizontal ? secondSize.width : secondSize.height)
        return lowerBound <= upperBound ? lowerBound...upperBound : nil
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard let limits = dividerLimits(in: splitView) else { return proposedMinimumPosition }
        return min(max(proposedMinimumPosition, limits.lowerBound), limits.upperBound)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard let limits = dividerLimits(in: splitView) else { return proposedMaximumPosition }
        return max(min(proposedMaximumPosition, limits.upperBound), limits.lowerBound)
    }
}
