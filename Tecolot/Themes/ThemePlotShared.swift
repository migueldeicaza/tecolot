//
//  ThemePlotShared.swift
//  Tecolot
//
//  Shared UI components, formatting helpers, and spatial plot utilities used
//  across ThemeBrowserView, ThemeStripWallView, ThemeMapView, ThemeSpace3DView,
//  ThemeHoverCard, ThemeInspectorPanel, and ThemeEditorView.
//
import SwiftUI

/// Plain-language metric formatting shared by ThemeHoverCard and ThemeInspectorPanel.
enum ThemeMetricFormatting {
    static func contrastRatio(_ contrast: Double) -> String {
        String(format: "%.1f:1", contrast)
    }

    static func percentile(_ value: Double, in sorted: [Double]) -> String {
        let rank = CatalogStatistics.percentileRank(of: value, in: sorted)
        return "\(Int((rank * 100).rounded()))%"
    }
}

/// Shared key/value GridRow used in ThemeHoverCard and ThemeInspectorPanel.
struct ThemeStatRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .lineLimit(1)
        }
    }
}

/// Unified Preview menu Picker (`None / Shell / mc / Claude / Icon`) shared by
/// ThemeBrowserView, ThemeInspectorPanel, and ThemeEditorView.
struct ThemePreviewMenuPicker: View {
    @Binding var selection: ThemePreviewPage?
    var controlSize: ControlSize = .regular
    var hideLabel: Bool = false

    var body: some View {
        let picker = Picker("Preview", selection: $selection) {
            Text("None").tag(ThemePreviewPage?.none)
            Divider()
            ForEach(ThemePreviewPage.allCases) { page in
                Text(page.title).tag(Optional(page))
            }
        }
        .pickerStyle(.menu)
        .controlSize(controlSize)
        .fixedSize()

        if hideLabel {
            picker.labelsHidden()
        } else {
            picker
        }
    }
}

/// Compact "CUSTOM" capsule badge shown on user-defined themes in Grid and Strips.
struct ThemeCustomBadge: View {
    var compact: Bool = false

    var body: some View {
        Text("CUSTOM")
            .font(compact ? .system(size: 8, weight: .bold) : .caption2.bold())
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 4 : 5)
            .padding(.vertical, compact ? 1.5 : 2)
            .background(.regularMaterial, in: Capsule())
            .padding(compact ? 4 : 5)
            .accessibilityLabel("Custom theme")
    }
}

/// Standard context menu items for a theme in Grid and Strips.
struct ThemeContextMenuItems: View {
    let theme: TerminalTheme
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    let onShowSimilar: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", action: onToggleFavorite)
        Button("Show Similar Themes", action: onShowSimilar)
        Button(theme.isBuiltIn ? "Duplicate & Edit…" : "Edit…", action: onEdit)
        if !theme.isBuiltIn {
            Button("Delete User Theme", role: .destructive, action: onDelete)
        }
    }
}

/// Spatial navigation, hover-card placement, and accessibility helpers shared
/// by the 2D map and 3D space views.
enum ThemePlotInteraction {
    struct ScreenCandidate {
        let id: String
        let screenPoint: CGPoint
    }

    static func directionVector(for key: KeyEquivalent) -> CGVector? {
        switch key {
        case .upArrow: CGVector(dx: 0, dy: -1)
        case .downArrow: CGVector(dx: 0, dy: 1)
        case .leftArrow: CGVector(dx: -1, dy: 0)
        case .rightArrow: CGVector(dx: 1, dy: 0)
        default: nil
        }
    }

    /// Nearest matching theme in an arrow direction, penalized by angular
    /// deviation (spec §45) so keyboard navigation feels spatial.
    static func nextTheme(
        from anchorName: String,
        anchorPoint: CGPoint,
        direction: CGVector,
        candidates: [ScreenCandidate],
        matching: Set<String>
    ) -> String? {
        var best: (name: String, score: CGFloat)?
        for candidate in candidates where matching.contains(candidate.id) && candidate.id != anchorName {
            let dx = candidate.screenPoint.x - anchorPoint.x
            let dy = candidate.screenPoint.y - anchorPoint.y
            let along = dx * direction.dx + dy * direction.dy
            guard along > 0 else {
                continue
            }
            let distance = hypot(dx, dy)
            guard distance > 0 else {
                continue
            }
            let anglePenalty = 1 - along / distance
            let score = distance * (1 + 3 * anglePenalty)
            if score < (best?.score ?? .infinity) {
                best = (candidate.id, score)
            }
        }
        return best?.name
    }

    /// Computes a clamped top-left offset for a floating hover card so it stays
    /// inside the plot container and avoids covering the hovered marker.
    static func hoverCardOffset(
        around anchor: CGPoint,
        in containerSize: CGSize,
        hasPreview: Bool
    ) -> CGPoint {
        let cardHeight: CGFloat = hasPreview ? 300 : 175
        let cardWidth: CGFloat = 260
        let x = min(max(anchor.x + 18, 4), max(containerSize.width - cardWidth - 4, 4))
        let above = anchor.y > containerSize.height * 0.50
        let y = above
            ? max(anchor.y - cardHeight - 14, 4)
            : min(anchor.y + 14, max(containerSize.height - cardHeight - 4, 4))
        return CGPoint(x: x, y: y)
    }

    static func inspectorStatusLabel(isHovering: Bool, isPinned: Bool) -> String {
        if isHovering { return "Hovering" }
        if isPinned { return "Pinned" }
        return "Selected"
    }
}

/// Shared accessibility children builder for both 2D and 3D plot views.
struct ThemePlotAccessibilityPoints: View {
    let ids: [String]
    let metrics: [String: ThemeMetrics]
    let catalog: CatalogStatistics?
    let selectedThemeName: String
    let onSelect: (String) -> Void

    var body: some View {
        ForEach(ids, id: \.self) { id in
            if let themeMetrics = metrics[id] {
                Color.clear
                    .accessibilityLabel(ThemeMapView.accessibilityLabel(
                        name: id, metrics: themeMetrics, catalog: catalog
                    ))
                    .accessibilityAddTraits(
                        id == selectedThemeName ? [.isButton, .isSelected] : .isButton
                    )
                    .accessibilityAction {
                        onSelect(id)
                    }
            }
        }
    }
}

/// Shared docked inspector wrapper used by ThemeMapView and ThemeSpace3DView.
struct ThemePlotDockedInspector: View {
    let themes: [TerminalTheme]
    let metrics: [String: ThemeMetrics]
    let catalog: CatalogStatistics?
    let hoveredThemeName: String?
    let pinnedThemeName: String?
    let selectedThemeName: String
    @Binding var previewPage: ThemePreviewPage?
    let nearbyCount: Int
    var similarityRank: (rank: Int, total: Int)? = nil

    var body: some View {
        let inspectedName = hoveredThemeName ?? pinnedThemeName ?? selectedThemeName
        let isHovering = hoveredThemeName != nil
        if
            let theme = themes.first(where: { $0.name == inspectedName }),
            let themeMetrics = metrics[inspectedName] {
            ThemeInspectorPanel(
                theme: theme,
                metrics: themeMetrics,
                catalog: catalog,
                statusLabel: ThemePlotInteraction.inspectorStatusLabel(
                    isHovering: isHovering, isPinned: pinnedThemeName != nil
                ),
                previewPage: $previewPage,
                nearbyCount: isHovering ? max(nearbyCount, 0) : 0,
                canCycleNearby: isHovering,
                similarityRank: similarityRank
            )
        } else {
            Color.clear.frame(width: 262)
        }
    }
}
