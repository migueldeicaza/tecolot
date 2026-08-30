//
//  ThemeProjection3DTests.swift
//  TecolotTests
//
import Foundation
import Testing
import simd
@testable import Tecolot

final class ThemeProjection3DTests {
    @Test func colorSpaceKeepsNeutralsOnTheLightnessAxis() throws {
        var dark = TerminalTheme.fallback
        dark.name = "Dark Neutral"
        dark.background = ProfileColor(hex: "#202020")!
        var light = TerminalTheme.fallback
        light.name = "Light Neutral"
        light.background = ProfileColor(hex: "#dddddd")!

        let index = ThemeCatalogIndex()
        index.update(themes: [dark, light])
        let catalog = try #require(index.catalog)
        let points = ThemeProjection3D.project(
            themes: [dark, light], metrics: index.metrics, catalog: catalog, mode: .colorSpace3D
        )
        let darkPoint = try #require(points.first(where: { $0.id == dark.name }))
        let lightPoint = try #require(points.first(where: { $0.id == light.name }))

        #expect(abs(darkPoint.position.x) < 1e-12)
        #expect(abs(darkPoint.position.z) < 1e-12)
        #expect(abs(lightPoint.position.x) < 1e-12)
        #expect(abs(lightPoint.position.z) < 1e-12)
        #expect(lightPoint.position.y > darkPoint.position.y)
    }

    @Test func colorSpaceExpansionPreservesHueDirection() throws {
        var blue = TerminalTheme.fallback
        blue.name = "Blue"
        blue.background = ProfileColor(hex: "#102d72")!
        var red = TerminalTheme.fallback
        red.name = "Red"
        red.background = ProfileColor(hex: "#702020")!

        let index = ThemeCatalogIndex()
        index.update(themes: [blue, red])
        let catalog = try #require(index.catalog)
        let perceptual = ThemeProjection3D.project(
            themes: [blue, red], metrics: index.metrics, catalog: catalog, mode: .colorSpace3D,
            colorSpaceChromaScale: .perceptual
        )
        let expanded = ThemeProjection3D.project(
            themes: [blue, red], metrics: index.metrics, catalog: catalog, mode: .colorSpace3D,
            colorSpaceChromaScale: .expanded
        )

        for point in perceptual {
            let expandedPoint = try #require(expanded.first(where: { $0.id == point.id }))
            let rawAngle = atan2(point.rawPosition.z, point.rawPosition.x)
            #expect(abs(atan2(point.position.z, point.position.x) - rawAngle) < 1e-12)
            #expect(abs(atan2(expandedPoint.position.z, expandedPoint.position.x) - rawAngle) < 1e-12)
            #expect(abs(expandedPoint.position.y - point.position.y) < 1e-12)
        }
    }

    @Test func paletteSpaceUsesTheExistingCatalogNormalizations() throws {
        let themes = ThemeCatalogIndexTests.syntheticCatalog(count: 12)
        let index = ThemeCatalogIndex()
        index.update(themes: themes)
        let catalog = try #require(index.catalog)
        let points = ThemeProjection3D.project(
            themes: themes, metrics: index.metrics, catalog: catalog, mode: .paletteSpace3D
        )

        for point in points {
            let metrics = try #require(index.metrics[point.id])
            #expect(abs(
                point.position.x - (2 * catalog.normalized(metrics.ansiSeparationP10, for: .ansiSeparationP10) - 1)
            ) < 1e-12)
            #expect(abs(
                point.position.y - (2 * ThemeProjection.contrastFloor(metrics) - 1)
            ) < 1e-12)
            #expect(abs(
                point.position.z - (2 * catalog.normalized(metrics.ansiColorfulness, for: .ansiColorfulness) - 1)
            ) < 1e-12)
        }
    }

    @Test func similaritySpaceIsDeterministicAndUsesOneScale() throws {
        let themes = ThemeCatalogIndexTests.syntheticCatalog(count: 24)
        let first = ThemeCatalogIndex()
        let second = ThemeCatalogIndex()
        first.update(themes: themes)
        second.update(themes: themes)
        let firstCatalog = try #require(first.catalog)
        let secondCatalog = try #require(second.catalog)
        let basis = try #require(firstCatalog.similarity3D)

        let firstPoints = ThemeProjection3D.project(
            themes: themes, metrics: first.metrics, catalog: firstCatalog, mode: .similaritySpace3D
        )
        let secondPoints = ThemeProjection3D.project(
            themes: themes, metrics: second.metrics, catalog: secondCatalog, mode: .similaritySpace3D
        )
        #expect(firstPoints.count == themes.count)
        for firstPoint in firstPoints {
            let secondPoint = try #require(secondPoints.first(where: { $0.id == firstPoint.id }))
            #expect(simd_length(firstPoint.position - secondPoint.position) < 1e-9)
        }

        #expect(abs(length(basis.basisX) - 1) < 1e-8)
        #expect(abs(length(basis.basisY) - 1) < 1e-8)
        #expect(abs(length(basis.basisZ) - 1) < 1e-8)
        #expect(abs(dot(basis.basisX, basis.basisY)) < 1e-7)
        #expect(abs(dot(basis.basisX, basis.basisZ)) < 1e-7)
        #expect(abs(dot(basis.basisY, basis.basisZ)) < 1e-7)

        let interior = try #require(firstPoints.first {
            max(abs($0.position.x), abs($0.position.y), abs($0.position.z)) < 0.9
                && abs($0.rawPosition.x) > 1e-9
                && abs($0.rawPosition.y) > 1e-9
        })
        #expect(abs(interior.position.x / interior.rawPosition.x - 1 / basis.scale) < 1e-9)
        #expect(abs(interior.position.y / interior.rawPosition.y - 1 / basis.scale) < 1e-9)
    }

    private func dot(_ left: [Double], _ right: [Double]) -> Double {
        zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private func length(_ vector: [Double]) -> Double {
        sqrt(dot(vector, vector))
    }
}
