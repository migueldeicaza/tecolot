//
//  ThemeProjectionTests.swift
//  TecolotTests
//
//  Tests the plot projections: every mode stays inside the unit square for
//  the bundled catalog, and the background spectrum places neutral
//  backgrounds at the center and tinted ones toward the rim.
//
import Foundation
import Testing
@testable import Tecolot

final class ThemeProjectionTests {
    @Test func everyModeStaysInsideTheUnitSquareForTheBundledCatalog() throws {
        // The test bundle is hosted by the app, so the bundled themes load
        let themes = ThemeStore.loadBundledThemes()
        try #require(!themes.isEmpty)

        let index = ThemeCatalogIndex()
        index.update(themes: themes)
        let catalog = try #require(index.catalog)

        for mode in ThemePlotMode.allCases {
            let points = ThemeProjection.project(
                themes: themes, metrics: index.metrics, catalog: catalog, mode: mode
            )
            #expect(points.count == themes.count)
            for point in points {
                #expect(point.position.x >= 0 && point.position.x <= 1)
                #expect(point.position.y >= 0 && point.position.y <= 1)
            }
        }
    }

    @Test func backgroundSpectrumExpandsRadially() throws {
        var neutral = TerminalTheme.fallback
        neutral.name = "Neutral Background"
        neutral.background = ProfileColor(hex: "#202020")!
        var tinted = TerminalTheme.fallback
        tinted.name = "Tinted Background"
        tinted.background = ProfileColor(hex: "#103080")!  // strongly blue
        var mild = TerminalTheme.fallback
        mild.name = "Mild Background"
        mild.background = ProfileColor(hex: "#202028")!

        let index = ThemeCatalogIndex()
        index.update(themes: [neutral, tinted, mild])
        let catalog = try #require(index.catalog)
        let points = ThemeProjection.project(
            themes: [neutral, tinted, mild],
            metrics: index.metrics,
            catalog: catalog,
            mode: .backgroundSpectrum
        )
        func radius(_ name: String) -> Double {
            let position = points.first { $0.id == name }!.position
            return hypot(position.x - 0.5, position.y - 0.5)
        }

        // A neutral background sits at the center
        #expect(radius("Neutral Background") < 0.01)
        // A strongly tinted one moves toward the rim
        #expect(radius("Tinted Background") > 0.3)
        #expect(radius("Tinted Background") > radius("Mild Background"))

        // The tinted point sits at its hue angle: blue points down-left in
        // OKLab (negative b, slightly negative a) → x < 0.5
        let tintedPosition = points.first { $0.id == "Tinted Background" }!.position
        #expect(tintedPosition.x < 0.5)
    }

    @Test func systemSelectionThemesAreMarkedForTheInteractionPlot() throws {
        var custom = TerminalTheme.fallback
        custom.name = "Custom"
        custom.selectionBackground = ProfileColor(hex: "#4466aa")
        var system = TerminalTheme.fallback
        system.name = "System"
        system.selectionBackground = nil

        let index = ThemeCatalogIndex()
        index.update(themes: [custom, system])
        let catalog = try #require(index.catalog)
        let points = ThemeProjection.project(
            themes: [custom, system],
            metrics: index.metrics,
            catalog: catalog,
            mode: .interactionColors
        )

        #expect(points.first { $0.id == "Custom" }?.hasCustomSelection == true)
        #expect(points.first { $0.id == "System" }?.hasCustomSelection == false)
    }

    @Test func neutralThemeUsesTheForegroundAsAccent() throws {
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

        let index = ThemeCatalogIndex()
        index.update(themes: [theme, TerminalTheme.fallback])
        let catalog = try #require(index.catalog)
        let points = ThemeProjection.project(
            themes: [theme], metrics: index.metrics, catalog: catalog,
            mode: .brightnessAndColorfulness
        )

        #expect(points.first?.accent == theme.foreground)
    }
}
