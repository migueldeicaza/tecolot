import AppKit
import Testing
@testable import Tecolot

@MainActor
private final class SidebarModelWindow: TerminalGroupWindow {
    let id = UUID()
    var group: TerminalTabGroup
    var activations = 0
    init(_ group: TerminalTabGroup) {
        self.group = group
    }
    func show(_ group: TerminalTabGroup) {
        self.group = group
    }
    func activate() {
        activations += 1
    }
    func closeWindow() {}
}

@MainActor
@Suite(.serialized)
struct SidebarTests {
    private func dormant(_ name: String = "Saved") -> TerminalTab {
        let saved = RestoreTab(name: name, root: .pane(RestorePane(id: UUID(), kind: .local)))
        return TerminalTab(dormant: RestoreStore.launchSpec(for: RestoredTab(tab: saved, panes: [:])), startsProcesses: false)
    }
    private func live(_ name: String = "Live") -> TerminalTab {
        let tab = TerminalTab(startsProcesses: false)
        tab.customName = name
        return tab
    }
    private func manager() -> TerminalWindowManager {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            SidebarModelWindow($0)
        }
        return manager
    }
    private func stop(_ manager: TerminalWindowManager) {
        for window in manager.windows {
            manager.closeWindow(window)
        }
        for group in manager.groups {
            manager.closeGroup(group)
        }
        manager.makeWindow = nil
    }

    @Test func collapseOfAGroupShownElsewhereReachesEverySidebar() throws {
        let suite = "SidebarCollapse-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { stop(manager) }
        let current = manager.newGroup(tab: live("One"))
        let owner = try #require(manager.openWindow(group: current) as? TerminalWindowController)
        let other = manager.newGroup(tab: live("Two"))
        _ = manager.openWindow(group: other)
        let background = manager.newGroup(tab: live("Three"))
        owner.sidebar.reload()
        #expect(owner.sidebar.model?.numberedTabs.map(\.tab.title) == ["One", "Two", "Three"])
        // Neither group is shown in `owner`, but its sidebar lists both.
        manager.setCollapsed(true, group: background)
        #expect(owner.sidebar.model?.numberedTabs.map(\.tab.title) == ["One", "Two"])
        manager.setCollapsed(true, group: other)
        #expect(owner.sidebar.model?.numberedTabs.map(\.tab.title) == ["One"])
        manager.collapseOthers(background)
        #expect(owner.sidebar.model?.numberedTabs.map(\.tab.title) == ["Three"])
    }

    @Test func orderedKindsCollapseFilterAndDigitDestinations() {
        let manager = manager()
        defer { stop(manager) }
        let current = manager.newGroup(tab: live("One"))
        let owner = manager.openWindow(group: current)
        let other = manager.newGroup(tab: live("Two"))
        _ = manager.openWindow(group: other)
        let background = manager.newGroup(tab: live("Three"))
        let saved = manager.newGroup(tab: dormant("Four"))
        let model = SidebarModel(manager: manager, current: current)
        #expect(model.sections.map(\.group.id) == manager.groups.map(\.id))
        #expect(model.sections.map(\.kind) == [.current, .otherWindow, .background, .dormant])
        #expect(model.numberedTabs.map(\.tab.title) == ["One", "Two", "Three", "Four"])
        manager.setCollapsed(true, group: other)
        #expect(SidebarModel(manager: manager, current: current).numberedTabs.map(\.tab.title) == ["One", "Three", "Four"])
        manager.rename(background, to: "Work")
        #expect(SidebarModel(manager: manager, current: current, filter: "work").numberedTabs.map(\.tab.title) == ["Three"])
        #expect(SidebarModel(manager: manager, current: current, filter: "four").numberedTabs.map(\.tab.title) == ["Four"])
        manager.collapseOthers(background)
        #expect(manager.groups.filter {
            !$0.isCollapsed
        }.map(\.id) == [background.id])
        manager.moveGroup(saved, offset: -1)
        #expect(SidebarModel(manager: manager, current: owner.group).sections.map(\.group.id) == [current.id, other.id, saved.id, background.id])
        #expect(saved.tabs[0].isDormant)
    }

    @Test func clicksRouteCurrentOtherBackgroundAndDormant() throws {
        let manager = manager()
        defer { stop(manager) }
        let current = manager.newGroup(tab: live())
        let owner = try #require(manager.openWindow(group: current) as? SidebarModelWindow)
        let other = manager.newGroup(tab: live())
        let elsewhere = try #require(manager.openWindow(group: other) as? SidebarModelWindow)
        let background = manager.newGroup(tab: live())
        let saved = manager.newGroup(tab: dormant())
        manager.navigate(to: current, tab: current.tabs[0], in: owner)
        #expect(owner.activations == 1)
        manager.navigate(to: other, tab: other.tabs[0], in: owner)
        #expect(elsewhere.activations == 1)
        #expect(owner.group === current)
        manager.navigate(to: background, tab: background.tabs[0], in: owner)
        #expect(owner.group === background)
        #expect(manager.backgroundGroups.contains {
            $0 === current
        })
        manager.navigate(to: saved, tab: saved.tabs[0], in: owner)
        #expect(owner.group === saved)
        #expect(!saved.tabs[0].isDormant)
        #expect(Set(manager.windows.map(\.group.id)).count == manager.windows.count)
    }

    @Test func moveMatrixKeepsOneHostAndDormantSiblingsAsleep() throws {
        for sourceKind in 0..<4 {
            for targetKind in 0..<4 {
                let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
                let moved = sourceKind == 3 ? dormant() : live()
                let source = manager.newGroup(tab: moved)
                let targetTab = targetKind == 3 ? dormant() : live()
                let target = manager.newGroup(tab: targetTab)
                if sourceKind < 2 {
                    _ = manager.openWindow(group: source)
                }
                if targetKind < 2 {
                    _ = manager.openWindow(group: target)
                }
                let before = moved.loadedWorkspace
                manager.move(moved, from: source, to: target, insertion: 0)
                #expect(!manager.groups.contains {
                    $0 === source
                })
                #expect(target.tabs.first === moved)
                #expect(target.selection == moved.id)
                #expect(targetTab.isDormant == (targetKind == 3))
                #expect(moved.loadedWorkspace === before)
                #expect(Set(manager.groups.flatMap {
                    $0.tabs.map(\.id)
                }).count == 2)
                #expect(Set(manager.windows.map(\.group.id)).count == manager.windows.count)
                if !moved.isDormant {
                    let expected = (manager.window(showing: target) as? TerminalWindowController)?.window
                    #expect(moved.hostView.window === expected)
                }
                stop(manager)
            }
        }
    }

    @Test func contextMenuMovesTheBackgroundTabAndRetainsNewWindowAction() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        defer { stop(manager) }
        let current = manager.newGroup(tab: live("Current"))
        let owner = try #require(manager.openWindow(group: current) as? TerminalWindowController)
        let moving = live("Move me")
        let background = manager.newGroup(tab: moving)
        let saved = manager.newGroup(tab: dormant())
        let cell = TabItemView(tab: moving, controller: owner)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))
        let menu = try #require(cell.menu(for: event))
        #expect(menu.items.contains {
            $0.title == "Move to New Window"
        })
        let moves = try #require(menu.items.first {
            $0.title == "Move to Group"
        }?.submenu)
        #expect(moves.items.prefix(3).map(\.title) == manager.groups.map(\.name))
        #expect(moves.items.last?.title == "New Group")
        moves.performActionForItem(at: 2)
        #expect(saved.tabs.last === moving)
        #expect(saved.tabs.first?.isDormant == true)
        #expect(moving.hostView.window == nil)
        #expect(!manager.groups.contains {
            $0 === background
        })
    }

    @Test func newBackgroundTabHasASurfaceWithoutStartingDormantSiblings() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        defer { stop(manager) }
        let current = manager.newGroup(tab: live())
        let owner = try #require(manager.openWindow(group: current) as? TerminalWindowController)
        let saved = dormant()
        let background = manager.newGroup(tab: saved)
        owner.newTab(in: background, startsProcesses: false)
        let added = try #require(background.tabs.last)
        #expect(added !== saved)
        #expect(saved.isDormant)
        #expect(!added.isDormant)
        #expect(added.loadedWorkspace?.focusedController?.surface != nil)
        #expect(added.hostView.window == nil)
        #expect(owner.group === current)
    }

    @Test func liveStyleChangesReachEveryWindowAndOutlineNavigationRetainsFocus() async throws {
        let suite = "SidebarWindows-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { stop(manager) }
        let first = manager.newGroup(tab: live("One"))
        let next = live("Two")
        manager.addTab(next, to: first)
        let second = manager.newGroup(tab: live("Three"))
        let a = try #require(manager.openWindow(group: first) as? TerminalWindowController)
        let b = try #require(manager.openWindow(group: second) as? TerminalWindowController)
        SidebarPreferences.setStyle(.left, defaults: defaults)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        #expect(a.sidebarPreferences.style == .left)
        #expect(b.sidebarPreferences.style == .left)
        a.window?.makeFirstResponder(a.sidebar.outline)
        let row = a.sidebar.outline.row(forItem: first.tabs[0])
        a.sidebar.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        #expect(first.selection == first.tabs[0].id)
        #expect(a.window?.firstResponder === a.sidebar.outline)
        a.sidebar.select(next)
        #expect(first.selection == next.id)
        #expect(a.window?.firstResponder === next.loadedWorkspace?.focusedController?.surface)
        a.toggleSidebar()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        #expect(a.sidebar.isHidden && b.sidebar.isHidden)
    }

    @Test func backgroundTitlesUpdateWithoutAManagerOrActivityNotification() async throws {
        let suite = "SidebarObservation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SidebarPreferences.setStyle(.left, defaults: defaults)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { stop(manager) }
        let current = manager.newGroup(tab: live())
        let owner = try #require(manager.openWindow(group: current) as? TerminalWindowController)
        let tab = live("Before")
        _ = manager.newGroup(tab: tab)
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        let row = owner.sidebar.outline.row(forItem: tab)
        let cell = try #require(owner.sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabItemView)
        tab.customName = "After"
        let deadline = ContinuousClock.now + .seconds(2)
        while cell.titleField.stringValue != "After", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(cell.titleField.stringValue == "After")
    }

    @Test func filteredDropBoundariesAndReorderMath() {
        let tabs = [live("a"), live("b"), live("c"), live("d")]
        let group = TerminalTabGroup(name: "g", tabs: tabs)
        let visible = [tabs[1], tabs[3]]
        #expect(SidebarModel.insertionIndex(group: group, visible: visible, boundary: -1) == 4)
        #expect(SidebarModel.insertionIndex(group: group, visible: visible, boundary: 0) == 1)
        #expect(SidebarModel.insertionIndex(group: group, visible: visible, boundary: 1) == 3)
        #expect(SidebarModel.insertionIndex(group: group, visible: visible, boundary: 2) == 4)
        #expect(TabStripLayout.reorderIndex(source: 1, insertion: 4, count: 4) == 3)
        #expect(TabStripLayout.reorderIndex(source: 3, insertion: 1, count: 4) == 1)
        #expect(SidebarModel.insertionIndex(group: group, visible: [], boundary: 0) == 4)
    }

    /// Saves the exact view frames and a workspace for background window captures.
    @Test func measuredFramesAccessibilityAndCaptureFixture() throws {
        let directory = URL(fileURLWithPath: "/tmp/tecolot-m5", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "SidebarGeometry-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(271, forKey: SidebarPreferences.widthKey)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        let tab = live("Three panes")
        let pane = try #require(tab.workspace.focusedController)
        tab.workspace.split(pane, direction: .right)
        tab.workspace.split(pane, direction: .down)
        let group = manager.newGroup(tab: tab)
        manager.rename(group, to: "Development")
        manager.addTab(live("Build"), to: group)
        manager.addTab(live("Tests"), to: group)
        manager.select(tab, in: group)
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        let elsewhere = manager.newGroup(tab: live("Logs"))
        manager.rename(elsewhere, to: "Other Window")
        _ = manager.openWindow(group: elsewhere)
        let background = manager.newGroup(tab: live("Worker"))
        manager.rename(background, to: "Live Background")
        let collapsed = manager.newGroup(tab: dormant("Archive"))
        manager.rename(collapsed, to: "Collapsed")
        manager.setCollapsed(true, group: collapsed)
        let saved = manager.newGroup(tab: dormant("Saved shell"))
        manager.rename(saved, to: "Dormant")
        defer { stop(manager) }
        let window = try #require(owner.window)
        window.setFrame(NSRect(x: 160, y: 120, width: 1180, height: 760), display: false)
        func rect(_ value: NSRect) -> [Double] {
            [value.minX, value.minY, value.width, value.height]
        }
        var measurements: [[String: Any]] = []
        for style in [SidebarPreferences.Style.left, .right] {
            SidebarPreferences.setStyle(style, defaults: defaults)
            owner.refreshSidebarPreferences()
            for hidden in [false, true] {
                defaults.set(hidden, forKey: SidebarPreferences.hiddenKey)
                owner.refreshSidebarPreferences()
                let root = try #require(window.contentView)
                root.layoutSubtreeIfNeeded()
                owner.positionTrafficLights()
                owner.sidebar.outline.layoutSubtreeIfNeeded()
                let row = owner.sidebar.outline.row(forItem: tab)
                let cell = try #require(owner.sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabItemView)
                cell.layoutSubtreeIfNeeded()
                #expect(cell.frame.minX == 9)
                if !hidden {
                    #expect(cell.frame.width == 253)
                }
                #expect(cell.frame.height == 32)
                #expect(cell.icon.frame.width == 24)
                #expect(cell.titleField.superview?.frame.minX == 38)
                #expect(owner.sidebar.outline.accessibilityRole() == .outline)
                #expect(cell.accessibilityLabel() == tab.title)
                #expect(cell.accessibilityValue() as? String == tab.status.accessibilityValue)
                let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
                    window.standardWindowButton(type).map {
                        root.convert($0.bounds, from: $0)
                    }
                }
                #expect(lights.first == NSRect(x: 17, y: 17, width: 16, height: 16))
                if !hidden {
                    let heading = try #require(owner.sidebar.outline.view(atColumn: 0, row: 0, makeIfNecessary: true))
                    #expect(heading.frame.height == 25)
                    #expect(owner.sidebar.convert(heading.bounds, from: heading).minY == 45)
                    #expect(owner.sidebar.scroll.contentInsets.top == 0)
                    #expect(owner.sidebar.outline.rect(ofRow: 0).minY == 0)
                    #expect(owner.sidebar.outline.rect(ofRow: 1).minY == 34)
                    #expect(owner.sidebar.convert(cell.bounds, from: cell).minY == 72)
                }
                measurements.append([
                    "style": style.rawValue,
                    "hidden": hidden,
                    "firstHeaderRow": rect(owner.sidebar.outline.rect(ofRow: 0)),
                    "tabInSidebar": rect(owner.sidebar.convert(cell.bounds, from: cell)),
                    "sidebar": rect(owner.sidebar.frame),
                    "list": rect(owner.sidebar.scroll.frame),
                    "tab": rect(cell.frame),
                    "icon": rect(cell.icon.frame),
                    "title": rect(cell.titleField.superview!.frame),
                    "header": rect(owner.contentHeader.frame),
                    "content": rect(tab.hostView.frame),
                    "trafficLights": lights.map(rect)
                ])
            }
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("view-measurements.json"))
        let store = RestoreStore(directory: directory)
        var (state, _, _) = store.capture(limit: 0, manager: manager)
        // Materialize the background terminal before capturing its live description.
        _ = background.tabs[0].hostView
        state = store.capture(limit: 0, manager: manager).0
        #expect(state.groups.count == 5)
        // Restore this third window, then close it without activation to make a live background group.
        state.windows = [group, elsewhere, background].map {
            RestoreWindow(groupID: $0.id, frame: NSStringFromRect(NSRect(x: 160, y: 120, width: 1180, height: 760)))
        }
        state.windowGroupsMigrated = true
        for index in state.groups.indices {
            state.groups[index].tabs = state.groups[index].tabs.map { saved in
                var saved = saved
                func theme(_ node: RestorePaneNode) -> RestorePaneNode {
                    switch node {
                    case .pane(var pane):
                        pane.themeOverride = "Terminal Basic"
                        return .pane(pane)
                    case .split(let orientation, let fraction, let first, let second):
                        return .split(orientation, fraction: fraction, first: theme(first), second: theme(second))
                    }
                }
                saved.root = theme(saved.root)
                return saved
            }
        }
        try RestoreStateMigrator().encodeCurrent(state).write(to: directory.appendingPathComponent("capture-workspace.json"))
    }

    @Test func singlePaneCardRoundsOnlyTheOutsideCorners() throws {
        let suite = "SidebarCorners-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SidebarPreferences.setStyle(.right, defaults: defaults)
        defaults.set(271, forKey: SidebarPreferences.widthKey)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { stop(manager) }
        let tab = live()
        tab.workspace.focusedController?.themeOverride = "Terminal Basic"
        let group = manager.newGroup(tab: tab)
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        let window = try #require(owner.window)
        window.setContentSize(NSSize(width: 1180, height: 760))
        owner.refreshTabPreferences()
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        owner.chromeBackdrop.update(
            visible: true, backdrop: .chrome,
            appearance: ResolvedWorkspaceAppearance(theme: .fallback), chromeColor: .magenta
        )
        root.displayIfNeeded()
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / root.bounds.width
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        graphics.cgContext.translateBy(x: 0, y: root.bounds.height)
        graphics.cgContext.scaleBy(x: 1, y: -1)
        root.layer?.render(in: graphics.cgContext)
        func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
        }
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
        }
        let outside = try color(2, 400)
        let inside = try color(40, 400)
        #expect(distance(outside, inside) > 0.5)
        #expect(try distance(color(8.5, 8.5), outside) < 0.03)
        #expect(try distance(color(8.5, 751.5), outside) < 0.03)
        #expect(try distance(color(12, 43), inside) < 0.03)
        #expect(try distance(color(12, 45), inside) < 0.03)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/tecolot-m5/card-corners-offscreen.png"))
    }

    @Test func stylesWidthAndHiddenStatePersistWithoutReplacingFocus() throws {
        let suite = "SidebarTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SidebarPreferences(defaults: defaults).width == 240)
        #expect(SidebarPreferences.clampWidth(5) == 167)
        #expect(SidebarPreferences.clampWidth(600) == 480)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        let tab = live()
        let group = manager.newGroup(tab: tab)
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { stop(manager) }
        let window = try #require(owner.window)
        window.setContentSize(NSSize(width: 1180, height: 760))
        let surface = try #require(tab.workspace.focusedController?.surface)
        window.makeFirstResponder(surface)
        for style in SidebarPreferences.Style.allCases {
            SidebarPreferences.setStyle(style, defaults: defaults)
            owner.refreshSidebarPreferences()
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(group.selection == tab.id)
            #expect(window.firstResponder === surface)
            #expect(tab.hostView.window === window)
            #expect(owner.sidebarPreferences.style == style)
            if style != .above {
                #expect(owner.sidebar.frame.width == 240)
                #expect(owner.sidebar.frame.minX == (style == .left ? 0 : 940))
                #expect(tab.hostView.frame.minX == (style == .left ? 240 : 8))
                #expect(owner.contentHeader.isHidden)
                owner.toggleSidebar()
                #expect(owner.sidebarPreferences.hidden)
                #expect(owner.sidebar.isHidden)
                #expect(owner.contentHeader.isHidden)
                #expect(owner.trafficLightCardID != nil)
                #expect(tab.hostView.frame.minX == 8)
                #expect(window.firstResponder === surface)
                owner.toggleSidebar()
            }
        }
        owner.resizeSidebar(to: 999, originalFrame: window.frame, originalWidth: 240)
        #expect(SidebarPreferences(defaults: defaults).width == 480)
        SidebarPreferences.setStyle(.right, defaults: defaults)
        SidebarPreferences.toggleStyle(defaults: defaults)
        #expect(SidebarPreferences(defaults: defaults).style == .above)
        SidebarPreferences.toggleStyle(defaults: defaults)
        #expect(SidebarPreferences(defaults: defaults).style == .right)
        defaults.set(true, forKey: SidebarPreferences.hiddenKey)
        #expect(SidebarPreferences(defaults: defaults).hidden)
        // In Above, digit nine chooses the ninth numbered cell, even with overflow.
        SidebarPreferences.setStyle(.above, defaults: defaults)
        owner.refreshSidebarPreferences()
        for index in 1...11 {
            manager.addTab(live("Tab \(index)"), to: group)
        }
        owner.selectNumberedTab(8)
        #expect(group.selection == group.tabs[8].id)
        manager.setCollapsed(true, group: group)
        let store = RestoreStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let (state, _, _) = store.capture(limit: 0, manager: manager)
        let roundTrip = try RestoreStateMigrator().decode(RestoreStateMigrator().encodeCurrent(state), from: 2)
        #expect(roundTrip.groups.first?.isCollapsed == true)
    }
}

