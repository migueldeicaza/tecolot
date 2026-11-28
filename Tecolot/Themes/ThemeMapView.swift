//
//  ThemeMapView.swift
//  Tecolot
//
//  The 2D theme browser: one Canvas draws every theme as a marker (body =
//  background, ring = foreground, dot = dominant accent) at its projected
//  position. Hover previews, click selects, arrow keys navigate spatially,
//  Return applies, Escape clears the pin. Position is meaning: search dims
//  non-matching markers instead of moving anything.
//
import SwiftUI

/// Geometry shared by interaction (hit testing, hover card, keyboard) and
/// drawing (PlotCanvas); a single definition keeps them aligned.
enum PlotGeometry {
    static let markerRadius: CGFloat = 5
    static let hoveredMarkerRadius: CGFloat = 7
    static let capsuleSize = CGSize(width: 22, height: 11)
    static let hoveredCapsuleSize = CGSize(width: 28, height: 14)
    static let compactCapsuleSize = CGSize(width: 19, height: 9.5)
    static let hitRadius: CGFloat = 14
    static let coLocatedRadius: CGFloat = 7
    /// Container width threshold at which the docked live inspector sits
    /// beside the plot instead of floating a hover card over neighbors.
    static let dockedInspectorThreshold: CGFloat = 660

    static func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: 22, y: 22, width: max(size.width - 44, 1), height: max(size.height - 44, 1))
    }

    static func clampedPan(_ pan: CGSize, zoom: CGFloat, in rect: CGRect) -> CGSize {
        let maxX = rect.width * max(zoom - 1, 0) / 2
        let maxY = rect.height * max(zoom - 1, 0) / 2
        return CGSize(
            width: min(max(pan.width, -maxX), maxX),
            height: min(max(pan.height, -maxY), maxY)
        )
    }

    static func viewPoint(
        for position: CGPoint,
        in rect: CGRect,
        zoom: CGFloat = 1,
        pan: CGSize = .zero
    ) -> CGPoint {
        let baseX = rect.minX + position.x * rect.width
        let baseY = rect.minY + position.y * rect.height
        guard zoom != 1 || pan != .zero else {
            return CGPoint(x: baseX, y: baseY)
        }
        let clamped = clampedPan(pan, zoom: zoom, in: rect)
        return CGPoint(
            x: rect.midX + (baseX - rect.midX) * zoom + clamped.width,
            y: rect.midY + (baseY - rect.midY) * zoom + clamped.height
        )
    }
}

