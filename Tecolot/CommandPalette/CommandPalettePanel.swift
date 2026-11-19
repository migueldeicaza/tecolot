import AppKit
import QuartzCore

/// Floating borderless Command Palette panel (⇧⌘P), following Rex's geometry and Tecolot's glass/vibrancy conventions.
@MainActor
final class CommandPalettePanel: NSPanel, CommandPalettePresenting, NSWindowDelegate,
NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private let rootView = CommandPaletteRootView()
    private let headerView = CommandPaletteHeaderView()
    private let scrollView = NSScrollView()
    private let tableView = CommandPaletteTableView()
    private let footerView = CommandPaletteFooterView()

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

    private let defaults: UserDefaults
    private let appModel: AppModel

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    var inputField: NSTextField {
        headerView.textField
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

        headerView.textField.delegate = self
        headerView.onClear = { [weak self] in
            self?.clearInput()
        }
        headerView.onChipClick = { [weak self] in
            self?.model?.pop()
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("palette"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clickRow)
        tableView.setAccessibilityLabel("Command Palette Results")
        tableView.onHover = { [weak self] rowIndex in
            self?.handleHover(at: rowIndex)
        }

        scrollView.documentView = tableView
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = true

        rootView.contentContainer.addSubview(headerView)
        rootView.contentContainer.addSubview(scrollView)
        rootView.contentContainer.addSubview(footerView)

        rootView.onAppearanceChange = { [weak self] in
            self?.refreshStyling()
        }

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
            self?.reloadTableAndResize()
        }
        paletteModel.onScopeChanged = { [weak self] in
            self?.syncHeaderFromModel()
        }
        paletteModel.onQueryReplaced = { [weak self] newText in
            self?.applyQueryText(newText, moveCaretToEnd: true)
        }
        paletteModel.onRequestDismiss = { [weak self] restoreFocus in
            self?.dismiss(restoreFocus: restoreFocus)
        }
        model = paletteModel

        computeAnchorOrigin(over: controller.window)
        tableView.ignoreStationaryPointer()
        paletteModel.reset(initialScope: initialScope)
        syncHeaderFromModel()
        reloadTableAndResize()

        controller.window?.addChildWindow(self, ordered: .above)
        if NSApp.isActive {
            makeKeyAndOrderFront(nil)
            focusInput(moveCaretToEnd: !headerView.textField.stringValue.isEmpty)
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
        let footerTotal: CGFloat = (model?.currentScope.showsFooter ?? true) ? CommandPaletteMetrics.footerHeight : 0
        let listContentHeight = (model?.items ?? []).reduce(CGFloat(0)) {
            $0 + $1.height
        }
        let listVerticalPadding: CGFloat = 10
        let rawHeight = headerTotal + listContentHeight + listVerticalPadding + footerTotal
        return min(CommandPaletteMetrics.maxHeight, max(CommandPaletteMetrics.minHeight, rawHeight))
    }

    private func layoutAndResize() {
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

        let bounds = rootView.contentContainer.bounds
        let headerHeight = CommandPaletteMetrics.headerTopInset
            + CommandPaletteMetrics.inputHeight
            + CommandPaletteMetrics.headerBottomInset
        let showsFooter = model?.currentScope.showsFooter ?? true
        let footerHeight: CGFloat = showsFooter ? CommandPaletteMetrics.footerHeight : 0

        headerView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        footerView.isHidden = !showsFooter
        footerView.frame = NSRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: footerHeight)
        let scrollTop = headerHeight + 2
        let scrollBottomPadding: CGFloat = showsFooter ? 4 : 6
        scrollView.frame = NSRect(
            x: 0,
            y: scrollTop,
            width: bounds.width,
            height: max(0, bounds.height - scrollTop - footerHeight - scrollBottomPadding)
        )
        let contentWidth = scrollView.contentView.bounds.width
        if abs(tableView.frame.width - contentWidth) > 0.5 {
            tableView.frame.size.width = contentWidth
        }
        tableView.sizeLastColumnToFit()
    }

    private func syncHeaderFromModel() {
        guard let model else {
            return
        }
        headerView.configure(
            chipTitle: model.currentScope.chipTitle,
            placeholder: model.currentScope.placeholder,
            text: model.query
        )
        focusInput(moveCaretToEnd: !model.query.isEmpty)
    }

    private func applyQueryText(_ text: String, moveCaretToEnd: Bool) {
        headerView.setText(text)
        focusInput(moveCaretToEnd: moveCaretToEnd)
    }

    private func focusInput(moveCaretToEnd: Bool) {
        guard isVisible, NSApp.isActive else {
            return
        }
        makeFirstResponder(headerView.textField)
        if moveCaretToEnd, let editor = headerView.textField.currentEditor() as? NSTextView {
            let end = (headerView.textField.stringValue as NSString).length
            editor.selectedRange = NSRange(location: end, length: 0)
        }
    }

    private func clearInput() {
        headerView.setText("")
        model?.setQuery("")
        focusInput(moveCaretToEnd: false)
    }

    private func reloadTableAndResize() {
        layoutAndResize()
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        if let selected = model?.selectedIndex {
            scrollRowToVisibleImmediately(selected)
            tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        footerView.setActionEnabled(model?.selectedRow != nil)
    }

    private func refreshStyling() {
        rootView.refreshAppearance()
        headerView.refreshAppearance()
        footerView.refreshAppearance()
        tableView.reloadData()
        if let selected = model?.selectedIndex {
            tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
    }

    // MARK: - Keyboard & IME Handling

    override func sendEvent(_ event: NSEvent) {
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
        if let editor = headerView.textField.currentEditor() as? NSTextView, editor.hasMarkedText() {
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
        case 36, 76: // Return / Enter
            model?.executeSelected()
            return true
        case 51: // Backspace on empty input pops scope chip
            if headerView.textField.stringValue.isEmpty, model?.handleBackspaceOnEmpty() == true {
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
        guard let model else {
            return
        }
        tableView.ignoreStationaryPointer()
        model.moveSelection(by: delta)
        if let selected = model.selectedIndex {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrollRowToVisibleImmediately(selected)
            tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            tableView.layoutSubtreeIfNeeded()
            CATransaction.commit()
        }
        footerView.setActionEnabled(model.selectedRow != nil)
    }

    /// Scrolls synchronously without AppKit's multi-frame scrollRowToVisible animation so the
    /// selection pill never disappears offscreen or clips halfway behind the footer during key repeat.
    private func scrollRowToVisibleImmediately(_ row: Int) {
        let rowRect = tableView.rect(ofRow: row)
        guard !rowRect.isEmpty else {
            return
        }
        let clipView = scrollView.contentView
        let visible = clipView.bounds
        let maxY = max(0, tableView.bounds.height - visible.height)
        var targetY = visible.origin.y
        if rowRect.minY < visible.minY {
            targetY = rowRect.minY
        } else if rowRect.maxY > visible.maxY {
            targetY = rowRect.maxY - visible.height
        } else {
            return
        }
        targetY = max(0, min(maxY, targetY))
        guard abs(targetY - visible.origin.y) > 0.5 else {
            return
        }
        clipView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        tableView.layoutSubtreeIfNeeded()
    }

    private func handleHover(at rowIndex: Int) {
        guard let model, model.items.indices.contains(rowIndex), model.items[rowIndex].isSelectable else {
            return
        }
        guard model.selectedIndex != rowIndex else {
            return
        }
        model.selectIndex(rowIndex, triggerPreview: true)
        tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        footerView.setActionEnabled(model.selectedRow != nil)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        let text = headerView.textField.stringValue
        headerView.updateClearButtonVisibility()
        model?.setQuery(text)
    }

    // MARK: - NSTableViewDataSource & Delegate

    private static let sectionHeaderID = NSUserInterfaceItemIdentifier("palette.sectionHeader")
    private static let dividerID = NSUserInterfaceItemIdentifier("palette.divider")
    private static let hintID = NSUserInterfaceItemIdentifier("palette.hint")
    private static let standardRowID = NSUserInterfaceItemIdentifier("palette.standard")
    private static let twoLineRowID = NSUserInterfaceItemIdentifier("palette.twoLine")

    func numberOfRows(in tableView: NSTableView) -> Int {
        model?.items.count ?? 0
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let items = model?.items, items.indices.contains(row) else {
            return CommandPaletteMetrics.rowHeight
        }
        return items[row].height
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard let items = model?.items, items.indices.contains(row) else {
            return false
        }
        return items[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CommandPaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let items = model?.items, items.indices.contains(row) else {
            return nil
        }
        let isSelected = model?.selectedIndex == row
        switch items[row] {
        case .sectionHeader(let title):
            let cell = (tableView.makeView(withIdentifier: Self.sectionHeaderID, owner: self) as? CommandPaletteSectionHeaderCell)
                ?? {
                    let created = CommandPaletteSectionHeaderCell()
                    created.identifier = Self.sectionHeaderID
                    return created
                }()
            cell.configure(title: title)
            return cell
        case .divider:
            let cell = (tableView.makeView(withIdentifier: Self.dividerID, owner: self) as? CommandPaletteDividerCell)
                ?? {
                    let created = CommandPaletteDividerCell()
                    created.identifier = Self.dividerID
                    return created
                }()
            return cell
        case .hint(let message):
            let cell = (tableView.makeView(withIdentifier: Self.hintID, owner: self) as? CommandPaletteHintCell)
                ?? {
                    let created = CommandPaletteHintCell()
                    created.identifier = Self.hintID
                    return created
                }()
            cell.configure(message: message)
            return cell
        case .row(let rowModel):
            switch rowModel.style {
            case .standard:
                let cell = (tableView.makeView(withIdentifier: Self.standardRowID, owner: self) as? CommandPaletteStandardRowCell)
                    ?? {
                        let created = CommandPaletteStandardRowCell()
                        created.identifier = Self.standardRowID
                        return created
                    }()
                cell.configure(row: rowModel, selected: isSelected)
                return cell
            case .twoLine:
                let cell = (tableView.makeView(withIdentifier: Self.twoLineRowID, owner: self) as? CommandPaletteTwoLineRowCell)
                    ?? {
                        let created = CommandPaletteTwoLineRowCell()
                        created.identifier = Self.twoLineRowID
                        return created
                    }()
                cell.configure(row: rowModel, selected: isSelected)
                return cell
            }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = tableView.selectedRow
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else {
            return
        }
        for rowIndex in visible.location..<(visible.location + visible.length) {
            if let cell = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? CommandPaletteSelectableCell {
                cell.updateSelection(rowIndex == selected)
            }
        }
    }

    @objc private func clickRow() {
        let clicked = tableView.clickedRow
        guard clicked >= 0 else {
            return
        }
        model?.execute(at: clicked)
    }
}

// MARK: - Root Glass / Vibrancy Surface

@MainActor
private final class CommandPaletteRootView: NSView {
    var onAppearanceChange: (() -> Void)?
    let contentContainer = FlippedContainerView()
    private let backgroundView: NSView
    private let borderLayer = CALayer()

    override var isFlipped: Bool {
        true
    }

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
        onAppearanceChange?()
    }

    func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            layer?.backgroundColor = reduceTransparency ? NSColor.windowBackgroundColor.cgColor : NSColor.clear.cgColor
            borderLayer.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        }
    }
}

private final class FlippedContainerView: NSView {
    override var isFlipped: Bool {
        true
    }
}

// MARK: - Header (Search Pill + Scope Chip + Clear Button)

@MainActor
private final class CommandPaletteHeaderView: NSView {
    private let pill = FlippedContainerView()
    private let searchIcon = NSImageView()
    private let chipButton = NSButton()
    private let chipLabel = NSTextField(labelWithString: "")
    let textField = NSTextField()
    private let clearButton = NSButton()

    var onClear: (() -> Void)?
    var onChipClick: (() -> Void)?

    private var chipTitle: String?
    private let chipFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private let fieldFont = NSFont.systemFont(ofSize: 13.5)

    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        pill.wantsLayer = true
        pill.layer?.cornerRadius = CommandPaletteMetrics.inputCornerRadius
        addSubview(pill)

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        searchIcon.contentTintColor = .labelColor
        pill.addSubview(searchIcon)

        chipButton.isBordered = false
        chipButton.title = ""
        chipButton.wantsLayer = true
        chipButton.layer?.cornerRadius = 7
        chipButton.target = self
        chipButton.action = #selector(chipTapped)
        chipButton.isHidden = true
        chipButton.toolTip = "Press Backspace or click to return"
        pill.addSubview(chipButton)

        chipLabel.font = chipFont
        chipLabel.textColor = .labelColor
        chipLabel.alignment = .center
        chipLabel.lineBreakMode = .byTruncatingTail
        chipLabel.setAccessibilityElement(false)
        chipButton.addSubview(chipLabel)

        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = fieldFont
        textField.textColor = .labelColor
        textField.lineBreakMode = .byTruncatingHead
        textField.cell?.usesSingleLineMode = true
        textField.cell?.isScrollable = true
        textField.setAccessibilityLabel("Command Palette Search")
        pill.addSubview(textField)

        clearButton.isBordered = false
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear search")
        clearButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.isHidden = true
        pill.addSubview(clearButton)

        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(chipTitle: String?, placeholder: String, text: String) {
        self.chipTitle = chipTitle
        textField.stringValue = text
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: fieldFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        if let chipTitle {
            searchIcon.isHidden = true
            chipButton.isHidden = false
            chipLabel.stringValue = chipTitle
            chipButton.setAccessibilityLabel("Scope: \(chipTitle)")
        } else {
            searchIcon.isHidden = false
            chipButton.isHidden = true
        }
        updateClearButtonVisibility()
        needsLayout = true
    }

    func setText(_ text: String) {
        textField.stringValue = text
        updateClearButtonVisibility()
    }

    func updateClearButtonVisibility() {
        clearButton.isHidden = textField.stringValue.isEmpty
        needsLayout = true
    }

    func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            chipButton.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor
        }
    }

    override func layout() {
        super.layout()
        let inset = CommandPaletteMetrics.horizontalInset
        pill.frame = NSRect(
            x: inset,
            y: CommandPaletteMetrics.headerTopInset,
            width: bounds.width - inset * 2,
            height: CommandPaletteMetrics.inputHeight
        )

        let pillBounds = pill.bounds
        let fieldHeight = max(17, ceil(textField.intrinsicContentSize.height))
        let fieldY = round((pillBounds.height - fieldHeight) / 2)

        let leadingX: CGFloat
        if let chipTitle, !chipTitle.isEmpty {
            chipLabel.sizeToFit()
            let labelWidth = ceil(chipLabel.frame.width)
            let labelHeight = ceil(chipLabel.frame.height)
            let chipWidth = min(164, labelWidth + 14)
            let chipHeight: CGFloat = 22
            let chipY = round((pillBounds.height - chipHeight) / 2)
            chipButton.frame = NSRect(
                x: 6,
                y: chipY,
                width: chipWidth,
                height: chipHeight
            )
            // Align chip text baseline to the input text field baseline.
            let targetBaselineInPill = fieldY + fieldFont.ascender
            let labelYInChip = round(targetBaselineInPill - chipFont.ascender - chipY)
            chipLabel.frame = NSRect(
                x: 4,
                y: labelYInChip,
                width: max(0, chipWidth - 8),
                height: labelHeight
            )
            leadingX = chipButton.frame.maxX + 7
        } else {
            searchIcon.frame = NSRect(x: 9, y: round((pillBounds.height - 16) / 2), width: 16, height: 16)
            leadingX = searchIcon.frame.maxX + 7
        }

        let trailingPadding: CGFloat
        if clearButton.isHidden {
            trailingPadding = 10
        } else {
            clearButton.frame = NSRect(
                x: pillBounds.width - 26,
                y: round((pillBounds.height - 18) / 2),
                width: 18,
                height: 18
            )
            trailingPadding = 30
        }

        textField.frame = NSRect(
            x: leadingX,
            y: fieldY,
            width: max(40, pillBounds.width - leadingX - trailingPadding),
            height: fieldHeight
        )
    }

    @objc private func clearTapped() {
        onClear?()
    }

    @objc private func chipTapped() {
        onChipClick?()
    }
}

