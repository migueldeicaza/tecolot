import AppKit
import Foundation
import SwiftTerm

private struct PreferencesV0 {
    var newTabsUseCurrentDirectory: Bool?
    var newTabsUseCurrentProfile: Bool?
    var useCommandDigitsForTabs: Bool?
    var restoredRowsLimit: Int?
    var startupMode: String?
    var startupProfileID: String?
    var startupWindowGroupID: String?
    var secureKeyboardEntry: Bool?
    var logHostOutput: Bool?
    var useMetalRenderer: Bool?
}

private struct PreferencesV1 {
    var newTabsUseCurrentDirectory: Bool
    var newTabsUseCurrentProfile: Bool
    var useCommandDigitsForTabs: Bool
    var restoredRowsLimit: Int
    var startupMode: String
    var startupProfileID: String?
    var startupWindowGroupID: String?
    var secureKeyboardEntry: Bool
    var logHostOutput: Bool
    var useMetalRenderer: Bool
}

@MainActor
final class PreferenceMigrator {
    static let currentVersion = 2
    static let schemaKey = "settingsSchemaVersion"

    private let defaults: UserDefaults
    private let backupDirectory: URL
    private let issueCenter: PersistenceIssueCenter
    private let sourceURL: URL
    private let applySecureKeyboardEntry: @MainActor (Bool) -> Void

    private let managedKeys = [
        "newTabsUseCurrentDirectory",
        "newTabsUseCurrentProfile",
        "useCommandDigitsForTabs",
        "restoredRowsLimit",
        "startupMode",
        "startupProfileID",
        "startupWindowGroupID",
        "startupGroupIDs",
        "SecureKeyboardEntry",
        "LogHostOutput",
        "useMetalRenderer",
        TerminalNotificationPreferences.bellStyleKey,
        TerminalNotificationPreferences.allowsProgramNotificationsKey
    ]

    init(
        defaults: UserDefaults = .standard,
        applicationSupportDirectory: URL,
        backupDirectory: URL,
        issueCenter: PersistenceIssueCenter,
        applySecureKeyboardEntry: @escaping @MainActor (Bool) -> Void = {
            SecureKeyboardEntry.shared.isEnabled = $0
        }
    ) {
        self.defaults = defaults
        self.backupDirectory = backupDirectory
        self.issueCenter = issueCenter
        self.applySecureKeyboardEntry = applySecureKeyboardEntry
        sourceURL = applicationSupportDirectory.appendingPathComponent("preferences.json")
    }

    func migrate(profiles: ProfileStore) {
        let sourceVersion: Int
        do {
            sourceVersion = try readSchemaVersion()
        } catch {
            issueCenter.report(PersistenceIssue(
                domain: .preferences,
                sourceURL: sourceURL,
                kind: .invalidFormat,
                message: error.localizedDescription,
                supportedVersion: Self.currentVersion
            ))
            return
        }
        guard sourceVersion <= Self.currentVersion else {
            issueCenter.report(PersistenceIssue(
                domain: .preferences,
                sourceURL: sourceURL,
                kind: .unsupportedVersion,
                message: "The preferences use schema version \(sourceVersion). This version of Tecolot supports up to version \(Self.currentVersion).",
                foundVersion: sourceVersion,
                supportedVersion: Self.currentVersion
            ))
            return
        }

        if sourceVersion < Self.currentVersion {
            do {
                let snapshot = try snapshotData()
                _ = try PersistenceBackups.writeSnapshotIfNeeded(
                    snapshot,
                    sourceName: sourceURL.lastPathComponent,
                    domain: .preferences,
                    sourceVersion: sourceVersion,
                    root: backupDirectory
                )
            } catch {
                issueCenter.report(PersistenceIssue(
                    domain: .preferences,
                    sourceURL: sourceURL,
                    kind: .backupFailed,
                    message: error.localizedDescription,
                    foundVersion: sourceVersion,
                    supportedVersion: Self.currentVersion
                ))
                return
            }
        }

        let source = readV0()
        let migrated = migrateV0(source, profiles: profiles)
        apply(migrated)
        migrateBellPreferences(profiles: profiles)
        defaults.set(Self.currentVersion, forKey: Self.schemaKey)
        if defaults.synchronize() {
            issueCenter.resolve(domain: .preferences, sourceURL: sourceURL)
        } else {
            issueCenter.report(PersistenceIssue(
                domain: .preferences,
                sourceURL: sourceURL,
                kind: .writeFailed,
                message: "Tecolot could not save the migrated preferences.",
                foundVersion: sourceVersion,
                supportedVersion: Self.currentVersion
            ))
        }
    }

