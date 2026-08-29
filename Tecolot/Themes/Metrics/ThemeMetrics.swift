//
//  ThemeMetrics.swift
//  Tecolot
//
//  The full set of perceptual metrics computed for one theme in a single
//  analysis pass (spec-theme.md §9/§52, adapted per spec-theme-tecolot.md).
//  All metrics are computed even when the UI does not surface them yet.
//
import Foundation

/// Version of the metric algorithm. Bump when the perceptual model, the
/// weights, or the feature-vector layout changes, so persisted layouts are
/// never silently reinterpreted.
nonisolated enum ThemeMetricVersion: Int, Sendable {
    case v1 = 1
}

nonisolated struct ThemeMetrics: Sendable {
    // Background (§10)
    let backgroundLightness: Double
    let backgroundChroma: Double
    let backgroundHue: Double?

    // Foreground (§11)
    let foregroundContrast: Double

    // ANSI contrast profile (§12/§13)
    let ansiContrastMinimum: Double
    let ansiContrastP10: Double
    let ansiContrastMedian: Double
    let contrastUnevenness: Double

    // ANSI colorfulness and dynamic range (§14/§15)
    let ansiColorfulness: Double
    let ansiLightnessSpread: Double

    // ANSI distinguishability (§16)
    let ansiSeparationMinimum: Double
    let ansiSeparationP10: Double
    let ansiSeparationMean: Double

    // Normal vs bright behavior (§17/§18)
    let brightPairSeparation: Double
    let brightLightnessLift: Double
    let brightHueDrift: Double?

    // Accent character (§19–§21)
    let hueDiversity: Double?
    let dominantAccentHue: Double?
    /// ANSI slot of the most chromatic accent near the dominant hue, resolved
    /// once during analysis for the map marker's center dot; nil when neutral
    let dominantAccentIndex: Int?
    let accentCoherence: Double
    let temperature: Double

    // Interaction colors (§22/§23), from fallback resolution — never alpha
    let cursorContrast: Double
    let cursorSeparation: Double
    let selectionSeparation: Double
    let selectionTextContrast: Double

    /// False when the theme has no selectionBackground and the synthetic
    /// 25% foreground-over-background mix stands in for it
    let hasCustomSelection: Bool
    /// True when the theme defines its own cursor color; informational
    let hasCustomCursor: Bool

    /// 60 values: the [toe(L), 2a, 2b] coordinates of the 20 semantic colors
    /// with the §25 role weights, divided by sqrt(25). Euclidean distance
    /// between two vectors is the weighted theme distance.
    let featureVector: [Double]
}

// Descriptive bucket words from the spec's group tables (§10/§11/§21),
// used by the hover card and by accessibility labels — never raw numbers.
extension ThemeMetrics {
    nonisolated var backgroundLightnessBucket: String {
        switch backgroundLightness {
        case ..<0.30: return "Very Dark"
        case ..<0.50: return "Dark"
        case ..<0.70: return "Medium"
        case ..<0.85: return "Light"
        default: return "Very Light"
        }
    }

    nonisolated var contrastBucket: String {
        switch foregroundContrast {
        case ..<3.0: return "soft contrast"
        case ..<4.5: return "moderate contrast"
        case ..<7.0: return "strong contrast"
        default: return "very strong contrast"
        }
    }

    nonisolated var temperatureBucket: String {
        switch temperature {
        case ..<(-0.15): return "cool"
        case ..<0.15: return "balanced"
        default: return "warm"
        }
    }

    /// Approximate color name for the background hue; nil when neutral
    nonisolated var backgroundHueName: String? {
        guard backgroundChroma >= 0.015, let hue = backgroundHue else { return nil }
        // Landmark OKLCH hues with everyday names; nearest wins
        let landmarks: [(hue: Double, name: String)] = [
            (25, "Red"), (55, "Orange"), (90, "Yellow"), (130, "Green"),
            (165, "Teal"), (200, "Cyan"), (240, "Sky"), (265, "Blue"),
            (300, "Purple"), (330, "Magenta"), (355, "Pink")
        ]
        return landmarks.min {
            ThemeColorMath.circularHueDistance(hue, $0.hue)
                < ThemeColorMath.circularHueDistance(hue, $1.hue)
        }?.name
    }

    /// "Dark Blue", "Very Dark Neutral", … for the hover card
    nonisolated var backgroundDescription: String {
        "\(backgroundLightnessBucket) \(backgroundHueName ?? "Neutral")"
    }
}
