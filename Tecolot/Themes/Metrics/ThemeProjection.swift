//
//  ThemeProjection.swift
//  Tecolot
//
//  Maps analyzed themes into unit-square positions (0…1, y down) for the
//  2D theme browser (spec §28–§36). Knows nothing about SwiftUI; it imports
//  CoreGraphics only for CGPoint.
//
import CoreGraphics
import Foundation

nonisolated enum ThemePlotMode: String, CaseIterable, Identifiable, Sendable {
    case backgroundSpectrum
    case brightnessAndColorfulness
    case contrastAndColorfulness
    case contrastAndDistinctness
    case temperatureAndContrast
    case accentSpectrum
    case similarityMap
    case interactionColors

    var id: String { rawValue }

    /// The six tabs V1 exposes (spec §46); the other modes stay computed
    static let v1Tabs: [ThemePlotMode] = [
        .backgroundSpectrum, .brightnessAndColorfulness, .contrastAndColorfulness,
        .contrastAndDistinctness, .temperatureAndContrast, .similarityMap
    ]

    var title: String {
        switch self {
        case .backgroundSpectrum: return "Spectrum"
        case .brightnessAndColorfulness: return "Brightness"
        case .contrastAndColorfulness: return "Colorfulness"
        case .contrastAndDistinctness: return "Clarity"
        case .temperatureAndContrast: return "Warm ↔ Cool"
        case .accentSpectrum: return "Accents"
        case .similarityMap: return "Similarity"
        case .interactionColors: return "Interaction"
        }
    }

    /// Edge labels drawn around the plot; nil edges stay unlabeled
    var axisLabels: (top: String?, bottom: String?, left: String?, right: String?) {
        switch self {
        case .backgroundSpectrum:
            return (nil, "Background Color · neutral center, tinted rim", nil, nil)
        case .brightnessAndColorfulness:
            return ("LIGHT", "DARK", "MUTED", "VIVID")
        case .contrastAndColorfulness:
            return ("HIGH CONTRAST", "SOFT CONTRAST", "MUTED", "COLORFUL")
        case .contrastAndDistinctness:
            return ("HIGH CONTRAST", "LOW CONTRAST", "SIMILAR COLORS", "DISTINCT COLORS")
        case .temperatureAndContrast:
            return ("HIGH CONTRAST", "SOFT CONTRAST", "COOL", "WARM")
        case .accentSpectrum:
            return (nil, "Accent Color · muted or mixed center", nil, nil)
        case .similarityMap:
            return (nil, "Visual Similarity · themes nearby look alike", nil, nil)
        case .interactionColors:
            return ("VISIBLE CURSOR", "SUBTLE CURSOR", "SUBTLE", "STRONG SELECTION")
        }
    }
}

nonisolated struct ThemePlotPoint: Identifiable, Sendable {
    /// Theme name — the store's key, matching every browser callback
    let id: String
    /// Position in unit space, 0…1 with y growing downward
    let position: CGPoint
    /// Marker body fill
    let background: ProfileColor
    /// Marker ring
    let foreground: ProfileColor
    /// Marker center dot: the most chromatic accent near the dominant hue
    let accent: ProfileColor
    /// False when the theme relies on the system selection color; the
    /// Interaction Colors plot draws these hollow
    let hasCustomSelection: Bool
}

