//
//  ThemeAnalyzer.swift
//  Tecolot
//
//  Computes every ThemeMetrics value for one theme in a single pass, builds
//  the 60-dimensional feature vector, and defines the theme distance and
//  the stable content hash used as the metric cache key.
//
import CryptoKit
import Foundation

nonisolated struct ThemeAnalyzer: Sendable {
    static let version = ThemeMetricVersion.v1

    /// ANSI slots that carry accent semantics: red…cyan and their bright
    /// variants. black/white/brightBlack/brightWhite are excluded (§19).
    private static let accentIndices = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]

    init() {}

    func analyze(_ theme: TerminalTheme) -> ThemeMetrics {
        let background = PerceptualColor(theme.background)
        let foreground = PerceptualColor(theme.foreground)

        // ThemeStore filters invalid themes, but the engine must not trap on
        // a malformed value: pad or cut the ANSI table to 16 entries.
        var ansi = theme.ansi.map { PerceptualColor($0) }
        if ansi.count != 16 {
            ansi = Array((ansi + Array(repeating: foreground, count: 16)).prefix(16))
        }

        // Contrast profile (§12/§13)
        let contrasts = ansi.map { ThemeColorMath.contrastRatio($0.luminance, background.luminance) }
        let logContrasts = contrasts.map { log2($0) }

        // Colorfulness: RMS chroma (§14)
        let ansiColorfulness = sqrt(ThemeColorMath.mean(ansi.map { $0.chroma * $0.chroma }))

        // Dynamic range (§15)
        let lightnesses = ansi.map(\.L).sorted()
        let ansiLightnessSpread = ThemeColorMath.quantileOfSorted(lightnesses, 0.90)
            - ThemeColorMath.quantileOfSorted(lightnesses, 0.10)

        // Distinguishability: nearest-neighbor distances (§16)
        var nearest: [Double] = []
        nearest.reserveCapacity(16)
        for i in 0..<16 {
            var minimum = Double.infinity
            for j in 0..<16 where j != i {
                minimum = min(minimum, ThemeColorMath.deltaEOKr2(ansi[i], ansi[j]))
            }
            nearest.append(minimum)
        }

        // Normal vs bright pairs (§17/§18)
        var pairSeparations: [Double] = []
        var lifts: [Double] = []
        for i in 0..<8 {
            pairSeparations.append(ThemeColorMath.deltaEOKr2(ansi[i], ansi[i + 8]))
            lifts.append(ansi[i + 8].L - ansi[i].L)
        }
        var hueDrifts: [Double] = []
        for i in 1...6 {
            guard let normalHue = ansi[i].hue, let brightHue = ansi[i + 8].hue else { continue }
            hueDrifts.append(ThemeColorMath.circularHueDistance(normalHue, brightHue))
        }

        // Accent centroid on the hue wheel, chroma²-weighted (§19–§21)
        var weightSum = 0.0
        var u = 0.0
        var v = 0.0
        for index in ThemeAnalyzer.accentIndices {
            let accent = ansi[index]
            guard let hue = accent.hue else { continue }
            let weight = accent.chroma * accent.chroma
            let radians = hue * .pi / 180
            weightSum += weight
            u += weight * cos(radians)
            v += weight * sin(radians)
        }
        let accentCoherence: Double
        let hueDiversity: Double?
        let dominantAccentHue: Double?
        let dominantAccentIndex: Int?
        let temperature: Double
        if weightSum > 0 {
            u /= weightSum
            v /= weightSum
            let coherence = sqrt(u * u + v * v)
            accentCoherence = coherence
            hueDiversity = 1 - coherence
            if coherence > 1e-6 {
                var degrees = atan2(v, u) * 180 / .pi
                if degrees < 0 {
                    degrees += 360
                }
                dominantAccentHue = degrees.truncatingRemainder(dividingBy: 360)
            } else {
                dominantAccentHue = nil
            }
            let warm = 60.0 * .pi / 180
            temperature = u * cos(warm) + v * sin(warm)
        } else {
            // Neutral palette: no chromatic accent exists
            accentCoherence = 0
            hueDiversity = nil
            dominantAccentHue = nil
            temperature = 0
        }
        dominantAccentIndex = ThemeAnalyzer.accentIndex(near: dominantAccentHue, in: ansi)

        // Interaction colors from fallback resolution (spec-theme-tecolot §2.2)
        let effectiveCursor = theme.cursor.map { PerceptualColor($0) } ?? foreground
        let hasCustomSelection = theme.selectionBackground != nil
        let effectiveSelection: PerceptualColor
        if let selection = theme.selectionBackground {
            effectiveSelection = PerceptualColor(selection)
        } else {
            // 25% foreground over background, mixed in linear RGB
            effectiveSelection = PerceptualColor(
                linearRed: 0.25 * foreground.linearRed + 0.75 * background.linearRed,
                linearGreen: 0.25 * foreground.linearGreen + 0.75 * background.linearGreen,
                linearBlue: 0.25 * foreground.linearBlue + 0.75 * background.linearBlue
            )
        }
        let effectiveSelectionText = theme.selectionText.map { PerceptualColor($0) } ?? foreground

        // Feature vector (§25): role-weighted ΔEOKr2 coordinates
        var featureVector: [Double] = []
        featureVector.reserveCapacity(60)
        func append(_ color: PerceptualColor, weight: Double) {
            let scale = sqrt(weight) / 5.0  // sqrt(weight) / sqrt(25)
            for component in color.perceptualComponents {
                featureVector.append(scale * component)
            }
        }
        append(background, weight: 5)
        append(foreground, weight: 3)
        for color in ansi {
            append(color, weight: 1)
        }
        append(effectiveCursor, weight: 0.5)
        append(effectiveSelection, weight: 0.5)

        return ThemeMetrics(
            backgroundLightness: background.L,
            backgroundChroma: background.chroma,
            backgroundHue: background.hue,
            foregroundContrast: ThemeColorMath.contrastRatio(foreground.luminance, background.luminance),
            ansiContrastMinimum: contrasts.min() ?? 1,
            ansiContrastP10: ThemeColorMath.quantile(contrasts, 0.10),
            ansiContrastMedian: ThemeColorMath.quantile(contrasts, 0.50),
            contrastUnevenness: ThemeColorMath.standardDeviation(logContrasts),
            ansiColorfulness: ansiColorfulness,
            ansiLightnessSpread: ansiLightnessSpread,
            ansiSeparationMinimum: nearest.min() ?? 0,
            ansiSeparationP10: ThemeColorMath.quantile(nearest, 0.10),
            ansiSeparationMean: ThemeColorMath.mean(nearest),
            brightPairSeparation: ThemeColorMath.mean(pairSeparations),
            brightLightnessLift: ThemeColorMath.mean(lifts),
            brightHueDrift: hueDrifts.isEmpty ? nil : ThemeColorMath.mean(hueDrifts),
            hueDiversity: hueDiversity,
            dominantAccentHue: dominantAccentHue,
            dominantAccentIndex: dominantAccentIndex,
            accentCoherence: accentCoherence,
            temperature: temperature,
            cursorContrast: ThemeColorMath.contrastRatio(effectiveCursor.luminance, background.luminance),
            cursorSeparation: ThemeColorMath.deltaEOKr2(effectiveCursor, background),
            selectionSeparation: ThemeColorMath.deltaEOKr2(effectiveSelection, background),
            selectionTextContrast: ThemeColorMath.contrastRatio(
                effectiveSelectionText.luminance, effectiveSelection.luminance
            ),
            hasCustomSelection: hasCustomSelection,
            hasCustomCursor: theme.cursor != nil,
            featureVector: featureVector
        )
    }

    /// The accent slot whose color best represents the dominant hue: the most
    /// chromatic accent within 30°, or the nearest-hue accent otherwise
    private static func accentIndex(near dominantHue: Double?, in ansi: [PerceptualColor]) -> Int? {
        guard let dominantHue else { return nil }
        var nearest: (index: Int, distance: Double)?
        var mostChromaticNearby: (index: Int, chroma: Double)?
        for index in accentIndices {
            let accent = ansi[index]
            guard let hue = accent.hue else { continue }
            let distance = ThemeColorMath.circularHueDistance(hue, dominantHue)
            if distance < (nearest?.distance ?? .infinity) {
                nearest = (index, distance)
            }
            if distance <= 30, accent.chroma > (mostChromaticNearby?.chroma ?? -1) {
                mostChromaticNearby = (index, accent.chroma)
            }
        }
        return mostChromaticNearby?.index ?? nearest?.index
    }
}

/// Weighted perceptual distance between two whole themes (spec §24/§25):
/// plain Euclidean distance between the feature vectors.
nonisolated func themeDistance(_ a: ThemeMetrics, _ b: ThemeMetrics) -> Double {
    var sum = 0.0
    for (x, y) in zip(a.featureVector, b.featureVector) {
        sum += (x - y) * (x - y)
    }
    return sqrt(sum)
}

extension TerminalTheme {
    /// Stable identity of the theme's colors: SHA-256 of the canonical JSON
    /// encoding (sorted keys) with `name` and `baseThemeName` stripped, so a
    /// pure rename does not invalidate cached metrics. Together with
    /// ThemeMetricVersion this is the (future persisted) metric cache key.
    nonisolated var contentHash: String {
        var canonical = self
        canonical.name = ""
        canonical.baseThemeName = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(canonical)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