/// The common map marker. Both Canvas renderers use this Palette Capsule glyph
/// so every point communicates background, foreground contrast, and all six
/// chromatic ANSI slots (R, G, Y, B, M, C) in canonical order.
enum PlotMarkerRenderer {
    static func draw(
        _ point: some ThemeMarkerPoint,
        at center: CGPoint,
        in context: GraphicsContext,
        isHovered: Bool,
        isSelected: Bool,
        isPinned: Bool,
        opacity: Double,
        hollow: Bool = false,
        compact: Bool = false,
        showBrightRow: Bool = false
    ) {
        let baseSize: CGSize
        if isHovered {
            baseSize = showBrightRow
                ? CGSize(width: 30, height: 16)
                : PlotGeometry.hoveredCapsuleSize
        } else if showBrightRow {
            baseSize = CGSize(width: 26, height: 14)
        } else {
            baseSize = compact ? PlotGeometry.compactCapsuleSize : PlotGeometry.capsuleSize
        }

        let rect = CGRect(
            x: center.x - baseSize.width / 2,
            y: center.y - baseSize.height / 2,
            width: baseSize.width,
            height: baseSize.height
        )
        let cornerRadius = min(baseSize.height * 0.34, 4.5)
        var layer = context
        layer.opacity = opacity

        if isSelected || isPinned {
            let haloRect = rect.insetBy(dx: -2.5, dy: -2.5)
            let halo = Path(roundedRect: haloRect, cornerRadius: cornerRadius + 2)
            layer.stroke(halo, with: .color(.accentColor), lineWidth: isSelected ? 2.2 : 1.4)
        }

        let body = Path(roundedRect: rect, cornerRadius: cornerRadius)
        if hollow {
            // Hollow markers (system-default selection on Interaction plot) draw
            // only a distinct dashed outline so they read immediately as synthetic.
            layer.stroke(
                body,
                with: .color(point.foreground.swiftUIColor.opacity(isHovered ? 0.95 : 0.78)),
                style: StrokeStyle(lineWidth: isHovered ? 1.5 : 1.15, dash: [3, 2])
            )
            return
        }

        layer.fill(body, with: .color(point.background.swiftUIColor))
        layer.stroke(
            body,
            with: .color(point.foreground.swiftUIColor.opacity(isHovered ? 0.95 : 0.65)),
            lineWidth: isHovered ? 1.4 : 1.0
        )

        // Left zone: two mini horizontal foreground text bars showing real contrast on bg
        let inner = rect.insetBy(dx: 2.2, dy: 2.0)
        let fgWidth = max(inner.width * 0.24, 3.2)
        let barHeight = max(inner.height * 0.24, 1.3)
        let fgColor = point.foreground.swiftUIColor
        let topBar = CGRect(
            x: inner.minX,
            y: inner.minY + inner.height * 0.16,
            width: fgWidth,
            height: barHeight
        )
        let bottomBar = CGRect(
            x: inner.minX,
            y: inner.minY + inner.height * 0.60,
            width: fgWidth * 0.72,
            height: barHeight
        )
        layer.fill(Path(roundedRect: topBar, cornerRadius: 0.6), with: .color(fgColor))
        layer.fill(Path(roundedRect: bottomBar, cornerRadius: 0.6), with: .color(fgColor.opacity(0.75)))

        // Right zone: 6 canonical chromatic ANSI stripes (R, G, Y, B, M, C)
        let palette = point.chromaticPalette
        guard !palette.isEmpty else {
            return
        }
        let stripeStart = inner.minX + fgWidth + 1.6
        let stripeAreaWidth = max(inner.maxX - stripeStart, 6)
        let stripeWidth = stripeAreaWidth / CGFloat(palette.count)
        let brightPalette = point.brightChromaticPalette

        if showBrightRow, brightPalette.count == palette.count {
            let rowGap: CGFloat = 1.0
            let rowHeight = max((inner.height - rowGap) / 2, 1.5)
            for (index, color) in palette.enumerated() {
                let x = stripeStart + CGFloat(index) * stripeWidth
                let topStripe = CGRect(
                    x: x, y: inner.minY,
                    width: max(stripeWidth - 0.35, 1), height: rowHeight
                )
                let bottomStripe = CGRect(
                    x: x, y: inner.minY + rowHeight + rowGap,
                    width: max(stripeWidth - 0.35, 1), height: rowHeight
                )
                layer.fill(Path(topStripe), with: .color(color.swiftUIColor))
                layer.fill(Path(bottomStripe), with: .color(brightPalette[index].swiftUIColor))
            }
        } else {
            for (index, color) in palette.enumerated() {
                let x = stripeStart + CGFloat(index) * stripeWidth
                let stripe = CGRect(
                    x: x, y: inner.minY,
                    width: max(stripeWidth - 0.35, 1), height: inner.height
                )
                layer.fill(Path(stripe), with: .color(color.swiftUIColor))
            }
        }
    }
}

struct ThemeMapView: View {
    let themes: [TerminalTheme]
    let metrics: [String: ThemeMetrics]
    let catalog: CatalogStatistics?
    let mode: ThemePlotMode
    let query: String
    let selectedThemeName: String
    @Binding var pinnedThemeName: String?
    @Binding var previewPage: ThemePreviewPage?
    let onSelect: (TerminalTheme) -> Void
    /// Invoked from a marker's context menu; the owner switches the plot
    /// to the similarity map and pins the theme
    var onShowSimilar: ((String) -> Void)? = nil

    @State private var hoveredThemeName: String?
    @State private var showHoverCard = false
    @State private var hoverDebounce: Task<Void, Never>?
    @State private var fromPositions: [String: CGPoint] = [:]
    @State private var animationProgress: Double = 1
    @State private var zoom: CGFloat = 1
    @State private var magnificationStartZoom: CGFloat?
    @State private var magnificationStartPan: CGSize?
    @State private var pan: CGSize = .zero
    @State private var dragStartPan: CGSize?

