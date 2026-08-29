//
//  ThemeCatalogIndexTests.swift
//  TecolotTests
//
//  Tests the catalog index: content-hash memoization, PCA determinism and
//  orientation, robust normalization and the analysis performance budget.
//
import Foundation
import Testing
@testable import Tecolot

final class ThemeCatalogIndexTests {
    @Test func renamingAThemeKeepsItsContentHash() {
        var renamed = TerminalTheme.fallback
        renamed.name = "Renamed"

        #expect(renamed.contentHash == TerminalTheme.fallback.contentHash)
    }

    @Test func editingOneThemeReanalyzesOnlyThatTheme() {
        var analysisCount = 0
        let analyzer = ThemeAnalyzer()
        let index = ThemeCatalogIndex(analyze: { theme in
            analysisCount += 1
            return analyzer.analyze(theme)
        })

        var catalog = Self.syntheticCatalog(count: 10)
        index.update(themes: catalog)
        #expect(analysisCount == catalog.count)

        catalog[3].background = ProfileColor(hex: "#123456")!
        index.update(themes: catalog)
        #expect(analysisCount == catalog.count + 1)

        // A pure rename re-analyzes nothing
        catalog[5].name = "Renamed Theme"
        index.update(themes: catalog)
        #expect(analysisCount == catalog.count + 1)
        #expect(index.metrics["Renamed Theme"] != nil)
    }

    @Test func pcaProjectionIsDeterministicAndOriented() throws {
        let catalog = Self.syntheticCatalog(count: 24)
        let first = ThemeCatalogIndex()
        let second = ThemeCatalogIndex()
        first.update(themes: catalog)
        second.update(themes: catalog)

        let statsA = try #require(first.catalog)
        let statsB = try #require(second.catalog)
        for (a, b) in zip(statsA.pc1, statsB.pc1) {
            #expect(abs(a - b) < 1e-9)
        }
        for (a, b) in zip(statsA.pc2, statsB.pc2) {
            #expect(abs(a - b) < 1e-9)
        }

        // Orientation: pc2 grows with lightness, pc1 with warmth
        func project(_ name: String) -> (x: Double, y: Double) {
            let vector = first.metrics[name]!.featureVector
            let centered = zip(vector, statsA.pcaMean).map(-)
            return (
                x: zip(centered, statsA.pc1).reduce(0) { $0 + $1.0 * $1.1 },
                y: zip(centered, statsA.pc2).reduce(0) { $0 + $1.0 * $1.1 }
            )
        }
        // The synthetic catalog contains a light, a dark, a warm and a cool
        // extreme (see syntheticCatalog)
        #expect(project("Light Extreme").y > project("Dark Extreme").y)
        #expect(project("Warm Extreme").x > project("Cool Extreme").x)
    }

    @Test func robustBoundsIgnoreAPathologicalOutlier() throws {
        // Colorfulness must vary smoothly so the P98 bound does not sit on a
        // distribution cliff: blend the palette from gray toward saturation.
        let catalog: [TerminalTheme] = (0..<50).map { i in
            let fraction = Double(i) / 49
            var theme = TerminalTheme.fallback
            theme.name = "Blend \(i)"
            theme.ansi = (0..<16).map { slot in
                let target: (r: Double, g: Double, b: Double) =
                    slot % 2 == 0 ? (1, 0.2, 0.1) : (0.1, 0.3, 1)
                func channel(_ t: Double) -> UInt16 {
                    UInt16(((0.5 + fraction * (t - 0.5)) * 65535).rounded())
                }
                return ProfileColor(
                    red: channel(target.r), green: channel(target.g), blue: channel(target.b)
                )
            }
            return theme
        }
        let baseline = ThemeCatalogIndex()
        baseline.update(themes: catalog)
        let baselineStats = try #require(baseline.catalog)

        // One absurdly colorful theme joins the catalog
        var outlier = TerminalTheme.fallback
        outlier.name = "Outlier"
        outlier.ansi = (0..<16).map { _ in ProfileColor(hex: "#ff00ff")! }
        let extended = ThemeCatalogIndex()
        extended.update(themes: catalog + [outlier])
        let extendedStats = try #require(extended.catalog)

        for theme in catalog {
            let value = baseline.metrics[theme.name]!.ansiColorfulness
            let before = baselineStats.normalized(value, for: .ansiColorfulness)
            let after = extendedStats.normalized(value, for: .ansiColorfulness)
            #expect(abs(before - after) < 0.05)
        }
    }

