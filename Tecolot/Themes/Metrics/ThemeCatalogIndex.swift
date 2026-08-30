//
//  ThemeCatalogIndex.swift
//  Tecolot
//
//  The bridge between ThemeStore and the metrics consumers: analyzes each
//  theme (memoized by metric version + content hash), computes catalog-wide
//  statistics — robust normalization bounds, percentile tables, the
//  orientation-stabilized PCA basis — and sorts theme lists by ThemeSortMode.
//
import Combine
import Foundation
import simd

/// Sort orders derived from the metrics engine (spec §26)
nonisolated enum ThemeSortMode: Hashable, Sendable {
    case name
    case backgroundLightness
    case backgroundHue
    case backgroundChroma
    case foregroundContrast
    case ansiVisibility
    case ansiDistinctness
    case colorfulness
    case dynamicRange
    case temperature
    case hueDiversity
    case brightPairSeparation
    case cursorVisibility
    case selectionVisibility
    /// Distance from the named theme. Keyed by theme NAME — the store's key
    /// for metrics, favorites, and pins — because slugs can collide.
    case similarity(to: String)

    var title: String {
        switch self {
        case .name: return "Name"
        case .backgroundLightness: return "Background Brightness"
        case .backgroundHue: return "Background Color"
        case .backgroundChroma: return "Background Saturation"
        case .foregroundContrast: return "Text Contrast"
        case .ansiVisibility: return "ANSI Visibility"
        case .ansiDistinctness: return "Color Distinction"
        case .colorfulness: return "Colorfulness"
        case .dynamicRange: return "Dynamic Range"
        case .temperature: return "Warm ↔ Cool"
        case .hueDiversity: return "Palette Variety"
        case .brightPairSeparation: return "Bright Color Difference"
        case .cursorVisibility: return "Cursor Visibility"
        case .selectionVisibility: return "Selection Visibility"
        case .similarity: return "Similar to Current"
        }
    }
}

/// Metrics without a natural 0…1 range that plots need normalized (§37)
nonisolated enum MetricKey: Hashable, CaseIterable, Sendable {
    case ansiColorfulness
    case ansiSeparationP10
    case selectionSeparation
}

nonisolated struct CatalogStatistics: Sendable {
    /// Robust P02…P98 bounds per metric (§37)
    let normalizationBounds: [MetricKey: ClosedRange<Double>]
    /// Ascending colorfulness values, for percentile ranks and §14 buckets
    let colorfulnessSorted: [Double]
    /// Ascending ansiSeparationP10 values, for percentile ranks
    let distinctnessSorted: [Double]
    /// max(0.04, P95 of background chroma), the §29 radial scale
    let backgroundChromaP95: Double
    /// max(0.05, P98 of background chroma), the 3D color-space scale
    let backgroundChromaP98: Double
    /// Mean of the 60-dim feature vectors
    let pcaMean: [Double]
    /// First principal component, orientation-stabilized (warmth increases)
    let pc1: [Double]
    /// Second principal component, orientation-stabilized (lightness increases)
    let pc2: [Double]
    /// Separate from pc1/pc2 so 3D orientation cannot move the shipped 2D map.
    let similarity3D: Similarity3DBasis?

    /// Clamped robust normalization into 0…1
    func normalized(_ value: Double, for key: MetricKey) -> Double {
        guard let bounds = normalizationBounds[key] else { return 0.5 }
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return 0.5 }
        return min(max((value - bounds.lowerBound) / span, 0), 1)
    }

    /// Fraction of catalog values below `value` in an ascending table, 0…1
    static func percentileRank(of value: Double, in sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return Double(low) / Double(sorted.count)
    }

    /// §14 percentile bucket word for a colorfulness value
    func colorfulnessBucket(for value: Double) -> String {
        let rank = CatalogStatistics.percentileRank(of: value, in: colorfulnessSorted)
        switch rank {
        case ..<0.25: return "Muted"
        case ..<0.75: return "Balanced"
        case ..<0.95: return "Vivid"
        default: return "Extreme"
        }
    }
}

/// The rotated, common-scaled PCA basis used only by Similarity Space 3D.
/// Values remain in memory and are rebuilt with the catalog fingerprint.
nonisolated struct Similarity3DBasis: Sendable {
    let basisX: [Double]
    let basisY: [Double]
    let basisZ: [Double]
    let scale: Double
    let variances: SIMD3<Double>
}

