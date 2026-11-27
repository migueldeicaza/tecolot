import AppKit
import QuartzCore
import SwiftUI

/// Floating borderless Command Palette panel (⇧⌘P), hosting `CommandPaletteView` inside a
/// glass/vibrancy `NSPanel` shell for windowing, outside-click dismissal, and keyboard/IME control.
@MainActor
final class CommandPalettePanel: NSPanel, CommandPalettePresenting, NSWindowDelegate {
    private let rootView = CommandPaletteRootView()
    private var hostingView: NSHostingView<CommandPaletteView>?

    private weak var owner: TerminalWindowController?
    private weak var manager: TerminalWindowManager?
    private weak var previousResponder: NSResponder?
    private var model: CommandPaletteModel?

    private struct PendingClickDismissal {
        let windowNumber: Int
        let eventNumber: Int
        let timestamp: TimeInterval
    }

    private var clickMonitor: Any?
    private var groupsObserver: NSObjectProtocol?
    private var closing = false
    private var topEdgeScreenY: CGFloat = 0
    private var fixedCenterX: CGFloat = 0
    private var fixedAnchorPoint: NSPoint?
    private var pendingClickDismissal: PendingClickDismissal?
    private var lastPointerScreenLocation: NSPoint?

    private let defaults: UserDefaults
    private let appModel: AppModel

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    var activeModel: CommandPaletteModel? {
        model
    }