// MARK: - Footer (Action [↩])

@MainActor
private final class CommandPaletteFooterView: NSView {
    private let separator = NSView()
    private let actionLabel = NSTextField(labelWithString: "Action")
    private let keycap = NSView()
    private let keycapGlyph = NSImageView()

    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        separator.wantsLayer = true
        addSubview(separator)

        actionLabel.font = .systemFont(ofSize: 12)
        actionLabel.textColor = .secondaryLabelColor
        addSubview(actionLabel)

        keycap.wantsLayer = true
        keycap.layer?.cornerRadius = 5
        keycap.layer?.borderWidth = 1
        addSubview(keycap)

        keycapGlyph.image = NSImage(systemSymbolName: "return", accessibilityDescription: "Return")
        keycapGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        keycapGlyph.contentTintColor = .secondaryLabelColor
        keycap.addSubview(keycapGlyph)

        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setActionEnabled(_ enabled: Bool) {
        let alpha: CGFloat = enabled ? 1.0 : 0.42
        actionLabel.alphaValue = alpha
        keycap.alphaValue = alpha
    }

    func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            separator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
            keycap.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
            keycap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor
        }
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        let keycapSize = NSSize(width: 22, height: 18)
        keycap.frame = NSRect(
            x: bounds.width - 12 - keycapSize.width,
            y: round((bounds.height - keycapSize.height) / 2),
            width: keycapSize.width,
            height: keycapSize.height
        )
        keycapGlyph.frame = NSRect(x: 4, y: 2, width: 14, height: 14)

        actionLabel.sizeToFit()
        actionLabel.frame = NSRect(
            x: keycap.frame.minX - 6 - actionLabel.frame.width,
            y: round((bounds.height - actionLabel.frame.height) / 2),
            width: actionLabel.frame.width,
            height: actionLabel.frame.height
        )
    }
}

