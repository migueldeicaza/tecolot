import AppKit
import Testing
import TecolotSessionDirectory
@testable import Tecolot

@MainActor
private final class GroupAnchorRecorder: GroupSwitcherPresenting {
    private(set) var anchor: NSView?
    private(set) var rect: NSRect?

    func present(for controller: TerminalWindowController, manager: TerminalWindowManager, anchor: NSView) {
        self.anchor = anchor
        self.rect = anchor.bounds
    }
}

@MainActor
struct TabStripIntegrationTests {
    @Test(arguments: [0, 1, 2, 3])
    func groupNameRule(groupCount: Int) {
        #expect(HorizontalTabBarView.showsGroupName(groupCount: groupCount) == (groupCount > 1))
    }

    @Test(arguments: [false, true])
    func groupCountReflowsExistingWindows(openSecondWindow: Bool) throws {
        let suite = "GroupCaption-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("horizontal", forKey: ProgramActivityPreferences.tabStyleKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer {
            for group in manager.groups {
                manager.closeGroup(group)
            }
            manager.makeWindow = nil
        }
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        manager.rename(group, to: "TabSpec")
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        owner.window?.setContentSize(NSSize(width: 1180, height: 760))
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        let bar = owner.tabBar
        bar.layoutSubtreeIfNeeded()
        let cell = try #require(bar.cells.first)
        let selectorCell = try #require(bar.groupButton.cell as? GroupSelectorCell)
        let glyph = bar.convert(selectorCell.imageRect(forBounds: bar.groupButton.bounds), from: bar.groupButton)
        #expect(!bar.isHidden)
        #expect(!bar.groupButton.isHidden)
        #expect(bar.groupButton.title.isEmpty)
        #expect(bar.groupButton.isAccessibilityElement())
        #expect(bar.groupButton.accessibilityLabel() == "Go to Group")
        #expect(bar.groupButton.accessibilityValue() as? String == group.name)
        #expect(bar.groupButton.toolTip == "Go to Group (⌘K)")
        #expect(bar.groupButton.frame == NSRect(x: 85, y: 7, width: 34, height: 32))
        #expect(bar.scroll.frame == NSRect(x: 127, y: 7, width: 902, height: 32))
        #expect(selectorCell.titleRect(forBounds: bar.groupButton.bounds) == .zero)
        #expect(glyph == NSRect(x: 95.5, y: 15, width: 16, height: 16))

