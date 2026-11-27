import AppKit
import QuartzCore

/// Above-style window chrome. Cells share one selection surface and scroll track.
final class HorizontalTabBarView: NSView {
    var usesSharedBackdrop = false
    weak var controller: TerminalWindowController?
    weak var activityManager: TerminalWindowManager?
    let groupButton = GroupButton()
    let scroll = TabScrollView()
    private let track = TabTrackView()
    let selectionSurface = TabSelectionSurfaceView()
    let theme = ThemeTitlebarControl()
    private let zoom = ChromeIconButton(treatment: .toolbar)
    private let add = ChromeIconButton(treatment: .toolbar)
    let commandPaletteButton = ChromeIconButton(treatment: .toolbar)
    let activityButton = ChromeIconButton(treatment: .toolbar)
    private let activityBadge = ProgramStatusBadgeView()
    private let activityPopover = ActivityPopover()
    private(set) var cells: [TabItemView] = []
    lazy var dragController = TabDragController(bar: self)
    private var defaultsObserver: DefaultsValueObserver<TabStripPreferences>?
    private var preferences = TabStripPreferences()
    private var activityPreferences = ProgramActivitySettings.shared.value
    private var terminalTheme: TerminalTheme?
    private var opacity = 1.0
    private var observers: [NSObjectProtocol] = []
    private var flagsMonitor: Any?
    private var hintTask: Task<Void, Never>?
    private var hintsShown = false
    private var reflow = false
    private var inserted = Set<UUID>()
    private var mouseSelection = false
    private var lastSelection: UUID?
    private var lastViewportWidth: CGFloat = 0
    private var groupEditor: InlineNameField?
    private var groupName = ""
    private var placeholderIndex: Int?
    private var placeholderTab: UUID?
    private let dropIndicator = NSView()
    override var isFlipped: Bool {
        true
    }
    override var mouseDownCanMoveWindow: Bool {
        false
    }
    var stripLayout: TabStripLayout {
        TabStripLayout(available: scroll.contentView.bounds.width, count: cells.count, fill: preferences.fill)
    }
    private var motion: TabAnimationPolicy {
        TabAnimationPolicy.layout(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            style: preferences.animationStyle
        )
    }
    nonisolated static func showsGroupName(groupCount: Int) -> Bool {
        groupCount > 1
    }
    private var usesNamedCaption: Bool {
        Self.showsGroupName(groupCount: controller?.manager.groups.count ?? 0) || groupEditor != nil
    }