    init(defaults: UserDefaults = .standard, appModel: AppModel = .shared) {
        self.defaults = defaults
        self.appModel = appModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: CommandPaletteMetrics.width, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .normal
        isFloatingPanel = false
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        delegate = self
        acceptsMouseMovedEvents = true
        contentView = rootView

        setAccessibilityRole(.window)
        setAccessibilitySubrole(.systemDialog)
        setAccessibilityLabel("Command Palette")
    }

    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        if let groupsObserver {
            NotificationCenter.default.removeObserver(groupsObserver)
        }
    }

    // MARK: - Presentation

    func present(
        for controller: TerminalWindowController,
        manager: TerminalWindowManager,
        initialScope: PaletteScope = .root,
        anchor: NSPoint? = nil
    ) {
        if shouldSuppressReopenForCurrentClick() {
            return
        }
        if isVisible {
            // If triggered with the same scope (e.g. ⇧⌘P toggle), dismiss cleanly.
            if case .root = initialScope, model?.isAtRoot == true {
                dismiss(restoreFocus: true)
                return
            }
            dismiss(restoreFocus: false)
        }

        owner = controller
        self.manager = manager
        previousResponder = controller.window?.firstResponder
        appearance = controller.window?.appearance
        fixedAnchorPoint = anchor

        let catalog = CommandPaletteCatalog(
            owner: controller,
            manager: manager,
            appModel: appModel,
            defaults: defaults
        )
        let paletteModel = CommandPaletteModel(
            catalog: catalog,
            mru: CommandPaletteMRU(defaults: defaults)
        )
        paletteModel.onItemsChanged = { [weak self] in
            self?.updatePanelFrame()
        }
        paletteModel.onRequestDismiss = { [weak self] restoreFocus in
            self?.dismiss(restoreFocus: restoreFocus)
        }
        model = paletteModel

        mountContent(for: paletteModel)
        computeAnchorOrigin(over: controller.window)
        ignoreStationaryPointer()
        paletteModel.reset(initialScope: initialScope)
        updatePanelFrame()

        controller.window?.addChildWindow(self, ordered: .above)
        if NSApp.isActive {
            makeKeyAndOrderFront(nil)
            paletteModel.requestFieldFocus(moveCaretToEnd: !paletteModel.query.isEmpty)
        } else {
            orderFront(nil)
        }

        installMonitors(manager: manager)
    }

    func dismiss(restoreFocus: Bool = true) {
        guard !closing else {
            return
        }
        closing = true
        recordPointerDismissalIfNeeded()
        model?.cancelDirectoryLoad()
        model?.revertPreviewIfNeeded()
        parent?.removeChildWindow(self)
        orderOut(nil)
        removeMonitors()
        if restoreFocus, let previousResponder {
            owner?.window?.makeFirstResponder(previousResponder)
        }
        closing = false
    }

    override func becomeKey() {
        super.becomeKey()
        // Wait for SwiftUI to observe that the panel became key before requesting field focus.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.firstResponder === self else {
                return
            }
            self.model?.requestFieldFocus(moveCaretToEnd: !(self.model?.query.isEmpty ?? true))
        }
    }

    private func mountContent(for paletteModel: CommandPaletteModel) {
        hostingView?.removeFromSuperview()
        let host = NSHostingView(rootView: CommandPaletteView(model: paletteModel))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = rootView.contentContainer.bounds
        host.autoresizingMask = [.width, .height]
        rootView.contentContainer.addSubview(host)
        hostingView = host
    }

    // MARK: - Monitors & Dismissal Guard

    private func installMonitors(manager: TerminalWindowManager) {
        removeMonitors()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self {
                if event.type == .leftMouseDown {
                    self.recordClickDismissal(from: event)
                }
                self.dismiss(restoreFocus: false)
            }
            return event
        }
        groupsObserver = NotificationCenter.default.addObserver(
            forName: .groupsDidChange,
            object: manager,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else {
                    return
                }
                self.model?.rebuild(preferredSelectionID: self.model?.selectedRow?.id)
            }
        }
    }

    private func removeMonitors() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let groupsObserver {
            NotificationCenter.default.removeObserver(groupsObserver)
            self.groupsObserver = nil
        }
    }

    /// Exposed for unit testing toolbar-button mouse-down -> mouse-up toggle suppression.
    func recordClickDismissal(from event: NSEvent) {
        pendingClickDismissal = PendingClickDismissal(
            windowNumber: event.windowNumber,
            eventNumber: event.eventNumber,
            timestamp: event.timestamp
        )
    }

    func shouldSuppressReopen(for event: NSEvent?) -> Bool {
        guard let event, let pending = pendingClickDismissal else {
            return false
        }
        if event.type == .leftMouseDown {
            if event.windowNumber == pending.windowNumber && abs(event.timestamp - pending.timestamp) < 0.05 {
                pendingClickDismissal = nil
                return true
            }
            pendingClickDismissal = nil
            return false
        }
        if event.type == .leftMouseUp {
            let matchesGesture = event.windowNumber == pending.windowNumber
                && event.eventNumber == pending.eventNumber
            pendingClickDismissal = nil
            return matchesGesture
        }
        pendingClickDismissal = nil
        return false
    }

    private func shouldSuppressReopenForCurrentClick() -> Bool {
        shouldSuppressReopen(for: NSApp.currentEvent)
    }

    private func recordPointerDismissalIfNeeded() {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown {
            recordClickDismissal(from: event)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !closing, isVisible else {
            return
        }
        dismiss(restoreFocus: false)
    }

    // MARK: - Positioning & Dynamic Height

    private func computeAnchorOrigin(over parentWindow: NSWindow?) {
        let width = CommandPaletteMetrics.width
        if let anchor = fixedAnchorPoint {
            fixedCenterX = anchor.x + width / 2
            topEdgeScreenY = anchor.y
            return
        }
        if let parentWindow, parentWindow.isVisible {
            fixedCenterX = parentWindow.frame.midX
            topEdgeScreenY = parentWindow.frame.maxY - CommandPaletteMetrics.topOffset
        } else if let visible = NSScreen.main?.visibleFrame {
            fixedCenterX = visible.midX
            topEdgeScreenY = visible.maxY - max(120, visible.height * 0.18)
        } else {
            fixedCenterX = 400
            topEdgeScreenY = 600
        }
    }

    private func desiredHeight() -> CGFloat {
        let headerTotal = CommandPaletteMetrics.headerTopInset
            + CommandPaletteMetrics.inputHeight
            + CommandPaletteMetrics.headerBottomInset
        let showsFooter = model?.currentScope.showsFooter ?? true
        let footerTotal: CGFloat = showsFooter ? CommandPaletteMetrics.footerHeight : 0
        let listContentHeight = (model?.items ?? []).reduce(CGFloat(0)) {
            $0 + $1.height
        }
        let listVerticalPadding = CommandPaletteMetrics.listTopPadding
            + (showsFooter
                ? CommandPaletteMetrics.listBottomPaddingWithFooter
                : CommandPaletteMetrics.listBottomPaddingWithoutFooter)
        let rawHeight = headerTotal + listContentHeight + listVerticalPadding + footerTotal
        return min(CommandPaletteMetrics.maxHeight, max(CommandPaletteMetrics.minHeight, rawHeight))
    }

    private func updatePanelFrame() {
        let width = CommandPaletteMetrics.width
        let height = desiredHeight()
        var origin = NSPoint(x: round(fixedCenterX - width / 2), y: round(topEdgeScreenY - height))

        let visible = owner?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        if let visible {
            origin.x = max(visible.minX + 8, min(visible.maxX - width - 8, origin.x))
            origin.y = max(visible.minY + 8, min(visible.maxY - height - 8, origin.y))
        }

        let targetFrame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        if frame != targetFrame {
            setFrame(targetFrame, display: true)
        }
    }

    // MARK: - Keyboard, Pointer & IME Handling

    private func ignoreStationaryPointer() {
        lastPointerScreenLocation = NSEvent.mouseLocation
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved {
            let screenLocation = NSEvent.mouseLocation
            let moved = lastPointerScreenLocation.map {
                abs(screenLocation.x - $0.x) >= 0.5 || abs(screenLocation.y - $0.y) >= 0.5
            } ?? true
            if moved {
                lastPointerScreenLocation = screenLocation
                model?.pointerMoved()
            }
        }
        if event.type == .keyDown, handleKeyDown(event) {
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "p" {
            dismiss(restoreFocus: true)
            return true
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            return handleGoToDirectoryShortcut()
        }
        if flags == .command, event.charactersIgnoringModifiers == "." {
            model?.cancelAndDismiss()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleGoToDirectoryShortcut() -> Bool {
        if case .directoryPicker = model?.currentScope {
            dismiss(restoreFocus: true)
        } else {
            model?.reset(initialScope: .directoryPicker(initialPath: nil))
        }
        return true
    }

    /// Exposed for unit testing with synthetic NSEvents.
    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "p" {
            dismiss(restoreFocus: true)
            return true
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            return handleGoToDirectoryShortcut()
        }
        if flags == .command, event.charactersIgnoringModifiers == "." {
            model?.cancelAndDismiss()
            return true
        }

        // Always consume Tab and Shift-Tab so focus never leaves the search field.
        if event.keyCode == 48 {
            if flags.isEmpty {
                _ = model?.tabComplete()
                return true
            }
            if flags == .shift {
                return true
            }
        }

        // Ctrl+N / Ctrl+P navigation
        if flags == .control {
            if event.charactersIgnoringModifiers?.lowercased() == "n" {
                moveSelection(by: 1)
                return true
            }
            if event.charactersIgnoringModifiers?.lowercased() == "p" {
                moveSelection(by: -1)
                return true
            }
        }

        guard flags.isEmpty else {
            return false
        }

        switch event.keyCode {
        case 53: // Escape
            model?.handleEscape()
            return true
        case 125: // Down Arrow
            moveSelection(by: 1)
            return true
        case 126: // Up Arrow
            moveSelection(by: -1)
            return true
        case 116: // Page Up
            moveSelectionByPage(-1)
            return true
        case 121: // Page Down
            moveSelectionByPage(1)
            return true
        case 115: // Home
            guard model?.currentScope.isTextEntryScope != true else {
                return false
            }
            selectFirst()
            return true
        case 119: // End
            guard model?.currentScope.isTextEntryScope != true else {
                return false
            }
            selectLast()
            return true
        case 36, 76: // Return / Enter
            model?.executeSelected()
            return true
        case 51: // Backspace on empty input pops scope chip
            if model?.query.isEmpty == true, model?.handleBackspaceOnEmpty() == true {
                return true
            }
            return false
        default:
            return false
        }
    }

    override func cancelOperation(_ sender: Any?) {
        model?.handleEscape()
    }

    private func moveSelection(by delta: Int) {
        ignoreStationaryPointer()
        model?.moveSelection(by: delta)
    }

    private func moveSelectionByPage(_ direction: Int) {
        ignoreStationaryPointer()
        model?.moveSelectionByPage(direction)
    }

    private func selectFirst() {
        ignoreStationaryPointer()
        model?.selectFirst()
    }

    private func selectLast() {
        ignoreStationaryPointer()
        model?.selectLast()
    }
}

// MARK: - Root Glass / Vibrancy Surface

@MainActor
private final class CommandPaletteRootView: NSView {
    let contentContainer = NSView()
    private let backgroundView: NSView
    private let borderLayer = CALayer()

    override init(frame: NSRect) {
        let radius = CommandPaletteMetrics.cornerRadius
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = radius
            glass.contentView = contentContainer
            backgroundView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = radius
            material.layer?.masksToBounds = true
            let side = radius * 2 + 1
            let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            mask.resizingMode = .stretch
            material.maskImage = mask
            material.addSubview(contentContainer)
            backgroundView = material
        }

        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true

        backgroundView.frame = bounds
        backgroundView.autoresizingMask = [.width, .height]
        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.width, .height]
        addSubview(backgroundView)

        borderLayer.cornerRadius = radius
        borderLayer.borderWidth = 1
        layer?.addSublayer(borderLayer)
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            layer?.backgroundColor = reduceTransparency ? NSColor.windowBackgroundColor.cgColor : NSColor.clear.cgColor
            borderLayer.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        }
    }
}
