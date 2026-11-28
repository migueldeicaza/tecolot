import AppKit
import SwiftUI

/// Single popover owner shared across all chrome ThemeTitlebarControl buttons
/// in a window (tab bar, sidebar, content header, pane header controls),
/// ensuring at most one ThemePickerPopover can ever exist per window.
@MainActor
final class ThemePickerPopoverCoordinator: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private weak var presentedController: TerminalSessionController?
    private weak var presentedAnchor: NSView?
    /// Set when a leftMouseDown directly on `presentedAnchor` transiently
    /// dismissed the popover so the immediately following mouseUp button action
    /// closes cleanly instead of reopening.
    private var suppressNextToggle: (controller: ObjectIdentifier, timestamp: TimeInterval)?

    var isPresentingPopover: Bool {
        popover?.isShown == true
    }

    func isPresenting(from anchor: NSView) -> Bool {
        popover?.isShown == true && presentedAnchor === anchor
    }

    func toggle(
        controller: TerminalSessionController,
        profiles: ProfileStore,
        themes: ThemeStore,
        themeIndex: ThemeCatalogIndex,
        anchor: NSView?,
        attachedToWindow: Bool
    ) {
        let controllerID = ObjectIdentifier(controller)
        if let suppressed = suppressNextToggle {
            suppressNextToggle = nil
            let elapsed = (NSApp.currentEvent?.timestamp ?? suppressed.timestamp) - suppressed.timestamp
            if suppressed.controller == controllerID, elapsed >= 0, elapsed < 0.5 {
                return
            }
        }

        // If the popover for this controller is already closing (e.g. clicking
        // the button dismissed the transient popover on mouseDown right before
        // the action ran), treat this click as closing rather than reopening.
        if let existing = popover, !existing.isShown, presentedController === controller {
            clearIfNotShown()
            return
        }

        clearIfNotShown()
        controller.showThemePicker.toggle()
        if controller.showThemePicker {
            show(
                controller: controller,
                profiles: profiles,
                themes: themes,
                themeIndex: themeIndex,
                anchor: anchor
            )
            // In a live window, never leave showThemePicker stuck true without a
            // shown popover (otherwise the next click appears to do nothing).
            if attachedToWindow, !isPresentingPopover {
                controller.showThemePicker = false
            }
        } else {
            close(clearingControllerFlag: false)
        }
    }

    func synchronize(
        controller: TerminalSessionController?,
        profiles: ProfileStore,
        themes: ThemeStore,
        themeIndex: ThemeCatalogIndex,
        anchor: NSView?
    ) {
        clearIfNotShown()
        if let presented = presentedController, presented !== controller {
            close(clearingControllerFlag: true)
        }
        guard let anchor else {
            // If the anchor currently hosting the popover became hidden, dismiss cleanly.
            if let presentedAnchor, presentedAnchor.window == nil || presentedAnchor.isHiddenOrHasHiddenAncestor {
                close(clearingControllerFlag: true)
            }
            return
        }
        if controller?.showThemePicker == true, let controller {
            if let existing = popover, existing.isShown, presentedController === controller {
                // Re-anchor in place when the same pane's anchor moves (e.g.
                // sidebar crossing the narrow overflow threshold) to preserve
                // search text and scroll position.
                if presentedAnchor !== anchor {
                    presentedAnchor = anchor
                    existing.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
                }
            } else {
                if popover != nil {
                    close(clearingControllerFlag: false)
                }
                show(
                    controller: controller,
                    profiles: profiles,
                    themes: themes,
                    themeIndex: themeIndex,
                    anchor: anchor
                )
            }
        } else if popover != nil {
            close(clearingControllerFlag: false)
        }
    }

    func close(clearingControllerFlag: Bool) {
        guard let existing = popover else {
            return
        }
        let oldController = presentedController
        popover = nil
        presentedController = nil
        presentedAnchor = nil
        if clearingControllerFlag {
            oldController?.showThemePicker = false
        }
        existing.close()
    }

    private func clearIfNotShown() {
        if let existing = popover, !existing.isShown {
            // Clear the old controller's flag before dropping the popover reference,
            // because popoverDidClose will ignore `existing` once `popover` is nil.
            let oldController = presentedController
            popover = nil
            presentedController = nil
            presentedAnchor = nil
            oldController?.showThemePicker = false
        }
    }

    private func show(
        controller: TerminalSessionController,
        profiles: ProfileStore,
        themes: ThemeStore,
        themeIndex: ThemeCatalogIndex,
        anchor: NSView?
    ) {
        clearIfNotShown()
        guard popover == nil, let anchor else {
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
        self.popover = popover
        self.presentedController = controller
        self.presentedAnchor = anchor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        if !popover.isShown {
            self.popover = nil
            self.presentedController = nil
            self.presentedAnchor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard
            let closed = notification.object as? NSPopover,
            closed === popover else {
            return
        }
        let closedController = presentedController
        let anchor = presentedAnchor
        popover = nil
        presentedController = nil
        presentedAnchor = nil
        closedController?.showThemePicker = false
        if
            let closedController,
            let anchor,
            let event = NSApp.currentEvent,
            event.type == .leftMouseDown,
            event.window === anchor.window,
            anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
            suppressNextToggle = (ObjectIdentifier(closedController), event.timestamp)
        }
    }
}