// MARK: - Table View & Inset Pill Selection

@MainActor
private final class CommandPaletteTableView: NSTableView {
    var onHover: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    private var lastHoverScreenLocation: NSPoint?

    func ignoreStationaryPointer() {
        lastHoverScreenLocation = NSEvent.mouseLocation
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let screenLocation = NSEvent.mouseLocation
        if
            let last = lastHoverScreenLocation,
            abs(screenLocation.x - last.x) < 0.5 && abs(screenLocation.y - last.y) < 0.5 {
            return
        }
        lastHoverScreenLocation = screenLocation
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        if index >= 0 {
            onHover?(index)
        }
    }
}

@MainActor
private final class CommandPaletteRowView: NSTableRowView {
    private let pillView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        pillView.wantsLayer = true
        pillView.layer?.cornerRadius = CommandPaletteMetrics.selectionPillCornerRadius
        pillView.isHidden = true
        addSubview(pillView, positioned: .below, relativeTo: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isSelected: Bool {
        didSet {
            guard oldValue != isSelected else {
                return
            }
            updatePillAppearance()
            if numberOfColumns > 0, let cell = view(atColumn: 0) as? CommandPaletteSelectableCell {
                cell.updateSelection(isSelected)
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = CommandPaletteMetrics.horizontalInset
        let width = min(bounds.width, CommandPaletteMetrics.width)
        pillView.frame = NSRect(
            x: inset,
            y: 1,
            width: max(0, width - inset * 2),
            height: max(0, bounds.height - 2)
        )
        CATransaction.commit()
        updatePillAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePillAppearance()
    }

    private func updatePillAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillView.isHidden = !isSelected
        if isSelected {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                pillView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            }
        }
        CATransaction.commit()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Rendered by layer-backed pillView for tear-free scrolling.
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }
}

// MARK: - Row Cells

@MainActor
private protocol CommandPaletteSelectableCell: NSView {
    func updateSelection(_ selected: Bool)
}

@MainActor
private final class CommandPaletteSectionHeaderCell: NSView {
    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String) {
        label.stringValue = title
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 18, y: 6, width: bounds.width - 36, height: 15)
    }
}

