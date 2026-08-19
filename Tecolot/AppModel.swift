//
//  AppModel.swift
//  Tecolot
//
//  Application-wide anchor for the profile/theme stores and the handoff of
//  launch parameters into new windows. The NSDocumentController-based window
//  creation path cannot carry parameters, so "New Window with Profile" style
//  commands deposit a consume-once LaunchSpec here that the new session's
//  controller picks up; every fallback path uses the default profile.
//
import Foundation

/// Parameters for the next session to be created
struct LaunchSpec {
    var profileID: TerminalProfile.ID?
    var workingDirectory: String?
    var themeOverride: String?
}

@MainActor
final class AppModel {
    static let shared = AppModel()

    let profiles: ProfileStore
    let themes: ThemeStore
    let windowGroups: WindowGroupStore
    let issueCenter: PersistenceIssueCenter
    let recovery: DataRecoveryCoordinator
    private let preferences: PreferenceMigrator

    /// Consume-once parameters for the next terminal session
    private var pendingLaunch: LaunchSpec?

    private init() {
        let issueCenter = PersistenceIssueCenter()
        self.issueCenter = issueCenter
        let applicationSupport = Self.applicationSupportDirectory()
        let backups = applicationSupport.appendingPathComponent("Backups")
        let legacyMigrationIssue = Self.migrateLegacyApplicationSupport(
            to: applicationSupport,
            allowExistingEmptyDestination: false
        )

        do {
            profiles = try ProfileStore(
                directory: applicationSupport,
                issueCenter: issueCenter,
                backupDirectory: backups
            )
        } catch {
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("Tecolot-profiles-fallback-\(UUID().uuidString)")
            profiles = try! ProfileStore(
                directory: fallback,
                issueCenter: issueCenter,
                backupDirectory: backups
            )
            issueCenter.report(PersistenceIssue(
                domain: .profiles,
                sourceURL: applicationSupport.appendingPathComponent("Profiles"),
                kind: .writeFailed,
                message: "Tecolot could not open profile storage. Built-in defaults are active: \(error.localizedDescription)"
            ))
        }
        themes = ThemeStore(
            directory: applicationSupport.appendingPathComponent("Themes"),
            issueCenter: issueCenter,
            backupDirectory: backups
        )
        windowGroups = WindowGroupStore(
            directory: applicationSupport,
            issueCenter: issueCenter,
            backupDirectory: backups
        )
        let preferences = PreferenceMigrator(
            applicationSupportDirectory: applicationSupport,
            backupDirectory: backups,
            issueCenter: issueCenter
        )
        self.preferences = preferences
        if let legacyMigrationIssue {
            issueCenter.report(legacyMigrationIssue)
        }
        preferences.migrate(profiles: profiles, windowGroups: windowGroups)
        recovery = DataRecoveryCoordinator(
            issueCenter: issueCenter,
            profiles: profiles,
            themes: themes,
            windowGroups: windowGroups,
            preferences: preferences,
            backupDirectory: backups,
            profileStorageDirectory: applicationSupport,
            retryLegacyMigration: {
                Self.migrateLegacyApplicationSupport(
                    to: applicationSupport,
                    allowExistingEmptyDestination: true
                )
            }
        )
    }

    /// Copies the legacy store once. Do not merge it into an existing store,
    /// because both stores can contain a profile with the same name.
    private static func migrateLegacyApplicationSupport(
        to destination: URL,
        allowExistingEmptyDestination: Bool
    ) -> PersistenceIssue? {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let source = applicationSupport.appendingPathComponent("com.tirania.MacTerminalUI")
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        do {
            if !fileManager.fileExists(atPath: destination.path) {
                let staging = destination.deletingLastPathComponent().appendingPathComponent(
                    ".tecolot-legacy-import-\(UUID().uuidString)"
                )
                defer { try? fileManager.removeItem(at: staging) }
                try fileManager.copyItem(at: source, to: staging)
                try fileManager.moveItem(at: staging, to: destination)
            } else if allowExistingEmptyDestination {
                guard !destinationContainsUserData(destination) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try mergeMissingItems(from: source, into: destination)
            } else {
                return nil
            }
            return nil
        } catch {
            return PersistenceIssue(
                domain: .legacyApplicationSupport,
                sourceURL: source,
                kind: .migrationFailed,
                message: "Tecolot could not copy the legacy application data: \(error.localizedDescription)"
            )
        }
    }

    private static func destinationContainsUserData(_ destination: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: destination,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return false }
        for case let url as URL in enumerator {
            if url.pathExtension == "json" {
                return true
            }
        }
        return false
    }

    private static func mergeMissingItems(from source: URL, into destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let children = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        for sourceChild in children {
            let destinationChild = destination.appendingPathComponent(sourceChild.lastPathComponent)
            let isDirectory = try sourceChild.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            if isDirectory,
               FileManager.default.fileExists(atPath: destinationChild.path) {
                try mergeMissingItems(from: sourceChild, into: destinationChild)
            } else {
                guard !FileManager.default.fileExists(atPath: destinationChild.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try FileManager.default.copyItem(at: sourceChild, to: destinationChild)
            }
        }
    }

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot")
    }

    func setPendingLaunch(_ spec: LaunchSpec) {
        pendingLaunch = spec
    }

    func discardPendingLaunch() {
        pendingLaunch = nil
    }

    /// Returns and clears the pending launch parameters
    func takePendingLaunch() -> LaunchSpec? {
        defer { pendingLaunch = nil }
        return pendingLaunch
    }

    /// The profile a new session should use for a given spec
    func resolveProfile(for spec: LaunchSpec?) -> TerminalProfile {
        if let id = spec?.profileID, let profile = profiles.profile(withID: id) {
            return profile
        }
        return profiles.defaultProfile
    }
}
