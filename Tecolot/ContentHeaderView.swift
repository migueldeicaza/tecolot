import AppKit

/// Supplies window controls and focused-pane identity when tabs are beside or hidden.
final class ContentHeaderView: NSView {
    weak var controller: TerminalWindowController?
    let directory = WorkingDirectoryTitlebarControl()
    let glyph = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    let toggle = ChromeIconButton(treatment: .window)
    private let activity = ChromeIconButton(treatment: .window)
    private let theme = ThemeTitlebarControl()
    private let zoom = ChromeIconButton(treatment: .window)
    private let add = ChromeIconButton(treatment: .window)
    private let paneBadge = ProgramStatusBadgeView()
    private let toggleBadge = ProgramStatusBadgeView()
    private let activityBadge = ProgramStatusBadgeView()
    private let popover = ActivityPopover()
    override var isFlipped: Bool {
        true
    }
    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for (button, symbol, title, action) in [
            (toggle, "sidebar.left", "Toggle Sidebar (⌘/)", #selector(toggleSidebar)),
            (activity, "eye", "Activity (⌘.)", #selector(toggleActivity)),
            (zoom, "arrow.down.right.and.arrow.up.left", "Reset Split Zoom", #selector(resetZoom)),
            (add, "plus", "New Tab (⌘T)", #selector(newTab))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.isBordered = false
            button.toolTip = title
            button.target = self
            button.action = action
        }
        directory.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingMiddle
        glyph.addSubview(paneBadge)
        toggle.addSubview(toggleBadge)
        activity.addSubview(activityBadge)
        for view in [directory, titleField, glyph, toggle, activity, theme, zoom, add] {
            addSubview(view)
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func refresh() {
        guard let controller else {
            return
        }
        let pane = controller.group.selectedTab?.loadedWorkspace?.focusedController
        let title = pane?.panePresentation.title ?? controller.group.selectedTab?.title ?? "Terminal"
        titleField.stringValue = title
        directory.configure(path: pane?.titlebarWorkingDirectory, title: "", hasActivity: false)
        directory.isHidden = pane?.titlebarWorkingDirectory == nil
        let iconSource = pane?.programStatus.tabStatus.app ?? pane?.panePresentation.executablePath
        glyph.image = TerminalAppIconResolver.shared.icon(forExecutablePath: iconSource)
        let model = AppModel.shared
        theme.configure(controller: pane, profiles: model.profiles, themes: model.themes, themeIndex: model.themeIndex)
        let hidden = controller.sidebarPreferences.hidden
        for view in [activity, theme, add] {
            view.isHidden = !hidden
        }
        zoom.isHidden = !hidden || controller.group.selectedTab?.loadedWorkspace?.zoomedControllerID == nil
        toggle.isHidden = !hidden
        layer?.backgroundColor = nil
        layer?.cornerRadius = 0
        let status = controller.manager.groups.flatMap(\.tabs).map(\.status).filter(\.unseen)
            .max {
                ($0.badge?.rawValue ?? -1) < ($1.badge?.rawValue ?? -1)
            } ?? .none
        let color = ProgramActivitySettings.shared.value.color
        let paneStatus = controller.group.selectedTab?.isMuted == true || !ProgramActivitySettings.shared.value.showTabs
            ? TabStatus.none : pane?.programStatus.tabStatus ?? .none
        paneBadge.configure(paneStatus, background: .windowBackgroundColor, colored: color)
        setAccessibilityValue(paneStatus.accessibilityValue)
        toggleBadge.configure(status, background: .windowBackgroundColor, colored: color)
        activityBadge.configure(status, background: .windowBackgroundColor, colored: color)
        activity.setAccessibilityLabel("Activity")
        activity.setAccessibilityValue(TabStatus.activityAccessibilityValue(count: controller.manager.groups.flatMap(\.tabs).filter {
            $0.status.unseen
        }.count))
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let right = controller?.sidebarPreferences.style == .right
        let fullscreen = controller?.isFullScreen ?? (window?.styleMask.contains(.fullScreen) == true)
        toggle.frame = NSRect(x: right ? bounds.width - 32 : (fullscreen ? 4 : 84), y: 4, width: 29, height: 25)
        let end = bounds.width - (right && !toggle.isHidden ? 38 : 4)
        add.frame = NSRect(x: end - 30, y: 3, width: 30, height: 28)
        zoom.frame = NSRect(x: add.frame.minX - (zoom.isHidden ? 0 : 30), y: 3, width: zoom.isHidden ? 0 : 30, height: 28)
        theme.frame = NSRect(x: zoom.frame.minX - 30, y: 3, width: 29, height: 28)
        activity.frame = NSRect(x: theme.frame.minX - 30, y: 3, width: 29, height: 28)
        let start: CGFloat = right || toggle.isHidden ? (fullscreen ? 10 : 82) : (fullscreen ? 40 : 120)
        glyph.frame = NSRect(x: start, y: 11, width: 14, height: 14)
        let titleEnd = activity.isHidden ? bounds.width - 8 : activity.frame.minX
        let available = max(0, titleEnd - start - 28)
        let titleWidth = min(titleField.intrinsicContentSize.width + 8, directory.isHidden ? available : available / 2)
        titleField.frame = NSRect(x: start + 20, y: 9, width: titleWidth, height: 18)
        directory.frame = NSRect(
            x: titleField.frame.maxX + 12,
            y: 6,
            width: max(22, available - titleWidth - 12),
            height: 24
        )
        paneBadge.frame = NSRect(x: 7, y: -7, width: 15, height: 15)
        toggleBadge.frame = NSRect(x: 17, y: 0, width: 15, height: 15)
        activityBadge.frame = toggleBadge.frame
    }
    @objc private func toggleSidebar() {
        controller?.toggleSidebar()
    }
    @objc func toggleActivity() {
        guard let controller else {
            return
        }
        popover.toggle(relativeTo: activity, owner: controller)
    }
    @objc private func resetZoom() {
        controller?.group.selectedTab?.loadedWorkspace?.clearSplitZoom()
    }
    @objc private func newTab() {
        controller?.newTab()
    }
}

/// The sidebar's inner edge preserves the content width when the preference asks for it.
final class SidebarResizeHandle: NSView {
    weak var controller: TerminalWindowController?
    override var mouseDownCanMoveWindow: Bool {
        false
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
    override func mouseDown(with event: NSEvent) {
        guard let controller, let window else {
            return
        }
        let start = window.convertPoint(toScreen: event.locationInWindow)
        let width = controller.sidebarPreferences.width
        let frame = window.frame
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                break
            }
            let point = window.convertPoint(toScreen: next.locationInWindow)
            let delta = (point.x - start.x) * (controller.sidebarPreferences.style == .right ? -1 : 1)
            controller.resizeSidebar(to: width + delta, originalFrame: frame, originalWidth: width)
        }
    }
}
