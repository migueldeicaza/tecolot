import AppKit

/// Tracks hover independently of AppKit's synchronous button tracking loop.
struct ChromeButtonHoverState: Equatable {
    /// Input from pointer tracking, button tracking, or view availability.
    enum Event {
        case enter
        case exit
        case press
        case release
        case unavailable
    }

    private(set) var hovered = false
    private(set) var pressed = false

    /// Clears both states when the pointer leaves or the button becomes unavailable.
    mutating func send(_ event: Event) {
        switch event {
        case .enter:
            hovered = true
        case .exit:
            hovered = false
            pressed = false
        case .press:
            pressed = true
        case .release:
            pressed = false
        case .unavailable:
            hovered = false
            pressed = false
        }
    }

    var highlighted: Bool {
        hovered || pressed
    }
}

/// A secondary chrome glyph with Rex's circular pointer highlight, preserving native button actions.
final class ChromeIconButton: NSButton {
    override class var cellClass: AnyClass? {
        get { ChromeIconButtonCell.self }
        set {}
    }

    /// Separates compact pane actions from the larger window actions.
    enum Treatment {
        case pane
        case window
        case toolbar
    }

    var treatment = Treatment.pane {
        didSet {
            glyph.symbolConfiguration = Self.symbolConfiguration(for: treatment)
            updateHighlightLayer()
            updateGlyphTint()
            needsDisplay = true
        }
    }
    var highlightDiameter: CGFloat {
        switch treatment {
        case .pane:
            22
        case .window:
            26
        case .toolbar:
            32
        }
    }

