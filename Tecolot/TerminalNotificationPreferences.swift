import CoreFoundation
import Foundation
import SwiftTerm

/// App-wide bell and OSC notification preferences, separate from program activity.
enum TerminalNotificationPreferences {
    static let bellStyleKey = "bellStyle"
    static let allowsProgramNotificationsKey = "allowsProgramNotifications"
    static let bellMigrationSeededKey = "bellMigrationSeeded"
    static let bellMigrationDifferedKey = "bellMigrationDiffered"
    static let bellMigrationNoteDismissedKey = "bellMigrationNoteDismissed"

    static func bellStyle(defaults: UserDefaults = .standard) -> BellStyle {
        guard let tag = defaults.object(forKey: bellStyleKey) as? String else {
            return .sound
        }
        return BellStyle(tagName: tag) ?? .sound
    }

    static func allowsProgramNotifications(defaults: UserDefaults = .standard) -> Bool {
        boolean(forKey: allowsProgramNotificationsKey, defaults: defaults) ?? true
    }

    static func bellMigrationSeeded(defaults: UserDefaults = .standard) -> Bool {
        boolean(forKey: bellMigrationSeededKey, defaults: defaults) ?? false
    }

    static func bellMigrationDiffered(defaults: UserDefaults = .standard) -> [String]? {
        guard let values = defaults.object(forKey: bellMigrationDifferedKey) as? [String],
              values.allSatisfy({ $0 == "bell" || $0 == "notifications" }) else {
            return nil
        }
        return values
    }

    static func bellMigrationNoteDismissed(defaults: UserDefaults = .standard) -> Bool {
        boolean(forKey: bellMigrationNoteDismissedKey, defaults: defaults) ?? false
    }

    static func showsMigrationNote(differed: [String]?, dismissed: Bool) -> Bool {
        !(differed ?? []).isEmpty && !dismissed
    }

    private static func boolean(forKey key: String, defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: key),
              CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }
}
