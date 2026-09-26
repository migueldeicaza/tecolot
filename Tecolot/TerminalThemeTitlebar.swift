import AppKit
import SwiftUI

@MainActor
enum TerminalThemeTitlebar {
    private static let identifier = NSUserInterfaceItemIdentifier("TecolotThemePicker")

    static func configure(
        _ window: NSWindow,
        controller: TerminalSessionController?,
        profiles: ProfileStore,
        themes: ThemeStore,
        themeIndex: ThemeCatalogIndex
    ) {
        let accessory: ThemeTitlebarAccessory
        if let existing = window.titlebarAccessoryViewControllers.first(where: {
            $0.identifier == identifier
        }) as? ThemeTitlebarAccessory {
            accessory = existing
        } else {
            accessory = ThemeTitlebarAccessory()
            accessory.identifier = identifier
            accessory.layoutAttribute = .right
            window.addTitlebarAccessoryViewController(accessory)
        }
        accessory.control.configure(
            controller: controller,
            profiles: profiles,
            themes: themes,
            themeIndex: themeIndex
        )
        accessory.view.setFrameSize(accessory.control.intrinsicContentSize)
    }
}

private final class ThemeTitlebarAccessory: NSTitlebarAccessoryViewController {
    let control = ThemeTitlebarControl()

    override func loadView() {
        view = control
    }
}

final class ThemeTitlebarControl: NSView, NSPopoverDelegate {
    private let button = NSButton()
    private var buttonCenterY: NSLayoutConstraint!
    private weak var controller: TerminalSessionController?
    private weak var presentedController: TerminalSessionController?
    private weak var profiles: ProfileStore?
    private weak var themes: ThemeStore?
    private weak var themeIndex: ThemeCatalogIndex?
    private var popover: NSPopover?

    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 24) }

    init() {
        super.init(frame: .zero)
        button.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: "Theme")
        button.imagePosition = .imageOnly
        button.bezelStyle = .circular
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = #selector(togglePicker(_:))
        button.toolTip = "Change the theme of this terminal"
        button.setAccessibilityLabel("Theme")
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        if controller?.showThemePicker == true {
            showPicker()
        }
    }

    override func layout() {
        super.layout()
        guard let constant = TitlebarAccessoryAlignment.centerYConstant(for: self),
              abs(buttonCenterY.constant - constant) > 0.5 else { return }
        buttonCenterY.constant = constant
    }

    func configure(
        controller: TerminalSessionController?,
        profiles: ProfileStore,
        themes: ThemeStore,
        themeIndex: ThemeCatalogIndex
    ) {
        if self.controller !== controller {
            self.controller?.showThemePicker = false
            popover?.close()
        }
        self.controller = controller
        self.profiles = profiles
        self.themes = themes
        self.themeIndex = themeIndex
        button.isEnabled = controller != nil
        // Read the flag now. The caller runs in a queued block, and a value
        // captured before it was queued can be out of date.
        if controller?.showThemePicker == true {
            showPicker()
        } else {
            popover?.close()
        }
    }

    @objc private func togglePicker(_ sender: NSButton) {
        guard let controller else { return }
        controller.showThemePicker.toggle()
        if controller.showThemePicker {
            showPicker()
        } else {
            popover?.close()
        }
    }

    private func showPicker() {
        // A popover that is closing is not shown, but it is not closed yet.
        // popoverDidClose opens the picker again if it is still necessary.
        guard popover == nil,
              let controller, let profiles, let themes, let themeIndex,
              button.window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 520, height: 500)
        popover.contentViewController = NSHostingController(rootView: ThemePickerPopover(
            controller: controller,
            themes: themes,
            themeIndex: themeIndex,
            profiles: profiles
        ))
        presentedController = controller
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover,
              closed === popover else { return }
        presentedController?.showThemePicker = false
        presentedController = nil
        popover = nil
        // The focus moved to a different pane while this popover closed,
        // and that pane asked for its picker.
        if controller?.showThemePicker == true {
            showPicker()
        }
    }
}
