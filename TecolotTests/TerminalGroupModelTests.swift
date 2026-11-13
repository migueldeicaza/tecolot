import AppKit
import Testing
@testable import Tecolot

@MainActor
struct GroupNameGeneratorTests {
    @Test func namesHaveOriginalLowercaseWordPairsAndAreUnique() {
        let generator = GroupNameGenerator()
        var names: [String] = []
        for _ in 0..<300 {
            let name = generator.generate(existingNames: names)
            #expect(name.range(of: "^[a-z]+-[a-z]+(-[0-9]+)?$", options: .regularExpression) != nil)
            #expect(!names.contains(name))
            names.append(name)
        }
    }

    @Test func originalWordListsAreLargeUniqueAndLowercaseASCII() {
        for words in [GroupNameGenerator.adjectives, GroupNameGenerator.nouns] {
            #expect(words.count >= 48)
            #expect(Set(words).count == words.count)
            #expect(words.allSatisfy {
                $0.range(of: "^[a-z]+$", options: .regularExpression) != nil
            })
        }
    }

    @Test func collisionsAreCaseInsensitiveAndFallbackUsesTheFirstFreeSuffix() {
        let generator = GroupNameGenerator(candidate: {
            "Brisk-Quill"
        })
        #expect(generator.generate(existingNames: ["BRISK-QUILL", "brisk-quill-2", "Brisk-Quill-3"]) == "brisk-quill-4")
        #expect(generator.generate(existingNames: []) == "brisk-quill")
    }

    @Test func emptyRenameGeneratesAFreshName() {
        let group = TerminalTabGroup(name: "brisk-quill", tabs: [])
        group.rename("Custom name", among: [group])
        #expect(group.isNameCustom)
        #expect(group.name == "Custom name")
        group.rename(" \n ", among: [group], generator: GroupNameGenerator(candidate: {
            "nimble-folio"
        }))
        #expect(group.name == "nimble-folio")
        #expect(!group.isNameCustom)
    }
}

@MainActor
private final class ModelWindow: TerminalGroupWindow {
    let id = UUID()
    var group: TerminalTabGroup
    var activations = 0
    var shows = 0
    var closed = false
    init(_ group: TerminalTabGroup) {
        self.group = group
    }
    func show(_ group: TerminalTabGroup) {
        self.group = group
        shows += 1
    }
    func activate() {
        activations += 1
    }
    func closeWindow() {
        closed = true
    }
}