    static func symbolConfiguration(for treatment: Treatment) -> NSImage.SymbolConfiguration {
        switch treatment {
        case .pane:
            NSImage.SymbolConfiguration(pointSize: 11.5, weight: .medium, scale: .small)
        case .window:
            NSImage.SymbolConfiguration(pointSize: 13, weight: .medium, scale: .medium)
        case .toolbar:
            NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium, scale: .medium)
        }
    }
    /// A presented panel keeps its opener selected after the pointer leaves.
    var isChromeActive = false {
        didSet {
            updateHighlightLayer()
            updateGlyphTint()
            setAccessibilityValue(isChromeActive ? "Open" : "Closed")
        }
    }
    private(set) var hoverState = ChromeButtonHoverState()
    private var hoverTrackingArea: NSTrackingArea?
    private let hoverLayer = CAShapeLayer()
    private let glyph = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.momentaryPushIn)
        bezelStyle = .smallSquare
        isBordered = false
        wantsLayer = true
        layer?.addSublayer(hoverLayer)
        updateHighlightLayer()
        imagePosition = .imageOnly
        (cell as? NSButtonCell)?.highlightsBy = []
        contentTintColor = .secondaryLabelColor
        glyph.imageAlignment = .alignCenter
        glyph.imageScaling = .scaleNone
        glyph.symbolConfiguration = Self.symbolConfiguration(for: treatment)
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        updateGlyphTint()
    }

    convenience init(treatment: Treatment) {
        self.init(frame: .zero)
        self.treatment = treatment
        glyph.symbolConfiguration = Self.symbolConfiguration(for: treatment)
        updateHighlightLayer()
        updateGlyphTint()
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Centers the decoration without changing the accessible frame or hit target.
    static func highlightRect(in bounds: NSRect, diameter: CGFloat) -> NSRect {
        let side = max(0, min(diameter, bounds.width, bounds.height))
        return NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    /// Matches the measured fill contrast on composited window chrome.
    static func highlightColor(dark: Bool, increasedContrast: Bool, treatment: Treatment = .pane) -> NSColor {
        let alpha: CGFloat = treatment == .pane ? 0.065 : 0.08
        return (dark ? NSColor.white : .black).withAlphaComponent(increasedContrast ? max(0.18, alpha) : alpha)
    }

    override var image: NSImage? {
        get { glyph.image }
        set {
            let template = newValue?.copy() as? NSImage
            template?.isTemplate = true
            glyph.symbolConfiguration = Self.symbolConfiguration(for: treatment)
            glyph.image = template
            super.image = newValue
            needsDisplay = true
        }
    }

    override var contentTintColor: NSColor? {
        didSet {
            updateGlyphTint()
        }
    }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                updateHover(.unavailable)
            }
        }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                updateHover(.unavailable)
            }
            updateGlyphTint()
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateHover(.unavailable)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHover(.unavailable)
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateHover(.unavailable)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        // Layout can move another action under a stationary pointer after zooming or closing a pane.
        synchronizeHoverWithPointer()
    }

    /// Rechecks the pointer after a header moves without a mouse event.
    private func synchronizeHoverWithPointer() {
        if let window, !isHiddenOrHasHiddenAncestor, isEnabled {
            let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            updateHover(bounds.contains(point) && visibleRect.contains(point) ? .enter : .exit)
        } else {
            updateHover(.unavailable)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard event.trackingArea === hoverTrackingArea else {
            return
        }
        if isEnabled, !isHiddenOrHasHiddenAncestor {
            updateHover(.enter)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard event.trackingArea === hoverTrackingArea else {
            return
        }
        updateHover(.exit)
    }

    /// Keeps press feedback visible while AppKit tracks the mouse.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            return
        }
        updateHover(.press)
        defer {
            updateHover(.release)
            synchronizeHoverWithPointer()
        }
        super.mouseDown(with: event)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updateHover(flag ? .press : .release)
    }

    /// Applies tracking and availability changes to both the glyph and highlight.
    func updateHover(_ event: ChromeButtonHoverState.Event) {
        let previous = hoverState
        hoverState.send(event)
        if previous != hoverState {
            updateHighlightLayer()
            updateGlyphTint()
            needsDisplay = true
        }
    }

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    override func layout() {
        super.layout()
        glyph.frame = bounds
        updateHighlightLayer()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHighlightLayer()
        updateGlyphTint()
        needsDisplay = true
    }

    /// A separate layer prevents cached AppKit drawing from retaining a departed hover.
    private func updateHighlightLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        hoverLayer.frame = bounds
        let rect = Self.highlightRect(in: bounds, diameter: highlightDiameter)
        hoverLayer.path = CGPath(ellipseIn: rect, transform: nil)
        hoverLayer.opacity = (hoverState.highlighted || isChromeActive) && isEnabled && !isHiddenOrHasHiddenAncestor ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            hoverLayer.fillColor = Self.highlightColor(dark: dark, increasedContrast: contrast, treatment: treatment).cgColor
            hoverLayer.strokeColor = contrast ? NSColor.secondaryLabelColor.cgColor : nil
            hoverLayer.lineWidth = contrast ? 1 : 0
        }
    }

    /// Gives toolbar/window chrome crisp contrast at rest while keeping pane actions quieter.
    private func updateGlyphTint() {
        let restBlend: CGFloat = treatment == .pane ? 0 : 0.48
        let fraction: CGFloat = isChromeActive ? 1 : hoverState.pressed ? 0.15 : hoverState.hovered ? (treatment == .pane ? 0.55 : 1) : restBlend
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glyph.contentTintColor = (contentTintColor ?? .secondaryLabelColor).blended(withFraction: fraction, of: .labelColor)
        }
        let opacity: CGFloat = treatment == .pane ? (hoverState.hovered && !hoverState.pressed ? 0.95 : 0.78) : 1
        glyph.alphaValue = opacity * (isEnabled ? 1 : 0.5)
    }

    /// The glyph is decorative; the existing button remains the pointer target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override var focusRingMaskBounds: NSRect {
        bounds
    }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: Self.highlightRect(in: bounds, diameter: highlightDiameter)).fill()
    }
}

/// Keeps AppKit from installing a native bezel layer behind the custom pointer treatment.
private final class ChromeIconButtonCell: NSButtonCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {}
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {}
    override func drawInterior(withFrame frame: NSRect, in controlView: NSView) {}
}
