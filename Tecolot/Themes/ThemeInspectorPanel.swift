//
//  ThemeInspectorPanel.swift
//  Tecolot
//
//  The live docked inspector shared by the 2D map, 3D spaces, and Palette
//  Strip Wall when wide enough to sit beside the visualization without
//  occluding neighbors. Includes:
//    - Selectable day-to-day preview (None / Shell / mc / Claude / Icon)
//    - ANSI Hue-Drift Wheel showing how normal & bright slots relate to
//      canonical ANSI hues (faithful vs. cohesively shifted vs. monochrome)
//    - 16-color ANSI swatch strip with per-slot deviation ticks
//    - Plain-language day-to-day legibility readouts (no raw OKLab numbers)
//
import SwiftUI

/// Reference RGB colors for the 6 canonical chromatic ANSI slots (1…6),
/// used on the Hue-Drift Wheel anchors and the Strip Wall reference bar.
enum CanonicalAnsiReference {
    struct Slot: Identifiable {
        let index: Int
        let shortLabel: String
        let hueDegrees: Double
        let referenceColor: Color

        var id: Int { index }
    }

    static let chromaticSlots: [Slot] = [
        Slot(index: 1, shortLabel: "R", hueDegrees: 27.0, referenceColor: Color(red: 0.88, green: 0.27, blue: 0.24)),
        Slot(index: 2, shortLabel: "G", hueDegrees: 142.0, referenceColor: Color(red: 0.22, green: 0.78, blue: 0.34)),
        Slot(index: 3, shortLabel: "Y", hueDegrees: 95.0, referenceColor: Color(red: 0.88, green: 0.70, blue: 0.14)),
        Slot(index: 4, shortLabel: "B", hueDegrees: 256.0, referenceColor: Color(red: 0.24, green: 0.52, blue: 0.96)),
        Slot(index: 5, shortLabel: "M", hueDegrees: 328.0, referenceColor: Color(red: 0.84, green: 0.30, blue: 0.80)),
        Slot(index: 6, shortLabel: "C", hueDegrees: 197.0, referenceColor: Color(red: 0.16, green: 0.74, blue: 0.80))
    ]

    static let allShortLabels = ["Bk", "R", "G", "Y", "B", "M", "C", "W"]

    static func referenceColor(forAnsiIndex index: Int) -> Color? {
        let base = index <= 7 ? index : index - 8
        return chromaticSlots.first(where: { $0.index == base })?.referenceColor
    }
}

/// Compact pill showing a theme's ANSI semantic archetype.
struct ThemeArchetypeBadge: View {
    let archetype: ANSIDeviationArchetype

    private var tint: Color {
        switch archetype {
        case .faithful:
            return .green
        case .softMuted:
            return .blue
        case .stylizedRemapped:
            return .purple
        case .monochromeTinted:
            return .orange
        }
    }

    var body: some View {
        Text(archetype.title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Compact 2×8 ANSI swatch bar rendered on the theme's background, with tiny
/// deviation ticks under chromatic slots whose fidelity drops below 0.45.
struct ThemeAnsiSwatchStrip: View {
    let theme: TerminalTheme
    let metrics: ThemeMetrics
    var compact = false

    private var swatchHeight: CGFloat {
        compact ? 11 : 14
    }

    var body: some View {
        VStack(spacing: compact ? 2 : 3) {
            row(range: 0..<8)
            row(range: 8..<16)
        }
        .padding(compact ? 4 : 6)
        .background(theme.background.swiftUIColor, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }

    private func row(range: Range<Int>) -> some View {
        HStack(spacing: compact ? 2 : 3) {
            ForEach(range, id: \.self) { index in
                let color = index < theme.ansi.count ? theme.ansi[index] : theme.foreground
                let fidelity = metrics.slotFidelity(forAnsiIndex: index)
                let deviated = fidelity.map { $0 < 0.45 } ?? false
                VStack(spacing: 1) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.swiftUIColor)
                        .frame(height: swatchHeight)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(theme.foreground.swiftUIColor.opacity(0.16), lineWidth: 0.5)
                        )
                    if !compact {
                        Circle()
                            .fill(deviated ? Color.orange : Color.clear)
                            .frame(width: 3, height: 3)
                    }
                }
            }
        }
    }
}

/// Polar fingerprint showing where each of the theme's 6 chromatic ANSI slots
/// lands in OKLCH (angle = hue, radius = chroma) relative to its canonical
/// anchor on the outer rim.
struct AnsiHueWheelView: View {
    let theme: TerminalTheme
    let metrics: ThemeMetrics

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outerRadius = side * 0.41
            let maxChroma = 0.22

