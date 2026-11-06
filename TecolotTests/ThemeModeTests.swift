import Foundation
import Testing
@testable import Tecolot

struct ThemeModeTests {
    private func profile(fromJSON json: String) throws -> TerminalProfile {
        try JSONDecoder().decode(TerminalProfile.self, from: Data(json.utf8))
    }

    @Test func legacyProfileUsesItsThemeInBothModes() throws {
        let profile = try profile(fromJSON: #"{"name": "Old", "themeName": "Dracula"}"#)
        #expect(profile.lightThemeName == "Dracula")
        #expect(profile.darkThemeName == "Dracula")
    }

    @Test func profileWithoutThemeUsesTheModeDefaults() throws {
        let profile = try profile(fromJSON: #"{"name": "Empty"}"#)
        #expect(profile.lightThemeName == TerminalProfile.defaultThemeName(isDark: false))
        #expect(profile.darkThemeName == TerminalProfile.defaultThemeName(isDark: true))
    }

    @Test func encodingKeepsBothSlotsAndTheLegacyKey() throws {
        var profile = TerminalProfile(name: "Both")
        profile.setThemeName("Nord", isDark: true)
        profile.setThemeName("Alabaster", isDark: false)
        let data = try JSONEncoder().encode(profile)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["themeName"] as? String == "Alabaster")
        #expect(object["darkThemeName"] as? String == "Nord")

        let decoded = try JSONDecoder().decode(TerminalProfile.self, from: data)
        #expect(decoded.themeName(isDark: false) == "Alabaster")
        #expect(decoded.themeName(isDark: true) == "Nord")
    }

    @Test func replaceThemeNameChangesOnlyMatchingSlots() {
        var profile = TerminalProfile(name: "Slots")
        profile.setThemeName("Mine", isDark: true)
        let changed = profile.replaceThemeName("Mine") { isDark in
            TerminalProfile.defaultThemeName(isDark: isDark)
        }
        #expect(changed)
        #expect(profile.darkThemeName == TerminalProfile.defaultThemeName(isDark: true))
        #expect(profile.lightThemeName == TerminalProfile.defaultThemeName(isDark: false))
        #expect(!profile.replaceThemeName("Absent") { _ in "Other" })
    }

    // MARK: Groups

    private func theme(_ name: String, builtIn: Bool = true) -> TerminalTheme {
        var theme = TerminalTheme.fallback
        theme.name = name
        theme.isBuiltIn = builtIn
        return theme
    }

    @Test func groupsAreCustomDefaultFavorites() {
        let themes = [
            theme("Zeta", builtIn: false), theme("Alpha", builtIn: false),
            theme("SwiftTerm"), theme("Nord"), theme("Dracula"), theme("Other")
        ]
        let groups = ThemeModeGroups.groups(
            themes: themes,
            favorites: ["Nord", "Dracula", "SwiftTerm", "Alpha"],
            defaultName: "SwiftTerm",
            activeName: "Nord"
        )
        #expect(groups.map(\.title) == ["Custom", "Default", "Favorites"])
        #expect(groups[0].themes.map(\.name) == ["Alpha", "Zeta"])
        #expect(groups[1].themes.map(\.name) == ["SwiftTerm"])
        // The default theme and custom themes are not repeated in Favorites.
        #expect(groups[2].themes.map(\.name) == ["Dracula", "Nord"])
    }

    @Test func activeThemeOutsideTheGroupsIsShownFirstInFavorites() {
        let themes = [theme("SwiftTerm"), theme("Nord"), theme("Other")]
        let groups = ThemeModeGroups.groups(
            themes: themes,
            favorites: ["Nord"],
            defaultName: "SwiftTerm",
            activeName: "Other"
        )
        #expect(groups.map(\.title) == ["Default", "Favorites"])
        #expect(groups[1].themes.map(\.name) == ["Other", "Nord"])
    }

    // MARK: Profile store

    @MainActor
    @Test func storeReplacesThemeNameInAllProfiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-mode-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = try ProfileStore(directory: directory)
        var second = TerminalProfile(name: "Second")
        second.setThemeName("Mine", isDark: false)
        try profiles.add(second)
        var first = profiles.defaultProfile
        first.setThemeName("Mine", isDark: true)
        try profiles.update(first)

        try profiles.replaceThemeName("Mine") { _ in "Renamed" }

        #expect(profiles.defaultProfile.darkThemeName == "Renamed")
        #expect(profiles.profile(named: "Second")?.lightThemeName == "Renamed")
        #expect(profiles.defaultProfile.lightThemeName == TerminalProfile.defaultThemeName(isDark: false))
    }
}
