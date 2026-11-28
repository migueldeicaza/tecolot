//
//  ThemeSpace3DView.swift
//  Tecolot
//
//  The Canvas renderer for the authored 3D spaces.
//
import SwiftUI

private struct ProjectedThemePoint3D: Identifiable {
    let point: ThemePlotPoint3D
    let screenPoint: CGPoint
    let depth: Double

    var id: String {
        point.id
    }
}

struct ThemeSpace3DView: View {
    let themes: [TerminalTheme]
    let metrics: [String: ThemeMetrics]
    let catalog: CatalogStatistics?
    let mode: ThemePlotMode
    let query: String
    let selectedThemeName: String
    @Binding var pinnedThemeName: String?
    @Binding var cameraByMode: [ThemePlotMode: ThemeCamera]
    @Binding var previewPage: ThemePreviewPage?
    let onSelect: (TerminalTheme) -> Void
    var onShowSimilar: ((String) -> Void)? = nil

    @State private var hoveredThemeName: String?
    @State private var showHoverCard = false
    @State private var hoverDebounce: Task<Void, Never>?
    @State private var lastDragTranslation = CGSize.zero
    @State private var magnificationStartZoom: Double?

    var body: some View {
        GeometryReader { outer in
            let showsDockedInspector = outer.size.width >= PlotGeometry.dockedInspectorThreshold
            let spaceSize = CGSize(
                width: showsDockedInspector ? max(outer.size.width - 263, 1) : outer.size.width,
                height: outer.size.height
            )
            let projected = projectedPoints(in: spaceSize)
            let matching = matchingNames

            HStack(spacing: 0) {
                spaceArea(
                    size: spaceSize,
                    projected: projected,
                    matching: matching,
                    showsDockedInspector: showsDockedInspector
                )
                if showsDockedInspector {
                    Divider()
                    dockedInspector(
                        projected: projected,
                        matching: matching
                    )
                }
            }
        }
        .onChange(of: mode) { _, _ in
            clearHover()
        }
        .frame(minWidth: 420, minHeight: 240)
        .help("Drag to rotate. Pinch or use + and − to zoom. Double-click empty space to reset.")
    }

