import CoreFoundation
import Foundation
import SwiftTerm

/// App-wide bell and OSC notification preferences, separate from program activity.
enum TerminalNotificationPreferences {
    static let bellStyleKey = "bellStyle"
    static let bellStyleDefault = BellStyle.sound
    static let allowsProgramNotificationsKey = "allowsProgramNotifications"
    static let allowsProgramNotificationsDefault = true
    static let bellMigrationSeededKey = "bellMigrationSeeded"
    static let bellMigrationSeededDefault = false
    static let bellMigrationDifferedKey = "bellMigrationDiffered"
    static let bellMigrationNoteDismissedKey = "bellMigrationNoteDismissed"
    static let bellMigrationNoteDismissedDefault = false

    static func bellStyle(defaults: UserDefaults = .standard) -> BellStyle {
        guard let tag = defaults.object(forKey: bellStyleKey) as? String else {
            return bellStyleDefault
        }
        return BellStyle(tagName: tag) ?? bellStyleDefault
    }

    static func allowsProgramNotifications(defaults: UserDefaults = .standard) -> Bool {
        boolean(forKey: allowsProgramNotificationsKey, defaults: defaults) ?? allowsProgramNotificationsDefault
    }

    static func bellMigrationSeeded(defaults: UserDefaults = .standard) -> Bool {
        boolean(forKey: bellMigrationSeededKey, defaults: defaults) ?? bellMigrationSeededDefault
    }

    static func bellMigrationDiffered(defaults: UserDefaults = .standard) -> [String]? {
        guard
            let values = defaults.object(forKey: bellMigrationDifferedKey) as? [String],
            values.allSatisfy({
                $0 == "bell" || $0 == "notifications"
            }) else {
            return nil
        }
        return values
    }

    static func bellMigrationNoteDismissed(defaults: UserDefaults = .standard) -> Bool {
        boolean(forKey: bellMigrationNoteDismissedKey, defaults: defaults) ?? bellMigrationNoteDismissedDefault
    }

    static func showsMigrationNote(differed: [String]?, dismissed: Bool) -> Bool {
        !(differed ?? []).isEmpty && !dismissed
    }

    private static func boolean(forKey key: String, defaults: UserDefaults) -> Bool? {
        guard
            let value = defaults.object(forKey: key),
            CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }
}
