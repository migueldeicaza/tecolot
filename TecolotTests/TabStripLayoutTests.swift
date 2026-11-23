import AppKit
import Testing
@testable import Tecolot

struct TabStripLayoutTests {
    @Test func workedWidthsFromSectionFour() {
        for available in [865.0, 857.0] {
            for fill in [false, true] {
                #expect(TabStripLayout(available: available, count: 1, fill: fill).cellWidth == 242)
                for count in [2, 3, 4, 10, 20] {
                    let layout = TabStripLayout(available: available, count: count, fill: fill)
                    let expected = min(fill ? .infinity : 241, max(65, available / Double(count))) + 1
                    #expect(abs(layout.cellWidth - expected) < 0.001)
                    #expect(layout.overflows == (count == 20))
                }
            }
        }
        #expect(abs(TabStripLayout(available: 857, count: 2, fill: true).cellWidth - 429.5) < 0.01)
        #expect(abs(TabStripLayout(available: 857, count: 3, fill: true).cellWidth - 286.6667) < 0.01)
        #expect(abs(TabStripLayout(available: 865, count: 4, fill: false).cellWidth - 217.25) < 0.01)
        #expect(TabStripLayout(available: 865, count: 20, fill: false).cellWidth == 66)
        #expect(!TabStripLayout(available: 865, count: 1, fill: true).showsSurface)
        #expect(TabStripLayout(available: 865, count: 1, fill: false).showsSurface)
        #expect(TabStripLayout(available: 0, count: 0, fill: false).contentWidth == 0)
    }

    @Test func overflowVisibilityAndRevealAtBothEnds() {
        let layout = TabStripLayout(available: 857, count: 20, fill: false)
        #expect(layout.contentWidth == 1301)
        #expect(layout.visibleIndices(offset: 0) == 0..<14)
        #expect(layout.visibleIndices(offset: 444) == 6..<20)
        #expect(layout.offset(revealing: 19, from: 0) == 444)
        #expect(layout.offset(revealing: 0, from: 444) == 0)
        #expect(layout.offset(revealing: 5, from: 100) == 100)
        let narrow = TabStripLayout(available: 20, count: 2, fill: false)
        #expect(narrow.overflows)
        #expect(narrow.offset(revealing: 1, from: 0) == 111)
        #expect(TabStripLayout(available: 0, count: 2, fill: false).visibleIndices(offset: 0).isEmpty)
    }

    @Test func reorderBoundariesAreMeasuredBeforeRemovingTheSource() {
        #expect(TabStripLayout.reorderIndex(source: 1, insertion: 1, count: 5) == 1)
        #expect(TabStripLayout.reorderIndex(source: 1, insertion: 2, count: 5) == 1)
        #expect(TabStripLayout.reorderIndex(source: 1, insertion: 5, count: 5) == 4)
        #expect(TabStripLayout.reorderIndex(source: 4, insertion: 0, count: 5) == 0)
        #expect(TabStripLayout.reorderIndex(source: 0, insertion: 99, count: 1) == 0)
        let layout = TabStripLayout(available: 865, count: 20, fill: false)
        #expect(layout.insertionIndex(at: -20) == 0)
        #expect(layout.insertionIndex(at: 32) == 0)
        #expect(layout.insertionIndex(at: 33) == 1)
        #expect(layout.insertionIndex(at: 10000) == 20)
    }

    @Test func pasteboardPayloadRoundTripRejectsInvalidOrIncompleteData() throws {
        let original = TabDropPayload(groupID: UUID(), tabID: UUID())
        #expect(TabDropPayload.typeName == "com.tirania.tecolot.tab")
        #expect(TabDropPayload(data: try #require(original.data)) == original)
        #expect(TabDropPayload(data: Data("{}".utf8)) == nil)
        #expect(TabDropPayload(data: Data("not json".utf8)) == nil)
    }

