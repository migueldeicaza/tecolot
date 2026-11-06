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

// MARK: Theme library

@MainActor
struct ThemeLibraryTests {
    private struct Fixture {
        let directory: URL
        let themes: ThemeStore
        let profiles: ProfileStore
        var library: ThemeLibrary { ThemeLibrary(themes: themes, profiles: profiles) }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-library-tests-\(UUID().uuidString)")
        let themes = ThemeStore(directory: directory.appendingPathComponent("Themes"))
        let profiles = try ProfileStore(directory: directory)
        return Fixture(directory: directory, themes: themes, profiles: profiles)
    }

    private func userTheme(_ name: String, from base: String, in themes: ThemeStore) -> TerminalTheme {
        var theme = themes.theme(named: base)
        theme.name = name
        theme.isBuiltIn = false
        theme.baseThemeName = base
        return theme
    }

    @Test func renameChangesProfilesInBothModes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let mine = userTheme("Mine", from: "Dracula", in: fixture.themes)
        try fixture.library.save(mine, replacing: nil)
        var profile = fixture.profiles.defaultProfile
        profile.setThemeName("Mine", isDark: true)
        profile.setThemeName("Mine", isDark: false)
        try fixture.profiles.update(profile)

        var renamed = mine
        renamed.name = "Mine2"
        try fixture.library.save(renamed, replacing: "Mine")

        #expect(fixture.profiles.defaultProfile.darkThemeName == "Mine2")
        #expect(fixture.profiles.defaultProfile.lightThemeName == "Mine2")
        #expect(fixture.themes.themes.contains { $0.name == "Mine2" })
        #expect(!fixture.themes.themes.contains { $0.name == "Mine" })
    }

    @Test func failedRenameKeepsProfiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let mine = userTheme("Mine", from: "Dracula", in: fixture.themes)
        try fixture.library.save(mine, replacing: nil)
        try fixture.library.save(userTheme("Other!", from: "Dracula", in: fixture.themes), replacing: nil)
        var profile = fixture.profiles.defaultProfile
        profile.setThemeName("Mine", isDark: true)
        try fixture.profiles.update(profile)

        // "Other?" has the same file name as "Other!": the save fails.
        var renamed = mine
        renamed.name = "Other?"
        #expect(throws: ProfilesError.duplicateThemeName) {
            try fixture.library.save(renamed, replacing: "Mine")
        }
        #expect(fixture.profiles.defaultProfile.darkThemeName == "Mine")
        #expect(fixture.themes.themes.contains { $0.name == "Mine" })
        #expect(fixture.themes.themes.contains { $0.name == "Other!" })
    }

    @Test func deleteUsesBaseOnlyForTheSameMode() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let base = fixture.themes.theme(named: "Dracula")
        #expect(base.isDark)
        try fixture.library.save(userTheme("Mine", from: "Dracula", in: fixture.themes), replacing: nil)
        var profile = fixture.profiles.defaultProfile
        profile.setThemeName("Mine", isDark: true)
        profile.setThemeName("Mine", isDark: false)
        try fixture.profiles.update(profile)

        try fixture.library.delete(named: "Mine")

        #expect(fixture.profiles.defaultProfile.darkThemeName == "Dracula")
        #expect(fixture.profiles.defaultProfile.lightThemeName == TerminalProfile.defaultThemeName(isDark: false))
        #expect(!fixture.themes.themes.contains { $0.name == "Mine" })
    }

    @Test func similarFileNameIsAConflict() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.library.save(userTheme("Mine!", from: "Dracula", in: fixture.themes), replacing: nil)

        #expect(fixture.themes.conflictingTheme(forName: "Mine?")?.name == "Mine!")
        #expect(fixture.themes.conflictingTheme(forName: "mine!")?.name == "Mine!")
        #expect(fixture.themes.conflictingTheme(forName: "Mine?", exceptUserTheme: "Mine!") == nil)
        #expect(fixture.themes.conflictingTheme(forName: "Yours") == nil)
    }

    @Test func darkThemeComesBackAfterAnOlderVersionWritesTheProfile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var profile = fixture.profiles.defaultProfile
        profile.setThemeName("Alabaster", isDark: false)
        profile.setThemeName("Nord", isDark: true)
        try fixture.profiles.update(profile)

        // An older version writes the profile without "darkThemeName".
        let url = ProfileStore.url(for: profile, in: fixture.directory.appendingPathComponent("Profiles"))
        let data = try Data(contentsOf: url)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stored = try #require(object["profile"] as? [String: Any])
        stored.removeValue(forKey: "darkThemeName")
        object["profile"] = stored
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        fixture.profiles.reload()
        #expect(fixture.profiles.defaultProfile.darkThemeName == "Nord")

        // The older version also changed the theme: use its theme.
        stored["themeName"] = "Dracula"
        object["profile"] = stored
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        fixture.profiles.reload()
        #expect(fixture.profiles.defaultProfile.lightThemeName == "Dracula")
        #expect(fixture.profiles.defaultProfile.darkThemeName == "Dracula")
    }

    @Test func hexFieldParsesWithAndWithoutHash() {
        #expect(HexColorWell.parse("FF0000") == ProfileColor(hex: "#ff0000"))
        #expect(HexColorWell.parse(" #00ff00 ") == ProfileColor(hex: "#00ff00"))
        #expect(HexColorWell.parse("FF00") == nil)
    }
}
