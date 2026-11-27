//
//  ThemeStripWallView.swift
//  Tecolot
//
//  The Aligned Palette Strip Wall: a comparative browser showing each theme
//  as a scannable row with the actual day-to-day sample preview (Shell, mc,
//  Claude, or Icon), a clickable (i) info button on the bottom-right of each
//  preview for full ANSI palette inspection, and a two-line 16-color ANSI
//  block (normal 0…7 over bright 8…15) aligned under a canonical 8-column
//  reference header.
//
import SwiftUI

enum ThemeToneFilter: String, CaseIterable, Identifiable {
    case all
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

private enum StripWallLayout {
    static let nameColumnWidth: CGFloat = 132
    static let swatchWidth: CGFloat = 17
    static let swatchHeight: CGFloat = 20
    static let swatchSpacing: CGFloat = 3
    static let swatchBoxPadding: CGFloat = 5
    static let sampleHeight: CGFloat = 76
    static let columnSpacing: CGFloat = 10

    /// Exact width of the 8-column ANSI swatch card (normal row over bright row).
    static let colorsColumnWidth: CGFloat =
        swatchWidth * 8 + swatchSpacing * 7 + swatchBoxPadding * 2
}

struct ThemeStripWallView: View {
    let themes: [TerminalTheme]
    let favorites: Set<String>
    let metrics: [String: ThemeMetrics]
    let catalog: CatalogStatistics?
    let selectedThemeName: String
    @Binding var previewPage: ThemePreviewPage?
    let onSelect: (TerminalTheme) -> Void
    let onToggleFavorite: (String) -> Void
    let onShowSimilar: (String) -> Void
    let onEdit: (TerminalTheme) -> Void
    let onDelete: (TerminalTheme) -> Void

    @State private var archetypeFilter: ANSIDeviationArchetype? = nil
    @State private var toneFilter: ThemeToneFilter = .all

