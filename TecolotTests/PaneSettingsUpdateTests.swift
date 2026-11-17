import AppKit
import Combine
import Testing
@testable import Tecolot

@MainActor
private final class SettingsReviewWindow: TerminalGroupWindow {
    let id = UUID()
    var group: TerminalTabGroup
    var shows = 0
    init(_ group: TerminalTabGroup) {
        self.group = group
    }
    func show(_ group: TerminalTabGroup) {
        self.group = group
        shows += 1
    }
    func activate() {}
    func closeWindow() {}
}

@MainActor
private final class SettingsReviewFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaneSettings-\(UUID())")
    let profiles: ProfileStore
    let themes: ThemeStore
    let registry = TerminalSessionRegistry()
    let manager: TerminalWindowManager
    let appearance = PassthroughSubject<Void, Never>()
    var isDark = false
    var observer: PaneSettingsObserver?
    var appliedProfiles: [UUID] = []
    var appliedThemes: [UUID] = []

    init() throws {
        profiles = try ProfileStore(directory: directory)
        themes = ThemeStore(directory: directory.appendingPathComponent("Themes"))
        manager = TerminalWindowManager(registry: registry)
        manager.makeWindow = {
            SettingsReviewWindow($0)
        }
    }

    func profile(_ name: String, theme: String = "Review A") throws -> TerminalProfile {
        var profile = TerminalProfile(name: name)
        profile.lightThemeName = theme
        profile.darkThemeName = "Review B"
        try profiles.add(profile)
        return profile
    }

    func theme(_ name: String) throws -> TerminalTheme {
        var theme = TerminalTheme.fallback
        theme.name = name
        theme.isBuiltIn = false
        try themes.saveUserTheme(theme)
        return themes.theme(named: name)
    }

    func group(_ profile: TerminalProfile, shown: Bool = true) -> TerminalTabGroup {
        let tab = TerminalTab(startsProcesses: false)
        tab.workspace.focusedController?.applyProfile(profile)
        let group = manager.newGroup(tab: tab)
        if shown {
            _ = manager.openWindow(group: group)
        }
        return group
    }

    func observe() {
        observer = PaneSettingsObserver(
            profiles: profiles, themes: themes,
            appearanceChanges: appearance.eraseToAnyPublisher(), isDark: { [unowned self] in
                self.isDark
            },
            registry: registry, manager: manager,
            applyProfile: { [unowned self] controller, profile in
                self.appliedProfiles.append(controller.id)
                controller.applyProfile(profile)
            },
            applyThemeColors: { [unowned self] in
                self.appliedThemes.append($0.id)
            }
        )
        for window in manager.windows {
            (window as? SettingsReviewWindow)?.shows = 0
        }
    }

    func shows(_ group: TerminalTabGroup) -> Int {
        (manager.window(showing: group) as? SettingsReviewWindow)?.shows ?? 0
    }

    func cleanup() {
        observer = nil
        for group in manager.groups {
            manager.closeGroup(group)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
struct PaneSettingsUpdateTests {
    private func nextTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @Test func profileBurstAppliesFinalValueOnceAndOnlyRemountsAffectedWindows() async throws {
        let f = try SettingsReviewFixture()
        defer { f.cleanup() }
        var profile = try f.profile("Used")
        let first = f.group(profile)
        let background = f.group(profile, shown: false)
        let other = f.group(try f.profile("Other"))
        f.observe()
        profile.fontSize = 17
        try f.profiles.update(profile)
        profile.fontSize = 19
        try f.profiles.update(profile)
        #expect(f.appliedProfiles.isEmpty)
        await nextTurn()
        let used = [first, background].compactMap {
            $0.selectedTab?.workspace.focusedController
        }
        #expect(Set(f.appliedProfiles) == Set(used.map(\.id)))
        #expect(f.appliedProfiles.count == 2)
        #expect(used.allSatisfy {
            $0.profile.fontSize == 19
        })
        #expect(f.appliedThemes.isEmpty)
        #expect(f.shows(first) == 1)
        #expect(f.shows(other) == 0)
        profile.fontSize = 21
        try f.profiles.update(profile)
        await nextTurn()
        #expect(f.appliedProfiles.count == 4)
        #expect(f.shows(first) == 2)
    }

    @Test func unusedProfileAndFavoriteChangesDoNoPaneOrWindowWork() async throws {
        let f = try SettingsReviewFixture()
        defer { f.cleanup() }
        let group = f.group(try f.profile("Used"))
        var unused = try f.profile("Unused")
        f.observe()
        unused.fontSize = 30
        try f.profiles.update(unused)
        try f.profiles.setDefault(unused.id)
        try f.themes.toggleFavorite(TerminalTheme.fallback.name)
        await nextTurn()
        #expect(f.appliedProfiles.isEmpty)
        #expect(f.appliedThemes.isEmpty)
        #expect(f.shows(group) == 0)
    }

    @Test func themeBurstOnlyTouchesEffectiveThemeIncludingOverridesAndBackgroundGroups() async throws {
        let f = try SettingsReviewFixture()
        defer { f.cleanup() }
        _ = try f.theme("Review A")
        var theme = try f.theme("Review B")
        let profile = try f.profile("Shared")
        let first = f.group(profile)
        let overridden = f.group(profile)
        let background = f.group(profile, shown: false)
        let overriddenPane = try #require(overridden.selectedTab?.workspace.focusedController)
        overriddenPane.themeOverride = theme.name
        let backgroundPane = try #require(background.selectedTab?.workspace.focusedController)
        backgroundPane.themeOverride = theme.name
        f.observe()
        theme.cursor = theme.foreground
        try f.themes.saveUserTheme(theme, replacing: theme.name)
        theme.cursor = theme.background
        try f.themes.saveUserTheme(theme, replacing: theme.name)
        await nextTurn()
        #expect(Set(f.appliedThemes) == Set([overriddenPane.id, backgroundPane.id]))
        #expect(f.appliedThemes.count == 2)
        #expect(f.appliedProfiles.isEmpty)
        #expect(f.shows(first) == 0)
        #expect(f.shows(overridden) == 1)
        // Deletion changes the effective value to the fallback and must also apply.
        try f.themes.deleteUserTheme(named: theme.name)
        await nextTurn()
        #expect(f.appliedThemes.count == 4)
        #expect(f.shows(overridden) == 2)
    }

    @Test func hiddenTabThemeChangesDoNotRemountTheSelectedTab() async throws {
        let f = try SettingsReviewFixture()
        defer { f.cleanup() }
        _ = try f.theme("Review A")
        var theme = try f.theme("Review B")
        let group = f.group(try f.profile("Selected"))
        let selected = group.selection
        let hidden = TerminalTab(startsProcesses: false)
        let pane = try #require(hidden.workspace.focusedController)
        pane.applyProfile(try f.profile("Hidden", theme: "Review B"))
        f.manager.addTab(hidden, to: group)
        f.manager.select(try #require(group.tabs.first {
            $0.id == selected
        }), in: group)
        f.observe()
        theme.cursor = theme.foreground
        try f.themes.saveUserTheme(theme, replacing: theme.name)
        await nextTurn()
        #expect(f.appliedThemes == [pane.id])
        #expect(f.shows(group) == 0)
    }

    @Test func combinedProfileThemeAndAppearanceEmissionsMakeOnePassAfterWillSet() async throws {
        let f = try SettingsReviewFixture()
        defer { f.cleanup() }
        var theme = try f.theme("Review B")
        var profile = try f.profile("First")
        let first = f.group(profile)
        let second = f.group(try f.profile("Second"))
        f.observe()
        profile.fontSize = 20
        try f.profiles.update(profile)
        theme.cursor = theme.foreground
        try f.themes.saveUserTheme(theme, replacing: theme.name)
        f.appearance.send() // Like @Published, emit before assigning the new value.
        f.isDark = true
        f.appearance.send()
        await nextTurn()
        #expect(f.appliedProfiles == [first.selectedTab?.workspace.focusedController?.id].compactMap {
            $0
        })
        #expect(f.appliedThemes == [second.selectedTab?.workspace.focusedController?.id].compactMap {
            $0
        })
        #expect(f.shows(first) == 1)
        #expect(f.shows(second) == 1)
        #expect(first.selectedTab?.workspace.focusedController?.profile.fontSize == 20)
    }

    @Test func queuedUpdateDoesNotRetainObserverOrRunAfterTeardown() async throws {
        let f = try SettingsReviewFixture()
        defer { f.cleanup() }
        let group = f.group(try f.profile("Used"))
        f.observe()
        weak var released = f.observer
        f.appearance.send()
        f.isDark = true
        f.observer = nil
        #expect(released == nil)
        await nextTurn()
        #expect(f.appliedProfiles.isEmpty)
        #expect(f.appliedThemes.isEmpty)
        #expect(f.shows(group) == 0)
    }
}
