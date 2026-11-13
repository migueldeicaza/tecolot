import AppKit
import TecolotWire

/// Text matching shared by the live activity list and its filter tests.
enum ActivityFilter {
    /// Requires every word to match somewhere in the presentation fields.
    static func matches(_ query: String, fields: [String]) -> Bool {
        let text = fields.joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.localizedStandardContains(String($0))
        }
    }
}

/// Status sections keep attention above work and completed tasks.
enum ActivitySection: Int, CaseIterable {
    case blocked, failed, working, finished, notified, quiet

    var title: String {
        switch self {
        case .blocked:
            "Needs attention"
        case .failed:
            "Failed"
        case .working:
            "Working"
        case .finished:
            "Finished"
        case .notified:
            "Notifications"
        case .quiet:
            "Activity"
        }
    }
}

/// A presentation snapshot, retaining durable identities for the reveal action.
@MainActor
struct ActivityEntry: Equatable {
    var tabID: UUID
    var groupID: UUID
    var paneID: UUID?
    var title: String
    var subtitle: String
    var source: String
    var status: TabStatus
    var icon: NSImage?

    var section: ActivitySection {
        switch status.state {
        case .blocked:
            .blocked
        case .error:
            .failed
        case .working:
            .working
        case .done:
            .finished
        default:
            status.badge == .notified ? .notified : .quiet
        }
    }

    /// Includes group, pane, application and status context in text searches.
    func matches(_ query: String) -> Bool {
        ActivityFilter.matches(query, fields: [title, subtitle, source, status.accessibilityValue, status.app ?? "", section.title])
    }
}

/// Geometry measured from Rex, including a separate empty-state height.
struct ActivityPopoverLayout {
    static let width: CGFloat = 300
    static let radius: CGFloat = 15
    static let rowHeight: CGFloat = 44
    static let sectionHeight: CGFloat = 25
    static let maximumHeight: CGFloat = 536
    let listHeight: CGFloat
    let height: CGFloat

    init(sectionCounts: [Int], maximumHeight: CGFloat = Self.maximumHeight) {
        let counts = sectionCounts.filter {
            $0 > 0
        }
        listHeight = counts.isEmpty ? 101 : 5 + counts.enumerated().reduce(CGFloat(0)) { total, item in
            total + (item.offset == 0 ? 0 : 7) + Self.sectionHeight + 2
                + CGFloat(item.element) * Self.rowHeight + CGFloat(item.element - 1) * 2
        }
        height = min(maximumHeight, counts.isEmpty ? 141 : listHeight + 40)
    }

    var listFrame: NSRect {
        NSRect(x: 0, y: 0, width: Self.width, height: max(0, height - 40))
    }
    var filterFrame: NSRect {
        NSRect(x: 5, y: height - 35, width: 290, height: 30)
    }
    var emptyFrame: NSRect {
        NSRect(x: 21, y: (height - 40 - 17) / 2, width: 258, height: 17)
    }
}

/// All groups share this arrowless, searchable activity panel.
@MainActor
final class ActivityPopover: NSViewController, NSSearchFieldDelegate {
    private let panel = ActivityPanel()
    private weak var owner: TerminalWindowController?
    private weak var anchor: NSView?
    private weak var previousResponder: NSResponder?
    private let scroll = NSScrollView()
    private let list = ActivityListView()
    let filterField = NSSearchField()
    private let empty = NSTextField(labelWithString: "Nothing to review yet")
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private(set) var selectedIndex = 0
    private var activityRows: [ActivityRow] = []
    private var entries: [ActivityEntry] = []
    private var visibleEntries: [ActivityEntry] = []
    private var appliedQuery = ""
    private var configured = false
    var isShown: Bool {
        panel.isVisible
    }

