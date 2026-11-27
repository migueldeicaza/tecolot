import AppKit
import SwiftUI

final class ThemeTitlebarControl: NSView, NSPopoverDelegate {
    private let button = ChromeIconButton(treatment: .window)
    var treatment: ChromeIconButton.Treatment {
        get { button.treatment }
        set { button.treatment = newValue }
    }
    var contentTintColor: NSColor? {
        get { button.contentTintColor }
        set { button.contentTintColor = newValue }
    }
    private weak var controller: TerminalSessionController?
    private weak var presentedController: TerminalSessionController?
    private weak var profiles: ProfileStore?
    private weak var themes: ThemeStore?
    private weak var themeIndex: ThemeCatalogIndex?
    /// Visible fallback view used when this control is collapsed into a narrow
    /// sidebar overflow menu.
    weak var fallbackAnchorView: NSView?
    private var popover: NSPopover?

    /// True when this control (or its fallback overflow anchor) is visibly
    /// hosted in a window and eligible to present the theme popover.
    var isPresentingPopover: Bool {
        popover?.isShown == true
    }

    private var effectiveAnchorView: NSView? {
        if button.window != nil, !button.isHiddenOrHasHiddenAncestor, !button.bounds.isEmpty {
            return button
        }
        if let fallback = fallbackAnchorView,
           fallback.window != nil, !fallback.isHiddenOrHasHiddenAncestor, !fallback.bounds.isEmpty {
            return fallback
        }
        return nil
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: 38, height: 24)
    }

    init() {
        super.init(frame: .zero)
        button.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: "Theme")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePicker(_:))
        button.toolTip = "Change the theme of this terminal"
        button.setAccessibilityLabel("Theme")
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }

    /// Opens the picker from a compact sidebar's actions menu.
    func presentPicker() {
        togglePicker(button)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        if controller?.showThemePicker == true, effectiveAnchorView != nil {
            showPicker()
        }
    }

    func configure(
        controller: TerminalSessionController?,
        profiles: ProfileStore,
        themes: ThemeStore,
        themeIndex: ThemeCatalogIndex
    ) {
        if self.controller !== controller {
            // Only the control that actually owns an open popover should clear
            // the old controller's flag; hidden sibling controls must not stomp it.
            if let existing = popover {
                popover = nil
                presentedController = nil
                self.controller?.showThemePicker = false
                existing.close()
            }
        }
        self.controller = controller
        self.profiles = profiles
        self.themes = themes
        self.themeIndex = themeIndex
        button.isEnabled = controller != nil
        // Hidden sibling controls (e.g. sidebar when tabs are on top, or
        // ContentHeader / PaneWindowControls when inactive) must never present
        // competing transient popovers.
        guard effectiveAnchorView != nil else {
            if let existing = popover {
                let oldController = presentedController
                popover = nil
                presentedController = nil
                oldController?.showThemePicker = false
                existing.close()
            }
            return
        }
        // Read the flag now. The caller runs in a queued block, and a value
        // captured before it was queued can be out of date.
        if controller?.showThemePicker == true {
            showPicker()
        } else {
            popover?.close()
        }
    }

    @objc private func togglePicker(_ sender: NSButton) {
        guard let controller else {
            return
        }
        if let existing = popover, !existing.isShown {
            popover = nil
            presentedController = nil
        }
        controller.showThemePicker.toggle()
        if controller.showThemePicker {
            showPicker()
        } else {
            popover?.close()
        }
    }

    private func showPicker() {
        if let existing = popover, !existing.isShown {
            popover = nil
            presentedController = nil
        }
        // A popover that is closing is not shown, but it is not closed yet.
        // popoverDidClose opens the picker again if it is still necessary.
        guard
            popover == nil,
            let controller, let profiles, let themes, let themeIndex,
            let anchor = effectiveAnchorView else {
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 520, height: 500)
        popover.contentViewController = NSHostingController(rootView: ThemePickerPopover(
            controller: controller,
            themes: themes,
            themeIndex: themeIndex,
            profiles: profiles,
            systemAppearance: AppModel.shared.systemAppearance
        ))
        presentedController = controller
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        if !popover.isShown {
            self.popover = nil
            self.presentedController = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard
            let closed = notification.object as? NSPopover,
            closed === popover else {
            return
        }
        presentedController?.showThemePicker = false
        presentedController = nil
        popover = nil
        // The focus moved to a different pane while this popover closed,
        // and that pane asked for its picker.
        if controller?.showThemePicker == true, effectiveAnchorView != nil {
            showPicker()
        }
    }
}
