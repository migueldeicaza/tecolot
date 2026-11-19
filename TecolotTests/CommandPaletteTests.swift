import AppKit
import Foundation
import Testing
@testable import Tecolot

// MARK: - Search & Highlighting

struct CommandPaletteSearchTests {
    @Test func ranksExactOverPrefixOverWordBoundaryOverSubstringOverFuzzyOverKeyword() throws {
        let exact = try #require(CommandPaletteSearch.match(query: "Close Tab", title: "Close Tab"))
        let prefix = try #require(CommandPaletteSearch.match(query: "Close", title: "Close Tab"))
        let wordBoundary = try #require(CommandPaletteSearch.match(query: "Tab", title: "Close Tab"))
        let substring = try #require(CommandPaletteSearch.match(query: "ose", title: "Close Tab"))
        let fuzzy = try #require(CommandPaletteSearch.match(query: "cltb", title: "Close Tab"))
        let keyword = try #require(CommandPaletteSearch.match(query: "kill", title: "Close Tab", keywords: ["kill"]))

        #expect(exact.score > prefix.score)
        #expect(prefix.score > wordBoundary.score)
        #expect(wordBoundary.score > substring.score)
        #expect(substring.score > fuzzy.score)
        #expect(fuzzy.score >= keyword.score)
    }

    @Test func subsequenceMatchesLikeRex() throws {
        let match = try #require(CommandPaletteSearch.match(query: "cltb", title: "Close Tab"))
        #expect(match.score > 0)
        // Non-contiguous fuzzy matches do not produce scattered letter highlights.
        #expect(match.titleRanges.isEmpty)
    }

    @Test func highlightsContiguousAndMultiTokenMatches() throws {
        let title = "Increase Font Size"
        let single = try #require(CommandPaletteSearch.match(query: "font", title: title))
        #expect(single.titleRanges.count == 1)
        #expect(String(title[single.titleRanges[0]]) == "Font")

        let multi = try #require(CommandPaletteSearch.match(query: "inc size", title: title))
        let matchedSlices = multi.titleRanges.map {
            String(title[$0])
        }
        #expect(matchedSlices == ["Inc", "Size"])
    }

    @Test func matchesSubtitleForTabRows() throws {
        let match = try #require(CommandPaletteSearch.match(query: "cosmic", title: "bash ~", subtitle: "cosmic-river"))
        #expect(match.titleRanges.isEmpty)
        #expect(match.subtitleRanges.count == 1)
        #expect(String("cosmic-river"[match.subtitleRanges[0]]) == "cosmic")
    }

    @Test func returnsNilWhenNoMatch() {
        #expect(CommandPaletteSearch.match(query: "zzzzz", title: "New Tab", keywords: ["shell"]) == nil)
    }
}

// MARK: - MRU Persistence

@MainActor
struct CommandPaletteMRUTests {
    @Test func recordsOrderDeduplicatesAndComputesDecayBoost() {
        let suite = "CommandPaletteMRUTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let mru = CommandPaletteMRU(defaults: defaults)
        #expect(mru.boost(for: "cmd.tab.new") == 0)

        mru.record("cmd.tab.new")
        mru.record("cmd.pane.splitRight")
        mru.record("cmd.tab.new")

        #expect(mru.recentIDs == ["cmd.tab.new", "cmd.pane.splitRight"])
        #expect(mru.boost(for: "cmd.tab.new") > mru.boost(for: "cmd.pane.splitRight"))
        #expect(mru.boost(for: "cmd.pane.splitRight") > 0)
    }
}

// MARK: - Catalog & State Machine

@MainActor
@Suite(.serialized)
struct CommandPaletteModelTests {
    private func makeFixture() -> (
        manager: TerminalWindowManager,
        controller: TerminalWindowController,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suite = "CommandPaletteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let tab = TerminalTab(startsProcesses: false)
        tab.customName = "api-server"
        let group = manager.newGroup(tab: tab)
        manager.rename(group, to: "cosmic-river")
        let controller = TerminalWindowController(group: group, manager: manager, defaults: defaults)
        return (manager, controller, defaults, suite)
    }

