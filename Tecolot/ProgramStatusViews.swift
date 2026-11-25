import AppKit
import SwiftTerm
import QuartzCore

/// Shared glyph badge for tabs, pane headers, Activity and the M5 sidebar.
final class ProgramStatusBadgeView: NSView {
    private var status = TabStatus.none
    private var colored = true
    private var ring = NSColor.windowBackgroundColor
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    /// Suppresses the quiet output dot to match Rex; explicit notifications and
    /// OSC 7501 states still badge the tab icon and toolbar eye.
    private static func visibleBadge(for status: TabStatus) -> TabStatus.Badge? {
        guard let badge = status.badge, badge > .quiet else {
            return nil
        }
        return badge
    }

    /// Updates glyph, color and badge transition animations only when presentation changes.
    func configure(_ status: TabStatus, background: NSColor, colored: Bool) {
        let previous = Self.visibleBadge(for: self.status)
        let next = Self.visibleBadge(for: status)
        guard self.status != status || ring != background || self.colored != colored else {
            return
        }
        self.status = status
        ring = background
        self.colored = colored
        needsDisplay = true
        guard let layer else {
            return
        }
        if previous != next {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            layer.add(fade, forKey: "badgeFade")
        }
        if previous == nil, next != nil {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.3
            layer.add(fade, forKey: "appearOpacity")
            isHidden = false
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.mass = 1
            scale.stiffness = pow(2 * .pi / 0.3, 2)
            scale.damping = 2 * 0.6 * sqrt(scale.stiffness)
            scale.fromValue = 0.3
            scale.toValue = 1
            scale.duration = 0.3
            layer.add(scale, forKey: "appear")
        } else if previous != nil, next == nil {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.15
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 0.6
            scale.duration = 0.15
            layer.add(fade, forKey: "disappear")
            layer.add(scale, forKey: "disappearScale")
        } else if previous != next {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            layer.add(fade, forKey: "color")
        }
        layer.opacity = next == nil ? 0 : 1
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let badge = Self.visibleBadge(for: status) else {
            return
        }
        let diameter: CGFloat = 10
        let rect = NSRect(
            x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter
        )
        ring.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -1.5, dy: -1.5)).fill()
        (colored ? badge.color : NSColor.secondaryLabelColor).setFill()
        NSBezierPath(ovalIn: rect).fill()
        if
            let name = status.badgeSymbol,
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
                .init(pointSize: 6.5, weight: .bold)
            ) {
            let glyph = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { target in
                image.draw(in: target)
                NSColor.white.setFill()
                target.fill(using: .sourceIn)
                return true
            }
            glyph.draw(in: NSRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8))
        }
    }
}

/// Draws the three-dot working wave with a static Reduce Motion alternative.
final class ProgramWorkingDotsView: NSView {
    private let copies = CAReplicatorLayer()
    private let dot = CALayer()
    private var reduced: Bool?
    private(set) var visible = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
        copies.instanceCount = 3
        copies.instanceDelay = 0.13
        copies.instanceTransform = CATransform3DMakeTranslation(5.5, 0, 0)
        dot.bounds = CGRect(x: 0, y: 0, width: 3, height: 3)
        dot.cornerRadius = 1.5
        copies.addSublayer(dot)
        layer?.addSublayer(copies)
    }
    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    override func layout() {
        super.layout()
        copies.frame = bounds
        dot.position = CGPoint(x: 2, y: bounds.midY)
    }
    /// Starts or pauses the working wave and respects Reduce Motion.
    func configure(visible: Bool, reduceMotion: Bool) {
        if self.visible != visible {
            self.visible = visible
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer?.presentation()?.opacity ?? (visible ? 0 : 1)
            fade.toValue = visible ? 1 : 0
            fade.duration = 0.2
            layer?.opacity = visible ? 1 : 0
            layer?.add(fade, forKey: "visibility")
        }
        guard visible else {
            dot.removeAllAnimations()
            reduced = nil
            return
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = NSColor.secondaryLabelColor.cgColor
        }
        guard reduced != reduceMotion else {
            return
        }
        reduced = reduceMotion
        dot.removeAllAnimations()
        dot.opacity = 0.45
        guard !reduceMotion else {
            return
        }
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0.45, 1, 0.45, 0.45]
        opacity.keyTimes = [0, 0.16, 0.325, 1]
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1, 1.3, 1, 1]
        scale.keyTimes = opacity.keyTimes
        let group = CAAnimationGroup()
        group.animations = [opacity, scale]
        group.duration = 1.23
        group.repeatCount = .infinity
        dot.add(group, forKey: "wave")
    }
}

