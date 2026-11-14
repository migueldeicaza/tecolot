import AppKit

/// A transient dismissal and its button action can belong to the same mouse-down.
nonisolated struct GroupSwitcherDismissal {
    private var pointerTimestamp: TimeInterval?

    mutating func record(pointerTimestamp: TimeInterval?) {
        if let pointerTimestamp {
            self.pointerTimestamp = pointerTimestamp
        }
    }

    func suppresses(pointerTimestamp: TimeInterval?) -> Bool {
        pointerTimestamp != nil && self.pointerTimestamp == pointerTimestamp
    }
}

/// The native unbordered search cell otherwise lets its text cover the search icon.
class GroupFilterCell: NSSearchFieldCell {
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 9, y: rect.midY - 7, width: 14, height: 14)
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - 22, y: rect.midY - 7, width: 14, height: 14)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 33, y: rect.midY - 8, width: max(0, rect.width - 33 - (stringValue.isEmpty ? 9 : 26)), height: 16)
    }
}

/// Includes the native table column's 6 pt side margins and the label's text
/// insets, rather than counting those margins again as accessory padding.
private enum GroupSwitcherMetrics {
    static let rowHeight: CGFloat = 28
    static let separatorHeight: CGFloat = 9.5
    static let labelX: CGFloat = 25
    static let keycapWidth: CGFloat = 37
    static let trailingInset: CGFloat = 2
    static let accessoryGap: CGFloat = 13

    static func rowHeight(_ row: GroupSwitcherModel.Row) -> CGFloat {
        rowHeight + (row.separatorBefore ? separatorHeight : 0)
    }

    static func requiredWidth(_ row: GroupSwitcherModel.Row, font: NSFont) -> CGFloat {
        let accessories: CGFloat = (row.keycap.isEmpty ? 0 : keycapWidth)
            + (row.isShownElsewhere ? 19 : 0)
        let gap = accessories > 0 ? accessoryGap : 0
        return (row.title as NSString).size(withAttributes: [.font: font]).width
            + 10 + 12 + labelX + 4 + trailingInset + accessories + gap
    }
}

@MainActor
protocol GroupSwitcherPresenting {
    func present(for controller: TerminalWindowController, manager: TerminalWindowManager, anchor: NSView)
}