    @Test func selectionSortGroupsSystemSelectionLast() {
        var custom = TerminalTheme.fallback
        custom.name = "Custom Selection"
        custom.selectionBackground = ProfileColor(hex: "#4466aa")
        var system = TerminalTheme.fallback
        system.name = "A System Selection"  // alphabetically first on purpose
        system.selectionBackground = nil

        let index = ThemeCatalogIndex()
        index.update(themes: [system, custom])
        let sorted = index.sorted([system, custom], by: .selectionVisibility)

        #expect(sorted.map(\.name) == ["Custom Selection", "A System Selection"])
    }

    @Test func similaritySortPutsTheReferenceFirst() {
        let catalog = Self.syntheticCatalog(count: 12)
        let index = ThemeCatalogIndex()
        index.update(themes: catalog)

        let reference = catalog[4]
        let sorted = index.sorted(catalog, by: .similarity(to: reference.name))
        #expect(sorted.first?.name == reference.name)

        // Moving the anchor re-orders the catalog around the new theme, so a
        // selection change in the browser reshuffles the similarity sort
        let other = catalog[9]
        let resorted = index.sorted(catalog, by: .similarity(to: other.name))
        #expect(resorted.first?.name == other.name)
        #expect(resorted.map(\.name) != sorted.map(\.name))
    }

    @Test func addingADuplicateContentThemeRefreshesCatalogStatistics() throws {
        // Duplicate & Edit creates an identical-content theme under a new
        // name; the catalog population changes even though the set of
        // content hashes does not.
        var catalog = Self.syntheticCatalog(count: 10)
        let index = ThemeCatalogIndex()
        index.update(themes: catalog)
        let before = try #require(index.catalog)

        var duplicate = catalog[0]
        duplicate.name = "\(duplicate.name) copy"
        catalog.append(duplicate)
        index.update(themes: catalog)
        let after = try #require(index.catalog)

        #expect(after.colorfulnessSorted.count == before.colorfulnessSorted.count + 1)
    }

    @Test func analysisOfLargeCatalogStaysWithinBudget() {
        let catalog = Self.syntheticCatalog(count: 300)
        let index = ThemeCatalogIndex()

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            index.update(themes: catalog)
        }
        // Budget is 10 ms for 300 themes; allow generous CI headroom
        #expect(elapsed < .milliseconds(500))
        #expect(index.metrics.count == catalog.count)
    }

    /// Themes with spread-out lightness, hue and colorfulness, including
    /// named light/dark/warm/cool extremes for the orientation tests
    static func syntheticCatalog(count: Int) -> [TerminalTheme] {
        var catalog: [TerminalTheme] = []
        for i in 0..<count {
            let fraction = Double(i) / Double(max(count - 1, 1))
            let level = UInt16(min(fraction, 1) * 65535)
            let hueShift = UInt16((Double(i).truncatingRemainder(dividingBy: 7) / 7) * 20000)
            var theme = TerminalTheme.fallback
            theme.name = "Synthetic \(i)"
            theme.background = ProfileColor(
                red: level, green: UInt16(min(UInt32(level / 2) + UInt32(hueShift), 65535)), blue: 65535 - level
            )
            theme.foreground = ProfileColor(
                red: 65535 - level, green: 65535 - level / 2, blue: level
            )
            theme.ansi[1] = ProfileColor(red: 65535, green: hueShift, blue: level / 3)
            theme.ansi[4] = ProfileColor(red: level / 3, green: hueShift, blue: 65535)
            catalog.append(theme)
        }
        var light = TerminalTheme.fallback
        light.name = "Light Extreme"
        light.background = ProfileColor(hex: "#ffffff")!
        light.foreground = ProfileColor(hex: "#222222")!
        var dark = TerminalTheme.fallback
        dark.name = "Dark Extreme"
        dark.background = ProfileColor(hex: "#000000")!
        var warm = TerminalTheme.fallback
        warm.name = "Warm Extreme"
        warm.ansi = (0..<16).map { _ in ProfileColor(hex: "#ff8800")! }
        var cool = TerminalTheme.fallback
        cool.name = "Cool Extreme"
        cool.ansi = (0..<16).map { _ in ProfileColor(hex: "#3366ff")! }
        return catalog + [light, dark, warm, cool]
    }
}
