import AppKit
import Observation
import QuartzCore
import TecolotSessionDirectory

/// Owns one terminal window and mounts every tab of its current group.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, TerminalGroupWindow {
    let id = UUID()
    private(set) var group: TerminalTabGroup
    // AppKit can retain a closed controller until the next event-loop turn.
    let manager: TerminalWindowManager
    private let content = TerminalWindowContentView()
    let tabBar = HorizontalTabBarView()
    let sidebar: SidebarTabBarView
    let contentHeader = ContentHeaderView()
    let paneHeaderControls = PaneWindowControlsView()
    private let cardOutlines = PaneCardOutlineOverlay(frame: .zero)
    private weak var outlinedHost: TerminalPaneHostView?
    let chromeBackdrop = TerminalWorkspaceBackdropView(frame: .zero)
    private(set) var trafficLightCardID: UUID?
    private(set) var topRightCardID: UUID?
    private(set) var chromeColor = NSColor.windowBackgroundColor
    private var backdropUsesCards = false
    private let resizeHandle = SidebarResizeHandle()
    private let defaults: UserDefaults
    private(set) var sidebarPreferences: SidebarPreferences
    private var sidebarObserver: NSObjectProtocol?
    private var activityObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var animateChrome = false
    private var mountedTabs: [TerminalTab] = []
    private var promptVisibility: [UUID] = []
    private let safeModeMessage: NSTextField = {
        let label = NSTextField(wrappingLabelWithString:
            "Tecolot did not finish starting last time. Your groups are kept; start them when you are ready.")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        return label
    }()
    private lazy var startGroupButton: NSButton = {
        let button = NSButton(title: "Start Group", target: self, action: #selector(startDormantGroup))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.refusesFirstResponder = false
        button.setAccessibilityLabel("Start Group")
        return button
    }()

    @objc private func startDormantGroup() {
        _ = manager.show(group, in: self)
    }

    private(set) var windowedFrame: NSRect?
    var restorationFrame: NSRect {
        if enteringFullScreen || window?.styleMask.contains(.fullScreen) == true {
            return windowedFrame ?? window?.frame ?? .zero
        }
        return window?.frame ?? .zero
    }
    private var enteringFullScreen = false
    private var observationGeneration = 0
    private let preferences: TerminalWindowPreferences
    private var trafficLightObservers: [NSObjectProtocol] = []
    private var observedTrafficLights: [NSButton] = []
    private var isPositioningTrafficLights = false
    private var trafficLightLayoutScheduled = false
    var groupPresenter: any GroupSwitcherPresenting = GroupSwitcherPanel()
    private let resumeRemotePrompts: @MainActor () -> Void

    init(group: TerminalTabGroup, manager: TerminalWindowManager, defaults: UserDefaults = .standard, resumeRemotePrompts: @escaping @MainActor () -> Void = {
        RemoteHosts.shared.resumePendingPrompts()
    }, sidebar suppliedSidebar: SidebarTabBarView? = nil) {
        self.group = group
        self.manager = manager
        self.defaults = defaults
        self.resumeRemotePrompts = resumeRemotePrompts
        self.sidebar = suppliedSidebar ?? SidebarTabBarView()
        sidebarPreferences = SidebarPreferences(defaults: defaults)
        preferences = TerminalWindowPreferences(defaults: defaults)
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 220)
        content.wantsLayer = true
        window.contentView = content
        content.addSubview(chromeBackdrop)
        content.addSubview(tabBar)
        content.addSubview(sidebar)
        content.addSubview(contentHeader)
        content.addSubview(cardOutlines)
        content.addSubview(paneHeaderControls)
        content.addSubview(resizeHandle)
        tabBar.usesSharedBackdrop = true
        sidebar.usesSharedBackdrop = true
        paneHeaderControls.controller = self
        sidebar.controller = self
        contentHeader.controller = self
        resizeHandle.controller = self
        content.onSwipe = { [weak self] event in
            self?.handleSidebarSwipe(event)
        }
        sidebarObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSidebarPreferences()
            }
        }
        activityObserver = NotificationCenter.default.addObserver(forName: .programActivityDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.window?.title = "\(self.group.selectedTab?.title ?? "Terminal") — \(self.group.name)"
                self.contentHeader.refresh()
                self.paneHeaderControls.refresh()
            }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                NotificationCenter.default.post(name: .programActivityDidChange, object: self)
            }
        }
        content.onLayout = { [weak self] in
            self?.layoutContent()
        }
        tabBar.controller = self
        tabBar.activityManager = manager
        preferences.onChange = { [weak self] in
            self?.refresh()
        }
        observeTrafficLights()
        show(group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        for observer in trafficLightObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let sidebarObserver {
            NotificationCenter.default.removeObserver(sidebarObserver)
        }
        if let activityObserver {
            NotificationCenter.default.removeObserver(activityObserver)
        }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    func toggleActivity() {
        if sidebarPreferences.style == .above {
            tabBar.toggleActivity()
        } else if !paneHeaderControls.isHidden {
            paneHeaderControls.toggleActivity()
        } else if sidebarPreferences.hidden {
            contentHeader.toggleActivity()
        } else {
            sidebar.toggleActivity()
        }
    }

    /// Changes chrome without replacing the selected terminal or its first responder.
    func refreshSidebarPreferences() {
        let next = SidebarPreferences(defaults: defaults)
        guard next != sidebarPreferences else {
            return
        }
        animateChrome = next.style != sidebarPreferences.style || next.hidden != sidebarPreferences.hidden
        sidebarPreferences = next
        refresh()
    }

    func toggleSidebar() {
        guard sidebarPreferences.style != .above else {
            return
        }
        defaults.set(!sidebarPreferences.hidden, forKey: SidebarPreferences.hiddenKey)
        refreshSidebarPreferences()
    }

    func resizeSidebar(to width: CGFloat, originalFrame: NSRect, originalWidth: CGFloat) {
        let width = SidebarPreferences.clampWidth(width)
        if !sidebarPreferences.preserveWidth, let window, !window.styleMask.contains(.fullScreen), !window.isZoomed {
            var frame = originalFrame
            frame.size.width += width - originalWidth
            if sidebarPreferences.style == .left {
                frame.origin.x -= width - originalWidth
            }
            window.setFrame(frame, display: true)
        }
        defaults.set(Double(width), forKey: SidebarPreferences.widthKey)
        refreshSidebarPreferences()
    }

    private func handleSidebarSwipe(_ event: NSEvent) {
        let option = event.modifierFlags.contains(.option)
        let gesture = sidebarPreferences.gesture
        if abs(event.deltaX) > abs(event.deltaY), (gesture == "swipe" && !option) || (gesture == "optionSwipe" && option) {
            toggleSidebar()
        }
    }

    func selectNumberedTab(_ index: Int) {
        if sidebarPreferences.style == .above {
            manager.selectTab(at: index, in: group)
        } else {
            sidebar.selectNumber(index)
        }
    }

    func show(_ group: TerminalTabGroup) {
        self.group = group
        refresh()
        observe()
    }

    private func refresh() {
        let tabs = group.tabs.filter {
            !$0.isDormant
        }
        if group.selectedTab?.isDormant == true {
            if startGroupButton.superview == nil {
                content.addSubview(safeModeMessage)
                content.addSubview(startGroupButton)
                window?.initialFirstResponder = startGroupButton
                window?.recalculateKeyViewLoop()
                window?.makeFirstResponder(startGroupButton)
            }
        } else {
            if window?.initialFirstResponder === startGroupButton {
                window?.initialFirstResponder = nil
            }
            if window?.firstResponder === startGroupButton {
                window?.makeFirstResponder(window)
            }
            safeModeMessage.removeFromSuperview()
            startGroupButton.removeFromSuperview()
        }
        for tab in mountedTabs where !tabs.contains(where: {
            $0 === tab
        }) {
            tab.loadedWorkspace?.controllers.forEach {
                $0.setProgramStatusDrawingVisible(false)
            }
            for card in tab.hostView.visibleCards {
                card.setOutlineContainer(nil)
            }
            if outlinedHost === tab.hostView {
                outlinedHost = nil
            }
            tab.hostView.removeFromSuperview()
        }
        mountedTabs = tabs
        for tab in tabs {
            let host = tab.hostView
            if host.superview !== content {
                content.addSubview(host, positioned: .below, relativeTo: tabBar)
            }
            host.usesWindowBackdrop = true
            host.requiresWindowHeader = preferences.value.paneStyle == .comfortable
                && sidebarPreferences.style != .above
                && (sidebarPreferences.style == .right || sidebarPreferences.hidden)
            host.onCardLayout = { [weak self] host in
                guard let self, self.group.selectedTab?.loadedWorkspace?.hostView === host else {
                    return
                }
                self.configureIntegratedHeaders(in: host)
            }
            host.isHidden = tab.id != group.selectedTab?.id
            tab.loadedWorkspace?.controllers.forEach {
                $0.setProgramStatusDrawingVisible(!host.isHidden)
            }
            host.synchronize(revision: tab.workspace.revision, settings: preferences.value)
        }
        // Resume only after a mounting or tab-visibility transition.
        let visibility = tabs.map(\.id) + [group.selectedTab?.id].compactMap {
            $0
        }
        if visibility != promptVisibility {
            promptVisibility = visibility
            resumeRemotePrompts()
        }
        let selected = group.selectedTab
        if let window, let selected, !selected.isDormant {
            let responder = window.firstResponder
            let followsTab = responder == nil || responder === window
                || responder is AppTerminalView || responder is RemoteTerminalView
            if followsTab, (responder as? NSView)?.isDescendant(of: selected.hostView) != true {
                window.makeFirstResponder(selected.workspace.focusedController?.surface)
            }
        }
        let pane = chromeController
        window?.title = "\(selected?.title ?? "Terminal") — \(group.name)"
        if let window {
            let theme = pane?.profile.useThemeColorsForWindowChrome == false ? nil : pane?.effectiveTheme
            TerminalWindowAppearance.apply(theme: theme, to: window)
            tabBar.apply(theme: theme, opacity: pane?.effectiveBackgroundOpacity ?? 1)
        }
        tabBar.isHidden = sidebarPreferences.style != .above
        sidebar.isHidden = sidebarPreferences.style == .above || sidebarPreferences.hidden
        resizeHandle.isHidden = sidebar.isHidden
        contentHeader.isHidden = sidebarPreferences.style == .above || (sidebarPreferences.style == .left && !sidebarPreferences.hidden)
        sidebar.apply(
            theme: pane?.profile.useThemeColorsForWindowChrome == false ? nil : pane?.effectiveTheme,
            opacity: pane?.effectiveBackgroundOpacity ?? 1
        )
        contentHeader.refresh()
        paneHeaderControls.refresh()
        refreshWindowBackdrop()
        tabBar.configure(group: group)
        tabBar.updateDrawingVisibility()
        sidebar.updateDrawingVisibility()
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
    }

    /// The controller the window chrome follows. Focus is briefly nil while a
    /// pane is torn down or before the first pane is built; falling back to the
    /// root pane keeps the titlebar on the profile theme instead of flashing
    /// the built-in dark fallback.
    private var chromeController: TerminalSessionController? {
        let workspace = group.selectedTab?.loadedWorkspace
        return workspace?.focusedController ?? workspace?.controllers.first
    }

    private func observe() {
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking {
            _ = group.name
            _ = group.selection
            for tab in group.tabs {
                _ = tab.customName
                _ = tab.isMuted
                guard let workspace = tab.loadedWorkspace else {
                    continue
                }
                _ = workspace.revision
                _ = workspace.focusedControllerID
                _ = workspace.focusHistory
                _ = workspace.zoomedControllerID
                for pane in workspace.controllers {
                    _ = pane.windowPresentation
                    _ = pane.profile
                    _ = pane.themeOverride
                    _ = pane.showThemePicker
                    _ = pane.effectiveBackgroundOpacity
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else {
                    return
                }
                self.refresh()
                self.observe()
            }
        }
    }

    /// One full-window surface prevents both seams and repeated alpha compositing.
    private func refreshWindowBackdrop() {
        let pane = chromeController
        let theme = pane?.profile.useThemeColorsForWindowChrome == false ? nil : pane?.effectiveTheme
        chromeColor = TabStripChrome(
            theme: theme,
            opacity: pane?.effectiveBackgroundOpacity ?? 1,
            key: window?.isKeyWindow == true,
            appearance: window?.effectiveAppearance ?? content.effectiveAppearance
        ).bar
        backdropUsesCards = group.selectedTab?.loadedWorkspace?.hostView?.cardsEnabled == true
            && preferences.value.paneStyle == .comfortable
        chromeBackdrop.update(
            visible: true,
            backdrop: backdropUsesCards ? preferences.value.paneCardsBackdrop : .chrome,
            appearance: ResolvedWorkspaceAppearance(theme: pane?.effectiveTheme ?? .fallback),
            opacity: pane?.effectiveBackgroundOpacity ?? 1,
            chromeColor: chromeColor
        )
        for tab in mountedTabs {
            tab.hostView.windowShowsDesktopBlur = chromeBackdrop.showsDesktopBlur
        }
        if group.selectedTab?.loadedWorkspace?.hostView == nil {
            chromeBackdrop.excludeCards([])
        }
        group.selectedTab?.loadedWorkspace?.updateWindowTransparency()
    }

    private var integratesCardHeaders: Bool {
        let host = group.selectedTab?.loadedWorkspace?.hostView
        return sidebarPreferences.style != .above
            && (sidebarPreferences.style == .right || sidebarPreferences.hidden)
            && host?.cardsEnabled == true && host?.appliedPaneStyle == .comfortable
    }

    /// Card identities come from current frames, rather than split-tree ordering.
    private func configureIntegratedHeaders(in host: TerminalPaneHostView) {
        if outlinedHost !== host {
            outlinedHost?.visibleCards.forEach {
                $0.setOutlineContainer(nil)
            }
            outlinedHost = host
        }
        cardOutlines.update(cards: host.visibleCards)
        let integrated = integratesCardHeaders
        let needsHeader = sidebarPreferences.style != .above
            && (sidebarPreferences.style == .right || sidebarPreferences.hidden) && !integrated
        if contentHeader.isHidden == needsHeader {
            contentHeader.isHidden = !needsHeader
            content.needsLayout = true
        }
        let usesCards = host.cardsEnabled && host.appliedPaneStyle == .comfortable
        if backdropUsesCards != usesCards {
            refreshWindowBackdrop()
        }
        let frames = Dictionary(uniqueKeysWithValues: host.visibleCards.map {
            ($0.controller.id, $0.convert($0.bounds, to: host))
        })
        let corners = PaneCardGeometry.topCorners(in: frames)
        trafficLightCardID = integrated ? corners.left : nil
        topRightCardID = integrated ? corners.right : nil
        let fullscreen = window?.styleMask.contains(.fullScreen) == true
        let leftToggle: CGFloat = sidebarPreferences.hidden && sidebarPreferences.style == .left ? (fullscreen ? 32 : 40) : 0
        for card in host.visibleCards {
            card.integratedWindowHeader = integrated
            card.windowLeadingInset = integrated && card.controller.id == corners.left
                ? (fullscreen ? 0 : 76) + leftToggle : 0
            card.windowTrailingInset = integrated && sidebarPreferences.hidden && card.controller.id == corners.right
                ? paneHeaderControls.trailingWidth : 0
        }
        chromeBackdrop.excludeCards(host.visibleCards.filter {
            $0.controller.effectiveBackgroundOpacity < 1
        }.map {
            $0.convert($0.bounds, to: chromeBackdrop)
        })
        positionTrafficLights()
    }

    private func layoutContent() {
        chromeBackdrop.frame = content.bounds
        cardOutlines.frame = content.bounds
        tabBar.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: 46)
        let style = sidebarPreferences.style
        let sideWidth = sidebar.isHidden ? 0 : sidebarPreferences.width
        let left = style == .left && !sidebar.isHidden
        sidebar.frame = NSRect(
            x: style == .right ? content.bounds.width - sideWidth : 0,
            y: 0,
            width: sideWidth,
            height: content.bounds.height
        )
        resizeHandle.frame = NSRect(
            x: left ? sideWidth - 3 : content.bounds.width - sideWidth - 3,
            y: 38,
            width: 6,
            height: max(0, content.bounds.height - 38)
        )
        let card = style == .above
            ? NSRect(x: 8, y: 46, width: max(0, content.bounds.width - 16), height: max(0, content.bounds.height - 54))
            : NSRect(x: left ? sideWidth : 8, y: 8, width: max(0, content.bounds.width - sideWidth - (sidebar.isHidden ? 16 : 8)), height: max(0, content.bounds.height - 16))
        contentHeader.isHidden = style == .above || (style == .left && !sidebarPreferences.hidden) || integratesCardHeaders
        paneHeaderControls.isHidden = !integratesCardHeaders || !sidebarPreferences.hidden
        paneHeaderControls.frame = NSRect(x: card.minX, y: card.minY, width: card.width, height: 36)
        let headerHeight: CGFloat = contentHeader.isHidden ? 0 : 36
        contentHeader.frame = NSRect(x: card.minX, y: card.minY, width: card.width, height: 36)
        let rect = NSRect(x: card.minX, y: card.minY + headerHeight, width: card.width, height: max(0, card.height - headerHeight))
        for tab in mountedTabs {
            tab.hostView.windowCardInsets = .window
            let previousFrame = tab.hostView.frame
            tab.hostView.frame = rect
            tab.hostView.wantsLayer = true
            tab.hostView.layer?.cornerRadius = 0
            let decoratedCards = tab.hostView.cardsEnabled && tab.hostView.appliedPaneStyle.showsDecorations
            tab.hostView.layer?.masksToBounds = style != .above && !decoratedCards
            if style == .above || decoratedCards {
                tab.hostView.layer?.mask = nil
            } else {
                applyCardMask(to: tab.hostView, rect: NSRect(x: 0, y: tab.hostView.isFlipped ? -headerHeight : 0, width: card.width, height: card.height))
            }
            tab.hostView.layoutSubtreeIfNeeded()
            if tab === group.selectedTab {
                configureIntegratedHeaders(in: tab.hostView)
            }
            if animateChrome {
                SidebarMotion.move(tab.hostView, from: previousFrame)
            }
        }
        if !contentHeader.isHidden {
            applyCardMask(to: contentHeader, rect: NSRect(origin: .zero, size: card.size))
        }
        animateChrome = false
        sidebar.layoutSubtreeIfNeeded()
        contentHeader.layoutSubtreeIfNeeded()
        paneHeaderControls.layoutSubtreeIfNeeded()
        let messageWidth = max(0, min(560, rect.width - 48))
        let messageHeight = safeModeMessage.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: messageWidth, height: .greatestFiniteMagnitude)).height ?? 40
        let top = rect.midY - (messageHeight + 16 + 32) / 2
        safeModeMessage.frame = NSRect(
            x: (rect.width - messageWidth) / 2,
            y: top,
            width: messageWidth,
            height: messageHeight
        )
        startGroupButton.frame = NSRect(
            x: max(0, (rect.width - 160) / 2),
            y: safeModeMessage.frame.maxY + 16,
            width: 160,
            height: 32
        )
        positionTrafficLights()
    }

    /// Clips each piece against the same rounded card, keeping their shared edge straight.
    private func applyCardMask(to view: NSView, rect: NSRect) {
        let mask = view.layer?.mask as? CAShapeLayer ?? CAShapeLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = view.bounds
        mask.path = PaneCardGeometry.path(in: rect)
        view.layer?.mask = mask
        CATransaction.commit()
    }

    /// Keeps the buttons centered even when AppKit lays out the titlebar again.
    func positionTrafficLights() {
        let fullscreen = window?.styleMask.contains(.fullScreen) == true
        if fullscreen {
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(type)?.isHidden = true
            }
        }
        guard !fullscreen, !isPositioningTrafficLights else {
            return
        }
        isPositioningTrafficLights = true
        defer { isPositioningTrafficLights = false }
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window?.standardWindowButton(type), let parent = button.superview else {
                continue
            }
            button.isHidden = false
            let inset: CGFloat = sidebarPreferences.style == .above ? 15 : 17
            let rect = NSRect(x: inset + CGFloat(index) * 23, y: inset, width: 16, height: 16)
            let frame = content.convert(rect, to: parent)
            if button.frame != frame {
                button.frame = frame
            }
        }
    }

    private func observeTrafficLights() {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap {
                window?.standardWindowButton($0)
            }
        guard buttons != observedTrafficLights else {
            return
        }
        for observer in trafficLightObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        observedTrafficLights = buttons
        trafficLightObservers = buttons.map { button in
            button.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: button,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isPositioningTrafficLights else {
                        return
                    }
                    self.scheduleTrafficLightLayout()
                }
            }
        }
    }

    private func scheduleTrafficLightLayout() {
        guard !trafficLightLayoutScheduled else {
            return
        }
        trafficLightLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.trafficLightLayoutScheduled = false
            self.observeTrafficLights()
            self.positionTrafficLights()
        }
    }

    var isManaged: Bool {
        manager.windows.contains {
            $0.id == id
        }
    }

    func activate() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
        group.selectedTab?.loadedWorkspace?.focusedController?.requestFocus()
    }

    func closeWindow() {
        for tab in mountedTabs {
            tab.hostView.removeFromSuperview()
        }
        mountedTabs = []
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        manager.closeWindow(self)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        manager.closeWindow(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshWindowBackdrop()
        scheduleTrafficLightLayout()
        group.lastShownAt = Date()
        group.selectedTab?.loadedWorkspace?.focusedController?.requestFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        refreshWindowBackdrop()
        scheduleTrafficLightLayout()
    }
    func windowDidResize(_ notification: Notification) {
        scheduleTrafficLightLayout()
        manager.persistenceDidChange?(false)
    }
    func windowDidMove(_ notification: Notification) {
        manager.persistenceDidChange?(false)
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        windowedFrame = window?.frame
        enteringFullScreen = true
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        enteringFullScreen = false
        windowedFrame = nil
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        enteringFullScreen = false
        if NSApp.isActive {
            window?.makeKey()
        }
        NSApp.mainMenu?.update()
        content.needsLayout = true
        manager.persistenceDidChange?(false)
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        enteringFullScreen = false
        windowedFrame = nil
        NSApp.mainMenu?.update()
        manager.persistenceDidChange?(false)
        content.needsLayout = true
        scheduleTrafficLightLayout()
    }

    func select(_ tab: TerminalTab) {
        manager.select(tab, in: group)
    }
    func newTab() {
        WindowOpener.openTab(spec: WindowOpener.inheritedTabSpec(), targetWindow: window)
    }
    func newGroup() {
        _ = manager.newGroup(in: self)
        activate()
    }
    func showGroups() {
        groupPresenter.present(for: self, manager: manager, anchor: tabBar.groupButton)
    }
    func requestCloseTab(_ tab: TerminalTab) {
        guard
            let group = manager.groups.first(where: {
                $0.tabs.contains {
                    $0 === tab
                }
            }) else {
            return
        }
        TabCloseConfirmation.confirm(tab, in: window) { [weak self, weak tab] in
            guard let self, let tab else {
                return
            }
            self.manager.closeTab(tab, in: group)
        }
    }
    func requestCloseGroup() {
        requestCloseGroup(group)
    }
    func requestCloseGroup(_ group: TerminalTabGroup) {
        GroupCloseConfirmation.confirm(group, in: window) { [weak self] in
            self?.manager.closeGroup(group)
        }
    }
    func requestCloseGroupAndEndSessions(_ target: TerminalTabGroup? = nil) {
        GroupSessionEnder.request(target ?? group, manager: manager, in: window)
    }
    func moveToNewWindow(_ tab: TerminalTab) {
        guard
            let source = manager.groups.first(where: {
                $0.tabs.contains {
                    $0 === tab
                }
            }) else {
            return
        }
        manager.moveToNewWindow(tab, from: source)
    }
    func closeOtherTabs(_ tab: TerminalTab) {
        guard
            let group = manager.groups.first(where: {
                $0.tabs.contains {
                    $0 === tab
                }
            }) else {
            return
        }
        let others = group.tabs.filter {
            $0 !== tab
        }
        TabCloseConfirmation.confirm(controllers: others.flatMap {
            $0.loadedWorkspace?.controllers ?? []
        }, title: "Close other tabs?", in: window) { [weak self] in
            guard let self else {
                return
            }
            for other in others {
                self.manager.closeTab(other, in: group)
            }
        }
    }
    func renameGroup() {
        if sidebarPreferences.style == .above {
            tabBar.beginGroupRename()
        } else {
            if sidebarPreferences.hidden {
                toggleSidebar()
            }
            sidebar.beginGroupRename(group)
        }
    }
    func renameTab(_ tab: TerminalTab) {
        if sidebarPreferences.style == .above {
            tabBar.beginTabRename(tab)
        } else {
            sidebar.beginRename(tab)
        }
    }

    /// Adds directly to the requested group without starting its dormant siblings.
    func newTab(in group: TerminalTabGroup, startsProcesses: Bool = true) {
        let pane = group.selectedTab?.loadedWorkspace?.focusedController
        let saved = group.selectedTab?.savedSpec?.restoredTab?.tab.root.panes.first
        let spec = WindowOpener.inheritedTabSpec(
            profileID: pane?.profile.id ?? saved?.profileID,
            workingDirectory: pane?.currentWorkingDirectory ?? saved?.directory?.path,
            remoteDestination: pane?.remoteDestination ?? saved?.remoteDestination
        )
        let tab = TerminalTab(spec: spec, startsProcesses: startsProcesses)
        manager.addTab(tab, to: group)
        if let owner = manager.window(showing: group) {
            owner.activate()
        } else {
            // A background tab needs its emulator and PTY without borrowing a window.
            let host = tab.hostView
            host.frame = NSRect(origin: .zero, size: window?.contentView?.bounds.size ?? NSSize(width: 900, height: 600))
            host.isHidden = true
            host.layoutSubtreeIfNeeded()
            tab.loadedWorkspace?.controllers.forEach {
                $0.setProgramStatusDrawingVisible(false)
            }
        }
    }
    func setGroupName(_ name: String) {
        manager.rename(group, to: name)
    }
    func tabNameDidChange() {
        refresh()
        observe()
        manager.persistenceDidChange?(false)
        NotificationCenter.default.post(name: .programActivityDidChange, object: self)
    }
    func focusSelectedTerminal() {
        group.selectedTab?.loadedWorkspace?.focusedController?.requestFocus()
    }
    func refreshTabPreferences() {
        for group in manager.groups {
            for tab in group.tabs {
                tab.loadedWorkspace?.updateProcessInspection()
                tab.loadedWorkspace?.hostView?.refreshAppearance()
            }
        }
        refresh()
    }
    func moveTab(_ tab: TerminalTab, offset: Int) {
        guard
            let group = manager.groups.first(where: {
                $0.tabs.contains {
                    $0 === tab
                }
            }) else {
            return
        }
        guard
            let index = group.tabs.firstIndex(where: {
                $0 === tab
            }), group.tabs.indices.contains(index + offset) else {
            return
        }
        manager.reorder(tab, in: group, insertion: offset > 0 ? index + 2 : index - 1)
    }

}

