import AppKit
import SwiftUI

struct GroupWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @State private var commandState = TerminalCommandState()
    @AppStorage(GlobalAppearanceSettings.showPaneHeadersKey) private var showPaneHeaders = true
    private var target: TerminalWindowCommandTarget? {
        _ = commandState.window
        return TerminalWindowCommandTarget.resolve(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow)
    }

    private var owner: TerminalWindowController? {
        target?.terminal
    }

    var body: some Commands {
        let _ = registerSessionBrowser()
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}
        CommandGroup(after: .newItem) {
            Divider()
            Button("Close") {
                if let owner {
                    owner.group.selectedTab?.loadedWorkspace?.focusedController?.requestClose()
                } else {
                    target?.window.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(target == nil)
            Button("Close Tab") {
                if let owner, let tab = owner.group.selectedTab {
                    owner.requestCloseTab(tab)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(owner == nil)
            Button("Close Window") {
                target?.window.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(target == nil)
            Button("Close Group") {
                owner?.requestCloseGroup()
            }
            .keyboardShortcut("w", modifiers: [.command, .option, .shift])
            .disabled(owner == nil)
            Button("Close Group and End Sessions") {
                owner?.requestCloseGroupAndEndSessions()
            }
            .disabled(owner == nil)
            Button("Duplicate Group") {
                if let owner {
                    TerminalWindowManager.shared.duplicate(owner.group)
                }
            }
            .disabled(owner == nil)
            Button("Rename Group…") {
                owner?.renameGroup()
            }
            .disabled(owner == nil)
        }
        CommandGroup(after: .toolbar) {
            Toggle("Show Pane Headers", isOn: $showPaneHeaders)
            Button("Toggle Tab Style") {
                SidebarPreferences.toggleStyle()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            Menu("Tab Style") {
                Button("Above") {
                    SidebarPreferences.setStyle(.above)
                }
                Button("Left Side") {
                    SidebarPreferences.setStyle(.left)
                }
                Button("Right Side") {
                    SidebarPreferences.setStyle(.right)
                }
            }
            Button("Toggle Sidebar") {
                owner?.toggleSidebar()
            }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(owner == nil)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Activity") {
                owner?.toggleActivity()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(owner == nil)
            Button("Go to Group…") {
                owner?.showGroups()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(owner == nil)
            Button("Previous Group") {
                if let owner {
                    TerminalWindowManager.shared.cycleGroup(-1, from: owner)
                }
            }
            .disabled(owner == nil)
            Button("Next Group") {
                if let owner {
                    TerminalWindowManager.shared.cycleGroup(1, from: owner)
                }
            }
            .disabled(owner == nil)
            Divider()
            Button("Previous Tab") {
                cycle(-1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(owner == nil)
            Button("Next Tab") {
                cycle(1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(owner == nil)
            Button("Select Previous Tab") {
                cycle(-1)
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(owner == nil)
            Button("Select Next Tab") {
                cycle(1)
            }
            .keyboardShortcut(.tab, modifiers: [.control])
            .disabled(owner == nil)
            Button("Move Tab Backward") {
                moveTab(-1)
            }
            .keyboardShortcut(.pageUp, modifiers: [.control, .shift])
            .disabled(owner == nil)
            Button("Move Tab Forward") {
                moveTab(1)
            }
            .keyboardShortcut(.pageDown, modifiers: [.control, .shift])
            .disabled(owner == nil)
            Button("Move Tab to New Window") {
                if let owner, let tab = owner.group.selectedTab {
                    owner.moveToNewWindow(tab)
                }
            }
            .disabled((owner?.group.tabs.count ?? 0) < 2)
            Button("Merge All Windows") {
                if let owner {
                    TerminalWindowManager.shared.mergeAllWindows(into: owner)
                }
            }
            .disabled(owner == nil)
        }
    }
    private func registerSessionBrowser() {
        SessionBrowserPresentation.open = {
            openWindow(id: SessionBrowserWindowID.value)
        }
    }
    private func moveTab(_ offset: Int) {
        if let owner, let tab = owner.group.selectedTab {
            owner.moveTab(tab, offset: offset)
        }
    }
    private func cycle(_ offset: Int) {
        if let owner {
            TerminalWindowManager.shared.cycleTab(offset, in: owner.group)
        }
    }
}
