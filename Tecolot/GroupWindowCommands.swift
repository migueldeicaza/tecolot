import AppKit
import SwiftUI

struct GroupWindowCommands: Commands {
    @State private var commandState = TerminalCommandState()
    @State private var shortcuts = AppShortcutStore.shared
    @AppStorage(GlobalAppearanceSettings.showPaneHeadersKey) private var showPaneHeaders = GlobalAppearanceSettings.showPaneHeadersDefault
    private var target: TerminalWindowCommandTarget? {
        _ = commandState.window
        return TerminalWindowCommandTarget.resolve(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow)
    }

    private var owner: TerminalWindowController? {
        target?.terminal
    }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Command Palette…") {
                owner?.toggleCommandPalette()
            }
            .appShortcut(.commandPalette, store: shortcuts)
            .disabled(owner == nil)
            Divider()
            Toggle("Show Pane Headers", isOn: $showPaneHeaders)
                .appShortcut(.showPaneHeaders, store: shortcuts)
            Button("Toggle Tab Style") {
                SidebarPreferences.toggleStyle()
            }
            .appShortcut(.toggleTabStyle, store: shortcuts)
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
            .appShortcut(.toggleSidebar, store: shortcuts)
            .disabled(owner == nil)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Activity") {
                owner?.toggleActivity()
            }
            .appShortcut(.activity, store: shortcuts)
            .disabled(owner == nil)
            Button("Go to Group…") {
                owner?.showGroups()
            }
            .appShortcut(.goToGroup, store: shortcuts)
            .disabled(owner == nil)
            Button("Previous Group") {
                if let owner {
                    TerminalWindowManager.shared.cycleGroup(-1, from: owner)
                }
            }
            .appShortcut(.previousGroup, store: shortcuts)
            .disabled(owner == nil)
            Button("Next Group") {
                if let owner {
                    TerminalWindowManager.shared.cycleGroup(1, from: owner)
                }
            }
            .appShortcut(.nextGroup, store: shortcuts)
            .disabled(owner == nil)
            Divider()
            Button("Previous Tab") {
                cycle(-1)
            }
            .appShortcut(.previousTab, store: shortcuts)
            .disabled(owner == nil)
            Button("Next Tab") {
                cycle(1)
            }
            .appShortcut(.nextTab, store: shortcuts)
            .disabled(owner == nil)
            Button("Select Previous Tab") {
                cycle(-1)
            }
            .appShortcut(.selectPreviousTab, store: shortcuts)
            .disabled(owner == nil)
            Button("Select Next Tab") {
                cycle(1)
            }
            .appShortcut(.selectNextTab, store: shortcuts)
            .disabled(owner == nil)
            Button("Move Tab Backward") {
                moveTab(-1)
            }
            .appShortcut(.moveTabBackward, store: shortcuts)
            .disabled(owner == nil)
            Button("Move Tab Forward") {
                moveTab(1)
            }
            .appShortcut(.moveTabForward, store: shortcuts)
            .disabled(owner == nil)
            Button("Rename Tab…") {
                if let owner, let tab = owner.group.selectedTab {
                    owner.renameTab(tab)
                }
            }
            .appShortcut(.renameTab, store: shortcuts)
            .disabled(owner?.group.selectedTab == nil)
            Button("Move Tab to New Window") {
                if let owner, let tab = owner.group.selectedTab {
                    owner.moveToNewWindow(tab)
                }
            }
            .appShortcut(.moveTabToNewWindow, store: shortcuts)
            .disabled((owner?.group.tabs.count ?? 0) < 2)
            Button("Merge All Windows") {
                if let owner {
                    TerminalWindowManager.shared.mergeAllWindows(into: owner)
                }
            }
            .appShortcut(.mergeAllWindows, store: shortcuts)
            .disabled(owner == nil)
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
