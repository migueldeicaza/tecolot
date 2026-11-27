import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Tecolot

@MainActor
@Suite(.serialized)
struct AppShortcutTests {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.tirania.Tecolot.AppShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func keyEvent(
        type: NSEvent.EventType = .keyDown,
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test func catalogCoversEveryActionIDWithUniqueDefaults() {
        #expect(AppShortcutCatalog.all.count == AppShortcutID.allCases.count)
        #expect(Set(AppShortcutCatalog.all.map(\.id)) == Set(AppShortcutID.allCases))

        let store = AppShortcutStore(defaults: makeIsolatedDefaults())
        for id in AppShortcutID.allCases {
            #expect(store.conflicts(for: id).isEmpty, "Default conflict on \(id)")
        }
    }

    @Test func overridesPersistAcrossStoreReloadsAndSupportExplicitUnbind() {
        let defaults = makeIsolatedDefaults()
        let store = AppShortcutStore(defaults: defaults)

        let custom = KeyCombo("b", modifiers: [.command, .shift])
        store.setShortcut(custom, for: .newTab)
        store.setShortcut(nil, for: .goToGroup)

        #expect(store.shortcut(for: .newTab) == custom)
        #expect(store.shortcut(for: .goToGroup) == nil)
        #expect(store.isCustomized(.newTab))
        #expect(store.isCustomized(.goToGroup))
        #expect(store.customizedCount == 2)

        let reloaded = AppShortcutStore(defaults: defaults)
        #expect(reloaded.shortcut(for: .newTab) == custom)
        #expect(reloaded.shortcut(for: .goToGroup) == nil)
        #expect(reloaded.customizedCount == 2)

        reloaded.reset(.newTab)
        #expect(reloaded.shortcut(for: .newTab) == KeyCombo("t", modifiers: [.command]))
        #expect(!reloaded.isCustomized(.newTab))
        #expect(reloaded.customizedCount == 1)

        reloaded.resetAll()
        #expect(reloaded.shortcut(for: .goToGroup) == KeyCombo("k", modifiers: [.command]))
        #expect(reloaded.customizedCount == 0)
    }

    @Test func settingDefaultValueClearsOverride() {
        let store = AppShortcutStore(defaults: makeIsolatedDefaults())
        let custom = KeyCombo("j", modifiers: [.command, .option])
        store.setShortcut(custom, for: .clearToStart)
        #expect(store.isCustomized(.clearToStart))

        store.setShortcut(AppShortcutID.clearToStart.descriptor.defaultShortcut, for: .clearToStart)
        #expect(!store.isCustomized(.clearToStart))
        #expect(store.customizedCount == 0)
    }

    @Test func conflictDetectionFlagsBothActions() {
        let store = AppShortcutStore(defaults: makeIsolatedDefaults())
        let cmdK = KeyCombo("k", modifiers: [.command])

        // Rebind Clear to Start to Cmd+K (already used by Go to Group).
        store.setShortcut(cmdK, for: .clearToStart)

        #expect(store.conflicts(for: .clearToStart) == [.goToGroup])
        #expect(store.conflicts(for: .goToGroup) == [.clearToStart])

        // Searching "cmd+k" surfaces both conflicting bindings.
        let matched = store.filteredSections(matching: "cmd+k").flatMap(\.items).map(\.id)
        #expect(matched.contains(.goToGroup))
        #expect(matched.contains(.clearToStart))
    }

    @Test func reverseKeySearchMatchesTextualAndGlyphQueries() {
        let store = AppShortcutStore(defaults: makeIsolatedDefaults())

        let cmdK = store.filteredSections(matching: "cmd+k").flatMap(\.items).map(\.id)
        #expect(cmdK == [.goToGroup])

        let glyphCmdK = store.filteredSections(matching: "⌘K").flatMap(\.items).map(\.id)
        #expect(glyphCmdK == [.goToGroup])

        let shiftCmdP = store.filteredSections(matching: "shift+cmd+p").flatMap(\.items).map(\.id)
        #expect(shiftCmdP == [.commandPalette])

        let ctrlTab = store.filteredSections(matching: "ctrl+tab").flatMap(\.items).map(\.id)
        #expect(ctrlTab == [.selectNextTab])

        let optCmdLeft = store.filteredSections(matching: "opt+cmd+left").flatMap(\.items).map(\.id)
        #expect(optCmdLeft == [.selectSplitLeft])
    }

    @Test func captureValidatesPrimaryModifiersAndSystemReservedKeys() {
        let validCmdT = keyEvent(characters: "t", keyCode: UInt16(kVK_ANSI_T), modifiers: [.command])
        #expect(KeyCombo.capture(from: validCmdT) == .valid(KeyCombo("t", modifiers: [.command])))

        let bareLetter = keyEvent(characters: "t", keyCode: UInt16(kVK_ANSI_T), modifiers: [])
        if case .rejected = KeyCombo.capture(from: bareLetter) {
            // Expected
        } else {
            Issue.record("Expected bare letter to be rejected")
        }

        let shiftOnlyLetter = keyEvent(characters: "T", keyCode: UInt16(kVK_ANSI_T), modifiers: [.shift])
        if case .rejected = KeyCombo.capture(from: shiftOnlyLetter) {
            // Expected
        } else {
            Issue.record("Expected shift-only letter to be rejected")
        }

        let bareF5 = keyEvent(characters: "", keyCode: UInt16(kVK_F5), modifiers: [])
        #expect(KeyCombo.capture(from: bareF5) == .valid(KeyCombo(.f5, modifiers: [])))

        let cmdQ = keyEvent(characters: "q", keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command])
        if case .rejected(let message) = KeyCombo.capture(from: cmdQ) {
            #expect(message.contains("macOS reserves"))
        } else {
            Issue.record("Expected Cmd+Q to be rejected")
        }
    }