    func restore(from backupURL: URL) throws {
        let data = try Data(contentsOf: backupURL)
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VersionedPersistenceError.invalidDocument("The preference backup is not valid.")
        }
        for key in managedKeys + [Self.schemaKey] {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in snapshot where key != Self.schemaKey {
            defaults.set(value, forKey: key)
        }
        defaults.set(0, forKey: Self.schemaKey)
        guard defaults.synchronize() else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func reset(profiles: ProfileStore) {
        for key in managedKeys + [Self.schemaKey] {
            defaults.removeObject(forKey: key)
        }
        migrate(profiles: profiles)
    }

    private func migrateBellPreferences(profiles: ProfileStore) {
        guard !TerminalNotificationPreferences.bellMigrationSeeded(defaults: defaults),
              !issueCenter.issues.contains(where: {
                  $0.domain == .profiles || $0.domain == .legacyApplicationSupport
              }) else {
            return
        }
        let profile = profiles.defaultProfile
        if defaults.object(forKey: TerminalNotificationPreferences.bellStyleKey) == nil {
            defaults.set(profile.bellStyle.tagName, forKey: TerminalNotificationPreferences.bellStyleKey)
        }
        if defaults.object(forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey) == nil {
            defaults.set(profile.allowsNotifications, forKey: TerminalNotificationPreferences.allowsProgramNotificationsKey)
        }
        var differed: [String] = []
        if profiles.profiles.contains(where: { $0.bellStyle != profile.bellStyle }) {
            differed.append("bell")
        }
        if profiles.profiles.contains(where: { $0.allowsNotifications != profile.allowsNotifications }) {
            differed.append("notifications")
        }
        if !differed.isEmpty {
            defaults.set(differed, forKey: TerminalNotificationPreferences.bellMigrationDifferedKey)
        }
        // UserDefaults can retain an equal numeric value's type when writing a Bool.
        defaults.removeObject(forKey: TerminalNotificationPreferences.bellMigrationSeededKey)
        defaults.set(true, forKey: TerminalNotificationPreferences.bellMigrationSeededKey)
    }

    private func snapshotData() throws -> Data {
        var snapshot: [String: Any] = [Self.schemaKey: defaults.object(forKey: Self.schemaKey) ?? 0]
        for key in managedKeys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }
        return try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
    }

    private func readSchemaVersion() throws -> Int {
        guard let rawValue = defaults.object(forKey: Self.schemaKey) else {
            return 0
        }
        guard
            let number = rawValue as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue == Double(number.intValue),
            number.intValue >= 0 else {
            throw VersionedPersistenceError.invalidDocument("The preference schema version is not valid.")
        }
        return number.intValue
    }

    private func readV0() -> PreferencesV0 {
        PreferencesV0(
            newTabsUseCurrentDirectory: boolean(forKey: "newTabsUseCurrentDirectory"),
            newTabsUseCurrentProfile: boolean(forKey: "newTabsUseCurrentProfile"),
            useCommandDigitsForTabs: boolean(forKey: "useCommandDigitsForTabs"),
            restoredRowsLimit: defaults.object(forKey: "restoredRowsLimit") as? Int,
            startupMode: defaults.string(forKey: "startupMode"),
            startupProfileID: defaults.string(forKey: "startupProfileID"),
            startupWindowGroupID: defaults.string(forKey: "startupWindowGroupID"),
            secureKeyboardEntry: boolean(forKey: "SecureKeyboardEntry"),
            logHostOutput: boolean(forKey: "LogHostOutput"),
            useMetalRenderer: boolean(forKey: "useMetalRenderer")
        )
    }

