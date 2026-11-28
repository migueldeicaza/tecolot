//
//  ThemeHoverCard.swift
//  Tecolot
//
//  The hover card for narrow layouts (such as the toolbar popover): shows the
//  theme name, the user's selected day-to-day preview (Shell, mc, Claude, or
//  Icon), the 16-color ANSI strip, and plain-language legibility & fidelity
//  summary rows. No raw OKLab values.
//
import SwiftUI

struct ThemeHoverCard: View {
    let theme: TerminalTheme
    let metrics: ThemeMetrics
    let catalog: CatalogStatistics?
    /// Selected hover preview sample (nil hides the miniature preview block)
    var previewPage: ThemePreviewPage? = .shell
    /// Count of other themes essentially co-located with this one
    var nearbyCount: Int = 0
    /// Rank relative to the pinned theme in Similarity Space 3D.
    var similarityRank: (rank: Int, total: Int)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(theme.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ThemeArchetypeBadge(archetype: metrics.ansiArchetype)
            }
            if let previewPage {
                ThemePreviewPageView(page: previewPage, theme: theme, hover: true)
                    .frame(width: 240, height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
            }
            ThemeAnsiSwatchStrip(theme: theme, metrics: metrics, compact: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                ThemeStatRow("Background", metrics.backgroundDescription)
                ThemeStatRow("Contrast", "\(ThemeMetricFormatting.contrastRatio(metrics.foregroundContrast)) · git diff \(metrics.diffClarityBucket.lowercased())")
                ThemeStatRow("Dimmed text", "\(ThemeMetricFormatting.contrastRatio(metrics.dimmedTextContrast)) (\(metrics.dimmedTextBucket.lowercased()))")
                if metrics.hasRepurposedBrights {
                    ThemeStatRow("ANSI brights", "Repurposed (Solarized-style)")
                } else if let catalog {
                    ThemeStatRow(
                        "Palette",
                        "\(ThemeMetricFormatting.percentile(metrics.ansiColorfulness, in: catalog.colorfulnessSorted)) colorful, "
                            + "\(ThemeMetricFormatting.percentile(metrics.ansiSeparationP10, in: catalog.distinctnessSorted)) distinct"
                    )
                }
            }
            .font(.caption)
            if nearbyCount > 0 {
                Text("+\(nearbyCount) nearby theme\(nearbyCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let similarityRank {
                Text("#\(similarityRank.rank) closest of \(similarityRank.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Keys 1–4 switch preview · 0 hides")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(radius: 6, y: 2)
    }
}


#Preview("Theme Hover Card") {
    let theme = SettingsPreviewData.themes.theme(
        named: SettingsPreviewData.profile.darkThemeName
    )

    if let metrics = SettingsPreviewData.themeIndex.metrics[theme.name] {
        ThemeHoverCard(
            theme: theme,
            metrics: metrics,
            catalog: SettingsPreviewData.themeIndex.catalog,
            nearbyCount: 2
        )
        .padding()
    }
}