    override func loadView() {
        let root = ActivityRootView(frame: NSRect(x: 0, y: 0, width: 300, height: 141))
        view = root
        root.onAppearanceChange = { [weak self] in
            self?.updateFilterFill()
        }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = list
        root.content.addSubview(scroll)
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        root.content.addSubview(empty)
        filterField.cell = ActivityFilterCell(textCell: "")
        filterField.isEditable = true
        filterField.isSelectable = true
        filterField.font = .systemFont(ofSize: 12)
        filterField.placeholderString = "Filter"
        filterField.focusRingType = .none
        filterField.isBezeled = false
        filterField.drawsBackground = false
        filterField.wantsLayer = true
        filterField.layer?.cornerRadius = 15
        filterField.sendsSearchStringImmediately = true
        filterField.delegate = self
        filterField.setAccessibilityLabel("Filter program activity")
        if let cell = filterField.cell as? NSSearchFieldCell {
            cell.searchButtonCell?.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        }
        root.content.addSubview(filterField)
        applyLayout(ActivityPopoverLayout(sectionCounts: []))
    }

    /// Button clicks and Cmd-period share one toggle and active-eye lifetime.
    func toggle(relativeTo anchor: NSView, owner: TerminalWindowController) {
        if isShown {
            dismiss()
            return
        }
        self.owner = owner
        self.anchor = anchor
        previousResponder = owner.window?.firstResponder
        loadViewIfNeeded()
        panel.contentViewController = self
        panel.appearance = owner.window?.appearance
        filterField.stringValue = ""
        configured = false
        reload()
        positionPanel()
        owner.window?.addChildWindow(panel, ordered: .above)
        setAnchorActive(true)
        if NSApp.isActive {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(filterField)
        } else {
            panel.orderFront(nil)
        }
        panel.invalidateShadow()
        activityRows.forEach {
            $0.setDrawingVisible(true)
        }
        installObservers()
    }