    @Test func rootSearchFindsGroupsTabsAndCommands() {
        let fixture = makeFixture()
        defer {
            fixture.controller.closeWindow()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }

        let catalog = CommandPaletteCatalog(
            owner: fixture.controller,
            manager: fixture.manager,
            defaults: fixture.defaults
        )
        let model = CommandPaletteModel(catalog: catalog, mru: CommandPaletteMRU(defaults: fixture.defaults))
        model.reset()

        // Empty query shows curated commands including sections.
        let sectionTitles = model.items.compactMap { item -> String? in
            if case .sectionHeader(let title) = item {
                return title
            }
            return nil
        }
        #expect(sectionTitles.contains("Pane"))
        #expect(sectionTitles.contains("Appearance"))
        #expect(sectionTitles.contains("App"))

        // Searching group name finds both the Group row and its Tab row.
        model.setQuery("cosmic")
        let matchingHeaders = model.items.compactMap { item -> String? in
            if case .sectionHeader(let title) = item {
                return title
            }
            return nil
        }
        #expect(matchingHeaders.contains("Groups"))
        #expect(matchingHeaders.contains("Tabs"))

        // Searching tab name finds the Tab row with its group subtitle.
        model.setQuery("api-server")
        let tabRow = model.items.compactMap(\.row).first {
            $0.id.hasPrefix("entity.tab.")
        }
        #expect(tabRow?.title == "api-server")
        #expect(tabRow?.subtitle == "cosmic-river")

        // Unmatched query renders empty hint state and clears selection.
        model.setQuery("zzzz-no-such-command")
        #expect(model.selectedIndex == nil)
        if case .hint(let message) = model.items.first {
            #expect(message == "No Results")
        } else {
            Issue.record("Expected No Results hint item")
        }
    }

    @Test func scopeStackPushPopAndTwoStageEscape() {
        let fixture = makeFixture()
        defer {
            fixture.controller.closeWindow()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }

        let catalog = CommandPaletteCatalog(
            owner: fixture.controller,
            manager: fixture.manager,
            defaults: fixture.defaults
        )
        let model = CommandPaletteModel(catalog: catalog, mru: CommandPaletteMRU(defaults: fixture.defaults))
        var dismissed = false
        model.onRequestDismiss = { _ in
            dismissed = true
        }
        model.reset()

        model.setQuery("Change Group")
        #expect(model.selectedRow?.id == "cmd.group.change")

        // Execute pushes [ Group ] scope.
        model.executeSelected()
        #expect(model.currentScope.chipTitle == "Group")
        #expect(model.query.isEmpty)
        #expect(!model.isAtRoot)

        // Typing inside sub-view then Escape clears query first (stays in scope).
        model.setQuery("abc")
        model.handleEscape()
        #expect(model.query.isEmpty)
        #expect(model.currentScope.chipTitle == "Group")
        #expect(!dismissed)

        // Backspace on empty sub-view pops scope and restores parent query + selection.
        #expect(model.handleBackspaceOnEmpty())
        #expect(model.isAtRoot)
        #expect(model.query == "Change Group")
        #expect(model.selectedRow?.id == "cmd.group.change")

        // Escape clears root query, second Escape dismisses.
        model.handleEscape()
        #expect(model.query.isEmpty)
        #expect(!dismissed)
        model.handleEscape()
        #expect(dismissed)
    }

