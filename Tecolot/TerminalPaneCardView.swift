import AppKit
import Observation
import SwiftTerm

/// Keeps the live terminal container intact when card appearance changes.
final class TerminalPaneCardView: NSView {
    /// The inputs of refreshAppearance(). The card applies them again only
    /// when one of them changes.
    private struct AppliedState: Equatable {
        var cardsEnabled: Bool
        var showsHeader: Bool
        var focused: Bool
        var zoomed: Bool
        var canZoom: Bool
        var presentation: PanePresentation
        var foreground: NSColor
        var background: NSColor
        var highContrast: Bool
        var padding: GlobalAppearanceSettings.TerminalPadding
        var paneStyle: GlobalAppearanceSettings.PaneStyle
        var highlightActivePane: Bool
        var highlightColor: NSColor
        var activityPreferences: ProgramActivityPreferences
        var muted: Bool
    }

    let controller: TerminalSessionController
    let content: TerminalSessionContainerView
    /// The host sets this value. See TerminalPaneHostView.cardsEnabled.
    var cardsEnabled: Bool {
        didSet {
            guard oldValue != cardsEnabled else {
                return
            }
            needsLayout = true
            refreshAppearance()
        }
    }
    private let surface = NSView()
    let header = PaneTitlebarView()
    let directoryProxy = WorkingDirectoryTitlebarControl()
    var showsHeader = true {
        didSet {
            if oldValue != showsHeader {
                needsLayout = true
                refreshAppearance()
            }
        }
    }
    var windowLeadingInset: CGFloat = 0 {
        didSet {
            if oldValue != windowLeadingInset {
                needsLayout = true
            }
        }
    }
    var windowTrailingInset: CGFloat = 0 {
        didSet {
            if oldValue != windowTrailingInset {
                needsLayout = true
            }
        }
    }
    var integratedWindowHeader = false {
        didSet {
            guard oldValue != integratedWindowHeader else {
                return
            }
            header.movesWindow = integratedWindowHeader
            needsLayout = true
        }
    }
    private let clip = CAShapeLayer()
    let outlineLayer = CAShapeLayer()
    private weak var outlineContainer: NSView?
    private var transitioning = false
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let directory = NSTextField(labelWithString: "")
    private let activity = ProgramStatusBadgeView()
    private var actionButtons: [NSButton] = []
    private let overflow = ChromeIconButton(frame: .zero)
    private var appliedState: AppliedState?
    private var focused = false
    private var paneStyle = GlobalAppearanceSettings.PaneStyle.comfortable