private final class TerminalWindowContentView: NSView {
    var onLayout: (() -> Void)?
    var onSwipe: ((NSEvent) -> Void)?
    override func swipe(with event: NSEvent) {
        onSwipe?(event)
    }
    override var isFlipped: Bool {
        true
    }
    override func layout() {
        super.layout()
        onLayout?()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    @objc private func invoke() {
        handler()
    }
}

/// Keeps tab gestures out of AppKit's native titlebar drag region before mouse-down.
final class TerminalWindow: NSWindow {
    private var movableBeforeCustomHover: Bool?

    private var paneHeaderDragActive = false

    /// The window server latches movability before dispatching mouse-down, so hover must set it.
    func updateTabPointer(at point: NSPoint) {
        guard !paneHeaderDragActive else {
            return
        }
        var hit = contentView?.superview?.hitTest(point)
        var capturesPointer = false
        while let view = hit {
            if view is TabItemView || (view as? PaneTitlebarView)?.movesWindow == true {
                capturesPointer = true
                break
            }
            hit = view.superview
        }
        if capturesPointer {
            if movableBeforeCustomHover == nil {
                movableBeforeCustomHover = isMovable
            }
            if isMovable {
                isMovable = false
            }
        } else if let previous = movableBeforeCustomHover {
            isMovable = previous
            movableBeforeCustomHover = nil
        }
    }

