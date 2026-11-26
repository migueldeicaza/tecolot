import AppKit
import Testing
@testable import Tecolot

@MainActor
struct TerminalPaneFocusTests {
    @Test func backgroundOutputRemainsMarkedDuringWindowUpdates() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let controller = try #require(workspace.focusedController)
        let hostView = TerminalPaneHostView(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision)

        let terminal = try #require(controller.terminal)
        #expect(window.makeFirstResponder(terminal))
        controller.attach(to: terminal)
        #expect(!window.isKeyWindow)

        controller.noteOutputActivity()
        #expect(controller.hasActivity)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(controller.hasActivity)
    }

    @Test func mouseClickFocusesTheClickedPane() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let firstController = try #require(workspace.focusedController)
        workspace.split(firstController, orientation: .vertical)
        let secondController = try #require(workspace.focusedController)
        let hostView = TerminalPaneHostView(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision)
        hostView.layoutSubtreeIfNeeded()

        let firstTerminal = try #require(firstController.terminal as? AppTerminalView)
        let secondTerminal = try #require(secondController.terminal as? AppTerminalView)
        #expect(window.makeFirstResponder(secondTerminal))
        secondController.didBecomeFocused()
        #expect(workspace.focusedController === secondController)

        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: firstTerminal.convert(NSPoint(x: 1, y: 1), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        firstTerminal.mouseDown(with: click)

        #expect(window.firstResponder === firstTerminal)
        #expect(workspace.focusedController === firstController)
        #expect(TerminalSessionRegistry.shared.controller(for: window) === firstController)
    }

    @Test func closingBottomRightPaneFocusesPaneAboveInsteadOfFirst() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let left = try #require(workspace.focusedController)
        workspace.split(left, direction: .right)
        let topRight = try #require(workspace.focusedController)
        workspace.split(topRight, direction: .down)
        let bottomRight = try #require(workspace.focusedController)

        #expect(workspace.close(bottomRight))
        #expect(workspace.focusedController === topRight)

        #expect(workspace.close(topRight))
        #expect(workspace.focusedController === left)
    }

    @Test func closingTopRightPaneFocusesLeftAndClosingLeftFocusesTopRight() throws {
        do {
            let workspace = TerminalPaneWorkspace(startsProcesses: false)
            let left = try #require(workspace.focusedController)
            workspace.split(left, direction: .right)
            let topRight = try #require(workspace.focusedController)
            workspace.split(topRight, direction: .down)
            workspace.markFocused(topRight)

            #expect(workspace.close(topRight))
            #expect(workspace.focusedController === left)
        }

        do {
            let workspace = TerminalPaneWorkspace(startsProcesses: false)
            let left = try #require(workspace.focusedController)
            workspace.split(left, direction: .right)
            let topRight = try #require(workspace.focusedController)
            workspace.split(topRight, direction: .down)
            workspace.markFocused(left)

            #expect(workspace.close(left))
            #expect(workspace.focusedController === topRight)
        }
    }

    @Test func closingBottomRowPanesFocusesClosestPrecedingPane() throws {
        do {
            let workspace = TerminalPaneWorkspace(startsProcesses: false)
            let top = try #require(workspace.focusedController)
            workspace.split(top, direction: .down)
            let bottomLeft = try #require(workspace.focusedController)
            workspace.split(bottomLeft, direction: .right)
            let bottomRight = try #require(workspace.focusedController)

            #expect(workspace.close(bottomRight))
            #expect(workspace.focusedController === bottomLeft)

            #expect(workspace.close(bottomLeft))
            #expect(workspace.focusedController === top)
        }

        do {
            let workspace = TerminalPaneWorkspace(startsProcesses: false)
            let top = try #require(workspace.focusedController)
            workspace.split(top, direction: .down)
            let bottomLeft = try #require(workspace.focusedController)
            workspace.split(bottomLeft, direction: .right)
            workspace.markFocused(top)

            #expect(workspace.close(top))
            #expect(workspace.focusedController === bottomLeft)
        }
    }

    @Test func closingMiddlePaneInRowFocusesPaneToItsLeftRegardlessOfNesting() throws {
        // Nested right: V(a, V(b, c))
        do {
            let workspace = TerminalPaneWorkspace(startsProcesses: false)
            let a = try #require(workspace.focusedController)
            workspace.split(a, direction: .right)
            let b = try #require(workspace.focusedController)
            workspace.split(b, direction: .right)
            workspace.markFocused(b)

            #expect(workspace.close(b))
            #expect(workspace.focusedController === a)
        }

        // Nested left: V(V(a, b), c)
        do {
            let workspace = TerminalPaneWorkspace(startsProcesses: false)
            let a = try #require(workspace.focusedController)
            workspace.split(a, direction: .right)
            workspace.markFocused(a)
            workspace.split(a, direction: .right)
            let b = try #require(workspace.focusedController)

            #expect(workspace.close(b))
            #expect(workspace.focusedController === a)
        }
    }

    @Test func closingPaneInGridDoesNotJumpDiagonally() throws {
        // Rows of columns: H(V(topLeft, topRight), V(bottomLeft, bottomRight))
        do {
            let workspace = TerminalPaneWorkspace(startsProcesses: false)
            let topLeft = try #require(workspace.focusedController)
            workspace.split(topLeft, direction: .down)
            let bottomLeft = try #require(workspace.focusedController)
            workspace.split(topLeft, direction: .right)
            workspace.split(bottomLeft, direction: .right)
            workspace.markFocused(bottomLeft)

            #expect(workspace.close(bottomLeft))
            #expect(workspace.focusedController === topLeft)
        }

        // Columns of rows: V(H(topLeft, bottomLeft), H(topRight, bottomRight))
        do {
            let workspace = TerminalPaneWorkspace(startsProcesses: false)
            let topLeft = try #require(workspace.focusedController)
            workspace.split(topLeft, direction: .right)
            let topRight = try #require(workspace.focusedController)
            workspace.split(topLeft, direction: .down)
            workspace.split(topRight, direction: .down)
            workspace.markFocused(topRight)

            #expect(workspace.close(topRight))
            #expect(workspace.focusedController === topLeft)
        }
    }

    @Test func closingPaneUsesDividerPositions() throws {
        // Give topLeft 80% of the height so it is visually centered beside `right`.
        do {
            let workspace = TerminalPaneWorkspace(startsProcesses: false)
            let topLeft = try #require(workspace.focusedController)
            workspace.split(topLeft, direction: .right)
            let right = try #require(workspace.focusedController)
            workspace.split(topLeft, direction: .down)

            let hostView = TerminalPaneHostView(workspace: workspace)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostView
            hostView.synchronize(revision: workspace.revision)
            hostView.layoutSubtreeIfNeeded()

            let outer = try #require(hostView.subviews.compactMap {
                $0 as? NSSplitView
            }.first)
            let leftSplit = try #require(outer.arrangedSubviews[0] as? TerminalWorkspaceSplitView)
            leftSplit.setPosition(320, ofDividerAt: 0)
            leftSplit.adjustSubviews()
            let leftNodeID = try #require(leftSplit.paneNode?.id)
            let fraction = try #require(hostView.dividerFraction(for: leftNodeID))
            #expect(fraction > 0.7)

            workspace.markFocused(right)
            #expect(workspace.close(right))
            #expect(workspace.focusedController === topLeft)
        }

        // Give bottomLeft 80% of the height so it is visually centered beside `right`.
        do {
            let workspace = TerminalPaneWorkspace(startsProcesses: false)
            let topLeft = try #require(workspace.focusedController)
            workspace.split(topLeft, direction: .right)
            let right = try #require(workspace.focusedController)
            workspace.split(topLeft, direction: .down)
            let bottomLeft = try #require(workspace.focusedController)

            let hostView = TerminalPaneHostView(workspace: workspace)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostView
            hostView.synchronize(revision: workspace.revision)
            hostView.layoutSubtreeIfNeeded()

            let outer = try #require(hostView.subviews.compactMap {
                $0 as? NSSplitView
            }.first)
            let leftSplit = try #require(outer.arrangedSubviews[0] as? TerminalWorkspaceSplitView)
            leftSplit.setPosition(80, ofDividerAt: 0)
            leftSplit.adjustSubviews()
            let leftNodeID = try #require(leftSplit.paneNode?.id)
            let fraction = try #require(hostView.dividerFraction(for: leftNodeID))
            #expect(fraction < 0.3)

            workspace.markFocused(right)
            #expect(workspace.close(right))
            #expect(workspace.focusedController === bottomLeft)
        }
    }

    @Test func twoClosesInOneTurnDoNotReuseStaleDividerFraction() throws {
        // Tree: V(Outer, V(R, H(L, a, b), c), d)
        // Set R (vertical) to 80% and L (horizontal) to 20% (a = 20%, b = 80%).
        // Closing c promotes L into R without rebuilding; closing d in the same
        // turn must resolve R through the pending transfer (20% -> b), not read
        // the stale 80% width fraction still on splitViews[R].
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let a = try #require(workspace.focusedController)
        workspace.split(a, direction: .right)
        let d = try #require(workspace.focusedController)
        workspace.split(a, direction: .right)
        let c = try #require(workspace.focusedController)
        workspace.split(a, direction: .down)
        let b = try #require(workspace.focusedController)

        let hostView = TerminalPaneHostView(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision)
        hostView.layoutSubtreeIfNeeded()

        let outer = try #require(hostView.subviews.compactMap {
            $0 as? TerminalWorkspaceSplitView
        }.first)
        let middle = try #require(outer.arrangedSubviews[0] as? TerminalWorkspaceSplitView)
        let leftSplit = try #require(middle.arrangedSubviews[0] as? TerminalWorkspaceSplitView)
        middle.setPosition(middle.bounds.width * 0.8, ofDividerAt: 0)
        middle.adjustSubviews()
        leftSplit.setPosition(leftSplit.bounds.height * 0.2, ofDividerAt: 0)
        leftSplit.adjustSubviews()

        let middleID = try #require(middle.paneNode?.id)
        let leftID = try #require(leftSplit.paneNode?.id)
        #expect(try #require(hostView.dividerFraction(for: middleID)) > 0.7)
        #expect(try #require(hostView.dividerFraction(for: leftID)) < 0.3)

        workspace.markFocused(d)
        #expect(workspace.close(c))
        // Do not call hostView.synchronize before the second close.
        #expect(workspace.close(d))
        #expect(workspace.focusedController === b)
    }

    @Test func restoredWorkspaceWithoutHostViewUsesRestoredDividerFractions() throws {
        let topLeftID = UUID()
        let bottomLeftID = UUID()
        let rightID = UUID()
        let root: RestorePaneNode = .split(
            .vertical,
            fraction: 0.5,
            first: .split(
                .horizontal,
                fraction: 0.8,
                first: .pane(RestorePane(id: topLeftID, kind: .local)),
                second: .pane(RestorePane(id: bottomLeftID, kind: .local))
            ),
            second: .pane(RestorePane(id: rightID, kind: .local))
        )
        let tab = RestoreTab(focusedPaneID: rightID, root: root)
        var spec = LaunchSpec()
        spec.restoredTab = RestoredTab(tab: tab, panes: [:])

        let workspace = TerminalPaneWorkspace(spec: spec, startsProcesses: false)
        _ = workspace.adoptPaneTree()
        let right = try #require(workspace.controllers.first {
            $0.id == rightID
        })
        let topLeft = try #require(workspace.controllers.first {
            $0.id == topLeftID
        })
        #expect(workspace.hostView == nil)
        #expect(workspace.close(right))
        #expect(workspace.focusedController === topLeft)
    }

    @Test func closingPaneSkipsZeroSizeCollapsedNeighbor() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let topLeft = try #require(workspace.focusedController)
        workspace.split(topLeft, direction: .right)
        let right = try #require(workspace.focusedController)
        workspace.split(topLeft, direction: .down)
        let bottomLeft = try #require(workspace.focusedController)

        let hostView = TerminalPaneHostView(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision)
        hostView.layoutSubtreeIfNeeded()

        let outer = try #require(hostView.subviews.compactMap {
            $0 as? NSSplitView
        }.first)
        let leftSplit = try #require(outer.arrangedSubviews[0] as? TerminalWorkspaceSplitView)
        // First record a large saved fraction, then collapse topLeft to height 0.
        leftSplit.setPosition(320, ofDividerAt: 0)
        leftSplit.adjustSubviews()
        hostView.snapshotDividerPositionsIfSynchronized()
        let leftNodeID = try #require(leftSplit.paneNode?.id)
        #expect(try #require(hostView.dividerFraction(for: leftNodeID)) > 0.7)

        leftSplit.arrangedSubviews[0].frame.size.height = 0
        leftSplit.arrangedSubviews[1].frame.size.height = leftSplit.bounds.height - leftSplit.dividerThickness
        // Persistence keeps the saved non-zero fraction while geometry sees 0.
        #expect(try #require(hostView.dividerFraction(for: leftNodeID)) > 0.7)
        #expect(try #require(hostView.layoutDividerFraction(for: leftNodeID)) == 0)

        workspace.markFocused(right)
        #expect(workspace.close(right))
        #expect(workspace.focusedController === bottomLeft)
    }

    @Test func twoClosesInOneTurnSkipCollapsedPaneWithoutPersistingZero() throws {
        // Tree: V(Outer, V(Middle, H(Left, topLeft, bottomLeft), middlePane), right)
        // Save a high fraction for Left, collapse topLeft to height 0, then close
        // middlePane and right in the same run-loop turn.
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let topLeft = try #require(workspace.focusedController)
        workspace.split(topLeft, direction: .right)
        let right = try #require(workspace.focusedController)
        workspace.split(topLeft, direction: .right)
        let middlePane = try #require(workspace.focusedController)
        workspace.split(topLeft, direction: .down)
        let bottomLeft = try #require(workspace.focusedController)

        let hostView = TerminalPaneHostView(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision)
        hostView.layoutSubtreeIfNeeded()

        let outer = try #require(hostView.subviews.compactMap {
            $0 as? TerminalWorkspaceSplitView
        }.first)
        let middle = try #require(outer.arrangedSubviews[0] as? TerminalWorkspaceSplitView)
        let leftSplit = try #require(middle.arrangedSubviews[0] as? TerminalWorkspaceSplitView)
        leftSplit.setPosition(320, ofDividerAt: 0)
        leftSplit.adjustSubviews()
        hostView.snapshotDividerPositionsIfSynchronized()

        leftSplit.arrangedSubviews[0].frame.size.height = 0
        leftSplit.arrangedSubviews[1].frame.size.height = leftSplit.bounds.height - leftSplit.dividerThickness

        let middleNodeID = try #require(middle.paneNode?.id)
        workspace.markFocused(right)
        #expect(workspace.close(middlePane))
        // After promoting Left into Middle without rebuilding:
        // persistence still sees > 0.7, geometry sees 0.
        #expect(try #require(hostView.dividerFraction(for: middleNodeID)) > 0.7)
        #expect(try #require(hostView.layoutDividerFraction(for: middleNodeID)) == 0)

        #expect(workspace.close(right))
        #expect(workspace.focusedController === bottomLeft)
    }

    @Test func zoomChangeBeforeRebuildPreservesDraggedDividerFraction() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)

        let hostView = TerminalPaneHostView(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision)
        hostView.layoutSubtreeIfNeeded()

        let split = try #require(hostView.subviews.compactMap {
            $0 as? TerminalWorkspaceSplitView
        }.first)
        split.setPosition(480, ofDividerAt: 0)
        split.adjustSubviews()
        let rootID = workspace.root.id
        #expect(try #require(hostView.dividerFraction(for: rootID)) > 0.75)

        workspace.toggleSplitZoom()
        // Before synchronize rebuilds, dividerFraction must still report the dragged value.
        #expect(try #require(hostView.dividerFraction(for: rootID)) > 0.75)
    }

    @Test func restoredFractionsAreClearedOnceHostAdoptsThem() throws {
        let root: RestorePaneNode = .split(
            .vertical,
            fraction: 0.8,
            first: .pane(RestorePane(id: UUID(), kind: .local)),
            second: .pane(RestorePane(id: UUID(), kind: .local))
        )
        var spec = LaunchSpec()
        spec.restoredTab = RestoredTab(tab: RestoreTab(root: root), panes: [:])

        let workspace = TerminalPaneWorkspace(spec: spec, startsProcesses: false)
        let firstHost = TerminalPaneHostView(workspace: workspace)
        #expect(try #require(firstHost.dividerFraction(for: workspace.root.id)) == 0.8)

        let secondHost = TerminalPaneHostView(workspace: workspace)
        #expect(secondHost.dividerFraction(for: workspace.root.id) == nil)
    }

    @Test func keyboardNavigationBreaksTiesInTreeOrderAndIgnoresSubpixelGapDifferences() throws {
        // Even left column: V(H(top, bottom), right).
        // Select-left from right must land on top (tree order), not bottom.
        do {
            let workspace = TerminalPaneWorkspace(startsProcesses: false)
            let top = try #require(workspace.focusedController)
            workspace.split(top, direction: .right)
            let right = try #require(workspace.focusedController)
            workspace.split(top, direction: .down)

            let hostView = TerminalPaneHostView(workspace: workspace)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostView
            hostView.synchronize(revision: workspace.revision)
            hostView.layoutSubtreeIfNeeded()

            workspace.markFocused(right)
            workspace.selectSplit(in: .left)
            #expect(workspace.focusedController === top)
        }

        // Subpixel primary gap difference (8.24pt vs 8.26pt) must not prevent
        // perpendicular alignment from choosing the aligned pane.
        do {
            let aligned = TerminalSessionController(startsProcess: false)
            let misaligned = TerminalSessionController(startsProcess: false)
            let source = CGRect(x: 200, y: 0, width: 200, height: 400)
            // Misaligned is 0.02pt closer horizontally (8.24pt vs 8.26pt) but far off-center.
            let misalignedRect = CGRect(x: 0, y: 300, width: 191.76, height: 100)
            let alignedRect = CGRect(x: 0, y: 150, width: 191.74, height: 100)

            let picked = TerminalPaneWorkspace.closestPane(
                in: .left,
                from: source,
                among: [(misaligned, misalignedRect), (aligned, alignedRect)],
                tolerance: 0.5,
                primaryQuantum: 2,
                tieBreak: .navigation
            )
            #expect(picked === aligned)
        }
    }

    @Test func keyboardNavigationPrefersDirectlyAdjacentPaneOverDistantAlignedPane() throws {
        // Tall 3-column layout: [left | (middleTop / middleBottom) | right]
        // Navigating left from `right` must pick an adjacent middle pane rather
        // than jumping past it to `left`.
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let left = try #require(workspace.focusedController)
        workspace.split(left, direction: .right)
        let middleTop = try #require(workspace.focusedController)
        workspace.split(middleTop, direction: .right)
        let right = try #require(workspace.focusedController)
        workspace.split(middleTop, direction: .down)
        let middleBottom = try #require(workspace.focusedController)

        let hostView = TerminalPaneHostView(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 1000),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision)
        hostView.layoutSubtreeIfNeeded()

        workspace.markFocused(right)
        workspace.selectSplit(in: .left)
        #expect(workspace.focusedController === middleTop || workspace.focusedController === middleBottom)
    }

    @Test func closingUnfocusedPanePreservesCurrentFocus() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let left = try #require(workspace.focusedController)
        workspace.split(left, direction: .right)
        let topRight = try #require(workspace.focusedController)
        workspace.split(topRight, direction: .down)
        let bottomRight = try #require(workspace.focusedController)

        workspace.markFocused(left)
        #expect(workspace.close(bottomRight))
        #expect(workspace.focusedController === left)
    }

    @Test func stressTestRandomizedPaneOperationsAndInvariants() throws {
        var rng = SeededGenerator(seed: 0xC0FFEE_5EED_2026)
        let directions: [TerminalPaneDirection] = [.up, .down, .left, .right]

        for trial in 0..<8 {
            let workspace = TerminalPaneWorkspace(startsProcesses: false)
            let hostView = TerminalPaneHostView(workspace: workspace)
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(400 + (trial % 4) * 150),
                    height: CGFloat(300 + (trial % 3) * 150)
                ),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostView
            hostView.synchronize(revision: workspace.revision)
            hostView.layoutSubtreeIfNeeded()

            for _ in 0..<120 {
                let op = rng.nextInt(upperBound: 100)
                switch op {
                case 0..<28:
                    // Split a random live pane (cap tree size so layout stays fast).
                    if workspace.paneCount < 14, let target = rng.element(from: workspace.controllers) {
                        workspace.split(target, direction: directions[rng.nextInt(upperBound: 4)])
                    }
                case 28..<52:
                    // Close 1 to 3 panes in the same turn (without syncing between them).
                    let burst = 1 + rng.nextInt(upperBound: 3)
                    for _ in 0..<burst where workspace.paneCount > 1 {
                        let closingFocused = rng.nextInt(upperBound: 4) != 0
                        let victim: TerminalSessionController? = closingFocused
                            ? workspace.focusedController
                            : rng.element(from: workspace.controllers)
                        if let victim {
                            let wasFocused = workspace.focusedController === victim
                            #expect(workspace.close(victim))
                            if wasFocused {
                                #expect(workspace.focusedController !== victim)
                            }
                            assertWorkspaceInvariants(workspace, hostView: hostView)
                        }
                    }
                case 52..<64:
                    // Randomly drag a live split divider (or collapse one pane to zero).
                    let splits = allSplitViews(in: hostView)
                    if let split = rng.element(from: splits), split.arrangedSubviews.count == 2 {
                        let total = split.isVertical ? split.bounds.width : split.bounds.height
                        let available = total - split.dividerThickness
                        if available > 2 {
                            if rng.nextInt(upperBound: 8) == 0 {
                                // Simulate a collapsed pane.
                                let collapseFirst = rng.nextInt(upperBound: 2) == 0
                                if split.isVertical {
                                    split.arrangedSubviews[0].frame.size.width = collapseFirst ? 0 : available
                                    split.arrangedSubviews[1].frame.size.width = collapseFirst ? available : 0
                                } else {
                                    split.arrangedSubviews[0].frame.size.height = collapseFirst ? 0 : available
                                    split.arrangedSubviews[1].frame.size.height = collapseFirst ? available : 0
                                }
                            } else {
                                let ratio = CGFloat(10 + rng.nextInt(upperBound: 81)) / 100
                                split.setPosition(available * ratio, ofDividerAt: 0)
                                split.adjustSubviews()
                            }
                        }
                    }
                case 64..<74:
                    // Directional keyboard navigation.
                    workspace.selectSplit(in: directions[rng.nextInt(upperBound: 4)])
                case 74..<82:
                    // Previous / next split navigation.
                    if rng.nextInt(upperBound: 2) == 0 {
                        workspace.selectPreviousSplit()
                    } else {
                        workspace.selectNextSplit()
                    }
                case 82..<90:
                    // Zoom toggle / clear.
                    if rng.nextInt(upperBound: 3) == 0 {
                        workspace.clearSplitZoom()
                    } else {
                        workspace.toggleSplitZoom()
                    }
                case 90..<95:
                    // Equalize or move divider.
                    if rng.nextInt(upperBound: 2) == 0 {
                        workspace.equalizeSplits()
                    } else {
                        workspace.moveDivider(in: directions[rng.nextInt(upperBound: 4)])
                    }
                default:
                    // Mark a random live pane focused.
                    if let target = rng.element(from: workspace.controllers) {
                        workspace.markFocused(target)
                    }
                }

                // Synchronize ~65% of turns so we stress both synced and multi-turn-unsynced states.
                if rng.nextInt(upperBound: 100) < 65 {
                    hostView.synchronize(revision: workspace.revision)
                    hostView.layoutSubtreeIfNeeded()
                }
                assertWorkspaceInvariants(workspace, hostView: hostView)
            }

            // Drain all panes down to 1 and verify final state.
            while workspace.paneCount > 1 {
                let victim = try #require(workspace.focusedController)
                #expect(workspace.close(victim))
                assertWorkspaceInvariants(workspace, hostView: hostView)
            }
            hostView.synchronize(revision: workspace.revision)
            hostView.layoutSubtreeIfNeeded()
            #expect(workspace.paneCount == 1)
            #expect(workspace.zoomedControllerID == nil)
            // Closing the last pane must return false.
            let last = try #require(workspace.focusedController)
            #expect(!workspace.close(last))
        }
    }

    @Test func stressTestRestoredTreesAndExtremeFractions() throws {
        var rng = SeededGenerator(seed: 0xDEAD_BEEF_99)
        let extremeFractions: [Double?] = [nil, 0.0, 0.0001, 0.2, 0.5, 0.8, 0.9999, 1.0, -0.5, 1.5]

        func makeRandomRestoreNode(depth: Int) -> RestorePaneNode {
            if depth >= 4 || (depth >= 1 && rng.nextInt(upperBound: 100) < 35) {
                return .pane(RestorePane(id: UUID(), kind: .local))
            }
            let orientation: TerminalPaneSplit = rng.nextInt(upperBound: 2) == 0 ? .vertical : .horizontal
            let fraction = extremeFractions[rng.nextInt(upperBound: extremeFractions.count)]
            return .split(
                orientation,
                fraction: fraction,
                first: makeRandomRestoreNode(depth: depth + 1),
                second: makeRandomRestoreNode(depth: depth + 1)
            )
        }

        for trial in 0..<20 {
            let root = makeRandomRestoreNode(depth: 0)
            let panes = root.panes
            let focusedID = panes[rng.nextInt(upperBound: panes.count)].id
            var spec = LaunchSpec()
            spec.restoredTab = RestoredTab(
                tab: RestoreTab(focusedPaneID: focusedID, root: root),
                panes: [:]
            )
            let workspace = TerminalPaneWorkspace(spec: spec, startsProcesses: false)
            workspace.adoptPaneTree()

            // Close half the panes before any host view exists.
            let headlessCloses = max(0, workspace.paneCount / 2)
            for _ in 0..<headlessCloses where workspace.paneCount > 1 {
                let victim = try #require(workspace.focusedController)
                #expect(workspace.close(victim))
                assertWorkspaceInvariants(workspace, hostView: nil)
            }

            // Attach a host view mid-flight on alternating trials and drain remaining panes.
            var hostView: TerminalPaneHostView?
            var window: NSWindow?
            if trial.isMultiple(of: 2) {
                let host = TerminalPaneHostView(workspace: workspace)
                let win = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                win.contentView = host
                host.synchronize(revision: workspace.revision)
                host.layoutSubtreeIfNeeded()
                hostView = host
                window = win
            }

            while workspace.paneCount > 1 {
                let victim = try #require(workspace.focusedController)
                #expect(workspace.close(victim))
                if let hostView, rng.nextInt(upperBound: 2) == 0 {
                    hostView.synchronize(revision: workspace.revision)
                    hostView.layoutSubtreeIfNeeded()
                }
                assertWorkspaceInvariants(workspace, hostView: hostView)
            }
            _ = window
        }
    }

    @Test func stressTestClosestPaneIsPermutationInvariant() {
        var rng = SeededGenerator(seed: 0xBA5E_BA11)
        let directions: [TerminalPaneDirection] = [.up, .down, .left, .right]
        let policies: [TerminalPaneWorkspace.PaneNeighborTieBreak] = [.closeSuccessor, .navigation]

        for _ in 0..<200 {
            let source = CGRect(
                x: CGFloat(rng.nextInt(upperBound: 400)),
                y: CGFloat(rng.nextInt(upperBound: 400)),
                width: CGFloat(40 + rng.nextInt(upperBound: 200)),
                height: CGFloat(40 + rng.nextInt(upperBound: 200))
            )
            var candidates: [(controller: TerminalSessionController, rect: CGRect)] = []
            let count = 3 + rng.nextInt(upperBound: 10)
            for _ in 0..<count {
                // Mix normal rects, near-tied subpixel rects, and zero-size rects.
                let jitter = CGFloat(rng.nextInt(upperBound: 5)) * 0.02
                let width: CGFloat = rng.nextInt(upperBound: 10) == 0
                    ? 0 : CGFloat(20 + rng.nextInt(upperBound: 200)) + jitter
                let height: CGFloat = rng.nextInt(upperBound: 10) == 0
                    ? 0 : CGFloat(20 + rng.nextInt(upperBound: 200)) + jitter
                let rect = CGRect(
                    x: CGFloat(rng.nextInt(upperBound: 600)) + jitter,
                    y: CGFloat(rng.nextInt(upperBound: 600)) + jitter,
                    width: width,
                    height: height
                )
                candidates.append((TerminalSessionController(startsProcess: false), rect))
            }
            for direction in directions {
                for policy in policies {
                    let expected = TerminalPaneWorkspace.closestPane(
                        in: direction,
                        from: source,
                        among: candidates,
                        tolerance: 0.5,
                        primaryQuantum: 2,
                        tieBreak: policy
                    )
                    // Reversed and shuffled permutations must pick the exact same pane.
                    let reversed = TerminalPaneWorkspace.closestPane(
                        in: direction,
                        from: source,
                        among: candidates.reversed(),
                        tolerance: 0.5,
                        primaryQuantum: 2,
                        tieBreak: policy
                    )
                    #expect(expected === reversed)
                    var shuffled = candidates
                    rng.shuffle(&shuffled)
                    let fromShuffled = TerminalPaneWorkspace.closestPane(
                        in: direction,
                        from: source,
                        among: shuffled,
                        tolerance: 0.5,
                        primaryQuantum: 2,
                        tieBreak: policy
                    )
                    #expect(expected === fromShuffled)
                }
            }
        }
    }

    private func assertWorkspaceInvariants(
        _ workspace: TerminalPaneWorkspace,
        hostView: TerminalPaneHostView?
    ) {
        let live = workspace.controllers
        let liveIDs = Set(live.map(\.id))
        #expect(!live.isEmpty)
        #expect(liveIDs.count == live.count)
        #expect(Set(workspace.creationOrder) == liveIDs)
        #expect(workspace.creationOrder.count == live.count)
        #expect(Set(workspace.focusHistory).isSubset(of: liveIDs))
        #expect(Set(workspace.focusHistory).count == workspace.focusHistory.count)
        let focused = workspace.focusedController
        #expect(focused != nil)
        if let focused {
            #expect(liveIDs.contains(focused.id))
        }
        if let zoomed = workspace.zoomedControllerID {
            #expect(live.count > 1)
            #expect(liveIDs.contains(zoomed))
        }
        if let hostView {
            for splitID in splitNodeIDs(in: workspace.root) {
                if let persisted = hostView.dividerFraction(for: splitID) {
                    #expect(persisted.isFinite && persisted > 0 && persisted <= 1)
                }
                if let layout = hostView.layoutDividerFraction(for: splitID) {
                    #expect(layout.isFinite && layout >= 0 && layout <= 1)
                }
            }
        }
    }

    private func splitNodeIDs(in node: TerminalPaneNode) -> [UUID] {
        guard case .split(_, let first, let second) = node.content else {
            return []
        }
        return [node.id] + splitNodeIDs(in: first) + splitNodeIDs(in: second)
    }

    private func allSplitViews(in view: NSView) -> [TerminalWorkspaceSplitView] {
        var result: [TerminalWorkspaceSplitView] = []
        if let split = view as? TerminalWorkspaceSplitView {
            result.append(split)
        }
        for subview in view.subviews {
            result.append(contentsOf: allSplitViews(in: subview))
        }
        return result
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextInt(upperBound: Int) -> Int {
        Int(nextUInt64() % UInt64(upperBound))
    }

    mutating func element<T>(from array: [T]) -> T? {
        guard !array.isEmpty else {
            return nil
        }
        return array[nextInt(upperBound: array.count)]
    }

    mutating func shuffle<T>(_ array: inout [T]) {
        guard array.count > 1 else {
            return
        }
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            let j = nextInt(upperBound: i + 1)
            array.swapAt(i, j)
        }
    }
}
