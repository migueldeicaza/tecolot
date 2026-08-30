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
    @ObservationIgnored private let startsProcesses: Bool
    @ObservationIgnored weak var hostView: TerminalPaneHostView?

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
        guard let node = findNode(for: controller, in: root) else { return }

        let newController = TerminalSessionController(startsProcess: startsProcesses)
        newController.prepareForSplit(from: controller)
        newController.workspace = self

        let existingNode = TerminalPaneNode(content: .terminal(controller))
        let newNode = TerminalPaneNode(content: .terminal(newController))
        node.content = .split(orientation, existingNode, newNode)
        focusedControllerID = newController.id
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
        hostView?.equalizeSplits()
    }

    func moveDivider(in direction: TerminalPaneDirection) {
        hostView?.moveDivider(in: direction)
    }

    /// Removes a pane. Returns false when it is the only pane in the window.
    @discardableResult
    func close(_ controller: TerminalSessionController) -> Bool {
        guard paneCount > 1, remove(controller, from: root) else { return false }
        controller.terminate()
        if focusedControllerID == controller.id, let fallback = controllers.first {
            focusedControllerID = fallback.id
            fallback.requestFocus()
        }
        revision += 1
        return true
    }

    func terminateAll() {
        for controller in controllers {
            controller.terminate()
        }
    }

    func updateWindowTransparency() {
        guard let window = controllers.compactMap(\.terminal?.window).first else { return }
        TerminalWindowTransparency.apply(
            to: window,
            isEnabled: controllers.contains { $0.effectiveBackgroundOpacity < 1.0 }
        )
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
            node.content = second.content
            return true
        }
        if isTerminal(controller, in: second) {
            node.content = first.content
            return true
        }
        return remove(controller, from: first) || remove(controller, from: second)
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

    func makeNSView(context: Context) -> TerminalPaneHostView {
        let view = TerminalPaneHostView(workspace: workspace, document: document)
        view.synchronize(revision: revision, document: document)
        return view
    }

    func updateNSView(_ nsView: TerminalPaneHostView, context: Context) {
        nsView.synchronize(revision: revision, document: document)
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

final class TerminalPaneHostView: NSView {
    let workspace: TerminalPaneWorkspace
    private var document: TerminalDocument
    private var displayedRevision = -1
    private var paneViews: [UUID: NSView] = [:]

    init(workspace: TerminalPaneWorkspace, document: TerminalDocument) {
        self.workspace = workspace
        self.document = document
        super.init(frame: .zero)
        workspace.hostView = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func synchronize(revision: Int, document: TerminalDocument) {
        self.document = document
        guard displayedRevision != revision else { return }
        displayedRevision = revision
        rebuild()
    }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }

    private func rebuild() {
        // Removing a focused terminal does not always make AppKit resign it.
        // Clear the first responder first so the old pane sends focus-out.
        if let terminal = window?.firstResponder as? AppTerminalView,
           terminal.isDescendant(of: self) {
            window?.makeFirstResponder(nil)
        }
        subviews.forEach { $0.removeFromSuperview() }
        paneViews.removeAll()
        let rootView = makeView(for: workspace.root)
        rootView.frame = bounds
        rootView.autoresizingMask = [.width, .height]
        addSubview(rootView)

        // Reattaching a terminal view clears AppKit's first responder. Ask
        // for focus after the new split hierarchy is in the window.
        workspace.focusedController?.requestFocus()
    }

    func selectSplit(in direction: TerminalPaneDirection) {
        guard let focused = workspace.focusedController,
              let source = paneViews[focused.id] else { return }

        let sourceFrame = source.convert(source.bounds, to: self)
        let candidates = workspace.controllers.compactMap { controller -> (TerminalSessionController, CGRect)? in
            guard controller !== focused, let pane = paneViews[controller.id] else { return nil }
            return (controller, pane.convert(pane.bounds, to: self))
        }
        guard let target = candidates
            .filter({ isInDirection($0.1, from: sourceFrame, direction: direction) })
            .min(by: { directionScore($0.1, from: sourceFrame, direction: direction)
                < directionScore($1.1, from: sourceFrame, direction: direction) })?.0 else {
            return
        }
        workspace.markFocused(target)
        target.requestFocus()
    }

    func equalizeSplits() {
        equalizeSplits(in: subviews.first)
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
        let divider = splitView.dividerThickness
        let availableLength = movesAlongHorizontalAxis ? splitView.bounds.width : splitView.bounds.height
        let minimumLength = minimumPaneLength(in: splitView, horizontal: movesAlongHorizontalAxis)
        let minimumPosition = max(
            minimumLength,
            splitView.minPossiblePositionOfDivider(at: 0)
        )
        let maximumPosition = min(
            availableLength - divider - minimumLength,
            splitView.maxPossiblePositionOfDivider(at: 0)
        )
        guard maximumPosition >= minimumPosition else { return }

        let firstPane = splitView.arrangedSubviews[0]
        let position = movesAlongHorizontalAxis ? firstPane.frame.width : firstPane.frame.height
        splitView.setPosition(min(max(position + delta, minimumPosition), maximumPosition), ofDividerAt: 0)
        splitView.adjustSubviews()
    }

    private func makeView(for node: TerminalPaneNode) -> NSView {
        switch node.content {
        case .terminal(let controller):
            // The container supplies the terminal's Auto Layout constraints.
            // NSSplitView must size the container, not the terminal itself.
            let view = TerminalSessionContainerView(
                terminal: controller.makeTerminalView(document: document)
            )
            paneViews[controller.id] = view
            return view
        case .split(let orientation, let first, let second):
            let splitView = NSSplitView(frame: .zero)
            splitView.isVertical = orientation == .vertical
            splitView.dividerStyle = .thin
            splitView.addArrangedSubview(makeView(for: first))
            splitView.addArrangedSubview(makeView(for: second))
            return splitView
        }
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

    private func minimumPaneLength(in splitView: NSSplitView, horizontal: Bool) -> CGFloat {
        workspace.controllers
            .compactMap { controller -> CGFloat? in
                guard let pane = paneViews[controller.id], pane.isDescendant(of: splitView) else { return nil }
                return terminalCellSize(for: controller, horizontal: horizontal)
            }
            .max() ?? 1
    }
}
