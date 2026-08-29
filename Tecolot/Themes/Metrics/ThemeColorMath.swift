//
//  ThemeColorMath.swift
//  Tecolot
//
//  Pure color math for theme analysis: sRGB linearization, WCAG relative
//  luminance and contrast, OKLab conversion, the ΔEOKr2 perceptual distance,
//  circular hue arithmetic and type-7 quantiles. Formulas follow
//  spec-theme.md §4–§8 and §27. This file must import only Foundation.
//
import Foundation

nonisolated enum ThemeColorMath {
    /// Decodes one sRGB channel (0…1) to linear light. Uses the 0.04045
    /// constant of the current WCAG formulation, not the older 0.03928.
    static func linearize(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance from linear channels, 0…1
    static func relativeLuminance(linearRed: Double, linearGreen: Double, linearBlue: Double) -> Double {
        0.2126 * linearRed + 0.7152 * linearGreen + 0.0722 * linearBlue
    }

    /// WCAG contrast ratio between two relative luminances, 1…21
    static func contrastRatio(_ luminance1: Double, _ luminance2: Double) -> Double {
        let lighter = max(luminance1, luminance2)
        let darker = min(luminance1, luminance2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Normalized contrast for positioning and scoring: ln(C)/ln(21) maps
    /// 1:1 → 0 and 21:1 → 1. The UI shows raw ratios, never this value.
    static func contrastUtility(_ contrast: Double) -> Double {
        log(max(contrast, 1)) / log(21.0)
    }

    /// Linear RGB → OKLab
    static func oklab(
        linearRed r: Double, linearGreen g: Double, linearBlue b: Double
    ) -> (L: Double, a: Double, b: Double) {
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l3 = cbrt(l)
        let m3 = cbrt(m)
        let s3 = cbrt(s)
        return (
            L: 0.2104542553 * l3 + 0.7936177850 * m3 - 0.0040720468 * s3,
            a: 1.9779984951 * l3 - 2.4285922050 * m3 + 0.4505937099 * s3,
            b: 0.0259040371 * l3 + 0.7827717662 * m3 - 0.8086757660 * s3
        )
    }

    /// The ΔEOKr2 lightness toe from CSS Color 4
    static func toe(_ x: Double) -> Double {
        let k1 = 0.206
        let k2 = 0.03
        let k3 = (1 + k1) / (1 + k2)
        let t = k3 * x - k1
        return 0.5 * (t + sqrt(t * t + 4 * k2 * k3 * x))
    }

    /// ΔEOKr2 perceptual distance: Euclidean distance between the
    /// [toe(L), 2a, 2b] representations of the two colors
    static func deltaEOKr2(_ c1: PerceptualColor, _ c2: PerceptualColor) -> Double {
        let dl = toe(c1.L) - toe(c2.L)
        let da = 2 * (c1.a - c2.a)
        let db = 2 * (c1.b - c2.b)
        return sqrt(dl * dl + da * da + db * db)
    }

    /// Shortest angular distance between two hues in degrees, 0…180
    static func circularHueDistance(_ h1: Double, _ h2: Double) -> Double {
        let difference = abs(h1 - h2).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    /// Type-7 linearly interpolated quantile; sorts a copy of `values`
    static func quantile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        return quantileOfSorted(values.sorted(), q)
    }

    /// Type-7 quantile over an array already sorted in ascending order
    static func quantileOfSorted(_ sorted: [Double], _ q: Double) -> Double {
        guard let last = sorted.last else { return 0 }
        let position = Double(sorted.count - 1) * q
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard upper < sorted.count else { return last }
        let fraction = position - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// Population standard deviation
    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let m = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)
        return sqrt(variance)
    }
}