        let second = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        manager.rename(second, to: "Two")
        bar.layoutSubtreeIfNeeded()
        #expect(!bar.groupButton.isHidden)
        #expect(bar.groupButton.title == group.name)
        #expect(bar.groupButton.isAccessibilityElement())
        #expect(bar.groupButton.accessibilityValue() as? String == group.name)
        #expect(bar.groupButton.frame == NSRect(x: 85, y: 5, width: 105, height: 36))
        #expect(bar.scroll.frame == NSRect(x: 198, y: 7, width: 831, height: 32))
        #expect(bar.convert(selectorCell.imageRect(forBounds: bar.groupButton.bounds), from: bar.groupButton) == glyph)
        if openSecondWindow {
            let other = try #require(manager.openWindow(group: second) as? TerminalWindowController)
            other.tabBar.layoutSubtreeIfNeeded()
            #expect(!other.tabBar.groupButton.isHidden)
            #expect(other.tabBar.groupButton.title == second.name)
            #expect(other.tabBar.groupButton.accessibilityValue() as? String == second.name)
            #expect(other.tabBar.groupButton.frame == NSRect(x: 85, y: 5, width: 105, height: 36))
            #expect(other.tabBar.scroll.frame.minX == other.tabBar.groupButton.frame.maxX + 8)
        } else {
            #expect(manager.backgroundGroups.contains {
                $0 === second
            })
        }
        manager.closeGroup(second)
        bar.layoutSubtreeIfNeeded()
        #expect(!bar.groupButton.isHidden)
        #expect(bar.groupButton.title.isEmpty)
        #expect(bar.groupButton.isAccessibilityElement())
        #expect(bar.groupButton.accessibilityValue() as? String == group.name)
        #expect(bar.groupButton.frame == NSRect(x: 85, y: 7, width: 34, height: 32))
        #expect(bar.scroll.frame == NSRect(x: 127, y: 7, width: 902, height: 32))
        #expect(bar.cells.first === cell)
        #expect(cell.tab.hostView.window === owner.window)
    }

    @Test(arguments: ["horizontal", "vertical"])
    func groupSwitcherAnchorsOnButtonInBothCaptionStates(style: String) throws {
        let suite = "GroupAnchor-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(style, forKey: ProgramActivityPreferences.tabStyleKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { manager.makeWindow = nil }
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        let recorder = GroupAnchorRecorder()
        owner.groupPresenter = recorder
        owner.tabBar.layoutSubtreeIfNeeded()
        owner.tabBar.groupButton.performClick(nil)
        let anchor = try #require(recorder.anchor)
        let rect = try #require(recorder.rect)
        #expect(!owner.tabBar.groupButton.isHidden)
        #expect(owner.tabBar.groupButton.title.isEmpty)
        #expect(anchor === owner.tabBar.groupButton)
        #expect(anchor.isHiddenOrHasHiddenAncestor == (style == "vertical"))
        #expect(anchor.bounds.contains(rect))
        #expect(rect == owner.tabBar.groupButton.bounds)
        #expect(rect.height > 0 && rect.width > 0)

        let second = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        defer { manager.closeGroup(second) }
        owner.showGroups()
        #expect(owner.tabBar.groupButton.title == group.name)
        #expect(recorder.anchor === owner.tabBar.groupButton)
        #expect(recorder.rect == owner.tabBar.groupButton.bounds)
    }

    @Test func measuredChromeFramesAndSelectedReveal() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let first = TerminalTab(startsProcesses: false)
        let group = manager.newGroup(tab: first)
        manager.rename(group, to: "TabSpec")
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        let window = try #require(owner.window)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.contentView?.layoutSubtreeIfNeeded()
        let bar = owner.tabBar
        bar.layoutSubtreeIfNeeded()
        #expect(bar.frame == NSRect(x: 0, y: 0, width: 1180, height: 46))
        #expect(bar.groupButton.frame == NSRect(x: 85, y: 7, width: 34, height: 32))
        #expect(!bar.groupButton.isHidden)
        #expect(bar.groupButton.title.isEmpty)
        #expect(bar.groupButton.accessibilityValue() as? String == group.name)
        #expect(bar.scroll.frame == NSRect(x: 127, y: 7, width: 902, height: 32))
        #expect(!bar.commandPaletteButton.isHidden)
        #expect(bar.cells[0].frame.width == 242)
        #expect(first.hostView.frame == NSRect(x: 8, y: 46, width: 1164, height: 706))
        for _ in 1..<20 {
            manager.addTab(TerminalTab(startsProcesses: false), to: group)
        }
        bar.layoutSubtreeIfNeeded()
        #expect(bar.stripLayout.overflows)
        #expect(bar.cells.last?.frame.width == 66)
        let last = try #require(bar.cells.last)
        #expect(bar.scroll.contentView.bounds.maxX >= last.frame.maxX - 1)
        manager.select(first, in: group)
        bar.layoutSubtreeIfNeeded()
        #expect(bar.scroll.contentView.bounds.minX == 0)
    }

    @Test func reorderAndCrossGroupInsertionPreserveSelectionAndHostOwnership() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let tabs = (0..<4).map { _ in
            TerminalTab(startsProcesses: false)
        }
        let source = manager.newGroup(tab: tabs[0])
        for tab in tabs.dropFirst() {
            manager.addTab(tab, to: source)
        }
        manager.select(tabs[1], in: source)
        let owner = try #require(manager.openWindow(group: source) as? TerminalWindowController)
        manager.reorder(tabs[1], in: source, insertion: 4)
        #expect(source.tabs.map(\.id) == [tabs[0], tabs[2], tabs[3], tabs[1]].map(\.id))
        #expect(source.selection == tabs[1].id)
        let target = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let destination = try #require(manager.openWindow(group: target) as? TerminalWindowController)
        manager.move(tabs[1], from: source, to: target, insertion: 0)
        #expect(target.tabs.first === tabs[1])
        #expect(tabs[1].hostView.window === destination.window)
        #expect(source.tabs.count == 3 && owner.group === source)
        manager.closeGroup(source)
        manager.closeGroup(target)
    }

    @Test func switcherMatchesTheRowsInReferenceImages33Through36() throws {
        let directory = URL(fileURLWithPath: "/tmp/tecolot-m3/review", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let panel = GroupSwitcherPanel()
        let groups = [
            GroupSwitcherModel.Group(id: UUID(), name: "Onboarding"),
            .init(id: UUID(), name: "silent-thicket", isCurrent: true)
        ]
        func referenceRows(filter: String) -> [GroupSwitcherModel.Row] {
            GroupSwitcherModel(groups: groups, filter: filter).rows.compactMap { row in
                switch row.action {
                case .attach:
                    return nil
                case .remote:
                    return .init(
                        title: "Add Remote Host…",
                        keycap: "",
                        symbol: row.symbol,
                        action: row.action,
                        separatorBefore: row.separatorBefore
                    )
                case .newGroup(let name):
                    return .init(
                        title: name.map {
                            "New Session “\($0)”"
                        } ?? "New Session",
                        keycap: row.keycap,
                        symbol: row.symbol,
                        action: row.action,
                        separatorBefore: row.separatorBefore
                    )
                case .group:
                    return row
                }
            }
        }
        let fixtures: [(String, String, Int, NSSize)] = [
            ("33", "", 1, NSSize(width: 194, height: 181)),
            ("34", "sil", 0, NSSize(width: 194, height: 115)),
            ("35", "zebra", 0, NSSize(width: 230, height: 78)),
            ("36", "", 2, NSSize(width: 194, height: 181))
        ]
        var measurements: [[String: Any]] = []
        for (name, filter, selection, expected) in fixtures {
            panel.configure(rows: referenceRows(filter: filter), selection: selection, filter: filter)
            let view = try #require(panel.contentView)
            view.layoutSubtreeIfNeeded()
            #expect(abs(panel.frame.width - expected.width) <= 1)
            #expect(abs(panel.frame.height - expected.height) <= 1)
            #expect(panel.filterField.frame.height == 30)
            #expect(panel.table.frame.width <= panel.table.enclosingScrollView!.contentView.bounds.width)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            // At x=12 the highlight is clear of both the rounded edge and the
            // checkmark/icon. Its painted height must fill the 28 pt row.
            let bluePixels = (0..<bitmap.pixelsHigh).filter { y in
                guard let color = bitmap.colorAt(x: Int(12 * scale), y: y)?.usingColorSpace(.deviceRGB) else {
                    return false
                }
                return color.redComponent < 0.4 && color.greenComponent > 0.15 && color.blueComponent > 0.6
            }.count
            let capsuleHeight = CGFloat(bluePixels) / scale
            #expect(abs(capsuleHeight - 28) <= 1)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("switcher-reference-" + name + ".png"))
            measurements.append([
                "reference": name,
                "width": panel.frame.width,
                "height": panel.frame.height,
                "capsuleHeight": capsuleHeight
            ])
        }
        // Both actions are explicitly required by §3.1. Their extra row adds
        // 28 pt to the reference's two-group layout, without widening it.
        panel.configure(model: .init(groups: groups, filter: ""))
        #expect(panel.frame.size == NSSize(width: 194, height: 209))
        let production = try #require(panel.contentView)
        production.layoutSubtreeIfNeeded()
        let bitmap = try #require(production.bitmapImageRepForCachingDisplay(in: production.bounds))
        production.cacheDisplay(in: production.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("switcher-tecolot-two-groups.png"))
        measurements.append(["fixture": "Tecolot two groups", "width": panel.frame.width, "height": panel.frame.height])
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("switcher-measurements.json"))
        #expect(!panel.isVisible)
    }

    @Test func titleOriginFollowsTheIconCount() {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = workspace.controllers[0]
        for _ in 1..<5 {
            workspace.split(first, direction: .right)
        }
        defer { workspace.terminateAll() }
        let cell = TabItemView(tab: TerminalTab(workspace: workspace), controller: nil)
        cell.frame = NSRect(x: 0, y: 0, width: 242, height: 32)
        var preferences = TabStripPreferences()
        let origins: [CGFloat] = [16.5, 44, 48.5, 54.5, 60.5, 66.5]
        for count in 0...5 {
            preferences.iconCount = count
            cell.configure(
                selected: true,
                key: false,
                chrome: TabStripChrome(theme: nil, opacity: 1, key: false, appearance: cell.effectiveAppearance),
                preferences: preferences
            )
            cell.layoutSubtreeIfNeeded()
            #expect(cell.titleField.superview?.frame.minX == origins[count])
        }
    }

    @Test(arguments: ["TabSpec", String(repeating: "Wide ", count: 20)])
    func renameCommandsAndContextMenusUseInlineEditors(initialGroupName: String) throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let tab = TerminalTab(startsProcesses: false)
        let group = manager.newGroup(tab: tab)
        manager.rename(group, to: initialGroupName)
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        owner.window?.setContentSize(NSSize(width: 1180, height: 760))
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(!owner.tabBar.groupButton.isHidden)
        #expect(owner.tabBar.groupButton.title.isEmpty)
        owner.renameGroup() // File > Rename Group… routes here.
        let groupEditor = try #require(owner.tabBar.subviews.compactMap {
            $0 as? InlineNameField
        }.first)
        let captionWidth: CGFloat = initialGroupName == "TabSpec" ? 105 : 190
        #expect(!groupEditor.isHiddenOrHasHiddenAncestor)
        #expect(owner.tabBar.groupButton.frame == NSRect(x: 85, y: 5, width: captionWidth, height: 36))
        #expect(groupEditor.frame == NSRect(x: 87, y: 11, width: captionWidth - 4, height: 24))
        #expect(owner.tabBar.groupButton.isHidden)
        #expect(owner.tabBar.scroll.frame == NSRect(x: 93 + captionWidth, y: 7, width: 936 - captionWidth, height: 32))
        groupEditor.stringValue = "Inline group"
        #expect(groupEditor.control(groupEditor, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(group.name == "Inline group")
        #expect(groupEditor.superview == nil)
        owner.tabBar.layoutSubtreeIfNeeded()
        #expect(!owner.tabBar.groupButton.isHidden)
        #expect(owner.tabBar.groupButton.title.isEmpty)
        #expect(owner.tabBar.groupButton.accessibilityValue() as? String == "Inline group")
        #expect(owner.tabBar.groupButton.frame == NSRect(x: 85, y: 7, width: 34, height: 32))
        #expect(owner.tabBar.scroll.frame == NSRect(x: 127, y: 7, width: 902, height: 32))

        owner.renameTab(tab)
        let cell = try #require(owner.tabBar.cells.first)
        let editor = try #require(cell.subviews.compactMap {
            $0 as? InlineNameField
        }.first)
        editor.stringValue = "Inline tab"
        #expect(editor.control(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(tab.customName == "Inline tab")
        #expect(editor.superview == nil)

        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: owner.window!.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        for (view, title, container) in [
            (cell as NSView, "Rename Tab…", cell as NSView),
            (owner.tabBar.groupButton as NSView, "Rename Group…", owner.tabBar as NSView)
        ] {
            let item = try #require(view.menu(for: event)?.items.first {
                $0.title == title
            })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            let inline = try #require(container.subviews.compactMap {
                $0 as? InlineNameField
            }.first)
            #expect(inline.control(inline, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            #expect(inline.superview == nil)
        }
        owner.tabBar.layoutSubtreeIfNeeded()
        #expect(!owner.tabBar.groupButton.isHidden)
        #expect(owner.tabBar.groupButton.title.isEmpty)
        #expect(owner.tabBar.groupButton.isAccessibilityElement())
        #expect(owner.tabBar.groupButton.accessibilityValue() as? String == "Inline group")
        #expect(owner.tabBar.groupButton.frame == NSRect(x: 85, y: 7, width: 34, height: 32))
        #expect(owner.tabBar.scroll.frame == NSRect(x: 127, y: 7, width: 902, height: 32))
        #expect(owner.window?.isVisible == false)
    }

    @Test func renderBackgroundCaptureFallbacksAndMeasureFrames() async throws {
        let directory = URL(fileURLWithPath: "/tmp/tecolot-m3", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var measurements: [[String: Any]] = []
        func rect(_ value: NSRect) -> [Double] {
            [value.minX, value.minY, value.width, value.height]
        }
        for (style, theme) in [("light", "Terminal Basic"), ("dark", "Terminal Basic Dark")] {
            for (kind, count) in [("one", 1), ("five", 5), ("overflow", 20), ("split", 1)] {
                let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
                let first = TerminalTab(startsProcesses: false)
                let group = manager.newGroup(tab: first)
                manager.rename(group, to: "TabSpec")
                for index in 1..<max(1, count) {
                    let tab = TerminalTab(startsProcesses: false)
                    tab.customName = "Tab \(index + 1)"
                    manager.addTab(tab, to: group)
                }
                if kind == "split", let pane = first.workspace.focusedController {
                    first.workspace.split(pane, direction: .right)
                    first.workspace.split(pane, direction: .down)
                }
                let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
                let window = try #require(owner.window)
                window.setContentSize(NSSize(width: 1180, height: 760))
                for tab in group.tabs {
                    for (index, pane) in tab.workspace.controllers.enumerated() {
                        pane.applyThemeOverride(theme)
                        pane.updatePaneExecutablePath(["/usr/bin/python3", "/usr/bin/emacs", "/opt/bin/claude"][index % 3])
                        pane.terminal?.feed(text: "\u{1b}[32m$\u{1b}[0m Tecolot M3\r\nAbove tabs, \(kind), \(style) theme\r\n")
                    }
                }
                manager.select(first, in: group)
                owner.show(group)
                let root = try #require(window.contentView)
                root.layoutSubtreeIfNeeded()
                let bar = owner.tabBar
                bar.layoutSubtreeIfNeeded()
                let firstCell = try #require(bar.cells.first)
                firstCell.layoutSubtreeIfNeeded()
                let surface = root.superview ?? root
                surface.layoutSubtreeIfNeeded()
                let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
                surface.cacheDisplay(in: surface.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = kind + "-" + style
                try data.write(to: directory.appendingPathComponent(name + "-offscreen.png"))
                measurements.append([
                    "name": name,
                    "bar": rect(bar.frame),
                    "groupButton": rect(bar.groupButton.frame),
                    "strip": rect(bar.scroll.frame),
                    "cell": rect(firstCell.frame),
                    "iconHost": rect(firstCell.icon.frame),
                    "title": rect(firstCell.titleField.superview!.frame),
                    "close": rect(firstCell.closeButton.frame),
                    "content": rect(first.hostView.frame),
                    "selection": rect(bar.selectionSurface.frame),
                    "contentWidth": bar.stripLayout.contentWidth,
                    "selectedOffset": bar.scroll.contentView.bounds.minX,
                    "visibleIndices": Array(bar.stripLayout.visibleIndices(offset: bar.scroll.contentView.bounds.minX)),
                    "trafficLights": [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
                        window.standardWindowButton($0).map {
                            rect(root.convert($0.bounds, from: $0))
                        }
                    }
                ])
                #expect(!window.isVisible)
                manager.closeGroup(group)
                // Let hosted tests that are waiting for PTY/helper responses
                // run between the relatively expensive bitmap captures.
                await Task.yield()
            }
        }
        let data = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("chrome-measurements.json"))
    }

    /// Prepares a reproducible workspace for a background-only manual capture.
    /// This writes fixtures in /tmp, never into the app's state directory.
    @Test func prepareBackgroundCaptureWorkspace() throws {
        let directory = URL(fileURLWithPath: "/tmp/tecolot-m3", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var groups: [RestoreGroup] = []
        var windows: [RestoreWindow] = []
        for (style, theme) in [("light", "Terminal Basic"), ("dark", "Terminal Basic Dark")] {
            for (kind, count) in [("one", 1), ("five", 5), ("overflow", 20), ("split", 1)] {
                let tabs = (0..<count).map { index -> RestoreTab in
                    let pane = RestorePane(
                        id: UUID(),
                        kind: .local,
                        themeOverride: theme,
                        directory: PaneDirectory(path: "/tmp", source: .osc7)
                    )
                    var root = RestorePaneNode.pane(pane)
                    if kind == "split" {
                        root = .split(
                            .vertical,
                            fraction: 0.5,
                            first: root,
                            second: .split(
                                .horizontal,
                                fraction: 0.5,
                                first: .pane(RestorePane(id: UUID(), kind: .local, themeOverride: theme)),
                                second: .pane(RestorePane(id: UUID(), kind: .local, themeOverride: theme))
                            )
                        )
                    }
                    return RestoreTab(name: "\(kind)-\(style) \(index + 1)", focusedPaneID: pane.id, root: root)
                }
                let group = RestoreGroup(name: "TabSpec", isNameCustom: true, tabs: tabs)
                groups.append(group)
                windows.append(RestoreWindow(groupID: group.id, frame: NSStringFromRect(NSRect(x: 160, y: 120, width: 1180, height: 760))))
            }
        }
        let state = RestoreState(
            bootID: nil,
            savedAt: Date(),
            groups: groups,
            windows: windows,
            windowGroupsMigrated: true,
            cleanShutdown: false
        )
        try RestoreStateMigrator().encodeCurrent(state).write(to: directory.appendingPathComponent("capture-workspace.json"))
    }
}

@MainActor
struct TabStripPointerTests {
    @Test func tabHoverSuspendsNativeWindowMovementBeforeMouseDown() throws {
        let suite = "TabStripPointer-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("horizontal", forKey: ProgramActivityPreferences.tabStyleKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { manager.makeWindow = nil }
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        let window = try #require(owner.window as? TerminalWindow)
        window.contentView?.layoutSubtreeIfNeeded()
        let cell = try #require(owner.tabBar.cells.first)
        let point = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
        window.isMovable = true
        window.updateTabPointer(at: point)
        #expect(!window.isMovable)
        window.updateTabPointer(at: point)
        window.updateTabPointer(at: NSPoint(x: 10, y: 100))
        #expect(window.isMovable)
        window.isMovable = false
        window.updateTabPointer(at: point)
        window.updateTabPointer(at: NSPoint(x: 10, y: 100))
        #expect(!window.isMovable)
    }

    @Test func titlebarTabCentersRouteMouseHitsToCells() throws {
        let suite = "TabStripPointer-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("horizontal", forKey: ProgramActivityPreferences.tabStyleKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { manager.makeWindow = nil }
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        manager.addTab(TerminalTab(startsProcesses: false), to: group)
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        let window = try #require(owner.window)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.contentView?.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let frame = try #require(window.contentView?.superview)
        for cell in owner.tabBar.cells {
            let center = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: frame)
            let hit = frame.hitTest(center)
            #expect(hit === cell)
        }
        #expect(!owner.tabBar.scroll.automaticallyAdjustsContentInsets)
        #expect(!owner.tabBar.mouseDownCanMoveWindow)
        #expect(!owner.tabBar.scroll.mouseDownCanMoveWindow)
    }
}