    @Test func reduceMotionNeverChoosesMovingLayout() {
        #expect(TabAnimationPolicy.layout(reduceMotion: false, style: "natural") == .moving)
        #expect(TabAnimationPolicy.layout(reduceMotion: false, style: "snappy") == .moving)
        #expect(TabAnimationPolicy.layout(reduceMotion: true, style: "natural") == .crossfade)
        #expect(TabAnimationPolicy.layout(reduceMotion: true, style: "snappy") == .crossfade)
        #expect(TabAnimationPolicy.layout(reduceMotion: true, style: "off") == .immediate)
        #expect(TabAnimationPolicy.layout(reduceMotion: false, style: "off") == .immediate)
    }
}

@MainActor
struct TabIconStackTests {
    @Test func focusHistoryPrecedesCreationOrderAndClosedPanesAreIgnored() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let a = try #require(workspace.focusedController)
        workspace.split(a, direction: .left)
        let b = try #require(workspace.focusedController)
        workspace.split(b, direction: .down)
        let c = try #require(workspace.focusedController)
        workspace.markFocused(a)
        #expect(workspace.focusHistory == [a.id, c.id, b.id])
        let live = workspace.controllers.map(\.id)
        #expect(TerminalTabIconStack.paneIDs(
            creationOrder: workspace.creationOrder,
            focusHistory: workspace.focusHistory,
            liveIDs: live,
            limit: 2
        ) == [a.id, c.id])
        #expect(TerminalTabIconStack.paneIDs(
            creationOrder: [b.id, a.id, c.id],
            focusHistory: [a.id, UUID(), a.id],
            liveIDs: live,
            limit: 5
        ) == [a.id, b.id, c.id])
        #expect(TerminalTabIconStack.paneIDs(creationOrder: live, focusHistory: [], liveIDs: live, limit: 0).isEmpty)
        workspace.close(c)
        #expect(!workspace.focusHistory.contains(c.id))
        workspace.terminateAll()
    }

    @Test func aliasesStayWithinTecolotsSupportedPrograms() {
        for (command, identity) in [
            ("vi", "vim"),
            ("view", "vim"),
            ("vimdiff", "vim"),
            ("emacsclient", "emacs"),
            ("python3", "python"),
            ("ipython", "python"),
            ("python3.14", "python"),
            ("nodejs", "node"),
            ("NVIM", "nvim")
        ] {
            #expect(ProgramGlyphCatalog.entry(forExecutablePath: "/opt/bin/" + command).id == identity)
        }
        for command in ["zsh", "fish", "unrecognized", "inspector", "gitchanges", "UnrealEditor", "npm-loader.js"] {
            #expect(ProgramGlyphCatalog.entry(forExecutablePath: "/bin/" + command) == ProgramGlyphCatalog.terminal)
        }
        #expect(ProgramGlyphCatalog.entries.allSatisfy {
            $0.id == "terminal" || TerminalAppIconResolver.fallbackSymbolName(for: $0.id) != "terminal"
                || TerminalAppIconResolver.brandAssetName(for: $0.id) != nil
                || !TerminalAppIconResolver.bundleIdentifiers(for: $0.id).isEmpty
        })
    }

    nonisolated private static var referenceCatalogURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tab-bar-spec-programs.json")
    }

    @Test(.enabled(
        if: FileManager.default.fileExists(atPath: Self.referenceCatalogURL.path),
        "Optional reference catalog is absent"
    ))
    func unsupportedReferenceIDsCannotEnterTecolotsCatalog() throws {
        struct ReferenceID: Decodable { let id: String }
        // Deliberately decode ids only. Reference names, aliases, colors and
        // artwork are not inputs to the application or its catalog.
        let reference = try JSONDecoder().decode([ReferenceID].self, from: Data(contentsOf: Self.referenceCatalogURL))
        let unsupported = Set(reference.map(\.id).filter {
            $0 != "terminal" && TerminalAppIconResolver.fallbackSymbolName(for: $0) == "terminal"
                && TerminalAppIconResolver.brandAssetName(for: $0) == nil
                && TerminalAppIconResolver.bundleIdentifiers(for: $0).isEmpty
        })
        #expect(Set(ProgramGlyphCatalog.entries.map(\.id)).isDisjoint(with: unsupported))
    }

    @Test func iconDefaultsClampAndColorModesFollowSelection() throws {
        let suite = "TabStripPreferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var prefs = TabStripPreferences(defaults: defaults)
        #expect(prefs.iconCount == 3 && prefs.colorMode == .always && !prefs.fill)
        defaults.set(100, forKey: TabStripPreferences.iconCountKey)
        #expect(TabStripPreferences(defaults: defaults).iconCount == 5)
        defaults.set(-1, forKey: TabStripPreferences.iconCountKey)
        #expect(TabStripPreferences(defaults: defaults).iconCount == 0)
        defaults.set(4, forKey: TabStripPreferences.iconCountKey)
        defaults.set(false, forKey: TabStripPreferences.trackRunningProgramsKey)
        #expect(TabStripPreferences(defaults: defaults).iconCount == 0)
        defaults.set(true, forKey: TabStripPreferences.trackRunningProgramsKey)
        #expect(TabStripPreferences(defaults: defaults).iconCount == 4)
        prefs.colorMode = .activePanes
        #expect(prefs.colorsTile(selected: true, index: 0))
        #expect(!prefs.colorsTile(selected: true, index: 1))
        #expect(!prefs.colorsTile(selected: false, index: 0))
        prefs.colorMode = .activeTabs
        #expect(prefs.colorsTile(selected: true, index: 2))
        #expect(!prefs.colorsTile(selected: false, index: 0))
        prefs.colorMode = .never
        #expect(!prefs.colorsTile(selected: true, index: 0))
    }

    @Test func processInspectionDoesNotRequirePaneCardsOrAWindow() {
        #expect(TabStripPreferences.inspectsProcesses(tracking: true, paneCards: false, iconCount: 3))
        #expect(TabStripPreferences.inspectsProcesses(tracking: true, paneCards: true, iconCount: 0))
        #expect(!TabStripPreferences.inspectsProcesses(tracking: true, paneCards: false, iconCount: 0))
        #expect(!TabStripPreferences.inspectsProcesses(tracking: false, paneCards: true, iconCount: 3))
    }
}

