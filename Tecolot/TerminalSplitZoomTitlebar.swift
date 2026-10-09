import AppKit
import SwiftTerm

@MainActor
enum TerminalSplitZoomTitlebar {
    private static let identifier = NSUserInterfaceItemIdentifier("TecolotSplitZoom")

    static func configure(_ window: NSWindow, workspace: TerminalPaneWorkspace) {
        let accessory: SplitZoomTitlebarAccessory
        if let existing = window.titlebarAccessoryViewControllers.first(where: {
            $0.identifier == identifier
        }) as? SplitZoomTitlebarAccessory {
            accessory = existing
        } else {
            accessory = SplitZoomTitlebarAccessory()
            accessory.identifier = identifier
            accessory.layoutAttribute = .right
            window.addTitlebarAccessoryViewController(accessory)
        }
        accessory.control.configure(workspace: workspace)

        let tabControl: TerminalTabAccessory
        if let existing = window.tab.accessoryView as? TerminalTabAccessory {
            tabControl = existing
        } else {
            tabControl = TerminalTabAccessory()
            window.tab.accessoryView = tabControl
        }
        tabControl.configure(workspace: workspace)
        if workspace.appearanceSettings.paneCardsEnabled {
            let image = TerminalTabIconStack.image(workspace: workspace)
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(origin: NSPoint(x: 0, y: 6 - image.size.height / 2), size: image.size)
            // The attributed title is a copy of the tab title. AppKit does not
            // update the copy when window.title changes. This is not a problem
            // because each title change goes through updateWindowTitle(), and
            // that function calls configure again. Tecolot has no Save As
            // command, so NSDocument does not change the title by itself.
            // If you add a path that sets window.title, call configure after it.
            let title = NSMutableAttributedString(attachment: attachment)
            title.append(NSAttributedString(string: "  " + window.tab.title))
            window.tab.attributedTitle = title
            window.tab.toolTip = workspace.controllers.map { $0.panePresentation.title }.joined(separator: "\n")
        } else {
            window.tab.attributedTitle = nil
            window.tab.toolTip = nil
        }
    }
}

/// Draws the pane icons for the native tab title. The icon of the focused
/// pane is in front of the stack.
@MainActor
enum TerminalTabIconStack {
    static func image(workspace: TerminalPaneWorkspace) -> NSImage {
        let focused = workspace.focusedController
        let ordered = (focused.map { [$0] } ?? []) + workspace.controllers.filter { $0 !== focused }
        let entries = ordered.prefix(3).map { controller in
            let image = TerminalAppIconResolver.shared.icon(forExecutablePath: controller.panePresentation.executablePath)
            let foreground = controller.terminal?.nativeForegroundColor ?? .labelColor
            let background = controller.terminal?.nativeBackgroundColor ?? .windowBackgroundColor
            let tintedImage = image.isTemplate
                ? (image.withSymbolConfiguration(.init(paletteColors: [foreground])) ?? image)
                : image
            return (tintedImage, background.withAlphaComponent(1), foreground)
        }
        // Leave room around the rotated corners and their shadows.
        let size = NSSize(width: 30 + CGFloat(max(0, entries.count - 1)) * 6, height: 26)
        return NSImage(size: size, flipped: false) { _ in
            for index in entries.indices.reversed() {
                let (icon, background, foreground) = entries[index]
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: 15 + CGFloat(index) * 6, yBy: 13)
                transform.rotate(byDegrees: entries.count == 1 ? 0 : -3 + CGFloat(entries.count - 1 - index) * 5)
                transform.concat()
                let rect = NSRect(x: -12, y: -9.5, width: 24, height: 19)
                let tile = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
                shadow.shadowBlurRadius = 1
                shadow.shadowOffset = NSSize(width: 0, height: -0.5)
                shadow.set()
                background.setFill()
                tile.fill()
                NSGraphicsContext.restoreGraphicsState()
                foreground.withAlphaComponent(0.22).setStroke()
                tile.lineWidth = 0.75
                tile.stroke()
                let iconBounds = rect.insetBy(dx: 2, dy: 2)
                if icon.size.width > 0, icon.size.height > 0 {
                    let scale = min(iconBounds.width / icon.size.width, iconBounds.height / icon.size.height)
                    let iconSize = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
                    let iconRect = NSRect(x: iconBounds.midX - iconSize.width / 2,
                                          y: iconBounds.midY - iconSize.height / 2,
                                          width: iconSize.width, height: iconSize.height)
                    icon.draw(in: iconRect, from: .zero,
                              operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }
}

/// The native tab owns this view. Its width follows the visible controls.
private final class TerminalTabAccessory: NSView {
    private let zoomButton = SplitZoomButton()
    private var accessoryWidth: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: accessoryWidth, height: 20)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 20))
        addSubview(zoomButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }

    func configure(workspace: TerminalPaneWorkspace) {
        zoomButton.configure(workspace: workspace)
        let showsZoom = workspace.zoomedControllerID != nil
        let width: CGFloat = showsZoom ? 20 : 0
        zoomButton.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        if accessoryWidth != width {
            accessoryWidth = width
            invalidateIntrinsicContentSize()
        }
        setFrameSize(intrinsicContentSize)
        isHidden = width == 0
    }
}

private final class SplitZoomTitlebarAccessory: NSTitlebarAccessoryViewController {
    let control = SplitZoomTitlebarControl()

    override func loadView() {
        view = control
    }
}

private final class SplitZoomButton: NSButton {
    private weak var workspace: TerminalPaneWorkspace?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)
        imagePosition = .imageOnly
        isBordered = false
        target = self
        action = #selector(resetZoom)
        toolTip = "Reset Split Zoom"
        setAccessibilityLabel("Reset Split Zoom")
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }

    func configure(workspace: TerminalPaneWorkspace) {
        self.workspace = workspace
        isHidden = workspace.zoomedControllerID == nil
    }

    @objc private func resetZoom() {
        guard let workspace else { return }
        window?.makeKeyAndOrderFront(nil)
        workspace.clearSplitZoom()
    }
}

private final class SplitZoomTitlebarControl: NSView {
    private let button = SplitZoomButton()
    private var buttonCenterY: NSLayoutConstraint!
    private weak var workspace: TerminalPaneWorkspace?
    private var isShowingButton = false

    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: isShowingButton ? 38 : 0, height: 24)
    }

    init() {
        super.init(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        buttonCenterY = button.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            buttonCenterY
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }

    func configure(workspace: TerminalPaneWorkspace) {
        self.workspace = workspace
        button.configure(workspace: workspace)
        refreshVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshVisibility()
    }

    override func layout() {
        super.layout()
        refreshVisibility()
        guard let constant = TitlebarAccessoryAlignment.centerYConstant(for: self),
              abs(buttonCenterY.constant - constant) > 0.5 else { return }
        buttonCenterY.constant = constant
    }

    private func refreshVisibility() {
        let shouldShow = workspace?.zoomedControllerID != nil
            && window?.tabGroup?.isTabBarVisible != true
        button.isHidden = !shouldShow
        guard isShowingButton != shouldShow else { return }
        isShowingButton = shouldShow
        invalidateIntrinsicContentSize()
        setFrameSize(intrinsicContentSize)
    }
}
