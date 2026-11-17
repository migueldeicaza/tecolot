import Foundation
import SwiftTerm
import Testing
@testable import Tecolot

@MainActor
struct TerminalNotificationMigrationTests {
    private typealias Preferences = TerminalNotificationPreferences

    private final class Fixture {
        let domain = "bell-migration-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bell-migration-\(UUID())")
        let defaults: UserDefaults
        let issues = PersistenceIssueCenter()
        let profiles: ProfileStore
        let migrator: PreferenceMigrator

        init() throws {
            defaults = try #require(UserDefaults(suiteName: domain))
            profiles = try ProfileStore(directory: directory, issueCenter: issues)
            migrator = PreferenceMigrator(
                defaults: defaults, applicationSupportDirectory: directory,
                backupDirectory: directory.appendingPathComponent("Backups"), issueCenter: issues,
                applySecureKeyboardEntry: { _ in }
            )
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }

        func setDefaultValues() throws {
            var profile = profiles.defaultProfile
            profile.bellStyle = .visual
            profile.allowsNotifications = false
            try profiles.update(profile)
        }
    }

    @Test(arguments: [0, 2])
    func seedsFromDefaultProfileOnNormalAndCurrentSchemaPaths(version: Int) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.setDefaultValues()
        fixture.defaults.set(version, forKey: PreferenceMigrator.schemaKey)
        fixture.migrator.migrate(profiles: fixture.profiles)
        #expect(Preferences.bellStyle(defaults: fixture.defaults) == .visual)
        #expect(!Preferences.allowsProgramNotifications(defaults: fixture.defaults))
        #expect(Preferences.bellMigrationSeeded(defaults: fixture.defaults))
        #expect(Preferences.bellMigrationDiffered(defaults: fixture.defaults) == nil)
        #expect(fixture.defaults.integer(forKey: PreferenceMigrator.schemaKey) == 2)
        #expect(PreferenceMigrator.currentVersion == 2)
    }

    @Test(arguments: [true, false], [true, false])
    func preservesEachExistingKey(bellExists: Bool, notificationsExist: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.setDefaultValues()
        if bellExists {
            fixture.defaults.set(BellStyle.none.tagName, forKey: Preferences.bellStyleKey)
        }
        if notificationsExist {
            fixture.defaults.set(true, forKey: Preferences.allowsProgramNotificationsKey)
        }
        fixture.migrator.migrate(profiles: fixture.profiles)
        #expect(Preferences.bellStyle(defaults: fixture.defaults) == (bellExists ? .none : .visual))
        #expect(Preferences.allowsProgramNotifications(defaults: fixture.defaults) == notificationsExist)
    }

    @Test func secondRunChangesNothingEvenIfProfilesChange() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.migrator.migrate(profiles: fixture.profiles)
        let before = try #require(fixture.defaults.persistentDomain(forName: fixture.domain))
        try fixture.setDefaultValues()
        fixture.migrator.migrate(profiles: fixture.profiles)
        let after = try #require(fixture.defaults.persistentDomain(forName: fixture.domain))
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
    }

    @Test func malformedMarkerIsReplacedWithABoolean() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(1, forKey: Preferences.bellMigrationSeededKey)
        #expect(!Preferences.bellMigrationSeeded(defaults: fixture.defaults))
        fixture.migrator.migrate(profiles: fixture.profiles)
        #expect(Preferences.bellMigrationSeeded(defaults: fixture.defaults))
    }

    @Test(arguments: [true, false], [true, false])
    func recordsExactlyWhichProfileValuesDiffer(bellDiffers: Bool, notificationsDiffer: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var other = TerminalProfile(name: "Other")
        other.bellStyle = bellDiffers ? .none : fixture.profiles.defaultProfile.bellStyle
        other.allowsNotifications = notificationsDiffer ? false : fixture.profiles.defaultProfile.allowsNotifications
        try fixture.profiles.add(other)
        fixture.migrator.migrate(profiles: fixture.profiles)
        let expected = (bellDiffers ? ["bell"] : []) + (notificationsDiffer ? ["notifications"] : [])
        #expect(Preferences.bellMigrationDiffered(defaults: fixture.defaults) == (expected.isEmpty ? nil : expected))
        if expected.isEmpty {
            #expect(fixture.defaults.object(forKey: Preferences.bellMigrationDifferedKey) == nil)
        }
    }

    @Test(arguments: [PersistenceDomain.profiles, .legacyApplicationSupport])
    func waitsForCompleteProfileDataThenRetries(domain: PersistenceDomain) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.setDefaultValues()
        let source = fixture.directory.appendingPathComponent("unreadable.json")
        fixture.issues.report(PersistenceIssue(
            domain: domain, sourceURL: source, kind: .unreadable, message: "Try again next launch"
        ))
        fixture.migrator.migrate(profiles: fixture.profiles)
        for key in [
            Preferences.bellStyleKey,
            Preferences.allowsProgramNotificationsKey,
            Preferences.bellMigrationDifferedKey,
            Preferences.bellMigrationSeededKey
        ] {
            #expect(fixture.defaults.object(forKey: key) == nil)
        }
        fixture.issues.resolve(domain: domain, sourceURL: source)
        fixture.migrator.migrate(profiles: fixture.profiles)
        #expect(Preferences.bellStyle(defaults: fixture.defaults) == .visual)
        #expect(!Preferences.allowsProgramNotifications(defaults: fixture.defaults))
        #expect(Preferences.bellMigrationSeeded(defaults: fixture.defaults))
    }

    @Test func resetKeepsMarkersAndDoesNotSeedOrFlagAgain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.setDefaultValues()
        try fixture.profiles.add(TerminalProfile(name: "Different"))
        fixture.migrator.migrate(profiles: fixture.profiles)
        #expect(Preferences.bellMigrationDiffered(defaults: fixture.defaults) == ["bell", "notifications"])
        fixture.defaults.set(true, forKey: Preferences.bellMigrationNoteDismissedKey)
        fixture.migrator.reset(profiles: fixture.profiles)
        #expect(Preferences.bellStyle(defaults: fixture.defaults) == .sound)
        #expect(Preferences.allowsProgramNotifications(defaults: fixture.defaults))
        #expect(fixture.defaults.object(forKey: Preferences.bellStyleKey) == nil)
        #expect(fixture.defaults.object(forKey: Preferences.allowsProgramNotificationsKey) == nil)
        #expect(Preferences.bellMigrationSeeded(defaults: fixture.defaults))
        #expect(Preferences.bellMigrationNoteDismissed(defaults: fixture.defaults))
        #expect(Preferences.bellMigrationDiffered(defaults: fixture.defaults) == ["bell", "notifications"])

        // Removing the old flag proves neither reset nor another launch writes it again.
        fixture.defaults.removeObject(forKey: Preferences.bellMigrationDifferedKey)
        fixture.migrator.reset(profiles: fixture.profiles)
        fixture.migrator.migrate(profiles: fixture.profiles)
        #expect(fixture.defaults.object(forKey: Preferences.bellMigrationDifferedKey) == nil)
        #expect(Preferences.bellStyle(defaults: fixture.defaults) == .sound)
        #expect(Preferences.allowsProgramNotifications(defaults: fixture.defaults))
    }

    @Test(arguments: ["invalid", "future", "backup"])
    func earlyFailuresDoNotSeed(failure: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        switch failure {
        case "invalid":
            fixture.defaults.set("invalid", forKey: PreferenceMigrator.schemaKey)
        case "future":
            fixture.defaults.set(3, forKey: PreferenceMigrator.schemaKey)
        default:
            let backups = fixture.directory.appendingPathComponent("Backups")
            try? FileManager.default.removeItem(at: backups)
            try Data("not a directory".utf8).write(to: backups)
        }
        fixture.migrator.migrate(profiles: fixture.profiles)
        #expect(fixture.issues.issues.contains {
            $0.domain == .preferences
        })
        for key in [
            Preferences.bellStyleKey,
            Preferences.allowsProgramNotificationsKey,
            Preferences.bellMigrationDifferedKey,
            Preferences.bellMigrationSeededKey
        ] {
            #expect(fixture.defaults.object(forKey: key) == nil)
        }
    }
}
