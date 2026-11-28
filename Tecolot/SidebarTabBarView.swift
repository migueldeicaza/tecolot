import AppKit
import QuartzCore
import Observation

/// The all-groups outline shares tab content and status drawing with the Above strip.
final class SidebarTabBarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSDraggingSource {
    var usesSharedBackdrop = false
    weak var controller: TerminalWindowController?
    let outline = SidebarOutlineView()
    let scroll = NSScrollView()
    let toggle = ChromeIconButton(treatment: .window)
    let activity = ChromeIconButton(treatment: .window)
    let commandPalette = ChromeIconButton(treatment: .window)
    let theme = ThemeTitlebarControl()
    private let zoom = ChromeIconButton(treatment: .window)
    private let add = ChromeIconButton(treatment: .window)
    private let overflow = ChromeIconButton(treatment: .window)
    private let filterButton = ChromeIconButton(treatment: .window)
    private let newGroup = ChromeIconButton(treatment: .window)
    let filter = NSSearchField()
    private let activityBadge = ProgramStatusBadgeView()
    private let popover = ActivityPopover()
    private var cells: [UUID: TabItemView] = [:]
    private(set) var model: SidebarModel?
    private var makeModel: @MainActor (TerminalWindowManager, TerminalTabGroup, String) -> SidebarModel = {
        SidebarModel(manager: $0, current: $1, filter: $2)
    }
    private var observers: [NSObjectProtocol] = []
    private var flagsMonitor: Any?
    private var hintsTask: Task<Void, Never>?
    private var defaultsObserver: DefaultsValueObserver<TabStripPreferences>?
    private var textSizeObserver: DefaultsValueObserver<CGFloat>?
    private var hints = false
    private var reloading = false
    private var observationGeneration = 0
    private var structure: [[UUID]] = []
    private var filterShown = false
    private var draggedTab: TerminalTab?
    private var dragCancelled = false
    private var escapeMonitor: Any?
    private var terminalTheme: TerminalTheme?
    private var opacity = 1.0
    override var isFlipped: Bool {
        true
    }
    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Tabs"))
        column.minWidth = 0
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 0
        outline.intercellSpacing = .zero
        outline.selectionHighlightStyle = .none
        outline.focusRingType = .none
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Groups and tabs")
        outline.registerForDraggedTypes([TabDropPayload.pasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = .init()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        scroll.contentView.postsBoundsChangedNotifications = true
        filter.placeholderString = "Filter groups and tabs"
        filter.delegate = self
        filter.isHidden = true
        configure(toggle, symbol: "sidebar.left", title: "Toggle Sidebar", action: #selector(toggleSidebar))
        configure(activity, symbol: "eye", title: "Activity", action: #selector(toggleActivity))
        configure(commandPalette, symbol: "command", title: "Command Palette", action: #selector(toggleCommandPalette))
        configure(add, symbol: "plus", title: "New Tab", action: #selector(addTab))
        configure(zoom, symbol: "arrow.down.right.and.arrow.up.left", title: "Reset Split Zoom", action: #selector(resetZoom))
        configure(overflow, symbol: "ellipsis.circle", title: "Sidebar actions", action: #selector(showOverflow))
        configure(filterButton, symbol: "line.3.horizontal.decrease.circle", title: "Filter", action: #selector(showFilter))
        configure(newGroup, symbol: "plus.rectangle.on.rectangle", title: "New Group", action: #selector(addGroup))
        theme.fallbackAnchorView = overflow
        updateShortcutToolTips()
        activity.addSubview(activityBadge)
        for view in [scroll, toggle, activity, commandPalette, theme, zoom, add, overflow, filterButton, newGroup, filter] {
            addSubview(view)
        }
        for name in [
            Notification.Name.groupsDidChange,
            .programActivityDidChange,
            .programActivityPreferencesDidChange,
            .appShortcutsDidChange,
            NSView.boundsDidChangeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification
        ] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    if note.name == .appShortcutsDidChange {
                        self.updateShortcutToolTips()
                    } else if note.name == NSView.boundsDidChangeNotification {
                        if note.object as? NSClipView === self.scroll.contentView {
                            self.updateDrawingVisibility()
                        }
                    } else {
                        self.reload()
                    }
                }
            })
        }
        defaultsObserver = DefaultsValueObserver(defaults: .standard, keys: TabStripPreferences.observedKeys, read: TabStripPreferences.init(defaults:))
        defaultsObserver?.onChange = { [weak self] _ in
            self?.reload()
        }
        textSizeObserver = DefaultsValueObserver(defaults: .standard, keys: [SidebarPreferences.textSizeKey, SidebarPreferences.systemSizeKey]) {
            SidebarPreferences(defaults: $0).textSize
        }
        textSizeObserver?.onChange = { [weak self] _ in
            self?.reload()
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.showHints(event)
            return event
        }
    }

    /// Supplies the outline's snapshot source independently of its presentation.
    convenience init(frame: NSRect, makeModel: @escaping @MainActor (TerminalWindowManager, TerminalTabGroup, String) -> SidebarModel) {
        self.init(frame: frame)
        self.makeModel = makeModel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        hintsTask?.cancel()
    }

    private func configure(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = title
        button.setAccessibilityLabel(title)
    }

    func updateShortcutToolTips() {
        let shortcuts = AppShortcutStore.shared
        toggle.toolTip = shortcuts.toolTip("Toggle Sidebar", for: .toggleSidebar)
        activity.toolTip = shortcuts.toolTip("Activity", for: .activity)
        commandPalette.toolTip = shortcuts.toolTip("Command Palette", for: .commandPalette)
        add.toolTip = shortcuts.toolTip("New Tab", for: .newTab)
        newGroup.toolTip = shortcuts.toolTip("New Group", for: .newGroup)
    }

    func apply(theme: TerminalTheme?, opacity: Double) {
        guard model == nil || terminalTheme != theme || self.opacity != opacity else {
            return
        }
        terminalTheme = theme
        self.opacity = opacity
        reload()
    }

    func refreshThemeControl() {
        let pane = controller?.group.selectedTab?.loadedWorkspace?.focusedController
        theme.configure(controller: pane)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reload()
    }

    /// Rebuilds only the outline; terminal hosts continue to belong to their single owner.
    func reload() {
        guard let controller, !reloading else {
            return
        }
        reloading = true
        defer {
            reloading = false
            observeRows()
        }
        model = makeModel(controller.manager, controller.group, filter.stringValue)
        let ids = Set(model?.sections.flatMap {
            $0.tabs.map(\.id)
        } ?? [])
        for (id, cell) in cells where !ids.contains(id) {
            cell.setDrawingVisible(false)
            cells.removeValue(forKey: id)
        }
        let nextStructure = model?.sections.map {
            [$0.group.id] + $0.tabs.map(\.id)
        } ?? []
        let changedStructure = nextStructure != structure
        let animates = !changedStructure && !isHidden && window?.isVisible == true
            && TabStripPreferences().animationStyle != "off" && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var positions: [UUID: CGFloat] = [:]
        if animates {
            for row in 0..<outline.numberOfRows {
                guard let id = outlineID(at: row), let view = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else {
                    continue
                }
                positions[id] = convert(view.bounds, from: view).minY
            }
        }
        var expandedTabs = Set<UUID>()
        structure = nextStructure
        if changedStructure {
            outline.reloadData()
        }
        for section in model?.sections ?? [] {
            let group = section.group
            let expanded = outline.isItemExpanded(group)
            guard expanded == group.isCollapsed else {
                continue
            }
            if group.isCollapsed {
                if animates {
                    fadeCollapsedRows(group)
                }
                outline.collapseItem(group)
            } else {
                expandedTabs.formUnion(section.tabs.map(\.id))
                outline.expandItem(group)
            }
        }
        outline.layoutSubtreeIfNeeded()
        if animates {
            for row in 0..<outline.numberOfRows {
                guard
                    outline.rect(ofRow: row).intersects(outline.visibleRect), let id = outlineID(at: row),
                    let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else {
                    continue
                }
                cell.wantsLayer = true
                if expandedTabs.contains(id) {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.duration = 0.12
                    cell.layer?.add(fade, forKey: "groupExpandFade")
                    animateRow(cell, offset: -8)
                } else if let old = positions[id] {
                    animateRow(cell, offset: old - convert(cell.bounds, from: cell).minY)
                }
            }
        }
        for row in 0..<outline.numberOfRows {
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarGroupHeader)?.refresh()
        }
        if let tab = controller.group.selectedTab {
            let row = outline.row(forItem: tab)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        let chrome = TabStripChrome(theme: terminalTheme, opacity: opacity, key: window?.isKeyWindow == true, appearance: effectiveAppearance)
        layer?.backgroundColor = usesSharedBackdrop ? nil : chrome.bar.cgColor
        for cell in cells.values {
            cell.configure(
                selected: controller.group === group(for: cell.tab) && cell.tab.id == controller.group.selection,
                key: window?.isKeyWindow == true,
                chrome: chrome,
                preferences: TabStripPreferences()
            )
            if let group = group(for: cell.tab), let owner = controller.manager.window(showing: group), owner.id != controller.id {
                cell.toolTip = "Shown in another window"
            }
            cell.setHint(hints ? number(for: cell.tab) : nil)
        }
        let pane = controller.group.selectedTab?.loadedWorkspace?.focusedController
        theme.configure(controller: pane)
        zoom.isHidden = controller.group.selectedTab?.loadedWorkspace?.zoomedControllerID == nil
        let status = controller.manager.groups.flatMap(\.tabs).map(\.status).filter(\.unseen)
            .max {
                ($0.badge?.rawValue ?? -1) < ($1.badge?.rawValue ?? -1)
            } ?? .none
        activityBadge.configure(status, background: chrome.bar, colored: ProgramActivitySettings.shared.value.color)
        activity.setAccessibilityLabel("Activity")
        activity.setAccessibilityValue(TabStatus.activityAccessibilityValue(count: controller.manager.groups.flatMap(\.tabs).filter {
            $0.status.unseen
        }.count))
        needsLayout = true
        updateDrawingVisibility()
    }

    /// Background panes have no window controller to publish title and icon changes for them.
    private func observeRows() {
        guard let controller else {
            return
        }
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking {
            for group in controller.manager.groups {
                _ = group.name
                _ = group.isCollapsed
                for tab in group.tabs {
                    _ = tab.title
                    _ = tab.isMuted
                    _ = tab.status
                    for pane in tab.loadedWorkspace?.controllers ?? [] {
                        _ = pane.panePresentation
                    }
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else {
                    return
                }
                self.reload()
            }
        }
    }

    private func outlineID(at row: Int) -> UUID? {
        let item = outline.item(atRow: row)
        return (item as? TerminalTabGroup)?.id ?? (item as? TerminalTab)?.id
    }

    /// Fades departing rows over 130 ms while their snapshots rise by three points.
    private func fadeCollapsedRows(_ group: TerminalTabGroup) {
        for tab in group.tabs {
            guard
                let cell = cells[tab.id], outline.row(forItem: tab) >= 0,
                outline.rect(ofRow: outline.row(forItem: tab)).intersects(outline.visibleRect),
                let image = NSImage(data: cell.dataWithPDF(inside: cell.bounds)) else {
                continue
            }
            let snapshot = SidebarRowSnapshot()
            snapshot.image = image
            snapshot.imageScaling = .scaleAxesIndependently
            snapshot.frame = scroll.contentView.convert(cell.bounds, from: cell)
            snapshot.setAccessibilityElement(false)
            scroll.contentView.addSubview(snapshot)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.13
                snapshot.animator().alphaValue = 0
                snapshot.animator().frame = snapshot.frame.offsetBy(dx: 0, dy: -3)
            } completionHandler: {
                snapshot.removeFromSuperview()
            }
        }
    }

    /// Expanding rows settle from eight points above, using the sidebar's spring.
    private func animateRow(_ cell: NSView, offset: CGFloat) {
        guard offset != 0 else {
            return
        }
        let snappy = TabStripPreferences().animationStyle == "snappy"
        let response = snappy ? 0.20 : 0.32
        let spring = CASpringAnimation(keyPath: "transform.translation.y")
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 2 * (snappy ? 1.0 : 0.91) * sqrt(spring.stiffness)
        spring.fromValue = offset
        spring.toValue = 0
        spring.duration = 0.3
        cell.layer?.add(spring, forKey: "groupRowPosition")
    }

    override func layout() {
        super.layout()
        let right = controller?.sidebarPreferences.style == .right
        let fullscreen = controller?.isFullScreen ?? (window?.styleMask.contains(.fullScreen) == true)
        toggle.frame = NSRect(x: right ? bounds.width - 40 : (fullscreen ? 12 : 92), y: 12, width: 29, height: 25)
        let pitch: CGFloat = 26
        let start: CGFloat = right ? 9 : bounds.width - 113
        add.frame = NSRect(x: right ? start : start + pitch * 3, y: 12, width: 26, height: 26)
        theme.frame = NSRect(x: right ? start + pitch : start + pitch * 2, y: 12, width: 26, height: 26)
        commandPalette.frame = NSRect(x: right ? start + pitch * 2 : start + pitch, y: 12, width: 26, height: 26)
        activity.frame = NSRect(x: right ? start + pitch * 3 : start, y: 12, width: 26, height: 26)
        let narrow = !right && bounds.width < (fullscreen ? 156 : 236)
        for view in [activity, commandPalette, theme, add] {
            view.isHidden = narrow
        }
        overflow.isHidden = !narrow
        overflow.frame = NSRect(x: bounds.width - 38, y: 12, width: 29, height: 26)
        let bottomZoom = right || bounds.width < (fullscreen ? 210 : 290)
        zoom.frame = NSRect(
            x: bottomZoom ? bounds.width - 70 : start - 30,
            y: bottomZoom ? bounds.height - 32 : 12,
            width: 29,
            height: 26
        )
        activityBadge.frame = NSRect(x: 15, y: 2, width: 13, height: 13)
        let filterHeight: CGFloat = filterShown ? 30 : 0
        filter.frame = NSRect(x: 10, y: 40, width: max(0, bounds.width - 20), height: 24)
        scroll.frame = NSRect(x: 0, y: 38 + filterHeight, width: bounds.width, height: max(0, bounds.height - 76 - filterHeight))
        let width = max(0, scroll.contentSize.width)
        outline.tableColumns.first?.width = width
        outline.setFrameSize(NSSize(width: width, height: outline.frame.height))
        filterButton.frame = NSRect(x: 9, y: bounds.height - 32, width: 32, height: 25)
        newGroup.frame = NSRect(x: bounds.width - 40, y: bounds.height - 32, width: 30, height: 25)
        updateDrawingVisibility()
    }

    private func group(for tab: TerminalTab) -> TerminalTabGroup? {
        controller?.manager.groups.first {
            $0.tabs.contains {
                $0 === tab
            }
        }
    }
    private func number(for tab: TerminalTab) -> Int? {
        guard
            let index = model?.numberedTabs.firstIndex(where: {
                $0.tab === tab
            }), index < 9 else {
            return nil
        }
        return index + 1
    }
    func select(_ tab: TerminalTab, preservingOutlineFocus: Bool = false) {
        guard let controller, let group = group(for: tab) else {
            return
        }
        let keyboard = preservingOutlineFocus && window?.firstResponder === outline
        controller.manager.navigate(to: group, tab: tab, in: controller)
        if keyboard, controller.group === group {
            window?.makeFirstResponder(outline)
        } else if let owner = controller.manager.window(showing: group) as? TerminalWindowController {
            owner.window?.makeFirstResponder(tab.loadedWorkspace?.focusedController?.surface)
        }
    }
    func selectNumber(_ index: Int) {
        guard let tabs = model?.numberedTabs, tabs.indices.contains(index) else {
            return
        }
        select(tabs[index].tab)
    }
    func beginRename(_ tab: TerminalTab, onFinish: (() -> Void)? = nil) {
        if model == nil {
            reload()
        }
        var temporarilyExpandedGroup: TerminalTabGroup?
        if let tabGroup = group(for: tab), tabGroup.isCollapsed {
            temporarilyExpandedGroup = tabGroup
            controller?.manager.setCollapsed(false, group: tabGroup)
            reload()
        }
        let finish: () -> Void = { [weak self, weak temporarilyExpandedGroup] in
            if let temporarilyExpandedGroup {
                self?.controller?.manager.setCollapsed(true, group: temporarilyExpandedGroup)
            }
            onFinish?()
        }
        if outline.row(forItem: tab) < 0 {
            filter.stringValue = ""
            reload()
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        outline.tile()
        let row = outline.row(forItem: tab)
        guard row >= 0 else {
            finish()
            return
        }
        outline.scrollRowToVisible(row)
        outline.layoutSubtreeIfNeeded()
        guard
            let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabItemView,
            cell.window != nil else {
            finish()
            return
        }
        cell.beginRename(onFinish: finish)
    }
    func beginGroupRename(_ group: TerminalTabGroup, onFinish: (() -> Void)? = nil) {
        if model == nil {
            reload()
        }
        if outline.row(forItem: group) < 0 {
            filter.stringValue = ""
            reload()
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        outline.tile()
        let row = outline.row(forItem: group)
        guard row >= 0 else {
            onFinish?()
            return
        }
        outline.scrollRowToVisible(row)
        outline.layoutSubtreeIfNeeded()
        guard
            let header = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarGroupHeader,
            header.window != nil else {
            onFinish?()
            return
        }
        header.beginRename(onFinish: onFinish)
    }
    /// Window visibility can change while these rows keep their viewport geometry.
    var tabsInViewport: [TerminalTab] {
        guard !isHidden else {
            return []
        }
        return cells.values.compactMap { cell in
            let row = outline.row(forItem: cell.tab)
            return row >= 0 && outline.rect(ofRow: row).intersects(outline.visibleRect) ? cell.tab : nil
        }
    }

    func hasVisibleCell(for tab: TerminalTab) -> Bool {
        let row = outline.row(forItem: tab)
        return !isHidden && window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true && row >= 0
            && outline.rect(ofRow: row).intersects(outline.visibleRect)
    }
    func updateDrawingVisibility() {
        let visible = !isHidden && window?.occlusionState.contains(.visible) == true && !NSApp.isHidden
        for cell in cells.values {
            let row = outline.row(forItem: cell.tab)
            cell.setDrawingVisible(visible && row >= 0 && outline.rect(ofRow: row).intersects(outline.visibleRect))
            cell.tab.loadedWorkspace?.updateProcessInspection()
        }
    }
    private func showHints(_ event: NSEvent) {
        hintsTask?.cancel()
        guard
            !isHidden, window?.isKeyWindow == true, UserDefaults.standard.bool(forKey: TabSelectionCommands.useCommandDigitsForTabsKey),
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            hints = false
            for cell in cells.values {
                cell.setHint(nil)
            }
            return
        }
        hintsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, self.window?.isKeyWindow == true else {
                return
            }
            self.hints = true
            for cell in self.cells.values {
                cell.setHint(self.number(for: cell.tab))
            }
        }
    }
    @objc private func toggleSidebar() {
        controller?.toggleSidebar()
    }
    @objc func toggleActivity() {
        guard let controller else {
            return
        }
        popover.toggle(relativeTo: activity.isHidden ? overflow : activity, owner: controller)
    }
    @objc private func toggleCommandPalette() {
        controller?.toggleCommandPalette()
    }
    @objc private func addTab() {
        controller?.newTab()
    }
    @objc private func resetZoom() {
        controller?.group.selectedTab?.loadedWorkspace?.clearSplitZoom()
    }
    @objc private func addGroup() {
        controller?.newGroup()
    }
    /// At minimum width, a menu keeps the controls clear of the traffic lights.
    @objc private func showOverflow() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Activity") { [weak self] in
            self?.toggleActivity()
        })
        menu.addItem(ClosureMenuItem("Command Palette…") { [weak self] in
            self?.toggleCommandPalette()
        })
        menu.addItem(ClosureMenuItem("Theme…") { [weak self] in
            self?.theme.presentPicker()
        })
        menu.addItem(ClosureMenuItem("New Tab") { [weak self] in
            self?.addTab()
        })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.maxY), in: overflow)
    }
    func focusFilter() {
        if !filterShown {
            filterShown = true
            filter.isHidden = false
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        window?.makeFirstResponder(filter)
    }
    @objc private func showFilter() {
        filterShown.toggle()
        filter.isHidden = !filterShown
        if !filterShown {
            filter.stringValue = ""
            reload()
        }
        needsLayout = true
        if filterShown {
            layoutSubtreeIfNeeded()
            window?.makeFirstResponder(filter)
        } else {
            controller?.endTemporarySidebarReveal()
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        reload()
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSSearchField === filter else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.controller?.endTemporarySidebarReveal()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let group = item as? TerminalTabGroup {
            return model?.sections.first {
                $0.group === group
            }?.tabs.count ?? 0
        }
        return model?.sections.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? TerminalTabGroup {
            return model!.sections.first {
                $0.group === group
            }!.tabs[index]
        }
        return model!.sections[index].group
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is TerminalTabGroup
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is TerminalTabGroup ? 34 : 32
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? TerminalTabGroup {
            let header = SidebarGroupHeader(group: group, sidebar: self)
            header.toolTip = controller?.manager.window(showing: group).map {
                $0.id != controller?.id ? "Shown in another window" : group.name
            } ?? group.name
            return header
        }
        guard let tab = item as? TerminalTab else {
            return nil
        }
        let cell = cells[tab.id] ?? TabItemView(tab: tab, controller: controller)
        cells[tab.id] = cell
        cell.sidebar = self
        cell.showDivider(false)
        cell.setAccessibilityRole(.cell)
        cell.configure(selected: controller?.group.selection == tab.id)
        cell.toolTip = group(for: tab).flatMap {
            controller?.manager.window(showing: $0)
        }.map {
            $0.id != controller?.id ? "Shown in another window" : tab.title
        } ?? tab.title
        cell.setHint(hints ? number(for: tab) : nil)
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let tab = outline.item(atRow: outline.selectedRow) as? TerminalTab else {
            return
        }
        select(tab, preservingOutlineFocus: true)
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        collapseChanged(notification, collapsed: false)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        collapseChanged(notification, collapsed: true)
    }
    private func collapseChanged(_ notification: Notification, collapsed: Bool) {
        guard !reloading, let group = notification.userInfo?["NSObject"] as? TerminalTabGroup else {
            return
        }
        controller?.manager.setCollapsed(collapsed, group: group)
    }

    /// Custom cell drags and native outline drops use the same private payload as the strip.
    func beginDrag(tab: TerminalTab, cell: TabItemView, event: NSEvent) {
        guard let group = group(for: tab), let data = TabDropPayload(groupID: group.id, tabID: tab.id).data else {
            return
        }
        let writer = NSPasteboardItem()
        writer.setData(data, forType: TabDropPayload.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = NSImage(data: cell.dataWithPDF(inside: cell.bounds)) ?? NSImage(size: cell.bounds.size)
        item.setDraggingFrame(cell.bounds, contents: image)
        draggedTab = tab
        dragCancelled = false
        cell.alphaValue = 0.25
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dragCancelled = true
            }
            return event
        }
        cell.beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }
    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        defer {
            (window as? TerminalWindow)?.finishTabPointerGesture()
            if let tab = draggedTab {
                cells[tab.id]?.alphaValue = 1
            }
            draggedTab = nil
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }
        guard
            operation.isEmpty, !dragCancelled, NSEvent.pressedMouseButtons == 0,
            let controller, let tab = draggedTab, let source = group(for: tab) else {
            return
        }
        if let window, bounds.insetBy(dx: -12, dy: -12).contains(convert(window.convertPoint(fromScreen: point), from: nil)) {
            return
        }
        if let owner = controller.manager.moveToNewWindow(tab, from: source, activate: false) as? TerminalWindowController {
            owner.window?.setFrameTopLeftPoint(point)
            owner.window?.orderFront(nil)
        }
    }
    private func resolve(_ info: any NSDraggingInfo) -> (TerminalTabGroup, TerminalTab)? {
        guard
            info.draggingSource is TabDragController || info.draggingSource is SidebarTabBarView,
            let data = info.draggingPasteboard.data(forType: TabDropPayload.pasteboardType), let payload = TabDropPayload(data: data),
            let source = controller?.manager.groups.first(where: {
                $0.id == payload.groupID
            }),
            let tab = source.tabs.first(where: {
                $0.id == payload.tabID
            }) else {
            return nil
        }
        return (source, tab)
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard resolve(info) != nil else {
            return []
        }
        if
            let tab = item as? TerminalTab, let group = group(for: tab), let section = model?.sections.first(where: {
                $0.group === group
            }),
            let index = section.tabs.firstIndex(where: {
                $0 === tab
            }) {
            outlineView.setDropItem(group, dropChildIndex: index)
        } else if item == nil {
            return []
        }
        return .move
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard
            let (source, tab) = resolve(info), let target = item as? TerminalTabGroup,
            let section = model?.sections.first(where: {
                $0.group === target
            }), let controller else {
            return false
        }
        let insertion = SidebarModel.insertionIndex(group: target, visible: section.tabs, boundary: index)
        if source === target {
            controller.manager.reorder(tab, in: source, insertion: insertion)
        } else {
            controller.manager.move(tab, from: source, to: target, insertion: insertion)
        }
        return true
    }
}

