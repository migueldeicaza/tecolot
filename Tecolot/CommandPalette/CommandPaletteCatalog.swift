import AppKit
import Foundation
import Sparkle
import TecolotSessionClient

/// Builds commands, live navigation entries (groups, tabs, settings), and drill-down scopes.
@MainActor
final class CommandPaletteCatalog {
    struct Context {
        weak var owner: TerminalWindowController?
        let manager: TerminalWindowManager
        let appModel: AppModel
        let defaults: UserDefaults

        var activeGroup: TerminalTabGroup? {
            owner?.group
        }

        var activeTab: TerminalTab? {
            owner?.group.selectedTab
        }

        var activeWorkspace: TerminalPaneWorkspace? {
            activeTab?.loadedWorkspace
        }

        var activePane: TerminalSessionController? {
            activeWorkspace?.focusedController
        }
    }

    let context: Context

    init(
        owner: TerminalWindowController?,
        manager: TerminalWindowManager,
        appModel: AppModel = .shared,
        defaults: UserDefaults = .standard
    ) {
        context = Context(owner: owner, manager: manager, appModel: appModel, defaults: defaults)
    }

    // MARK: - Root: Live Entities

    func groupRows() -> [PaletteRow] {
        let currentGroup = context.activeGroup
        return context.manager.groups.map { group in
            let isCurrent = group === currentGroup
            return PaletteRow(
                id: "entity.group.\(group.id.uuidString)",
                section: "Groups",
                style: .standard(
                    title: group.name,
                    accessory: isCurrent ? .checkmark : .none
                ),
                keywords: [],
                isCommand: false,
                isDefaultSelection: isCurrent
            ) { [weak owner = context.owner, manager = context.manager, weak group] in
                guard let group else {
                    return .dismiss(restoreFocus: true)
                }
                if let owner {
                    manager.navigate(to: group, in: owner)
                } else {
                    manager.navigate(to: group)
                }
                return .dismiss(restoreFocus: false)
            }
        }
    }

    func tabRows() -> [PaletteRow] {
        let currentTabID = context.activeTab?.id
        let preferences = TabStripPreferences(defaults: context.defaults)
        let appearance = context.owner?.window?.effectiveAppearance
        let scale = context.owner?.window?.backingScaleFactor ?? 2
        let showActivity = ProgramActivitySettings.shared.value.showTabs

        var rows: [PaletteRow] = []
        for group in context.manager.groups {
            for tab in group.tabs {
                let isCurrent = tab.id == currentTabID && group === context.activeGroup
                let icon: PaletteIcon
                if let workspace = tab.loadedWorkspace {
                    icon = .image(TerminalTabIconStack.image(
                        workspace: workspace,
                        preferences: preferences,
                        selected: isCurrent,
                        appearance: appearance,
                        scale: scale,
                        showsProgress: tab.status.progress != nil && showActivity,
                        vertical: true
                    ))
                } else {
                    icon = .symbol("terminal")
                }
                rows.append(
                    PaletteRow(
                        id: "entity.tab.\(tab.id.uuidString)",
                        section: "Tabs",
                        style: .twoLine(
                            title: tab.title,
                            subtitle: group.name,
                            icon: icon,
                            accessory: isCurrent ? .checkmark : .none
                        ),
                        keywords: [],
                        isCommand: false,
                        isDefaultSelection: isCurrent
                    ) { [weak owner = context.owner, manager = context.manager, weak group, weak tab] in
                        guard let group, let tab else {
                            return .dismiss(restoreFocus: true)
                        }
                        if let owner {
                            manager.navigate(to: group, tab: tab, in: owner)
                        } else {
                            manager.navigate(to: group, tab: tab)
                        }
                        return .dismiss(restoreFocus: false)
                    }
                )
            }
        }
        return rows
    }

