//
//  ThemeHoverCard.swift
//  Tecolot
//
//  The hover/pin card of the theme map: the theme name, the same miniature
//  the card grid uses (the two previews must never disagree), and a few
//  descriptive stat rows. No raw OKLab values.
//
import SwiftUI

struct ThemeHoverCard: View {
    let theme: TerminalTheme
    let metrics: ThemeMetrics
    let catalog: CatalogStatistics?
    /// Count of other themes essentially co-located with this one
    var nearbyCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(theme.name)
                .font(.headline)
                .lineLimit(1)
            ThemePreview(theme: theme, fontSize: 10, extended: true)
                .frame(width: 220, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                statRow("Background", metrics.backgroundDescription)
                statRow("Contrast", ratio(metrics.foregroundContrast))
                statRow("ANSI visibility", ratio(metrics.ansiContrastP10))
                if let catalog {
                    statRow(
                        "Palette",
                        "\(percent(metrics.ansiColorfulness, in: catalog.colorfulnessSorted)) colorful, "
                        + "\(percent(metrics.ansiSeparationP10, in: catalog.distinctnessSorted)) distinct"
                    )
                }
            }
            .font(.caption)
            if nearbyCount > 0 {
                Text("+\(nearbyCount) nearby theme\(nearbyCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(radius: 6, y: 2)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
        }
    }

    private func ratio(_ contrast: Double) -> String {
        String(format: "%.1f:1", contrast)
    }

    private func percent(_ value: Double, in sorted: [Double]) -> String {
        let rank = CatalogStatistics.percentileRank(of: value, in: sorted)
        return "\(Int((rank * 100).rounded()))%"
    }
}
