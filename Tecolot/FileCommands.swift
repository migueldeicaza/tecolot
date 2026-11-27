//
//  FileCommands.swift
//  Tecolot
//
//  Owns the entire File menu so SwiftUI's placement anchors stay in standard
//  macOS order: Create, Sessions & Group, Close, and Print.
//

import AppKit
import SwiftUI

struct FileCommands: Commands {
    @ObservedObject var profiles: ProfileStore
    @Environment(\.openWindow) private var openWindow
    @State private var commandState = TerminalCommandState()
    @State private var shortcuts = AppShortcutStore.shared

    private var target: TerminalWindowCommandTarget? {
        _ = commandState.window
        return TerminalWindowCommandTarget.resolve(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow)
    }

    private var owner: TerminalWindowController? {
        target?.terminal
    }

    private var closeTitle: String {
        owner != nil && (commandState.controller?.workspace?.paneCount ?? 0) > 1 ? "Close Pane" : "Close"
    }

    var body: some Commands {
        let _ = registerSessionBrowser()

        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                WindowOpener.openWindow(spec: LaunchSpec())
            }
            .appShortcut(.newWindow, store: shortcuts)

            Button("New Tab") {
                // Inherits working directory and profile from the current
                // tab per the General settings
                WindowOpener.openTab(spec: WindowOpener.inheritedTabSpec())
            }
            .appShortcut(.newTab, store: shortcuts)

            Button("New Group") {
                if let controller = TerminalWindowManager.shared.controller(for: WindowOpener.frontTerminalWindow()) {
                    controller.newGroup()
                } else {
                    WindowOpener.openWindow(spec: LaunchSpec())
                }
            }
            .appShortcut(.newGroup, store: shortcuts)

            Menu("New Window with Profile") {
                ForEach(profiles.profiles) { profile in
                    Button(profile.name) {
                        WindowOpener.openWindow(spec: LaunchSpec(profileID: profile.id))
                    }
                }
            }

            Menu("New Tab with Profile") {
                ForEach(profiles.profiles) { profile in
                    Button(profile.name) {
                        var spec = WindowOpener.inheritedTabSpec()
                        spec.profileID = profile.id
                        WindowOpener.openTab(spec: spec)
                    }
                }
            }

            Divider()

            Menu("Sessions") {
                Button("New Persistent Tab") {
                    var spec = WindowOpener.inheritedTabSpec()
                    spec.persistent = true
                    WindowOpener.openTab(spec: spec)
                }
                .appShortcut(.newPersistentTab, store: shortcuts)

                Button("New Persistent Window") {
                    var spec = LaunchSpec()
                    spec.persistent = true
                    WindowOpener.openWindow(spec: spec)
                }
                .appShortcut(.newPersistentWindow, store: shortcuts)

                Divider()

                Button("New Remote Session…") {
                    guard let destination = RemoteDestinationPanel.run() else {
                        return
                    }
                    var spec = LaunchSpec()
                    spec.remoteDestination = destination
                    spec.persistent = true
                    WindowOpener.openTab(spec: spec)
                }
                .appShortcut(.newRemoteSession, store: shortcuts)

                Divider()

                Button("Attach to Session…") {
                    openWindow(id: SessionBrowserWindowID.value)
                }
                .appShortcut(.attachToSession, store: shortcuts)

                Button("Connect to Host…") {
                    openWindow(id: SessionBrowserWindowID.value)
                    // The window opens first, so that the host section shows in it.
                    DispatchQueue.main.async {
                        SessionBrowserModel.shared.connectToHost()
                    }
                }
            }

            Menu("Group") {
                Button("Rename Group…") {
                    owner?.renameGroup()
                }
                .appShortcut(.renameGroup, store: shortcuts)
                .disabled(owner == nil)

                Button("Duplicate Group") {
                    if let owner {
                        TerminalWindowManager.shared.duplicate(owner.group)
                    }
                }
                .appShortcut(.duplicateGroup, store: shortcuts)
                .disabled(owner == nil)

                Divider()

                Button("Close Group") {
                    owner?.requestCloseGroup()
                }
                .appShortcut(.closeGroup, store: shortcuts)
                .disabled(owner == nil)

                Button("Close Group and End Sessions") {
                    owner?.requestCloseGroupAndEndSessions()
                }
                .appShortcut(.closeGroupAndEndSessions, store: shortcuts)
                .disabled(owner == nil)
            }
            .disabled(owner == nil)

            Divider()

            Button("Go to Directory…") {
                owner?.openCommandPalette(scope: .directoryPicker(initialPath: nil))
            }
            .appShortcut(.goToDirectory, store: shortcuts)
            .disabled(owner == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button(closeTitle) {
                if let owner {
                    owner.requestCloseSelectedPane()
                } else {
                    target?.window.performClose(nil)
                }
            }
            .appShortcut(.closePane, store: shortcuts)
            .disabled(target == nil)

            Button("Close Tab") {
                if let owner, let tab = owner.group.selectedTab {
                    owner.requestCloseTab(tab)
                }
            }
            .appShortcut(.closeTab, store: shortcuts)
            .disabled(owner == nil)

            Button("Close Window") {
                target?.window.performClose(nil)
            }
            .appShortcut(.closeWindow, store: shortcuts)
            .disabled(target == nil)
        }

        CommandGroup(replacing: .importExport) {}

        // No default keyboard shortcut: Command-P must reach the terminal unless the user binds it.
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                commandState.controller?.printBuffer()
            }
            .appShortcut(.printTerminal, store: shortcuts)
            .disabled(commandState.controller == nil)
        }
    }

    private func registerSessionBrowser() {
        SessionBrowserPresentation.open = {
            openWindow(id: SessionBrowserWindowID.value)
        }
    }
}