    private func migrateV0(
        _ source: PreferencesV0,
        profiles: ProfileStore
    ) -> PreferencesV1 {
        let validModes = Set(["default", "profile", "windowGroup", "groups"])
        var startupMode = source.startupMode ?? "default"
        if !validModes.contains(startupMode) {
            startupMode = "default"
        }

        var startupProfileID = source.startupProfileID
        let startupWindowGroupID = source.startupWindowGroupID
        if startupMode == "profile" {
            let rawID = startupProfileID ?? ""
            if let id = UUID(uuidString: rawID) {
                let profileDataIsIncomplete = issueCenter.issues.contains {
                    $0.domain == .profiles || $0.domain == .legacyApplicationSupport
                }
                if profiles.profile(withID: id) == nil, !profileDataIsIncomplete {
                    startupProfileID = nil
                    startupMode = "default"
                }
            } else {
                startupProfileID = nil
                startupMode = "default"
            }
        }
        return PreferencesV1(
            newTabsUseCurrentDirectory: source.newTabsUseCurrentDirectory ?? true,
            newTabsUseCurrentProfile: source.newTabsUseCurrentProfile ?? true,
            useCommandDigitsForTabs: source.useCommandDigitsForTabs ?? true,
            restoredRowsLimit: min(max(source.restoredRowsLimit ?? 1_000, 0), 100_000),
            startupMode: startupMode,
            startupProfileID: startupProfileID,
            startupWindowGroupID: startupWindowGroupID,
            secureKeyboardEntry: source.secureKeyboardEntry ?? false,
            logHostOutput: source.logHostOutput ?? false,
            useMetalRenderer: source.useMetalRenderer ?? true
        )
    }

    private func apply(_ preferences: PreferencesV1) {
        defaults.set(preferences.newTabsUseCurrentDirectory, forKey: "newTabsUseCurrentDirectory")
        defaults.set(preferences.newTabsUseCurrentProfile, forKey: "newTabsUseCurrentProfile")
        defaults.set(preferences.useCommandDigitsForTabs, forKey: "useCommandDigitsForTabs")
        defaults.set(preferences.restoredRowsLimit, forKey: "restoredRowsLimit")
        defaults.set(preferences.startupMode, forKey: "startupMode")
        setOptional(preferences.startupProfileID, forKey: "startupProfileID")
        setOptional(preferences.startupWindowGroupID, forKey: "startupWindowGroupID")
        defaults.set(preferences.secureKeyboardEntry, forKey: "SecureKeyboardEntry")
        defaults.set(preferences.logHostOutput, forKey: "LogHostOutput")
        defaults.set(preferences.useMetalRenderer, forKey: "useMetalRenderer")
        applySecureKeyboardEntry(preferences.secureKeyboardEntry)
    }

