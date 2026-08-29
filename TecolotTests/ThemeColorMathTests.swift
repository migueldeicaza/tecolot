//
//  ThemeColorMathTests.swift
//  TecolotTests
//
//  Tests the color conversion and statistics primitives of the metrics
//  engine against known reference values.
//
import Testing
@testable import Tecolot

final class ThemeColorMathTests {
    @Test func blackHasZeroLuminanceAndWhiteHasOne() {
        let black = PerceptualColor(ProfileColor(hex: "#000000")!)
        let white = PerceptualColor(ProfileColor(hex: "#ffffff")!)

        #expect(abs(black.luminance) < 1e-9)
        #expect(abs(white.luminance - 1) < 1e-9)
    }

    @Test func blackOnWhiteContrastIsTwentyOne() {
        let black = PerceptualColor(ProfileColor(hex: "#000000")!)
        let white = PerceptualColor(ProfileColor(hex: "#ffffff")!)

        #expect(abs(ThemeColorMath.contrastRatio(black.luminance, white.luminance) - 21) < 1e-9)
        #expect(abs(ThemeColorMath.contrastUtility(21) - 1) < 1e-9)
        #expect(abs(ThemeColorMath.contrastUtility(1)) < 1e-9)
    }

    @Test func linearizationUsesTheCurrentWCAGConstant() {
        // 0.04 sits between the older 0.03928 and the current 0.04045
        // threshold; the current formula divides by 12.92.
        #expect(abs(ThemeColorMath.linearize(0.04) - 0.04 / 12.92) < 1e-9)
        #expect(abs(ThemeColorMath.linearize(1) - 1) < 1e-9)
        #expect(abs(ThemeColorMath.linearize(0)) < 1e-9)
    }

    @Test func deltaEIsZeroForIdenticalColorsAndSymmetric() {
        let red = PerceptualColor(ProfileColor(hex: "#c23621")!)
        let blue = PerceptualColor(ProfileColor(hex: "#492ee1")!)

        #expect(ThemeColorMath.deltaEOKr2(red, red) == 0)
        #expect(abs(
            ThemeColorMath.deltaEOKr2(red, blue) - ThemeColorMath.deltaEOKr2(blue, red)
        ) < 1e-12)
        #expect(ThemeColorMath.deltaEOKr2(red, blue) > 0)
    }

    @Test func oklabMatchesReferenceValues() {
        // Reference values from the OKLab definition (Björn Ottosson)
        let white = PerceptualColor(ProfileColor(hex: "#ffffff")!)
        #expect(abs(white.L - 1) < 1e-3)
        #expect(abs(white.a) < 1e-3)
        #expect(abs(white.b) < 1e-3)
        #expect(white.hue == nil)

        let red = PerceptualColor(ProfileColor(hex: "#ff0000")!)
        #expect(abs(red.L - 0.6280) < 1e-3)
        #expect(abs(red.a - 0.2249) < 1e-3)
        #expect(abs(red.b - 0.1258) < 1e-3)

        let blue = PerceptualColor(ProfileColor(hex: "#0000ff")!)
        #expect(abs(blue.L - 0.4520) < 1e-3)
        #expect(abs(blue.a - -0.0325) < 1e-3)
        #expect(abs(blue.b - -0.3115) < 1e-3)
    }

    @Test func toeKeepsTheEndpoints() {
        #expect(abs(ThemeColorMath.toe(0)) < 1e-9)
        #expect(abs(ThemeColorMath.toe(1) - 1) < 1e-6)
    }

    @Test func circularHueDistanceWrapsAroundZero() {
        #expect(abs(ThemeColorMath.circularHueDistance(350, 10) - 20) < 1e-9)
        #expect(abs(ThemeColorMath.circularHueDistance(90, 270) - 180) < 1e-9)
        #expect(ThemeColorMath.circularHueDistance(45, 45) == 0)
    }

    @Test func quantileMatchesTheTypeSevenEstimator() {
        let values: [Double] = [40, 10, 30, 20]  // unsorted on purpose

        // position = (4 - 1) × q, then linear interpolation
        #expect(abs(ThemeColorMath.quantile(values, 0.10) - 13) < 1e-9)
        #expect(abs(ThemeColorMath.quantile(values, 0.50) - 25) < 1e-9)
        #expect(ThemeColorMath.quantile(values, 0) == 10)
        #expect(ThemeColorMath.quantile(values, 1) == 40)
        #expect(ThemeColorMath.quantile([], 0.5) == 0)
    }
}
