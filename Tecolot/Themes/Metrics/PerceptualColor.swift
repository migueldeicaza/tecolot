//
//  PerceptualColor.swift
//  Tecolot
//
//  A theme color in the representations the metrics engine works with:
//  WCAG relative luminance, OKLab coordinates and OKLCH chroma/hue, plus
//  the raw linear channels needed to derive the synthetic selection color.
//
import Foundation

nonisolated struct PerceptualColor: Sendable {
    /// WCAG relative luminance, 0…1
    let luminance: Double
    /// OKLab lightness
    let L: Double
    /// OKLab a component
    let a: Double
    /// OKLab b component
    let b: Double
    /// OKLCH chroma
    let chroma: Double
    /// OKLCH hue in degrees 0..<360; nil when the color is visually neutral
    let hue: Double?
    /// Linear RGB channels, kept for compositing derived colors
    let linearRed: Double
    let linearGreen: Double
    let linearBlue: Double

    /// Product-level chroma threshold below which hue has no useful meaning
    static let neutralChromaThreshold = 0.004

    init(_ color: ProfileColor) {
        self.init(
            linearRed: ThemeColorMath.linearize(Double(color.red) / 65535.0),
            linearGreen: ThemeColorMath.linearize(Double(color.green) / 65535.0),
            linearBlue: ThemeColorMath.linearize(Double(color.blue) / 65535.0)
        )
    }

    init(linearRed: Double, linearGreen: Double, linearBlue: Double) {
        self.linearRed = linearRed
        self.linearGreen = linearGreen
        self.linearBlue = linearBlue
        luminance = ThemeColorMath.relativeLuminance(
            linearRed: linearRed, linearGreen: linearGreen, linearBlue: linearBlue
        )
        let lab = ThemeColorMath.oklab(
            linearRed: linearRed, linearGreen: linearGreen, linearBlue: linearBlue
        )
        L = lab.L
        a = lab.a
        b = lab.b
        chroma = sqrt(lab.a * lab.a + lab.b * lab.b)
        if chroma < PerceptualColor.neutralChromaThreshold {
            hue = nil
        } else {
            var degrees = atan2(lab.b, lab.a) * 180 / .pi
            if degrees < 0 {
                degrees += 360
            }
            hue = degrees.truncatingRemainder(dividingBy: 360)
        }
    }

    /// The ΔEOKr2 coordinates [toe(L), 2a, 2b]. Euclidean distance between
    /// these vectors is the perceptual color distance (spec §8/§25).
    var perceptualComponents: [Double] {
        [ThemeColorMath.toe(L), 2 * a, 2 * b]
    }
}
