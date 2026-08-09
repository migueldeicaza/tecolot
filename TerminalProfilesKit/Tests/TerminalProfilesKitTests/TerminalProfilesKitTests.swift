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

    @Test func swiftTermThemeMatchesMacTerminalDefaults () throws {
        let theme = try #require (
            ThemeStore.loadBundledThemes ().first { $0.name == "SwiftTerm" }
        )
        #expect (theme.ansi == TerminalTheme.fallback.ansi)
        #expect (theme.foreground.hexString == "#ffffff")
        #expect (theme.background.hexString == "#282c34")
        #expect (theme.cursor?.hexString == "#30d158")
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

private func fixture(_ name: String, extension fileExtension: String = "json") throws -> Data {
    let directory = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let url = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
    return try Data(contentsOf: url)
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

    @Test func deletionReloadsThemesWhenFavoritePersistenceFails() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-delete-partial-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let issues = PersistenceIssueCenter()
        let store = ThemeStore(directory: dir, issueCenter: issues)
        var custom = store.theme(named: "Dracula")
        custom.name = "Favorite to Delete"
        custom.isBuiltIn = false
        try store.saveUserTheme(custom)
        try store.toggleFavorite(custom.name)

        let favoritesURL = dir.appendingPathComponent("favorites.json")
        try FileManager.default.removeItem(at: favoritesURL)
        try FileManager.default.createDirectory(at: favoritesURL, withIntermediateDirectories: true)

        var deletionFailed = false
        do {
            try store.deleteUserTheme(named: custom.name)
        } catch {
            deletionFailed = true
        }

        #expect(deletionFailed)
        #expect(!store.themes.contains { $0.name == custom.name })
        #expect(issues.issues.contains {
            $0.domain == .themeFavorites && $0.sourceURL.lastPathComponent == "favorites.json"
        })
        #expect(!issues.issues.contains {
            $0.domain == .userThemes && $0.sourceURL.lastPathComponent == "\(custom.id).json"
        })
    }

    @Test func favoritesPersist () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        try store.toggleFavorite ("Dracula")
        #expect (store.isFavorite ("Dracula"))
        let reloaded = ThemeStore (directory: dir)
        #expect (reloaded.isFavorite ("Dracula"))
    }

    @Test func failedFavoritesDocumentStaysReadOnlyUntilRecovery() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-favorites-read-only-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let favoritesURL = dir.appendingPathComponent("favorites.json")
        let original = Data("{broken".utf8)
        try original.write(to: favoritesURL)
        let issues = PersistenceIssueCenter()
        let store = ThemeStore(directory: dir, issueCenter: issues)

        var custom = store.theme(named: "Dracula")
        custom.name = "Protected Theme"
        custom.isBuiltIn = false
        try store.saveUserTheme(custom)

        #expect(throws: PersistenceMutationError.recoveryRequired(.themeFavorites)) {
            try store.toggleFavorite(custom.name)
        }
        #expect(throws: PersistenceMutationError.recoveryRequired(.themeFavorites)) {
            try store.deleteUserTheme(named: custom.name)
        }
        #expect(try Data(contentsOf: favoritesURL) == original)
        #expect(store.themes.contains { $0.name == custom.name })
        #expect(issues.issues.contains {
            $0.domain == .themeFavorites && $0.sourceURL == favoritesURL
        })
    }

    @Test func inPlaceRenameUpdatesTheThemeAndItsFavorite() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var custom = store.theme(named: "Dracula")
        custom.name = "Slug Match+"
        custom.isBuiltIn = false
        try store.saveUserTheme(custom)
        try store.toggleFavorite(custom.name)

        let oldName = custom.name
        let oldID = custom.id
        custom.name = "Slug Match"
        #expect(custom.id == oldID)
        try store.saveUserTheme(custom, replacing: oldName)

        #expect(store.themes.contains { $0.name == custom.name && !$0.isBuiltIn })
        #expect(!store.themes.contains { $0.name == oldName })
        #expect(store.isFavorite(custom.name))
        #expect(!store.isFavorite(oldName))
        let themeFiles = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ).filter {
            $0.pathExtension == "json" && $0.lastPathComponent != "favorites.json"
        }
        #expect(themeFiles.map(\.lastPathComponent) == ["\(custom.id).json"])
    }

    @Test func migratesRawFavoritesOnceAndKeepsOriginalBackup() throws {
        let (store, dir) = try makeStore()
        _ = store
        defer { try? FileManager.default.removeItem(at: dir) }
        let favoritesURL = dir.appendingPathComponent("favorites.json")
        let original = try fixture("favorites-v0")
        try original.write(to: favoritesURL)

        let backupRoot = dir.appendingPathComponent("TestBackups")
        let migrated = ThemeStore(directory: dir, backupDirectory: backupRoot)
        #expect(migrated.favorites == ["Dracula", "Nord"])
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: favoritesURL)
        ) as? [String: Any])
        #expect((object["version"] as? NSNumber)?.intValue == 1)

        let backupURL = PersistenceBackups.backupURL(
            for: favoritesURL,
            domain: .themeFavorites,
            sourceVersion: 0,
            root: backupRoot
        )
        #expect(try Data(contentsOf: backupURL) == original)

        _ = ThemeStore(directory: dir, backupDirectory: backupRoot)
        let backups = try FileManager.default.contentsOfDirectory(
            at: backupURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(backups.count == 1)
    }

    @Test func migratesRawUserThemeAndLoadsValidSiblingWhenOneIsCorrupt() throws {
        let (initialStore, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var theme = initialStore.theme(named: "Dracula")
        theme.name = "Legacy Theme"
        theme.isBuiltIn = false
        let validURL = dir.appendingPathComponent("legacy-theme.json")
        let original = try JSONEncoder().encode(theme)
        try original.write(to: validURL)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))

        let issues = PersistenceIssueCenter()
        let backupRoot = dir.appendingPathComponent("TestBackups")
        let store = ThemeStore(
            directory: dir,
            issueCenter: issues,
            backupDirectory: backupRoot
        )
        #expect(store.theme(named: "Legacy Theme").name == "Legacy Theme")
        #expect(issues.issues.count == 1)
        #expect(issues.issues.first?.sourceURL.lastPathComponent == "broken.json")
        let migratedObject = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: validURL)
        ) as? [String: Any])
        #expect((migratedObject["version"] as? NSNumber)?.intValue == 1)
        let backupURL = PersistenceBackups.backupURL(
            for: validURL,
            domain: .userThemes,
            sourceVersion: 0,
            root: backupRoot
        )
        #expect(try Data(contentsOf: backupURL) == original)
    }

    @Test func importsItermColorsAndAvoidsNameCollisions () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }

        func color (_ red: Double, _ green: Double, _ blue: Double) -> [String: Double] {
            ["Red Component": red, "Green Component": green, "Blue Component": blue]
        }
        var plist: [String: Any] = [
            "Foreground Color": color (0.5, 0.25, 1),
            "Background Color": color (0, 0.75, 0.125),
            "Cursor Color": color (1, 0, 0)
        ]
        for index in 0..<16 {
            plist ["Ansi \(index) Color"] = color (Double (index) / 15, 0.5, 0.25)
        }
        let file = dir.appendingPathComponent ("Dracula.itermcolors")
        let data = try PropertyListSerialization.data (
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write (to: file)

        let imported = try store.importTheme (from: file)
        #expect (imported.name == "Dracula 2")
        #expect (imported.ansi.count == 16)
        #expect (imported.ansi [15] == ProfileColor (red: 65535, green: 32768, blue: 16384))
        #expect (imported.foreground == ProfileColor (red: 32768, green: 16384, blue: 65535))
        #expect (imported.background == ProfileColor (red: 0, green: 49151, blue: 8192))

        let second = try store.importTheme (from: file)
        #expect (second.name == "Dracula 3")
    }

    @Test func importsTerminalThemeJSON () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        var source = store.theme (named: "Dracula")
        source.name = "JSON Import"
        source.isBuiltIn = false
        let file = dir.appendingPathComponent ("theme.json")
        try JSONEncoder ().encode (source).write (to: file)

        let imported = try store.importTheme (from: file)
        #expect (imported.name == "JSON Import")
        #expect (imported.ansi == source.ansi)
        #expect (store.theme (named: "JSON Import").foreground == source.foreground)
    }
}

