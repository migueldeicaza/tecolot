import AppKit

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

        let tabButton: SplitZoomButton
        if let existing = window.tab.accessoryView as? SplitZoomButton {
            tabButton = existing
        } else {
            tabButton = SplitZoomButton()
            tabButton.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            window.tab.accessoryView = tabButton
        }
        tabButton.configure(workspace: workspace)
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