/// A searchable menu-like panel, with no NSMenu tracking loop around its field.
final class GroupSwitcherPanel: NSPanel, GroupSwitcherPresenting, NSWindowDelegate,
NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let material = NSVisualEffectView()
    let filterField = GroupFilterField()
    let table = GroupMenuTableView()
    private let scroll = NSScrollView()
    private let groupSeparator = NSBox()
    private weak var owner: TerminalWindowController?
    private weak var manager: TerminalWindowManager?
    private weak var previousResponder: NSResponder?
    private var anchorPoint = NSPoint.zero
    private var rows: [GroupSwitcherModel.Row] = []
    private var accessibilityMenuItems: [GroupMenuItemElement] = []
    private var clickMonitor: Any?
    private var groupsObserver: NSObjectProtocol?
    private var closing = false
    private var dismissal = GroupSwitcherDismissal()
    private var currentPointerTimestamp: TimeInterval? {
        let event = NSApp.currentEvent
        return event?.type == .leftMouseDown ? event?.timestamp : nil
    }
    override var canBecomeKey: Bool {
        true
    }
    override var canBecomeMain: Bool {
        false
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 194, height: 180),
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
        material.material = .menu
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 13
        material.layer?.masksToBounds = true
        // A layer corner does not clip behind-window blur; the mask image also shapes the shadow.
        let radius: CGFloat = 13
        let side = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        material.maskImage = mask
        contentView = material
        filterField.cell = GroupFilterCell(textCell: "")
        filterField.isEditable = true
        filterField.isSelectable = true
        filterField.placeholderString = "Filter or create…"
        filterField.font = .systemFont(ofSize: 13)
        filterField.placeholderAttributedString = NSAttributedString(string: "Filter or create…", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor
        ])
        filterField.focusRingType = .none
        filterField.isBezeled = false
        filterField.drawsBackground = false
        filterField.wantsLayer = true
        filterField.layer?.cornerRadius = 12
        filterField.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        filterField.onConfirm = { [weak self] in
            guard let self else {
                return false
            }
            self.choose(self.table.selectedRow)
            return true
        }
        table.menuItems = { [weak self] in
            guard let self else {
                return []
            }
            if self.accessibilityMenuItems.count != self.rows.count {
                self.accessibilityMenuItems = self.rows.indices.map { _ in
                    GroupMenuItemElement()
                }
            }
            for (index, element) in self.accessibilityMenuItems.enumerated() {
                element.setAccessibilityRole(.menuItem)
                element.setAccessibilityLabel(self.rows[index].title)
                element.setAccessibilityEnabled(true)
                element.setAccessibilitySelected(self.table.selectedRow == index)
                element.setAccessibilityParent(self.table)
                if let window = self.table.window {
                    element.setAccessibilityFrame(window.convertToScreen(self.table.convert(self.table.rect(ofRow: index), to: nil)))
                }
                element.onPress = { [weak self] in
                    self?.choose(index)
                }
            }
            return self.accessibilityMenuItems
        }
        filterField.delegate = self
        filterField.sendsSearchStringImmediately = true
        filterField.setAccessibilityLabel("Filter or create a group")
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("group")))
        table.headerView = nil
        table.style = .fullWidth
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.rowHeight = GroupSwitcherMetrics.rowHeight
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(chooseClickedRow)
        table.setAccessibilityLabel("Groups")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        material.addSubview(filterField)
        material.addSubview(scroll)
        groupSeparator.boxType = .separator
        groupSeparator.setAccessibilityElement(false)
        material.addSubview(groupSeparator)
        setAccessibilityRole(.window)
        setAccessibilitySubrole(.systemDialog)
        setAccessibilityLabel("Go to Group")
    }
    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        if let groupsObserver {
            NotificationCenter.default.removeObserver(groupsObserver)
        }
    }

    func present(for controller: TerminalWindowController, manager: TerminalWindowManager, anchor: NSView) {
        guard !dismissal.suppresses(pointerTimestamp: currentPointerTimestamp) else {
            return
        }
        if isVisible {
            dismiss()
            return
        }
        if clickMonitor != nil {
            dismiss()
        }
        owner = controller
        self.manager = manager
        previousResponder = controller.window?.firstResponder
        appearance = controller.window?.appearance
        filterField.stringValue = ""
        let corner = anchor.convert(NSPoint(x: -3, y: anchor.bounds.maxY + 3), to: nil)
        anchorPoint = controller.window?.convertPoint(toScreen: corner) ?? .zero
        reload()
        controller.window?.addChildWindow(self, ordered: .above)
        // A background invocation can be rendered/captured without activating
        // the application. Normal keyboard invocation gives the filter focus.
        if NSApp.isActive {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(filterField)
        } else {
            orderFront(nil)
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self {
                self.dismiss(pointerTimestamp: event.type == .leftMouseDown ? event.timestamp : nil)
            }
            return event
        }
        groupsObserver = NotificationCenter.default.addObserver(forName: .groupsDidChange, object: manager, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
            }
        }
    }

    func dismiss(pointerTimestamp: TimeInterval? = nil) {
        guard !closing else {
            return
        }
        closing = true
        dismissal.record(pointerTimestamp: pointerTimestamp)
        parent?.removeChildWindow(self)
        orderOut(nil)
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let groupsObserver {
            NotificationCenter.default.removeObserver(groupsObserver)
            self.groupsObserver = nil
        }
        if let previousResponder {
            owner?.window?.makeFirstResponder(previousResponder)
        }
        closing = false
    }
    func windowDidResignKey(_ notification: Notification) {
        dismiss(pointerTimestamp: currentPointerTimestamp)
    }
    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    private func reload() {
        guard let manager, let owner else {
            return
        }
        let groups = manager.groups.map { group in
            GroupSwitcherModel.Group(
                id: group.id,
                name: group.name,
                isCurrent: group === owner.group,
                isShownElsewhere: manager.window(showing: group).map {
                    $0.id != owner.id
                } ?? false
            )
        }
        configure(model: GroupSwitcherModel(groups: groups, filter: filterField.stringValue))
    }

    /// Also used by offscreen rendering; does not order the panel onto a screen.
    func configure(model: GroupSwitcherModel) {
        configure(rows: model.rows, selection: model.initialSelection, filter: model.filter)
    }

    /// Accepts presentation rows so offscreen fixtures can use exactly the
    /// content in the measured screenshots, including their action labels.
    func configure(rows: [GroupSwitcherModel.Row], selection: Int, filter: String) {
        filterField.stringValue = filter
        self.rows = rows
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        let font = NSFont.systemFont(ofSize: 13)
        let width = ceil(min(520, max(194, rows.map {
            GroupSwitcherMetrics.requiredWidth($0, font: font)
        }.max() ?? 194)))
        let listHeight = rows.reduce(CGFloat(0)) {
            $0 + GroupSwitcherMetrics.rowHeight($1)
        }
        let screenHeight = owner?.window?.screen?.visibleFrame.height ?? 800
        let height = min(screenHeight - 60, 45 + listHeight + 5)
        setContentSize(NSSize(width: width, height: height))
        if anchorPoint != .zero {
            setFrameTopLeftPoint(anchorPoint)
        }
        filterField.frame = NSRect(x: 5, y: height - 35, width: width - 10, height: 30)
        scroll.frame = NSRect(x: 5, y: 5, width: width - 10, height: height - 50)
        table.tableColumns.first?.width = max(0, scroll.contentView.bounds.width - 12)
        table.frame.size.width = scroll.contentView.bounds.width
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
        groupSeparator.isHidden = true
        if
            let firstAction = rows.firstIndex(where: {
                if case .newGroup = $0.action {
                    return $0.separatorBefore
                }
                return false
            }) {
            let line = table.convert(NSRect(x: 0, y: table.rect(ofRow: firstAction).minY + 4, width: width, height: 1), to: material)
            groupSeparator.frame = NSRect(x: 0, y: line.minY, width: width, height: 1)
            groupSeparator.isHidden = false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        GroupSwitcherMetrics.rowHeight(rows[row])
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = GroupSwitcherRowContent(row: rows[row])
        view.setSelected(table.selectedRow == row)
        return view
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = GroupSwitcherRowView()
        view.separatorBefore = rows[row].separatorBefore
        if case .newGroup = rows[row].action {
            view.usesFullWidthSeparator = true
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.menuItem)
        view.setAccessibilityLabel(rows[row].title)
        view.setAccessibilityHelp(rows[row].isShownElsewhere ? "Shown in another window" : nil)
        view.onPress = { [weak self] in
            self?.choose(row)
        }
        return view
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        for index in rows.indices {
            let selected = table.selectedRow == index
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? GroupSwitcherRowContent)?.setSelected(selected)
            table.rowView(atRow: index, makeIfNecessary: false)?.setAccessibilitySelected(selected)
        }
    }
    @objc private func chooseClickedRow() {
        choose(table.clickedRow)
    }
    private func choose(_ index: Int) {
        guard rows.indices.contains(index), let owner, let manager else {
            return
        }
        let action = rows[index].action
        dismiss()
        switch action {
        case .group(let id):
            if
                let group = manager.groups.first(where: {
                    $0.id == id
                }) {
                if group !== owner.group {
                    manager.navigate(to: group, in: owner)
                } else if group.tabs.contains(where: \.isDormant) {
                    _ = manager.show(group, in: owner)
                }
            }
        case .newGroup(let name):
            let group = manager.newGroup(in: owner)
            if let name {
                manager.rename(group, to: name)
            }
            owner.activate()
        case .remote:
            guard let destination = RemoteDestinationPanel.run() else {
                return
            }
            var spec = LaunchSpec()
            spec.remoteDestination = destination
            spec.persistent = true
            _ = manager.newGroup(in: owner, tab: TerminalTab(spec: spec))
            owner.activate()
        case .attach:
            SessionBrowserPresentation.open?()
        }
    }
    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else {
            return
        }
        let next = max(0, min(rows.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            choose(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            if filterField.stringValue.isEmpty {
                dismiss()
            } else {
                filterField.stringValue = ""
                reload()
            }
        default:
            return false
        }
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "k" {
            dismiss()
            return true
        }
        if
            flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "n",
            let index = rows.firstIndex(where: {
                if case .newGroup = $0.action {
                    return true
                }
                return false
            }) {
            choose(index)
            return true
        }
        if
            flags == .command, let text = event.charactersIgnoringModifiers, let digit = Int(text), (1...9).contains(digit),
            let index = rows.firstIndex(where: {
                $0.keycap == "⌘\(digit)"
            }) {
            choose(index)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The SwiftUI commands supply their OpenWindowAction for the existing Sessions scene.
@MainActor
enum SessionBrowserPresentation { static var open: (() -> Void)? }

private final class GroupSwitcherRowView: NSTableRowView {
    let separator = NSBox()
    var separatorBefore = false
    var usesFullWidthSeparator = false
    var onPress: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        separator.setAccessibilityElement(false)
        addSubview(separator)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    override func layout() {
        super.layout()
        separator.isHidden = !separatorBefore || usesFullWidthSeparator
        separator.frame = NSRect(x: 6, y: 3, width: max(0, bounds.width - 12), height: 1)
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else {
            return
        }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(
            x: bounds.minX,
            y: bounds.minY + (separatorBefore ? GroupSwitcherMetrics.separatorHeight : 0),
            width: bounds.width,
            height: GroupSwitcherMetrics.rowHeight
        ), xRadius: 6, yRadius: 6).fill()
    }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

private final class GroupSwitcherRowContent: NSView {
    private let row: GroupSwitcherModel.Row
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let keycap = NSTextField(labelWithString: "")
    private let marker = NSImageView()
    override var isFlipped: Bool {
        true
    }
    init(row: GroupSwitcherModel.Row) {
        self.row = row
        super.init(frame: .zero)
        title.stringValue = row.title
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        keycap.stringValue = row.keycap
        keycap.font = .systemFont(ofSize: 12, weight: .medium)
        keycap.alignment = .right
        let name = row.isCurrent ? "checkmark" : row.symbol
        symbol.image = name.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        marker.image = row.isShownElsewhere ? NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Shown in another window") : nil
        toolTip = row.isShownElsewhere ? "Shown in another window" : nil
        for view in [symbol, title, keycap, marker] {
            addSubview(view)
            view.setAccessibilityElement(false)
        }
        setAccessibilityElement(false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    func setSelected(_ selected: Bool) {
        title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        keycap.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        symbol.contentTintColor = title.textColor
        marker.contentTintColor = title.textColor
    }
    override func layout() {
        super.layout()
        let top: CGFloat = row.separatorBefore ? GroupSwitcherMetrics.separatorHeight : 0
        symbol.frame = NSRect(x: 2, y: top + 6, width: 16, height: 16)
        let capWidth: CGFloat = row.keycap.isEmpty ? 0 : GroupSwitcherMetrics.keycapWidth
        let markerWidth: CGFloat = row.isShownElsewhere ? 19 : 0
        let gap: CGFloat = capWidth + markerWidth > 0 ? GroupSwitcherMetrics.accessoryGap : 0
        title.frame = NSRect(
            x: GroupSwitcherMetrics.labelX,
            y: top + 5,
            width: max(0, bounds.width - GroupSwitcherMetrics.labelX - GroupSwitcherMetrics.trailingInset - gap - capWidth - markerWidth),
            height: 18
        )
        keycap.frame = NSRect(x: bounds.width - capWidth - GroupSwitcherMetrics.trailingInset, y: top + 6, width: capWidth, height: 16)
        marker.frame = NSRect(x: keycap.frame.minX - markerWidth, y: top + 7, width: 14, height: 14)
    }
}

/// Exposes menu actions directly instead of AppKit's synthetic table-row wrappers.
final class GroupMenuTableView: NSTableView {
    var menuItems: (() -> [Any])?
    override func accessibilityRole() -> NSAccessibility.Role? {
        .menu
    }
    override func accessibilityChildren() -> [Any]? {
        menuItems?() ?? []
    }
}
private final class GroupMenuItemElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
final class GroupFilterField: NSSearchField {
    var onConfirm: (() -> Bool)?
    override func accessibilityPerformConfirm() -> Bool {
        onConfirm?() ?? false
    }
}
