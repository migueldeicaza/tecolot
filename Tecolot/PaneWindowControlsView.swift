import AppKit

/// Keeps hidden-sidebar actions in card headers without introducing another header row.
final class PaneWindowControlsView: NSView {
    weak var controller: TerminalWindowController?
    let toggle = ChromeIconButton(treatment: .window)
    private let activity = ChromeIconButton(treatment: .window)
    let theme = ThemeTitlebarControl()
    private let zoom = ChromeIconButton(treatment: .window)
    private let add = ChromeIconButton(treatment: .window)
    private let badge = ProgramStatusBadgeView()
    private let popover = ActivityPopover()
    private(set) var trailingWidth: CGFloat = 0

    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (button, symbol, label, selector) in [
            (toggle, "sidebar.left", "Toggle Sidebar (⌘/)", #selector(toggleSidebar)),
            (activity, "eye", "Activity (⌘.)", #selector(toggleActivity)),
            (zoom, "arrow.down.right.and.arrow.up.left", "Reset Split Zoom", #selector(resetZoom)),
            (add, "plus", "New Tab (⌘T)", #selector(newTab))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = label
            button.target = self
            button.action = selector
        }
        for view in [toggle, activity, theme, zoom, add] {
            addSubview(view)
        }
        theme.contentTintColor = .secondaryLabelColor
        toggle.addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func refresh() {
        let pane = controller?.group.selectedTab?.loadedWorkspace?.focusedController
        theme.configure(controller: pane)
        zoom.isHidden = pane?.workspace?.zoomedControllerID == nil
        trailingWidth = (controller?.sidebarPreferences.style == .right ? 38 : 0) + (zoom.isHidden ? 90 : 120)
        let status = controller?.manager.groups.flatMap(\.tabs).map(\.status).filter(\.unseen).max {
            ($0.badge?.rawValue ?? -1) < ($1.badge?.rawValue ?? -1)
        } ?? .none
        badge.configure(status, background: .windowBackgroundColor, colored: ProgramActivitySettings.shared.value.color)
        activity.setAccessibilityLabel("Activity")
        activity.setAccessibilityValue(TabStatus.activityAccessibilityValue(count: controller?.manager.groups.flatMap(\.tabs).filter {
            $0.status.unseen
        }.count ?? 0))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let right = controller?.sidebarPreferences.style == .right
        let fullscreen = controller?.isFullScreen ?? (window?.styleMask.contains(.fullScreen) == true)
        let left: CGFloat = fullscreen ? 4 : 84
        toggle.frame = NSRect(x: right ? bounds.width - 32 : left, y: 4.5, width: 29, height: 25)
        let end = bounds.width - (right ? 38 : 4)
        add.frame = NSRect(x: end - 30, y: 4, width: 30, height: 28)
        zoom.frame = NSRect(x: add.frame.minX - (zoom.isHidden ? 0 : 30), y: 4, width: zoom.isHidden ? 0 : 30, height: 28)
        theme.frame = NSRect(x: zoom.frame.minX - 30, y: 4, width: 29, height: 28)
        activity.frame = NSRect(x: theme.frame.minX - 30, y: 4, width: 29, height: 28)
        badge.frame = NSRect(x: 17, y: 0, width: 15, height: 15)
    }

    /// Blank header space belongs to the card underneath, including native window dragging.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    @objc func toggleActivity() {
        guard let controller else {
            return
        }
        popover.toggle(relativeTo: activity, owner: controller)
    }
    @objc private func toggleSidebar() {
        controller?.toggleSidebar()
    }
    @objc private func resetZoom() {
        controller?.group.selectedTab?.loadedWorkspace?.clearSplitZoom()
    }
    @objc private func newTab() {
        controller?.newTab()
    }
}
