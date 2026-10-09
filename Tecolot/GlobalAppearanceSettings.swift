import AppKit

/// The app-wide card settings. ContentView reads them with @AppStorage and
/// gives them to the workspace of each window. SettingsView writes them.
nonisolated struct GlobalAppearanceSettings: Equatable {
    /// UserDefaults keeps the raw values. Do not change them.
    nonisolated enum Backdrop: String, CaseIterable {
        case gradient
        case desktopBlur

        var title: String {
            switch self {
            case .gradient: "Theme gradient"
            case .desktopBlur: "Desktop blur"
            }
        }
    }

    static let paneCardsEnabledKey = "paneCardsEnabled"
    static let paneCardsBackdropKey = "paneCardsBackdrop"
    var paneCardsEnabled = true
    var paneCardsBackdrop = Backdrop.gradient

    /// The height of the title bar of a card.
    static let cardTitlebarHeight: CGFloat = 32
    /// The space around the cards and between them.
    static let cardSpacing: CGFloat = 12
}

struct ResolvedWorkspaceAppearance {
    let gradientColors: [NSColor]
    let tintColor: NSColor
    let isDark: Bool

    func gradientColors(opacity: Double, reduceTransparency: Bool) -> [NSColor] {
        let alpha = reduceTransparency ? 1 : min(max(opacity, 0), 1)
        return gradientColors.map { $0.withAlphaComponent(CGFloat(alpha)) }
    }

    init(theme: TerminalTheme) {
        func color(_ value: ProfileColor) -> NSColor {
            NSColor(srgbRed: CGFloat(value.red) / 65_535,
                    green: CGFloat(value.green) / 65_535,
                    blue: CGFloat(value.blue) / 65_535, alpha: 1)
        }
        let base = color(theme.background)
        let colors = theme.isValid ? [theme.ansi[1], theme.ansi[4], theme.ansi[3]] : [theme.background]
        gradientColors = colors.map { base.blended(withFraction: 0.14, of: color($0)) ?? base }
        tintColor = base.withAlphaComponent(0.55)
        isDark = theme.isDark
    }
}

final class TerminalWorkspaceBackdropView: NSView {
    private let effect = NSVisualEffectView()
    private let gradient = CAGradientLayer()
    private let tint = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effect.blendingMode = .behindWindow
        effect.material = .underWindowBackground
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        layer?.addSublayer(gradient)
        layer?.addSublayer(tint)
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        effect.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        tint.frame = bounds
        CATransaction.commit()
    }

    /// True when the backdrop shows the desktop through the window.
    var showsDesktopBlur: Bool { !isHidden && !effect.isHidden }

    func update(visible: Bool, backdrop: GlobalAppearanceSettings.Backdrop,
                appearance: ResolvedWorkspaceAppearance, opacity: Double = 1) {
        isHidden = !visible
        let blur = backdrop == .desktopBlur
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effect.isHidden = !blur
        gradient.isHidden = blur
        tint.isHidden = !blur
        effect.appearance = NSAppearance(named: appearance.isDark ? .darkAqua : .aqua)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = appearance.gradientColors(
            opacity: opacity,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        ).map(\.cgColor)
        tint.backgroundColor = appearance.tintColor.cgColor
        CATransaction.commit()
    }
}

final class TerminalWorkspaceSplitView: NSSplitView {
    /// The split node that this view shows. The host uses it to find the
    /// minimum size of each side.
    var paneNode: TerminalPaneNode?
    var cardsEnabled = true {
        didSet { if oldValue != cardsEnabled { needsDisplay = true } }
    }

    static func dividerThickness(cardsEnabled: Bool) -> CGFloat {
        cardsEnabled ? GlobalAppearanceSettings.cardSpacing : 1
    }

    override var dividerThickness: CGFloat { Self.dividerThickness(cardsEnabled: cardsEnabled) }
    override func drawDivider(in rect: NSRect) {
        if !cardsEnabled { super.drawDivider(in: rect) }
    }
}