@MainActor
private final class CommandPaletteDividerCell: NSView {
    private let line = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.wantsLayer = true
        addSubview(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        line.frame = NSRect(x: 12, y: floor(bounds.midY), width: max(0, bounds.width - 24), height: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        }
    }
}

@MainActor
private final class CommandPaletteHintCell: NSView {
    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(message: String) {
        label.stringValue = message
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame = NSRect(
            x: 16,
            y: round((bounds.height - label.frame.height) / 2),
            width: max(0, bounds.width - 32),
            height: label.frame.height
        )
    }
}

@MainActor
private final class CommandPaletteStandardRowCell: NSView, CommandPaletteSelectableCell {
    private var row: PaletteRow?
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let accessoryIcon = NSImageView()
    private var hasIcon = false
    private var hasAccessoryIcon = false

    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = true
        addSubview(iconView)

        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.alignment = .right
        addSubview(detailLabel)

        accessoryIcon.imageScaling = .scaleProportionallyDown
        addSubview(accessoryIcon)

        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(row: PaletteRow, selected: Bool) {
        self.row = row
        if case .standard(_, let icon, _) = row.style, let icon {
            hasIcon = true
            iconView.image = icon
            iconView.isHidden = false
        } else {
            hasIcon = false
            iconView.image = nil
            iconView.isHidden = true
        }
        setAccessibilityLabel(row.title)
        updateSelection(selected)
        if bounds.width > 0 {
            layout()
        } else {
            needsLayout = true
        }
    }