@MainActor
struct TerminalWindowManagerTests {
    private func manager() -> TerminalWindowManager {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            ModelWindow($0)
        }
        return manager
    }
    private func tab() -> TerminalTab {
        TerminalTab(startsProcesses: false)
    }
    private func check(_ manager: TerminalWindowManager, sourceLocation: SourceLocation = #_sourceLocation) {
        let shown = manager.windows.map {
            $0.group.id
        }
        #expect(Set(shown).count == shown.count, sourceLocation: sourceLocation)
        #expect(manager.windows.allSatisfy { window in
            manager.window(showing: window.group)?.id == window.id
        }, sourceLocation: sourceLocation)
        let tabs = manager.groups.flatMap {
            $0.tabs.map(\.id)
        }
        #expect(Set(tabs).count == tabs.count, sourceLocation: sourceLocation)
        #expect(manager.groups.allSatisfy {
            !$0.tabs.isEmpty && $0.selectedTab != nil
        }, sourceLocation: sourceLocation)
    }

    @Test func showSwitchAndNavigationEnforceTheSingleViewRule() throws {
        let manager = manager()
        let first = manager.newGroup(tab: tab())
        let second = manager.newGroup(tab: tab())
        let a = try #require(manager.openWindow(group: first) as? ModelWindow)
        let b = try #require(manager.openWindow(group: second) as? ModelWindow)
        #expect(!manager.show(second, in: a))
        #expect(a.group === first)
        let chosen = tab()
        manager.addTab(chosen, to: second)
        manager.navigate(to: second, tab: chosen, in: a)
        #expect(b.activations == 1)
        #expect(second.selection == chosen.id)
        #expect(a.group === first)
        check(manager)
        let third = manager.newGroup(in: a, tab: tab())
        #expect(manager.backgroundGroups.contains {
            $0 === first
        })
        check(manager)
        manager.navigate(to: first, in: a)
        #expect(a.group === first)
        #expect(manager.backgroundGroups.contains {
            $0 === third
        })
        check(manager)
    }

    @Test func changesRefreshOnlyTheAffectedWindow() throws {
        let manager = manager()
        let firstTab = tab()
        let first = manager.newGroup(tab: firstTab)
        let a = try #require(manager.openWindow(group: first) as? ModelWindow)
        let second = manager.newGroup(tab: tab())
        let b = try #require(manager.openWindow(group: second) as? ModelWindow)
        let background = manager.newGroup(tab: tab())
        manager.rename(background, to: "Background")
        #expect(a.shows == 0)
        #expect(b.shows == 0)
        manager.addTab(tab(), to: first)
        #expect(a.shows == 1)
        #expect(b.shows == 0)
        manager.select(firstTab, in: first)
        #expect(a.shows == 2)
        manager.rename(first, to: "Foreground")
        #expect(a.shows == 3)
        manager.closeWindow(b)
        #expect(a.shows == 3)
        manager.navigate(to: first, in: a)
        #expect(a.shows == 3)
        #expect(b.shows == 0)
        check(manager)
    }

    @Test func movesMergeAndClosesPreserveOwnership() throws {
        let manager = manager()
        let firstTab = tab()
        let first = manager.newGroup(tab: firstTab)
        let a = manager.openWindow(group: first)
        let second = manager.newGroup(tab: tab())
        let b = manager.openWindow(group: second)
        let moved = tab()
        manager.addTab(moved, to: first)
        manager.move(moved, from: first, to: second)
        #expect(!first.tabs.contains {
            $0 === moved
        })
        #expect(second.tabs.last === moved)
        check(manager)
        let c = try #require(manager.moveToNewWindow(moved, from: second))
        #expect(c.group.tabs.first === moved)
        check(manager)
        // Moving the sole tab removes its old group, keeping the tab alive.
        manager.move(firstTab, from: first, to: second)
        #expect(!manager.groups.contains {
            $0 === first
        })
        #expect(!manager.windows.contains {
            $0.id == a.id
        })
        check(manager)
        manager.mergeAllWindows(into: b)
        #expect(manager.windows.count == 1)
        #expect(manager.groups.count == 1)
        #expect(b.group.tabs.contains {
            $0 === moved
        })
        check(manager)
        manager.closeTab(moved, in: second)
        check(manager)
        manager.closeGroup(second)
        #expect(manager.groups.isEmpty)
        #expect(manager.windows.isEmpty)
    }

    @Test func lastTabFallsBackToMostRecentlyShownBackgroundGroup() {
        let manager = manager()
        let oldest = manager.newGroup(tab: tab())
        let recent = manager.newGroup(tab: tab())
        oldest.lastShownAt = Date(timeIntervalSince1970: 1)
        recent.lastShownAt = Date(timeIntervalSince1970: 2)
        let current = manager.newGroup(tab: tab())
        let window = manager.openWindow(group: current)
        if let tab = current.tabs.first {
            manager.closeTab(tab, in: current)
        }
        #expect(window.group === recent)
        #expect(manager.groups.count == 2)
        check(manager)
        manager.closeGroup(recent)
        #expect(window.group === oldest)
        manager.closeGroup(oldest)
        #expect(manager.windows.isEmpty)
        #expect(manager.groups.isEmpty)
    }

    @Test func closingTheLastWindowKeepsEveryGroupAndReopenReusesTheRecentOne() throws {
        let manager = manager()
        let background = manager.newGroup(tab: tab())
        background.lastShownAt = .distantPast
        let shown = manager.newGroup(tab: tab())
        let window = try #require(manager.openWindow(group: shown) as? ModelWindow)
        manager.closeWindow(window)
        #expect(window.closed)
        #expect(manager.groups.count == 2)
        #expect(manager.windows.isEmpty)
        #expect(manager.mostRecentBackgroundGroup === shown)
        manager.navigate(to: shown)
        #expect(manager.windows.count == 1)
        #expect(manager.windows.first?.group === shown)
        check(manager)
    }

    @Test func lastTabClosesTheWindowWhenOnlyNeverShownGroupsRemain() throws {
        let manager = manager()
        let saved = RestoreTab(root: .pane(RestorePane(id: UUID(), kind: .local)))
        let dormant = TerminalTab(
            dormant: RestoreStore.launchSpec(for: RestoredTab(tab: saved, panes: [:])),
            startsProcesses: false
        )
        let neverShown = manager.newGroup(tab: dormant)
        let currentTab = tab()
        let current = manager.newGroup(tab: currentTab)
        let window = try #require(manager.openWindow(group: current) as? ModelWindow)
        manager.closeTab(currentTab, in: current)
        #expect(window.closed && manager.windows.isEmpty)
        #expect(manager.groups.count == 1 && manager.groups[0] === neverShown)
        #expect(neverShown.lastShownAt == nil && dormant.isDormant)
        manager.closeGroup(neverShown)
    }

    @Test func movingToBackgroundAndAddingAnExistingTabNeverDuplicatesIt() {
        let manager = manager()
        let moved = tab()
        let source = manager.newGroup(tab: moved)
        _ = manager.openWindow(group: source)
        let target = manager.newGroup(tab: tab())
        manager.addTab(moved, to: target)
        #expect(manager.windows.isEmpty)
        #expect(manager.backgroundGroups.contains {
            $0 === target
        })
        #expect(!manager.groups.contains {
            $0 === source
        })
        manager.addTab(moved, to: target)
        #expect(target.tabs.count == 2)
        check(manager)
        manager.closeGroup(target)
    }
}