    @Test func recorderHandlesEscapeDeleteAndCapture() {
        let store = AppShortcutStore(defaults: makeIsolatedDefaults())
        let recorder = ShortcutRecorderController()

        recorder.beginRecording(for: .newTab, store: store)
        #expect(store.isRecording)
        #expect(recorder.recordingActionID == .newTab)

        // Escape cancels without changing shortcut.
        let esc = keyEvent(characters: "\u{1B}", keyCode: UInt16(kVK_Escape), modifiers: [])
        #expect(recorder.handleEvent(esc) == nil)
        #expect(!store.isRecording)
        #expect(store.shortcut(for: .newTab) == KeyCombo("t", modifiers: [.command]))

        // Delete clears the shortcut.
        recorder.beginRecording(for: .newTab, store: store)
        let del = keyEvent(characters: "\u{7F}", keyCode: UInt16(kVK_Delete), modifiers: [])
        #expect(recorder.handleEvent(del) == nil)
        #expect(!store.isRecording)
        #expect(store.shortcut(for: .newTab) == nil)

        // Valid combo records and ends recording.
        recorder.beginRecording(for: .newTab, store: store)
        let optCmdN = keyEvent(characters: "n", keyCode: UInt16(kVK_ANSI_N), modifiers: [.command, .option])
        #expect(recorder.handleEvent(optCmdN) == nil)
        #expect(!store.isRecording)
        #expect(store.shortcut(for: .newTab) == KeyCombo("n", modifiers: [.command, .option]))
    }