/// A filled sector with a 1.5 pt ring, positioned over the front tile's glyph.
final class ProgramProgressPieView: NSView {
    private let ring = CAShapeLayer()
    private let wedge = CAShapeLayer()
    private var progress: Int?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
        for shape in [wedge, ring] {
            shape.fillColor = nil
            shape.strokeColor = NSColor.white.cgColor
            layer?.addSublayer(shape)
        }
        ring.lineWidth = 1.5
        wedge.lineWidth = 5
    }
    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        let path = CGMutablePath()
        path.addArc(center: center, radius: 2.5, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        wedge.path = path
    }
    /// Updates the progress wedge with a bounded percentage.
    func configure(_ progress: Int) {
        guard self.progress != progress else {
            return
        }
        let old = wedge.presentation()?.strokeEnd ?? wedge.strokeEnd
        self.progress = progress
        wedge.strokeEnd = CGFloat(progress) / 100
        let change = CABasicAnimation(keyPath: "strokeEnd")
        change.fromValue = old
        change.toValue = wedge.strokeEnd
        change.duration = 0.25
        change.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wedge.add(change, forKey: "progress")
    }
}

/// The ticker uses the clipping view's layer clock, so all of its holds,
/// fades and scrolls pause together when the strip is out of view.
@MainActor
/// Rotates blocked messages and scrolls long announcements at the configured speed.
final class TabAnnouncementTicker {
    private weak var clip: NSView?
    private weak var title: NSTextField?
    private weak var mask: CAGradientLayer?
    private var labels: [NSTextField] = []
    private var signature = ""
    /// Binds announcement layers to the existing title clip without retaining the cell.
    init(clip: NSView, title: NSTextField, mask: CAGradientLayer) {
        self.clip = clip
        self.title = title
        self.mask = mask
        title.wantsLayer = true
    }
    /// Rebuilds scrolling and dwell animations only when messages or motion settings change.
    func configure(messages: [String], speed: Double, reduceMotion: Bool) {
        guard let clip, let title else {
            return
        }
        let messages = messages.filter {
            !$0.isEmpty
        }
        let font = title.font ?? NSFont.systemFont(ofSize: 13)
        let next = "\(messages)|\(clip.bounds.width)|\(speed)|\(reduceMotion)|\(font.fontName)|\(font.pointSize)"
        guard next != signature else {
            return
        }
        signature = next
        if !labels.isEmpty, messages.isEmpty {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.layer?.add(fade, forKey: "announcementReturn")
        }
        labels.forEach {
            $0.removeFromSuperview()
        }
        labels = []
        title.layer?.removeAnimation(forKey: "announcement")
        mask?.removeAnimation(forKey: "leadingOverflow")
        title.layer?.opacity = 1
        guard !messages.isEmpty else {
            return
        }
        let widths = messages.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }
        let scrolls = widths.map {
            !reduceMotion && $0 > clip.bounds.width ? Double($0 + 30) / speed : 0
        }
        let durations = scrolls.map {
            0.25 + ($0 == 0 ? 5.3 : 1.4 + $0 + 1) + 0.25 + 4.5
        }
        let total = durations.reduce(0, +)
        var offset = 0.0
        var titleTimes: [NSNumber] = [0]
        var titleValues: [Float] = [1]
        let normalMask = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        let scrollingMask = [
            NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor,
        ]
        var maskTimes: [NSNumber] = [0]
        var maskValues = [normalMask]
        for index in messages.indices {
            let label = NSTextField(
                labelWithString: scrolls[index] == 0 ? messages[index] : messages[index] + "     " + messages[index]
            )
            label.font = font
            label.textColor = title.textColor
            label.wantsLayer = true
            if scrolls[index] > 0 {
                let space = (" " as NSString).size(withAttributes: [.font: font]).width
                let text = NSMutableAttributedString(string: messages[index], attributes: [.font: font])
                text.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: 30 - space]))
                text.append(NSAttributedString(string: messages[index], attributes: [.font: font]))
                label.attributedStringValue = text
            }
            label.frame = NSRect(x: 0, y: 0, width: max(clip.bounds.width, widths[index] * 2 + 30), height: 18)
            label.setAccessibilityElement(false)
            clip.addSubview(label)
            labels.append(label)
            let end = offset + durations[index] - 4.5
            let times = [0, offset / total, (offset + 0.25) / total, (end - 0.25) / total, end / total, 1].map {
                NSNumber(value: $0)
            }
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.keyTimes = times
            fade.values = [0, 0, 1, 1, 0, 0]
            fade.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: times.count - 1)
            fade.duration = total
            fade.repeatCount = .infinity
            label.layer?.opacity = 0
            label.layer?.add(fade, forKey: "announcement")
            titleTimes += [
                NSNumber(value: offset / total), NSNumber(value: (offset + 0.25) / total),
                NSNumber(value: (end - 0.25) / total), NSNumber(value: end / total),
            ]
            titleValues += [1, 0, 0, 1]
            if scrolls[index] > 0 {
                maskTimes += [
                    NSNumber(value: (offset + 1.65) / total), NSNumber(value: (offset + 1.65 + scrolls[index]) / total),
                ]
                maskValues += [scrollingMask, normalMask]
                let move = CAKeyframeAnimation(keyPath: "transform.translation.x")
                move.keyTimes = [
                    0, NSNumber(value: (offset + 1.65) / total),
                    NSNumber(value: (offset + 1.65 + scrolls[index]) / total), NSNumber(value: end / total), 1,
                ]
                move.values = [0, 0, -(widths[index] + 30), -(widths[index] + 30), 0]
                move.calculationMode = .linear
                move.duration = total
                move.repeatCount = .infinity
                label.layer?.add(move, forKey: "scroll")
            }
            offset += durations[index]
        }
        if maskTimes.count > 1 {
            maskTimes.append(1)
            maskValues.append(normalMask)
            let overflow = CAKeyframeAnimation(keyPath: "colors")
            overflow.keyTimes = maskTimes
            overflow.values = maskValues
            overflow.calculationMode = .discrete
            overflow.duration = total
            overflow.repeatCount = .infinity
            mask?.add(overflow, forKey: "leadingOverflow")
        }
        titleTimes.append(1)
        titleValues.append(1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.keyTimes = titleTimes
        fade.values = titleValues
        fade.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: titleTimes.count - 1
        )
        fade.duration = total
        fade.repeatCount = .infinity
        title.layer?.add(fade, forKey: "announcement")
    }
}

/// Reproduces native local flashes while retaining the legacy persistent bell policy.
@MainActor
enum ProgramActivityBell {
    /// Persistent panes historically beep for every non-none style and never flash.
    static func policy(style: BellStyle, local: Bool) -> (sound: Bool, visual: Bool) {
        guard local else {
            return (style != .none, false)
        }
        switch style {
        case .none:
            return (false, false)
        case .sound:
            return (true, false)
        case .visual:
            return (false, true)
        case .soundAndVisual:
            return (true, true)
        }
    }

    /// Uses SwiftTerm's 200 ms foreground overlay animation exactly once.
    static func flash(on view: NSView, color: NSColor) {
        guard let layer = view.layer else {
            return
        }
        let flash = CALayer()
        flash.frame = view.bounds
        flash.backgroundColor = color.cgColor
        flash.opacity = 0
        layer.addSublayer(flash)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            flash.removeFromSuperlayer()
        }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 0.35, 0]
        animation.keyTimes = [0, 0.3, 1]
        animation.duration = 0.2
        flash.add(animation, forKey: "bell")
        CATransaction.commit()
    }
}