@MainActor
struct TerminalGroupRegistryTests {
    @Test func registryIncludesBackgroundPanesAndFollowsAMovingTab() throws {
        let registry = TerminalSessionRegistry()
        let manager = TerminalWindowManager(registry: registry)
        manager.makeWindow = {
            ModelWindow($0)
        }
        let tab = TerminalTab(startsProcesses: false)
        let first = manager.newGroup(tab: tab)
        let pane = try #require(tab.workspace.focusedController)
        tab.workspace.split(pane, direction: .right)
        let second = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        #expect(registry.controllers(in: first).count == 2)
        #expect(registry.allControllers.count == 3)
        manager.move(tab, from: first, to: second)
        #expect(registry.controllers(in: first).isEmpty)
        #expect(registry.controllers(in: second).count == 3)
        #expect(Set(registry.allControllers.map(\.id)).count == 3)
        manager.closeGroup(second)
        #expect(registry.controllers(in: second).isEmpty)
        #expect(registry.allControllers.isEmpty)
    }

    @Test func backgroundProcessExitClosesItsOwnTabThenItsGroup() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        manager.makeWindow = {
            ModelWindow($0)
        }
        let first = TerminalTab(startsProcesses: false)
        let second = TerminalTab(startsProcesses: false)
        let group = manager.newGroup(tab: first)
        manager.addTab(second, to: group)
        let window = manager.openWindow(group: group)
        manager.closeWindow(window)
        let a = try #require(first.workspace.focusedController)
        let b = try #require(second.workspace.focusedController)
        var profile = a.profile
        profile.whenShellExits = .closeWindow
        a.applyProfile(profile)
        b.applyProfile(profile)
        a.processTerminated(source: nil, exitCode: 0)
        #expect(group.tabs.count == 1)
        #expect(group.tabs.first === second)
        b.processTerminated(source: nil, exitCode: 0)
        #expect(manager.groups.isEmpty)
    }

    @Test func shownTabsStayMountedAndMovingAHostChangesWindowLookups() throws {
        let registry = TerminalSessionRegistry()
        let manager = TerminalWindowManager(registry: registry)
        let firstTab = TerminalTab(startsProcesses: false)
        let first = manager.newGroup(tab: firstTab)
        let a = try #require(manager.openWindow(group: first) as? TerminalWindowController)
        let secondTab = TerminalTab(startsProcesses: false)
        manager.addTab(secondTab, to: first)
        let second = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let b = try #require(manager.openWindow(group: second) as? TerminalWindowController)
        defer { for window in manager.windows {
            manager.closeWindow(window)
        } }
        #expect(firstTab.hostView.window === a.window)
        #expect(firstTab.hostView.isHidden)
        #expect(secondTab.hostView.window === a.window)
        #expect(!secondTab.hostView.isHidden)
        #expect(registry.controllers(for: a.window).count == 2)
        #expect(registry.controller(for: a.window) === secondTab.workspace.focusedController)
        a.window?.makeFirstResponder(firstTab.workspace.focusedController?.surface)
        manager.move(firstTab, from: first, to: second)
        #expect(firstTab.hostView.window === b.window)
        #expect(a.window?.firstResponder === secondTab.workspace.focusedController?.surface)
        #expect(registry.controllers(for: a.window).count == 1)
        #expect(registry.controllers(for: b.window).count == 2)
        #expect(registry.controller(for: b.window) === firstTab.workspace.focusedController)
        manager.closeWindow(b)
        #expect(firstTab.hostView.window == nil)
        #expect(registry.allControllers.count == 3)
        try #require(firstTab.workspace.focusedController).noteOutputActivity()
        #expect(firstTab.workspace.focusedController?.hasActivity == true)
    }
    @Test func closingAGroupMovesKeyboardFocusToItsFallbackTab() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let first = manager.newGroup(tab: TerminalTab(startsProcesses: false))
        let owner = try #require(manager.openWindow(group: first) as? TerminalWindowController)
        let second = manager.newGroup(in: owner, tab: TerminalTab(startsProcesses: false))
        owner.window?.makeFirstResponder(second.selectedTab?.workspace.focusedController?.surface)
        manager.closeGroup(second)
        #expect(owner.group === first)
        #expect(owner.window?.firstResponder === first.selectedTab?.workspace.focusedController?.surface)
        manager.closeGroup(first)
    }

    @Test func captureSavesShownAndDormantGroupsAndSelection() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let firstTab = TerminalTab(startsProcesses: false)
        firstTab.customName = "Build"
        let group = manager.newGroup(tab: firstTab)
        let window = manager.openWindow(group: group)
        let secondTab = TerminalTab(startsProcesses: false)
        manager.addTab(secondTab, to: group)
        manager.select(firstTab, in: group)
        let description = RestoreTab(root: .pane(RestorePane(id: UUID(), kind: .local)))
        let dormant = TerminalTab(dormant: RestoreStore.launchSpec(for: RestoredTab(tab: description, panes: [:])))
        let background = manager.newGroup(tab: dormant)
        defer {
            manager.closeWindow(window)
            manager.closeGroup(group)
            manager.closeGroup(background)
        }
        let store = RestoreStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let (state, _, _) = store.capture(limit: 0, manager: manager)
        #expect(state.windows.count == 1)
        let saved = try #require(state.groups.first)
        #expect(state.groups.count == 2)
        #expect(state.windows.first?.groupID == group.id)
        #expect(background.tabs.first?.isDormant == true)
        #expect(saved.tabs.count == 2)
        #expect(saved.selectedTabIndex == 0)
        #expect(saved.tabs.first?.name == "Build")
        #expect(saved.tabs.first?.root.panes.first?.id == firstTab.workspace.focusedController?.id)
        #expect(saved.tabs.allSatisfy {
            $0.fileURL == nil
        })
    }

}