@MainActor
struct SidebarHeaderPointerTests {
    @Test func inlineHeaderRenameGetsFocusAfterOutlineMouseHandling() async throws {
        let suite = "SidebarHeaderPointer-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("vertical", forKey: ProgramActivityPreferences.tabStyleKey)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { manager.makeWindow = nil }
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        let window = try #require(owner.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let outline = owner.sidebar.outline
        let row = outline.row(forItem: group)
        let header = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true))
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1
        ))
        header.mouseDown(with: event)
        window.makeFirstResponder(outline)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        let editor = try #require(header.subviews.compactMap {
            $0 as? NSTextField
        }.first {
            $0.isEditable
        })
        #expect(window.firstResponder === editor.currentEditor())
        #expect(!TerminalSessionController.canAutomaticallyFocus(from: window.firstResponder, in: window))
        window.makeFirstResponder(window)
    }

    @Test func renamedGroupHeaderUpdatesItsAccessibilityLabel() throws {
        let suite = "SidebarHeaderLabel-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("vertical", forKey: ProgramActivityPreferences.tabStyleKey)
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            TerminalWindowController(group: $0, manager: manager, defaults: defaults)
        }
        defer { manager.makeWindow = nil }
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: group) as? TerminalWindowController)
        defer { manager.closeGroup(group) }
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        let outline = owner.sidebar.outline
        let header = try #require(outline.view(atColumn: 0, row: outline.row(forItem: group), makeIfNecessary: true))
        manager.rename(group, to: "Renamed group")
        #expect(header.accessibilityLabel() == "Renamed group")
    }

    @Test func automaticTerminalFocusPreservesChromeControls() {
        let window = NSWindow()
        #expect(TerminalSessionController.canAutomaticallyFocus(from: nil, in: window))
        #expect(TerminalSessionController.canAutomaticallyFocus(from: window, in: window))
        for control in [NSTextField(), NSTextView(), NSOutlineView(), NSButton()] as [NSResponder] {
            #expect(!TerminalSessionController.canAutomaticallyFocus(from: control, in: window))
        }
        let hidden = NSOutlineView()
        hidden.isHidden = true
        #expect(TerminalSessionController.canAutomaticallyFocus(from: hidden, in: window))
    }
}
