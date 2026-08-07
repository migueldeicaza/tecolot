import Foundation
import Testing
@testable import TerminalProfilesKit

final class ProfileColorTests {
    @Test func hexRoundTrip () throws {
        let color = try #require (ProfileColor (hex: "#282a36"))
        #expect (color.hexString == "#282a36")
        let data = try JSONEncoder ().encode (color)
        #expect (String (data: data, encoding: .utf8) == "\"#282a36\"")
        let decoded = try JSONDecoder ().decode (ProfileColor.self, from: data)
        #expect (decoded == color)
    }

    @Test func sixteenBitEncodesLosslessly () throws {
        let color = ProfileColor (red: 0x1234, green: 0x5678, blue: 0x9abc)
        let decoded = try JSONDecoder ().decode (ProfileColor.self,
                                                 from: try JSONEncoder ().encode (color))
        #expect (decoded == color)
    }

    @Test func rejectsInvalid () {
        #expect (ProfileColor (hex: "nope") == nil)
    }
}

final class ThemeTests {
    @Test func slugging () {
        #expect (TerminalTheme.slug (for: "Rose Pine Dawn") == "rose-pine-dawn")
        #expect (TerminalTheme.slug (for: "Dark+") == "dark")
        #expect (TerminalTheme.slug (for: "Black Metal (Bathory)") == "black-metal-bathory")
    }

    @Test func fallbackIsValid () {
        #expect (TerminalTheme.fallback.isValid)
        #expect (TerminalTheme.fallback.isDark)
    }

    @Test func bundledThemesAllValid () {
        let themes = ThemeStore.loadBundledThemes ()
        #expect (themes.count >= 100)
        var seen = Set<String> ()
        for theme in themes {
            #expect (theme.isValid, "theme \(theme.name) does not have 16 ANSI colors")
            #expect (!seen.contains (theme.id), "duplicate slug \(theme.id)")
            seen.insert (theme.id)
        }
    }

    @Test func themeCodableRoundTrip () throws {
        let themes = ThemeStore.loadBundledThemes ()
        let first = try #require (themes.first)
        let decoded = try JSONDecoder ().decode (TerminalTheme.self,
                                                 from: try JSONEncoder ().encode (first))
        #expect (decoded == first)
    }
}

@MainActor
final class ThemeStoreTests {
    private func makeStore () throws -> (ThemeStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent ("theme-store-tests-\(UUID ().uuidString)")
        try FileManager.default.createDirectory (at: dir, withIntermediateDirectories: true)
        return (ThemeStore (directory: dir), dir)
    }

    @Test func lookupAndFallback () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        #expect (store.theme (named: "Dracula").name == "Dracula")
        #expect (store.theme (named: "No Such Theme").name == TerminalTheme.fallback.name)
    }

    @Test func userThemeShadowsAndDeletes () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        var custom = store.theme (named: "Dracula")
        custom.name = "My Dracula"
        custom.isBuiltIn = false
        try store.saveUserTheme (custom)
        #expect (store.theme (named: "My Dracula").isBuiltIn == false)

        #expect (throws: ProfilesError.themeIsBuiltIn) {
            try store.deleteUserTheme (named: "Dracula")
        }
        try store.deleteUserTheme (named: "My Dracula")
        #expect (store.theme (named: "My Dracula").name == TerminalTheme.fallback.name)
    }

    @Test func favoritesPersist () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        store.toggleFavorite ("Dracula")
        #expect (store.isFavorite ("Dracula"))
        let reloaded = ThemeStore (directory: dir)
        #expect (reloaded.isFavorite ("Dracula"))
    }
}

@MainActor
final class ProfileStoreTests {
    private func makeStore () throws -> (ProfileStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent ("profile-store-tests-\(UUID ().uuidString)")
        return (try ProfileStore (directory: dir), dir)
    }

