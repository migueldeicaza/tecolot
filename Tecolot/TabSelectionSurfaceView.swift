import AppKit
import QuartzCore

/// The single selection capsule belongs to the strip, never to a tab cell.
final class TabSelectionSurfaceView: NSView {
    private var glassView: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        setAccessibilityElement(false)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.wantsLayer = true
            glass.cornerRadius = 16
            glass.style = .regular
            glass.autoresizingMask = [.width, .height]
            addSubview(glass)
            glassView = glass
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    override func layout() {
        super.layout()
        glassView?.frame = bounds
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func apply(chrome: TabStripChrome, key: Bool) {
        layer?.backgroundColor = chrome.selection.cgColor
        layer?.borderColor = chrome.hairline.cgColor
        layer?.borderWidth = key ? 0.5 : 0
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = key ? 0.14 : 0
        layer?.shadowRadius = 3.5
        layer?.shadowOffset = CGSize(width: 0, height: -1.5)
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.isHidden = !key
            glass.tintColor = chrome.selection.withAlphaComponent(0.35)
        }
    }

    func move(to rect: NSRect, animated: Bool) {
        let oldPosition = layer?.presentation()?.position ?? layer?.position
        let oldBounds = layer?.presentation()?.bounds ?? layer?.bounds
        frame = rect
        glassView?.frame = bounds
        guard animated, let layer, let oldPosition, let oldBounds else {
            layer?.removeAllAnimations()
            glassView?.layer?.removeAllAnimations()
            return
        }
        func makeSpring(keyPath: String, from: Any, to: Any) -> CASpringAnimation {
            let spring = CASpringAnimation(keyPath: keyPath)
            // Critically damped, response 0.2 s (§10 mouse selection option).
            spring.mass = 1
            spring.stiffness = pow(2 * .pi / 0.2, 2)
            spring.damping = 2 * sqrt(spring.stiffness)
            spring.fromValue = from
            spring.toValue = to
            spring.duration = 0.2
            return spring
        }
        for (key, from, to) in [
            ("position", NSValue(point: oldPosition), NSValue(point: layer.position)),
            ("bounds", NSValue(rect: oldBounds), NSValue(rect: layer.bounds))
        ] {
            layer.add(makeSpring(keyPath: key, from: from, to: to), forKey: key)
        }
        // NSGlassEffectView lays out its internal SDF sublayers immediately on resize
        // and does not inherit a parent layer's bounds spring. Scaling its backing layer
        // with the matching spring keeps the glass locked to the capsule's animated bounds.
        if let glassLayer = glassView?.layer {
            if oldBounds.size != layer.bounds.size,
               oldBounds.width > 0, oldBounds.height > 0,
               layer.bounds.width > 0, layer.bounds.height > 0 {
                glassLayer.add(
                    makeSpring(keyPath: "transform.scale.x", from: oldBounds.width / layer.bounds.width, to: 1),
                    forKey: "transform.scale.x"
                )
                glassLayer.add(
                    makeSpring(keyPath: "transform.scale.y", from: oldBounds.height / layer.bounds.height, to: 1),
                    forKey: "transform.scale.y"
                )
            } else {
                glassLayer.removeAnimation(forKey: "transform.scale.x")
                glassLayer.removeAnimation(forKey: "transform.scale.y")
            }
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
            track = dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.055)
            selection = ProgramGlyphCatalog.color(key ? (dark ? 0x454545 : 0xFBFBFB) : (dark ? 0x383838 : 0xF2F2F2))
            hover = dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.055)
        } else {
            bar = blend(dark ? (key ? 0.05 : 0.1) : (key ? 0.05 : 0.03), dark ? .white : .black)
                .withAlphaComponent(opacity)
            track = dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.055)
            selection = dark ? blend(key ? 0.17 : 0.08, .white) : blend(key ? 0.01 : 0.04, .black)
            hover = dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.055)
        }
        hairline = dark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.06)
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
