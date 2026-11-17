import AppKit
import QuartzCore

/// The single selection capsule belongs to the strip, never to a tab cell.
final class TabSelectionSurfaceView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        setAccessibilityElement(false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func apply(chrome: TabStripChrome, key: Bool) {
        layer?.backgroundColor = chrome.selection.cgColor
        layer?.borderColor = chrome.hairline.cgColor
        layer?.borderWidth = key ? 0.5 : 0
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = key ? 0.2 : 0
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    func move(to rect: NSRect, animated: Bool) {
        let oldPosition = layer?.presentation()?.position ?? layer?.position
        let oldBounds = layer?.presentation()?.bounds ?? layer?.bounds
        frame = rect
        guard animated, let layer, let oldPosition, let oldBounds else {
            layer?.removeAllAnimations()
            return
        }
        for (key, from, to) in [
            ("position", NSValue(point: oldPosition), NSValue(point: layer.position)),
            ("bounds", NSValue(rect: oldBounds), NSValue(rect: layer.bounds))
        ] {
            let spring = CASpringAnimation(keyPath: key)
            // Critically damped, response 0.2 s (§10 mouse selection option).
            spring.mass = 1
            spring.stiffness = pow(2 * .pi / 0.2, 2)
            spring.damping = 2 * sqrt(spring.stiffness)
            spring.fromValue = from
            spring.toValue = to
            spring.duration = 0.2
            layer.add(spring, forKey: key)
        }
    }
}

/// The terminal theme supplies the hue; semantic surface levels supply contrast.
struct TabStripChrome {
    let bar: NSColor
    let track: NSColor
    let selection: NSColor
    let hover: NSColor
    let hairline: NSColor

    init(theme: TerminalTheme?, opacity: Double, key: Bool, appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = TerminalWindowAppearance.background(theme: theme, opacity: 1)
        func blend(_ fraction: CGFloat, _ color: NSColor) -> NSColor {
            base.blended(withFraction: fraction, of: color) ?? base
        }
        if theme == nil {
            bar = ProgramGlyphCatalog.color(key ? (dark ? 0x292929 : 0xF2F2F2) : (dark ? 0x303030 : 0xF7F7F7))
            track = ProgramGlyphCatalog.color(dark ? 0x202020 : 0xE8E8E8)
            selection = ProgramGlyphCatalog.color(key ? (dark ? 0x454545 : 0xFBFBFB) : (dark ? 0x383838 : 0xF2F2F2))
            hover = ProgramGlyphCatalog.color(dark ? 0x383838 : 0xDCDCDC)
        } else {
            bar = blend(dark ? (key ? 0.05 : 0.1) : (key ? 0.05 : 0.03), dark ? .white : .black)
                .withAlphaComponent(opacity)
            track = blend(dark ? 0.14 : 0.09, .black)
            selection = dark ? blend(key ? 0.17 : 0.08, .white) : blend(key ? 0.015 : 0.05, .black)
            hover = blend(dark ? 0.10 : 0.14, dark ? .white : .black)
        }
        hairline = dark ? NSColor.white.withAlphaComponent(0.12) : ProgramGlyphCatalog.color(0xD9D9D9)
    }
}

/// Horizontal wheel events and vertical mouse wheels both scroll the strip.
final class TabScrollView: NSScrollView {
    var viewportChanged: (() -> Void)?
    private let fade = CAGradientLayer()
    private var boundsObserver: NSObjectProtocol?

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        // The strip occupies the titlebar; automatic safe-area insets intercept its tab centers.
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFade()
                self?.viewportChanged?()
            }
        }
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = fade
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }
    override func layout() {
        super.layout()
        updateFade()
    }

    func updateFade() {
        // The shared divider adds one point to an otherwise fitting strip.
        // That extra divider must not turn on a 16 pt overflow fade.
        let leading = contentView.bounds.minX > 1.01
        let trailing = contentView.bounds.maxX < (documentView?.bounds.width ?? 0) - 1.01
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        let edge = min(0.5, 16 / max(1, bounds.width))
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        fade.colors = [
            (leading ? NSColor.clear : .black).cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            (trailing ? NSColor.clear : .black).cgColor
        ]
        CATransaction.commit()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let maximum = max(0, (documentView?.bounds.width ?? 0) - contentView.bounds.width)
        contentView.scroll(to: NSPoint(x: min(maximum, max(0, contentView.bounds.minX - delta)), y: 0))
        reflectScrolledClipView(contentView)
    }
}
