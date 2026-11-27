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
    case v2 = 2
}

/// High-level semantic category explaining how a theme treats official ANSI
/// color names vs. chromatic diversity.
nonisolated enum ANSIDeviationArchetype: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Classic / faithful ANSI hues with strong chromatic separation.
    case faithful
    /// Hues lean toward canonical ANSI names, softened or muted in chroma.
    case softMuted
    /// Colorful and distinct palette, but ANSI slots are deliberately remapped or rotated.
    case stylizedRemapped
    /// Color is collapsed into one hue family or drained toward grayscale.
    case monochromeTinted

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .faithful:
            return "Faithful"
        case .softMuted:
            return "Soft"
        case .stylizedRemapped:
            return "Stylized"
        case .monochromeTinted:
            return "Monochrome"
        }
    }

    var detailDescription: String {
        switch self {
        case .faithful:
            return "Classic ANSI hues"
        case .softMuted:
            return "Soft / muted ANSI"
        case .stylizedRemapped:
            return "Stylized / remapped"
        case .monochromeTinted:
            return "Monochrome / tinted"
        }
    }
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

    // ANSI semantic fidelity and deviation decomposition (v2)
    /// Per-slot fidelity in 0…1 for the 12 chromatic slots [1…6, 9…14].
    let ansiSlotFidelities: [Double]
    /// Signed hue shift in (-180, 180] degrees from canonical focal hue for [1…6, 9…14]; nil if neutral.
    let ansiSlotSignedHueShifts: [Double?]
    /// Mean fidelity of normal chromatic ANSI slots 1…6, 0…1.
    let ansiNormalFidelity: Double
    /// Mean fidelity of bright chromatic ANSI slots 9…14, 0…1.
    let ansiBrightFidelity: Double
    /// Overall weighted ANSI name fidelity (65% normal, 35% bright), 0…1.
    let ansiNameFidelity: Double
    /// Positive gap when normal slots are faithful but bright slots are repurposed (e.g. Solarized).
    let brightSlotDivergence: Double
    /// Chromatic span weighted by chroma sufficiency, 0…1. Separates vivid remapped palettes from monochrome.
    let chromaticVitality: Double
    /// Circular coherence of signed hue shifts across chromatic slots, 0…1.
    let hueShiftCoherence: Double
    /// Circular mean hue rotation in degrees; nil when neutral.
    let meanHueShift: Double?
    /// Derived archetype explaining whether deviations stay colorful or strip out color.
    let ansiArchetype: ANSIDeviationArchetype

    // Day-to-day real-app legibility (v2)
    /// git diff clarity combining red/green separation and contrast on background, 0…1.
    let diffClarity: Double
    /// WCAG contrast of ANSI 8 (bright black / dimmed text / comments) against background.
    let dimmedTextContrast: Double
    /// Minimum WCAG contrast of classic TUI pairings (ANSI 15 on 4, ANSI 0 on 6).
    let tuiChromeContrast: Double

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
        case ..<0.30:
            return "Very Dark"
        case ..<0.50:
            return "Dark"
        case ..<0.70:
            return "Medium"
        case ..<0.85:
            return "Light"
        default:
            return "Very Light"
        }
    }

    nonisolated var contrastBucket: String {
        switch foregroundContrast {
        case ..<3.0:
            return "soft contrast"
        case ..<4.5:
            return "moderate contrast"
        case ..<7.0:
            return "strong contrast"
        default:
            return "very strong contrast"
        }
    }

    nonisolated var temperatureBucket: String {
        switch temperature {
        case ..<(-0.15):
            return "cool"
        case ..<0.15:
            return "balanced"
        default:
            return "warm"
        }
    }

    /// Approximate color name for the background hue; nil when neutral
    nonisolated var backgroundHueName: String? {
        guard backgroundChroma >= 0.015, let hue = backgroundHue else {
            return nil
        }
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

    /// True when normal ANSI slots match their names but bright slots are repurposed (e.g. Solarized)
    nonisolated var hasRepurposedBrights: Bool {
        brightSlotDivergence >= 0.25
    }

    /// Returns the fidelity (0…1) for an ANSI index in 1…6 or 9…14; nil for neutral slots 0, 7, 8, 15.
    nonisolated func slotFidelity(forAnsiIndex index: Int) -> Double? {
        guard let offset = ThemeAnalyzer.accentIndices.firstIndex(of: index),
              offset < ansiSlotFidelities.count else {
            return nil
        }
        return ansiSlotFidelities[offset]
    }

    /// Plain-language git diff red/green clarity label
    nonisolated var diffClarityBucket: String {
        switch diffClarity {
        case 0.55...:
            return "Clear"
        case 0.30..<0.55:
            return "Subtle"
        default:
            return "Collapsed"
        }
    }

    /// Plain-language dimmed/comment text (ANSI 8) readability label
    nonisolated var dimmedTextBucket: String {
        switch dimmedTextContrast {
        case 4.5...:
            return "Strong"
        case 2.5..<4.5:
            return "Readable"
        default:
            return "Faint"
        }
    }
}
