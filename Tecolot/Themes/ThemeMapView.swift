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
    static let hitRadius: CGFloat = 12
    static let coLocatedRadius: CGFloat = 5

    static func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: 20, y: 22, width: max(size.width - 40, 1), height: max(size.height - 44, 1))
    }

    static func viewPoint(for position: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + position.x * rect.width,
            y: rect.minY + position.y * rect.height
        )
    }
}

/// The common map marker. Both Canvas renderers use this glyph so marker
/// color and selection meaning stay identical in 2D and 3D.
enum PlotMarkerRenderer {
    static func draw(
        _ point: some ThemeMarkerPoint,
        at center: CGPoint,
        in context: GraphicsContext,
        isHovered: Bool,
        isSelected: Bool,
        isPinned: Bool,
        opacity: Double,
        hollow: Bool = false
    ) {
        let radius = isHovered ? PlotGeometry.hoveredMarkerRadius : PlotGeometry.markerRadius
        var layer = context
        layer.opacity = opacity

        if isSelected || isPinned {
            let halo = Path(ellipseIn: CGRect(
                x: center.x - radius - 3.5, y: center.y - radius - 3.5,
                width: (radius + 3.5) * 2, height: (radius + 3.5) * 2
            ))
            layer.stroke(halo, with: .color(.accentColor), lineWidth: isSelected ? 2.5 : 1.5)
        }

        let body = Path(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
        ))
        if !hollow {
            layer.fill(body, with: .color(point.background.swiftUIColor))
        }
        layer.stroke(body, with: .color(point.foreground.swiftUIColor), lineWidth: 1.5)

        let dotRadius: CGFloat = 1.5
        let dot = Path(ellipseIn: CGRect(
            x: center.x - dotRadius, y: center.y - dotRadius,
            width: dotRadius * 2, height: dotRadius * 2
        ))
        layer.fill(dot, with: .color(point.accent.swiftUIColor))
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
    let onSelect: (TerminalTheme) -> Void
    /// Invoked from a marker's context menu; the owner switches the plot
    /// to the similarity map and pins the theme
    var onShowSimilar: ((String) -> Void)? = nil

    @State private var hoveredThemeName: String?
    @State private var showHoverCard = false
    @State private var hoverDebounce: Task<Void, Never>?
    @State private var fromPositions: [String: CGPoint] = [:]
    @State private var animationProgress: Double = 1

