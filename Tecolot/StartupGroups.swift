import AppKit

/// The Startup selection uses stable live group IDs, including every window
/// imported from the previously selected Window Group template.
nonisolated enum StartupGroups {
    static func ids(defaults: UserDefaults = .standard) -> Set<UUID> {
        Set((defaults.stringArray(forKey: "startupGroupIDs") ?? []).compactMap(UUID.init(uuidString:)))
    }

    static func set(_ ids: Set<UUID>, orderedBy order: [UUID], defaults: UserDefaults = .standard) {
        defaults.set(order.filter(ids.contains).map(\.uuidString), forKey: "startupGroupIDs")
    }
}

extension TerminalWindowManager {
    /// Used only when restoration opened no window. Never-shown groups stay
    /// dormant unless the person explicitly chose them in Startup settings.
    func openStartupWindows(defaults: UserDefaults = .standard, openNewWindow: (LaunchSpec) -> Void) {
        if defaults.string(forKey: "startupMode") == "groups" {
            let chosen = StartupGroups.ids(defaults: defaults)
            let selected = groups.filter {
                chosen.contains($0.id)
            }
            if !selected.isEmpty {
                for group in selected {
                    showStartupGroup(group)
                }
                return
            }
        }
        if let group = mostRecentBackgroundGroup {
            showStartupGroup(group)
            return
        }
        var spec = LaunchSpec()
        spec.activate = false
        if defaults.string(forKey: "startupMode") == "profile" {
            spec.profileID = defaults.string(forKey: "startupProfileID").flatMap(UUID.init(uuidString:))
        }
        openNewWindow(spec)
    }

    /// Dock reopen uses only groups with a previous showing, independent of
    /// Startup settings. A never-shown imported template is not a fallback.
    func reopenWindow(openNewWindow: (LaunchSpec) -> Void) {
        if let group = mostRecentBackgroundGroup {
            navigate(to: group)
        } else {
            openNewWindow(LaunchSpec())
        }
    }

    private func showStartupGroup(_ group: TerminalTabGroup) {
        if let owner = openWindow(group: group) as? TerminalWindowController {
            owner.window?.orderFront(nil)
        }
    }
}