nonisolated enum ThemeProjection {
    static func project(
        themes: [TerminalTheme],
        metrics: [String: ThemeMetrics],
        catalog: CatalogStatistics,
        mode: ThemePlotMode
    ) -> [ThemePlotPoint] {
        // The similarity map needs catalog-relative bounds of the projected
        // coordinates themselves; compute them in a first pass.
        var similarityCoordinates: [String: (x: Double, y: Double)] = [:]
        var similarityBounds: (x: ClosedRange<Double>, y: ClosedRange<Double>)?
        if mode == .similarityMap {
            var xs: [Double] = []
            var ys: [Double] = []
            for theme in themes {
                guard let themeMetrics = metrics[theme.name],
                      themeMetrics.featureVector.count == catalog.pcaMean.count else { continue }
                let centered = zip(themeMetrics.featureVector, catalog.pcaMean).map(-)
                let x = zip(centered, catalog.pc1).reduce(0) { $0 + $1.0 * $1.1 }
                let y = zip(centered, catalog.pc2).reduce(0) { $0 + $1.0 * $1.1 }
                similarityCoordinates[theme.name] = (x, y)
                xs.append(x)
                ys.append(y)
            }
            if !xs.isEmpty {
                similarityBounds = (robustBounds(xs), robustBounds(ys))
            }
        }

        return themes.compactMap { theme in
            guard let themeMetrics = metrics[theme.name] else { return nil }
            let position: CGPoint
            switch mode {
            case .backgroundSpectrum:
                // Radial: hue as angle, chroma exaggerated toward the rim (§29)
                position = radialPosition(
                    hue: themeMetrics.backgroundHue,
                    radius: pow(
                        min(max(themeMetrics.backgroundChroma / catalog.backgroundChromaP95, 0), 1),
                        0.65
                    )
                )
            case .brightnessAndColorfulness:
                position = CGPoint(
                    x: catalog.normalized(themeMetrics.ansiColorfulness, for: .ansiColorfulness),
                    y: 1 - themeMetrics.backgroundLightness
                )
            case .contrastAndColorfulness:
                position = CGPoint(
                    x: catalog.normalized(themeMetrics.ansiColorfulness, for: .ansiColorfulness),
                    y: 1 - contrastFloor(themeMetrics)
                )
            case .contrastAndDistinctness:
                position = CGPoint(
                    x: catalog.normalized(themeMetrics.ansiSeparationP10, for: .ansiSeparationP10),
                    y: 1 - contrastFloor(themeMetrics)
                )
            case .temperatureAndContrast:
                position = CGPoint(
                    x: (themeMetrics.temperature + 1) / 2,
                    y: 1 - contrastFloor(themeMetrics)
                )
            case .accentSpectrum:
                position = radialPosition(
                    hue: themeMetrics.dominantAccentHue,
                    radius: catalog.normalized(themeMetrics.ansiColorfulness, for: .ansiColorfulness)
                        * themeMetrics.accentCoherence
                )
            case .similarityMap:
                guard let coordinates = similarityCoordinates[theme.name],
                      let bounds = similarityBounds else { return nil }
                // pc2 grows with lightness; screen y grows downward
                position = CGPoint(
                    x: normalized(coordinates.x, in: bounds.x),
                    y: 1 - normalized(coordinates.y, in: bounds.y)
                )
            case .interactionColors:
                position = CGPoint(
                    x: catalog.normalized(themeMetrics.selectionSeparation, for: .selectionSeparation),
                    y: 1 - ThemeColorMath.contrastUtility(themeMetrics.cursorContrast)
                )
            }
            return ThemePlotPoint(
                id: theme.name,
                position: position,
                background: theme.background,
                foreground: theme.foreground,
                accent: accentColor(for: theme, metrics: themeMetrics),
                hasCustomSelection: themeMetrics.hasCustomSelection
            )
        }
    }

    /// min(text contrast, ANSI P10 contrast), as a 0…1 utility (§31)
    private static func contrastFloor(_ metrics: ThemeMetrics) -> Double {
        min(
            ThemeColorMath.contrastUtility(metrics.foregroundContrast),
            ThemeColorMath.contrastUtility(metrics.ansiContrastP10)
        )
    }

    private static func radialPosition(hue: Double?, radius: Double) -> CGPoint {
        guard let hue else { return CGPoint(x: 0.5, y: 0.5) }
        let clamped = min(max(radius, 0), 1)
        let radians = hue * .pi / 180
        return CGPoint(
            x: 0.5 + 0.46 * clamped * cos(radians),
            y: 0.5 - 0.46 * clamped * sin(radians)
        )
    }

    private static func robustBounds(_ values: [Double]) -> ClosedRange<Double> {
        let sorted = values.sorted()
        let low = ThemeColorMath.quantileOfSorted(sorted, 0.02)
        let high = ThemeColorMath.quantileOfSorted(sorted, 0.98)
        return low...high
    }

    private static func normalized(_ value: Double, in bounds: ClosedRange<Double>) -> Double {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return 0.5 }
        return min(max((value - bounds.lowerBound) / span, 0), 1)
    }

    /// The marker's center-dot color: the accent slot the analyzer resolved
    /// near the dominant hue; the foreground for neutral themes
    private static func accentColor(for theme: TerminalTheme, metrics: ThemeMetrics) -> ProfileColor {
        guard let index = metrics.dominantAccentIndex, index < theme.ansi.count else {
            return theme.foreground
        }
        return theme.ansi[index]
    }
}