    private func refreshGroupCaption() {
        groupButton.title = usesNamedCaption ? groupName : ""
        groupButton.setAccessibilityValue(groupName)
        groupButton.isHidden = groupEditor != nil
        groupButton.setAccessibilityElement(!groupButton.isHidden)
        needsLayout = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.wantsLayer = true
        track.layer?.cornerRadius = 16
        track.bar = self
        track.setAccessibilityElement(true)
        track.setAccessibilityRole(.group)
        track.setAccessibilityLabel("Tab list")
        track.addSubview(selectionSurface)
        scroll.documentView = track
        scroll.viewportChanged = { [weak self] in
            self?.updateDrawingVisibility()
        }
        groupButton.cell = GroupSelectorCell()
        groupButton.isBordered = false
        groupButton.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        groupButton.imagePosition = .imageLeading
        groupButton.imageScaling = .scaleNone
        groupButton.font = .systemFont(ofSize: 13, weight: .semibold)
        groupButton.alignment = .left
        groupButton.contentTintColor = .labelColor
        groupButton.target = self
        groupButton.action = #selector(groups)
        groupButton.contextMenu = { [weak self] in
            self?.groupContextMenu() ?? NSMenu()
        }
        groupButton.setAccessibilityLabel("Go to Group")
        theme.treatment = .toolbar
        zoom.image = NSImage(
            systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Reset Split Zoom"
        )
        zoom.target = self
        zoom.action = #selector(resetZoom)
        zoom.toolTip = "Reset Split Zoom"
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        add.target = self
        add.action = #selector(newTab)
        activityButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Activity")
        activityButton.target = self
        activityButton.action = #selector(toggleActivity)
        activityButton.setAccessibilityLabel("Activity")
        activityButton.addSubview(activityBadge)
        commandPaletteButton.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Command Palette")
        commandPaletteButton.target = self
        commandPaletteButton.action = #selector(toggleCommandPalette)
        commandPaletteButton.setAccessibilityLabel("Command Palette")
        updateShortcutToolTips()
        for button in [zoom, add, commandPaletteButton, activityButton] {
            button.isBordered = false
        }
        for view in [groupButton, scroll, theme, zoom, add, commandPaletteButton, activityButton] {
            addSubview(view)
        }
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicator.layer?.cornerRadius = 1.5
        dropIndicator.isHidden = true
        track.addSubview(dropIndicator)
        registerForDraggedTypes([TabDropPayload.pasteboardType])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tabs")
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            .programActivityDidChange, .groupsDidChange, .programActivityPreferencesDidChange,
            .appShortcutsDidChange,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self else {
                            return
                        }
                        if note.name == .appShortcutsDidChange {
                            self.updateShortcutToolTips()
                            return
                        }
                        if note.name == .programActivityDidChange || note.name == .groupsDidChange {
                            if note.name == .groupsDidChange, note.object as? TerminalWindowManager === self.controller?.manager {
                                self.refreshGroupCaption()
                            }
                            if note.name == .programActivityDidChange {
                                self.refreshActivity(changedPane: note.object as? TerminalSessionController)
                            }
                            if self.window?.isVisible == true {
                                self.updateActivityBadge()
                            }
                            return
                        }
                        if note.name == .programActivityPreferencesDidChange {
                            let next = TabStripPreferences()
                            let nextActivity = ProgramActivitySettings.shared.value
                            guard next != self.preferences || nextActivity != self.activityPreferences else {
                                return
                            }
                            self.preferences = next
                            self.activityPreferences = nextActivity
                            self.controller?.refreshTabPreferences()
                        }
                        self.refreshChrome()
                        self.needsLayout = true
                        self.updateDrawingVisibility()
                        if self.window?.isKeyWindow != true {
                            self.hideHints()
                        }
                    }
                }
            )
        }
        defaultsObserver = DefaultsValueObserver(defaults: .standard, keys: TabStripPreferences.observedKeys, read: TabStripPreferences.init(defaults:))
        defaultsObserver?.onChange = { [weak self] next in
            guard let self else {
                return
            }
            self.preferences = next
            self.controller?.refreshTabPreferences()
            self.refreshChrome()
            self.needsLayout = true
            self.updateDrawingVisibility()
            if self.window?.isKeyWindow != true {
                self.hideHints()
            }
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.flagsChanged(with: event)
            }
            return event
        }
        statusDrawingSetup()
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
        hintTask?.cancel()
    }
    private func statusDrawingSetup() {
        dropIndicator.setAccessibilityElement(false)
    }

    func apply(theme: TerminalTheme?, opacity: Double) {
        terminalTheme = theme
        self.opacity = opacity
        refreshChrome()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChrome()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshChrome()
    }
    private func refreshChrome() {
        let key = window?.isKeyWindow == true
        let chrome = TabStripChrome(theme: terminalTheme, opacity: opacity, key: key, appearance: effectiveAppearance)
        layer?.backgroundColor = usesSharedBackdrop ? nil : chrome.bar.cgColor
        superview?.layer?.backgroundColor = usesSharedBackdrop ? nil : chrome.bar.cgColor
        track.layer?.backgroundColor = key && stripLayout.showsSurface ? chrome.track.cgColor : NSColor.clear.cgColor
        selectionSurface.apply(chrome: chrome, key: key)
        for cell in cells {
            cell.configure(selected: cell.isSelected, key: key, chrome: chrome, preferences: preferences)
        }
        updateActivityBadge()
        updateDividers()
    }

    /// Progress refreshes only its cell, independently of structural window observation.
    func refreshActivity(changedPane: TerminalSessionController?) {
        let tab = changedPane?.owningTab
        let key = window?.isKeyWindow == true
        let chrome = TabStripChrome(theme: terminalTheme, opacity: opacity, key: key, appearance: effectiveAppearance)
        for cell in cells where tab == nil || cell.tab === tab {
            cell.configure(selected: cell.isSelected, key: key, chrome: chrome, preferences: preferences)
        }
    }

    /// Reduces unseen activity across all live groups for the trailing Activity button.
    private func updateActivityBadge() {
        let statuses = (activityManager?.groups ?? []).flatMap(\.tabs).map(\.status)
        let status = statuses.filter(\.unseen).max {
            ($0.badge?.rawValue ?? -1) < ($1.badge?.rawValue ?? -1)
        } ?? .none
        activityBadge.configure(
            status, background: chromeBackground, colored: ProgramActivitySettings.shared.value.color
        )
        let count = statuses.filter(\.unseen).count
        activityButton.setAccessibilityValue(TabStatus.activityAccessibilityValue(count: count))
    }
    private var chromeBackground: NSColor {
        TabStripChrome(
            theme: terminalTheme, opacity: opacity, key: window?.isKeyWindow == true, appearance: effectiveAppearance
        ).bar
    }
    /// Toggles the shared Activity popup for the button and Command-period shortcut.
    @objc func toggleActivity() {
        guard let controller else {
            return
        }
        activityPopover.toggle(relativeTo: activityButton, owner: controller)
    }

    @objc private func toggleCommandPalette() {
        controller?.toggleCommandPalette()
    }

    func configure(group: TerminalTabGroup) {
        groupName = group.name
        refreshGroupCaption()
        let previous = cells
        let ids = group.tabs.map(\.id)
        reflow = previous.map(\.tab.id) != ids && !previous.isEmpty
        for cell in previous where !ids.contains(cell.tab.id) {
            if motion == .immediate {
                cell.removeFromSuperview()
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = motion == .crossfade ? 0.12 : 0.2
                    cell.animator().alphaValue = 0
                    if motion == .moving {
                        cell.animator().frame = NSRect(x: cell.frame.midX, y: 0, width: 0, height: 32)
                    }
                } completionHandler: {
                    cell.removeFromSuperview()
                }
            }
        }
        inserted = Set(ids).subtracting(previous.map(\.tab.id))
        cells = group.tabs.map { tab in
            previous.first {
                $0.tab === tab
            }
                ?? {
                    let cell = TabItemView(tab: tab, controller: controller)
                    cell.bar = self
                    track.addSubview(cell, positioned: .above, relativeTo: selectionSurface)
                    if !previous.isEmpty && motion != .immediate {
                        cell.alphaValue = 0
                    }
                    return cell
                }()
        }
        for (index, cell) in cells.enumerated() {
            cell.configure(selected: cell.tab.id == group.selectedTab?.id)
            cell.setHint(hintsShown && index < 9 ? index + 1 : nil)
        }
        let workspace = group.selectedTab?.loadedWorkspace
        zoom.isHidden = workspace?.zoomedControllerID == nil
        theme.configure(controller: workspace?.focusedController)
        refreshChrome()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let fullscreen = controller?.isFullScreen ?? (window?.styleMask.contains(.fullScreen) == true)
        let groupWidth = usesNamedCaption ? min(190, max(105, groupButton.intrinsicContentSize.width + 8)) : 34
        groupButton.frame = NSRect(x: fullscreen ? 8 : 85, y: usesNamedCaption ? 5 : 7, width: groupWidth, height: usesNamedCaption ? 36 : 32)
        groupEditor?.frame = groupButton.frame.insetBy(dx: 2, dy: 6)
        add.frame = NSRect(x: bounds.width - 41, y: 7, width: 35, height: 32)
        let zoomWidth: CGFloat = zoom.isHidden ? 0 : 34
        zoom.frame = NSRect(x: add.frame.minX - zoomWidth, y: 7, width: zoomWidth, height: 32)
        theme.frame = NSRect(x: zoom.frame.minX - 34, y: 7, width: 35, height: 32)
        commandPaletteButton.frame = NSRect(x: theme.frame.minX - 34, y: 7, width: 35, height: 32)
        let activityStart = commandPaletteButton.frame.minX - 34
        activityButton.frame = NSRect(x: activityStart, y: 7, width: 35, height: 32)
        activityBadge.frame = NSRect(x: 19, y: 3, width: 13, height: 13)
        let start = groupButton.frame.maxX + 8
        scroll.frame = NSRect(x: start, y: 7, width: max(0, activityStart - start - 8), height: 32)
        let geometry = stripLayout
        let extraGap = placeholderTab.map { id in
            cells.contains {
                $0.tab.id == id
            } ? CGFloat(0) : geometry.step
        } ?? 0
        track.frame = NSRect(x: 0, y: 0, width: max(geometry.contentWidth + extraGap, scroll.bounds.width), height: 32)
        // The track is only as long as the tabs, even when the viewport is wider.
        track.layer?.backgroundColor = NSColor.clear.cgColor
        track.surfaceFrame = NSRect(x: 0, y: 0, width: geometry.contentWidth + extraGap, height: 32)
        track.surfaceColor =
            window?.isKeyWindow == true && geometry.showsSurface
                ? TabStripChrome(theme: terminalTheme, opacity: opacity, key: true, appearance: effectiveAppearance).track
                : .clear
        for (index, cell) in cells.enumerated() {
            var destination = geometry.frame(at: index)
            if let boundary = placeholderIndex, let dragged = placeholderTab {
                let remaining = cells.filter {
                    $0.tab.id != dragged
                }
                if cell.tab.id == dragged {
                    cell.alphaValue = 0.25
                    destination.origin.x = CGFloat(boundary) * geometry.step
                } else if
                    let position = remaining.firstIndex(where: {
                        $0 === cell
                    }) {
                    destination.origin.x = CGFloat(position >= boundary ? position + 1 : position) * geometry.step
                }
            }
            if reflow && motion == .moving && !inserted.contains(cell.tab.id) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    cell.animator().frame = destination
                }
            } else {
                cell.frame = destination
            }
            if inserted.contains(cell.tab.id), cell.alphaValue < 1 {
                if motion == .moving {
                    let final = destination
                    cell.frame = NSRect(x: destination.minX, y: 0, width: 0, height: 32)
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.2
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        cell.animator().frame = final
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak cell] in
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = 0.1
                            cell?.animator().alphaValue = 1
                        }
                    }
                } else {
                    cell.animator().alphaValue = 1
                }
            }
        }
        if let index = cells.firstIndex(where: \.isSelected) {
            let id = cells[index].tab.id
            let key = window?.isKeyWindow == true
            selectionSurface.isHidden = !geometry.showsSurface || placeholderTab == id
            var rect = geometry.frame(at: index)
            if
                let boundary = placeholderIndex, let dragged = placeholderTab,
                let remainingIndex = cells.filter({
                    $0.tab.id != dragged
                }).firstIndex(where: {
                    $0 === cells[index]
                }) {
                rect.origin.x =
                    CGFloat(remainingIndex >= boundary ? remainingIndex + 1 : remainingIndex) * geometry.step
            }
            rect = rect.insetBy(dx: 1, dy: key ? 0.5 : 1)
            selectionSurface.move(
                to: rect, animated: mouseSelection && id != lastSelection && motion == .moving && !reflow
            )
            if placeholderIndex == nil && (lastSelection != id || reflow || lastViewportWidth != geometry.available) {
                let offset = geometry.offset(revealing: index, from: scroll.contentView.bounds.minX)
                scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            lastSelection = id
        } else {
            selectionSurface.isHidden = true
        }
        if let placeholderIndex {
            dropIndicator.frame = NSRect(x: CGFloat(placeholderIndex) * geometry.step, y: 3, width: 3, height: 26)
        }
        dropIndicator.isHidden = placeholderIndex == nil
        scroll.updateFade()
        lastViewportWidth = geometry.available
        inserted = []
        reflow = false
        mouseSelection = false
        updateDrawingVisibility()
    }

    func selectByMouse(_ tab: TerminalTab) {
        mouseSelection = controller?.group.selection != tab.id
        controller?.select(tab)
    }
    func updateDividers() {
        for (index, cell) in cells.enumerated() {
            let next = cells.indices.contains(index + 1) ? cells[index + 1] : nil
            cell.showDivider(
                next != nil && !cell.isSelected && !cell.isHovered && next?.isSelected != true
                    && next?.isHovered != true
            )
        }
    }
    func hasVisibleCell(for tab: TerminalTab) -> Bool {
        guard
            !isHidden, window?.isVisible == true, window?.isMiniaturized == false,
            window?.occlusionState.contains(.visible) == true,
            let index = cells.firstIndex(where: {
                $0.tab === tab
            }) else {
            return false
        }
        return stripLayout.visibleIndices(offset: scroll.contentView.bounds.minX).contains(index)
    }
    func updateDrawingVisibility() {
        let visible = !isHidden && window?.occlusionState.contains(.visible) == true && !NSApp.isHidden
        let range = stripLayout.visibleIndices(offset: scroll.contentView.bounds.minX)
        for (index, cell) in cells.enumerated() {
            cell.setDrawingVisible(visible && range.contains(index))
            cell.tab.loadedWorkspace?.updateProcessInspection()
        }
    }
    func updateShortcutToolTips() {
        let shortcuts = AppShortcutStore.shared
        groupButton.toolTip = shortcuts.toolTip("Go to Group", for: .goToGroup)
        add.toolTip = shortcuts.toolTip("New Tab", for: .newTab)
        activityButton.toolTip = shortcuts.toolTip("Activity", for: .activity)
        commandPaletteButton.toolTip = shortcuts.toolTip("Command Palette", for: .commandPalette)
    }

    override func flagsChanged(with event: NSEvent) {
        hintTask?.cancel()
        guard
            window?.isKeyWindow == true, UserDefaults.standard.bool(forKey: TabSelectionCommands.useCommandDigitsForTabsKey),
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        else {
            hideHints()
            return
        }
        hintTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return
            }
            guard let self, self.window?.isKeyWindow == true else {
                return
            }
            self.hintsShown = true
            for (index, cell) in self.cells.enumerated() {
                cell.setHint(index < 9 ? index + 1 : nil)
            }
        }
    }
    private func hideHints() {
        hintTask?.cancel()
        hintsShown = false
        for cell in cells {
            cell.setHint(nil)
        }
    }
    func beginTabRename(_ tab: TerminalTab) {
        cells.first {
            $0.tab === tab
        }?.beginRename()
    }
    func beginGroupRename() {
        guard let controller, groupEditor == nil else {
            return
        }
        let editor = InlineNameField(value: controller.group.name) { [weak self] value in
            guard let self else {
                return
            }
            if let value {
                self.controller?.setGroupName(value)
            }
            self.groupEditor?.removeFromSuperview()
            self.groupEditor = nil
            self.refreshGroupCaption()
            self.controller?.focusSelectedTerminal()
        }
        groupEditor = editor
        refreshGroupCaption()
        addSubview(editor)
        needsLayout = true
        layoutSubtreeIfNeeded()
        editor.beginEditing()
    }
    private func groupContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("New Group") { [weak self] in
            self?.controller?.newGroup()
        })
        menu.addItem(ClosureMenuItem("Rename Group…") { [weak self] in
            self?.beginGroupRename()
        })
        menu.addItem(
            ClosureMenuItem("Duplicate Group") { [weak self] in
                guard let owner = self?.controller else {
                    return
                }
                owner.manager.duplicate(owner.group)
            }
        )
        menu.addItem(ClosureMenuItem("Close Group") { [weak self] in
            self?.controller?.requestCloseGroup()
        })
        menu.addItem(ClosureMenuItem("Close Group and End Sessions") { [weak self] in
            self?.controller?.requestCloseGroupAndEndSessions()
        })
        return menu
    }
    func showDrop(at index: Int?, tabID: UUID? = nil) {
        placeholderIndex = index
        placeholderTab = tabID
        if index == nil {
            cells.forEach {
                $0.alphaValue = 1
            }
        }
        reflow = true
        needsLayout = true
    }
    func dropIndex(screenPoint: NSPoint) -> Int {
        guard let window else {
            return cells.count
        }
        let local = track.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return stripLayout.insertionIndex(at: local.x)
    }
    func autoscrollDrop(screenPoint: NSPoint) {
        guard let window else {
            return
        }
        let point = scroll.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let delta: CGFloat = point.x < 24 ? -12 : point.x > scroll.bounds.width - 24 ? 12 : 0
        let maximum = max(0, track.frame.width - scroll.bounds.width)
        scroll.contentView.scroll(to: NSPoint(x: max(0, min(maximum, scroll.contentView.bounds.minX + delta)), y: 0))
    }
    @objc private func groups() {
        controller?.showGroups()
    }
    @objc private func newTab() {
        controller?.newTab()
    }
    @objc private func resetZoom() {
        controller?.group.selectedTab?.loadedWorkspace?.clearSplitZoom()
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            controller?.newTab()
        } else {
            window?.performDrag(with: event)
        }
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragController.update(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragController.update(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        showDrop(at: nil)
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dragController.accepts(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dragController.drop(sender)
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        showDrop(at: nil)
    }
}

private final class TabTrackView: NSView {
    weak var bar: HorizontalTabBarView?
    var surfaceFrame = NSRect.zero {
        didSet { needsDisplay = true }
    }
    var surfaceColor = NSColor.clear {
        didSet { needsDisplay = true }
    }
    override func accessibilityChildren() -> [Any]? {
        bar?.cells ?? []
    }
    override var isFlipped: Bool {
        true
    }
    override var mouseDownCanMoveWindow: Bool {
        false
    }
    override func draw(_ dirtyRect: NSRect) {
        surfaceColor.setFill()
        NSBezierPath(roundedRect: surfaceFrame, xRadius: 16, yRadius: 16).fill()
    }
    override func mouseDown(with event: NSEvent) {
        bar?.mouseDown(with: event)
    }
}

final class GroupButton: NSButton {
    var contextMenu: (() -> NSMenu)?
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var tracking: NSTrackingArea?
    private(set) var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        if title.isEmpty {
            return NSSize(width: 34, height: 32)
        }
        let width = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
        return NSSize(width: ceil(width) + 42, height: 36)
    }

    override var isHidden: Bool {
        didSet {
            synchronizeHoverWithPointer()
        }
    }

    override var isEnabled: Bool {
        didSet {
            synchronizeHoverWithPointer()
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        setHovered(false)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        synchronizeHoverWithPointer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeHoverWithPointer()
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        synchronizeHoverWithPointer()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        synchronizeHoverWithPointer()
    }

    private func synchronizeHoverWithPointer() {
        if let window, !isHiddenOrHasHiddenAncestor, isEnabled {
            let point = convert(window.convertPoint(fromScreen: pointerLocation()), from: nil)
            setHovered(bounds.contains(point) && visibleRect.contains(point))
        } else {
            setHovered(false)
        }
    }

    func setHovered(_ next: Bool) {
        guard hovered != next else {
            return
        }
        hovered = next
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard event.trackingArea === tracking else {
            return
        }
        if isEnabled, !isHiddenOrHasHiddenAncestor {
            setHovered(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard event.trackingArea === tracking else {
            return
        }
        setHovered(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered, isEnabled, !isHiddenOrHasHiddenAncestor {
            let inset: CGFloat = title.isEmpty ? 0 : 2
            let pillRect = bounds.insetBy(dx: 0, dy: inset)
            if pillRect.width > 0, pillRect.height > 0 {
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let path = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
                ChromeIconButton.highlightColor(dark: dark, increasedContrast: contrast, treatment: .toolbar).setFill()
                path.fill()
                if contrast {
                    NSColor.secondaryLabelColor.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        highlight(true)
        defer {
            highlight(false)
            synchronizeHoverWithPointer()
        }
        if let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        defer { synchronizeHoverWithPointer() }
        super.rightMouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        highlight(false)
        synchronizeHoverWithPointer()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        setHovered(false)
        return contextMenu?()
    }
}

/// Keeps the selector's leading icon and text at the measured Rex insets.
final class GroupSelectorCell: NSButtonCell {
    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        super.drawImage(image, withFrame: imageRect(forBounds: controlView.bounds), in: controlView)
    }

    /// NSButtonCell otherwise centers a short name inside the reserved title rectangle.
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        guard !title.string.isEmpty else {
            return .zero
        }
        let rect = titleRect(forBounds: controlView.bounds)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: title.string, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
            .paragraphStyle: paragraph
        ]).draw(in: rect)
        return rect
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        // The system stack glyph has an optical inset inside its image rectangle.
        NSRect(x: rect.minX + 10.5, y: rect.midY - 8, width: 16, height: 16)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        title.isEmpty ? .zero : NSRect(x: rect.minX + 36, y: rect.midY - 8, width: max(0, rect.width - 44), height: 16)
    }
}
