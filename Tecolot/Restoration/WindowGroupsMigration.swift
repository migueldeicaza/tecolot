import Foundation
import TecolotSessionDirectory

extension RestoreStore {
    /// Imports templates into descriptions only. A failed import stays in the
    /// Window Groups recovery domain and is retried on the next launch.
    func migrateWindowGroups(in state: inout RestoreState) -> Bool {
        let source = directory.deletingLastPathComponent().appendingPathComponent("window-groups.json")
        let backups = directory.deletingLastPathComponent().appendingPathComponent("Backups")
        if state.windowGroupsMigrated {
            // Finish archiving if a previous launch stopped after committing.
            return archiveWindowGroups(source, backups: backups)
        }
        let result = VersionedFileLoader.load(
            from: source,
            domain: .windowGroups,
            backupRoot: backups,
            migrator: WindowGroupsMigrator(),
            rewritePolicy: .inMemoryOnly
        )
        if let issue = result.issue {
            issueCenter.report(issue)
            return false
        }
        var migrated = state
        var mappings: [UUID: [UUID]] = [:]
        for old in result.value ?? [] {
            var ids: [UUID] = []
            for (index, window) in old.windows.enumerated() where !window.tabs.isEmpty {
                let base = index == 0 ? old.name : "\(old.name) \(index + 1)"
                var name = base
                var suffix = 2
                while
                    migrated.groups.contains(where: {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame
                    }) {
                    name = "\(base) \(suffix)"
                    suffix += 1
                }
                let tabs = window.tabs.map { tab in
                    RestoreTab(root: .pane(RestorePane(
                        id: UUID(),
                        kind: .local,
                        profileID: tab.profileID,
                        themeOverride: tab.themeOverride,
                        directory: tab.workingDirectory.map {
                            PaneDirectory(path: $0, source: .osc7)
                        }
                    )))
                }
                let group = RestoreGroup(
                    name: name,
                    isNameCustom: true,
                    selectedTabIndex: min(max(window.selectedTabIndex, 0), tabs.count - 1),
                    tabs: tabs
                )
                migrated.groups.append(group)
                ids.append(group.id)
            }
            mappings[old.id] = ids
        }
        migrated.windowGroupsMigrated = true
        // Commit the IDs before archiving the source or changing preferences.
        guard writeLaunchState(migrated) else {
            return false
        }
        state = migrated
        if
            defaults.string(forKey: StartupGroups.startupModeKey) == "windowGroup",
            let oldID = defaults.string(forKey: StartupGroups.startupWindowGroupIDKey).flatMap(UUID.init(uuidString:)),
            let ids = mappings[oldID] {
            defaults.set(ids.map(\.uuidString), forKey: StartupGroups.startupGroupIDsKey)
            defaults.set("groups", forKey: StartupGroups.startupModeKey)
            defaults.removeObject(forKey: StartupGroups.startupWindowGroupIDKey)
        }
        return archiveWindowGroups(source, backups: backups)
    }

    private func archiveWindowGroups(_ source: URL, backups: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: source.path) else {
            return true
        }
        do {
            let version = try WindowGroupsMigrator().sourceVersion(in: Data(contentsOf: source))
            _ = try PersistenceBackups.createIfNeeded(
                for: source,
                domain: .windowGroups,
                sourceVersion: version,
                root: backups
            )
            try FileManager.default.removeItem(at: source)
            issueCenter.resolve(domain: .windowGroups, sourceURL: source)
            return true
        } catch {
            issueCenter.report(PersistenceIssue(
                domain: .windowGroups,
                sourceURL: source,
                kind: .backupFailed,
                message: error.localizedDescription
            ))
            return false
        }
    }

    /// Data Recovery can retry an import without restarting live groups.
    func retryWindowGroupsMigration() {
        guard isEnabled, isReady else {
            return
        }
        var state = capture(limit: 0).0
        guard migrateWindowGroups(in: &state) else {
            return
        }
        for saved in state.groups where !manager.groups.contains(where: {
            $0.id == saved.id
        }) {
            let tabs = saved.tabs.map {
                TerminalTab(dormant: Self.launchSpec(for: RestoredTab(tab: $0, panes: [:])))
            }
            let group = TerminalTabGroup(id: saved.id, name: saved.name, isNameCustom: saved.isNameCustom, tabs: tabs)
            group.selection = tabs[saved.selectedTabIndex].id
            manager.addRestoredGroup(group)
        }
        windowGroupsMigrated = state.windowGroupsMigrated
        stateDidChange(immediately: true)
    }
}