            // Concentric reference rings: muted threshold (0.07) and vivid rim
            let mutedRadius = outerRadius * (ThemeAnalyzer.chromaticSufficiencyThreshold / maxChroma)
            let mutedRing = Path(ellipseIn: CGRect(
                x: center.x - mutedRadius, y: center.y - mutedRadius,
                width: mutedRadius * 2, height: mutedRadius * 2
            ))
            context.stroke(
                mutedRing,
                with: .color(theme.foreground.swiftUIColor.opacity(0.16)),
                style: StrokeStyle(lineWidth: 0.75, dash: [2, 2])
            )

            let outerRing = Path(ellipseIn: CGRect(
                x: center.x - outerRadius, y: center.y - outerRadius,
                width: outerRadius * 2, height: outerRadius * 2
            ))
            context.stroke(
                outerRing,
                with: .color(theme.foreground.swiftUIColor.opacity(0.24)),
                lineWidth: 0.75
            )

            func point(angleDegrees: Double, radius: CGFloat) -> CGPoint {
                let rad = angleDegrees * .pi / 180
                return CGPoint(
                    x: center.x + radius * cos(rad),
                    y: center.y - radius * sin(rad)
                )
            }

            func colorPosition(for ansiIndex: Int) -> CGPoint {
                guard ansiIndex < theme.ansi.count else {
                    return center
                }
                let pc = PerceptualColor(theme.ansi[ansiIndex])
                guard let hue = pc.hue else {
                    return center
                }
                let r = outerRadius * CGFloat(min(pc.chroma / maxChroma, 0.92))
                return point(angleDegrees: hue, radius: r)
            }

            // Draw canonical anchor pips and tethers to actual normal & bright colors
            for slot in CanonicalAnsiReference.chromaticSlots {
                let anchor = point(angleDegrees: slot.hueDegrees, radius: outerRadius)
                let labelPos = point(angleDegrees: slot.hueDegrees, radius: outerRadius + 9)
                let normalPos = colorPosition(for: slot.index)
                let brightPos = colorPosition(for: slot.index + 8)

                // Tether from canonical anchor to normal ANSI color
                var tether = Path()
                tether.move(to: anchor)
                tether.addLine(to: normalPos)
                context.stroke(
                    tether,
                    with: .color(slot.referenceColor.opacity(0.55)),
                    lineWidth: 1.1
                )

                // Subtle secondary tether to bright variant when it moves noticeably
                let brightGap = hypot(brightPos.x - normalPos.x, brightPos.y - normalPos.y)
                if brightGap > 3 {
                    var brightTether = Path()
                    brightTether.move(to: normalPos)
                    brightTether.addLine(to: brightPos)
                    context.stroke(
                        brightTether,
                        with: .color(theme.foreground.swiftUIColor.opacity(0.30)),
                        style: StrokeStyle(lineWidth: 0.75, dash: [1.5, 1.5])
                    )
                }

                // Canonical anchor pip on the rim
                let anchorDot = Path(ellipseIn: CGRect(
                    x: anchor.x - 2.2, y: anchor.y - 2.2, width: 4.4, height: 4.4
                ))
                context.fill(anchorDot, with: .color(slot.referenceColor))

                // Short canonical letter outside the rim
                context.draw(
                    Text(slot.shortLabel)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(slot.referenceColor.opacity(0.9)),
                    at: labelPos
                )

                // Bright ANSI dot (smaller hollow ring)
                if slot.index + 8 < theme.ansi.count, brightGap > 3 {
                    let brightColor = theme.ansi[slot.index + 8].swiftUIColor
                    let brightDot = Path(ellipseIn: CGRect(
                        x: brightPos.x - 2.6, y: brightPos.y - 2.6, width: 5.2, height: 5.2
                    ))
                    context.fill(brightDot, with: .color(brightColor))
                    context.stroke(
                        brightDot,
                        with: .color(theme.foreground.swiftUIColor.opacity(0.65)),
                        lineWidth: 0.75
                    )
                }

                // Normal ANSI dot (filled circle with crisp rim)
                if slot.index < theme.ansi.count {
                    let actualColor = theme.ansi[slot.index].swiftUIColor
                    let dot = Path(ellipseIn: CGRect(
                        x: normalPos.x - 3.6, y: normalPos.y - 3.6, width: 7.2, height: 7.2
                    ))
                    context.fill(dot, with: .color(actualColor))
                    context.stroke(
                        dot,
                        with: .color(theme.background.swiftUIColor.opacity(0.9)),
                        lineWidth: 1
                    )
                }
            }
        }
        .background(theme.background.swiftUIColor, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ANSI hue wheel: \(metrics.ansiArchetype.detailDescription)")
    }
}