@MainActor
final class ProfileStoreTests {
    private func makeStore () throws -> (ProfileStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent ("profile-store-tests-\(UUID ().uuidString)")
        return (try ProfileStore (directory: dir), dir)
    }

    @Test func startsWithoutCreatingProfile () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        #expect (store.profiles.isEmpty)
        #expect (store.defaultProfile.name == "Default")
        #expect (store.defaultProfile.themeName == "SwiftTerm")
        #expect (!FileManager.default.fileExists(atPath: dir.appendingPathComponent("store.json").path))
        #expect ((try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("Profiles"),
            includingPropertiesForKeys: nil
        )).isEmpty)
    }

    @Test func crudAndPersistence () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }

        var extra = TerminalProfile (name: "Servers")
        extra.themeName = "Nord"
        extra.fontSize = 14
        try store.add (extra)
        #expect (store.profiles.count == 1)
        #expect (store.defaultProfileID == extra.id)

        #expect (throws: ProfilesError.duplicateName) {
            try store.add (TerminalProfile (name: "Servers"))
        }

        let copy = try store.duplicate (extra.id)
        #expect (copy.name == "Servers copy")
        try store.rename (copy.id, to: "Workers")
        try store.setDefault (extra.id)

        // A fresh store sees everything
        let reloaded = try ProfileStore (directory: dir)
        #expect (reloaded.profiles.count == 2)
        #expect (reloaded.defaultProfile.name == "Servers")
        #expect (reloaded.profile (named: "Workers") != nil)
        #expect (reloaded.profile (named: "Servers")?.themeName == "Nord")

        try store.delete (copy.id)
        #expect (store.profiles.count == 1)
    }

    @Test func cannotDeleteLastProfile () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        let profile = TerminalProfile(name: "Default")
        try store.add(profile)
        #expect (throws: ProfilesError.cannotDeleteLastProfile) {
            try store.delete (profile.id)
        }
    }

    @Test func importExportRoundTrip () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        try store.add(TerminalProfile(name: "Default"))
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
        var profile = TerminalProfile(name: "Default")
        profile.scrollbackLines = nil
        try store.add(profile)
        let reloaded = try ProfileStore (directory: dir)
        #expect (reloaded.defaultProfile.scrollbackLines == nil)
    }

    @Test func keyBindingsSurviveRoundTrip () throws {
        let (store, dir) = try makeStore ()
        defer { try? FileManager.default.removeItem (at: dir) }
        var profile = TerminalProfile(name: "Default")
        profile.keyBindings = [
            TerminalKeyBinding(
                key: "k",
                modifiers: [.command, .shift],
                action: .sendEscapeSequence,
                value: "[1;2A"
            ),
            TerminalKeyBinding(
                key: "pageup",
                modifiers: [.option],
                action: .scrollPageUp
            )
        ]
        try store.add(profile)

        let reloaded = try ProfileStore(directory: dir)
        #expect(reloaded.defaultProfile.keyBindings == profile.keyBindings)
    }

    @Test func repairsDuplicateNamesWithoutDeletingProfiles () throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-store-duplicate-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profilesDirectory = dir.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)

        var recovered = TerminalProfile(name: "Default")
        recovered.fontSize = 21
        let selectedDefault = TerminalProfile(name: "Default")
        try ProfileStore.write(profile: recovered, in: profilesDirectory)
        try ProfileStore.write(profile: selectedDefault, in: profilesDirectory)
        let recoveredURL = ProfileStore.url(for: recovered, in: profilesDirectory)
        let originalRecovered = try Data(contentsOf: recoveredURL)
        let state = """
        {"version":1,"defaultProfileID":"\(selectedDefault.id.uuidString)"}
        """
        try #require(state.data(using: .utf8)).write(to: dir.appendingPathComponent("store.json"))

        let store = try ProfileStore(directory: dir)
        #expect(store.profiles.count == 2)
        #expect(store.defaultProfile.id == selectedDefault.id)
        #expect(store.defaultProfile.name == "Default")
        #expect(store.profile(withID: recovered.id)?.name == "Default copy")
        let backupURL = PersistenceBackups.backupURL(
            for: recoveredURL,
            domain: .profiles,
            sourceVersion: 1,
            root: dir.appendingPathComponent("Backups")
        )
        #expect(try Data(contentsOf: backupURL) == originalRecovered)

        var editable = try #require(store.profile(withID: recovered.id))
        editable.optionAsMetaKey = false
        try store.update(editable)

        let reloaded = try ProfileStore(directory: dir)
        #expect(reloaded.profiles.count == 2)
        #expect(reloaded.profile(withID: recovered.id)?.fontSize == 21)
        #expect(reloaded.profile(withID: recovered.id)?.optionAsMetaKey == false)
    }

    @Test func validV1ProfileUsesDefaultsForFieldsThatAreAbsent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-store-historical-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profilesDirectory = dir.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try fixture("profile-v1-missing-fields").write(
            to: profilesDirectory.appendingPathComponent("historical.json")
        )

        let store = try ProfileStore(directory: dir)
        let profile = try #require(store.profile(named: "Historical Profile"))
        #expect(profile.fontSize == TerminalProfile.standardValues.fontSize)
        #expect(profile.shell == .loginShell)
        #expect(profile.titleComponents == [.activeTitle, .workingDirectory])
    }

    @Test func futureProfileRemainsUntouchedAndIsReported() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-store-future-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profilesDirectory = dir.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        let sourceURL = profilesDirectory.appendingPathComponent("future.json")
        let original = try fixture("profile-v99")
        try original.write(to: sourceURL)
        let issues = PersistenceIssueCenter()

        let store = try ProfileStore(directory: dir, issueCenter: issues)
        #expect(store.profiles.isEmpty)
        #expect(issues.issues.count == 1)
        #expect(issues.issues.first?.kind == .unsupportedVersion)
        #expect(issues.issues.first?.foundVersion == 99)
        #expect(try Data(contentsOf: sourceURL) == original)
    }

    @Test func failedStoreStateCannotBeReplacedBySelectingADefault() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-state-read-only-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profilesDirectory = dir.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(
            at: profilesDirectory,
            withIntermediateDirectories: true
        )
        let profile = TerminalProfile(name: "Recovered Profile")
        try ProfileStore.write(profile: profile, in: profilesDirectory)
        let stateURL = dir.appendingPathComponent("store.json")
        let original = Data("{\"version\":99,\"defaultProfileID\":\"\(profile.id.uuidString)\"}".utf8)
        try original.write(to: stateURL)
        let issues = PersistenceIssueCenter()
        let store = try ProfileStore(directory: dir, issueCenter: issues)

        #expect(throws: PersistenceMutationError.recoveryRequired(.profileStore)) {
            try store.setDefault(profile.id)
        }
        #expect(try Data(contentsOf: stateURL) == original)
        #expect(issues.issues.contains {
            $0.domain == .profileStore && $0.kind == .unsupportedVersion
        })
    }

    @Test func corruptProfileDoesNotHideAValidSibling() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-store-partial-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profilesDirectory = dir.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try fixture("profile-v1-missing-fields").write(
            to: profilesDirectory.appendingPathComponent("valid.json")
        )
        let brokenURL = profilesDirectory.appendingPathComponent("broken.json")
        let broken = Data("{broken".utf8)
        try broken.write(to: brokenURL)
        let issues = PersistenceIssueCenter()

        let store = try ProfileStore(directory: dir, issueCenter: issues)
        #expect(store.profiles.map(\.name) == ["Historical Profile"])
        #expect(issues.issues.count == 1)
        #expect(issues.issues.first?.sourceURL.lastPathComponent == brokenURL.lastPathComponent)
        #expect(try Data(contentsOf: brokenURL) == broken)
    }

    @Test func temporaryStoreCanReconnectToPersistentStorage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-store-reconnect-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let temporaryDirectory = root.appendingPathComponent("Temporary")
        let persistentDirectory = root.appendingPathComponent("Persistent")
        let persistentProfiles = persistentDirectory.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(
            at: persistentProfiles,
            withIntermediateDirectories: true
        )
        try fixture("profile-v1-missing-fields").write(
            to: persistentProfiles.appendingPathComponent("historical.json")
        )

        let store = try ProfileStore(directory: temporaryDirectory)
        #expect(store.profiles.isEmpty)
        try store.useStorage(directory: persistentDirectory)

        #expect(store.profiles.map(\.name) == ["Historical Profile"])
        #expect(store.defaultProfile.name == "Historical Profile")
    }
}