    func updateSelection(_ selected: Bool) {
        guard let row else {
            return
        }
        let baseColor: NSColor = selected ? .white : .labelColor
        let highlightColor: NSColor = selected ? .white : .controlAccentColor
        let secondaryColor: NSColor = selected ? NSColor.white.withAlphaComponent(0.9) : .secondaryLabelColor

        titleLabel.attributedStringValue = CommandPaletteSearch.attributedString(
            row.title,
            matchRanges: row.matchRanges,
            font: .systemFont(ofSize: 13, weight: .regular),
            highlightFont: .systemFont(ofSize: 13, weight: .semibold),
            baseColor: baseColor,
            highlightColor: highlightColor
        )

        if case .standard(_, _, let accessory) = row.style {
            applyAccessory(accessory, primaryColor: baseColor, secondaryColor: secondaryColor)
        }
    }

    private func applyAccessory(_ accessory: PaletteRowAccessory, primaryColor: NSColor, secondaryColor: NSColor) {
        detailLabel.stringValue = ""
        detailLabel.isHidden = true
        accessoryIcon.image = nil
        accessoryIcon.isHidden = true
        hasAccessoryIcon = false

        switch accessory {
        case .none:
            break
        case .shortcut(let shortcut):
            detailLabel.stringValue = shortcut
            detailLabel.font = .systemFont(ofSize: 12.5)
            detailLabel.textColor = secondaryColor
            detailLabel.isHidden = false
        case .status(let text):
            detailLabel.stringValue = text
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = secondaryColor
            detailLabel.isHidden = false
        case .checkmark:
            accessoryIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")
            accessoryIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
            accessoryIcon.contentTintColor = primaryColor
            accessoryIcon.isHidden = false
            hasAccessoryIcon = true
        case .returnGlyph:
            accessoryIcon.image = NSImage(systemSymbolName: "return", accessibilityDescription: "Return")
            accessoryIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .medium)
            accessoryIcon.contentTintColor = primaryColor
            accessoryIcon.isHidden = false
            hasAccessoryIcon = true
        case .chevron(let detail, let shortcut):
            if let text = shortcut ?? detail, !text.isEmpty {
                detailLabel.stringValue = text
                detailLabel.font = .systemFont(ofSize: shortcut != nil ? 12.5 : 12)
                detailLabel.textColor = secondaryColor
                detailLabel.isHidden = false
            }
            accessoryIcon.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "More options")
            accessoryIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
            accessoryIcon.contentTintColor = primaryColor
            accessoryIcon.isHidden = false
            hasAccessoryIcon = true
        }
    }

    override func layout() {
        super.layout()
        let leftPad: CGFloat = 18
        var leftX = leftPad
        if hasIcon {
            iconView.frame = NSRect(x: leftPad, y: round((bounds.height - 16) / 2), width: 16, height: 16)
            leftX = iconView.frame.maxX + 8
        }

        var rightX = bounds.width - 18
        if hasAccessoryIcon {
            let iconW: CGFloat = 14
            accessoryIcon.frame = NSRect(x: rightX - iconW, y: round((bounds.height - 14) / 2), width: iconW, height: 14)
            rightX = accessoryIcon.frame.minX - 6
        }

        if !detailLabel.isHidden {
            detailLabel.sizeToFit()
            let detailWidth = min(130, ceil(detailLabel.frame.width))
            detailLabel.frame = NSRect(
                x: rightX - detailWidth,
                y: round((bounds.height - detailLabel.frame.height) / 2),
                width: detailWidth,
                height: detailLabel.frame.height
            )
            rightX = detailLabel.frame.minX - 8
        }

        let titleHeight: CGFloat = 17
        titleLabel.frame = NSRect(
            x: leftX,
            y: round((bounds.height - titleHeight) / 2),
            width: max(20, rightX - leftX),
            height: titleHeight
        )
    }
}