    /// Closes every dismissal path through the same button and responder cleanup.
    func dismiss() {
        activityRows.forEach {
            $0.setDrawingVisible(false)
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentViewController = nil
        setAnchorActive(false)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        keyMonitor = nil
        clickMonitor = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        if let previousResponder {
            owner?.window?.makeFirstResponder(previousResponder)
        }
    }

    private func setAnchorActive(_ active: Bool) {
        guard let button = anchor as? ChromeIconButton else {
            return
        }
        if button.accessibilityLabel() == nil {
            button.setAccessibilityLabel(button.toolTip ?? "Activity")
        }
        button.isChromeActive = active
        button.image = NSImage(systemSymbolName: active ? "eye.fill" : "eye", accessibilityDescription: "Activity")
    }

    /// Keeps editing in the field while arrows, Return and dismissal remain list commands.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        if (filterField.currentEditor() as? NSTextView)?.hasMarkedText() == true {
            return false
        }
        if event.keyCode == 53, !filterField.stringValue.isEmpty {
            filterField.stringValue = ""
            configure(entries: entries)
            return true
        }
        if ActivityNavigation.isDismissKey(event) {
            dismiss()
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if activityRows.indices.contains(selectedIndex) {
                activityRows[selectedIndex].performClick(nil)
            }
            return true
        }
        guard event.keyCode == 125 || event.keyCode == 126 else {
            return false
        }
        selectedIndex = ActivityNavigation.moved(selectedIndex, count: activityRows.count, down: event.keyCode == 125)
        updateSelection()
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        configure(entries: entries)
    }

    /// Uses the same presentation path for manager snapshots and offscreen fixtures.
    func configure(entries: [ActivityEntry]) {
        loadViewIfNeeded()
        let query = filterField.stringValue
        guard !configured || self.entries != entries || appliedQuery != query else {
            return
        }
        let selectedID = configured && visibleEntries.indices.contains(selectedIndex) ? visibleEntries[selectedIndex].tabID : nil
        let changedQuery = appliedQuery != query
        self.entries = entries
        appliedQuery = query
        configured = true
        visibleEntries = ActivitySection.allCases.flatMap { section in
            entries.filter {
                $0.section == section && $0.matches(query)
            }
        }
        list.subviews.forEach {
            $0.removeFromSuperview()
        }
        activityRows.removeAll()
        var y: CGFloat = 5
        var counts: [Int] = []
        for section in ActivitySection.allCases {
            let members = visibleEntries.filter {
                $0.section == section
            }
            guard !members.isEmpty else {
                continue
            }
            if !counts.isEmpty {
                y += 7
            }
            counts.append(members.count)
            let label = NSTextField(labelWithString: section.title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 17, y: y + 4, width: 266, height: 17)
            list.addSubview(label)
            y += ActivityPopoverLayout.sectionHeight + 2
            for (index, entry) in members.enumerated() {
                let row = ActivityRow(entry: entry) { [weak self] in
                    self?.choose(entry)
                }
                row.onHover = { [weak self] in
                    guard
                        let self, let index = self.visibleEntries.firstIndex(where: {
                            $0.tabID == entry.tabID
                        }) else {
                        return
                    }
                    self.selectedIndex = index
                    self.updateSelection()
                }
                row.frame = NSRect(x: 5, y: y, width: 290, height: ActivityPopoverLayout.rowHeight)
                list.addSubview(row)
                row.setDrawingVisible(isShown)
                activityRows.append(row)
                y += ActivityPopoverLayout.rowHeight + (index == members.count - 1 ? 0 : 2)
            }
        }
        selectedIndex = changedQuery ? 0 : visibleEntries.firstIndex {
            $0.tabID == (selectedID ?? owner?.group.selectedTab?.id)
        } ?? 0
        empty.stringValue = query.isEmpty ? "Nothing to review yet" : "No matching activity"
        empty.isHidden = !visibleEntries.isEmpty
        scroll.isHidden = visibleEntries.isEmpty
        applyLayout(ActivityPopoverLayout(sectionCounts: counts))
        updateSelection()
    }

    /// Builds live rows without starting dormant groups or attaching their panes.
    private func reload() {
        if isShown, owner == nil || owner?.window?.isVisible != true || anchor?.window == nil || anchor?.isHiddenOrHasHiddenAncestor == true {
            dismiss()
            return
        }
        guard let owner else {
            return
        }
        var values: [ActivityEntry] = []
        var icons = TabStripPreferences()
        icons.iconCount = 1
        for group in owner.manager.groups {
            for tab in group.tabs where !tab.isDormant {
                let status = tab.status
                guard status.winner != nil || status.badge != nil else {
                    continue
                }
                let pane = tab.loadedWorkspace?.controllers.first {
                    $0.id == status.winner?.paneID
                }
                    ?? tab.loadedWorkspace?.focusedController
                let source = "\(group.name) › \(tab.title) › \(pane?.panePresentation.title ?? "Terminal")"
                    + " " + (pane.map {
                        TerminalNotifier.source(of: $0)
                    } ?? "")
                var subtitle = status.message.flatMap {
                    $0.isEmpty ? nil : $0
                } ?? group.name
                if let progress = status.progress {
                    subtitle += " · \(progress)%"
                }
                let icon = tab.loadedWorkspace.map {
                    TerminalTabIconStack.image(workspace: $0, preferences: icons, appearance: owner.window?.appearance, showsProgress: status.progress != nil)
                }
                values.append(ActivityEntry(
                    tabID: tab.id,
                    groupID: group.id,
                    paneID: status.winner?.paneID,
                    title: tab.title,
                    subtitle: subtitle,
                    source: source,
                    status: status,
                    icon: icon
                ))
            }
        }
        configure(entries: values)
    }

    /// Applies measured list, footer and empty-state frames without losing field focus.
    private func applyLayout(_ layout: ActivityPopoverLayout) {
        let oldSize = panel.frame.size
        view.frame.size = NSSize(width: 300, height: layout.height)
        panel.setContentSize(view.frame.size)
        scroll.frame = layout.listFrame
        list.frame = NSRect(x: 0, y: 0, width: 300, height: layout.listHeight)
        empty.frame = layout.emptyFrame
        filterField.frame = layout.filterFrame
        updateFilterFill()
        panel.invalidateShadow()
        if isShown, oldSize != panel.frame.size {
            positionPanel()
        }
    }

    /// Keeps the filter's subtle fill readable in either appearance and Increase Contrast.
    private func updateFilterFill() {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        filterField.layer?.backgroundColor = (dark ? NSColor.white : .black).withAlphaComponent(contrast ? 0.16 : dark ? 0.045 : 0.04).cgColor
        filterField.layer?.borderWidth = contrast ? 1 : 0
        filterField.layer?.borderColor = NSColor.secondaryLabelColor.cgColor
    }

    /// Aligns the panel below its opener while keeping it on screen.
    private func positionPanel() {
        guard let anchor, let window = anchor.window else {
            return
        }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let x = min(max(screen.minX + 5, rect.maxX - panel.frame.width + 5), screen.maxX - panel.frame.width - 5)
        let top = rect.minY - 5
        panel.setFrameOrigin(NSPoint(x: x, y: max(screen.minY + 5, top - panel.frame.height)))
    }

    /// Exposes the selected row to accessibility and scrolls it into view.
    private func updateSelection() {
        for (index, row) in activityRows.enumerated() {
            row.isActivitySelected = index == selectedIndex
        }
        if activityRows.indices.contains(selectedIndex) {
            list.scrollToVisible(activityRows[selectedIndex].frame)
        }
    }

    /// Reveals the existing winning pane or group without duplicating its view.
    private func choose(_ entry: ActivityEntry) {
        guard
            let owner, let group = owner.manager.groups.first(where: {
                $0.id == entry.groupID
            }),
            let tab = group.tabs.first(where: {
                $0.id == entry.tabID
            }) else {
            return
        }
        dismiss()
        if
            let pane = tab.loadedWorkspace?.controllers.first(where: {
                $0.id == entry.paneID
            }) {
            pane.reveal()
        } else {
            owner.manager.navigate(to: group, tab: tab, in: owner)
        }
    }

    /// Scopes live updates and keyboard/pointer dismissal to this presentation.
    private func installObservers() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard
                let self, self.isShown,
                ActivityNavigation.acceptsKeyEvent(event, popoverWindow: self.panel, ownerWindow: self.owner?.window) else {
                return event
            }
            return self.handleKey(event) ? nil : event
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window !== self.panel else {
                return event
            }
            if
                let anchor = self.anchor, event.window === anchor.window,
                anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                return event
            }
            self.dismiss()
            return event
        }
        for name in [Notification.Name.programActivityDidChange, .groupsDidChange, .programActivityPreferencesDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reload()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }
}

