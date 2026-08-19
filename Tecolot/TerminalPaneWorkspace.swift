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
import SwiftUI

enum TerminalPaneSplit: String, Codable, Sendable {
    /// A vertical divider puts panes next to each other.
    case vertical
    /// A horizontal divider stacks panes.
    case horizontal
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

    init() {
        let controller = TerminalSessionController()
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

        let newController = TerminalSessionController()
        newController.prepareForSplit(from: controller)
        newController.workspace = self

        let existingNode = TerminalPaneNode(content: .terminal(controller))
        let newNode = TerminalPaneNode(content: .terminal(newController))
        node.content = .split(orientation, existingNode, newNode)
        focusedControllerID = newController.id
        revision += 1
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
        if controllers.contains(where: { $0.profile.backgroundOpacity < 1.0 }) {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else if !window.isOpaque {
            window.isOpaque = true
            window.backgroundColor = nil
        }
    }

    private func contains(_ controller: TerminalSessionController) -> Bool {
        controllers.contains { $0 === controller }
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

final class TerminalPaneHostView: NSView {
    let workspace: TerminalPaneWorkspace
    private var document: TerminalDocument
    private var displayedRevision = -1

    init(workspace: TerminalPaneWorkspace, document: TerminalDocument) {
        self.workspace = workspace
        self.document = document
        super.init(frame: .zero)
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
        let rootView = makeView(for: workspace.root)
        rootView.frame = bounds
        rootView.autoresizingMask = [.width, .height]
        addSubview(rootView)

        // Reattaching a terminal view clears AppKit's first responder. Ask
        // for focus after the new split hierarchy is in the window.
        workspace.focusedController?.requestFocus()
    }

    private func makeView(for node: TerminalPaneNode) -> NSView {
        switch node.content {
        case .terminal(let controller):
            // The container supplies the terminal's Auto Layout constraints.
            // NSSplitView must size the container, not the terminal itself.
            return TerminalSessionContainerView(
                terminal: controller.makeTerminalView(document: document)
            )
        case .split(let orientation, let first, let second):
            let splitView = NSSplitView(frame: .zero)
            splitView.isVertical = orientation == .vertical
            splitView.dividerStyle = .thin
            splitView.addArrangedSubview(makeView(for: first))
            splitView.addArrangedSubview(makeView(for: second))
            return splitView
        }
    }
}
