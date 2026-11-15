//
//  AppModel.swift
//  Tecolot
//
//  Application-wide anchor for the profile and theme stores.
//
import Combine
import Foundation

/// Parameters for the next session to be created
nonisolated struct LaunchSpec {
    var profileID: TerminalProfile.ID?
    var workingDirectory: String?
    /// The SSH destination for a remote persistent session.
    var remoteDestination: String?
    var themeOverride: String?
    /// Run the shell in a persistent session (tecolot-sessiond) that keeps
    /// running when the pane closes or the app quits.
    var persistent = false
    /// Attach to this running persistent session instead of starting a shell.
    var attachSessionID: String?
    /// A saved tab to rebuild, with its splits (restore on relaunch).
    var restoredTab: RestoredTab?
    /// Bring the app to the front. The windows that open at launch set it
    /// to false: an app that starts in the background (after a log in, or
    /// opened by another app) must not take the focus. A launch from the
    /// Dock or Finder activates the app anyway.
    var activate = true
}

@MainActor
final class AppModel {
    static let shared = AppModel()

    let profiles: ProfileStore
    let themes: ThemeStore
    let themeIndex: ThemeCatalogIndex
    /// Selects the light or the dark theme of each profile.
    let systemAppearance = SystemAppearance()
    let issueCenter: PersistenceIssueCenter
    let recovery: DataRecoveryCoordinator
    private let preferences: PreferenceMigrator
    private var themeSubscription: AnyCancellable?
    private var paneSettingsObserver: PaneSettingsObserver?

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
        let themeIndex = ThemeCatalogIndex()
        self.themeIndex = themeIndex
        themeIndex.update(themes: themes.themes)
        // @Published emits on willSet, so use the emitted value, not the store
        themeSubscription = themes.$themes.sink { newThemes in
            themeIndex.update(themes: newThemes)
        }
        let preferences = PreferenceMigrator(
            applicationSupportDirectory: applicationSupport,
            backupDirectory: backups,
            issueCenter: issueCenter
        )
        self.preferences = preferences
        if let legacyMigrationIssue {
            issueCenter.report(legacyMigrationIssue)
        }
        preferences.migrate(profiles: profiles)
        recovery = DataRecoveryCoordinator(
            issueCenter: issueCenter,
            profiles: profiles,
            themes: themes,
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
        observePaneSettings()
    }

    /// Applies store edits to panes in both shown and background groups.
    private func observePaneSettings() {
        paneSettingsObserver = PaneSettingsObserver(
            profiles: profiles, themes: themes,
            appearanceChanges: systemAppearance.objectWillChange.eraseToAnyPublisher(),
            isDark: { [systemAppearance] in
                systemAppearance.isDark
            },
            registry: .shared, manager: .shared
        )
    }

    /// Copies the legacy store once. Do not merge it into an existing store,
    /// because both stores can contain a profile with the same name.
    private static func migrateLegacyApplicationSupport(
        to destination: URL,
        allowExistingEmptyDestination: Bool
    ) -> PersistenceIssue? {
        let fileManager = FileManager.default
        guard
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
            return nil
        }
        let source = applicationSupport.appendingPathComponent("com.tirania.MacTerminalUI")
        guard fileManager.fileExists(atPath: source.path) else {
            return nil
        }
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
        guard
            let enumerator = FileManager.default.enumerator(
                at: destination,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else {
            return false
        }
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
            if
                isDirectory,
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

    /// The profile a new session should use for a given spec
    func resolveProfile(for spec: LaunchSpec?) -> TerminalProfile {
        if let id = spec?.profileID, let profile = profiles.profile(withID: id) {
            return profile
        }
        return profiles.defaultProfile
    }
}

/// Delays willSet emissions until the stores contain their new values, once per turn.
@MainActor
final class PaneSettingsObserver {
    private let profiles: ProfileStore
    private let themes: ThemeStore
    private let isDark: () -> Bool
    private let registry: TerminalSessionRegistry
    private let manager: TerminalWindowManager
    private let applyProfile: @MainActor (TerminalSessionController, TerminalProfile) -> Void
    private let applyThemeColors: @MainActor (TerminalSessionController) -> Void
    private var previousThemes: [String: TerminalTheme]
    private var previousIsDark: Bool
    private var pending = false
    private var subscriptions: [AnyCancellable] = []

    init(
        profiles: ProfileStore, themes: ThemeStore,
        appearanceChanges: AnyPublisher<Void, Never>, isDark: @escaping () -> Bool,
        registry: TerminalSessionRegistry, manager: TerminalWindowManager,
        applyProfile: @escaping @MainActor (TerminalSessionController, TerminalProfile) -> Void = {
            $0.applyProfile($1)
        },
        applyThemeColors: @escaping @MainActor (TerminalSessionController) -> Void = {
            $0.applyThemeColors()
        }
    ) {
        self.profiles = profiles
        self.themes = themes
        self.isDark = isDark
        self.registry = registry
        self.manager = manager
        self.applyProfile = applyProfile
        self.applyThemeColors = applyThemeColors
        previousThemes = Self.index(themes.themes)
        previousIsDark = isDark()
        for publisher in [
            profiles.objectWillChange.eraseToAnyPublisher(),
            themes.objectWillChange.eraseToAnyPublisher(),
            appearanceChanges
        ] {
            publisher.sink { [weak self] in
                self?.scheduleUpdate()
            }.store(in: &subscriptions)
        }
    }

    private static func index(_ themes: [TerminalTheme]) -> [String: TerminalTheme] {
        Dictionary(themes.map {
            ($0.name, $0)
        }, uniquingKeysWith: { _, last in
            last
        })
    }

    private func scheduleUpdate() {
        guard !pending else {
            return
        }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.pending = false
            self.update()
        }
    }

    private func update() {
        let nextThemes = Self.index(themes.themes)
        let nextIsDark = isDark()
        let appearanceChanged = nextIsDark != previousIsDark
        var affected = Set<UUID>()
        for controller in registry.allControllers {
            if let profile = profiles.profile(withID: controller.profile.id), profile != controller.profile {
                applyProfile(controller, profile)
                affected.insert(controller.id)
            } else {
                let oldName = controller.themeOverride ?? controller.profile.themeName(isDark: previousIsDark)
                let newName = controller.themeOverride ?? controller.profile.themeName(isDark: nextIsDark)
                let oldTheme = previousThemes[oldName] ?? .fallback
                let newTheme = nextThemes[newName] ?? .fallback
                // Native colors/chrome may depend on appearance even with a fixed theme.
                if appearanceChanged || oldTheme != newTheme {
                    applyThemeColors(controller)
                    affected.insert(controller.id)
                }
            }
        }
        previousThemes = nextThemes
        previousIsDark = nextIsDark
        manager.refreshWindows(affectedControllers: affected, systemAppearanceChanged: appearanceChanged)
    }
}