    var body: some View {
        GeometryReader { outer in
            let showsDockedInspector = outer.size.width >= PlotGeometry.dockedInspectorThreshold
            let plotSize = CGSize(
                width: showsDockedInspector ? max(outer.size.width - 263, 1) : outer.size.width,
                height: outer.size.height
            )
            let rect = PlotGeometry.plotRect(in: plotSize)
            let points = projectedPoints(for: mode)
            let matching = matchingNames
            let effectivePan = PlotGeometry.clampedPan(pan, zoom: zoom, in: rect)

            HStack(spacing: 0) {
                plotArea(
                    size: plotSize,
                    rect: rect,
                    points: points,
                    matching: matching,
                    effectivePan: effectivePan,
                    showsDockedInspector: showsDockedInspector
                )
                if showsDockedInspector {
                    Divider()
                    dockedInspector(
                        points: points,
                        matching: matching,
                        in: rect
                    )
                }
            }
        }
        .onChange(of: mode) { oldMode, _ in
            fromPositions = Dictionary(
                uniqueKeysWithValues: projectedPoints(for: oldMode).map {
                    ($0.id, $0.position)
                }
            )
            clearHover()
            zoom = 1
            pan = .zero
            animationProgress = 0
            withAnimation(.snappy) {
                animationProgress = 1
            }
        }
        .frame(minWidth: 420, minHeight: 240)
    }