    var body: some View {
        GeometryReader { geometry in
            let points = projectedPoints(for: mode)
            let matching = matchingNames
            let rect = PlotGeometry.plotRect(in: geometry.size)
            ZStack(alignment: .topLeading) {
                PlotCanvas(
                    progress: animationProgress,
                    from: fromPositions,
                    points: points,
                    matching: matching,
                    hoveredID: hoveredThemeName,
                    pinnedID: pinnedThemeName,
                    selectedID: selectedThemeName,
                    mode: mode
                )
                hoverCard(points: points, matching: matching, in: rect, size: geometry.size)
            }
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
            .focusable()
            .focusEffectDisabled()
            .onKeyPress { press in
                handleKey(press, points: points, matching: matching, in: rect)
            }
            .contextMenu {
                if let onShowSimilar,
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
        .onChange(of: mode) { oldMode, _ in
            fromPositions = Dictionary(
                uniqueKeysWithValues: projectedPoints(for: oldMode).map { ($0.id, $0.position) }
            )
            clearHover()
            animationProgress = 0
            withAnimation(.snappy) {
                animationProgress = 1
            }
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    // MARK: - Projection

    private func projectedPoints(for mode: ThemePlotMode) -> [ThemePlotPoint] {
        guard let catalog else { return [] }
        return ThemeProjection.project(
            themes: themes, metrics: metrics, catalog: catalog, mode: mode
        )
    }

    private var matchingNames: Set<String> {
        Set(themes.map(\.name).filter { ThemeBrowserSections.matches($0, query: query) })
    }

    // MARK: - Hover

    private func updateHover(
        at location: CGPoint, points: [ThemePlotPoint], matching: Set<String>, in rect: CGRect
    ) {
        let name = nearestTheme(to: location, points: points, matching: matching, in: rect)
        guard name != hoveredThemeName else { return }
        hoveredThemeName = name
        showHoverCard = false
        hoverDebounce?.cancel()
        guard name != nil else { return }
        hoverDebounce = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
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
            let viewPoint = PlotGeometry.viewPoint(for: point.position, in: rect)
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
        guard let anchor = points.first(where: { $0.id == name }) else { return [name] }
        let anchorPoint = PlotGeometry.viewPoint(for: anchor.position, in: rect)
        return points.filter { point in
            guard matching.contains(point.id) else { return false }
            let viewPoint = PlotGeometry.viewPoint(for: point.position, in: rect)
            return hypot(anchorPoint.x - viewPoint.x, anchorPoint.y - viewPoint.y)
                <= PlotGeometry.coLocatedRadius
        }
        .map(\.id)
    }

    // MARK: - Selection and keyboard

    private func selectTheme(named name: String) {
        guard let theme = themes.first(where: { $0.name == name }) else { return }
        onSelect(theme)
    }

    private func handleKey(
        _ press: KeyPress, points: [ThemePlotPoint], matching: Set<String>, in rect: CGRect
    ) -> KeyPress.Result {
        switch press.key {
        case .return:
            guard let name = pinnedThemeName ?? hoveredThemeName else { return .ignored }
            selectTheme(named: name)
            return .handled
        case .escape:
            // With no pin, Escape falls through (and closes the popover)
            guard pinnedThemeName != nil else { return .ignored }
            pinnedThemeName = nil
            return .handled
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            // While hovering a co-located pile, ↑/↓ cycles through it
            if let hovered = hoveredThemeName,
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
            let direction: CGVector
            switch press.key {
            case .upArrow: direction = CGVector(dx: 0, dy: -1)
            case .downArrow: direction = CGVector(dx: 0, dy: 1)
            case .leftArrow: direction = CGVector(dx: -1, dy: 0)
            default: direction = CGVector(dx: 1, dy: 0)
            }
            if let next = nextTheme(
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
            anchorPosition = PlotGeometry.viewPoint(for: anchor.position, in: rect)
        } else {
            anchorPosition = CGPoint(x: rect.midX, y: rect.midY)
        }
        var best: (name: String, score: CGFloat)?
        for point in points where matching.contains(point.id) && point.id != anchorName {
            let viewPoint = PlotGeometry.viewPoint(for: point.position, in: rect)
            let dx = viewPoint.x - anchorPosition.x
            let dy = viewPoint.y - anchorPosition.y
            let along = dx * direction.dx + dy * direction.dy
            guard along > 0 else { continue }
            let distance = hypot(dx, dy)
            guard distance > 0 else { continue }
            let anglePenalty = 1 - along / distance  // 0 straight ahead, 1 perpendicular
            let score = distance * (1 + 3 * anglePenalty)
            if score < (best?.score ?? .infinity) {
                best = (point.id, score)
            }
        }
        return best?.name
    }

    // MARK: - Hover card

    @ViewBuilder
    private func hoverCard(
        points: [ThemePlotPoint], matching: Set<String>, in rect: CGRect, size: CGSize
    ) -> some View {
        // The card is strictly hover-driven; leaving the point dismisses it
        if showHoverCard,
           let cardName = hoveredThemeName,
           let theme = themes.first(where: { $0.name == cardName }),
           let themeMetrics = metrics[cardName],
           let point = points.first(where: { $0.id == cardName }) {
            let anchor = PlotGeometry.viewPoint(for: point.position, in: rect)
            let cardSize = CGSize(width: 244, height: 200)
            let x = min(max(anchor.x + 16, 4), max(size.width - cardSize.width - 4, 4))
            let above = anchor.y > size.height * 0.55
            let y = above
                ? max(anchor.y - cardSize.height - 14, 4)
                : min(anchor.y + 14, max(size.height - cardSize.height - 4, 4))
            ThemeHoverCard(
                theme: theme,
                metrics: themeMetrics,
                catalog: catalog,
                nearbyCount: coLocatedGroup(
                    around: cardName, points: points, matching: matching, in: rect
                ).count - 1
            )
            .offset(x: x, y: y)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: - Accessibility

    @ViewBuilder
    private func accessibilityPoints(_ points: [ThemePlotPoint]) -> some View {
        ForEach(points) { point in
            if let themeMetrics = metrics[point.id] {
                Color.clear
                    .accessibilityLabel(ThemeMapView.accessibilityLabel(
                        name: point.id, metrics: themeMetrics, catalog: catalog
                    ))
                    .accessibilityAddTraits(
                        point.id == selectedThemeName ? [.isButton, .isSelected] : .isButton
                    )
                    .accessibilityAction {
                        selectTheme(named: point.id)
                    }
            }
        }
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

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let rect = PlotGeometry.plotRect(in: size)
            drawAxisLabels(in: context, size: size)
            // Hovered marker draws last, on top of the pile
            for point in points where point.id != hoveredID {
                draw(point, in: context, rect: rect)
            }
            if let hovered = points.first(where: { $0.id == hoveredID }) {
                draw(hovered, in: context, rect: rect)
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
        return PlotGeometry.viewPoint(for: unit, in: rect)
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
            hollow: hollow
        )
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
    @Previewable @State var pinnedThemeName: String? = SettingsPreviewData.profile.themeName

    ThemeMapView(
        themes: SettingsPreviewData.themes.themes,
        metrics: SettingsPreviewData.themeIndex.metrics,
        catalog: SettingsPreviewData.themeIndex.catalog,
        mode: .brightnessAndColorfulness,
        query: "",
        selectedThemeName: SettingsPreviewData.profile.themeName,
        pinnedThemeName: $pinnedThemeName,
        onSelect: { _ in },
        onShowSimilar: { _ in }
    )
    .frame(width: 720, height: 480)
    .padding()
}