/// Group controls remain available through the outline and the context menu.
private final class SidebarGroupHeader: NSView {
    let group: TerminalTabGroup
    weak var sidebar: SidebarTabBarView?
    private let title = NSTextField(labelWithString: "")
    private let add = ChromeIconButton(treatment: .pane)
    private let chevron = ChromeIconButton(treatment: .pane)
    private let windowGlyph = NSImageView()
    private let badge = ProgramStatusBadgeView()
    private var editor: InlineNameField?
    private var tracking: NSTrackingArea?
    private var hovered = false
    override var isFlipped: Bool {
        true
    }
    init(group: TerminalTabGroup, sidebar: SidebarTabBarView) {
        self.group = group
        self.sidebar = sidebar
        super.init(frame: .zero)
        title.stringValue = group.name
        setAccessibilityLabel(group.name)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        windowGlyph.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Shown in another window")
        windowGlyph.isHidden = sidebar.controller?.manager.window(showing: group).map {
            $0.id == sidebar.controller?.id
        } ?? true
        add.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "New Tab in \(group.name)")
        add.target = self
        add.action = #selector(newTab)
        chevron.target = self
        chevron.action = #selector(toggleCollapse)
        for view in [title, add, chevron, badge, windowGlyph] {
            addSubview(view)
        }
        add.isHidden = true
        refresh()
    }
    func refresh() {
        setAccessibilityLabel(group.name)
        chevron.image = NSImage(
            systemSymbolName: group.isCollapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: group.isCollapsed ? "Expand \(group.name)" : "Collapse \(group.name)"
        )
        chevron.isHidden = !hovered && !group.isCollapsed
        guard editor == nil else {
            return
        }
        title.stringValue = group.name
        windowGlyph.isHidden = sidebar?.controller?.manager.window(showing: group).map {
            $0.id == sidebar?.controller?.id
        } ?? true
        let status = group.isCollapsed && ProgramActivitySettings.shared.value.showTabs ? group.tabs.map(\.status).max {
            ($0.badge?.rawValue ?? -1) < ($1.badge?.rawValue ?? -1)
        } ?? .none : .none
        badge.configure(status, background: .windowBackgroundColor, colored: ProgramActivitySettings.shared.value.color)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityValue(status.accessibilityValue)
        setAccessibilityExpanded(!group.isCollapsed)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Expand or Collapse Group", handler: { [weak self] in
                self?.accessibilityPerformPress() ?? false
            }),
            NSAccessibilityCustomAction(name: "New Tab", handler: { [weak self] in self?.newTab()
                return true
            })
        ])
    }
    override func accessibilityPerformPress() -> Bool {
        guard let manager = sidebar?.controller?.manager else {
            return false
        }
        manager.setCollapsed(!group.isCollapsed, group: group)
        return true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    override func layout() {
        super.layout()
        title.frame = NSRect(x: 10, y: 4, width: max(0, bounds.width - 86), height: 18)
        chevron.frame = NSRect(x: bounds.width - 24, y: 2, width: 22, height: 22)
        add.frame = NSRect(x: bounds.width - 47, y: 2, width: 22, height: 22)
        windowGlyph.frame = NSRect(x: bounds.width - 73, y: 4, width: 16, height: 16)
        badge.frame = NSRect(x: bounds.width - 95, y: 4, width: 15, height: 15)
        editor?.frame = title.frame
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next)
        tracking = next
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        add.isHidden = false
        chevron.isHidden = false
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        add.isHidden = true
        chevron.isHidden = !group.isCollapsed
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            beginRename()
        } else {
            toggleCollapse()
        }
    }
    @objc private func toggleCollapse() {
        sidebar?.controller?.manager.setCollapsed(!group.isCollapsed, group: group)
    }
    @objc private func newTab() {
        sidebar?.controller?.newTab(in: group)
    }
    func beginRename(onFinish: (() -> Void)? = nil) {
        if let existing = editor {
            if existing.window != nil, existing.beginEditing() {
                return
            }
            existing.cancel()
        }
        guard window != nil, !isHiddenOrHasHiddenAncestor else {
            onFinish?()
            return
        }
        let field = InlineNameField(value: group.name) { [weak self] value in
            guard let self else {
                onFinish?()
                return
            }
            if let value {
                self.sidebar?.controller?.manager.rename(self.group, to: value)
            }
            self.editor?.removeFromSuperview()
            self.editor = nil
            self.title.isHidden = false
            self.sidebar?.controller?.focusSelectedTerminal()
            onFinish?()
        }
        editor = field
        title.isHidden = true
        addSubview(field)
        needsLayout = true
        layoutSubtreeIfNeeded()
        // The outline finishes its mouse/menu focus handling after this callback returns.
        DispatchQueue.main.async { [weak field] in
            field?.beginEditing()
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller = sidebar?.controller else {
            return nil
        }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Rename…") { [weak self] in
            self?.beginRename()
        })
        menu.addItem(ClosureMenuItem("New Tab") { [weak self] in
            self?.newTab()
        })
        menu.addItem(ClosureMenuItem("Close Group") { [weak controller, group] in
            controller?.requestCloseGroup(group)
        })
        menu.addItem(ClosureMenuItem("Close Group and End Sessions") { [weak controller, group] in
            controller?.requestCloseGroupAndEndSessions(group)
        })
        menu.addItem(ClosureMenuItem("Duplicate Group") { [weak controller, group] in
            controller?.manager.duplicate(group)
        })
        menu.addItem(ClosureMenuItem("Collapse Others") { [weak controller, group] in
            controller?.manager.collapseOthers(group)
        })
        for (name, offset) in [("Move Up", -1), ("Move Down", 1)] {
            menu.addItem(ClosureMenuItem(name) { [weak controller, group] in
                controller?.manager.moveGroup(group, offset: offset)
            })
        }
        return menu
    }
}

/// Uses the measured row insets and puts disclosure at the header's trailing edge.
final class SidebarOutlineView: NSOutlineView {
    override func accessibilityChildren() -> [Any]? {
        (0..<numberOfRows).compactMap {
            view(atColumn: 0, row: $0, makeIfNecessary: true)
        }
    }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var rect = super.frameOfCell(atColumn: column, row: row)
        let group = item(atRow: row) is TerminalTabGroup
        let inset: CGFloat = group ? 10 : 9
        if group {
            rect.origin.y += 7
            rect.size.height = 25
        }
        rect.origin.x = inset
        rect.size.width = max(0, bounds.width - inset * 2)
        return rect
    }
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        .zero
    }
}

/// A departing row's short-lived drawing never intercepts an outline action.
private final class SidebarRowSnapshot: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