    private func plotArea(
        size: CGSize,
        rect: CGRect,
        points: [ThemePlotPoint],
        matching: Set<String>,
        effectivePan: CGSize,
        showsDockedInspector: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            PlotCanvas(
                progress: animationProgress,
                from: fromPositions,
                points: points,
                matching: matching,
                hoveredID: hoveredThemeName,
                pinnedID: pinnedThemeName,
                selectedID: selectedThemeName,
                mode: mode,
                zoom: zoom,
                pan: effectivePan
            )
            if !showsDockedInspector {
                hoverCard(points: points, matching: matching, in: rect, size: size)
            }
            if zoom > 1.02 {
                Button("Reset Zoom") {
                    resetView()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .padding(8)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                updateHover(at: location, points: points, matching: matching, in: rect)
            case .ended:
                clearHover()
            }
        }
        .gesture(
            SpatialTapGesture().onEnded { value in
                if let name = nearestTheme(
                    to: value.location, points: points, matching: matching, in: rect
                ) {
                    pinnedThemeName = name
                    selectTheme(named: name)
                }
            }
        )
        .simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { value in
                if nearestTheme(to: value.location, points: points, matching: matching, in: rect) == nil {
                    resetView()
                }
            }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let startZoom = magnificationStartZoom ?? zoom
                    let startPan = magnificationStartPan ?? PlotGeometry.clampedPan(pan, zoom: startZoom, in: rect)
                    magnificationStartZoom = startZoom
                    magnificationStartPan = startPan
                    let newZoom = min(max(startZoom * value.magnification, 1.0), 3.5)
                    let scaleRatio = newZoom / max(startZoom, 1.0)
                    zoom = newZoom
                    pan = PlotGeometry.clampedPan(
                        CGSize(width: startPan.width * scaleRatio, height: startPan.height * scaleRatio),
                        zoom: newZoom,
                        in: rect
                    )
                }
                .onEnded { _ in
                    magnificationStartZoom = nil
                    magnificationStartPan = nil
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard zoom > 1.01 else {
                        return
                    }
                    let start = dragStartPan ?? PlotGeometry.clampedPan(pan, zoom: zoom, in: rect)
                    dragStartPan = start
                    pan = PlotGeometry.clampedPan(
                        CGSize(
                            width: start.width + value.translation.width,
                            height: start.height + value.translation.height
                        ),
                        zoom: zoom,
                        in: rect
                    )
                }
                .onEnded { _ in
                    dragStartPan = nil
                }
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in
            handleKey(press, points: points, matching: matching, in: rect)
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
            accessibilityPoints(points)
        }
    }

    @ViewBuilder
    private func dockedInspector(
        points: [ThemePlotPoint],
        matching: Set<String>,
        in rect: CGRect
    ) -> some View {
        let nearby = hoveredThemeName.map {
            coLocatedGroup(around: $0, points: points, matching: matching, in: rect).count - 1
        } ?? 0
        ThemePlotDockedInspector(
            themes: themes,
            metrics: metrics,
            catalog: catalog,
            hoveredThemeName: hoveredThemeName,
            pinnedThemeName: pinnedThemeName,
            selectedThemeName: selectedThemeName,
            previewPage: $previewPage,
            nearbyCount: nearby
        )
    }

    private func resetView() {
        withAnimation(.snappy) {
            zoom = 1
            pan = .zero
        }
    }

    // MARK: - Projection

    private func projectedPoints(for mode: ThemePlotMode) -> [ThemePlotPoint] {
        guard let catalog else {
            return []
        }
        return ThemeProjection.project(
            themes: themes, metrics: metrics, catalog: catalog, mode: mode
        )
    }

    private var matchingNames: Set<String> {
        Set(themes.map(\.name).filter {
            ThemeBrowserSections.matches($0, query: query)
        })
    }

    // MARK: - Hover

    private func updateHover(
        at location: CGPoint, points: [ThemePlotPoint], matching: Set<String>, in rect: CGRect
    ) {
        let name = nearestTheme(to: location, points: points, matching: matching, in: rect)
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

    /// Nearest matching theme within the hit radius; non-matching markers
    /// are excluded from hit testing while a query is active
    private func nearestTheme(
        to location: CGPoint, points: [ThemePlotPoint], matching: Set<String>, in rect: CGRect
    ) -> String? {
        var best: (name: String, distance: CGFloat)?
        for point in points where matching.contains(point.id) {
            let viewPoint = PlotGeometry.viewPoint(for: point.position, in: rect, zoom: zoom, pan: pan)
            let distance = hypot(location.x - viewPoint.x, location.y - viewPoint.y)
            if distance <= PlotGeometry.hitRadius, distance < (best?.distance ?? .infinity) {
                best = (point.id, distance)
            }
        }
        return best?.name
    }

    /// Themes essentially co-located with `name`, including itself, in a
    /// stable order for cycling
    private func coLocatedGroup(
        around name: String, points: [ThemePlotPoint], matching: Set<String>, in rect: CGRect
    ) -> [String] {
        guard
            let anchor = points.first(where: {
                $0.id == name
            }) else {
            return [name]
        }
        let anchorPoint = PlotGeometry.viewPoint(for: anchor.position, in: rect, zoom: zoom, pan: pan)
        return points.filter { point in
            guard matching.contains(point.id) else {
                return false
            }
            let viewPoint = PlotGeometry.viewPoint(for: point.position, in: rect, zoom: zoom, pan: pan)
            return hypot(anchorPoint.x - viewPoint.x, anchorPoint.y - viewPoint.y)
                <= PlotGeometry.coLocatedRadius
        }
        .map(\.id)
    }

    // MARK: - Selection and keyboard

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
        _ press: KeyPress, points: [ThemePlotPoint], matching: Set<String>, in rect: CGRect
    ) -> KeyPress.Result {
        if let mappedPreview = ThemePreviewPage.fromShortcutCharacter(press.characters) {
            previewPage = mappedPreview
            return .handled
        }
        if press.characters == "+" || press.characters == "=" {
            let oldZoom = zoom
            let newZoom = min(zoom * 1.25, 3.5)
            let ratio = newZoom / max(oldZoom, 1.0)
            zoom = newZoom
            pan = PlotGeometry.clampedPan(
                CGSize(width: pan.width * ratio, height: pan.height * ratio),
                zoom: newZoom,
                in: rect
            )
            return .handled
        }
        if press.characters == "-" {
            let oldZoom = zoom
            let newZoom = max(zoom / 1.25, 1.0)
            let ratio = newZoom / max(oldZoom, 1.0)
            zoom = newZoom
            pan = PlotGeometry.clampedPan(
                CGSize(width: pan.width * ratio, height: pan.height * ratio),
                zoom: newZoom,
                in: rect
            )
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
            // With no pin, Escape falls through (and closes the popover)
            guard pinnedThemeName != nil else {
                return .ignored
            }
            pinnedThemeName = nil
            return .handled
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            // While hovering a co-located pile, ↑/↓ cycles through it
            if
                let hovered = hoveredThemeName,
                press.key == .upArrow || press.key == .downArrow {
                let group = coLocatedGroup(
                    around: hovered, points: points, matching: matching, in: rect
                )
                if group.count > 1, let index = group.firstIndex(of: hovered) {
                    let step = press.key == .downArrow ? 1 : group.count - 1
                    hoveredThemeName = group[(index + step) % group.count]
                    return .handled
                }
            }
            if
                let direction = ThemePlotInteraction.directionVector(for: press.key),
                let next = nextTheme(
                    inDirection: direction, points: points, matching: matching, in: rect
                ) {
                pinnedThemeName = next
            }
            return .handled
        default:
            return .ignored
        }
    }

    /// Nearest theme in an arrow direction, penalized by angular deviation
    /// (spec §45) so navigation feels spatial
    private func nextTheme(
        inDirection direction: CGVector, points: [ThemePlotPoint],
        matching: Set<String>, in rect: CGRect
    ) -> String? {
        let anchorName = pinnedThemeName ?? hoveredThemeName ?? selectedThemeName
        let anchorPosition: CGPoint
        if let anchor = points.first(where: { $0.id == anchorName }) {
            anchorPosition = PlotGeometry.viewPoint(for: anchor.position, in: rect, zoom: zoom, pan: pan)
        } else {
            anchorPosition = CGPoint(x: rect.midX, y: rect.midY)
        }
        let candidates = points.map {
            ThemePlotInteraction.ScreenCandidate(
                id: $0.id,
                screenPoint: PlotGeometry.viewPoint(for: $0.position, in: rect, zoom: zoom, pan: pan)
            )
        }
        return ThemePlotInteraction.nextTheme(
            from: anchorName,
            anchorPoint: anchorPosition,
            direction: direction,
            candidates: candidates,
            matching: matching
        )
    }

    // MARK: - Hover card

    @ViewBuilder
    private func hoverCard(
        points: [ThemePlotPoint], matching: Set<String>, in rect: CGRect, size: CGSize
    ) -> some View {
        // The card is strictly hover-driven; leaving the point dismisses it
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
            let anchor = PlotGeometry.viewPoint(for: point.position, in: rect, zoom: zoom, pan: pan)
            let offset = ThemePlotInteraction.hoverCardOffset(
                around: anchor, in: size, hasPreview: previewPage != nil
            )
            ThemeHoverCard(
                theme: theme,
                metrics: themeMetrics,
                catalog: catalog,
                previewPage: previewPage,
                nearbyCount: coLocatedGroup(
                    around: cardName, points: points, matching: matching, in: rect
                ).count - 1
            )
            .offset(x: offset.x, y: offset.y)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: - Accessibility

    @ViewBuilder
    private func accessibilityPoints(_ points: [ThemePlotPoint]) -> some View {
        ThemePlotAccessibilityPoints(
            ids: points.map(\.id),
            metrics: metrics,
            catalog: catalog,
            selectedThemeName: selectedThemeName,
            onSelect: selectTheme(named:)
        )
    }

    /// "Dracula, dark, cool, strong contrast, colorful" — descriptive bucket
    /// words, never metric numbers (spec §44)
    static func accessibilityLabel(
        name: String, metrics: ThemeMetrics, catalog: CatalogStatistics?
    ) -> String {
        var parts = [
            name,
            metrics.backgroundLightnessBucket.lowercased(),
            metrics.temperatureBucket,
            metrics.contrastBucket
        ]
        if let catalog {
            parts.append(catalog.colorfulnessBucket(for: metrics.ansiColorfulness).lowercased())
        }
        return parts.joined(separator: ", ")
    }
}