struct GroupSwitcherModelTests {
    private let a = UUID(), b = UUID(), c = UUID()
    private var groups: [GroupSwitcherModel.Group] {
        [
            .init(id: a, name: "Onboarding"),
            .init(id: b, name: "silent-thicket", isCurrent: true),
            .init(id: c, name: "SILENT work", isShownElsewhere: true)
        ]
    }
    @Test func filterPreservesManagerOrderRenumbersKeycapsAndSelectsFirstMatch() {
        let model = GroupSwitcherModel(groups: groups, filter: "SIL")
        #expect(model.initialSelection == 0)
        #expect(model.rows.map(\.keycap) == ["⌘1", "⌘2", "⇧⌘N"])
        #expect(model.rows.map(\.action) == [.group(b), .group(c), .newGroup(nil)])
        #expect(model.rows[1].isShownElsewhere)
        let all = GroupSwitcherModel(groups: groups, filter: "")
        #expect(all.initialSelection == 1)
        #expect(all.rows.suffix(2).map(\.action) == [.remote, .attach])
    }
    @Test func onlyNoMatchesUsesTypedTextAsNewGroupName() {
        let create = GroupSwitcherModel(groups: groups, filter: " zebra ")
        #expect(create.rows.count == 1)
        #expect(create.rows[0].title == "New Group “zebra”")
        #expect(create.rows[0].action == .newGroup("zebra"))
        #expect(GroupSwitcherModel(groups: [], filter: "").rows[0].action == .newGroup(nil))
        #expect(GroupSwitcherModel(groups: groups, filter: "Onboarding").rows.last?.action == .newGroup(nil))
    }
    @Test func onlyFirstNineVisibleGroupsHaveKeycaps() {
        let many = (0..<12).map {
            GroupSwitcherModel.Group(id: UUID(), name: "Group \($0)")
        }
        let model = GroupSwitcherModel(groups: many, filter: "Group")
        #expect(model.rows[8].keycap == "⌘9")
        #expect(model.rows[9].keycap.isEmpty)
        #expect(model.rows[11].keycap.isEmpty)
    }
}