    private func boolean(forKey key: String) -> Bool? {
        guard
            let value = defaults.object(forKey: key),
            CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private func setOptional(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

@MainActor
final class DataRecoveryCoordinator {
    let issueCenter: PersistenceIssueCenter

    private let profiles: ProfileStore
    private let themes: ThemeStore
    private let preferences: PreferenceMigrator
    private let backupDirectory: URL
    private let profileStorageDirectory: URL
    private let retryLegacyMigration: () -> PersistenceIssue?

    init(
        issueCenter: PersistenceIssueCenter,
        profiles: ProfileStore,
        themes: ThemeStore,
        preferences: PreferenceMigrator,
        backupDirectory: URL,
        profileStorageDirectory: URL,
        retryLegacyMigration: @escaping () -> PersistenceIssue?
    ) {
        self.issueCenter = issueCenter
        self.profiles = profiles
        self.themes = themes
        self.preferences = preferences
        self.backupDirectory = backupDirectory
        self.profileStorageDirectory = profileStorageDirectory
        self.retryLegacyMigration = retryLegacyMigration
    }

    func reveal(_ issue: PersistenceIssue) {
        let target = FileManager.default.fileExists(atPath: issue.sourceURL.path)
            ? issue.sourceURL
            : availableBackup(for: issue) ?? issue.sourceURL.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func retry(_ issue: PersistenceIssue) {
        switch issue.domain {
        case .profiles, .profileStore:
            reconnectProfileStorage(sourceURL: issue.sourceURL)
        case .legacyApplicationSupport:
            retryLegacyApplicationSupport(sourceURL: issue.sourceURL)
        default:
            reload(domain: issue.domain)
        }
    }

    func availableBackup(for issue: PersistenceIssue) -> URL? {
        if
            let backupURL = issue.backupURL,
            FileManager.default.fileExists(atPath: backupURL.path) {
            return backupURL
        }
        let directory = backupDirectory.appendingPathComponent(issue.domain.rawValue)
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else {
            return nil
        }
        let prefix = "\(issue.sourceURL.lastPathComponent).v"
        return files
            .filter {
                $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "backup"
            }
            .sorted {
                $0.lastPathComponent > $1.lastPathComponent
            }
            .first
    }

    func restore(_ issue: PersistenceIssue) throws {
        guard let backupURL = availableBackup(for: issue) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if issue.domain == .preferences {
            try preferences.restore(from: backupURL)
        } else {
            try PersistenceBackups.restore(backupURL, to: issue.sourceURL)
        }
        retry(issue)
    }

    func resetPreferences() {
        preferences.reset(profiles: profiles)
    }

    func moveToTrash(_ issue: PersistenceIssue) async throws {
        let values = try issue.sourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.trashItem(at: issue.sourceURL, resultingItemURL: nil)
        retry(issue)
    }

    func canMoveToTrash(_ issue: PersistenceIssue) -> Bool {
        (try? issue.sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func reload(domain: PersistenceDomain) {
        switch domain {
        case .profiles, .profileStore:
            profiles.reload()
        case .userThemes, .themeFavorites:
            themes.reload()
        case .windowGroups:
            RestoreStore.shared.retryWindowGroupsMigration()
        case .preferences:
            preferences.migrate(profiles: profiles)
        case .terminalDocument:
            break
        case .legacyApplicationSupport:
            break
        case .windowRestoration:
            // A retry permits writes only after the file can be loaded.
            RestoreStore.shared.retryRestorationRecovery()
            break
        }
    }

    private func reconnectProfileStorage(sourceURL: URL, migratePreferences: Bool = true) {
        do {
            try profiles.useStorage(
                directory: profileStorageDirectory,
                backupDirectory: backupDirectory
            )
            if migratePreferences {
                preferences.migrate(profiles: profiles)
            }
        } catch {
            issueCenter.report(PersistenceIssue(
                domain: .profiles,
                sourceURL: sourceURL,
                kind: .unreadable,
                message: "Tecolot still cannot open profile storage: \(error.localizedDescription)"
            ))
        }
    }

    private func retryLegacyApplicationSupport(sourceURL: URL) {
        if let issue = retryLegacyMigration() {
            issueCenter.report(issue)
            return
        }
        issueCenter.resolve(domain: .legacyApplicationSupport, sourceURL: sourceURL)
        reconnectProfileStorage(
            sourceURL: profileStorageDirectory.appendingPathComponent("Profiles"),
            migratePreferences: false
        )
        themes.reload()
        RestoreStore.shared.retryWindowGroupsMigration()
        preferences.migrate(profiles: profiles)
    }
}