/// Draws the plot; Animatable so mode changes glide markers between their
/// old and new projected positions
private struct PlotCanvas: View, Animatable {
    var progress: Double
    let from: [String: CGPoint]
    let points: [ThemePlotPoint]
    let matching: Set<String>
    let hoveredID: String?
    let pinnedID: String?
    let selectedID: String?
    let mode: ThemePlotMode
    let zoom: CGFloat
    let pan: CGSize

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let rect = PlotGeometry.plotRect(in: size)
            drawAxisLabels(in: context, size: size)

            // Clip markers and quadrant guides inside the label margin so
            // zoomed/panned markers never paint over axis labels.
            let clipRect = CGRect(
                x: 16, y: 16,
                width: max(size.width - 32, 1),
                height: max(size.height - 32, 1)
            )
            var clipped = context
            clipped.clip(to: Path(clipRect))

            if mode == .ansiFidelity {
                drawFidelityQuadrants(in: clipped, rect: rect)
            }
            // Hovered marker draws last, on top of the pile
            for point in points where point.id != hoveredID {
                draw(point, in: clipped, rect: rect)
            }
            if
                let hovered = points.first(where: {
                    $0.id == hoveredID
                }) {
                draw(hovered, in: clipped, rect: rect)
            }
        }
    }

    private func position(of point: ThemePlotPoint, in rect: CGRect) -> CGPoint {
        var unit = point.position
        if progress < 1, let source = from[point.id] {
            unit = CGPoint(
                x: source.x + (unit.x - source.x) * progress,
                y: source.y + (unit.y - source.y) * progress
            )
        }
        return PlotGeometry.viewPoint(for: unit, in: rect, zoom: zoom, pan: pan)
    }

    private func draw(_ point: ThemePlotPoint, in context: GraphicsContext, rect: CGRect) {
        let center = position(of: point, in: rect)
        let isHovered = point.id == hoveredID
        let dimmed = !matching.contains(point.id)
        // The Interaction Colors plot shows themes on the system selection
        // color as hollow markers: the synthetic position is not real data
        let hollow = mode == .interactionColors && !point.hasCustomSelection
        PlotMarkerRenderer.draw(
            point,
            at: center,
            in: context,
            isHovered: isHovered,
            isSelected: point.id == selectedID,
            isPinned: point.id == pinnedID,
            opacity: dimmed ? 0.25 : 1,
            hollow: hollow,
            showBrightRow: zoom >= 1.9
        )
    }

    private func drawFidelityQuadrants(in context: GraphicsContext, rect: CGRect) {
        let splitUnit = CGPoint(
            x: ThemeAnalyzer.fidelityArchetypeThreshold,
            y: 1 - ThemeAnalyzer.vitalityArchetypeThreshold
        )
        let splitPoint = PlotGeometry.viewPoint(for: splitUnit, in: rect, zoom: zoom, pan: pan)
        let splitX = splitPoint.x
        let splitY = splitPoint.y

        var guides = Path()
        if splitX > rect.minX && splitX < rect.maxX {
            guides.move(to: CGPoint(x: splitX, y: rect.minY))
            guides.addLine(to: CGPoint(x: splitX, y: rect.maxY))
        }
        if splitY > rect.minY && splitY < rect.maxY {
            guides.move(to: CGPoint(x: rect.minX, y: splitY))
            guides.addLine(to: CGPoint(x: rect.maxX, y: splitY))
        }
        context.stroke(
            guides,
            with: .color(.secondary.opacity(0.18)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
        )

        func watermark(_ label: String, at point: CGPoint, anchor: UnitPoint) {
            context.draw(
                Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary.opacity(0.45)),
                at: point,
                anchor: anchor
            )
        }
        watermark("Stylized & Remapped", at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), anchor: .topLeading)
        watermark("Classic & Faithful", at: CGPoint(x: rect.maxX - 6, y: rect.minY + 4), anchor: .topTrailing)
        watermark("Monochrome & Tinted", at: CGPoint(x: rect.minX + 6, y: rect.maxY - 4), anchor: .bottomLeading)
        watermark("Soft & Muted", at: CGPoint(x: rect.maxX - 6, y: rect.maxY - 4), anchor: .bottomTrailing)
    }

    private func drawAxisLabels(in context: GraphicsContext, size: CGSize) {
        let labels = mode.axisLabels
        func text(_ string: String) -> Text {
            Text(string).font(.caption2).foregroundStyle(.secondary)
        }
        if let top = labels.top {
            context.draw(text(top), at: CGPoint(x: size.width / 2, y: 10))
        }
        if let bottom = labels.bottom {
            context.draw(text(bottom), at: CGPoint(x: size.width / 2, y: size.height - 10))
        }
        if let left = labels.left {
            var rotated = context
            rotated.translateBy(x: 10, y: size.height / 2)
            rotated.rotate(by: .degrees(-90))
            rotated.draw(text(left), at: .zero)
        }
        if let right = labels.right {
            var rotated = context
            rotated.translateBy(x: size.width - 10, y: size.height / 2)
            rotated.rotate(by: .degrees(90))
            rotated.draw(text(right), at: .zero)
        }
    }
}


#Preview("Theme Map") {
    @Previewable @State var pinnedThemeName: String? = SettingsPreviewData.profile.darkThemeName
    @Previewable @State var previewPage: ThemePreviewPage? = .shell

    ThemeMapView(
        themes: SettingsPreviewData.themes.themes,
        metrics: SettingsPreviewData.themeIndex.metrics,
        catalog: SettingsPreviewData.themeIndex.catalog,
        mode: .ansiFidelity,
        query: "",
        selectedThemeName: SettingsPreviewData.profile.darkThemeName,
        pinnedThemeName: $pinnedThemeName,
        previewPage: $previewPage,
        onSelect: { _ in },
        onShowSimilar: { _ in }
    )
    .frame(width: 720, height: 480)
    .padding()
}