@MainActor
struct GroupClosePolicyTests {
    @Test func onlyNonIdleLocalPanesCount() {
        let states: [TerminalClosePolicy.PaneState] = [
            .init(persistent: false, running: true, childProcesses: 0),
            .init(persistent: false, running: true, childProcesses: 1),
            .init(persistent: true, running: true, childProcesses: 2),
            .init(persistent: false, running: false, childProcesses: 1)
        ]
        #expect(TerminalClosePolicy.runningTaskCount(states: states) == 1)
    }

    @Test func groupConfirmationAndQuitSeeTasksInBackgroundGroups() async throws {
        let registry = TerminalSessionRegistry()
        let manager = TerminalWindowManager(registry: registry)
        manager.makeWindow = {
            ModelWindow($0)
        }
        let tab = TerminalTab(startsProcesses: false)
        let group = manager.newGroup(tab: tab)
        let pane = try #require(tab.workspace.focusedController)
        let terminal = try #require(pane.makeTerminalView() as? AppTerminalView)
        defer { pane.terminate() }
        #expect(!GroupCloseConfirmation.requiresConfirmation(group))
        terminal.startProcess(executable: "/bin/sh", args: ["-c", "sleep 30 & wait"])
        let deadline = ContinuousClock.now + .seconds(3)
        while TerminalClosePolicy.runningTaskCount(in: registry.allControllers) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let window = manager.openWindow(group: group)
        manager.closeWindow(window)
        #expect(GroupCloseConfirmation.requiresConfirmation(group))
        #expect(TerminalClosePolicy.runningTaskCount(in: registry.allControllers) == 1)
        #expect(manager.backgroundGroups.count == 1)
    }
}