    init(controller: TerminalSessionController, content: TerminalSessionContainerView, cardsEnabled: Bool) {
        self.controller = controller
        self.content = content
        self.cardsEnabled = cardsEnabled
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        surface.wantsLayer = true
        surface.layer?.masksToBounds = true
        surface.layer?.mask = clip
        outlineLayer.fillColor = nil
        outlineLayer.actions = PaneCardGeometry.outlineActions
        layer?.addSublayer(outlineLayer)
        addSubview(surface)
        surface.addSubview(content)
        surface.addSubview(header)
        header.onSelect = { [weak self] in
            self?.selectPane()
        }
        icon.imageScaling = .scaleProportionallyDown
        header.addSubview(icon)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        directory.font = .systemFont(ofSize: 12)
        for label in [title, directory] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.isSelectable = false
            header.addSubview(label)
        }
        header.addSubview(directoryProxy)
        header.addSubview(activity)
        let actions: [(String, String, Selector)] = [
            ("Split Right", "rectangle.split.2x1", #selector(splitRight)),
            ("Split Down", "rectangle.split.1x2", #selector(splitDown)),
            ("Zoom Pane", "arrow.up.left.and.arrow.down.right", #selector(toggleZoom)),
            ("Close Pane", "xmark", #selector(closePane))
        ]
        for (label, symbol, action) in actions {
            let button = ChromeIconButton(frame: .zero)
            configure(button, label: label, symbol: symbol, action: action)
            header.addSubview(button)
            actionButtons.append(button)
        }
        configure(overflow, label: "Pane Actions", symbol: "ellipsis", action: #selector(showActions))
        header.addSubview(overflow)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        header.setAccessibilityElement(true)
        header.setAccessibilityRole(.group)
        header.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Split Right", handler: { [weak self] in self?.splitRight()
                return true
            }),
            NSAccessibilityCustomAction(name: "Split Down", handler: { [weak self] in self?.splitDown()
                return true
            }),
            NSAccessibilityCustomAction(name: "Zoom or Restore Pane", handler: { [weak self] in self?.toggleZoom()
                return true
            }),
            NSAccessibilityCustomAction(name: "Close Pane", handler: { [weak self] in self?.closePane()
                return true
            })
        ])
        refreshAppearance()
        observePresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(_ button: NSButton, label: String, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    /// The card observes its own title, icon, focus and zoom. The host
    /// sends the changes of colors, metrics and pane count.
    private func observePresentation() {
        withObservationTracking {
            _ = controller.panePresentation
            _ = controller.owningTab?.isMuted
            _ = controller.programStatus.tabStatus
            _ = controller.workspace?.focusedControllerID
            _ = controller.workspace?.zoomedControllerID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.refreshAppearance()
                self.observePresentation()
            }
        }
    }

    func refreshAppearance() {
        let workspace = controller.workspace
        var presentation = controller.panePresentation
        presentation.status = controller.programStatus.tabStatus
        let state = AppliedState(
            cardsEnabled: cardsEnabled,
            showsHeader: showsHeader,
            focused: workspace?.focusedControllerID == controller.id,
            zoomed: workspace?.zoomedControllerID == controller.id,
            canZoom: (workspace?.paneCount ?? 1) > 1,
            presentation: presentation,
            foreground: content.terminal.nativeForegroundColor,
            background: content.terminal.nativeBackgroundColor,
            highContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            padding: workspace?.appearanceSettings.terminalPadding ?? GlobalAppearanceSettings.storedTerminalPadding,
            paneStyle: workspace?.appearanceSettings.paneStyle ?? .comfortable,
            highlightActivePane: workspace?.appearanceSettings.highlightActivePane ?? true,
            highlightColor: (workspace?.appearanceSettings.activePaneColor ?? .controlAccentColor).usingColorSpace(.sRGB) ?? .controlAccentColor,
            activityPreferences: ProgramActivitySettings.shared.value, muted: controller.owningTab?.isMuted == true
        )
        guard state != appliedState else {
            return
        }
        appliedState = state
        let enabled = state.cardsEnabled
        focused = state.focused
        paneStyle = state.paneStyle
        content.setPadding(state.padding.points, top: state.padding.topPoints(cardsEnabled: enabled && showsHeader))
        let foreground = state.foreground
        let background = state.background
        let highContrast = state.highContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layer?.cornerRadius = enabled ? state.paneStyle.cornerRadius : 0
        surface.layer?.cornerCurve = .continuous
        // An opaque base also covers the interval before a Metal drawable
        // arrives. Leave translucent surfaces clear. If not, the alpha
        // applies two times.
        surface.layer?.backgroundColor = background.alphaComponent >= 1 ? background.cgColor : NSColor.clear.cgColor
        let focus = PaneFocusAppearance(
            enabled: enabled,
            focused: focused,
            hasMultiplePanes: state.canZoom,
            showsHeader: showsHeader,
            style: state.paneStyle,
            highlight: state.highlightActivePane,
            color: state.highlightColor,
            foreground: foreground,
            background: background,
            highContrast: highContrast
        )
        surface.layer?.borderWidth = 0
        outlineLayer.lineWidth = focus.lineWidth
        outlineLayer.strokeColor = focus.stroke.cgColor
        surface.layer?.borderColor = foreground.withAlphaComponent(highContrast ? 0.8 : (focused ? 0.28 : 0.10)).cgColor
        header.wantsLayer = true
        let headerBackground = focus.header
        header.layer?.backgroundColor = headerBackground.cgColor
        layer?.shadowColor = focus.shadow.cgColor
        layer?.shadowOpacity = focus.shadowOpacity
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        CATransaction.commit()
        header.isHidden = !enabled || !showsHeader
        presentation = state.presentation
        directoryProxy.configure(path: controller.titlebarWorkingDirectory, title: "", hasActivity: false)
        title.stringValue = presentation.title
        title.textColor = foreground
        title.toolTip = presentation.title
        directory.stringValue = Self.displayDirectory(presentation.directory)
        directory.textColor = foreground.withAlphaComponent(highContrast ? 0.85 : 0.65)
        directory.toolTip = presentation.directory
        let status = controller.owningTab?.isMuted == true || !ProgramActivitySettings.shared.value.showTabs ? TabStatus.none : presentation.status
        activity.configure(status, background: headerBackground, colored: ProgramActivitySettings.shared.value.color)
        activity.isHidden = status.badge == nil
        setAccessibilityValue(status.accessibilityValue)
        header.setAccessibilityLabel(presentation.title + " pane header")
        header.setAccessibilityValue(status.accessibilityValue)
        icon.image = TerminalAppIconResolver.shared.icon(forExecutablePath: presentation.executablePath)
        icon.contentTintColor = foreground
        icon.toolTip = TerminalAppIconResolver.identity(forExecutablePath: presentation.executablePath) ?? "Terminal"
        icon.setAccessibilityLabel(icon.toolTip ?? "Terminal")
        setAccessibilityLabel(presentation.title)
        let zoomed = state.zoomed
        actionButtons[2].image = NSImage(systemSymbolName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        actionButtons[2].toolTip = zoomed ? "Restore Panes" : "Zoom Pane"
        actionButtons[2].setAccessibilityLabel(actionButtons[2].toolTip ?? "Zoom Pane")
        actionButtons[2].isEnabled = state.canZoom
        for button in actionButtons + [overflow] {
            button.contentTintColor = .secondaryLabelColor
        }
        needsLayout = true
    }

    /// Prepares the layer for a transition of the host. The layer clips its
    /// content, and the background of the surface fills the area that the
    /// content does not cover. The shadow has the final shape, so remove it.
    func beginTransition() {
        guard let layer else {
            return
        }
        transitioning = true
        updateOutlinePlacement()
        layer.masksToBounds = true
        layer.cornerRadius = surface.layer?.cornerRadius ?? 0
        layer.cornerCurve = .continuous
        let mask = CAShapeLayer()
        mask.path = PaneCardGeometry.path(in: bounds, radius: layer.cornerRadius)
        layer.mask = mask
        // The surface keeps a translucent background clear, so that the
        // alpha applies one time. Use the same color.
        layer.backgroundColor = surface.layer?.backgroundColor
        layer.shadowOpacity = 0
    }

    /// Restores the layer after a transition.
    func endTransition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transitioning = false
        layer?.masksToBounds = false
        layer?.cornerRadius = 0
        layer?.mask = nil
        layer?.backgroundColor = nil
        CATransaction.commit()
        appliedState = nil
        refreshAppearance()
        updateOutlinePlacement()
    }

    /// Window outlines share one canvas; standalone hosts retain their local outline.
    func setOutlineContainer(_ view: NSView?) {
        outlineContainer = view
        updateOutlinePlacement()
    }

    private func updateOutlinePlacement() {
        PaneCardGeometry.withoutImplicitAnimations {
            let container = transitioning ? nil : outlineContainer
            let parent = container?.layer ?? layer
            if outlineLayer.superlayer !== parent || (container == nil && parent?.sublayers?.last !== outlineLayer) {
                outlineLayer.removeFromSuperlayer()
                parent?.addSublayer(outlineLayer)
            }
            outlineLayer.frame = container.map {
                convert(bounds, to: $0)
            } ?? bounds
        }
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        updateOutlinePlacement()
        let height = cardsEnabled && showsHeader ? paneStyle.headerHeight : 0
        header.frame = NSRect(x: 0, y: max(0, bounds.height - height), width: bounds.width, height: height)
        // The terminal container has required padding on each side. Keep
        // that size during initial attachment and very small window layouts.
        content.frame = NSRect(
            x: 0,
            y: 0,
            width: max(content.padding * 2, bounds.width),
            height: max(content.topPadding + content.padding, bounds.height - height)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = cardsEnabled ? paneStyle.cornerRadius : 0
        let path = PaneCardGeometry.path(in: bounds, radius: radius)
        clip.frame = surface.bounds
        clip.path = path
        outlineLayer.path = path
        layer?.shadowPath = path
        CATransaction.commit()
        let availableWidth = bounds.width - windowLeadingInset - windowTrailingInset
        let compact = availableWidth < 310
        let controlsWidth: CGFloat = (focused ? (compact ? 32 : 116) : 0) + windowTrailingInset
        for (index, button) in actionButtons.enumerated() {
            button.isHidden = !focused || compact
            button.frame = NSRect(x: bounds.width - windowTrailingInset - 112 + CGFloat(index) * 26, y: (height - 26) / 2, width: 26, height: 26)
        }
        overflow.isHidden = !focused || !compact
        overflow.frame = NSRect(x: bounds.width - windowTrailingInset - 32, y: (height - 26) / 2, width: 26, height: 26)
        icon.frame = NSRect(x: (paneStyle == .comfortable ? 6 : 10) + windowLeadingInset, y: (height - 18) / 2, width: 18, height: 18)
        activity.frame = NSRect(x: 27 + windowLeadingInset, y: 0, width: 15, height: 15)
        let textStart: CGFloat = (paneStyle == .comfortable ? 32 : 36) + windowLeadingInset
        let available = max(0, bounds.width - textStart - controlsWidth - 8)
        let proxy = integratedWindowHeader && paneStyle == .comfortable && directoryProxy.path != nil
        directoryProxy.isHidden = !proxy
        let titleWidth = min(proxy ? available / 2 : available, Self.textWidth(title))
        let gap: CGFloat = directory.stringValue.isEmpty ? 0 : 8
        let directoryWidth = min(max(0, available - titleWidth - gap), Self.textWidth(directory))
        directory.isHidden = proxy || directoryWidth == 0
        title.frame = NSRect(x: textStart, y: (height - 18) / 2, width: titleWidth, height: 18)
        directory.frame = NSRect(x: title.frame.maxX + gap, y: (height - 18) / 2, width: directoryWidth, height: 18)
        directoryProxy.frame = NSRect(
            x: title.frame.maxX + 8,
            y: (height - 24) / 2,
            width: min(directoryProxy.intrinsicContentSize.width, max(0, available - titleWidth - 8)),
            height: 24
        )
    }

    private static func textWidth(_ label: NSTextField) -> CGFloat {
        // When a field truncates its text, its intrinsic width can change
        // with its earlier frame. Measure the full text, so that the field
        // can expand after a resize or a title change.
        guard !label.stringValue.isEmpty else {
            return 0
        }
        let font = label.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + 4
    }

    private func selectPane() {
        controller.workspace?.markFocused(controller)
        if let terminal = controller.surface, let window {
            window.makeFirstResponder(terminal)
            controller.didBecomeFocused()
        }
    }

    @objc func splitRight() {
        selectPane()
        controller.workspace?.split(controller, direction: .right)
    }

    @objc func splitDown() {
        selectPane()
        controller.workspace?.split(controller, direction: .down)
    }

    @objc func toggleZoom() {
        selectPane()
        controller.workspace?.toggleSplitZoom()
    }

    @objc func closePane() {
        selectPane()
        controller.requestClose()
    }

    @objc private func showActions() {
        let menu = NSMenu()
        let zoomed = controller.workspace?.zoomedControllerID == controller.id
        for (label, action) in [("Split Right", #selector(splitRight)), ("Split Down", #selector(splitDown)), (zoomed ? "Restore Panes" : "Zoom Pane", #selector(toggleZoom)), ("Close Pane", #selector(closePane))] {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height), in: overflow)
    }

    private static func displayDirectory(_ path: String?) -> String {
        guard let path else {
            return ""
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

final class PaneTitlebarView: NSView {
    var onSelect: (() -> Void)?
    var movesWindow = false
    override var mouseDownCanMoveWindow: Bool {
        false
    }
    override func mouseDown(with event: NSEvent) {
        onSelect?()
        guard movesWindow else {
            return
        }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")?.lowercased() {
            case "minimize":
                window?.miniaturize(nil)
            case "none":
                break
            default:
                window?.performZoom(nil)
            }
        } else {
            if let terminalWindow = window as? TerminalWindow {
                terminalWindow.performPaneHeaderDrag(with: event)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else {
            return nil
        }
        var ancestor: NSView? = hit
        while let view = ancestor, view !== self {
            if view is NSButton || view is WorkingDirectoryTitlebarControl {
                return hit
            }
            ancestor = view.superview
        }
        return self
    }
}