/// A single tab's icon, title and status, with the existing reveal action.
private final class ActivityRow: NSButton {
    var onHover: (() -> Void)?
    var isActivitySelected = false {
        didSet { updateColors() }
    }
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    private let icon = NSImageView()
    private let badge = ProgramStatusBadgeView()
    private let pie = ProgramProgressPieView()
    private let working = ProgramWorkingDotsView()
    private let hasWorkingDots: Bool
    private var drawingVisible = false
    private let heading = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private let handler: () -> Void
    private let unseen: Bool

    /// Builds a native reveal button with the shared program indicators.
    init(entry: ActivityEntry, handler: @escaping () -> Void) {
        self.handler = handler
        unseen = entry.status.unseen
        hasWorkingDots = entry.status.state == .working && entry.status.progress == nil
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 10
        target = self
        action = #selector(choose)
        icon.image = entry.icon ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        heading.stringValue = ProgramStatusText.sanitize(entry.title, limit: 512)
        heading.font = .systemFont(ofSize: 13, weight: entry.status.unseen ? .semibold : .regular)
        message.stringValue = ProgramStatusText.sanitize(entry.subtitle, limit: 512)
        message.font = .systemFont(ofSize: 12)
        for label in [heading, message] {
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityElement(false)
        }
        icon.setAccessibilityElement(false)
        badge.configure(entry.status, background: .windowBackgroundColor, colored: ProgramActivitySettings.shared.value.color)
        pie.isHidden = entry.status.progress == nil
        if let progress = entry.status.progress {
            pie.configure(progress)
        }
        for child in [icon, badge, pie, working, heading, message] {
            addSubview(child)
        }
        setAccessibilityLabel(ProgramStatusText.sanitize(entry.source, limit: 1024))
        setAccessibilityValue(entry.status.accessibilityValue)
        toolTip = entry.source + "\n" + entry.status.accessibilityValue
        updateColors()
    }

    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    override var isFlipped: Bool {
        true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 11, width: 22, height: 22)
        badge.frame = NSRect(x: 23, y: 5, width: 15, height: 15)
        pie.frame = NSRect(x: 15, y: 16, width: 12, height: 12)
        working.frame = NSRect(x: bounds.width - 30, y: 10, width: 18, height: 7)
        heading.frame = NSRect(x: 37, y: 3, width: bounds.width - (hasWorkingDots ? 80 : 47), height: 18)
        message.frame = NSRect(x: 37, y: 22, width: bounds.width - 47, height: 17)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea {
            hovered = true
            updateColors()
            onHover?()
        }
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea {
            hovered = false
            updateColors()
        }
    }
    /// Keeps selected-row contrast and accessible selection in sync.
    private func updateColors() {
        layer?.backgroundColor = isActivitySelected ? NSColor.controlAccentColor.cgColor : (hovered ? NSColor.quaternaryLabelColor.cgColor : nil)
        heading.font = .systemFont(ofSize: 13, weight: isActivitySelected || unseen ? .semibold : .regular)
        heading.textColor = isActivitySelected ? .alternateSelectedControlTextColor : .labelColor
        message.textColor = isActivitySelected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.85) : .secondaryLabelColor
        working.appearance = isActivitySelected ? NSAppearance(named: .darkAqua) : nil
        working.configure(visible: drawingVisible && hasWorkingDots, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        setAccessibilitySelected(isActivitySelected)
    }
    /// The shared working wave runs only while this panel is presented.
    func setDrawingVisible(_ visible: Bool) {
        drawingVisible = visible
        working.configure(visible: visible && hasWorkingDots, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    @objc private func choose() {
        handler()
    }
}

/// Native glass clips its backdrop; the older material also needs a stretchable mask.
private final class ActivityRootView: NSView {
    var onAppearanceChange: (() -> Void)?
    let content = ActivityListView()
    private let background: NSView
    override var acceptsFirstResponder: Bool {
        true
    }
    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = ActivityPopoverLayout.radius
            glass.contentView = content
            background = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = ActivityPopoverLayout.radius
            material.layer?.masksToBounds = true
            let radius = ActivityPopoverLayout.radius
            let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            mask.resizingMode = .stretch
            material.maskImage = mask
            material.addSubview(content)
            background = material
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = ActivityPopoverLayout.radius
        layer?.masksToBounds = true
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(background)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Flipped coordinates keep section and row geometry independent of the panel height.
private final class ActivityListView: NSView {
    override var isFlipped: Bool {
        true
    }
}

/// Preserves native field editing while reserving room for the filter glyph.
private final class ActivityFilterCell: GroupFilterCell {
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 8, y: rect.midY - 7, width: 14, height: 14)
    }
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 28, y: rect.midY - 8, width: max(0, rect.width - 28 - (stringValue.isEmpty ? 9 : 26)), height: 16)
    }
}

/// An arrowless child window that can focus its filter without activating another app.
private final class ActivityPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
    override var canBecomeMain: Bool {
        false
    }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 141), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .normal
        isFloatingPanel = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = true
        setAccessibilityLabel("Program activity")
        setAccessibilitySubrole(.systemDialog)
    }
}

/// Keyboard policy shared by the popup and its regression tests.
enum ActivityNavigation {
    /// Accepts keys only from the panel and its owning terminal window.
    static func acceptsKeyEvent(_ event: NSEvent, popoverWindow: NSWindow?, ownerWindow: NSWindow?) -> Bool {
        guard let window = event.window else {
            return false
        }
        return window === popoverWindow || window === ownerWindow
    }
    /// Recognizes dismissal even when the filter editor owns focus.
    static func isDismissKey(_ event: NSEvent) -> Bool {
        event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == ".")
    }
    /// Clamps arrow navigation to the available rows, including an empty list.
    static func moved(_ index: Int, count: Int, down: Bool) -> Int {
        min(max(0, count - 1), max(0, index + (down ? 1 : -1)))
    }
}
