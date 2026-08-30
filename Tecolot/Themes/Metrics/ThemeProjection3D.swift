//
//  ThemeProjection3D.swift
//  Tecolot
//
//  Framework-independent coordinates for the authored 3D theme spaces.
//  The renderer supplies the camera and screen projection.
//
import Foundation
import simd

nonisolated enum ColorSpaceChromaScale: Sendable {
    case perceptual
    case expanded
}

nonisolated struct ThemePlotPoint3D: Identifiable, Sendable {
    /// Theme name. It is the key used by the theme store and metric table.
    let id: String
    /// Canonical coordinates: X right, Y up, Z toward the viewer.
    let position: SIMD3<Double>
    /// Source values before a catalog normalization or display transform.
    let rawPosition: SIMD3<Double>
    let background: ProfileColor
    let foreground: ProfileColor
    let accent: ProfileColor
}

extension ThemePlotPoint3D: ThemeMarkerPoint {}

nonisolated enum ThemeProjection3D {
    static let perceptualChromaDefaultsKey = "themeColorSpacePerceptualChroma"

    /// The advanced setting is intentionally not surfaced in the browser.
    /// Tests and a future inspector can select either mapping explicitly.
    static func preferredColorSpaceChromaScale(
        defaults: UserDefaults = .standard
    ) -> ColorSpaceChromaScale {
        defaults.bool(forKey: perceptualChromaDefaultsKey) ? .perceptual : .expanded
    }

    static func project(
        themes: [TerminalTheme],
        metrics: [String: ThemeMetrics],
        catalog: CatalogStatistics,
        mode: ThemePlotMode,
        colorSpaceChromaScale: ColorSpaceChromaScale = .expanded
    ) -> [ThemePlotPoint3D] {
        guard mode.isThreeDimensional else { return [] }

        return themes.compactMap { theme in
            guard let themeMetrics = metrics[theme.name] else { return nil }
            let rawPosition: SIMD3<Double>
            let position: SIMD3<Double>

            switch mode {
            case .colorSpace3D:
                let hue = (themeMetrics.backgroundHue ?? 0) * .pi / 180
                let chroma = themeMetrics.backgroundChroma
                let a = themeMetrics.backgroundHue == nil ? 0 : chroma * cos(hue)
                let b = themeMetrics.backgroundHue == nil ? 0 : chroma * sin(hue)
                rawPosition = SIMD3(a, themeMetrics.backgroundLightness, b)

                let normalizedChroma = themeMetrics.backgroundHue == nil
                    ? 0
                    : min(max(chroma / catalog.backgroundChromaP98, 0), 1)
                let displayChroma: Double
                switch colorSpaceChromaScale {
                case .perceptual:
                    displayChroma = normalizedChroma
                case .expanded:
                    displayChroma = pow(normalizedChroma, 0.65)
                }
                position = SIMD3(
                    displayChroma * cos(hue),
                    2 * themeMetrics.backgroundLightness - 1,
                    displayChroma * sin(hue)
                )

            case .paletteSpace3D:
                let distinctness = catalog.normalized(
                    themeMetrics.ansiSeparationP10, for: .ansiSeparationP10
                )
                let visibility = ThemeProjection.contrastFloor(themeMetrics)
                let colorfulness = catalog.normalized(
                    themeMetrics.ansiColorfulness, for: .ansiColorfulness
                )
                rawPosition = SIMD3(
                    themeMetrics.ansiSeparationP10,
                    visibility,
                    themeMetrics.ansiColorfulness
                )
                position = SIMD3(
                    2 * distinctness - 1,
                    2 * visibility - 1,
                    2 * colorfulness - 1
                )

            case .similaritySpace3D:
                guard let basis = catalog.similarity3D,
                      themeMetrics.featureVector.count == catalog.pcaMean.count else {
                    return nil
                }
                let centered = zip(themeMetrics.featureVector, catalog.pcaMean).map(-)
                let rawX = dot(centered, basis.basisX)
                let rawY = dot(centered, basis.basisY)
                let rawZ = dot(centered, basis.basisZ)
                rawPosition = SIMD3(rawX, rawY, rawZ)
                position = SIMD3(
                    clamp(rawX / basis.scale),
                    clamp(rawY / basis.scale),
                    clamp(rawZ / basis.scale)
                )

            default:
                return nil
            }

            return ThemePlotPoint3D(
                id: theme.name,
                position: position,
                rawPosition: rawPosition,
                background: theme.background,
                foreground: theme.foreground,
                accent: ThemeProjection.accentColor(for: theme, metrics: themeMetrics)
            )
        }
    }

    private static func dot(_ left: [Double], _ right: [Double]) -> Double {
        zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }
}