final class TerminalSessionDocumentCodecTests {
    @Test func plainTextMigratesInMemoryAndSavesAsV1() throws {
        let original = Data("prompt output\n".utf8)
        let value = try TerminalSessionDocumentCodec.decode(original)
        #expect(value.content == "prompt output\n")
        #expect(value.profileID == nil)

        let saved = try TerminalSessionDocumentCodec.encode(value)
        let object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect((object["version"] as? NSNumber)?.intValue == 1)
        #expect(try TerminalSessionDocumentCodec.decode(saved) == value)
    }

    @Test func futureEnvelopeIsNeverTreatedAsTerminalText() throws {
        let data = try fixture("terminal-v99")
        #expect(throws: VersionedPersistenceError.unsupportedVersion(found: 99, supported: 1)) {
            try TerminalSessionDocumentCodec.decode(data)
        }
    }

    @Test func jsonWithoutVersionRemainsLegacyTerminalText() throws {
        let data = Data("{\"ordinary\":\"terminal output\"}".utf8)
        #expect(try TerminalSessionDocumentCodec.decode(data).content == String(data: data, encoding: .utf8))
    }
}

final class LaunchParametersTests {
    @Test func loginShellUsesLoginIdiom () {
        let profile = TerminalProfile (name: "Test")
        let params = ProfileApplier.launchParameters (for: profile)
        #expect (params.execName?.hasPrefix ("-") == true)
        #expect (params.environment.contains ("TERM=xterm-256color"))
        #expect (params.environment.contains ("TERM_PROGRAM=tecolot"))
        #expect (params.environment.contains { $0.hasPrefix("TECOLOT_RESOURCES_DIR=") })
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

    @Test func directInteractiveShellGetsIntegration () {
        var profile = TerminalProfile(name: "Test")
        profile.shell = .command("/bin/zsh", runInShell: false)
        let params = ProfileApplier.launchParameters(for: profile)

        #expect(params.environment.contains { $0.hasPrefix("ZDOTDIR=") })
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

    @Test func shellIntegrationDoesNotOverrideProfileCursor() {
        var profile = TerminalProfile(name: "Test")
        profile.cursorStyle = .steadyUnderline

        let params = ProfileApplier.launchParameters(for: profile)

        #expect(params.environment.contains("TECOLOT_SHELL_FEATURES=title"))
    }
}

final class TecolotShellIntegrationTests {
    private let resources = URL(fileURLWithPath: "/tmp/tecolot resources", isDirectory: true)

    @Test func exportsTerminalIdentityWithoutAutomaticInjection () {
        let input = LaunchParameters(
            executable: "/bin/zsh",
            args: ["-lc", "echo test"],
            execName: nil,
            environment: ["TERM=xterm-256color"],
            currentDirectory: nil
        )
        let result = TecolotShellIntegration.configure(
            input,
            automatic: false,
            resourcesDirectory: resources,
            processEnvironment: [:],
            terminalProgramVersion: "1.2.3"
        )

        #expect(result.args == input.args)
        #expect(result.environment.contains("TERM_PROGRAM=tecolot"))
        #expect(result.environment.contains("TERM_PROGRAM_VERSION=1.2.3"))
        #expect(result.environment.contains("TECOLOT_SHELL_FEATURES=title"))
        #expect(result.environment.contains("TECOLOT_RESOURCES_DIR=/tmp/tecolot resources"))
        #expect(!result.environment.contains { $0.hasPrefix("ZDOTDIR=") })
    }

    @Test func shellFeaturesDoNotContainCursorControl() {
        let input = LaunchParameters(
            executable: "/bin/zsh", args: [], execName: nil,
            environment: [], currentDirectory: nil
        )

        let result = TecolotShellIntegration.configure(
            input, automatic: false,
            resourcesDirectory: resources, processEnvironment: [:],
            terminalProgramVersion: "1"
        )

        #expect(result.environment.contains("TECOLOT_SHELL_FEATURES=title"))
    }

    @Test func injectsZshAndPreservesZDotDirectory () {
        let input = LaunchParameters(
            executable: "/bin/zsh",
            args: [],
            execName: "-zsh",
            environment: [],
            currentDirectory: nil
        )
        let result = TecolotShellIntegration.configure(
            input,
            automatic: true,
            resourcesDirectory: resources,
            processEnvironment: ["ZDOTDIR": "/Users/test/.config/zsh"],
            terminalProgramVersion: "1"
        )

        #expect(result.environment.contains("TECOLOT_ZSH_ZDOTDIR=/Users/test/.config/zsh"))
        #expect(result.environment.contains("ZDOTDIR=/tmp/tecolot resources/shell-integration/zsh"))
    }

    @Test func injectsFishThroughXDGDataDirectories () {
        let input = LaunchParameters(
            executable: "/opt/homebrew/bin/fish",
            args: [],
            execName: "-fish",
            environment: [],
            currentDirectory: nil
        )
        let result = TecolotShellIntegration.configure(
            input,
            automatic: true,
            resourcesDirectory: resources,
            processEnvironment: ["XDG_DATA_DIRS": "/opt/share:/usr/share"],
            terminalProgramVersion: "1"
        )

        let integration = "/tmp/tecolot resources/shell-integration"
        #expect(result.environment.contains("TECOLOT_SHELL_INTEGRATION_XDG_DIR=\(integration)"))
        #expect(result.environment.contains("XDG_DATA_DIRS=\(integration):/opt/share:/usr/share"))
    }

    @Test func injectsNushellModule () {
        let input = LaunchParameters(
            executable: "/opt/homebrew/bin/nu",
            args: ["--login"],
            execName: nil,
            environment: [],
            currentDirectory: nil
        )
        let result = TecolotShellIntegration.configure(
            input,
            automatic: true,
            resourcesDirectory: resources,
            processEnvironment: [:],
            terminalProgramVersion: "1"
        )

        #expect(result.args == ["--execute", "use tecolot *", "--login"])
    }

    @Test func doesNotInjectAppleBash () {
        let input = LaunchParameters(
            executable: "/bin/bash",
            args: [],
            execName: "-bash",
            environment: [],
            currentDirectory: nil
        )
        let result = TecolotShellIntegration.configure(
            input,
            automatic: true,
            resourcesDirectory: resources,
            processEnvironment: [:],
            terminalProgramVersion: "1"
        )

        #expect(result.args.isEmpty)
        #expect(!result.environment.contains { $0.hasPrefix("ENV=") })
        #expect(result.environment.contains("TECOLOT_RESOURCES_DIR=/tmp/tecolot resources"))
    }

    @Test func injectsSupportedBashAndPreservesFlags () throws {
        let resources = try #require(TecolotShellIntegration.resourcesDirectory)
        let input = LaunchParameters(
            executable: "/opt/homebrew/bin/bash",
            args: ["--noprofile", "--rcfile", "/tmp/test.bashrc", "-l"],
            execName: "-bash",
            environment: ["HOME=/Users/test"],
            currentDirectory: nil
        )
        let result = TecolotShellIntegration.configure(
            input,
            automatic: true,
            resourcesDirectory: resources,
            processEnvironment: ["ENV": "/tmp/original-env"],
            terminalProgramVersion: "1"
        )

        #expect(result.args == ["--posix", "-l"])
        #expect(result.environment.contains("TECOLOT_BASH_INJECT=1 --noprofile"))
        #expect(result.environment.contains("TECOLOT_BASH_RCFILE=/tmp/test.bashrc"))
        #expect(result.environment.contains("TECOLOT_BASH_ENV=/tmp/original-env"))
        #expect(result.environment.contains {
            $0.hasPrefix("ENV=") && $0.hasSuffix("/shell-integration/bash/tecolot.bash")
        })
    }

    @Test func doesNotInjectNoninteractiveShellCommands () throws {
        let resources = try #require(TecolotShellIntegration.resourcesDirectory)
        let bash = LaunchParameters(
            executable: "/opt/homebrew/bin/bash",
            args: ["-lc", "echo test"],
            execName: nil,
            environment: [],
            currentDirectory: nil
        )
        let bashResult = TecolotShellIntegration.configure(
            bash,
            automatic: true,
            resourcesDirectory: resources,
            processEnvironment: [:],
            terminalProgramVersion: "1"
        )
        #expect(bashResult.args == bash.args)
        #expect(!bashResult.environment.contains { $0.hasPrefix("ENV=") })

        let nushell = LaunchParameters(
            executable: "/opt/homebrew/bin/nu",
            args: ["--command", "echo test"],
            execName: nil,
            environment: [],
            currentDirectory: nil
        )
        let nushellResult = TecolotShellIntegration.configure(
            nushell,
            automatic: true,
            resourcesDirectory: resources,
            processEnvironment: [:],
            terminalProgramVersion: "1"
        )
        #expect(nushellResult.args == nushell.args)
    }
}