@MainActor
private final class CommandPaletteTwoLineRowCell: NSView, CommandPaletteSelectableCell {
    private var row: PaletteRow?
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let checkmarkView = NSImageView()
    private var showsCheckmark = false

    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        checkmarkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Active")
        checkmarkView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
        checkmarkView.isHidden = true
        addSubview(checkmarkView)

        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(row: PaletteRow, selected: Bool) {
        self.row = row
        if case .twoLine(_, _, let icon, let accessory) = row.style {
            iconView.image = icon ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            showsCheckmark = accessory == .checkmark
            checkmarkView.isHidden = !showsCheckmark
        }
        setAccessibilityLabel("\(row.title), \(row.subtitle ?? "")")
        updateSelection(selected)
        if bounds.width > 0 {
            layout()
        } else {
            needsLayout = true
        }
    }

    func updateSelection(_ selected: Bool) {
        guard let row else {
            return
        }
        let baseColor: NSColor = selected ? .white : .labelColor
        let highlightColor: NSColor = selected ? .white : .controlAccentColor
        let subColor: NSColor = selected ? NSColor.white.withAlphaComponent(0.86) : .secondaryLabelColor

        titleLabel.attributedStringValue = CommandPaletteSearch.attributedString(
            row.title,
            matchRanges: row.matchRanges,
            font: .systemFont(ofSize: 13, weight: .regular),
            highlightFont: .systemFont(ofSize: 13, weight: .semibold),
            baseColor: baseColor,
            highlightColor: highlightColor
        )

        subtitleLabel.attributedStringValue = CommandPaletteSearch.attributedString(
            row.subtitle ?? "",
            matchRanges: row.subtitleMatchRanges,
            font: .systemFont(ofSize: 11.5, weight: .regular),
            highlightFont: .systemFont(ofSize: 11.5, weight: .semibold),
            baseColor: subColor,
            highlightColor: highlightColor
        )

        if showsCheckmark {
            checkmarkView.contentTintColor = baseColor
        }
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 18, y: round((bounds.height - 20) / 2), width: 20, height: 20)
        var rightX = bounds.width - 18
        if showsCheckmark {
            checkmarkView.frame = NSRect(x: rightX - 14, y: round((bounds.height - 14) / 2), width: 14, height: 14)
            rightX = checkmarkView.frame.minX - 8
        }
        let textX = iconView.frame.maxX + 10
        let textW = max(20, rightX - textX)
        titleLabel.frame = NSRect(x: textX, y: 6, width: textW, height: 16)
        subtitleLabel.frame = NSRect(x: textX, y: 23, width: textW, height: 15)
    }
}
