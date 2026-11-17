import AppKit
import SwiftUI

/// Uses one continuous corner for card clips, outlines, shadows and snapshots.
nonisolated enum PaneCardGeometry {
    static let radius: CGFloat = 10

    /// Focus decoration must appear at its final geometry, even when moved between hosts.
    static func withoutImplicitAnimations(_ update: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        update()
    }

    /// Outlines never interpolate stroke or position when a tab becomes visible.
    static let outlineActions = Dictionary(uniqueKeysWithValues:
        ["position", "bounds", "path", "strokeColor", "lineWidth", "opacity", "transform", "sublayers"].map {
            ($0, NSNull())
        })

    static func path(in rect: CGRect, radius: CGFloat = radius) -> CGPath {
        RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
    }

    /// Chooses the visible cards touching the top edge in AppKit's bottom-up coordinates.
    static func topCorners(in frames: [UUID: CGRect]) -> (left: UUID?, right: UUID?) {
        guard let top = frames.values.map(\.maxY).max() else {
            return (nil, nil)
        }
        let row = frames.filter {
            abs($0.value.maxY - top) < 1
        }
        return (
            row.min {
                $0.value.minX < $1.value.minX
            }?.key,
            row.max {
                $0.value.maxX < $1.value.maxX
            }?.key
        )
    }
}

/// Outlines can extend into the gap without being clipped by split-view child bounds.
final class PaneCardOutlineOverlay: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(cards: [TerminalPaneCardView]) {
        PaneCardGeometry.withoutImplicitAnimations {
            let outlines = cards.map(\.outlineLayer)
            for existing in layer?.sublayers ?? [] where !outlines.contains(where: {
                $0 === existing
            }) {
                existing.removeFromSuperlayer()
            }
            for card in cards {
                card.setOutlineContainer(self)
            }
        }
    }
}
