import AppKit
import Testing
@testable import Tecolot

@MainActor
struct PaneFocusAnimationTests {
    @Test func outlineUpdatesDisableActionsAndRestoreTheOuterTransaction() {
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        PaneCardGeometry.withoutImplicitAnimations {
            #expect(CATransaction.disableActions())
            PaneCardGeometry.withoutImplicitAnimations {
                #expect(CATransaction.disableActions())
            }
            #expect(CATransaction.disableActions())
        }
        #expect(!CATransaction.disableActions())
        CATransaction.commit()
    }

    @Test func tabOutlineReparentingAndFocusAreImmediate() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let host = TerminalPaneHostView(workspace: workspace)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        host.synchronize(revision: workspace.revision)
        host.layoutSubtreeIfNeeded()
        let overlay = PaneCardOutlineOverlay(frame: host.bounds)
        let root = NSView(frame: host.bounds)
        root.wantsLayer = true
        root.addSubview(host)
        root.addSubview(overlay)
        let cards = host.visibleCards
        #expect(cards.count == 2)
        for _ in 0..<3 {
            overlay.update(cards: [])
            overlay.update(cards: cards)
            host.isHidden.toggle()
            workspace.markFocused(first)
            cards.forEach {
                $0.refreshAppearance()
            }
            root.layoutSubtreeIfNeeded()
            CATransaction.flush()
            for card in cards {
                #expect(card.outlineLayer.superlayer === overlay.layer)
                #expect(card.outlineLayer.frame == card.convert(card.bounds, to: overlay))
                #expect(card.outlineLayer.animationKeys()?.isEmpty != false)
                for key in ["position", "bounds", "path", "strokeColor", "lineWidth", "opacity", "transform"] {
                    #expect(card.outlineLayer.actions?[key] is NSNull)
                }
            }
        }
    }
}
