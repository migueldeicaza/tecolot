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
        #expect(metrics.brightHueDrift.map {
            abs($0) < 1e-12
        } ?? true)
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
        #expect(metrics.featureVector.allSatisfy {
            $0.isFinite
        })
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

    @Test func faithfulPrimaryPaletteScoresHighFidelityAndVitality() {
        let metrics = analyzer.analyze(TerminalTheme.fallback)

        #expect(metrics.ansiNameFidelity > 0.85)
        #expect(metrics.chromaticVitality > 0.70)
        #expect(metrics.ansiArchetype == .faithful)
        #expect(!metrics.hasRepurposedBrights)
        #expect(metrics.ansiSlotFidelities.count == 12)
        #expect(metrics.diffClarity > 0.50)
    }

    @Test func grayscalePaletteDoesNotScoreHighFidelity() {
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
        #expect(metrics.ansiNameFidelity == 0)
        #expect(metrics.chromaticVitality == 0)
        #expect(metrics.ansiArchetype == .monochromeTinted)
    }

    @Test func singleHuePhosphorPaletteClassifiesAsMonochrome() {
        var theme = TerminalTheme.fallback
        let ambers = ["#ff6a00", "#ffb000", "#ffc742", "#ff8c00", "#ffa033", "#ffd27f"]
        for (offset, index) in [1, 2, 3, 4, 5, 6].enumerated() {
            theme.ansi[index] = ProfileColor(hex: ambers[offset])!
            theme.ansi[index + 8] = ProfileColor(hex: ambers[offset])!
        }

        let metrics = analyzer.analyze(theme)
        #expect(metrics.chromaticVitality < 0.15)
        #expect(metrics.ansiArchetype == .monochromeTinted)
        #expect(metrics.diffClarity < analyzer.analyze(TerminalTheme.fallback).diffClarity)
    }

    @Test func vividRemappedPaletteClassifiesAsStylizedNotMonochrome() {
        var theme = TerminalTheme.fallback
        // Swap red→cyan, green→blue, yellow→magenta, blue→green, magenta→red, cyan→yellow
        let swapped = ["#00dfdb", "#00b4ff", "#ff4297", "#00c15a", "#ff3b30", "#ffd60a"]
        for (offset, index) in [1, 2, 3, 4, 5, 6].enumerated() {
            theme.ansi[index] = ProfileColor(hex: swapped[offset])!
            theme.ansi[index + 8] = ProfileColor(hex: swapped[offset])!
        }

        let metrics = analyzer.analyze(theme)
        #expect(metrics.ansiNameFidelity < 0.30)
        #expect(metrics.chromaticVitality > 0.60)
        #expect(metrics.ansiArchetype == .stylizedRemapped)
    }

    @Test func solarizedBrightSlotRepurposingIsDetected() {
        var theme = TerminalTheme.fallback
        // Keep faithful normal slots 1…6, replace bright slots 9…14 with neutral grays
        for index in 9...14 {
            theme.ansi[index] = ProfileColor(hex: "#657b83")!
        }

        let metrics = analyzer.analyze(theme)
        #expect(metrics.ansiNormalFidelity > 0.85)
        #expect(metrics.ansiBrightFidelity < 0.20)
        #expect(metrics.hasRepurposedBrights)
    }

    @Test func bundledThemesClassifyIntoExpectedArchetypes() throws {
        let themes = Dictionary(uniqueKeysWithValues: ThemeStore.loadBundledThemes().map { ($0.name, $0) })
        try #require(!themes.isEmpty)

        let swiftTerm = analyzer.analyze(try #require(themes["SwiftTerm"]))
        #expect(swiftTerm.ansiArchetype == .faithful)

        if let amber = themes["Amber CRT Retro"] {
            #expect(analyzer.analyze(amber).ansiArchetype == .monochromeTinted)
        }
        if let oxocarbon = themes["Oxocarbon"] {
            #expect(analyzer.analyze(oxocarbon).ansiArchetype == .stylizedRemapped)
        }
        if let solarized = themes["iTerm2 Solarized Dark"] {
            let m = analyzer.analyze(solarized)
            #expect(m.hasRepurposedBrights)
            #expect(m.ansiNormalFidelity > 0.85)
        }

        // Every bundled theme's archetype must strictly match the shared
        // Fidelity × Vitality crosshair thresholds (no vivid theme labelled Soft).
        for theme in themes.values {
            let m = analyzer.analyze(theme)
            let expectedFaithful = m.ansiNameFidelity >= ThemeAnalyzer.fidelityArchetypeThreshold
            let expectedVital = m.chromaticVitality >= ThemeAnalyzer.vitalityArchetypeThreshold
            switch (expectedFaithful, expectedVital) {
            case (true, true):
                #expect(m.ansiArchetype == .faithful)
            case (true, false):
                #expect(m.ansiArchetype == .softMuted)
            case (false, true):
                #expect(m.ansiArchetype == .stylizedRemapped)
            case (false, false):
                #expect(m.ansiArchetype == .monochromeTinted)
            }
        }
    }
}