    private var filteredThemes: [TerminalTheme] {
        themes.filter { theme in
            switch toneFilter {
            case .all:
                break
            case .dark:
                if !theme.isDark { return false }
            case .light:
                if theme.isDark { return false }
            }
            if let archetypeFilter {
                return metrics[theme.name]?.ansiArchetype == archetypeFilter
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            referenceHeader
            Divider()
            stripList
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in
            handleKey(press)
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Picker("Tone", selection: $toneFilter) {
                    ForEach(ThemeToneFilter.allCases) { tone in
                        Text(tone.title).tag(tone)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()

                Divider().frame(height: 16)

                filterChip(title: "All (\(themes.count))", isSelected: archetypeFilter == nil) {
                    archetypeFilter = nil
                }
                ForEach(ANSIDeviationArchetype.allCases) { archetype in
                    let count = themes.filter { metrics[$0.name]?.ansiArchetype == archetype }.count
                    filterChip(
                        title: "\(archetype.title) (\(count))",
                        isSelected: archetypeFilter == archetype
                    ) {
                        archetypeFilter = (archetypeFilter == archetype) ? nil : archetype
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pinned canonical ANSI reference header

    private var referenceHeader: some View {
        HStack(spacing: StripWallLayout.columnSpacing) {
            Text("Theme")
                .frame(width: StripWallLayout.nameColumnWidth, alignment: .leading)
            Text("Sample")
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 2) {
                HStack(spacing: StripWallLayout.swatchSpacing) {
                    ForEach(0..<8, id: \.self) { index in
                        VStack(spacing: 2) {
                            Text(CanonicalAnsiReference.allShortLabels[index])
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(
                                    CanonicalAnsiReference.referenceColor(forAnsiIndex: index)
                                        ?? Color.secondary.opacity(0.3)
                                )
                                .frame(width: StripWallLayout.swatchWidth - 2, height: 2.5)
                        }
                        .frame(width: StripWallLayout.swatchWidth)
                    }
                }
                .padding(.horizontal, StripWallLayout.swatchBoxPadding)
            }
            .frame(width: StripWallLayout.colorsColumnWidth)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.35))
    }

    // MARK: - Scrollable rows

    private var stripList: some View {
        let rows = filteredThemes
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(rows) { theme in
                        ThemeStripRow(
                            theme: theme,
                            metrics: metrics[theme.name],
                            catalog: catalog,
                            isSelected: theme.name == selectedThemeName,
                            isFavorite: favorites.contains(theme.name),
                            previewPage: $previewPage,
                            onSelect: { onSelect(theme) },
                            onToggleFavorite: { onToggleFavorite(theme.name) }
                        )
                        .id(theme.name)
                        .contextMenu {
                            Button(favorites.contains(theme.name) ? "Remove from Favorites" : "Add to Favorites") {
                                onToggleFavorite(theme.name)
                            }
                            Button("Show Similar Themes") {
                                onShowSimilar(theme.name)
                            }
                            Button(theme.isBuiltIn ? "Duplicate & Edit…" : "Edit…") {
                                onEdit(theme)
                            }
                            if !theme.isBuiltIn {
                                Button("Delete User Theme", role: .destructive) {
                                    onDelete(theme)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .onChange(of: selectedThemeName) { _, newName in
                if rows.contains(where: { $0.name == newName }) {
                    withAnimation(.snappy(duration: 0.15)) {
                        proxy.scrollTo(newName)
                    }
                }
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if let mappedPreview = ThemePreviewPage.fromShortcutCharacter(press.characters) {
            previewPage = mappedPreview
            return .handled
        }
        let rows = filteredThemes
        guard !rows.isEmpty else { return .ignored }
        switch press.key {
        case .upArrow, .downArrow:
            let target: TerminalTheme
            if let currentIndex = rows.firstIndex(where: { $0.name == selectedThemeName }) {
                let nextIndex = press.key == .downArrow
                    ? min(currentIndex + 1, rows.count - 1)
                    : max(currentIndex - 1, 0)
                target = rows[nextIndex]
            } else {
                target = press.key == .downArrow ? rows[0] : rows[rows.count - 1]
            }
            onSelect(target)
            return .handled
        default:
            return .ignored
        }
    }
}

private struct ThemeStripRow: View {
    let theme: TerminalTheme
    let metrics: ThemeMetrics?
    let catalog: CatalogStatistics?
    let isSelected: Bool
    let isFavorite: Bool
    @Binding var previewPage: ThemePreviewPage?
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: StripWallLayout.columnSpacing) {
            infoColumn
                .frame(width: StripWallLayout.nameColumnWidth, alignment: .leading)
            samplePreview
                .frame(minWidth: 140, maxWidth: .infinity)
            twoLineAnsiColumn
                .frame(width: StripWallLayout.colorsColumnWidth)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var rowBackground: Color {
        isSelected ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.015)
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(isFavorite ? .yellow : .secondary)
                        .opacity(isFavorite ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")

                Text(theme.name)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            if let metrics {
                HStack(spacing: 4) {
                    ThemeArchetypeBadge(archetype: metrics.ansiArchetype)
                    if metrics.hasRepurposedBrights {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("Bright ANSI slots are repurposed (Solarized-style)")
                    }
                }
                Text("\(metrics.backgroundLightnessBucket) · \(String(format: "%.1f:1", metrics.foregroundContrast))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The real day-to-day sample preview (Shell, mc, Claude, or Icon), with a
    /// clickable (i) info button on its bottom-right corner.
    private var samplePreview: some View {
        ThemePreviewPageView(page: previewPage ?? .shell, theme: theme, compact: true)
            .frame(height: StripWallLayout.sampleHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if !theme.isBuiltIn {
                    Text("CUSTOM")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let metrics {
                    ThemeInfoPopoverButton(
                        theme: theme,
                        metrics: metrics,
                        catalog: catalog,
                        previewPage: $previewPage
                    )
                    .padding(4)
                }
            }
    }

    /// Two stacked 8-color ANSI rows on the theme's background:
    /// top line = normal colors (0…7), bottom line = bright/highlighted colors (8…15).
    private var twoLineAnsiColumn: some View {
        VStack(spacing: 5) {
            swatchRow(range: 0..<8)
            swatchRow(range: 8..<16)
        }
        .padding(StripWallLayout.swatchBoxPadding)
        .frame(height: StripWallLayout.sampleHeight)
        .background(theme.background.swiftUIColor, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }

    private func swatchRow(range: Range<Int>) -> some View {
        HStack(spacing: StripWallLayout.swatchSpacing) {
            ForEach(range, id: \.self) { index in
                let fidelity = metrics?.slotFidelity(forAnsiIndex: index)
                let deviated = fidelity.map { $0 < 0.45 } ?? false
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ansi(index))
                        .frame(width: StripWallLayout.swatchWidth, height: StripWallLayout.swatchHeight)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(theme.foreground.swiftUIColor.opacity(0.18), lineWidth: 0.5)
                        )
                    Circle()
                        .fill(deviated ? Color.orange : Color.clear)
                        .frame(width: 3, height: 3)
                }
            }
        }
    }

    private func ansi(_ index: Int) -> Color {
        index < theme.ansi.count ? theme.ansi[index].swiftUIColor : theme.foreground.swiftUIColor
    }
}
