import AppKit
import Observation
import SwiftTerm

/// Keeps the live terminal container intact when card appearance changes.
final class TerminalPaneCardView: NSView {
    /// The inputs of refreshAppearance(). The card applies them again only
    /// when one of them changes.
    private struct AppliedState: Equatable {
        var cardsEnabled: Bool
        var focused: Bool
        var zoomed: Bool
        var canZoom: Bool
        var presentation: PanePresentation
        var foreground: NSColor
        var background: NSColor
        var highContrast: Bool
    }

    let controller: TerminalSessionController
    let content: TerminalSessionContainerView
    /// The host sets this value. See TerminalPaneHostView.cardsEnabled.
    var cardsEnabled: Bool {
        didSet {
            guard oldValue != cardsEnabled else { return }
            needsLayout = true
            refreshAppearance()
        }
    }
    private let surface = NSView()
    private let header = PaneTitlebarView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let directory = NSTextField(labelWithString: "")
    private let activity = NSTextField(labelWithString: "●")
    private var actionButtons: [NSButton] = []
    private let overflow = NSButton()
    private var appliedState: AppliedState?
    private var focused = false

    init(controller: TerminalSessionController, content: TerminalSessionContainerView, cardsEnabled: Bool) {
        self.controller = controller
        self.content = content
        self.cardsEnabled = cardsEnabled
        super.init(frame: .zero)
        wantsLayer = true
        surface.wantsLayer = true
        surface.layer?.masksToBounds = true
        addSubview(surface)
        surface.addSubview(content)
        surface.addSubview(header)
        header.onSelect = { [weak self] in self?.selectPane() }
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
        activity.font = .systemFont(ofSize: 10)
        header.addSubview(activity)
        let actions: [(String, String, Selector)] = [
            ("Split Right", "rectangle.split.2x1", #selector(splitRight)),
            ("Split Down", "rectangle.split.1x2", #selector(splitDown)),
            ("Zoom Pane", "arrow.up.left.and.arrow.down.right", #selector(toggleZoom)),
            ("Close Pane", "xmark", #selector(closePane))
        ]
        for (label, symbol, action) in actions {
            let button = NSButton()
            configure(button, label: label, symbol: symbol, action: action)
            header.addSubview(button)
            actionButtons.append(button)
        }
        configure(overflow, label: "Pane Actions", symbol: "ellipsis", action: #selector(showActions))
        header.addSubview(overflow)
        setAccessibilityRole(.group)
        refreshAppearance()
        observePresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure(_ button: NSButton, label: String, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
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
            _ = controller.workspace?.focusedControllerID
            _ = controller.workspace?.zoomedControllerID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshAppearance()
                self.observePresentation()
            }
        }
    }

    func refreshAppearance() {
        let workspace = controller.workspace
        let state = AppliedState(
            cardsEnabled: cardsEnabled,
            focused: workspace?.focusedControllerID == controller.id,
            zoomed: workspace?.zoomedControllerID == controller.id,
            canZoom: (workspace?.paneCount ?? 1) > 1,
            presentation: controller.panePresentation,
            foreground: content.terminal.nativeForegroundColor,
            background: content.terminal.nativeBackgroundColor,
            highContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        guard state != appliedState else { return }
        appliedState = state
        let enabled = state.cardsEnabled
        focused = state.focused
        content.setPaneCardsEnabled(enabled)
        let foreground = state.foreground
        let background = state.background
        let highContrast = state.highContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layer?.cornerRadius = enabled ? 14 : 0
        // An opaque base also covers the interval before a Metal drawable
        // arrives. Leave translucent surfaces clear. If not, the alpha
        // applies two times.
        surface.layer?.backgroundColor = background.alphaComponent >= 1 ? background.cgColor : NSColor.clear.cgColor
        surface.layer?.borderWidth = enabled && (focused || highContrast) ? (focused && highContrast ? 2 : 1) : 0
        surface.layer?.borderColor = foreground.withAlphaComponent(highContrast ? 0.8 : (focused ? 0.28 : 0.10)).cgColor
        header.wantsLayer = true
        let headerBackground = focused
            ? (background.blended(withFraction: highContrast ? 0.16 : 0.10, of: foreground) ?? background)
                .withAlphaComponent(background.alphaComponent)
            : background
        header.layer?.backgroundColor = headerBackground.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = enabled ? 0.08 : 0
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        CATransaction.commit()
        header.isHidden = !enabled
        let presentation = state.presentation
        title.stringValue = presentation.title
        title.textColor = foreground
        title.toolTip = presentation.title
        directory.stringValue = Self.displayDirectory(presentation.directory)
        directory.textColor = foreground.withAlphaComponent(highContrast ? 0.85 : 0.65)
        directory.toolTip = presentation.directory
        activity.isHidden = !presentation.hasActivity
        activity.textColor = foreground
        activity.setAccessibilityLabel("Activity in this pane")
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
        for button in actionButtons + [overflow] { button.contentTintColor = foreground.withAlphaComponent(0.7) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let height = cardsEnabled ? GlobalAppearanceSettings.cardTitlebarHeight : 0
        header.frame = NSRect(x: 0, y: max(0, bounds.height - height), width: bounds.width, height: height)
        // The terminal container has four points of required padding. Keep
        // that size during initial attachment and very small window layouts.
        content.frame = NSRect(x: 0, y: 0, width: max(4, bounds.width), height: max(4, bounds.height - height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cardsEnabled ? 14 : 0, cornerHeight: cardsEnabled ? 14 : 0, transform: nil)
        CATransaction.commit()
        let compact = bounds.width < 310
        let controlsWidth: CGFloat = focused ? (compact ? 32 : 116) : 0
        for (index, button) in actionButtons.enumerated() {
            button.isHidden = !focused || compact
            button.frame = NSRect(x: bounds.width - 112 + CGFloat(index) * 26, y: 3, width: 26, height: 26)
        }
        overflow.isHidden = !focused || !compact
        overflow.frame = NSRect(x: bounds.width - 32, y: 3, width: 26, height: 26)
        icon.frame = NSRect(x: 10, y: 7, width: 18, height: 18)
        activity.frame = NSRect(x: 32, y: 9, width: 10, height: 14)
        let textStart: CGFloat = controller.panePresentation.hasActivity ? 45 : 36
        let available = max(0, bounds.width - textStart - controlsWidth - 8)
        let titleWidth = min(available, Self.textWidth(title))
        let gap: CGFloat = directory.stringValue.isEmpty ? 0 : 8
        let directoryWidth = min(max(0, available - titleWidth - gap), Self.textWidth(directory))
        directory.isHidden = directoryWidth == 0
        title.frame = NSRect(x: textStart, y: 8, width: titleWidth, height: 18)
        directory.frame = NSRect(x: title.frame.maxX + gap, y: 8, width: directoryWidth, height: 18)
    }

    private static func textWidth(_ label: NSTextField) -> CGFloat {
        // When a field truncates its text, its intrinsic width can change
        // with its earlier frame. Measure the full text, so that the field
        // can expand after a resize or a title change.
        guard !label.stringValue.isEmpty else { return 0 }
        let font = label.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + 4
    }

    private func selectPane() {
        controller.workspace?.markFocused(controller)
        if let terminal = controller.terminal, let window {
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
        guard let path else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

private final class PaneTitlebarView: NSView {
    var onSelect: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }
}
