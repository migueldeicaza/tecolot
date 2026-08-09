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
import TerminalProfilesKit

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

    /// Consume-once parameters for the next terminal session
    private var pendingLaunch: LaunchSpec?

    private init() {
        Self.migrateLegacyApplicationSupport()
        // A failure to set up persistent storage falls back to an ephemeral
        // store in the temporary directory rather than crashing at startup
        if let store = try? ProfileStore() {
            profiles = store
        } else {
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("Tecolot-profiles-fallback")
            profiles = try! ProfileStore(directory: fallback)
        }
        themes = ThemeStore()
        windowGroups = WindowGroupStore()
    }

    /// Copies files that do not exist in the Tecolot directory. The old
    /// MacTerminalUI directory stays unchanged so the migration is recoverable.
    private static func migrateLegacyApplicationSupport() {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        let source = applicationSupport.appendingPathComponent("com.tirania.MacTerminalUI")
        let destination = applicationSupport.appendingPathComponent("com.tirania.Tecolot")
        guard fileManager.fileExists(atPath: source.path) else { return }
        copyMissingItems(from: source, to: destination, with: fileManager)
    }

    private static func copyMissingItems(
        from source: URL,
        to destination: URL,
        with fileManager: FileManager
    ) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }
        if !isDirectory.boolValue {
            guard !fileManager.fileExists(atPath: destination.path) else { return }
            try? fileManager.copyItem(at: source, to: destination)
            return
        }

        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let children = try? fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        ) else { return }
        for child in children {
            copyMissingItems(
                from: child,
                to: destination.appendingPathComponent(child.lastPathComponent),
                with: fileManager
            )
        }
    }

    func setPendingLaunch(_ spec: LaunchSpec) {
        pendingLaunch = spec
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