    @Test func dynamicTogglesAndEnumPickersMutateState() {
        let fixture = makeFixture()
        defer {
            fixture.controller.closeWindow()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }

        let catalog = CommandPaletteCatalog(
            owner: fixture.controller,
            manager: fixture.manager,
            defaults: fixture.defaults
        )
        let model = CommandPaletteModel(catalog: catalog, mru: CommandPaletteMRU(defaults: fixture.defaults))
        model.reset()

        // Mute Tab toggles isMuted and flips label to Unmute Tab.
        model.setQuery("Mute Tab")
        #expect(model.selectedRow?.title == "Mute Tab")
        model.executeSelected()
        #expect(fixture.controller.group.selectedTab?.isMuted == true)

        model.reset()
        model.setQuery("Unmute Tab")
        #expect(model.selectedRow?.title == "Unmute Tab")

        // Terminal Padding enum picker writes UserDefaults.
        model.setQuery("Change Terminal Padding")
        model.executeSelected()
        #expect(model.currentScope.chipTitle == "Terminal Padding")
        model.setQuery("Spacious")
        model.executeSelected()
        #expect(
            fixture.defaults.string(forKey: GlobalAppearanceSettings.terminalPaddingKey)
                == GlobalAppearanceSettings.TerminalPadding.spacious.rawValue
        )
    }

    @Test func numericInputValidatesBounds() {
        let fixture = makeFixture()
        defer {
            fixture.controller.closeWindow()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }

        let catalog = CommandPaletteCatalog(
            owner: fixture.controller,
            manager: fixture.manager,
            defaults: fixture.defaults
        )
        let model = CommandPaletteModel(catalog: catalog, mru: CommandPaletteMRU(defaults: fixture.defaults))
        var submitted: Double?
        model.reset(initialScope: .numericInput(
            title: "Terminal Font Size",
            rangeText: "8 pt–64 pt",
            hint: "Type a terminal font size",
            min: 8,
            max: 64,
            unit: "pt",
            onSubmit: {
                submitted = $0
            }
        ))

        // Empty shows hint.
        #expect(model.selectedRow == nil)

        // Out of range shows validation hint.
        model.setQuery("200")
        #expect(model.selectedRow == nil)

        // Valid number enables action row and commits value.
        model.setQuery("18")
        #expect(model.selectedRow?.title == "Set Terminal Font Size to 18 pt")
        model.executeSelected()
        #expect(submitted == 18)
    }

    @Test func directoryPickerListsSubdirectoriesAndCompletes() async throws {
        let fixture = makeFixture()
        defer {
            fixture.controller.closeWindow()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TecolotDirPicker-\(UUID().uuidString)", isDirectory: true)
        let alpha = tempRoot.appendingPathComponent("alpha", isDirectory: true)
        let beta = tempRoot.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let catalog = CommandPaletteCatalog(
            owner: fixture.controller,
            manager: fixture.manager,
            defaults: fixture.defaults
        )
        let model = CommandPaletteModel(catalog: catalog, mru: CommandPaletteMRU(defaults: fixture.defaults))
        model.reset(initialScope: .directoryPicker(initialPath: tempRoot.path + "/"))
        await model.directoryLoadTask?.value

        let titles = model.items.compactMap(\.row).map(\.title)
        #expect(titles.contains("alpha"))
        #expect(titles.contains("beta"))

        // Filter to beta: while async load is pending, selection is cleared and Return/Tab ignore stale rows.
        var dismissedDuringPendingLoad = false
        model.onRequestDismiss = { _ in
            dismissedDuringPendingLoad = true
        }
        model.setQuery(tempRoot.path + "/be")
        #expect(model.isDirectoryLoadPending)
        #expect(model.selectedIndex == nil)
        #expect(!model.tabComplete())
        model.execute(at: 1)
        #expect(!dismissedDuringPendingLoad)

        await model.directoryLoadTask?.value
        #expect(!model.isDirectoryLoadPending)
        #expect(model.selectedRow?.title == "beta")
        #expect(model.tabComplete())
        #expect(model.query == beta.path + "/")
    }

    @Test func shellExecutableDetectionAllowsNestedShellsAndRejectsPrograms() {
        #expect(TerminalSessionController.isShellExecutable("-zsh"))
        #expect(TerminalSessionController.isShellExecutable("/bin/bash"))
        #expect(TerminalSessionController.isShellExecutable("/nix/store/abc-bash-5.2/bin/bash"))
        #expect(TerminalSessionController.isShellExecutable("/opt/homebrew/bin/fish"))
        #expect(TerminalSessionController.isShellExecutable("nu"))
        #expect(!TerminalSessionController.isShellExecutable("/usr/bin/vim"))
        #expect(!TerminalSessionController.isShellExecutable("/usr/bin/python3"))
        #expect(!TerminalSessionController.isShellExecutable("node"))
        #expect(!TerminalSessionController.isShellExecutable("less"))
    }

    @Test func aShellRunningAScriptIsNotAtItsPrompt() throws {
        func interactive(_ arguments: String...) -> Bool {
            TerminalSessionController.isInteractiveShell(arguments: arguments)
        }
        #expect(interactive("-zsh"))
        #expect(interactive("bash"))
        #expect(interactive("bash", "--login", "-i"))
        #expect(interactive("bash", "--rcfile", "/tmp/rc"))
        #expect(interactive("zsh", "-o", "vi"))
        #expect(!interactive("bash", "build.sh"))
        #expect(!interactive("/bin/sh", "./configure", "--prefix=/usr"))
        #expect(!interactive("sh", "-c", "sleep 100"))
        #expect(!interactive("bash", "-lc", "make"))
        #expect(!interactive("bash", "--", "script"))
        #expect(!interactive("bash", "-o", "errexit", "script"))

        // The arguments of a live process: a script that waits for input.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "read line"]
        process.standardInput = Pipe()
        try process.run()
        defer { process.terminate() }
        let arguments = try #require(TerminalSessionController.processArguments(of: process.processIdentifier))
        #expect(arguments == ["/bin/sh", "-c", "read line"])
        #expect(!TerminalSessionController.isInteractiveShell(processID: process.processIdentifier))
    }

    @Test func relativeDirectoryQueriesResolveAgainstPaneWorkingDirectory() {
        let resolved = CommandPaletteCatalog.resolveDirectoryQuery("Sources", baseDirectory: "/Users/test/project")
        #expect(resolved.searchDir == "/Users/test/project")
        #expect(resolved.filterPrefix == "Sources")
        #expect(resolved.canonicalCurrent == "/Users/test/project/Sources")

        let nested = CommandPaletteCatalog.resolveDirectoryQuery("Sources/", baseDirectory: "/Users/test/project")
        #expect(nested.searchDir == "/Users/test/project/Sources/")
        #expect(nested.filterPrefix.isEmpty)
        #expect(nested.canonicalCurrent == "/Users/test/project/Sources")

        let parent = CommandPaletteCatalog.resolveDirectoryQuery("../other", baseDirectory: "/Users/test/project")
        #expect(parent.searchDir == "/Users/test")
        #expect(parent.filterPrefix == "other")
    }

    @Test func remotePaneDisablesGoToDirectoryAndCdClearsInputLine() {
        let suite = "CommandPaletteRemote-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        var spec = LaunchSpec()
        spec.remoteDestination = "user@example.com"
        spec.persistent = true
        let tab = TerminalTab(spec: spec, startsProcesses: false)
        let group = manager.newGroup(tab: tab)
        let controller = TerminalWindowController(group: group, manager: manager, defaults: defaults)
        defer { controller.closeWindow() }

        #expect(tab.loadedWorkspace?.focusedController?.canChangeDirectory == false)

        let catalog = CommandPaletteCatalog(owner: controller, manager: manager, defaults: defaults)
        let commandIDs = catalog.commandRows().map(\.id)
        #expect(!commandIDs.contains("cmd.tab.goToDirectory"))

        let model = CommandPaletteModel(catalog: catalog, mru: CommandPaletteMRU(defaults: defaults))
        model.reset(initialScope: .directoryPicker(initialPath: nil))
        #expect(model.selectedRow == nil)
        if case .hint(let message) = model.items.first {
            #expect(message.contains("local shell prompt"))
        } else {
            Issue.record("Expected local-shell hint on remote pane")
        }

        // Verify cd command clears partially typed input line and escapes quotes.
        let cmd = CommandPaletteCatalog.formattedChangeDirectoryCommand(for: "/tmp/it's here")
        #expect(cmd == "\u{05}\u{15}cd '/tmp/it'\\''s here'\r")
    }

    @Test func typingGenericTermsSurfacesCommandsAboveManyTabsAndGroups() {
        let fixture = makeFixture()
        defer {
            fixture.controller.closeWindow()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        // Create 15 extra tabs and 3 extra groups with unrelated names.
        for i in 1...15 {
            let tab = TerminalTab(startsProcesses: false)
            tab.customName = "worker-\(i)"
            fixture.manager.addTab(tab, to: fixture.controller.group)
        }
        for name in ["alpha-work", "beta-work", "gamma-work"] {
            let g = fixture.manager.newGroup(tab: TerminalTab(startsProcesses: false))
            fixture.manager.rename(g, to: name)
        }

        let catalog = CommandPaletteCatalog(
            owner: fixture.controller,
            manager: fixture.manager,
            defaults: fixture.defaults
        )
        let model = CommandPaletteModel(catalog: catalog, mru: CommandPaletteMRU(defaults: fixture.defaults))
        model.reset()

        for term in ["tab", "group", "session", "workspace"] {
            model.setQuery(term)
            let top = model.selectedRow
            #expect(top != nil, "Expected match for '\(term)'")
            #expect(top?.isCommand == true, "Expected command first for '\(term)', got \(top?.title ?? "nil")")
        }
    }

    @Test func selectionMovementSkipsSectionHeaders() {
        let fixture = makeFixture()
        defer {
            fixture.controller.closeWindow()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }

        let catalog = CommandPaletteCatalog(
            owner: fixture.controller,
            manager: fixture.manager,
            defaults: fixture.defaults
        )
        let model = CommandPaletteModel(catalog: catalog, mru: CommandPaletteMRU(defaults: fixture.defaults))
        model.reset()

        let start = model.selectedIndex
        #expect(start != nil)
        for _ in 0..<40 {
            model.moveSelection(by: 1)
            if let idx = model.selectedIndex {
                #expect(model.items[idx].isSelectable)
            }
        }
    }

    @Test func themePickerPreviewsOnNavigationAndRevertsOnCancel() {
        let fixture = makeFixture()
        defer {
            fixture.controller.closeWindow()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        guard
            let pane = fixture.controller.group.selectedTab?.loadedWorkspace?.focusedController,
            AppModel.shared.themes.themes.count >= 2 else {
            return
        }
        pane.applyThemeOverride(nil)
        let catalog = CommandPaletteCatalog(
            owner: fixture.controller,
            manager: fixture.manager,
            defaults: fixture.defaults
        )
        let model = CommandPaletteModel(catalog: catalog, mru: CommandPaletteMRU(defaults: fixture.defaults))
        model.reset()
        model.setQuery("Change Theme")
        model.executeSelected()
        #expect(model.currentScope.chipTitle == "Theme")

        // Arrow navigation triggers live preview.
        model.moveSelection(by: 1)
        #expect(pane.themeOverride != nil)

        // Popping scope without committing reverts to original (nil).
        #expect(model.pop())
        #expect(pane.themeOverride == nil)
    }
}

// MARK: - Panel UI, Geometry & Keyboard

@MainActor
@Suite(.serialized)
struct CommandPalettePanelTests {
    private final class SpyPresenter: CommandPalettePresenting {
        var isVisible = false
        var presentedScopes: [PaletteScope] = []
        var dismissCount = 0

        func present(
            for controller: TerminalWindowController,
            manager: TerminalWindowManager,
            initialScope: PaletteScope,
            anchor: NSPoint?
        ) {
            isVisible = true
            presentedScopes.append(initialScope)
        }

        func dismiss(restoreFocus: Bool) {
            isVisible = false
            dismissCount += 1
        }
    }

    @Test func windowControllerWiresCommandPalettePresenter() {
        let suite = "CommandPaletteWire-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let controller = TerminalWindowController(group: group, manager: manager, defaults: defaults)
        let spy = SpyPresenter()
        controller.commandPalettePresenter = spy

        controller.toggleCommandPalette()
        #expect(spy.isVisible)
        #expect(spy.presentedScopes.count == 1)

        controller.openCommandPalette(scope: .directoryPicker(initialPath: nil))
        #expect(spy.presentedScopes.count == 2)
        #expect(spy.presentedScopes.last?.chipTitle == "Go to Directory")

        controller.closeWindow()
        #expect(spy.dismissCount >= 1)
    }

    @Test func panelResizesFromPinnedTopEdgeAndHandlesKeys() throws {
        let suite = "CommandPalettePanel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let controller = TerminalWindowController(group: group, manager: manager, defaults: defaults)
        controller.window?.setFrame(NSRect(x: 200, y: 200, width: 900, height: 700), display: false)
        defer { controller.closeWindow() }

        let panel = CommandPalettePanel(defaults: defaults)
        panel.present(for: controller, manager: manager, initialScope: .root)
        #expect(panel.isVisible)
        #expect(panel.frame.width == CommandPaletteMetrics.width)

        let initialTopY = panel.frame.maxY
        let initialHeight = panel.frame.height
        #expect(initialHeight == CommandPaletteMetrics.maxHeight)

        // Filtering to empty shrinks panel height while keeping top edge pinned.
        panel.activeModel?.setQuery("zzzz-unmatched-query")
        #expect(panel.frame.height < initialHeight)
        #expect(abs(panel.frame.maxY - initialTopY) <= 1)

        // Pressing Escape clears query, second Escape dismisses.
        let esc = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ))
        #expect(panel.handleKeyDown(esc))
        #expect(panel.activeModel?.query == "")
        #expect(panel.isVisible)

        #expect(panel.handleKeyDown(esc))
        #expect(!panel.isVisible)
    }

    @Test func panelConsumesTabShiftTabCmdShiftGAndToolbarMouseUpToggle() throws {
        let suite = "CommandPaletteKeys-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let controller = TerminalWindowController(group: group, manager: manager, defaults: defaults)
        defer { controller.closeWindow() }

        let panel = CommandPalettePanel(defaults: defaults)
        panel.present(for: controller, manager: manager, initialScope: .root)
        #expect(panel.isVisible)

        // Tab with nothing to complete and Shift-Tab are always consumed so focus stays in the search field.
        let tab = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
        let shiftTab = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{19}",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
        #expect(panel.handleKeyDown(tab))
        #expect(panel.handleKeyDown(shiftTab))

        // ⇧⌘G switches open palette straight into Go to Directory, and pressing it again closes.
        let cmdShiftG = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "G",
            charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5
        ))
        #expect(panel.handleKeyDown(cmdShiftG))
        #expect(panel.activeModel?.currentScope.chipTitle == "Go to Directory")
        #expect(panel.handleKeyDown(cmdShiftG))
        #expect(!panel.isVisible)

        // Toolbar button mouse-down dismissal suppresses reopen on the paired mouse-up (even 150ms later),
        // but a new click gesture (different eventNumber) is not suppressed.
        let winNum = controller.window?.windowNumber ?? 1
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 100.0,
            windowNumber: winNum, context: nil, eventNumber: 42, clickCount: 1, pressure: 1
        ))
        let pairedUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 100.15,
            windowNumber: winNum, context: nil, eventNumber: 42, clickCount: 1, pressure: 0
        ))
        let nextUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 100.5,
            windowNumber: winNum, context: nil, eventNumber: 43, clickCount: 1, pressure: 0
        ))
        panel.recordClickDismissal(from: down)
        #expect(panel.shouldSuppressReopen(for: pairedUp))
        #expect(!panel.shouldSuppressReopen(for: nextUp))
    }
}
