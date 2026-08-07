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
}

@MainActor
final class AppModel {
    static let shared = AppModel()

    let profiles: ProfileStore
    let themes: ThemeStore

    /// Consume-once parameters for the next terminal session
    private var pendingLaunch: LaunchSpec?

    private init() {
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