    /// Custom headers receive double-clicks before explicitly handing a drag to AppKit.
    func performPaneHeaderDrag(with event: NSEvent) {
        let previous = isMovable
        paneHeaderDragActive = true
        isMovable = true
        defer {
            paneHeaderDragActive = false
            isMovable = previous
            updateTabPointer(at: mouseLocationOutsideOfEventStream)
        }
        performDrag(with: event)
    }

    /// Rechecks the source window after a drop, including a tab that changed windows.
    func finishTabPointerGesture() {
        updateTabPointer(at: mouseLocationOutsideOfEventStream)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSWindow.toggleFullScreen(_:)) {
            menuItem.title = styleMask.contains(.fullScreen) ? "Exit Full Screen" : "Enter Full Screen"
            return true
        }
        return super.validateMenuItem(menuItem)
    }

    override func sendEvent(_ event: NSEvent) {
        if [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseUp].contains(event.type) {
            updateTabPointer(at: event.locationInWindow)
        }
        // Native titlebar handling consumes double-clicks before ordinary responder dispatch.
        if
            event.type == .leftMouseDown,
            let header = contentView?.superview?.hitTest(event.locationInWindow) as? PaneTitlebarView,
            header.movesWindow {
            header.mouseDown(with: event)
            return
        }
        super.sendEvent(event)
    }
}
