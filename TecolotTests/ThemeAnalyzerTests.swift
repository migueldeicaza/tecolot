//
//  ThemeAnalyzerTests.swift
//  TecolotTests
//
//  Tests the per-theme metrics engine: fallback resolution for optional
//  cursor/selection, ANSI separation, bright pairs, accent statistics and
//  the weighted theme distance.
//
import Foundation
import Testing
@testable import Tecolot

final class ThemeAnalyzerTests {
    private let analyzer = ThemeAnalyzer()

    @Test func missingCursorFallsBackToForeground() {
        var theme = TerminalTheme.fallback
        theme.cursor = nil
        let metrics = analyzer.analyze(theme)

        #expect(!metrics.hasCustomCursor)
        #expect(abs(metrics.cursorContrast - metrics.foregroundContrast) < 1e-12)

        let foreground = PerceptualColor(theme.foreground)
        let background = PerceptualColor(theme.background)
        #expect(abs(
            metrics.cursorSeparation - ThemeColorMath.deltaEOKr2(foreground, background)
        ) < 1e-12)
    }

    @Test func missingSelectionUsesTheLinearMix() {
        var theme = TerminalTheme.fallback
        theme.selectionBackground = nil
        theme.selectionText = nil
        let metrics = analyzer.analyze(theme)

        #expect(!metrics.hasCustomSelection)

        let foreground = PerceptualColor(theme.foreground)
        let background = PerceptualColor(theme.background)
        let mix = PerceptualColor(
            linearRed: 0.25 * foreground.linearRed + 0.75 * background.linearRed,
            linearGreen: 0.25 * foreground.linearGreen + 0.75 * background.linearGreen,
            linearBlue: 0.25 * foreground.linearBlue + 0.75 * background.linearBlue
        )
        #expect(abs(
            metrics.selectionSeparation - ThemeColorMath.deltaEOKr2(mix, background)
        ) < 1e-12)
        #expect(abs(
            metrics.selectionTextContrast
                - ThemeColorMath.contrastRatio(foreground.luminance, mix.luminance)
        ) < 1e-12)
    }

    @Test func customSelectionIsUsedDirectly() {
        var theme = TerminalTheme.fallback
        theme.selectionBackground = ProfileColor(hex: "#3355aa")

        let metrics = analyzer.analyze(theme)
        #expect(metrics.hasCustomSelection)

        let selection = PerceptualColor(ProfileColor(hex: "#3355aa")!)
        let background = PerceptualColor(theme.background)
        #expect(abs(
            metrics.selectionSeparation - ThemeColorMath.deltaEOKr2(selection, background)
        ) < 1e-12)
    }

    @Test func duplicateAnsiEntriesGiveZeroMinimumSeparation() {
        var theme = TerminalTheme.fallback
        theme.ansi[3] = theme.ansi[5]

        let metrics = analyzer.analyze(theme)
        #expect(metrics.ansiSeparationMinimum == 0)
    }

    @Test func identicalBrightRowGivesZeroPairSeparationAndLift() {
        var theme = TerminalTheme.fallback
        for i in 0..<8 {
            theme.ansi[i + 8] = theme.ansi[i]
        }

        let metrics = analyzer.analyze(theme)
        #expect(metrics.brightPairSeparation == 0)
        #expect(abs(metrics.brightLightnessLift) < 1e-12)
        #expect(metrics.brightHueDrift.map { abs($0) < 1e-12 } ?? true)
    }

    @Test func sameHueAccentsAreCoherent() {
        // Scaled linear reds share one OKLab hue at different lightness
        let reds = ["#ff2200", "#e61f00", "#cc1b00", "#b31800", "#991400", "#801100"]
        var theme = TerminalTheme.fallback
        for (offset, index) in [1, 2, 3, 4, 5, 6].enumerated() {
            theme.ansi[index] = ProfileColor(hex: reds[offset])!
            theme.ansi[index + 8] = ProfileColor(hex: reds[offset])!
        }
        // Neutral non-accent slots
        theme.ansi[0] = ProfileColor(hex: "#000000")!
        theme.ansi[7] = ProfileColor(hex: "#cccccc")!
        theme.ansi[8] = ProfileColor(hex: "#555555")!
        theme.ansi[15] = ProfileColor(hex: "#ffffff")!

        let metrics = analyzer.analyze(theme)
        #expect(metrics.accentCoherence > 0.99)
        #expect((metrics.hueDiversity ?? 1) < 0.01)
        #expect(metrics.dominantAccentHue != nil)
    }

    @Test func spreadAccentHuesAreIncoherent() {
        // The six saturated RGB corner colors cover the hue wheel
        let corners = ["#ff0000", "#ffff00", "#00ff00", "#00ffff", "#0000ff", "#ff00ff"]
        var theme = TerminalTheme.fallback
        for (offset, index) in [1, 2, 3, 4, 5, 6].enumerated() {
            theme.ansi[index] = ProfileColor(hex: corners[offset])!
            theme.ansi[index + 8] = ProfileColor(hex: corners[offset])!
        }

        let metrics = analyzer.analyze(theme)
        #expect(metrics.accentCoherence < 0.2)
        #expect((metrics.hueDiversity ?? 0) > 0.8)
    }

    @Test func grayPaletteClassifiesAsNeutral() {
        let grays = (0..<16).map { step -> ProfileColor in
            let value = UInt16(step * 4369)
            return ProfileColor(red: value, green: value, blue: value)
        }
        let theme = TerminalTheme(
            name: "Grayscale",
            ansi: grays,
            foreground: ProfileColor(hex: "#eeeeee")!,
            background: ProfileColor(hex: "#111111")!
        )

        let metrics = analyzer.analyze(theme)
        #expect(metrics.dominantAccentHue == nil)
        #expect(metrics.hueDiversity == nil)
        #expect(metrics.accentCoherence == 0)
        #expect(metrics.temperature == 0)
        #expect(metrics.brightHueDrift == nil)
        #expect(metrics.backgroundHue == nil)
    }

    @Test func themeDistanceIsZeroOnSelfAndSymmetric() {
        var other = TerminalTheme.fallback
        other.background = ProfileColor(hex: "#fafafa")!

        let a = analyzer.analyze(TerminalTheme.fallback)
        let b = analyzer.analyze(other)

        #expect(themeDistance(a, a) == 0)
        #expect(abs(themeDistance(a, b) - themeDistance(b, a)) < 1e-12)
        #expect(themeDistance(a, b) > 0)
    }

    @Test func backgroundOutweighsCursorInThemeDistance() {
        // Give both roles the same starting color so both edits apply the
        // identical color delta; only the role weights differ.
        var base = TerminalTheme.fallback
        base.cursor = base.background

        var backgroundChanged = base
        backgroundChanged.background = ProfileColor(hex: "#404860")!
        var cursorChanged = base
        cursorChanged.cursor = ProfileColor(hex: "#404860")!

        let reference = analyzer.analyze(base)
        let backgroundDistance = themeDistance(reference, analyzer.analyze(backgroundChanged))
        let cursorDistance = themeDistance(reference, analyzer.analyze(cursorChanged))

        #expect(backgroundDistance > cursorDistance)
    }

    @Test func fallbackThemeAnalyzesPlausibly() {
        let metrics = analyzer.analyze(TerminalTheme.fallback)

        #expect(metrics.backgroundLightness < 0.5)
        #expect(metrics.foregroundContrast > 4.5)
        #expect(metrics.featureVector.count == 60)
        #expect(metrics.featureVector.allSatisfy { $0.isFinite })
        #expect(metrics.ansiSeparationMinimum > 0)
    }

    @Test func malformedAnsiTableDoesNotTrap() {
        var theme = TerminalTheme.fallback
        theme.ansi = Array(theme.ansi.prefix(3))

        let metrics = analyzer.analyze(theme)
        #expect(metrics.featureVector.count == 60)
    }

    @Test func contentHashIgnoresNameAndBaseTheme() {
        var renamed = TerminalTheme.fallback
        renamed.name = "Something Else"
        renamed.baseThemeName = "SwiftTerm"

        #expect(renamed.contentHash == TerminalTheme.fallback.contentHash)

        var recolored = TerminalTheme.fallback
        recolored.background = ProfileColor(hex: "#000000")!
        #expect(recolored.contentHash != TerminalTheme.fallback.contentHash)
    }
}
