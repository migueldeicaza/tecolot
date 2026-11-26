import AppKit
import QuartzCore
import TecolotWire

/// Shares tab content, status and hover feedback between strip cells and sidebar rows.
final class TabItemView: NSView {
    let tab: TerminalTab
    weak var bar: HorizontalTabBarView?
    weak var sidebar: SidebarTabBarView?
    var isSidebarRow: Bool {
        sidebar != nil
    }
    private let rowSelection = TabSelectionSurfaceView()
    private weak var controller: TerminalWindowController?
    private let hover = NSView()
    private let titleClip = NSView()
    let titleField = NSTextField(labelWithString: "")
    private let titleFade = CAGradientLayer()
    let closeButton = NSButton()
    let icon = NSImageView()
    private let hint = NSTextField(labelWithString: "")
    private let mute = NSImageView()
    private let divider = NSView()
    private let statusBadge = ProgramStatusBadgeView()
    private let workingDots = ProgramWorkingDotsView()
    private let progressPie = ProgramProgressPieView()
    private lazy var ticker = TabAnnouncementTicker(clip: titleClip, title: titleField, mask: titleFade)
    private var activityPreferences = ProgramActivitySettings.shared.value
    private var currentStatus = TabStatus.none
    private var bounceKey: String?
    private var announcementMessages: [String] = []
    /// M4 places dots/pie in this slot and the badge over the front tile.
    let statusIndicatorHost = NSView()
    let badgeHost = NSView()
    private var editor: InlineNameField?
    private var tracking: NSTrackingArea?
    private var mouseStart: NSEvent?
    private(set) var isSelected = false
    private(set) var isHovered = false
    private var isPressed = false
    private var iconCount = 0
    private var hintNumber: Int?
    private var key = false
    private var chrome = TabStripChrome(theme: nil, opacity: 1, key: false, appearance: .currentDrawing())
    private let accessibleClose = TabCloseAccessibilityElement()
    override func accessibilityChildren() -> [Any]? {
        [accessibleClose]
    }
    override var isFlipped: Bool {
        true
    }
    override var mouseDownCanMoveWindow: Bool {
        false
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Labels, icons and status decoration share the cell's mouse gestures.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else {
            return nil
        }
        if hit === closeButton || hit.isDescendant(of: closeButton) {
            return hit
        }
        if let editor, hit === editor || hit.isDescendant(of: editor) {
            return hit
        }
        return self
    }

    init(tab: TerminalTab, controller: TerminalWindowController?) {
        self.tab = tab
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(rowSelection)
        rowSelection.isHidden = true
        icon.wantsLayer = true
        statusIndicatorHost.wantsLayer = true
        badgeHost.wantsLayer = true
        statusIndicatorHost.addSubview(workingDots)
        badgeHost.addSubview(statusBadge)
        icon.addSubview(progressPie)
        hover.wantsLayer = true
        hover.layer?.cornerRadius = 16
        hover.alphaValue = 0
        titleClip.wantsLayer = true
        titleFade.startPoint = CGPoint(x: 0, y: 0.5)
        titleFade.endPoint = CGPoint(x: 1, y: 0.5)
        titleClip.layer?.mask = titleFade
        titleField.lineBreakMode = .byClipping
        titleField.font = .systemFont(ofSize: 13)
        titleField.isSelectable = false
        titleClip.addSubview(titleField)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.setAccessibilityLabel("Close Tab")
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.cornerRadius = 4
        hint.layer?.borderWidth = 1
        hint.alphaValue = 0
        mute.image = NSImage(systemSymbolName: "bell.slash", accessibilityDescription: "Muted")
        divider.wantsLayer = true
        for view in [hover, icon, titleClip, statusIndicatorHost, badgeHost, mute, hint, closeButton, divider] {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        closeButton.setAccessibilityElement(false)
        accessibleClose.setAccessibilityEnabled(true)
        accessibleClose.setAccessibilityRole(.button)
        accessibleClose.setAccessibilityLabel("Close Tab")
        accessibleClose.setAccessibilityParent(self)
        accessibleClose.onPress = { [weak self] in
            self?.closeTab()
        }
        setAccessibilityChildren([accessibleClose])
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Select Tab", target: self, selector: #selector(accessibilitySelect)),
            NSAccessibilityCustomAction(name: "Close Tab", target: self, selector: #selector(accessibilityClose)),
            NSAccessibilityCustomAction(name: "Rename Tab", target: self, selector: #selector(accessibilityRename)),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(selected: Bool) {
        configure(
            selected: selected, key: window?.isKeyWindow == true, chrome: chrome,
            preferences: TabStripPreferences()
        )
    }

    func configure(selected: Bool, key: Bool, chrome: TabStripChrome, preferences: TabStripPreferences) {
        isSelected = selected
        self.key = key
        self.chrome = chrome
        if !key {
            isHovered = false
            isPressed = false
        }
        titleField.stringValue = tab.title
        toolTip = tab.title
        iconCount = min(isSidebarRow ? 3 : 5, min(preferences.iconCount, tab.loadedWorkspace?.controllers.count ?? 0))
        icon.isHidden = iconCount == 0
        if let workspace = tab.loadedWorkspace, iconCount > 0 {
            let image = TerminalTabIconStack.image(
                workspace: workspace, preferences: preferences, selected: selected,
                appearance: effectiveAppearance, scale: window?.backingScaleFactor ?? 2,
                showsProgress: tab.status.progress != nil && ProgramActivitySettings.shared.value.showTabs,
                vertical: isSidebarRow
            )
            if icon.image !== image {
                if icon.image != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = 0.2
                    icon.layer?.add(fade, forKey: "frontCard")
                }
                icon.image = image
            }
        }
        mute.isHidden = !tab.isMuted
        setAccessibilityLabel(tab.title)
        setAccessibilityTitle(tab.title)
        currentStatus = tab.status
        activityPreferences = ProgramActivitySettings.shared.value
        setAccessibilityValue(currentStatus.accessibilityValue)
        configureStatus()
        setAccessibilitySelected(selected)
        rowSelection.isHidden = !isSidebarRow || !selected
        rowSelection.apply(chrome: chrome, key: key)
        updateAppearance()
        needsLayout = true
    }

    /// Updates indicator, badge, announcement and attention motion from the current tab reduction.
    private func configureStatus() {
        let status = activityPreferences.showTabs ? currentStatus : .none
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        statusBadge.configure(status, background: chrome.bar, colored: activityPreferences.color)
        workingDots.configure(visible: status.state == .working && status.progress == nil, reduceMotion: reduced)
        progressPie.isHidden = status.progress == nil || iconCount == 0
        if let progress = status.progress {
            progressPie.configure(progress)
        }
        announcementMessages = activityPreferences.announce ? status.blocked.compactMap {
            $0.value.message
        } : []
        let record = status.badgeRecord
        let nextBounce = record.map {
            "\($0.paneID):\($0.value.id):\($0.value.state):\($0.value.kind ?? ""):\($0.value.message ?? "")"
        }
        if nextBounce != bounceKey {
            bounceKey = nextBounce
            icon.layer?.removeAnimation(forKey: "attention")
            badgeHost.layer?.removeAnimation(forKey: "attention")
            if activityPreferences.bounce, !reduced, status.badge == .blocked || status.badge == .error {
                let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
                let duration = status.badge == .blocked ? 3.7 : 0.55
                bounce.values = [0, -7, 0, -1.5, 0, 0]
                bounce.keyTimes = [
                    0, NSNumber(value: 0.20 / duration), NSNumber(value: 0.40 / duration),
                    NSNumber(value: 0.46 / duration), NSNumber(value: 0.55 / duration), 1,
                ]
                bounce.duration = duration
                bounce.repeatCount = status.badge == .blocked ? Float(120 / 3.7) : 1
                bounce.timingFunctions = [
                    .init(name: .easeOut), .init(name: .easeIn), .init(name: .easeOut), .init(name: .easeIn),
                    .init(name: .linear),
                ]
                icon.layer?.add(bounce, forKey: "attention")
                badgeHost.layer?.add(bounce, forKey: "attention")
            }
        }
        if reduced || !activityPreferences.bounce {
            icon.layer?.removeAnimation(forKey: "attention")
            badgeHost.layer?.removeAnimation(forKey: "attention")
        }
    }

    func setHint(_ number: Int?) {
        hintNumber = number
        hint.stringValue = number.map {
            "⌘\($0)"
        } ?? ""
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            hint.animator().alphaValue = number == nil ? 0 : 1
        }
        updateAppearance()
        needsLayout = true
    }

    func showDivider(_ visible: Bool) {
        divider.isHidden = !visible || !key
    }

    private func updateAppearance() {
        hover.layer?.backgroundColor = chrome.hover.withAlphaComponent(
            chrome.hover.alphaComponent * (isPressed ? 0.85 : 1)
        ).cgColor
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            hover.animator().alphaValue = key && (isHovered || isPressed) ? 1 : 0
        }
        titleField.textColor = isSelected || (isHovered && key) ? .labelColor : .secondaryLabelColor
        let fontSize: CGFloat = isSidebarRow ? SidebarPreferences().textSize : 13
        let parts = tab.titleParts
        let text = NSMutableAttributedString(
            string: parts.primary,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: isSelected ? .medium : .regular),
                .foregroundColor: titleField.textColor ?? NSColor.labelColor,
            ]
        )
        if let directory = parts.directory {
            text.append(
                NSAttributedString(
                    string: " " + directory,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: fontSize),
                        .foregroundColor: isSelected || (isHovered && key)
                            ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
                    ]
                )
            )
        }
        titleField.attributedStringValue = text
        closeButton.isHidden = !(key && isHovered) || hintNumber != nil
        closeButton.contentTintColor = .labelColor
        hint.textColor = .secondaryLabelColor
        hint.layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.3).cgColor
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        statusIndicatorHost.isHidden = !closeButton.isHidden || hintNumber != nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        rowSelection.frame = bounds.insetBy(dx: 0, dy: 1)
        hover.frame = bounds.insetBy(dx: 0, dy: isSidebarRow ? 1 : 0)
        let stackWidth = iconCount > 0 ? (isSidebarRow ? 24 : 24 + CGFloat(iconCount - 1) * 6) : 0
        icon.frame = NSRect(x: isSidebarRow ? 9 : 10.5, y: 4, width: stackWidth, height: 24)
        let start: CGFloat = isSidebarRow ? (iconCount == 0 ? 11 : 38) : (iconCount == 0 ? 16.5 : (iconCount == 1 ? 44 : 42.5 + CGFloat(iconCount - 1) * 6))
        let accessory: CGFloat =
            hintNumber != nil
                ? 38
                : (!closeButton.isHidden || workingDots.visible ? 32 : 10.5)
        titleClip.frame = NSRect(x: start, y: 7, width: max(0, bounds.width - start - accessory), height: 18)
        titleField.frame = NSRect(
            x: 0, y: 0, width: max(titleClip.bounds.width, titleField.intrinsicContentSize.width), height: 18
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleFade.frame = titleClip.bounds
        let edge = max(0, 1 - 12 / max(1, titleClip.bounds.width))
        titleFade.locations = [
            0, NSNumber(value: Double(min(0.5, 12 / max(1, titleClip.bounds.width)))),
            NSNumber(value: Double(max(0.5, edge))), 1,
        ]
        titleFade.colors = [
            NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor,
            (titleField.frame.width > titleClip.bounds.width ? NSColor.clear : .black).cgColor,
        ]
        CATransaction.commit()
        closeButton.frame = NSRect(x: bounds.width - 25, y: 8, width: 16, height: 16)
        if let window {
            accessibleClose.setAccessibilityFrame(window.convertToScreen(convert(closeButton.frame, to: nil)))
        }
        hint.frame = NSRect(x: bounds.width - 32.5, y: 8, width: 22, height: 16)
        statusIndicatorHost.frame = NSRect(x: bounds.width - 27, y: 8, width: 16.5, height: 16)
        // Index zero is the front card, even when the fan has several tiles.
        badgeHost.frame = NSRect(
            x: iconCount > 0 ? 23 : 4,
            y: isSidebarRow ? 1 + CGFloat(max(0, iconCount - 1)) * 1.25 : 2,
            width: 13,
            height: 13
        )
        statusBadge.frame = badgeHost.bounds
        workingDots.frame = statusIndicatorHost.bounds
        progressPie.frame = NSRect(x: 6, y: 6 + (isSidebarRow ? CGFloat(max(0, iconCount - 1)) * 1.5 : 0), width: 12, height: 12)
        ticker.configure(
            messages: announcementMessages, speed: activityPreferences.tickerSpeed,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        mute.frame = NSRect(x: bounds.width - 41, y: 10, width: 12, height: 12)
        divider.frame = NSRect(x: bounds.width - 1, y: 7, width: 1, height: 18)
        editor?.frame = NSRect(x: start - 2, y: 5, width: max(20, bounds.width - start - 26), height: 22)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let next = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self
        )
        addTrackingArea(next)
        tracking = next
    }
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
        bar?.updateDividers()
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateAppearance()
        bar?.updateDividers()
    }
    override func mouseDown(with event: NSEvent) {
        mouseStart = event
        if event.clickCount == 2 {
            beginRename()
        } else {
            isPressed = true
            updateAppearance()
            bar?.selectByMouse(tab)
            sidebar?.select(tab)
            if bar == nil && sidebar == nil {
                controller?.select(tab)
            }
        }
    }
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        mouseStart = nil
        updateAppearance()
    }
    override func mouseDragged(with event: NSEvent) {
        guard
            let start = mouseStart,
            hypot(
                event.locationInWindow.x - start.locationInWindow.x,
                event.locationInWindow.y - start.locationInWindow.y
            ) >= 4
        else {
            return
        }
        mouseStart = nil
        isPressed = false
        updateAppearance()
        bar?.dragController.begin(tab: tab, cell: self, event: start)
        sidebar?.beginDrag(tab: tab, cell: self, event: start)
    }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            closeTab()
        } else {
            super.otherMouseDown(with: event)
        }
    }
    override func accessibilityPerformPress() -> Bool {
        if let sidebar {
            sidebar.select(tab)
        } else {
            controller?.select(tab)
        }
        return true
    }
    @objc private func accessibilitySelect() -> Bool {
        accessibilityPerformPress()
    }
    @objc private func accessibilityClose() -> Bool {
        closeTab()
        return true
    }
    @objc private func accessibilityRename() -> Bool {
        beginRename()
        return true
    }
    @objc private func closeTab() {
        controller?.requestCloseTab(tab)
    }

    func beginRename() {
        guard editor == nil else {
            return
        }
        let field = InlineNameField(value: tab.customName ?? tab.title) { [weak self] value in
            guard let self else {
                return
            }
            if let value {
                self.tab.customName = value.isEmpty ? nil : value
                self.controller?.tabNameDidChange()
            }
            self.editor?.removeFromSuperview()
            self.editor = nil
            self.titleClip.isHidden = false
            self.controller?.focusSelectedTerminal()
        }
        editor = field
        titleClip.isHidden = true
        addSubview(field)
        needsLayout = true
        layoutSubtreeIfNeeded()
        field.beginEditing()
    }

    /// Status drawing pauses independently of identity inspection in background groups.
    func setDrawingVisible(_ visible: Bool) {
        for layer in [statusIndicatorHost.layer, badgeHost.layer, icon.layer, titleClip.layer, titleFade].compactMap({
            $0
        }) {
            if visible && layer.speed == 0 {
                let paused = layer.timeOffset
                layer.speed = 1
                layer.timeOffset = 0
                layer.beginTime = 0
                layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
            } else if !visible && layer.speed != 0 {
                layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.speed = 0
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("New Tab") { [weak self] in
            guard
                let self, let controller = self.controller,
                let group = controller.manager.groups.first(where: {
                    $0.tabs.contains {
                        $0 === self.tab
                    }
                }) else {
                return
            }
            controller.newTab(in: group)
        })
        menu.addItem(ClosureMenuItem("Rename Tab…") { [weak self] in
            self?.beginRename()
        })
        let mute = ClosureMenuItem(tab.isMuted ? "Unmute" : "Mute") { [weak self] in
            guard let self else {
                return
            }
            self.tab.isMuted.toggle()
            self.controller?.tabNameDidChange()
        }
        mute.state = tab.isMuted ? .on : .off
        menu.addItem(mute)
        menu.addItem(.separator())
        if
            let controller, let source = controller.manager.groups.first(where: {
                $0.tabs.contains {
                    $0 === tab
                }
            }) {
            let destinations = NSMenu(title: "Move to Group")
            for group in controller.manager.groups {
                let item = ClosureMenuItem(group.name) { [weak controller, weak tab] in
                    guard let controller, let tab else {
                        return
                    }
                    controller.manager.move(tab, from: source, to: group)
                }
                item.state = group === source ? .on : .off
                item.isEnabled = group !== source
                destinations.addItem(item)
            }
            destinations.addItem(.separator())
            destinations.addItem(ClosureMenuItem("New Group") { [weak controller, weak tab] in
                guard let controller, let tab else {
                    return
                }
                controller.manager.moveToNewGroup(tab)
            })
            let move = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
            move.submenu = destinations
            menu.addItem(move)
        }
        for (title, offset) in [("Move Backward", -1), ("Move Forward", 1)] {
            let item = ClosureMenuItem(title) { [weak self] in
                guard let self else {
                    return
                }
                self.controller?.moveTab(self.tab, offset: offset)
            }
            if
                let group = controller?.manager.groups.first(where: {
                    $0.tabs.contains {
                        $0 === tab
                    }
                }), let index = group.tabs.firstIndex(where: {
                    $0 === tab
                }) {
                item.isEnabled = group.tabs.indices.contains(index + offset)
            }
            menu.addItem(item)
        }
        menu.addItem(
            ClosureMenuItem("Move to New Window") { [weak self] in
                guard let self else {
                    return
                }
                self.controller?.moveToNewWindow(self.tab)
            }
        )
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close Tab") { [weak self] in
            self?.closeTab()
        })
        menu.addItem(
            ClosureMenuItem("Close Others") { [weak self] in
                guard let self else {
                    return
                }
                self.controller?.closeOtherTabs(self.tab)
            }
        )
        if let path = tab.loadedWorkspace?.focusedController?.titlebarWorkingDirectory {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Open in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            })
            let ancestors = NSMenu(title: "Working Directory")
            for directory in TerminalWorkingDirectory.ancestors(of: path) {
                ancestors.addItem(ClosureMenuItem(directory.path) {
                    NSWorkspace.shared.open(directory)
                })
            }
            let item = NSMenuItem(title: "Working Directory", action: nil, keyEquivalent: "")
            item.submenu = ancestors
            menu.addItem(item)
        }
        return menu
    }
}

/// Commits on Return or focus loss, cancels on Escape, without a modal loop.
final class InlineNameField: NSTextField, NSTextFieldDelegate {
    private var finish: ((String?) -> Void)?
    init(value: String, finish: @escaping (String?) -> Void) {
        self.finish = finish
        super.init(frame: .zero)
        stringValue = value
        font = .systemFont(ofSize: 14)
        delegate = self
        isBezeled = true
        bezelStyle = .roundedBezel
        setAccessibilityLabel("Name")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    /// Select through the field editor. Calling NSTextField.selectText after
    /// makeFirstResponder ends the session we just started and commits it.
    func beginEditing() {
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }
    private func end(_ value: String?) {
        guard let action = finish else {
            return
        }
        finish = nil
        if currentEditor() != nil, let window {
            window.makeFirstResponder(window)
        }
        action(value)
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        end(stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            end(nil)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            end(stringValue)
            return true
        }
        return false
    }
}

/// The close action remains discoverable while its visual button is hidden.
private final class TabCloseAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