    func settingsRows(for query: String) -> [PaletteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            return []
        }
        let searchContext = SettingsSearchContext(
            profilesAreEmpty: context.appModel.profiles.profiles.isEmpty,
            updatesEnabled: UpdaterModel.shared.updatesEnabled
        )
        let results = SettingsSearchEngine.search(trimmed, context: searchContext).prefix(6)
        return results.map { result in
            let entry = result.entry
            return PaletteRow(
                id: "settings.\(entry.id)",
                section: "Settings",
                style: .twoLine(
                    title: entry.title,
                    subtitle: entry.breadcrumb,
                    icon: .symbol("gearshape"),
                    accessory: .none
                ),
                keywords: entry.keywords,
                isCommand: false
            ) {
                SettingsNavigator.shared.show(setting: entry.id)
                return .dismiss(restoreFocus: false)
            }
        }
    }

    // MARK: - Root: Commands

    func commandRows() -> [PaletteRow] {
        var rows: [PaletteRow] = []
        rows.append(contentsOf: sessionAndWindowCommands())
        rows.append(contentsOf: paneCommands())
        rows.append(contentsOf: appearanceCommands())
        rows.append(contentsOf: appCommands())
        return rows
    }

    private func sessionAndWindowCommands() -> [PaletteRow] {
        let owner = context.owner
        let manager = context.manager
        let activeTab = context.activeTab
        let activeGroup = context.activeGroup
        let activePane = context.activePane
        let isFullScreen = owner?.window?.styleMask.contains(.fullScreen) == true
        let hasMultipleTabs = (activeGroup?.tabs.count ?? 0) > 1
        let hasMultipleGroups = manager.groups.count > 1

        var rows: [PaletteRow] = []

        rows.append(PaletteRow(
            id: "cmd.group.change",
            section: nil,
            style: .standard(title: "Change Group…", accessory: .chevron(shortcut: "⌘K")),
            keywords: ["session", "switch", "workspace", "go to group"]
        ) {
            .push(.groupPicker)
        })

        if let activeGroup {
            rows.append(PaletteRow(
                id: "cmd.group.rename",
                section: nil,
                style: .standard(title: "Rename Group", accessory: .chevron()),
                keywords: ["session", "title", "name"]
            ) { [weak manager, weak activeGroup] in
                guard let activeGroup else {
                    return .dismiss()
                }
                return .push(.textInput(
                    title: "Rename Group",
                    placeholder: activeGroup.name,
                    initialText: "",
                    emptyActionTitle: nil,
                    submitActionPrefix: "Rename Group to",
                    onSubmit: { newName in
                        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            manager?.rename(activeGroup, to: cleaned)
                        }
                    },
                    onEmptyAction: nil
                ))
            })
        }

        if let activeTab {
            rows.append(PaletteRow(
                id: "cmd.tab.rename",
                section: nil,
                style: .standard(title: "Rename Tab", accessory: .chevron()),
                keywords: ["title", "name"]
            ) { [weak owner, weak activeTab] in
                guard let activeTab else {
                    return .dismiss()
                }
                return .push(.textInput(
                    title: "Rename Tab",
                    placeholder: activeTab.title,
                    initialText: "",
                    emptyActionTitle: "Restore Default Title",
                    submitActionPrefix: "Rename Tab to",
                    onSubmit: { newName in
                        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        activeTab.customName = cleaned.isEmpty ? nil : cleaned
                        owner?.tabNameDidChange()
                    },
                    onEmptyAction: {
                        activeTab.customName = nil
                        owner?.tabNameDidChange()
                    }
                ))
            })
        }

        rows.append(PaletteRow(
            id: "cmd.remote.connect",
            section: nil,
            style: .standard(title: "Connect to Remote Host…", accessory: .chevron(shortcut: "⇧⌥⌘T")),
            keywords: ["ssh", "remote", "server", "host", "add remote"]
        ) {
            .push(.sshHostPicker)
        })

        rows.append(PaletteRow(
            id: "cmd.group.new",
            section: nil,
            style: .standard(title: "New Group", accessory: .shortcut("⇧⌘N")),
            keywords: ["session", "workspace", "create"]
        ) { [weak owner] in
            if let owner {
                owner.newGroup()
            } else {
                WindowOpener.openWindow(spec: LaunchSpec())
            }
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.tab.new",
            section: nil,
            style: .standard(title: "New Tab", accessory: .shortcut("⌘T")),
            keywords: ["open", "create", "shell"]
        ) { [weak owner] in
            if let owner {
                owner.newTab()
            } else {
                WindowOpener.openTab(spec: WindowOpener.inheritedTabSpec())
            }
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.tab.newPersistent",
            section: nil,
            style: .standard(title: "New Persistent Tab", accessory: .shortcut("⌥⌘T")),
            keywords: ["session", "detach", "tmux", "helper"]
        ) { [weak owner] in
            var spec = WindowOpener.inheritedTabSpec()
            spec.persistent = true
            WindowOpener.openTab(spec: spec, targetWindow: owner?.window)
            return .dismiss(restoreFocus: false)
        })

        if activePane?.canChangeDirectory == true {
            rows.append(PaletteRow(
                id: "cmd.tab.goToDirectory",
                section: nil,
                style: .standard(title: "Go to Directory…", accessory: .chevron(shortcut: "⇧⌘G")),
                keywords: ["cd", "folder", "path", "open directory"]
            ) { [weak activePane] in
                .push(.directoryPicker(initialPath: activePane?.currentWorkingDirectory))
            })
        }

        rows.append(PaletteRow(
            id: "cmd.window.new",
            section: nil,
            style: .standard(title: "New Window", accessory: .shortcut("⌘N")),
            keywords: ["open", "create"]
        ) {
            WindowOpener.openWindow(spec: LaunchSpec())
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.window.newPersistent",
            section: nil,
            style: .standard(title: "New Persistent Window", accessory: .none),
            keywords: ["session", "helper"]
        ) {
            var spec = LaunchSpec()
            spec.persistent = true
            WindowOpener.openWindow(spec: spec)
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.session.attach",
            section: nil,
            style: .standard(title: "Attach to Session…", accessory: .none),
            keywords: ["sessions", "browser", "persistent", "reconnect"]
        ) {
            SessionBrowserPresentation.open?()
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.session.attachRemote",
            section: nil,
            style: .standard(title: "Attach to Remote Session…", accessory: .none),
            keywords: ["ssh", "sessions", "browser", "remote"]
        ) {
            SessionBrowserPresentation.open?()
            DispatchQueue.main.async {
                SessionBrowserModel.shared.connectToHost()
            }
            return .dismiss(restoreFocus: false)
        })

        if hasMultipleTabs {
            rows.append(PaletteRow(
                id: "cmd.tab.previous",
                section: nil,
                style: .standard(title: "Show Previous Tab", accessory: .shortcut("⌃⇧⇥")),
                keywords: ["switch", "cycle", "left"]
            ) { [weak activeGroup] in
                if let activeGroup {
                    manager.cycleTab(-1, in: activeGroup)
                }
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.tab.next",
                section: nil,
                style: .standard(title: "Show Next Tab", accessory: .shortcut("⌃⇥")),
                keywords: ["switch", "cycle", "right"]
            ) { [weak activeGroup] in
                if let activeGroup {
                    manager.cycleTab(1, in: activeGroup)
                }
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.tab.moveToNewWindow",
                section: nil,
                style: .standard(title: "Move Tab to New Window", accessory: .none),
                keywords: ["detach", "pop out", "split window"]
            ) { [weak owner, weak activeTab] in
                if let owner, let activeTab {
                    owner.moveToNewWindow(activeTab)
                }
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.tab.closeOthers",
                section: nil,
                style: .standard(title: "Close Other Tabs", accessory: .none),
                keywords: ["clean", "tabs"]
            ) { [weak owner, weak activeTab] in
                if let owner, let activeTab {
                    owner.closeOtherTabs(activeTab)
                }
                return .dismiss(restoreFocus: true)
            })
        }

        if let activeTab {
            rows.append(PaletteRow(
                id: "cmd.tab.moveToGroup",
                section: nil,
                style: .standard(title: "Move Tab to Group…", accessory: .chevron()),
                keywords: ["session", "organize"]
            ) {
                .push(.moveTabToGroup(tabID: activeTab.id))
            })

            rows.append(PaletteRow(
                id: "cmd.tab.mute",
                section: nil,
                style: .standard(title: activeTab.isMuted ? "Unmute Tab" : "Mute Tab", accessory: .none),
                keywords: ["bell", "sound", "notifications", "activity", "silence"]
            ) { [weak owner, weak activeTab] in
                activeTab?.isMuted.toggle()
                owner?.tabNameDidChange()
                return .dismiss(restoreFocus: true)
            })

            rows.append(PaletteRow(
                id: "cmd.tab.close",
                section: nil,
                style: .standard(title: "Close Tab", accessory: .shortcut("⌥⌘W")),
                keywords: ["kill", "exit"]
            ) { [weak owner, weak activeTab] in
                if let owner, let activeTab {
                    owner.requestCloseTab(activeTab)
                }
                return .dismiss(restoreFocus: false)
            })
        }

        if hasMultipleGroups {
            rows.append(PaletteRow(
                id: "cmd.group.previous",
                section: nil,
                style: .standard(title: "Previous Group", accessory: .none),
                keywords: ["session", "switch"]
            ) { [weak owner] in
                if let owner {
                    manager.cycleGroup(-1, from: owner)
                }
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.group.next",
                section: nil,
                style: .standard(title: "Next Group", accessory: .none),
                keywords: ["session", "switch"]
            ) { [weak owner] in
                if let owner {
                    manager.cycleGroup(1, from: owner)
                }
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.group.collapseOthers",
                section: nil,
                style: .standard(title: "Collapse Other Groups", accessory: .none),
                keywords: ["sidebar", "fold", "sessions"]
            ) { [weak activeGroup] in
                if let activeGroup {
                    manager.collapseOthers(activeGroup)
                }
                return .dismiss(restoreFocus: true)
            })
        }

        if let activeGroup {
            rows.append(PaletteRow(
                id: "cmd.group.duplicate",
                section: nil,
                style: .standard(title: "Duplicate Group", accessory: .none),
                keywords: ["clone", "copy", "session"]
            ) { [weak activeGroup] in
                if let activeGroup {
                    _ = manager.duplicate(activeGroup)
                }
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.group.close",
                section: nil,
                style: .standard(title: "Close Group", accessory: .shortcut("⇧⌥⌘W")),
                keywords: ["session"]
            ) { [weak owner] in
                owner?.requestCloseGroup()
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.group.closeAndEnd",
                section: nil,
                style: .standard(title: "Close Group and End Sessions", accessory: .none),
                keywords: ["terminate", "kill", "persistent"]
            ) { [weak owner] in
                owner?.requestCloseGroupAndEndSessions()
                return .dismiss(restoreFocus: false)
            })
        }

        if manager.windows.count > 1 {
            rows.append(PaletteRow(
                id: "cmd.window.mergeAll",
                section: nil,
                style: .standard(title: "Merge All Windows", accessory: .none),
                keywords: ["combine", "tabs"]
            ) { [weak owner] in
                if let owner {
                    manager.mergeAllWindows(into: owner)
                }
                return .dismiss(restoreFocus: false)
            })
        }

        if let dir = activePane?.titlebarWorkingDirectory {
            rows.append(PaletteRow(
                id: "cmd.tab.openInFinder",
                section: nil,
                style: .standard(title: "Open Directory in Finder", accessory: .none),
                keywords: ["reveal", "folder", "cwd", "finder"]
            ) {
                NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                return .dismiss(restoreFocus: false)
            })
        }

        rows.append(PaletteRow(
            id: "cmd.window.close",
            section: nil,
            style: .standard(title: "Close Window", accessory: .shortcut("⇧⌘W")),
            keywords: ["dismiss"]
        ) { [weak owner] in
            owner?.window?.performClose(nil)
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.window.fullScreen",
            section: nil,
            style: .standard(
                title: isFullScreen ? "Exit Full Screen" : "Enter Full Screen",
                accessory: .shortcut("⌃⌘F")
            ),
            keywords: ["fullscreen", "maximize", "zoom"]
        ) { [weak owner] in
            owner?.window?.toggleFullScreen(nil)
            return .dismiss(restoreFocus: true)
        })

        return rows
    }

    private func paneCommands() -> [PaletteRow] {
        guard let workspace = context.activeWorkspace, let pane = context.activePane else {
            return []
        }
        let owner = context.owner
        let hasMultiplePanes = workspace.paneCount > 1
        let isZoomed = workspace.zoomedControllerID != nil
        var rows: [PaletteRow] = []

        rows.append(PaletteRow(
            id: "cmd.pane.splitRight",
            section: "Pane",
            style: .standard(title: "Split Pane Right", accessory: .shortcut("⌘D")),
            keywords: ["vertical", "divide"]
        ) { [weak workspace, weak pane] in
            if let workspace, let pane {
                workspace.split(pane, direction: .right)
            }
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.splitDown",
            section: "Pane",
            style: .standard(title: "Split Pane Down", accessory: .shortcut("⇧⌘D")),
            keywords: ["horizontal", "divide", "below"]
        ) { [weak workspace, weak pane] in
            if let workspace, let pane {
                workspace.split(pane, direction: .down)
            }
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.splitLeft",
            section: "Pane",
            style: .standard(title: "Split Pane Left", accessory: .none),
            keywords: ["vertical", "divide"]
        ) { [weak workspace, weak pane] in
            if let workspace, let pane {
                workspace.split(pane, direction: .left)
            }
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.splitUp",
            section: "Pane",
            style: .standard(title: "Split Pane Up", accessory: .none),
            keywords: ["horizontal", "divide", "above"]
        ) { [weak workspace, weak pane] in
            if let workspace, let pane {
                workspace.split(pane, direction: .up)
            }
            return .dismiss(restoreFocus: false)
        })

        if hasMultiplePanes || isZoomed {
            rows.append(PaletteRow(
                id: "cmd.pane.zoom",
                section: "Pane",
                style: .standard(
                    title: isZoomed ? "Reset Split Zoom" : "Zoom Pane",
                    accessory: .shortcut("⇧⌘↩")
                ),
                keywords: ["maximize", "focus", "unzoom", "split"]
            ) { [weak workspace] in
                workspace?.toggleSplitZoom()
                return .dismiss(restoreFocus: true)
            })
        }

        if hasMultiplePanes {
            rows.append(PaletteRow(
                id: "cmd.pane.focusLeft",
                section: "Pane",
                style: .standard(title: "Focus Pane Left", accessory: .shortcut("⌥⌘←")),
                keywords: ["select", "split", "navigate"]
            ) { [weak workspace] in
                workspace?.selectSplit(in: .left)
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.pane.focusRight",
                section: "Pane",
                style: .standard(title: "Focus Pane Right", accessory: .shortcut("⌥⌘→")),
                keywords: ["select", "split", "navigate"]
            ) { [weak workspace] in
                workspace?.selectSplit(in: .right)
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.pane.focusUp",
                section: "Pane",
                style: .standard(title: "Focus Pane Up", accessory: .shortcut("⌥⌘↑")),
                keywords: ["select", "split", "above", "navigate"]
            ) { [weak workspace] in
                workspace?.selectSplit(in: .up)
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.pane.focusDown",
                section: "Pane",
                style: .standard(title: "Focus Pane Down", accessory: .shortcut("⌥⌘↓")),
                keywords: ["select", "split", "below", "navigate"]
            ) { [weak workspace] in
                workspace?.selectSplit(in: .down)
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.pane.focusPrevious",
                section: "Pane",
                style: .standard(title: "Focus Previous Pane", accessory: .shortcut("⌘[")),
                keywords: ["select", "split", "cycle"]
            ) { [weak workspace] in
                workspace?.selectPreviousSplit()
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.pane.focusNext",
                section: "Pane",
                style: .standard(title: "Focus Next Pane", accessory: .shortcut("⌘]")),
                keywords: ["select", "split", "cycle"]
            ) { [weak workspace] in
                workspace?.selectNextSplit()
                return .dismiss(restoreFocus: false)
            })

            rows.append(PaletteRow(
                id: "cmd.pane.equalize",
                section: "Pane",
                style: .standard(title: "Equalize Splits", accessory: .shortcut("⌃⌘=")),
                keywords: ["balance", "resize", "autobalance"]
            ) { [weak workspace] in
                workspace?.equalizeSplits()
                return .dismiss(restoreFocus: true)
            })
        }

        rows.append(PaletteRow(
            id: "cmd.pane.close",
            section: "Pane",
            style: .standard(title: "Close Pane", accessory: .shortcut("⌘W")),
            keywords: ["split", "close"]
        ) { [weak owner] in
            owner?.requestCloseSelectedPane()
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.find",
            section: "Pane",
            style: .standard(title: "Find…", accessory: .shortcut("⌘F")),
            keywords: ["search", "buffer", "scrollback"]
        ) { [weak pane] in
            pane?.performFind(.showFindInterface)
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.previousPrompt",
            section: "Pane",
            style: .standard(title: "Jump to Previous Prompt", accessory: .shortcut("⌘↑")),
            keywords: ["scroll", "command", "mark"]
        ) { [weak pane] in
            _ = pane?.scrollToPreviousPrompt()
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.nextPrompt",
            section: "Pane",
            style: .standard(title: "Jump to Next Prompt", accessory: .shortcut("⌘↓")),
            keywords: ["scroll", "command", "mark"]
        ) { [weak pane] in
            _ = pane?.scrollToNextPrompt()
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.pasteEscaped",
            section: "Pane",
            style: .standard(title: "Paste Escaped", accessory: .shortcut("⌃⌘V")),
            keywords: ["clipboard", "shell", "quote"]
        ) { [weak pane] in
            if let text = NSPasteboard.general.string(forType: .string) {
                let escaped = "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
                pane?.sendLiteralText(escaped)
            }
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.clear",
            section: "Pane",
            style: .standard(title: "Clear Terminal", accessory: .shortcut("⌃⌘K")),
            keywords: ["clear to start", "scrollback", "clean"]
        ) { [weak pane] in
            pane?.clearToStart()
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.softReset",
            section: "Pane",
            style: .standard(title: "Soft Reset Terminal", accessory: .none),
            keywords: ["reset", "decstr"]
        ) { [weak pane] in
            pane?.softReset()
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.hardReset",
            section: "Pane",
            style: .standard(title: "Hard Reset Terminal", accessory: .none),
            keywords: ["reset", "ris", "clear"]
        ) { [weak pane] in
            pane?.hardReset()
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.exportBuffer",
            section: "Pane",
            style: .standard(title: "Export Buffer…", accessory: .none),
            keywords: ["save", "scrollback", "text", "file"]
        ) { [weak pane] in
            pane?.exportBuffer()
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.exportSelection",
            section: "Pane",
            style: .standard(title: "Export Selection…", accessory: .none),
            keywords: ["save", "text", "file"]
        ) { [weak pane] in
            pane?.exportSelection()
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.print",
            section: "Pane",
            style: .standard(title: "Print…", accessory: .shortcut("⌘P")),
            keywords: ["pdf", "buffer"]
        ) { [weak pane] in
            pane?.printBuffer()
            return .dismiss(restoreFocus: false)
        })

        if pane.isPersistent {
            rows.append(PaletteRow(
                id: "cmd.pane.terminateSession",
                section: "Pane",
                style: .standard(title: "Terminate Session", accessory: .none),
                keywords: ["kill", "end", "persistent", "helper"]
            ) { [weak pane] in
                pane?.terminateSession()
                return .dismiss(restoreFocus: false)
            })
        }

        rows.append(PaletteRow(
            id: "cmd.pane.mouseReporting",
            section: "Pane",
            style: .standard(
                title: pane.allowMouseReporting ? "Disable Mouse Reporting" : "Enable Mouse Reporting",
                accessory: .shortcut("⌘R")
            ),
            keywords: ["mouse", "toggle"]
        ) { [weak pane] in
            pane?.allowMouseReporting.toggle()
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.optionAsMeta",
            section: "Pane",
            style: .standard(
                title: pane.optionAsMetaKey ? "Disable Option as Meta Key" : "Enable Option as Meta Key",
                accessory: .none
            ),
            keywords: ["alt", "keyboard", "meta"]
        ) { [weak pane] in
            pane?.optionAsMetaKey.toggle()
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.metalRenderer",
            section: "Pane",
            style: .standard(
                title: pane.useMetalRenderer ? "Disable Metal Renderer" : "Enable Metal Renderer",
                accessory: .none
            ),
            keywords: ["gpu", "render"]
        ) { [weak pane] in
            pane?.useMetalRenderer.toggle()
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.pane.secureInput",
            section: "Pane",
            style: .standard(
                title: SecureKeyboardEntry.shared.isEnabled ? "Disable Secure Keyboard Entry" : "Enable Secure Keyboard Entry",
                accessory: .none
            ),
            keywords: ["security", "password", "input"]
        ) {
            SecureKeyboardEntry.shared.isEnabled.toggle()
            return .dismiss(restoreFocus: true)
        })

        return rows
    }

    private func appearanceCommands() -> [PaletteRow] {
        let owner = context.owner
        let pane = context.activePane
        let defaults = context.defaults
        let appearance = GlobalAppearanceSettings(defaults: defaults)
        let sidebar = SidebarPreferences(defaults: defaults)
        let tabStrip = TabStripPreferences(defaults: defaults)
        let activity = ProgramActivityPreferences(defaults: defaults)
        var rows: [PaletteRow] = []

        if let pane {
            rows.append(PaletteRow(
                id: "cmd.appearance.theme",
                section: "Appearance",
                style: .standard(
                    title: "Change Theme",
                    accessory: .chevron(detail: pane.effectiveTheme.name, shortcut: nil)
                ),
                keywords: ["color", "scheme", "palette", "dark", "light"]
            ) { [weak pane] in
                guard let pane else {
                    return .dismiss()
                }
                return .push(.themePicker(originalThemeOverride: pane.themeOverride, controllerID: pane.id))
            })

            rows.append(PaletteRow(
                id: "cmd.profile.apply",
                section: "Appearance",
                style: .standard(
                    title: "Apply Profile to Window",
                    accessory: .chevron(detail: pane.profile.name)
                ),
                keywords: ["profile", "preset"]
            ) {
                .push(.profilePicker(mode: .applyToWindow))
            })
        }

        rows.append(PaletteRow(
            id: "cmd.profile.newTab",
            section: "Appearance",
            style: .standard(title: "New Tab with Profile…", accessory: .chevron()),
            keywords: ["profile", "tab"]
        ) {
            .push(.profilePicker(mode: .newTab))
        })

        rows.append(PaletteRow(
            id: "cmd.profile.newWindow",
            section: "Appearance",
            style: .standard(title: "New Window with Profile…", accessory: .chevron()),
            keywords: ["profile", "window"]
        ) {
            .push(.profilePicker(mode: .newWindow))
        })

        if let pane {
            rows.append(PaletteRow(
                id: "cmd.font.increase",
                section: "Appearance",
                style: .standard(title: "Increase Font Size", accessory: .shortcut("⌘+")),
                keywords: ["bigger", "zoom", "text", "larger"]
            ) { [weak pane] in
                pane?.biggerFont()
                return .dismiss(restoreFocus: true)
            })

            rows.append(PaletteRow(
                id: "cmd.font.decrease",
                section: "Appearance",
                style: .standard(title: "Decrease Font Size", accessory: .shortcut("⌘-")),
                keywords: ["smaller", "zoom", "text"]
            ) { [weak pane] in
                pane?.smallerFont()
                return .dismiss(restoreFocus: true)
            })

            rows.append(PaletteRow(
                id: "cmd.font.default",
                section: "Appearance",
                style: .standard(title: "Default Font Size", accessory: .shortcut("⌘0")),
                keywords: ["reset", "zoom", "text"]
            ) { [weak pane] in
                pane?.defaultFontSize()
                return .dismiss(restoreFocus: true)
            })

            let currentSizeText = pane.currentFontSize.map {
                "\(Int($0.rounded())) pt"
            }
            rows.append(PaletteRow(
                id: "cmd.font.setSize",
                section: "Appearance",
                style: .standard(
                    title: "Change Terminal Font Size",
                    accessory: .chevron(detail: currentSizeText)
                ),
                keywords: ["font", "size", "points", "text"]
            ) { [weak pane] in
                .push(.numericInput(
                    title: "Terminal Font Size",
                    rangeText: "8 pt–64 pt",
                    hint: "Type a terminal font size",
                    min: 8,
                    max: 64,
                    unit: "pt",
                    onSubmit: { value in
                        pane?.setFontSize(CGFloat(value))
                    }
                ))
            })
        }

        rows.append(PaletteRow(
            id: "cmd.appearance.padding",
            section: "Appearance",
            style: .standard(
                title: "Change Terminal Padding",
                accessory: .chevron(detail: appearance.terminalPadding.title)
            ),
            keywords: ["margin", "inset", "spacing"]
        ) { [defaults] in
            let current = GlobalAppearanceSettings(defaults: defaults).terminalPadding
            let options = GlobalAppearanceSettings.TerminalPadding.allCases.map { padding in
                PaletteEnumOption(
                    id: "padding.\(padding.rawValue)",
                    title: padding.title,
                    isSelected: padding == current
                ) {
                    defaults.set(padding.rawValue, forKey: GlobalAppearanceSettings.terminalPaddingKey)
                }
            }
            return .push(.enumPicker(title: "Terminal Padding", placeholder: "Select Terminal Padding…", options: options))
        })

        rows.append(PaletteRow(
            id: "cmd.appearance.backdrop",
            section: "Appearance",
            style: .standard(
                title: "Change Pane Backdrop",
                accessory: .chevron(detail: appearance.paneCardsBackdrop.title)
            ),
            keywords: ["background", "chrome", "gradient", "blur"]
        ) { [defaults] in
            let current = GlobalAppearanceSettings(defaults: defaults).paneCardsBackdrop
            let options = GlobalAppearanceSettings.Backdrop.allCases.map { backdrop in
                PaletteEnumOption(
                    id: "backdrop.\(backdrop.rawValue)",
                    title: backdrop.title,
                    isSelected: backdrop == current
                ) {
                    defaults.set(backdrop.rawValue, forKey: GlobalAppearanceSettings.paneCardsBackdropKey)
                }
            }
            return .push(.enumPicker(title: "Pane Backdrop", placeholder: "Select Pane Backdrop…", options: options))
        })

        rows.append(PaletteRow(
            id: "cmd.appearance.paneStyle.comfortable",
            section: "Appearance",
            style: .standard(
                title: "Comfortable Pane Style",
                accessory: appearance.paneStyle == .comfortable ? .checkmark : .none
            ),
            keywords: ["cards", "rounded", "spacing", "panes"]
        ) { [defaults] in
            defaults.set(GlobalAppearanceSettings.PaneStyle.comfortable.rawValue, forKey: GlobalAppearanceSettings.paneStyleKey)
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.appearance.paneStyle.compact",
            section: "Appearance",
            style: .standard(
                title: "Compact Pane Style",
                accessory: appearance.paneStyle == .compact ? .checkmark : .none
            ),
            keywords: ["dense", "panes"]
        ) { [defaults] in
            defaults.set(GlobalAppearanceSettings.PaneStyle.compact.rawValue, forKey: GlobalAppearanceSettings.paneStyleKey)
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.appearance.paneHeaders",
            section: "Appearance",
            style: .standard(
                title: appearance.paneCardsEnabled ? "Hide Pane Headers" : "Show Pane Headers",
                accessory: .none
            ),
            keywords: ["titlebar", "cards", "panes"]
        ) { [defaults] in
            let current = GlobalAppearanceSettings(defaults: defaults).paneCardsEnabled
            defaults.set(!current, forKey: GlobalAppearanceSettings.showPaneHeadersKey)
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.appearance.highlightActivePane",
            section: "Appearance",
            style: .standard(
                title: appearance.highlightActivePane ? "Hide Border on Active Pane" : "Highlight Active Pane",
                accessory: .none
            ),
            keywords: ["outline", "focus", "border", "active"]
        ) { [defaults] in
            let current = GlobalAppearanceSettings(defaults: defaults).highlightActivePane
            defaults.set(!current, forKey: GlobalAppearanceSettings.highlightActivePaneKey)
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.layout.tabsAbove",
            section: "Appearance",
            style: .standard(
                title: "Tabs Above",
                accessory: sidebar.style == .above ? .checkmark : .none
            ),
            keywords: ["horizontal", "tab bar", "top"]
        ) { [defaults] in
            SidebarPreferences.setStyle(.above, defaults: defaults)
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.layout.tabsLeft",
            section: "Appearance",
            style: .standard(
                title: "Tabs on Left Side",
                accessory: sidebar.style == .left ? .checkmark : .none
            ),
            keywords: ["vertical", "sidebar", "left"]
        ) { [defaults] in
            SidebarPreferences.setStyle(.left, defaults: defaults)
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.layout.tabsRight",
            section: "Appearance",
            style: .standard(
                title: "Tabs on Right Side",
                accessory: sidebar.style == .right ? .checkmark : .none
            ),
            keywords: ["vertical", "sidebar", "right"]
        ) { [defaults] in
            SidebarPreferences.setStyle(.right, defaults: defaults)
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.layout.toggleTabStyle",
            section: "Appearance",
            style: .standard(
                title: sidebar.style == .above ? "Switch to Vertical Tabs" : "Switch to Horizontal Tabs",
                accessory: .shortcut("⇧⌘S")
            ),
            keywords: ["tab style", "sidebar"]
        ) { [defaults] in
            SidebarPreferences.toggleStyle(defaults: defaults)
            return .dismiss(restoreFocus: true)
        })

        if sidebar.style != .above {
            rows.append(PaletteRow(
                id: "cmd.layout.toggleSidebar",
                section: "Appearance",
                style: .standard(
                    title: sidebar.hidden ? "Show Sidebar" : "Hide Sidebar",
                    accessory: .shortcut("⌘/")
                ),
                keywords: ["toggle", "tabs", "panel"]
            ) { [weak owner] in
                owner?.toggleSidebar()
                return .dismiss(restoreFocus: true)
            })

            rows.append(PaletteRow(
                id: "cmd.layout.focusTabFilter",
                section: "Appearance",
                style: .standard(title: "Focus Tab Filter", accessory: .none),
                keywords: ["sidebar", "filter", "search tabs"]
            ) { [weak owner] in
                owner?.focusSidebarFilter()
                return .dismiss(restoreFocus: false)
            })
        }

        let sidebarSizeLabel: String = {
            let stored = defaults.double(forKey: SidebarPreferences.textSizeKey)
            if stored <= 0 {
                return "System"
            }
            return "\(Int(stored)) pt"
        }()

        rows.append(PaletteRow(
            id: "cmd.appearance.sidebarTextSize",
            section: "Appearance",
            style: .standard(
                title: "Change Sidebar Text Size",
                accessory: .chevron(detail: sidebarSizeLabel)
            ),
            keywords: ["font", "sidebar", "size"]
        ) { [defaults] in
            let stored = defaults.double(forKey: SidebarPreferences.textSizeKey)
            let choices: [(String, Double)] = [
                ("System", 0),
                ("Small (11 pt)", 11),
                ("Medium (13 pt)", 13),
                ("Large (15 pt)", 15)
            ]
            let options = choices.map { label, value in
                PaletteEnumOption(
                    id: "sidebarSize.\(Int(value))",
                    title: label,
                    isSelected: Int(stored) == Int(value)
                ) {
                    defaults.set(value, forKey: SidebarPreferences.textSizeKey)
                }
            }
            return .push(.enumPicker(title: "Sidebar Text Size", placeholder: "Select Sidebar Text Size…", options: options))
        })

        rows.append(PaletteRow(
            id: "cmd.appearance.tabIconCount",
            section: "Appearance",
            style: .standard(
                title: "Change Tab Icon Count",
                accessory: .chevron(detail: "\(tabStrip.iconCount)")
            ),
            keywords: ["icons", "tabs", "programs"]
        ) { [defaults] in
            let current = TabStripPreferences(defaults: defaults).iconCount
            let options = (0...5).map { count in
                PaletteEnumOption(
                    id: "iconCount.\(count)",
                    title: count == 0 ? "None (0)" : "\(count)",
                    isSelected: count == current
                ) {
                    defaults.set(count, forKey: TabStripPreferences.iconCountKey)
                }
            }
            return .push(.enumPicker(title: "Tab Icon Count", placeholder: "Select Tab Icon Count…", options: options))
        })

        let colorModeLabel: String = {
            switch tabStrip.colorMode {
            case .always:
                "Always"
            case .activeTabs:
                "Active Tabs"
            case .activePanes:
                "Active Panes"
            case .never:
                "Never"
            }
        }()

        rows.append(PaletteRow(
            id: "cmd.appearance.tabIconColor",
            section: "Appearance",
            style: .standard(
                title: "Change Tab Icon Color",
                accessory: .chevron(detail: colorModeLabel)
            ),
            keywords: ["icons", "monochrome", "tabs"]
        ) { [defaults] in
            let current = TabStripPreferences(defaults: defaults).colorMode
            let pairs: [(TabStripPreferences.ColorMode, String)] = [
                (.always, "Always"),
                (.activeTabs, "Active Tabs"),
                (.activePanes, "Active Panes"),
                (.never, "Never")
            ]
            let options = pairs.map { mode, label in
                PaletteEnumOption(
                    id: "iconColor.\(mode.rawValue)",
                    title: label,
                    isSelected: mode == current
                ) {
                    defaults.set(mode.rawValue, forKey: TabStripPreferences.colorModeKey)
                }
            }
            return .push(.enumPicker(title: "Tab Icon Color", placeholder: "Select Tab Icon Color…", options: options))
        })

        rows.append(PaletteRow(
            id: "cmd.activity.toggle",
            section: "Appearance",
            style: .standard(title: "Show Activity", accessory: .shortcut("⌘.")),
            keywords: ["status", "notifications", "programs", "agents"]
        ) { [weak owner] in
            owner?.toggleActivity()
            return .dismiss(restoreFocus: false)
        })

        rows.append(PaletteRow(
            id: "cmd.activity.tabs",
            section: "Appearance",
            style: .standard(
                title: activity.showTabs ? "Hide Activity in Tabs" : "Show Activity in Tabs",
                accessory: .none
            ),
            keywords: ["badges", "status", "notifications"]
        ) { [defaults] in
            let current = ProgramActivityPreferences(defaults: defaults).showTabs
            defaults.set(!current, forKey: ProgramActivityPreferences.showTabsKey)
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.activity.notifications",
            section: "Appearance",
            style: .standard(
                title: activity.notifications ? "Hide System Notifications" : "Show System Notifications",
                accessory: .none
            ),
            keywords: ["alerts", "banners", "activity"]
        ) { [defaults] in
            let current = ProgramActivityPreferences(defaults: defaults).notifications
            defaults.set(!current, forKey: ProgramActivityPreferences.notificationsKey)
            return .dismiss(restoreFocus: true)
        })

        rows.append(PaletteRow(
            id: "cmd.activity.sounds",
            section: "Appearance",
            style: .standard(
                title: activity.sounds ? "Disable Activity Sounds" : "Enable Activity Sounds",
                accessory: .none
            ),
            keywords: ["audio", "bell", "chime"]
        ) { [defaults] in
            let current = ProgramActivityPreferences(defaults: defaults).sounds
            defaults.set(!current, forKey: ProgramActivityPreferences.soundsKey)
            return .dismiss(restoreFocus: true)
        })

        return rows
    }

    private func appCommands() -> [PaletteRow] {
        var rows: [PaletteRow] = []

        rows.append(PaletteRow(
            id: "cmd.app.settings",
            section: "App",
            style: .standard(title: "Settings…", accessory: .shortcut("⌘,")),
            keywords: ["preferences", "config", "options"]
        ) {
            SettingsNavigator.shared.show(.general)
            return .dismiss(restoreFocus: false)
        })

        if UpdaterModel.shared.updatesEnabled {
            rows.append(PaletteRow(
                id: "cmd.app.updates",
                section: "App",
                style: .standard(
                    title: "Check for Updates…",
                    accessory: UpdaterModel.shared.canCheckForUpdates ? .none : .status("Checking…")
                ),
                keywords: ["sparkle", "upgrade", "version"]
            ) {
                if UpdaterModel.shared.canCheckForUpdates {
                    UpdaterModel.shared.controller.checkForUpdates(nil)
                }
                return .dismiss(restoreFocus: false)
            })
        }

        rows.append(PaletteRow(
            id: "cmd.app.about",
            section: "App",
            style: .standard(title: "About Tecolot", accessory: .none),
            keywords: ["version", "info"]
        ) {
            NSApp.orderFrontStandardAboutPanel(nil)
            return .dismiss(restoreFocus: false)
        })

        return rows
    }

    // MARK: - Sub-View Scopes

    func rows(for scope: PaletteScope, query: String) -> (items: [PaletteDisplayItem], autoSelectID: String?) {
        switch scope {
        case .root, .directoryPicker:
            return ([], nil) // Root and async directory listing are assembled by CommandPaletteModel.
        case .groupPicker:
            return groupPickerItems(query: query)
        case .moveTabToGroup(let tabID):
            return moveTabItems(tabID: tabID, query: query)
        case .themePicker(_, let controllerID):
            return themePickerItems(controllerID: controllerID, query: query)
        case .profilePicker(let mode):
            return profilePickerItems(mode: mode, query: query)
        case .enumPicker(_, _, let options):
            return enumPickerItems(options: options, query: query)
        case .textInput(_, _, _, let emptyActionTitle, let submitPrefix, let onSubmit, let onEmptyAction):
            return textInputItems(
                query: query,
                emptyActionTitle: emptyActionTitle,
                submitPrefix: submitPrefix,
                onSubmit: onSubmit,
                onEmptyAction: onEmptyAction
            )
        case .numericInput(let title, _, let hint, let minVal, let maxVal, let unit, let onSubmit):
            return numericInputItems(
                title: title,
                hint: hint,
                min: minVal,
                max: maxVal,
                unit: unit,
                query: query,
                onSubmit: onSubmit
            )
        case .sshHostPicker:
            return sshHostPickerItems(query: query)
        }
    }

    private func groupPickerItems(query: String) -> ([PaletteDisplayItem], String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = context.activeGroup
        let allGroups = context.manager.groups

        var matchedRows: [(score: Int, row: PaletteRow)] = []
        for group in allGroups {
            let isCurrent = group === current
            let match = CommandPaletteSearch.match(query: trimmed, title: group.name)
            guard trimmed.isEmpty || match != nil else {
                continue
            }
            let row = PaletteRow(
                id: "scope.group.\(group.id.uuidString)",
                style: .standard(title: group.name, accessory: isCurrent ? .checkmark : .none),
                isCommand: false,
                isDefaultSelection: isCurrent,
                matchRanges: match?.titleRanges ?? []
            ) { [weak owner = context.owner, manager = context.manager, weak group] in
                if let group {
                    if let owner {
                        manager.navigate(to: group, in: owner)
                    } else {
                        manager.navigate(to: group)
                    }
                }
                return .dismiss(restoreFocus: false)
            }
            matchedRows.append((match?.score ?? 0, row))
        }

        if !trimmed.isEmpty {
            matchedRows.sort {
                $0.score > $1.score
            }
        }

        var items: [PaletteDisplayItem] = matchedRows.map {
            .row($0.row)
        }
        let hasExact = allGroups.contains {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }

        if !items.isEmpty {
            items.append(.divider)
        }

        if trimmed.isEmpty {
            items.append(.row(PaletteRow(
                id: "scope.group.new",
                style: .standard(title: "New Group", accessory: .shortcut("⇧⌘N")),
                isCommand: false
            ) { [weak owner = context.owner] in
                if let owner {
                    owner.newGroup()
                } else {
                    WindowOpener.openWindow(spec: LaunchSpec())
                }
                return .dismiss(restoreFocus: false)
            }))
        } else if !hasExact {
            items.append(.row(PaletteRow(
                id: "scope.group.create",
                style: .standard(title: "Create Group \"\(trimmed)\"", accessory: .returnGlyph),
                isCommand: false
            ) { [weak owner = context.owner, manager = context.manager] in
                let created: TerminalTabGroup
                if let owner {
                    created = manager.newGroup(in: owner)
                    owner.activate()
                } else {
                    created = manager.newGroup()
                    _ = manager.openWindow(group: created)
                }
                manager.rename(created, to: trimmed)
                return .dismiss(restoreFocus: false)
            }))
        }

        let autoSelectID = trimmed.isEmpty ? current.map {
            "scope.group.\($0.id.uuidString)"
        } : items.first(where: \.isSelectable)?.row?.id
        return (items, autoSelectID)
    }

    private func moveTabItems(tabID: UUID, query: String) -> ([PaletteDisplayItem], String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let sourceGroup = context.manager.groups.first(where: {
                $0.tabs.contains {
                    $0.id == tabID
                }
            }),
            let tab = sourceGroup.tabs.first(where: {
                $0.id == tabID
            }) else {
            return ([.hint("Tab is no longer open")], nil)
        }

        var items: [PaletteDisplayItem] = []
        let targets = context.manager.groups.filter {
            $0 !== sourceGroup
        }
        for group in targets {
            let match = CommandPaletteSearch.match(query: trimmed, title: group.name)
            guard trimmed.isEmpty || match != nil else {
                continue
            }
            items.append(.row(PaletteRow(
                id: "move.group.\(group.id.uuidString)",
                style: .standard(title: group.name, accessory: .none),
                isCommand: false,
                matchRanges: match?.titleRanges ?? []
            ) { [manager = context.manager, weak tab, weak sourceGroup, weak group] in
                if let tab, let sourceGroup, let group {
                    manager.move(tab, from: sourceGroup, to: group)
                }
                return .dismiss(restoreFocus: false)
            }))
        }

        if !items.isEmpty {
            items.append(.divider)
        }
        items.append(.row(PaletteRow(
            id: "move.group.new",
            style: .standard(
                title: trimmed.isEmpty ? "Move to New Group" : "Move to New Group \"\(trimmed)\"",
                accessory: .returnGlyph
            ),
            isCommand: false
        ) { [manager = context.manager, weak tab] in
            if let tab {
                manager.moveToNewGroup(tab)
                if !trimmed.isEmpty, let dest = tab.group {
                    manager.rename(dest, to: trimmed)
                }
            }
            return .dismiss(restoreFocus: false)
        }))
        return (items, items.first(where: \.isSelectable)?.row?.id)
    }

    private func themePickerItems(controllerID: UUID, query: String) -> ([PaletteDisplayItem], String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let themeStore = context.appModel.themes
        let pane = context.activeWorkspace?.controllers.first {
            $0.id == controllerID
        } ?? context.activePane
        let activeName = pane?.effectiveTheme.name
        let hasOverride = pane?.themeOverride != nil

        let favorites = themeStore.themes.filter {
            themeStore.favorites.contains($0.name)
        }
        let builtIn = themeStore.themes.filter {
            $0.isBuiltIn && !themeStore.favorites.contains($0.name)
        }
        let userThemes = themeStore.themes.filter {
            !$0.isBuiltIn && !themeStore.favorites.contains($0.name)
        }

        func makeRow(_ theme: TerminalTheme, section: String?) -> (score: Int, row: PaletteRow)? {
            let match = CommandPaletteSearch.match(query: trimmed, title: theme.name)
            guard trimmed.isEmpty || match != nil else {
                return nil
            }
            let isCurrent = theme.name == activeName
            let row = PaletteRow(
                id: "theme.\(theme.name)",
                section: section,
                style: .standard(title: theme.name, accessory: isCurrent ? .checkmark : .none),
                isCommand: false,
                isDefaultSelection: isCurrent,
                matchRanges: match?.titleRanges ?? [],
                onPreview: { [weak pane] in
                    pane?.applyThemeOverride(theme.name)
                }
            ) { [weak pane] in
                pane?.applyThemeOverride(theme.name)
                return .dismiss(restoreFocus: true)
            }
            return (match?.score ?? 0, row)
        }

        var items: [PaletteDisplayItem] = []

        if hasOverride, trimmed.isEmpty || CommandPaletteSearch.match(query: trimmed, title: "Reset to Profile Theme") != nil {
            let match = CommandPaletteSearch.match(query: trimmed, title: "Reset to Profile Theme")
            items.append(.row(PaletteRow(
                id: "theme.reset",
                style: .standard(title: "Reset to Profile Theme", accessory: .none),
                isCommand: false,
                matchRanges: match?.titleRanges ?? [],
                onPreview: { [weak pane] in
                    pane?.applyThemeOverride(nil)
                }
            ) { [weak pane] in
                pane?.applyThemeOverride(nil)
                return .dismiss(restoreFocus: true)
            }))
        }

        func appendSection(_ title: String?, themes: [TerminalTheme]) {
            var matched = themes.compactMap {
                makeRow($0, section: title)
            }
            guard !matched.isEmpty else {
                return
            }
            if !trimmed.isEmpty {
                matched.sort {
                    $0.score > $1.score
                }
            }
            if let title {
                items.append(.sectionHeader(title))
            }
            items.append(contentsOf: matched.map {
                .row($0.row)
            })
        }

        appendSection("Favorites", themes: favorites)
        appendSection(favorites.isEmpty ? nil : "Built-in", themes: builtIn)
        appendSection("User themes", themes: userThemes)

        if items.isEmpty {
            return ([.hint("No Results")], nil)
        }
        let autoSelectID = trimmed.isEmpty ? activeName.map {
            "theme.\($0)"
        } : items.first(where: \.isSelectable)?.row?.id
        return (items, autoSelectID)
    }

    private func profilePickerItems(mode: PaletteProfilePickerMode, query: String) -> ([PaletteDisplayItem], String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let profiles = context.appModel.profiles.profiles
        let activeProfileID = context.activePane?.profile.id ?? context.appModel.profiles.defaultProfileID

        var matched: [(score: Int, row: PaletteRow)] = []
        for profile in profiles {
            let match = CommandPaletteSearch.match(query: trimmed, title: profile.name)
            guard trimmed.isEmpty || match != nil else {
                continue
            }
            let isCurrent = profile.id == activeProfileID
            let row = PaletteRow(
                id: "profile.\(profile.id.uuidString)",
                style: .standard(title: profile.name, accessory: isCurrent ? .checkmark : .none),
                isCommand: false,
                isDefaultSelection: isCurrent,
                matchRanges: match?.titleRanges ?? []
            ) { [weak owner = context.owner, weak pane = context.activePane] in
                switch mode {
                case .applyToWindow:
                    pane?.applyProfile(profile)
                    return .dismiss(restoreFocus: true)
                case .newTab:
                    var spec = WindowOpener.inheritedTabSpec()
                    spec.profileID = profile.id
                    WindowOpener.openTab(spec: spec, targetWindow: owner?.window)
                    return .dismiss(restoreFocus: false)
                case .newWindow:
                    WindowOpener.openWindow(spec: LaunchSpec(profileID: profile.id))
                    return .dismiss(restoreFocus: false)
                }
            }
            matched.append((match?.score ?? 0, row))
        }

        if !trimmed.isEmpty {
            matched.sort {
                $0.score > $1.score
            }
        }
        if matched.isEmpty {
            return ([.hint("No Results")], nil)
        }
        let items = matched.map {
            PaletteDisplayItem.row($0.row)
        }
        let autoSelectID = trimmed.isEmpty ? "profile.\(activeProfileID.uuidString)" : matched.first?.row.id
        return (items, autoSelectID)
    }

    private func enumPickerItems(options: [PaletteEnumOption], query: String) -> ([PaletteDisplayItem], String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var matched: [(score: Int, row: PaletteRow)] = []
        for option in options {
            let match = CommandPaletteSearch.match(query: trimmed, title: option.title, keywords: option.keywords)
            guard trimmed.isEmpty || match != nil else {
                continue
            }
            let row = PaletteRow(
                id: option.id,
                style: .standard(title: option.title, accessory: option.isSelected ? .checkmark : .none),
                isCommand: false,
                isDefaultSelection: option.isSelected,
                matchRanges: match?.titleRanges ?? []
            ) {
                option.onSelect()
                return .dismiss(restoreFocus: true)
            }
            matched.append((match?.score ?? 0, row))
        }
        if !trimmed.isEmpty {
            matched.sort {
                $0.score > $1.score
            }
        }
        if matched.isEmpty {
            return ([.hint("No Results")], nil)
        }
        let items = matched.map {
            PaletteDisplayItem.row($0.row)
        }
        let defaultID = options.first(where: \.isSelected)?.id
        let autoSelectID = trimmed.isEmpty ? defaultID : matched.first?.row.id
        return (items, autoSelectID)
    }

    private func textInputItems(
        query: String,
        emptyActionTitle: String?,
        submitPrefix: String,
        onSubmit: @escaping @MainActor (String) -> Void,
        onEmptyAction: (@MainActor () -> Void)?
    ) -> ([PaletteDisplayItem], String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let emptyActionTitle, let onEmptyAction {
                let row = PaletteRow(
                    id: "textInput.emptyAction",
                    style: .standard(title: emptyActionTitle, accessory: .returnGlyph),
                    isCommand: false
                ) {
                    onEmptyAction()
                    return .dismiss(restoreFocus: true)
                }
                return ([.row(row)], row.id)
            }
            return ([.hint("Type a new name and press Return")], nil)
        }
        let row = PaletteRow(
            id: "textInput.submit",
            style: .standard(title: "\(submitPrefix) \"\(trimmed)\"", accessory: .returnGlyph),
            isCommand: false
        ) {
            onSubmit(trimmed)
            return .dismiss(restoreFocus: true)
        }
        return ([.row(row)], row.id)
    }

    private func numericInputItems(
        title: String,
        hint: String,
        min minVal: Double,
        max maxVal: Double,
        unit: String,
        query: String,
        onSubmit: @escaping @MainActor (Double) -> Void
    ) -> ([PaletteDisplayItem], String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: unit, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ([.hint(hint)], nil)
        }
        guard let value = Double(trimmed), value.isFinite, value >= minVal, value <= maxVal else {
            return ([.hint("Enter a value between \(Int(minVal)) and \(Int(maxVal)) \(unit)")], nil)
        }
        let formatted = value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))" : String(format: "%.1f", value)
        let row = PaletteRow(
            id: "numeric.submit",
            style: .standard(title: "Set \(title) to \(formatted) \(unit)", accessory: .returnGlyph),
            isCommand: false
        ) {
            onSubmit(value)
            return .dismiss(restoreFocus: true)
        }
        return ([.row(row)], row.id)
    }

    nonisolated struct ResolvedDirectoryQuery: Equatable {
        let searchDir: String
        let filterPrefix: String
        let canonicalCurrent: String
    }

    nonisolated struct DirectoryEntry: Equatable {
        let id: String
        let title: String
        let fullPath: String
        let completionText: String
        let isCurrent: Bool
    }

    private var iconCache: [String: NSImage] = [:]

    private func cachedFileIcon(forPath path: String) -> NSImage {
        if let existing = iconCache[path] {
            return existing
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    /// Resolves absolute, tilde, or relative directory queries against the pane's working directory.
    nonisolated static func resolveDirectoryQuery(
        _ query: String,
        baseDirectory: String?
    ) -> ResolvedDirectoryQuery {
        let normalizedBase = normalizedDirectoryPath(baseDirectory)
        let raw = query.isEmpty ? normalizedBase : query
        let hadTrailingSlash = raw.hasSuffix("/")

        let expandedBase: String
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            expandedBase = (raw as NSString).expandingTildeInPath
        } else {
            let base = normalizedBase.count > 1 && normalizedBase.hasSuffix("/")
                ? String(normalizedBase.dropLast())
                : normalizedBase
            expandedBase = ((base as NSString).appendingPathComponent(raw) as NSString).standardizingPath
        }

        let expanded = hadTrailingSlash && !expandedBase.hasSuffix("/")
            ? expandedBase + "/"
            : expandedBase

        let searchDir: String
        let filterPrefix: String
        if expanded.hasSuffix("/") {
            searchDir = expanded
            filterPrefix = ""
        } else {
            let url = URL(fileURLWithPath: expanded)
            searchDir = url.deletingLastPathComponent().path
            filterPrefix = url.lastPathComponent
        }

        let canonicalCurrent = expanded.count > 1 && expanded.hasSuffix("/")
            ? String(expanded.dropLast())
            : expanded

        return ResolvedDirectoryQuery(
            searchDir: searchDir,
            filterPrefix: filterPrefix,
            canonicalCurrent: canonicalCurrent
        )
    }

    /// Runs off the main thread: filters filenames BEFORE stat-ing (`fileExists`) to avoid beachballing on large directories.
    nonisolated static func listDirectories(
        resolved: ResolvedDirectoryQuery,
        cachedNames: [String]?,
        limit: Int = 60
    ) -> (entries: [DirectoryEntry], allNames: [String]) {
        let fm = FileManager.default
        var entries: [DirectoryEntry] = []

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: resolved.canonicalCurrent, isDirectory: &isDir), isDir.boolValue {
            let displayName = URL(fileURLWithPath: resolved.canonicalCurrent).lastPathComponent
            let label = displayName.isEmpty ? "/" : displayName
            let completion = resolved.canonicalCurrent.hasSuffix("/")
                ? resolved.canonicalCurrent
                : resolved.canonicalCurrent + "/"
            entries.append(DirectoryEntry(
                id: "dir.current.\(resolved.canonicalCurrent)",
                title: label,
                fullPath: resolved.canonicalCurrent,
                completionText: completion,
                isCurrent: true
            ))
        }

        let allNames = cachedNames ?? ((try? fm.contentsOfDirectory(atPath: resolved.searchDir)) ?? [])
        let showHidden = resolved.filterPrefix.hasPrefix(".")

        // Filter by name BEFORE calling fileExists so huge directories don't stat thousands of unmatched files.
        var matchedNames: [(name: String, score: Int)] = []
        matchedNames.reserveCapacity(min(allNames.count, limit * 2))
        for name in allNames {
            guard showHidden || !name.hasPrefix(".") else {
                continue
            }
            if resolved.filterPrefix.isEmpty {
                matchedNames.append((name, 0))
            } else if let match = CommandPaletteSearch.match(query: resolved.filterPrefix, title: name) {
                matchedNames.append((name, match.score))
            }
        }

        if resolved.filterPrefix.isEmpty {
            matchedNames.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } else {
            matchedNames.sort { lhs, rhs in
                lhs.score != rhs.score
                    ? lhs.score > rhs.score
                    : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }

        for item in matchedNames {
            if entries.count >= limit {
                break
            }
            let fullPath = (resolved.searchDir as NSString).appendingPathComponent(item.name)
            if fullPath == resolved.canonicalCurrent {
                continue
            }
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &childIsDir), childIsDir.boolValue else {
                continue
            }
            let completion = fullPath.hasSuffix("/") ? fullPath : fullPath + "/"
            entries.append(DirectoryEntry(
                id: "dir.entry.\(fullPath)",
                title: item.name,
                fullPath: fullPath,
                completionText: completion,
                isCurrent: false
            ))
        }

        return (entries, allNames)
    }

    func makeDirectoryPickerItems(
        entries: [DirectoryEntry],
        filterPrefix: String
    ) -> ([PaletteDisplayItem], String?) {
        let pane = context.activePane
        guard pane?.canChangeDirectory != false else {
            return ([.hint("Go to Directory is only available at a local shell prompt")], nil)
        }
        guard !entries.isEmpty else {
            return ([.hint("No matching directories")], nil)
        }
        let rows: [PaletteRow] = entries.map { entry in
            let matchRanges = (!entry.isCurrent && !filterPrefix.isEmpty)
                ? (CommandPaletteSearch.match(query: filterPrefix, title: entry.title)?.titleRanges ?? [])
                : []
            return PaletteRow(
                id: entry.id,
                section: "Go to",
                style: .standard(
                    title: entry.title,
                    icon: .image(cachedFileIcon(forPath: entry.fullPath)),
                    accessory: .none
                ),
                isCommand: false,
                completionText: entry.completionText,
                matchRanges: matchRanges
            ) { [weak pane] in
                Self.sendChangeDirectory(entry.fullPath, to: pane)
                return .dismiss(restoreFocus: true)
            }
        }
        var items: [PaletteDisplayItem] = [.sectionHeader("Go to")]
        items.append(contentsOf: rows.map {
            .row($0)
        })
        return (items, rows.first?.id)
    }

    private func sshHostPickerItems(query: String) -> ([PaletteDisplayItem], String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let recentStore = RecentRemoteDestinations(defaults: context.defaults)
        let recents = recentStore.destinations
        let recentSet = Set(recents)
        let aliases = ((try? SSHHostAliases.list()) ?? []).filter {
            !recentSet.contains($0)
        }

        func connect(_ destination: String) -> PaletteOutcome {
            recentStore.record(destination)
            var spec = LaunchSpec()
            spec.remoteDestination = destination
            spec.persistent = true
            WindowOpener.openTab(spec: spec, targetWindow: context.owner?.window)
            return .dismiss(restoreFocus: false)
        }

        var items: [PaletteDisplayItem] = []

        if
            !trimmed.isEmpty, (try? SSHConfiguration.validate(trimmed)) != nil,
            !recents.contains(trimmed), !aliases.contains(trimmed) {
            items.append(.row(PaletteRow(
                id: "ssh.typed.\(trimmed)",
                style: .standard(
                    title: "Connect to \(trimmed)",
                    icon: .symbol("network"),
                    accessory: .returnGlyph
                ),
                isCommand: false
            ) {
                connect(trimmed)
            }))
        }

        let matchedRecents: [PaletteRow] = recents.compactMap { dest in
            let match = CommandPaletteSearch.match(query: trimmed, title: dest)
            guard trimmed.isEmpty || match != nil else {
                return nil
            }
            return PaletteRow(
                id: "ssh.recent.\(dest)",
                style: .standard(
                    title: dest,
                    icon: .symbol("clock"),
                    accessory: .none
                ),
                isCommand: false,
                completionText: dest,
                matchRanges: match?.titleRanges ?? []
            ) {
                connect(dest)
            }
        }
        if !matchedRecents.isEmpty {
            items.append(.sectionHeader("Recent"))
            items.append(contentsOf: matchedRecents.map {
                .row($0)
            })
        }

        let matchedAliases: [PaletteRow] = aliases.compactMap { alias in
            let match = CommandPaletteSearch.match(query: trimmed, title: alias)
            guard trimmed.isEmpty || match != nil else {
                return nil
            }
            return PaletteRow(
                id: "ssh.alias.\(alias)",
                style: .standard(
                    title: alias,
                    icon: .symbol("server.rack"),
                    accessory: .none
                ),
                isCommand: false,
                completionText: alias,
                matchRanges: match?.titleRanges ?? []
            ) {
                connect(alias)
            }
        }
        if !matchedAliases.isEmpty {
            items.append(.sectionHeader("SSH Config"))
            items.append(contentsOf: matchedAliases.map {
                .row($0)
            })
        }

        if items.isEmpty {
            return ([.hint("Type user@host to connect")], nil)
        }
        return (items, items.first(where: \.isSelectable)?.row?.id)
    }

    nonisolated static func normalizedDirectoryPath(_ path: String?) -> String {
        let base = (path?.isEmpty == false ? path! : NSHomeDirectory())
        return base.hasSuffix("/") ? base : base + "/"
    }

    nonisolated static func formattedChangeDirectoryCommand(for path: String) -> String {
        let escaped = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Ctrl-E + Ctrl-U clears any partially typed shell input before issuing cd.
        return "\u{05}\u{15}cd \(escaped)\r"
    }

    private static func sendChangeDirectory(_ path: String, to pane: TerminalSessionController?) {
        guard let pane, pane.canChangeDirectory else {
            return
        }
        pane.sendLiteralText(formattedChangeDirectoryCommand(for: path))
    }
}