final class ThemeTitlebarControl: NSView {
    private let button = ChromeIconButton(treatment: .window)
    var treatment: ChromeIconButton.Treatment {
        get { button.treatment }
        set { button.treatment = newValue }
    }
    var contentTintColor: NSColor? {
        get { button.contentTintColor }
        set { button.contentTintColor = newValue }
    }
    /// Shared per-window popover coordinator (defaults to a standalone instance for tests).
    var popoverCoordinator = ThemePickerPopoverCoordinator()
    /// Visible fallback view used when this control is collapsed into a narrow
    /// sidebar overflow menu.
    weak var fallbackAnchorView: NSView?

    private weak var controller: TerminalSessionController?
    private weak var profiles: ProfileStore?
    private weak var themes: ThemeStore?
    private weak var themeIndex: ThemeCatalogIndex?

    /// True when this control's button or fallback anchor is currently hosting the theme popover.
    var isPresentingPopover: Bool {
        if popoverCoordinator.isPresenting(from: button) {
            return true
        }
        if let fallback = fallbackAnchorView, popoverCoordinator.isPresenting(from: fallback) {
            return true
        }
        return false
    }

    var effectiveAnchorView: NSView? {
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
        guard let profiles, let themes, let themeIndex, let anchor = effectiveAnchorView else {
            return
        }
        popoverCoordinator.synchronize(
            controller: controller,
            profiles: profiles,
            themes: themes,
            themeIndex: themeIndex,
            anchor: anchor
        )
    }

    /// Convenience for window chrome views using AppModel.shared.
    func configure(controller: TerminalSessionController?) {
        let model = AppModel.shared
        configure(
            controller: controller,
            profiles: model.profiles,
            themes: model.themes,
            themeIndex: model.themeIndex
        )
    }

    func configure(
        controller: TerminalSessionController?,
        profiles: ProfileStore,
        themes: ThemeStore,
        themeIndex: ThemeCatalogIndex
    ) {
        self.controller = controller
        self.profiles = profiles
        self.themes = themes
        self.themeIndex = themeIndex
        button.isEnabled = controller != nil

        // Only synchronize the coordinator if this control is visibly anchored
        // or currently owns the open popover (e.g. while becoming hidden).
        let anchor = effectiveAnchorView
        guard anchor != nil || isPresentingPopover else {
            return
        }
        popoverCoordinator.synchronize(
            controller: controller,
            profiles: profiles,
            themes: themes,
            themeIndex: themeIndex,
            anchor: anchor
        )
    }

    @objc private func togglePicker(_ sender: NSButton) {
        guard let controller, let profiles, let themes, let themeIndex else {
            return
        }
        let attached = button.window != nil || fallbackAnchorView?.window != nil
        popoverCoordinator.toggle(
            controller: controller,
            profiles: profiles,
            themes: themes,
            themeIndex: themeIndex,
            anchor: effectiveAnchorView,
            attachedToWindow: attached
        )
    }
}