/// Small (i) button placed at the bottom-right corner of a theme preview.
/// Clicking it opens the full ThemeInspectorPanel in a popover (Hue-Drift Wheel,
/// 16 ANSI swatches, selectable preview, and day-to-day legibility stats).
struct ThemeInfoPopoverButton: View {
    let theme: TerminalTheme
    let metrics: ThemeMetrics
    let catalog: CatalogStatistics?
    @Binding var previewPage: ThemePreviewPage?

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.75)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Inspect ANSI palette & legibility")
        .accessibilityLabel("Inspect \(theme.name) palette")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            ThemeInspectorPanel(
                theme: theme,
                metrics: metrics,
                catalog: catalog,
                statusLabel: theme.isDark ? "Dark" : "Light",
                previewPage: $previewPage,
                inPopover: true
            )
        }
    }
}

/// Docked right-hand live inspector for 2D/3D views, or popover content for (i) buttons.
struct ThemeInspectorPanel: View {
    let theme: TerminalTheme
    let metrics: ThemeMetrics
    let catalog: CatalogStatistics?
    let statusLabel: String
    @Binding var previewPage: ThemePreviewPage?
    var nearbyCount: Int = 0
    var canCycleNearby: Bool = false
    var similarityRank: (rank: Int, total: Int)? = nil
    var inPopover: Bool = false

    var body: some View {
        Group {
            if inPopover {
                inspectorContent
                    .frame(width: 280)
            } else {
                ScrollView {
                    inspectorContent
                }
                .frame(width: 262)
                .background(.background.opacity(0.6))
            }
        }
    }

    private var inspectorContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            previewSection
            wheelAndPaletteSection
            legibilitySection
            if nearbyCount > 0 || similarityRank != nil {
                contextFootnote
            }
        }
        .padding(10)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(theme.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ThemeArchetypeBadge(archetype: metrics.ansiArchetype)
                Text(metrics.backgroundDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Preview", selection: $previewPage) {
                    Text("None").tag(ThemePreviewPage?.none)
                    Divider()
                    ForEach(ThemePreviewPage.allCases) { page in
                        Text(page.title).tag(Optional(page))
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
            }
            if let previewPage {
                ThemePreviewPageView(page: previewPage, theme: theme, hover: true)
                    .frame(height: 122)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
            }
        }
    }

    private var wheelAndPaletteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                AnsiHueWheelView(theme: theme, metrics: metrics)
                    .frame(width: 108, height: 108)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ANSI Hue Map")
                        .font(.caption.weight(.semibold))
                    Text(hueWheelCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if metrics.hasRepurposedBrights {
                        Label("Brights repurposed", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ThemeAnsiSwatchStrip(theme: theme, metrics: metrics, compact: false)
        }
    }

    private var hueWheelCaption: String {
        switch metrics.ansiArchetype {
        case .faithful:
            return "Colors sit close to their canonical ANSI hues with distinct separation."
        case .softMuted:
            return "Canonical hues are softened inward for lower eye strain."
        case .stylizedRemapped:
            return "Hues stay vivid and distinct, but ANSI slots are creatively remapped."
        case .monochromeTinted:
            return "ANSI colors collapse toward one tint or neutral grayscale."
        }
    }

    private var legibilitySection: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            statRow("Text", "\(ratio(metrics.foregroundContrast)) · \(metrics.contrastBucket)")
            statRow("git diff", "\(metrics.diffClarityBucket) red/green")
            statRow("Dimmed (8)", "\(ratio(metrics.dimmedTextContrast)) · \(metrics.dimmedTextBucket.lowercased())")
            statRow("TUI chrome", ratio(metrics.tuiChromeContrast))
            if let catalog {
                statRow(
                    "Palette",
                    "\(percent(metrics.ansiColorfulness, in: catalog.colorfulnessSorted)) vivid, "
                        + "\(percent(metrics.ansiSeparationP10, in: catalog.distinctnessSorted)) distinct"
                )
            }
        }
        .font(.caption)
    }

    private var contextFootnote: some View {
        VStack(alignment: .leading, spacing: 2) {
            if nearbyCount > 0 {
                let suffix = canCycleNearby ? " (↑/↓ to cycle)" : ""
                Text("+\(nearbyCount) nearby theme\(nearbyCount == 1 ? "" : "s")\(suffix)")
            }
            if let similarityRank {
                Text("#\(similarityRank.rank) closest of \(similarityRank.total)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .lineLimit(1)
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