@MainActor
final class ThemeCatalogIndex: ObservableObject {
    /// Per-theme metrics, keyed by theme name like every other theme table
    @Published private(set) var metrics: [String: ThemeMetrics] = [:]
    @Published private(set) var catalog: CatalogStatistics?

    private let analyze: (TerminalTheme) -> ThemeMetrics
    /// Memoized results keyed by (metricVersion, contentHash)
    private var cache: [String: ThemeMetrics] = [:]
    /// Sorted multiset of per-theme cache keys. The cache dictionary
    /// collapses identical-content themes into one entry, so catalog
    /// invalidation must track multiplicity separately.
    private var catalogFingerprint: [String] = []

    init(analyze: ((TerminalTheme) -> ThemeMetrics)? = nil) {
        self.analyze = analyze ?? { ThemeAnalyzer().analyze($0) }
    }

    private static func cacheKey(for theme: TerminalTheme) -> String {
        "\(ThemeAnalyzer.version.rawValue)-\(theme.contentHash)"
    }

    func update(themes: [TerminalTheme]) {
        var newMetrics: [String: ThemeMetrics] = [:]
        var newCache: [String: ThemeMetrics] = [:]
        var keys: [String] = []
        keys.reserveCapacity(themes.count)
        for theme in themes {
            let key = ThemeCatalogIndex.cacheKey(for: theme)
            let themeMetrics = newCache[key] ?? cache[key] ?? analyze(theme)
            newCache[key] = themeMetrics
            newMetrics[theme.name] = themeMetrics
            keys.append(key)
        }
        let fingerprint = keys.sorted()
        let contentChanged = fingerprint != catalogFingerprint
        catalogFingerprint = fingerprint
        cache = newCache
        metrics = newMetrics
        if catalog == nil || contentChanged {
            catalog = ThemeCatalogIndex.catalogStatistics(
                for: themes.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                },
                metrics: newMetrics
            )
        }
    }

    /// Sorted copy of `themes` per the mode, name as the final tie-breaker
    func sorted(_ themes: [TerminalTheme], by mode: ThemeSortMode) -> [TerminalTheme] {
        func byName(_ left: TerminalTheme, _ right: TerminalTheme) -> Bool {
            left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

        // Sorts by a per-theme key, evaluated once per theme rather than per
        // comparison; themes without metrics or without the optional value go
        // last, names break every tie.
        func sortedByKey(
            ascending: Bool = true,
            _ key: (ThemeMetrics) -> Double?
        ) -> [TerminalTheme] {
            themes
                .map { (theme: $0, value: metrics[$0.name].flatMap(key)) }
                .sorted { left, right in
                    switch (left.value, right.value) {
                    case (nil, nil):
                        return byName(left.theme, right.theme)
                    case (nil, _):
                        return false
                    case (_, nil):
                        return true
                    case (let l?, let r?):
                        if l == r {
                            return byName(left.theme, right.theme)
                        }
                        return ascending ? l < r : l > r
                    }
                }
                .map(\.theme)
        }

        switch mode {
        case .name:
            return themes.sorted(by: byName)
        case .backgroundLightness:
            return sortedByKey { $0.backgroundLightness }
        case .backgroundHue:
            return sortedByKey { $0.backgroundHue }
        case .backgroundChroma:
            return sortedByKey { $0.backgroundChroma }
        case .foregroundContrast:
            return sortedByKey(ascending: false) { $0.foregroundContrast }
        case .ansiVisibility:
            return sortedByKey(ascending: false) { $0.ansiContrastP10 }
        case .ansiDistinctness:
            return sortedByKey(ascending: false) { $0.ansiSeparationP10 }
        case .colorfulness:
            return sortedByKey(ascending: false) { $0.ansiColorfulness }
        case .dynamicRange:
            return sortedByKey(ascending: false) { $0.ansiLightnessSpread }
        case .temperature:
            return sortedByKey(ascending: false) { $0.temperature }
        case .hueDiversity:
            return sortedByKey(ascending: false) { $0.hueDiversity }
        case .brightPairSeparation:
            return sortedByKey(ascending: false) { $0.brightPairSeparation }
        case .cursorVisibility:
            return sortedByKey(ascending: false) { $0.cursorContrast }
        case .selectionVisibility:
            // Themes on the system selection color have no real value; they
            // group last instead of pretending the synthetic mix is real.
            return sortedByKey(ascending: false) {
                $0.hasCustomSelection ? $0.selectionSeparation : nil
            }
        case .similarity(let name):
            guard let reference = metrics[name] else {
                return themes.sorted(by: byName)
            }
            return sortedByKey { themeDistance(reference, $0) }
        }
    }

    // MARK: - Catalog statistics

    nonisolated private static func catalogStatistics(
        for themes: [TerminalTheme],
        metrics: [String: ThemeMetrics]
    ) -> CatalogStatistics? {
        let ordered = themes.compactMap { metrics[$0.name] }
        guard !ordered.isEmpty else { return nil }

        func bounds(_ values: [Double]) -> ClosedRange<Double> {
            let sorted = values.sorted()
            let low = ThemeColorMath.quantileOfSorted(sorted, 0.02)
            let high = ThemeColorMath.quantileOfSorted(sorted, 0.98)
            return low...high
        }

        let colorfulness = ordered.map(\.ansiColorfulness)
        let distinctness = ordered.map(\.ansiSeparationP10)
        let normalizationBounds: [MetricKey: ClosedRange<Double>] = [
            .ansiColorfulness: bounds(colorfulness),
            .ansiSeparationP10: bounds(distinctness),
            .selectionSeparation: bounds(ordered.map(\.selectionSeparation))
        ]

        let basis = pcaBasis(for: ordered)

        return CatalogStatistics(
            normalizationBounds: normalizationBounds,
            colorfulnessSorted: colorfulness.sorted(),
            distinctnessSorted: distinctness.sorted(),
            backgroundChromaP95: max(
                0.04, ThemeColorMath.quantile(ordered.map(\.backgroundChroma), 0.95)
            ),
            backgroundChromaP98: max(
                0.05, ThemeColorMath.quantile(ordered.map(\.backgroundChroma), 0.98)
            ),
            pcaMean: basis.mean,
            pc1: basis.pc1,
            pc2: basis.pc2,
            similarity3D: basis.similarity3D
        )
    }

    // MARK: - PCA (spec §35)

    nonisolated private struct PCABasis {
        let mean: [Double]
        let pc1: [Double]
        let pc2: [Double]
        let similarity3D: Similarity3DBasis?
    }

    nonisolated private static func pcaBasis(for ordered: [ThemeMetrics]) -> PCABasis {
        let dimensions = 60
        var identity1 = [Double](repeating: 0, count: dimensions)
        identity1[0] = 1
        var identity2 = [Double](repeating: 0, count: dimensions)
        identity2[1] = 1

        let vectors = ordered.map(\.featureVector).filter { $0.count == dimensions }
        guard vectors.count >= 2 else {
            return PCABasis(
                mean: vectors.first ?? [Double](repeating: 0, count: dimensions),
                pc1: identity1,
                pc2: identity2,
                similarity3D: nil
            )
        }

        var mean = [Double](repeating: 0, count: dimensions)
        for vector in vectors {
            for i in 0..<dimensions {
                mean[i] += vector[i]
            }
        }
        for i in 0..<dimensions {
            mean[i] /= Double(vectors.count)
        }
        let centered = vectors.map { vector in
            (0..<dimensions).map { vector[$0] - mean[$0] }
        }

        // Covariance matrix, row-major 60×60
        var covariance = [Double](repeating: 0, count: dimensions * dimensions)
        for vector in centered {
            for row in 0..<dimensions {
                let value = vector[row]
                guard value != 0 else { continue }
                for column in 0..<dimensions {
                    covariance[row * dimensions + column] += value * vector[column]
                }
            }
        }
        for i in 0..<covariance.count {
            covariance[i] /= Double(vectors.count)
        }

        guard var pc1 = principalComponent(of: covariance, dimensions: dimensions) else {
            return PCABasis(mean: mean, pc1: identity1, pc2: identity2, similarity3D: nil)
        }
        // Deflate: remove the first component's variance, then repeat
        let lambda = rayleighQuotient(covariance, pc1, dimensions: dimensions)
        var deflated = covariance
        for row in 0..<dimensions {
            for column in 0..<dimensions {
                deflated[row * dimensions + column] -= lambda * pc1[row] * pc1[column]
            }
        }
        let rawPC1 = pc1
        let rawPC2 = principalComponent(of: deflated, dimensions: dimensions)
        var pc2 = rawPC2 ?? identity2

        stabilizeOrientation(pc1: &pc1, pc2: &pc2, centered: centered, metrics: ordered)

        let similarity3D: Similarity3DBasis?
        if vectors.count >= 3, let rawPC2 {
            let lambda2 = rayleighQuotient(deflated, rawPC2, dimensions: dimensions)
            var twiceDeflated = deflated
            for row in 0..<dimensions {
                for column in 0..<dimensions {
                    twiceDeflated[row * dimensions + column] -= lambda2 * rawPC2[row] * rawPC2[column]
                }
            }
            if let rawPC3 = principalComponent(of: twiceDeflated, dimensions: dimensions) {
                let lambda1 = rayleighQuotient(covariance, rawPC1, dimensions: dimensions)
                let lambda3 = rayleighQuotient(twiceDeflated, rawPC3, dimensions: dimensions)
                let totalVariance = (0..<dimensions).reduce(0.0) { partial, index in
                    partial + covariance[index * dimensions + index]
                }
                similarity3D = stabilizedSimilarity3DBasis(
                    pc1: rawPC1,
                    pc2: rawPC2,
                    pc3: rawPC3,
                    centered: centered,
                    metrics: ordered,
                    variances: SIMD3(lambda1, lambda2, lambda3),
                    totalVariance: totalVariance
                )
            } else {
                similarity3D = nil
            }
        } else {
            similarity3D = nil
        }

        return PCABasis(mean: mean, pc1: pc1, pc2: pc2, similarity3D: similarity3D)
    }

    /// Creates a rigidly rotated 3D PCA basis. The existing pc1/pc2 basis
    /// is deliberately not reused because its in-plane stabilization serves
    /// the 2D similarity map.
    nonisolated private static func stabilizedSimilarity3DBasis(
        pc1: [Double],
        pc2: [Double],
        pc3: [Double],
        centered: [[Double]],
        metrics: [ThemeMetrics],
        variances: SIMD3<Double>,
        totalVariance: Double
    ) -> Similarity3DBasis {
        func dot(_ left: [Double], _ right: [Double]) -> Double {
            zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
        }
        func covariance(_ values: [Double], _ property: [Double]) -> Double {
            let meanValue = ThemeColorMath.mean(values)
            let meanProperty = ThemeColorMath.mean(property)
            return zip(values, property).reduce(0) {
                $0 + ($1.0 - meanValue) * ($1.1 - meanProperty)
            } / Double(values.count)
        }
        func normalized(_ vector: SIMD3<Double>) -> SIMD3<Double>? {
            let length = simd_length(vector)
            guard length > 1e-12 else { return nil }
            return vector / length
        }
        func basisVector(_ components: SIMD3<Double>) -> [Double] {
            (0..<pc1.count).map {
                components.x * pc1[$0] + components.y * pc2[$0] + components.z * pc3[$0]
            }
        }

        let x = centered.map { dot($0, pc1) }
        let y = centered.map { dot($0, pc2) }
        let z = centered.map { dot($0, pc3) }
        let lightness = metrics.map(\.backgroundLightness)
        let temperature = metrics.map(\.temperature)

        let unrotated = (
            x: SIMD3<Double>(1, 0, 0),
            y: SIMD3<Double>(0, 1, 0),
            z: SIMD3<Double>(0, 0, 1)
        )
        guard let up = normalized(SIMD3(
            covariance(x, lightness), covariance(y, lightness), covariance(z, lightness)
        )) else {
            return similarity3DBasis(
                x: unrotated.x, y: unrotated.y, z: unrotated.z,
                basisVector: basisVector, centered: centered, variances: variances,
                totalVariance: totalVariance
            )
        }

        let temperatureDirection = SIMD3(
            covariance(x, temperature), covariance(y, temperature), covariance(z, temperature)
        )
        let horizontal = temperatureDirection - simd_dot(temperatureDirection, up) * up
        guard let right = normalized(horizontal) else {
            // With no temperature signal, preserve the raw PCA horizontal plane.
            return similarity3DBasis(
                x: unrotated.x, y: unrotated.y, z: unrotated.z,
                basisVector: basisVector, centered: centered, variances: variances,
                totalVariance: totalVariance
            )
        }
        let toward = simd_cross(right, up)
        return similarity3DBasis(
            x: right,
            y: up,
            z: toward,
            basisVector: basisVector,
            centered: centered,
            variances: variances,
            totalVariance: totalVariance
        )
    }

    nonisolated private static func similarity3DBasis(
        x: SIMD3<Double>,
        y: SIMD3<Double>,
        z: SIMD3<Double>,
        basisVector: (SIMD3<Double>) -> [Double],
        centered: [[Double]],
        variances: SIMD3<Double>,
        totalVariance: Double
    ) -> Similarity3DBasis {
        let basisX = basisVector(x)
        let basisY = basisVector(y)
        let basisZ = basisVector(z)
        func dot(_ left: [Double], _ right: [Double]) -> Double {
            zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let radii = centered.map { vector in
            let x = dot(vector, basisX)
            let y = dot(vector, basisY)
            let z = dot(vector, basisZ)
            return sqrt(x * x + y * y + z * z)
        }
        let scale = max(1e-12, ThemeColorMath.quantile(radii, 0.98))
        let explained = totalVariance > 0 ? variances / totalVariance : variances
        return Similarity3DBasis(
            basisX: basisX,
            basisY: basisY,
            basisZ: basisZ,
            scale: scale,
            variances: explained
        )
    }

    /// Dominant eigenvector by deterministic power iteration; nil when the
    /// matrix has no usable variance
    nonisolated private static func principalComponent(
        of matrix: [Double], dimensions: Int
    ) -> [Double]? {
        // Deterministic, non-degenerate start vector
        var vector = (0..<dimensions).map { 1.0 + 0.001 * Double($0) }
        normalize(&vector)
        for _ in 0..<200 {
            var next = [Double](repeating: 0, count: dimensions)
            for row in 0..<dimensions {
                var sum = 0.0
                for column in 0..<dimensions {
                    sum += matrix[row * dimensions + column] * vector[column]
                }
                next[row] = sum
            }
            let length = sqrt(next.reduce(0) { $0 + $1 * $1 })
            guard length > 1e-12 else { return nil }
            for i in 0..<dimensions {
                next[i] /= length
            }
            let drift = zip(next, vector).reduce(0) { $0 + abs($1.0 - $1.1) }
            vector = next
            if drift < 1e-12 {
                break
            }
        }
        return vector
    }

    nonisolated private static func rayleighQuotient(
        _ matrix: [Double], _ vector: [Double], dimensions: Int
    ) -> Double {
        var result = 0.0
        for row in 0..<dimensions {
            var sum = 0.0
            for column in 0..<dimensions {
                sum += matrix[row * dimensions + column] * vector[column]
            }
            result += vector[row] * sum
        }
        return result
    }

    nonisolated private static func normalize(_ vector: inout [Double]) {
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return }
        for i in 0..<vector.count {
            vector[i] /= length
        }
    }

    /// Rotates the 2D basis so that increasing background lightness points
    /// along +pc2 and increasing temperature along +pc1 (§35). Projected
    /// distances are preserved.
    nonisolated private static func stabilizeOrientation(
        pc1: inout [Double], pc2: inout [Double],
        centered: [[Double]], metrics: [ThemeMetrics]
    ) {
        func dot(_ a: [Double], _ b: [Double]) -> Double {
            zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let xs = centered.map { dot($0, pc1) }
        let ys = centered.map { dot($0, pc2) }

        func covariance(_ values: [Double], _ property: [Double]) -> Double {
            let meanValue = ThemeColorMath.mean(values)
            let meanProperty = ThemeColorMath.mean(property)
            return zip(values, property).reduce(0) {
                $0 + ($1.0 - meanValue) * ($1.1 - meanProperty)
            } / Double(values.count)
        }

        // The in-plane direction most correlated with lightness becomes up
        let lightness = metrics.map(\.backgroundLightness)
        let upX = covariance(xs, lightness)
        let upY = covariance(ys, lightness)
        let upLength = sqrt(upX * upX + upY * upY)
        if upLength > 1e-12 {
            let ux = upX / upLength
            let uy = upY / upLength
            // New axes inside the PCA plane: up = (ux, uy), right ⟂ up
            let newPc2 = (0..<pc1.count).map { ux * pc1[$0] + uy * pc2[$0] }
            let newPc1 = (0..<pc1.count).map { uy * pc1[$0] - ux * pc2[$0] }
            pc1 = newPc1
            pc2 = newPc2
        }

        // Mirror so that warmer palettes sit toward the right
        let temperature = metrics.map(\.temperature)
        let newXs = centered.map { dot($0, pc1) }
        if covariance(newXs, temperature) < 0 {
            for i in 0..<pc1.count {
                pc1[i] = -pc1[i]
            }
        }
    }
}