    @Test func seedsDefaultProfile () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        #expect (store.profiles.count == 1)
        #expect (store.defaultProfile.name == "Default")
    }

    @Test func crudAndPersistence () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }

        var extra = TerminalProfile (name: "Servers")
        extra.themeName = "Nord"
        extra.fontSize = 14
        try store.add (extra)
        #expect (store.profiles.count == 2)

        #expect (throws: ProfilesError.duplicateName) {
            try store.add (TerminalProfile (name: "Servers"))
        }

        let copy = try store.duplicate (extra.id)
        #expect (copy.name == "Servers copy")
        try store.rename (copy.id, to: "Workers")
        try store.setDefault (extra.id)

        // A fresh store sees everything
        let reloaded = try ProfileStore (directory: dir)
        #expect (reloaded.profiles.count == 3)
        #expect (reloaded.defaultProfile.name == "Servers")
        #expect (reloaded.profile (named: "Workers") != nil)
        #expect (reloaded.profile (named: "Servers")?.themeName == "Nord")

        try store.delete (copy.id)
        #expect (store.profiles.count == 2)
    }

    @Test func cannotDeleteLastProfile () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        #expect (throws: ProfilesError.cannotDeleteLastProfile) {
            try store.delete (store.defaultProfileID)
        }
    }

    @Test func importExportRoundTrip () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        let file = dir.appendingPathComponent ("export.json")
        try store.exportProfile (store.defaultProfileID, to: file)
        let imported = try store.importProfile (from: file)
        #expect (imported.id != store.defaultProfileID)
        #expect (imported.name == "Default copy")
        #expect (store.profiles.count == 2)
    }

    @Test func unlimitedScrollbackSurvivesRoundTrip () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        var profile = store.defaultProfile
        profile.scrollbackLines = nil
        try store.update (profile)
        let reloaded = try ProfileStore (directory: dir)
        #expect (reloaded.defaultProfile.scrollbackLines == nil)
    }

    @Test func forwardCompatibleDecoding () throws {
        // A document with unknown keys and missing fields still loads
        let json = """
        {"version": 99, "profile": {"name": "Old", "someFutureField": true}}
        """
        let document = try JSONDecoder ().decode (ProfileDocument.self, from: json.data (using: .utf8)!)
        #expect (document.profile.name == "Old")
        #expect (document.profile.fontSize == TerminalProfile.standardValues.fontSize)
        #expect (document.profile.shell == .loginShell)
    }
}

final class LaunchParametersTests {
    @Test func loginShellUsesLoginIdiom () {
        let profile = TerminalProfile (name: "Test")
        let params = ProfileApplier.launchParameters (for: profile)
        #expect (params.execName?.hasPrefix ("-") == true)
        #expect (params.environment.contains ("TERM=xterm-256color"))
    }

    @Test func termNameFlowsIntoEnvironment () {
        var profile = TerminalProfile (name: "Test")
        profile.termName = "xterm-direct"
        let params = ProfileApplier.launchParameters (for: profile)
        #expect (params.environment.contains ("TERM=xterm-direct"))
    }

    @Test func runInShellWrapsCommand () {
        var profile = TerminalProfile (name: "Test")
        profile.shell = .command ("htop -d 10", runInShell: true)
        let params = ProfileApplier.launchParameters (for: profile)
        #expect (params.args == ["-lc", "htop -d 10"])
    }

    @Test func directCommandSplitsArgv () {
        var profile = TerminalProfile (name: "Test")
        profile.shell = .command ("/usr/bin/ssh example.org", runInShell: false)
        let params = ProfileApplier.launchParameters (for: profile)
        #expect (params.executable == "/usr/bin/ssh")
        #expect (params.args == ["example.org"])
    }

    @Test func initialDirectoryIsRespected () {
        let profile = TerminalProfile (name: "Test")
        let params = ProfileApplier.launchParameters (for: profile, initialDirectory: "/tmp")
        #expect (params.currentDirectory == "/tmp")
    }

    @Test func terminalOptionsMapping () {
        var profile = TerminalProfile (name: "Test")
        profile.columns = 120
        profile.rows = 40
        profile.scrollbackLines = 5000
        profile.cursorStyle = .steadyBar
        let options = ProfileApplier.terminalOptions (for: profile)
        #expect (options.cols == 120)
        #expect (options.rows == 40)
        #expect (options.scrollback == 5000)
        #expect (options.cursorStyle == .steadyBar)
        #expect (options.termName == "xterm-256color")
    }
}
