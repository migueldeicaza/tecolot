//
//  SettingsPreviewData.swift
//  Tecolot
//
//  Isolated sample data for Settings previews.
//
import Foundation

@MainActor
enum SettingsPreviewData {
    private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Tecolot-Settings-Preview-\(UUID().uuidString)")
    private static let backupDirectory = directory.appendingPathComponent("Backups")
    static let defaults = UserDefaults(suiteName: "com.tirania.Tecolot.SettingsPreview")!

    static let issueCenter = PersistenceIssueCenter()

    static let profiles: ProfileStore = {
        let store = try! ProfileStore(
            directory: directory,
            issueCenter: issueCenter,
            backupDirectory: backupDirectory
        )
        if store.profiles.isEmpty {
            try! store.add(TerminalProfile(name: "Default"))
            var servers = TerminalProfile(name: "Servers")
            servers.fontSize = 13
            servers.optionAsMetaKey = false
            try! store.add(servers)
        }
        return store
    }()

    static let themes = ThemeStore(
        directory: directory.appendingPathComponent("Themes"),
        issueCenter: issueCenter,
        backupDirectory: backupDirectory
    )

    static let windowGroups = WindowGroupStore(
        directory: directory,
        issueCenter: issueCenter,
        backupDirectory: backupDirectory
    )

    static let recovery = DataRecoveryCoordinator(
        issueCenter: issueCenter,
        profiles: profiles,
        themes: themes,
        windowGroups: windowGroups,
        preferences: PreferenceMigrator(
            defaults: defaults,
            applicationSupportDirectory: directory,
            backupDirectory: backupDirectory,
            issueCenter: issueCenter,
            applySecureKeyboardEntry: { _ in }
        ),
        backupDirectory: backupDirectory,
        profileStorageDirectory: directory,
        retryLegacyMigration: { nil }
    )

    static let sampleIssue: PersistenceIssue = {
        let issue = PersistenceIssue(
            domain: .profiles,
            sourceURL: directory.appendingPathComponent("Profiles/Broken Profile.json"),
            kind: .invalidFormat,
            message: "This preview profile file has invalid data.",
            foundVersion: 1,
            supportedVersion: 1
        )
        issueCenter.report(issue)
        return issue
    }()

    static var profile: TerminalProfile {
        profiles.defaultProfile
    }

    static var keyBinding: TerminalKeyBinding {
        TerminalKeyBinding(
            key: "k",
            modifiers: [.command, .shift],
            action: .sendText,
            value: "clear\n"
        )
    }
}