    private func spaceArea(
        size: CGSize,
        projected: [ProjectedThemePoint3D],
        matching: Set<String>,
        showsDockedInspector: Bool
    ) -> some View {
        let emphasis = similarityEmphasis(for: projected)
        let neighborIDs = similarityNeighborIDs(for: projected)

        return ZStack(alignment: .topLeading) {
            ThemeSpace3DCanvas(
                points: projected,
                matching: matching,
                hoveredID: hoveredThemeName,
                pinnedID: pinnedThemeName,
                selectedID: selectedThemeName,
                mode: mode,
                camera: activeCamera,
                horizontalScale: horizontalProjectionScale,
                emphasis: emphasis,
                neighborIDs: neighborIDs
            )
            if !showsDockedInspector {
                hoverCard(points: projected, matching: matching, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                updateHover(at: location, points: projected, matching: matching)
            case .ended:
                clearHover()
            }
        }
        .gesture(
            SpatialTapGesture(count: 2)
                .exclusively(before: SpatialTapGesture())
                .onEnded { result in
                    switch result {
                    case .first(let value):
                        if nearestTheme(to: value.location, points: projected, matching: matching) == nil {
                            resetCamera()
                        }
                    case .second(let value):
                        select(at: value.location, points: projected, matching: matching)
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let horizontal = value.translation.width - lastDragTranslation.width
                    let vertical = value.translation.height - lastDragTranslation.height
                    lastDragTranslation = value.translation
                    updateCamera { camera in
                        camera.rotate(
                            horizontalDelta: Double(horizontal),
                            verticalDelta: Double(vertical)
                        )
                    }
                }
                .onEnded { _ in
                    lastDragTranslation = .zero
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = magnificationStartZoom ?? activeCamera.zoom
                    magnificationStartZoom = start
                    updateCamera { camera in
                        camera.setZoom(start * Double(value.magnification))
                    }
                }
                .onEnded { _ in
                    magnificationStartZoom = nil
                }
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in
            handleKey(
                press,
                points: projected,
                matching: matching,
                defaultAnchor: CGPoint(x: size.width / 2, y: size.height / 2)
            )
        }
        .contextMenu {
            if
                let onShowSimilar,
                let name = hoveredThemeName ?? pinnedThemeName {
                Button("Show Similar Themes") {
                    onShowSimilar(name)
                }
            }
        }
        .accessibilityChildren {
            accessibilityPoints(projected)
        }
    }

    @ViewBuilder
    private func dockedInspector(
        projected: [ProjectedThemePoint3D],
        matching: Set<String>
    ) -> some View {
        let inspectedName = hoveredThemeName ?? pinnedThemeName ?? selectedThemeName
        let nearby = hoveredThemeName.map {
            coLocatedGroup(around: $0, points: projected, matching: matching).count - 1
        } ?? 0
        ThemePlotDockedInspector(
            themes: themes,
            metrics: metrics,
            catalog: catalog,
            hoveredThemeName: hoveredThemeName,
            pinnedThemeName: pinnedThemeName,
            selectedThemeName: selectedThemeName,
            previewPage: $previewPage,
            nearbyCount: nearby,
            similarityRank: similarityRank(of: inspectedName, in: projected)
        )
    }

    // MARK: - Projection

    private var activeCamera: ThemeCamera {
        cameraByMode[mode] ?? ThemeCamera.canonical(for: mode)
    }

    private var matchingNames: Set<String> {
        Set(themes.map(\.name).filter {
            ThemeBrowserSections.matches($0, query: query)
        })
    }

    /// Color Space is a chroma ring rather than a cube. It can use the
    /// browser's unused width without crowding the vertical lightness axis.
    private var horizontalProjectionScale: Double {
        mode == .colorSpace3D ? 2 : 1
    }

    private func projectedPoints(in size: CGSize) -> [ProjectedThemePoint3D] {
        guard let catalog else {
            return []
        }
        let points = ThemeProjection3D.project(
            themes: themes,
            metrics: metrics,
            catalog: catalog,
            mode: mode,
            colorSpaceChromaScale: ThemeProjection3D.preferredColorSpaceChromaScale()
        )
        let camera = activeCamera
        return points.map { point in
            let projection = camera.projectedPosition(
                of: point.position,
                in: size,
                horizontalScale: horizontalProjectionScale
            )
            return ProjectedThemePoint3D(
                point: point,
                screenPoint: projection.point,
                depth: projection.depth
            )
        }
    }

    private func updateCamera(_ change: (inout ThemeCamera) -> Void) {
        var camera = activeCamera
        change(&camera)
        cameraByMode[mode] = camera
    }

    private func resetCamera() {
        cameraByMode[mode] = ThemeCamera.canonical(for: mode)
    }

    // MARK: - Hover and picking

    private func updateHover(
        at location: CGPoint,
        points: [ProjectedThemePoint3D],
        matching: Set<String>
    ) {
        let name = nearestTheme(to: location, points: points, matching: matching)
        guard name != hoveredThemeName else {
            return
        }
        hoveredThemeName = name
        showHoverCard = false
        hoverDebounce?.cancel()
        guard name != nil else {
            return
        }
        hoverDebounce = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else {
                return
            }
            showHoverCard = true
        }
    }

    private func clearHover() {
        hoverDebounce?.cancel()
        hoveredThemeName = nil
        showHoverCard = false
    }

    /// Choose the nearest projected candidate. Camera depth breaks an exact
    /// screen-space tie, with the nearer point winning.
    private func nearestTheme(
        to location: CGPoint,
        points: [ProjectedThemePoint3D],
        matching: Set<String>
    ) -> String? {
        points
            .filter {
                matching.contains($0.id)
            }
            .map { point in
                (point: point, distance: hypot(location.x - point.screenPoint.x, location.y - point.screenPoint.y))
            }
            .filter {
                $0.distance <= PlotGeometry.hitRadius
            }
            .sorted {
                if abs($0.distance - $1.distance) > 0.001 {
                    return $0.distance < $1.distance
                }
                return $0.point.depth > $1.point.depth
            }
            .first?
            .point.id
    }

    private func coLocatedGroup(
        around name: String,
        points: [ProjectedThemePoint3D],
        matching: Set<String>
    ) -> [String] {
        guard
            let anchor = points.first(where: {
                $0.id == name
            }) else {
            return [name]
        }
        return points
            .filter { point in
                matching.contains(point.id)
                    && hypot(
                        point.screenPoint.x - anchor.screenPoint.x,
                        point.screenPoint.y - anchor.screenPoint.y
                    ) <= PlotGeometry.coLocatedRadius
            }
            .sorted {
                let firstDistance = hypot(
                    $0.screenPoint.x - anchor.screenPoint.x,
                    $0.screenPoint.y - anchor.screenPoint.y
                )
                let secondDistance = hypot(
                    $1.screenPoint.x - anchor.screenPoint.x,
                    $1.screenPoint.y - anchor.screenPoint.y
                )
                if abs(firstDistance - secondDistance) > 0.001 {
                    return firstDistance < secondDistance
                }
                return $0.depth > $1.depth
            }
            .map(\.id)
    }

    // MARK: - Selection and keyboard

    private func select(at location: CGPoint, points: [ProjectedThemePoint3D], matching: Set<String>) {
        guard let name = nearestTheme(to: location, points: points, matching: matching) else {
            return
        }
        pinnedThemeName = name
        selectTheme(named: name)
    }

    private func selectTheme(named name: String) {
        guard
            let theme = themes.first(where: {
                $0.name == name
            }) else {
            return
        }
        onSelect(theme)
    }

    private func handleKey(
        _ press: KeyPress,
        points: [ProjectedThemePoint3D],
        matching: Set<String>,
        defaultAnchor: CGPoint
    ) -> KeyPress.Result {
        if let mappedPreview = ThemePreviewPage.fromShortcutCharacter(press.characters) {
            previewPage = mappedPreview
            return .handled
        }
        if press.characters == "+" || press.characters == "=" {
            updateCamera {
                $0.setZoom($0.zoom * 1.2)
            }
            return .handled
        }
        if press.characters == "-" {
            updateCamera {
                $0.setZoom($0.zoom / 1.2)
            }
            return .handled
        }

        switch press.key {
        case .return:
            guard let name = pinnedThemeName ?? hoveredThemeName else {
                return .ignored
            }
            selectTheme(named: name)
            return .handled
        case .escape:
            guard pinnedThemeName != nil else {
                return .ignored
            }
            pinnedThemeName = nil
            return .handled
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            if
                let hovered = hoveredThemeName,
                press.key == .upArrow || press.key == .downArrow {
                let group = coLocatedGroup(around: hovered, points: points, matching: matching)
                if group.count > 1, let index = group.firstIndex(of: hovered) {
                    let step = press.key == .downArrow ? 1 : group.count - 1
                    hoveredThemeName = group[(index + step) % group.count]
                    return .handled
                }
            }
            if
                let direction = ThemePlotInteraction.directionVector(for: press.key),
                let next = nextTheme(
                    inDirection: direction,
                    points: points,
                    matching: matching,
                    defaultAnchor: defaultAnchor
                ) {
                pinnedThemeName = next
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func nextTheme(
        inDirection direction: CGVector,
        points: [ProjectedThemePoint3D],
        matching: Set<String>,
        defaultAnchor: CGPoint
    ) -> String? {
        let anchorName = pinnedThemeName ?? hoveredThemeName ?? selectedThemeName
        let anchor = points.first(where: { $0.id == anchorName })?.screenPoint ?? defaultAnchor
        let candidates = points.map {
            ThemePlotInteraction.ScreenCandidate(id: $0.id, screenPoint: $0.screenPoint)
        }
        return ThemePlotInteraction.nextTheme(
            from: anchorName,
            anchorPoint: anchor,
            direction: direction,
            candidates: candidates,
            matching: matching
        )
    }

    // MARK: - Similarity rendering

    private func similarityEmphasis(for points: [ProjectedThemePoint3D]) -> [String: Double] {
        guard
            mode == .similaritySpace3D,
            let pinnedName = pinnedThemeName,
            let pinnedMetrics = metrics[pinnedName] else {
            return [:]
        }
        let distances = points.compactMap { point -> (String, Double)? in
            guard let other = metrics[point.id] else {
                return nil
            }
            return (point.id, themeDistance(pinnedMetrics, other))
        }
        let nonzero = distances.map(\.1).filter {
            $0 > 0
        }
        let sigma = max(ThemeColorMath.quantile(nonzero, 0.20), 1e-12)
        return Dictionary(uniqueKeysWithValues: distances.map { name, distance in
            let emphasis = exp(-(distance * distance) / (2 * sigma * sigma))
            return (name, 0.15 + 0.85 * emphasis)
        })
    }

    private func similarityNeighborIDs(for points: [ProjectedThemePoint3D]) -> Set<String> {
        guard
            mode == .similaritySpace3D,
            let pinnedName = pinnedThemeName,
            let pinnedMetrics = metrics[pinnedName] else {
            return []
        }
        return Set(
            points
                .filter {
                    $0.id != pinnedName
                }
                .compactMap { point -> (String, Double)? in
                    guard let other = metrics[point.id] else {
                        return nil
                    }
                    return (point.id, themeDistance(pinnedMetrics, other))
                }
                .sorted {
                    $0.1 < $1.1
                }
                .prefix(5)
                .map(\.0)
        )
    }

    // MARK: - Hover card and accessibility

    @ViewBuilder
    private func hoverCard(
        points: [ProjectedThemePoint3D],
        matching: Set<String>,
        size: CGSize
    ) -> some View {
        if
            showHoverCard,
            let cardName = hoveredThemeName,
            let theme = themes.first(where: {
                $0.name == cardName
            }),
            let themeMetrics = metrics[cardName],
            let point = points.first(where: {
                $0.id == cardName
            }) {
            let rank = similarityRank(of: cardName, in: points)
            let offset = ThemePlotInteraction.hoverCardOffset(
                around: point.screenPoint,
                in: size,
                hasPreview: previewPage != nil
            )
            ThemeHoverCard(
                theme: theme,
                metrics: themeMetrics,
                catalog: catalog,
                previewPage: previewPage,
                nearbyCount: coLocatedGroup(around: cardName, points: points, matching: matching).count - 1,
                similarityRank: rank
            )
            .offset(x: offset.x, y: offset.y)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func similarityRank(
        of name: String,
        in points: [ProjectedThemePoint3D]
    ) -> (rank: Int, total: Int)? {
        guard
            mode == .similaritySpace3D,
            let pinnedName = pinnedThemeName,
            let pinnedMetrics = metrics[pinnedName] else {
            return nil
        }
        let ordered = points.compactMap { point -> (String, Double)? in
            guard let other = metrics[point.id] else {
                return nil
            }
            return (point.id, themeDistance(pinnedMetrics, other))
        }
        .sorted {
            $0.1 < $1.1
        }
        guard
            let index = ordered.firstIndex(where: {
                $0.0 == name
            }) else {
            return nil
        }
        return (index + 1, ordered.count)
    }

    @ViewBuilder
    private func accessibilityPoints(_ points: [ProjectedThemePoint3D]) -> some View {
        ThemePlotAccessibilityPoints(
            ids: points.map(\.id),
            metrics: metrics,
            catalog: catalog,
            selectedThemeName: selectedThemeName,
            onSelect: selectTheme(named:)
        )
    }
}

private struct ThemeSpace3DCanvas: View {
    let points: [ProjectedThemePoint3D]
    let matching: Set<String>
    let hoveredID: String?
    let pinnedID: String?
    let selectedID: String?
    let mode: ThemePlotMode
    let camera: ThemeCamera
    let horizontalScale: Double
    let emphasis: [String: Double]
    let neighborIDs: Set<String>

    var body: some View {
        Canvas { context, size in
            drawReferenceGeometry(in: context, size: size)
            drawNeighborLines(in: context)
            let ordered = points.sorted {
                $0.depth < $1.depth
            }
            for point in ordered where point.id != hoveredID {
                draw(point, in: context)
            }
            if
                let hovered = points.first(where: {
                    $0.id == hoveredID
                }) {
                draw(hovered, in: context)
            }
        }
    }

    private func draw(_ projected: ProjectedThemePoint3D, in context: GraphicsContext) {
        let depths = points.map(\.depth)
        let minimumDepth = depths.min() ?? 0
        let maximumDepth = depths.max() ?? minimumDepth
        let span = maximumDepth - minimumDepth
        let depthOpacity = span > 1e-12
            ? 0.75 + 0.25 * ((projected.depth - minimumDepth) / span)
            : 1
        let searchOpacity = matching.contains(projected.id) ? 1.0 : 0.25
        let similarityOpacity = emphasis[projected.id] ?? 1.0
        PlotMarkerRenderer.draw(
            projected.point,
            at: projected.screenPoint,
            in: context,
            isHovered: projected.id == hoveredID,
            isSelected: projected.id == selectedID,
            isPinned: projected.id == pinnedID,
            opacity: min(searchOpacity, similarityOpacity) * depthOpacity,
            compact: true
        )
    }

    private func drawNeighborLines(in context: GraphicsContext) {
        guard
            mode == .similaritySpace3D,
            let pinnedID,
            let anchor = points.first(where: {
                $0.id == pinnedID
            }) else {
            return
        }
        for neighbor in points where neighborIDs.contains(neighbor.id) {
            var path = Path()
            path.move(to: anchor.screenPoint)
            path.addLine(to: neighbor.screenPoint)
            context.stroke(path, with: .color(.secondary.opacity(0.15)), lineWidth: 1)
        }
    }

    private func drawReferenceGeometry(in context: GraphicsContext, size: CGSize) {
        switch mode {
        case .colorSpace3D:
            drawColorSpaceReference(in: context, size: size)
        case .paletteSpace3D:
            drawPaletteSpaceReference(in: context, size: size)
        case .fidelitySpace3D:
            drawFidelitySpaceReference(in: context, size: size)
        case .similaritySpace3D:
            drawSimilaritySpaceReference(in: context, size: size)
        default:
            break
        }
    }

    private func drawColorSpaceReference(in context: GraphicsContext, size: CGSize) {
        drawLine(
            from: SIMD3<Double>(0, -1, 0),
            to: SIMD3<Double>(0, 1, 0),
            in: context,
            size: size
        )
        var ring = Path()
        for step in 0...32 {
            let angle = Double(step) / 32 * 2 * .pi
            let point = project(SIMD3(cos(angle), -1, sin(angle)), in: size)
            if step == 0 {
                ring.move(to: point)
            } else {
                ring.addLine(to: point)
            }
        }
        context.stroke(ring, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
        context.draw(
            Text("Light").font(.caption2).foregroundStyle(.secondary),
            at: project(SIMD3(0, 1, 0), in: size)
        )
        context.draw(
            Text("Dark").font(.caption2).foregroundStyle(.secondary),
            at: project(SIMD3(0, -1, 0), in: size)
        )
        context.draw(
            Text("Neutral").font(.caption2).foregroundStyle(.secondary),
            at: project(SIMD3(0, 0, 0), in: size)
        )
        context.draw(
            Text("More Color").font(.caption2).foregroundStyle(.secondary),
            at: project(SIMD3(1, -1, 0), in: size)
        )
    }

    private func drawUnitCubeReference(in context: GraphicsContext, size: CGSize) {
        let corners: [SIMD3<Double>] = [
            SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(-1, 1, -1), SIMD3(1, 1, -1),
            SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(-1, 1, 1), SIMD3(1, 1, 1)
        ]
        let edges = [
            (0, 1), (0, 2), (0, 4), (1, 3), (1, 5), (2, 3),
            (2, 6), (3, 7), (4, 5), (4, 6), (5, 7), (6, 7)
        ]
        for edge in edges {
            drawLine(from: corners[edge.0], to: corners[edge.1], in: context, size: size)
        }
    }

    private func drawPaletteSpaceReference(in context: GraphicsContext, size: CGSize) {
        drawUnitCubeReference(in: context, size: size)
        drawLabel("Similar Colors", at: SIMD3(-1, 0, 0), in: context, size: size)
        drawLabel("Distinct Colors", at: SIMD3(1, 0, 0), in: context, size: size)
        drawLabel("Soft", at: SIMD3(0, -1, 0), in: context, size: size)
        drawLabel("High Visibility", at: SIMD3(0, 1, 0), in: context, size: size)
        drawLabel("Muted", at: SIMD3(0, 0, -1), in: context, size: size)
        drawLabel("Vivid", at: SIMD3(0, 0, 1), in: context, size: size)
    }

    private func drawFidelitySpaceReference(in context: GraphicsContext, size: CGSize) {
        drawUnitCubeReference(in: context, size: size)
        drawLabel("Far from ANSI", at: SIMD3(-1, 0, 0), in: context, size: size)
        drawLabel("Faithful ANSI", at: SIMD3(1, 0, 0), in: context, size: size)
        drawLabel("Dark", at: SIMD3(0, -1, 0), in: context, size: size)
        drawLabel("Light", at: SIMD3(0, 1, 0), in: context, size: size)
        drawLabel("Monochrome", at: SIMD3(0, 0, -1), in: context, size: size)
        drawLabel("Full Spectrum", at: SIMD3(0, 0, 1), in: context, size: size)
    }

    private func drawSimilaritySpaceReference(in context: GraphicsContext, size: CGSize) {
        // These axes are an orientation-stabilized PCA basis. The positive
        // X and Y directions follow warmth and lightness. Z groups the
        // remaining visual traits used for similarity.
        drawLine(
            from: SIMD3<Double>(-1, 0, 0),
            to: SIMD3<Double>(1, 0, 0),
            in: context,
            size: size
        )
        drawLine(
            from: SIMD3<Double>(0, -1, 0),
            to: SIMD3<Double>(0, 1, 0),
            in: context,
            size: size
        )
        drawLine(
            from: SIMD3<Double>(0, 0, -1),
            to: SIMD3<Double>(0, 0, 1),
            in: context,
            size: size
        )
        drawLabel("Warmth", at: SIMD3(1, 0, 0), in: context, size: size)
        drawLabel("Lightness", at: SIMD3(0, 1, 0), in: context, size: size)
        drawLabel("Other Visual Traits", at: SIMD3(0, 0, 1), in: context, size: size)
        context.draw(
            Text("themes nearby look alike").font(.caption2).foregroundStyle(.secondary),
            at: CGPoint(x: size.width / 2, y: size.height - 12)
        )
    }

    private func drawLine(
        from start: SIMD3<Double>,
        to end: SIMD3<Double>,
        in context: GraphicsContext,
        size: CGSize
    ) {
        var path = Path()
        path.move(to: project(start, in: size))
        path.addLine(to: project(end, in: size))
        context.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
    }

    private func drawLabel(
        _ label: String,
        at position: SIMD3<Double>,
        in context: GraphicsContext,
        size: CGSize
    ) {
        context.draw(
            Text(label).font(.caption2).foregroundStyle(.secondary),
            at: project(position, in: size)
        )
    }

    private func project(_ position: SIMD3<Double>, in size: CGSize) -> CGPoint {
        camera.projectedPosition(
            of: position,
            in: size,
            horizontalScale: horizontalScale
        ).point
    }
}

#Preview("3D Theme Space") {
    @Previewable @State var pinnedThemeName: String? = SettingsPreviewData.profile.darkThemeName
    @Previewable @State var cameraByMode: [ThemePlotMode: ThemeCamera] = [:]
    @Previewable @State var previewPage: ThemePreviewPage? = .shell

    ThemeSpace3DView(
        themes: SettingsPreviewData.themes.themes,
        metrics: SettingsPreviewData.themeIndex.metrics,
        catalog: SettingsPreviewData.themeIndex.catalog,
        mode: .fidelitySpace3D,
        query: "",
        selectedThemeName: SettingsPreviewData.profile.darkThemeName,
        pinnedThemeName: $pinnedThemeName,
        cameraByMode: $cameraByMode,
        previewPage: $previewPage,
        onSelect: { _ in },
        onShowSimilar: { _ in }
    )
    .frame(width: 720, height: 480)
    .padding()
}