    @Test func settingsKeyHandlerYieldsToActiveShortcutRecorder() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        let coordinator = SettingsKeyHandler.Coordinator()
        coordinator.window = window
        var closed = false
        var focusedSearch = false
        var recording = true
        coordinator.closeWindow = { _ in closed = true }
        coordinator.focusSearch = { focusedSearch = true }
        coordinator.shouldIgnoreKeys = { recording }
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        let esc = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: UInt16(kVK_Escape)
        )!
        let cmdF = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_F)
        )!

        NSApp.sendEvent(esc)
        NSApp.sendEvent(cmdF)
        #expect(!closed)
        #expect(!focusedSearch)

        recording = false
        NSApp.sendEvent(cmdF)
        #expect(focusedSearch)
    }

    @Test func commandPaletteReflectsCustomizedShortcuts() {
        let defaults = makeIsolatedDefaults()
        let shortcuts = AppShortcutStore(defaults: defaults)
        shortcuts.setShortcut(KeyCombo("b", modifiers: [.command, .shift]), for: .newTab)
        shortcuts.setShortcut(nil, for: .newWindow)

        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let catalog = CommandPaletteCatalog(
            owner: nil,
            manager: manager,
            defaults: defaults,
            shortcuts: shortcuts
        )
        let rows = catalog.commandRows()
        let newTabRow = rows.first { $0.id == "cmd.tab.new" }
        let newWindowRow = rows.first { $0.id == "cmd.window.new" }

        if case .standard(_, _, let accessory) = newTabRow?.style {
            #expect(accessory == .shortcut("⇧⌘B"))
        } else {
            Issue.record("Missing New Tab row")
        }

        if case .standard(_, _, let accessory) = newWindowRow?.style {
            #expect(accessory == .none)
        } else {
            Issue.record("Missing New Window row")
        }
    }

    private func findMenuItem(titled title: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else {
            return nil
        }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for item in menu.items {
            if item.title == title {
                return item
            }
            if let submenu = item.submenu, let found = findMenuItem(titled: title, in: submenu) {
                return found
            }
        }
        return nil
    }

    @Test func mutatingStoreUpdatesLiveSwiftUIMenuItemKeyEquivalent() async throws {
        let store = AppShortcutStore.shared
        let previous = store.shortcut(for: .newTab)
        let wasCustomized = store.isCustomized(.newTab)
        defer {
            if wasCustomized {
                store.setShortcut(previous, for: .newTab)
            } else {
                store.reset(.newTab)
            }
        }

        store.reset(.newTab)
        try await Task.sleep(for: .milliseconds(150))

        let item = try #require(findMenuItem(titled: "New Tab", in: NSApp.mainMenu))
        #expect(item.keyEquivalent.lowercased() == "t")
        #expect(item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == [.command])

        // Rebind to Shift+Cmd+B
        store.setShortcut(KeyCombo("b", modifiers: [.command, .shift]), for: .newTab)
        try await Task.sleep(for: .milliseconds(250))

        let rebound = try #require(findMenuItem(titled: "New Tab", in: NSApp.mainMenu))
        #expect(rebound.keyEquivalent.lowercased() == "b")
        #expect(rebound.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == [.command, .shift])

        // Explicitly unbind
        store.setShortcut(nil, for: .newTab)
        try await Task.sleep(for: .milliseconds(250))

        let unbound = try #require(findMenuItem(titled: "New Tab", in: NSApp.mainMenu))
        #expect(unbound.keyEquivalent.isEmpty)
    }

    @Test func resolveConflictsUnbindsOtherActionsAndPersists() {
        let defaults = makeIsolatedDefaults()
        let store = AppShortcutStore(defaults: defaults)
        let cmdK = KeyCombo("k", modifiers: [.command])

        // Bind both Clear to Start and Split Pane Left to Cmd+K alongside default Go to Group.
        store.setShortcut(cmdK, for: .clearToStart)
        store.setShortcut(cmdK, for: .splitPaneLeft)

        #expect(Set(store.conflicts(for: .clearToStart)) == [.goToGroup, .splitPaneLeft])

        store.resolveConflicts(keeping: .clearToStart)

        #expect(store.shortcut(for: .clearToStart) == cmdK)
        #expect(store.shortcut(for: .goToGroup) == nil)
        #expect(store.shortcut(for: .splitPaneLeft) == nil)
        #expect(store.conflicts(for: .clearToStart).isEmpty)
        #expect(store.isCustomized(.goToGroup))
        // Split Pane Left defaults to nil, so unbinding it clears its override cleanly.
        #expect(!store.isCustomized(.splitPaneLeft))

        let reloaded = AppShortcutStore(defaults: defaults)
        #expect(reloaded.shortcut(for: .clearToStart) == cmdK)
        #expect(reloaded.shortcut(for: .goToGroup) == nil)
        #expect(reloaded.shortcut(for: .splitPaneLeft) == nil)
    }

    @Test func newlyExposedCommandsUpdateLiveMenuItems() async throws {
        let store = AppShortcutStore.shared
        let ids: [AppShortcutID] = [.splitPaneLeft, .splitPaneUp, .renameTab]
        let saved = Dictionary(uniqueKeysWithValues: ids.map { ($0, (store.isCustomized($0), store.shortcut(for: $0))) })
        defer {
            for id in ids {
                if let (wasCustomized, combo) = saved[id], wasCustomized {
                    store.setShortcut(combo, for: id)
                } else {
                    store.reset(id)
                }
            }
        }

        store.setShortcut(KeyCombo("h", modifiers: [.command, .control, .option]), for: .splitPaneLeft)
        store.setShortcut(KeyCombo("k", modifiers: [.command, .control, .option]), for: .splitPaneUp)
        store.setShortcut(KeyCombo("r", modifiers: [.command, .option]), for: .renameTab)
        try await Task.sleep(for: .milliseconds(250))

        let splitLeft = try #require(findMenuItem(titled: "Split Pane Left", in: NSApp.mainMenu))
        #expect(splitLeft.keyEquivalent.lowercased() == "h")
        #expect(splitLeft.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == [.command, .control, .option])

        let splitUp = try #require(findMenuItem(titled: "Split Pane Up", in: NSApp.mainMenu))
        #expect(splitUp.keyEquivalent.lowercased() == "k")
        #expect(splitUp.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == [.command, .control, .option])

        let renameTab = try #require(findMenuItem(titled: "Rename Tab…", in: NSApp.mainMenu))
        #expect(renameTab.keyEquivalent.lowercased() == "r")
        #expect(renameTab.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == [.command, .option])
    }

    @Test func textSearchWithModifierWordsMatchesCommandNames() {
        let store = AppShortcutStore(defaults: makeIsolatedDefaults())

        let commandPalette = store.filteredSections(matching: "command palette").flatMap(\.items).map(\.id)
        #expect(commandPalette.contains(.commandPalette))

        let optionMeta = store.filteredSections(matching: "option as meta").flatMap(\.items).map(\.id)
        #expect(optionMeta == [.optionAsMetaKey])

        let cmdEquals = store.filteredSections(matching: "cmd+=").flatMap(\.items).map(\.id)
        #expect(cmdEquals == [.biggerFont])
    }

    @Test func biggerFontDefaultMatchesRecordedCmdEquals() {
        let store = AppShortcutStore(defaults: makeIsolatedDefaults())
        let cmdEqualsEvent = keyEvent(characters: "=", keyCode: UInt16(kVK_ANSI_Equal), modifiers: [.command])

        #expect(KeyCombo.capture(from: cmdEqualsEvent) == .valid(KeyCombo("=", modifiers: [.command])))
        #expect(AppShortcutID.biggerFont.descriptor.defaultShortcut == KeyCombo("=", modifiers: [.command]))

        store.setShortcut(KeyCombo("b", modifiers: [.command, .option]), for: .biggerFont)
        #expect(store.isCustomized(.biggerFont))

        if case .valid(let captured) = KeyCombo.capture(from: cmdEqualsEvent) {
            store.setShortcut(captured, for: .biggerFont)
        }
        #expect(!store.isCustomized(.biggerFont))
    }

    @Test func paletteNavigationKeysWinOverReboundPanelShortcuts() async throws {
        let store = AppShortcutStore.shared
        let previous = store.shortcut(for: .activity)
        let wasCustomized = store.isCustomized(.activity)
        defer {
            if wasCustomized {
                store.setShortcut(previous, for: .activity)
            } else {
                store.reset(.activity)
            }
        }

        // Rebind Activity to Ctrl+P, which is a built-in palette navigation key.
        store.setShortcut(KeyCombo("p", modifiers: [.control]), for: .activity)
        try await Task.sleep(for: .milliseconds(250))

        // Confirm the live main menu item actually holds Ctrl+P so yielding from
        // performKeyEquivalent would have fired Activity instead of moving selection.
        let activityItem = try #require(findMenuItem(titled: "Activity", in: NSApp.mainMenu))
        #expect(activityItem.keyEquivalent.lowercased() == "p")
        #expect(activityItem.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == [.control])

        let defaults = makeIsolatedDefaults()
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let controller = TerminalWindowController(group: group, manager: manager, defaults: defaults)
        let panel = CommandPalettePanel(defaults: defaults)
        panel.present(for: controller, manager: manager, initialScope: .root)
        defer { panel.dismiss(restoreFocus: false) }

        let ctrlN = keyEvent(characters: "n", keyCode: UInt16(kVK_ANSI_N), modifiers: [.control])
        let ctrlP = keyEvent(characters: "p", keyCode: UInt16(kVK_ANSI_P), modifiers: [.control])

        // Move down first so Ctrl+P has a previous row to move back to.
        #expect(panel.performKeyEquivalent(with: ctrlN))
        let afterDown = panel.activeModel?.selectedIndex

        // performKeyEquivalent must consume Ctrl+P directly and move selection up
        // before AppKit dispatches the key equivalent to NSApp.mainMenu.
        #expect(panel.performKeyEquivalent(with: ctrlP))
        #expect(panel.isVisible)
        #expect(panel.activeModel?.selectedIndex != afterDown)
    }

    @Test func renameTabTemporarilyRevealsHiddenSidebarWithoutMutatingDefaults() {
        let defaults = makeIsolatedDefaults()
        defaults.set("vertical", forKey: ProgramActivityPreferences.tabStyleKey)
        defaults.set("left", forKey: SidebarPreferences.positionKey)
        defaults.set(true, forKey: SidebarPreferences.hiddenKey)

        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let tab = TerminalTab(startsProcesses: false)
        let group = manager.newGroup(tab: tab)
        let controller = TerminalWindowController(group: group, manager: manager, defaults: defaults)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        #expect(controller.isSidebarHidden)
        #expect(controller.sidebar.isHidden)
        #expect(defaults.bool(forKey: SidebarPreferences.hiddenKey))

        controller.renameTab(tab)
        #expect(controller.sidebarTemporarilyRevealed)
        #expect(!controller.isSidebarHidden)
        #expect(!controller.sidebar.isHidden)
        // Stored preference must remain hidden.
        #expect(defaults.bool(forKey: SidebarPreferences.hiddenKey))

        controller.endTemporarySidebarReveal()
        #expect(!controller.sidebarTemporarilyRevealed)
        #expect(controller.isSidebarHidden)
        #expect(controller.sidebar.isHidden)
        #expect(defaults.bool(forKey: SidebarPreferences.hiddenKey))
    }

    @Test func oneUndecodableOverrideDoesNotDiscardOtherSavedOverrides() throws {
        let defaults = makeIsolatedDefaults()
        let seedStore = AppShortcutStore(defaults: defaults)
        let customNewTab = KeyCombo("b", modifiers: [.command, .shift])
        seedStore.setShortcut(customNewTab, for: .newTab)

        // Inject a corrupted sibling entry alongside the valid serialized override.
        let rawData = try #require(defaults.data(forKey: AppShortcutStore.overridesDefaultsKey))
        var json = try #require(JSONSerialization.jsonObject(with: rawData) as? [String: Any])
        json["goToGroup"] = ["corrupted": 42]
        let mutatedData = try JSONSerialization.data(withJSONObject: json)
        defaults.set(mutatedData, forKey: AppShortcutStore.overridesDefaultsKey)

        let reloaded = AppShortcutStore(defaults: defaults)
        #expect(reloaded.shortcut(for: .newTab) == customNewTab)
        #expect(reloaded.isCustomized(.newTab))
        #expect(reloaded.shortcut(for: .goToGroup) == AppShortcutID.goToGroup.descriptor.defaultShortcut)
    }

    @Test func recorderStopsOnOutsideMouseDownAndFirstResponderChange() throws {
        let store = AppShortcutStore(defaults: makeIsolatedDefaults())
        let recorder = ShortcutRecorderController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = try #require(window.contentView)
        let pillView = NSView(frame: NSRect(x: 260, y: 120, width: 152, height: 26))
        let filterField = NSTextField(frame: NSRect(x: 20, y: 240, width: 220, height: 24))
        contentView.addSubview(pillView)
        contentView.addSubview(filterField)

        // Clicking inside the active recorder pill keeps recording alive so its toggle/clear buttons work.
        recorder.beginRecording(for: .newTab, store: store, in: window)
        recorder.setActiveRecorderView(pillView)
        let insideClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 300, y: 132),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        #expect(recorder.handleEvent(insideClick) != nil)
        #expect(recorder.recordingActionID == .newTab)
        #expect(store.isRecording)

        // Clicking outside the pill (e.g., on the filter field) ends recording and lets the click pass through.
        let outsideClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 40, y: 250),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))
        #expect(recorder.handleEvent(outsideClick) != nil)
        #expect(recorder.recordingActionID == nil)
        #expect(!store.isRecording)

        // Delete is no longer swallowed and does not clear New Tab.
        let deleteEvent = keyEvent(characters: "\u{7F}", keyCode: 51, modifiers: [])
        #expect(recorder.handleEvent(deleteEvent) != nil)
        #expect(store.shortcut(for: .newTab) == AppShortcutID.newTab.descriptor.defaultShortcut)

        // Changing first responder (e.g., focusing the filter field) also stops recording.
        recorder.beginRecording(for: .newTab, store: store, in: window)
        recorder.setActiveRecorderView(pillView)
        #expect(recorder.recordingActionID == .newTab)
        #expect(window.makeFirstResponder(filterField))
        #expect(recorder.recordingActionID == nil)
        #expect(!store.isRecording)

        // Starting recording while the filter field already has focus resigns text focus cleanly.
        recorder.beginRecording(for: .newTab, store: store, in: window)
        #expect(!(window.firstResponder is NSText))
        #expect(recorder.recordingActionID == .newTab)
        recorder.stopRecording()
    }

    private func keyLayoutData(sourceID: String) -> Data? {
        guard let sources = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        for source in sources {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                continue
            }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            if id == sourceID, let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
                return Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
            }
        }
        return nil
    }

    private func translate(keyCode: Int, modifiers: NSEvent.ModifierFlags, layoutData: Data) -> String? {
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }
        if modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }
        if modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }
        return layoutData.withUnsafeBytes { rawBuffer -> String? in
            guard let layout = rawBuffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDown),
                carbonModifiers >> 8,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else {
                return nil
            }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    @Test func characterHelperUsesCommandLayerWhenCommandHeldAndBaseLayerOtherwise() throws {
        // Synthetic check covering Command vs non-Command query modifiers directly.
        var queriedModifiers: [NSEvent.ModifierFlags] = []
        let cmdResult = KeyCombo.character(
            modifiers: [.command, .shift, .option],
            charactersApplying: { mods in
                queriedModifiers.append(mods)
                return mods == [.command] ? "p" : "l"
            }
        )
        #expect(cmdResult == "p")
        #expect(queriedModifiers == [[.command]])

        queriedModifiers.removeAll()
        let ctrlResult = KeyCombo.character(
            modifiers: [.control, .shift],
            charactersApplying: { mods in
                queriedModifiers.append(mods)
                return mods == [] ? "l" : "p"
            }
        )
        #expect(ctrlResult == "l")
        #expect(queriedModifiers == [[]])

        // Real macOS keyboard layouts: Dvorak-QWERTY ⌘, Russian, and US.
        if let dvorakCmd = keyLayoutData(sourceID: "com.apple.keylayout.DVORAK-QWERTYCMD") {
            let cmdP = KeyCombo.character(
                modifiers: [.command],
                charactersApplying: { translate(keyCode: kVK_ANSI_P, modifiers: $0, layoutData: dvorakCmd) }
            )
            let shiftCmdP = KeyCombo.character(
                modifiers: [.command, .shift],
                charactersApplying: { translate(keyCode: kVK_ANSI_P, modifiers: $0, layoutData: dvorakCmd) }
            )
            let ctrlP = KeyCombo.character(
                modifiers: [.control],
                charactersApplying: { translate(keyCode: kVK_ANSI_P, modifiers: $0, layoutData: dvorakCmd) }
            )
            #expect(cmdP == "p")
            #expect(shiftCmdP == "p")
            #expect(ctrlP == "l")
        }

        if let russian = keyLayoutData(sourceID: "com.apple.keylayout.Russian") {
            let cmdP = KeyCombo.character(
                modifiers: [.command],
                charactersApplying: { translate(keyCode: kVK_ANSI_P, modifiers: $0, layoutData: russian) }
            )
            let shiftCmdBracket = KeyCombo.character(
                modifiers: [.command, .shift],
                charactersApplying: { translate(keyCode: kVK_ANSI_LeftBracket, modifiers: $0, layoutData: russian) }
            )
            let ctrlP = KeyCombo.character(
                modifiers: [.control],
                charactersApplying: { translate(keyCode: kVK_ANSI_P, modifiers: $0, layoutData: russian) }
            )
            #expect(cmdP == "p")
            #expect(shiftCmdBracket == "[")
            #expect(ctrlP == "з")
        }

        if let us = keyLayoutData(sourceID: "com.apple.keylayout.US") {
            let shiftCmdBracket = KeyCombo.character(
                modifiers: [.command, .shift],
                charactersApplying: { translate(keyCode: kVK_ANSI_LeftBracket, modifiers: $0, layoutData: us) }
            )
            let optCmdP = KeyCombo.character(
                modifiers: [.command, .option],
                charactersApplying: { translate(keyCode: kVK_ANSI_P, modifiers: $0, layoutData: us) }
            )
            #expect(shiftCmdBracket == "[")
            #expect(optCmdP == "p")
        }

        // Verify live NSEvent capture and matches(_:) agree on Shift+Cmd+[ and Control+K.
        let shiftCmdBracketEvent = keyEvent(
            characters: "{",
            keyCode: UInt16(kVK_ANSI_LeftBracket),
            modifiers: [.command, .shift]
        )
        let expectedBracket = KeyCombo("[", modifiers: [.command, .shift])
        #expect(KeyCombo.capture(from: shiftCmdBracketEvent) == .valid(expectedBracket))
        #expect(expectedBracket.matches(shiftCmdBracketEvent))
    }

    @Test func captureRejectsMenuReservedCombosWithOwnerNameAndAllowsCommandDigits() {
        let pasteEvent = keyEvent(characters: "v", keyCode: UInt16(kVK_ANSI_V), modifiers: [.command])
        #expect(KeyCombo.capture(from: pasteEvent) == .rejected("⌘V is used by Paste."))

        let copyEvent = keyEvent(characters: "c", keyCode: UInt16(kVK_ANSI_C), modifiers: [.command])
        #expect(KeyCombo.capture(from: copyEvent) == .rejected("⌘C is used by Copy."))

        let cutEvent = keyEvent(characters: "x", keyCode: UInt16(kVK_ANSI_X), modifiers: [.command])
        #expect(KeyCombo.capture(from: cutEvent) == .rejected("⌘X is used by Cut."))

        let selectAllEvent = keyEvent(characters: "a", keyCode: UInt16(kVK_ANSI_A), modifiers: [.command])
        #expect(KeyCombo.capture(from: selectAllEvent) == .rejected("⌘A is used by Select All."))

        let undoEvent = keyEvent(characters: "z", keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command])
        #expect(KeyCombo.capture(from: undoEvent) == .rejected("⌘Z is used by Undo."))

        let redoEvent = keyEvent(characters: "Z", keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command, .shift])
        #expect(KeyCombo.capture(from: redoEvent) == .rejected("⇧⌘Z is used by Redo."))

        let fullScreenEvent = keyEvent(characters: "f", keyCode: UInt16(kVK_ANSI_F), modifiers: [.command, .control])
        #expect(KeyCombo.capture(from: fullScreenEvent) == .rejected("⌃⌘F is used by Enter Full Screen."))

        let emojiEvent = keyEvent(characters: " ", keyCode: UInt16(kVK_Space), modifiers: [.command, .control])
        #expect(KeyCombo.capture(from: emojiEvent) == .rejected("⌃⌘Space is used by Emoji & Symbols."))

        let helpEvent = keyEvent(characters: "?", keyCode: UInt16(kVK_ANSI_Slash), modifiers: [.command, .shift])
        #expect(KeyCombo.capture(from: helpEvent) == .rejected("⇧⌘/ is used by Help."))

        let sidebarEvent = keyEvent(characters: "s", keyCode: UInt16(kVK_ANSI_S), modifiers: [.command, .option])
        #expect(KeyCombo.capture(from: sidebarEvent) == .rejected("⌥⌘S is used by Toggle Sidebar."))

        // ⌘1–⌘9 are intentionally allowed so users may bind them.
        let digitKeyCodes = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
            kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
        ]
        for (index, keyCode) in digitKeyCodes.enumerated() {
            let digit = String(index + 1)
            let event = keyEvent(characters: digit, keyCode: UInt16(keyCode), modifiers: [.command])
            #expect(KeyCombo.capture(from: event) == .valid(KeyCombo(digit, modifiers: [.command])))
        }
    }

    @Test func bindingCommandDigitOmitsMatchingSelectTabMenuShortcut() async throws {
        let store = AppShortcutStore.shared
        let previous = store.shortcut(for: .newTab)
        let wasCustomized = store.isCustomized(.newTab)
        defer {
            if wasCustomized {
                store.setShortcut(previous, for: .newTab)
            } else {
                store.reset(.newTab)
            }
        }

        store.reset(.newTab)
        try await Task.sleep(for: .milliseconds(150))

        let tab1Before = try #require(findMenuItem(titled: "Select Tab 1", in: NSApp.mainMenu))
        #expect(tab1Before.keyEquivalent == "1")
        #expect(tab1Before.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == [.command])

        // Binding New Tab to ⌘1 drops ⌘1 from Select Tab 1 while leaving Select Tab 2 intact.
        store.setShortcut(KeyCombo("1", modifiers: [.command]), for: .newTab)
        try await Task.sleep(for: .milliseconds(250))

        let tab1Claimed = try #require(findMenuItem(titled: "Select Tab 1", in: NSApp.mainMenu))
        #expect(tab1Claimed.keyEquivalent.isEmpty)

        let tab2Untouched = try #require(findMenuItem(titled: "Select Tab 2", in: NSApp.mainMenu))
        #expect(tab2Untouched.keyEquivalent == "2")

        let newTabItem = try #require(findMenuItem(titled: "New Tab", in: NSApp.mainMenu))
        #expect(newTabItem.keyEquivalent == "1")
        #expect(newTabItem.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == [.command])

        // Resetting New Tab restores ⌘1 on Select Tab 1.
        store.reset(.newTab)
        try await Task.sleep(for: .milliseconds(250))

        let tab1Restored = try #require(findMenuItem(titled: "Select Tab 1", in: NSApp.mainMenu))
        #expect(tab1Restored.keyEquivalent == "1")
    }

    @Test func allBuiltMainMenuKeyEquivalentsAreCatalogDrivenOrReserved() throws {
        let store = AppShortcutStore.shared
        let catalogCombos = Set(AppShortcutCatalog.all.compactMap { store.shortcut(for: $0.id) })
        let selectTabCombos = Set((1...9).map { KeyCombo(String($0), modifiers: [.command]) })

        func keyFromMenuItem(_ item: NSMenuItem) -> ShortcutKey? {
            guard let scalar = item.keyEquivalent.unicodeScalars.first else {
                return nil
            }
            switch Int(scalar.value) {
            case 0x0D:
                return .special(.returnKey)
            case 0x09:
                return .special(.tab)
            case 0x20:
                return .special(.space)
            case NSUpArrowFunctionKey:
                return .special(.upArrow)
            case NSDownArrowFunctionKey:
                return .special(.downArrow)
            case NSLeftArrowFunctionKey:
                return .special(.leftArrow)
            case NSRightArrowFunctionKey:
                return .special(.rightArrow)
            case NSPageUpFunctionKey:
                return .special(.pageUp)
            case NSPageDownFunctionKey:
                return .special(.pageDown)
            default:
                if CharacterSet.controlCharacters.contains(scalar) || (scalar.value >= 0xF700 && scalar.value <= 0xF8FF) {
                    return nil
                }
                return .character(item.keyEquivalent.lowercased())
            }
        }

        var uncategorized: [String] = []
        func walk(_ menu: NSMenu, path: [String]) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items {
                let currentPath = path + [item.title]
                if !item.keyEquivalent.isEmpty,
                   !item.keyEquivalentModifierMask.contains(.function)
                {
                    let mods = ShortcutModifiers(nsModifierFlags: item.keyEquivalentModifierMask)
                    if mods.hasPrimaryModifier, let key = keyFromMenuItem(item) {
                        let combo = KeyCombo(key, modifiers: mods)
                        let accountedFor = catalogCombos.contains(combo)
                            || KeyCombo.systemReserved.contains(combo)
                            || KeyCombo.menuReserved[combo] != nil
                            || selectTabCombos.contains(combo)
                        if !accountedFor {
                            uncategorized.append("\(currentPath.joined(separator: " > ")) (\(combo.displayString))")
                        }
                    }
                }
                if let submenu = item.submenu {
                    walk(submenu, path: currentPath)
                }
            }
        }

        let mainMenu = try #require(NSApp.mainMenu)
        walk(mainMenu, path: [])
        #expect(uncategorized.isEmpty, "Unaccounted menu shortcuts: \(uncategorized)")
    }

    @Test func corruptTopLevelOverridesBlobIsBackedUpBeforeOverwrite() {
        let defaults = makeIsolatedDefaults()
        let corruptBlob = Data("{not valid json".utf8)
        defaults.set(corruptBlob, forKey: AppShortcutStore.overridesDefaultsKey)

        // Loading a wholly unreadable blob falls back to defaults without touching the stored bytes.
        let store = AppShortcutStore(defaults: defaults)
        #expect(store.customizedCount == 0)
        #expect(defaults.data(forKey: AppShortcutStore.overridesDefaultsKey) == corruptBlob)
        #expect(defaults.data(forKey: AppShortcutStore.corruptOverridesBackupKey) == nil)

        // Making a subsequent edit archives the corrupt blob before overwriting overridesDefaultsKey.
        let custom = KeyCombo("b", modifiers: [.command, .shift])
        store.setShortcut(custom, for: .newTab)
        #expect(defaults.data(forKey: AppShortcutStore.corruptOverridesBackupKey) == corruptBlob)

        let reloaded = AppShortcutStore(defaults: defaults)
        #expect(reloaded.shortcut(for: .newTab) == custom)
    }

    @Test func chromeTooltipsAndGroupSwitcherKeycapTrackCustomizedShortcuts() {
        let store = AppShortcutStore.shared
        let tracked: [AppShortcutID] = [.toggleSidebar, .goToGroup, .newGroup]
        let saved: [(AppShortcutID, KeyCombo?, Bool)] = tracked.map {
            ($0, store.shortcut(for: $0), store.isCustomized($0))
        }
        defer {
            for (id, combo, wasCustomized) in saved {
                if wasCustomized {
                    store.setShortcut(combo, for: id)
                } else {
                    store.reset(id)
                }
            }
        }

        let header = ContentHeaderView(frame: .zero)
        let paneControls = PaneWindowControlsView(frame: .zero)
        let sidebar = SidebarTabBarView(frame: .zero)
        let tabBar = HorizontalTabBarView(frame: .zero)

        #expect(header.toggle.toolTip == "Toggle Sidebar (⌘/)")
        #expect(paneControls.toggle.toolTip == "Toggle Sidebar (⌘/)")
        #expect(tabBar.groupButton.toolTip == "Go to Group (⌘K)")

        // Rebind Toggle Sidebar and Go to Group; tooltips update live via notification.
        store.setShortcut(KeyCombo("b", modifiers: [.command, .option]), for: .toggleSidebar)
        store.setShortcut(KeyCombo("j", modifiers: [.command]), for: .goToGroup)

        #expect(header.toggle.toolTip == "Toggle Sidebar (⌥⌘B)")
        #expect(paneControls.toggle.toolTip == "Toggle Sidebar (⌥⌘B)")
        #expect(tabBar.groupButton.toolTip == "Go to Group (⌘J)")
        #expect(sidebar.subviews.compactMap { $0 as? NSButton }.contains { $0.toolTip == "Toggle Sidebar (⌥⌘B)" })

        // Unbinding drops the parenthetical shortcut cleanly.
        store.setShortcut(nil, for: .goToGroup)
        #expect(tabBar.groupButton.toolTip == "Go to Group")

        // GroupSwitcherModel uses the supplied New Group keycap (including empty when unbound).
        store.setShortcut(KeyCombo("g", modifiers: [.command, .option]), for: .newGroup)
        let reboundModel = GroupSwitcherModel(
            groups: [],
            filter: "",
            newGroupKeycap: store.displayString(for: .newGroup) ?? ""
        )
        #expect(reboundModel.rows.first(where: { $0.action == .newGroup(nil) })?.keycap == "⌥⌘G")

        store.setShortcut(nil, for: .newGroup)
        let unboundModel = GroupSwitcherModel(
            groups: [],
            filter: "",
            newGroupKeycap: store.displayString(for: .newGroup) ?? ""
        )
        #expect(unboundModel.rows.first(where: { $0.action == .newGroup(nil) })?.keycap == "")
    }

    @Test func shortcutsSettingsExposesToolbarMoreMenu() async throws {
        SettingsNavigator.shared.show(.general)
        try await Task.sleep(for: .milliseconds(250))
        SettingsNavigator.shared.show(.shortcuts)
        try await Task.sleep(for: .milliseconds(350))

        let settingsWindow = try #require(NSApp.windows.first { $0.title == "Shortcuts" && $0.isVisible })
        let toolbar = try #require(settingsWindow.toolbar)
        let moreItem = try #require(toolbar.items.first { $0.label == "More" })
        #expect(moreItem.isVisible)
        let menuTitles = moreItem.menuFormRepresentation?.submenu?.items.map(\.title) ?? []
        #expect(menuTitles.contains("Reset All…"))
    }
}
