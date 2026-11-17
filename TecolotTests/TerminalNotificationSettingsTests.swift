import Foundation
import SwiftTerm
import Testing
@testable import Tecolot

@MainActor
struct TerminalNotificationSettingsTests {
    private typealias Preferences = TerminalNotificationPreferences

    @Test func typedReadersUseDefaultsForAbsentOrMalformedValues() throws {
        let domain = "notification-settings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        func expectDefaults() {
            #expect(Preferences.bellStyle(defaults: defaults) == .sound)
            #expect(Preferences.allowsProgramNotifications(defaults: defaults))
            #expect(!Preferences.bellMigrationSeeded(defaults: defaults))
            #expect(Preferences.bellMigrationDiffered(defaults: defaults) == nil)
            #expect(!Preferences.bellMigrationNoteDismissed(defaults: defaults))
        }
        expectDefaults()
        defaults.set("unknown", forKey: Preferences.bellStyleKey)
        defaults.set("false", forKey: Preferences.allowsProgramNotificationsKey)
        defaults.set(1, forKey: Preferences.bellMigrationSeededKey)
        defaults.set(["unknown"], forKey: Preferences.bellMigrationDifferedKey)
        defaults.set("true", forKey: Preferences.bellMigrationNoteDismissedKey)
        expectDefaults()
        defaults.set(12, forKey: Preferences.bellStyleKey)
        defaults.set(0, forKey: Preferences.allowsProgramNotificationsKey)
        defaults.set("bell", forKey: Preferences.bellMigrationDifferedKey)
        expectDefaults()

        // Replace the malformed values, including numeric values equal to the Bools below.
        defaults.removePersistentDomain(forName: domain)
        defaults.set(BellStyle.visual.tagName, forKey: Preferences.bellStyleKey)
        defaults.set(false, forKey: Preferences.allowsProgramNotificationsKey)
        defaults.set(true, forKey: Preferences.bellMigrationSeededKey)
        defaults.set(["bell", "notifications"], forKey: Preferences.bellMigrationDifferedKey)
        defaults.set(true, forKey: Preferences.bellMigrationNoteDismissedKey)
        #expect(Preferences.bellStyle(defaults: defaults) == .visual)
        #expect(!Preferences.allowsProgramNotifications(defaults: defaults))
        #expect(Preferences.bellMigrationSeeded(defaults: defaults))
        #expect(Preferences.bellMigrationDiffered(defaults: defaults) == ["bell", "notifications"])
        #expect(Preferences.bellMigrationNoteDismissed(defaults: defaults))
    }

    @Test func migrationNoteRequiresDifferencesAndDisappearsAfterDismissal() {
        for differed: [String]? in [nil, [], ["bell"], ["notifications"], ["bell", "notifications"]] {
            #expect(Preferences.showsMigrationNote(differed: differed, dismissed: false) == !(differed ?? []).isEmpty)
            #expect(!Preferences.showsMigrationNote(differed: differed, dismissed: true))
        }
    }
}
