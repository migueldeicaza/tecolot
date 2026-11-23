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
            .keyboardShortcut("n", modifiers: [.command])

            Button("New Tab") {
                // Inherits working directory and profile from the current
                // tab per the General settings
                WindowOpener.openTab(spec: WindowOpener.inheritedTabSpec())
            }
            .keyboardShortcut("t", modifiers: [.command])

            Button("New Group") {
                if let controller = TerminalWindowManager.shared.controller(for: WindowOpener.frontTerminalWindow()) {
                    controller.newGroup()
                } else {
                    WindowOpener.openWindow(spec: LaunchSpec())
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

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
                .keyboardShortcut("t", modifiers: [.command, .option])

                Button("New Persistent Window") {
                    var spec = LaunchSpec()
                    spec.persistent = true
                    WindowOpener.openWindow(spec: spec)
                }

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
                .keyboardShortcut("t", modifiers: [.command, .option, .shift])

                Divider()

                Button("Attach to Session…") {
                    openWindow(id: SessionBrowserWindowID.value)
                }

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
                .disabled(owner == nil)

                Button("Duplicate Group") {
                    if let owner {
                        TerminalWindowManager.shared.duplicate(owner.group)
                    }
                }
                .disabled(owner == nil)

                Divider()

                Button("Close Group") {
                    owner?.requestCloseGroup()
                }
                .keyboardShortcut("w", modifiers: [.command, .option, .shift])
                .disabled(owner == nil)

                Button("Close Group and End Sessions") {
                    owner?.requestCloseGroupAndEndSessions()
                }
                .disabled(owner == nil)
            }
            .disabled(owner == nil)

            Divider()

            Button("Go to Directory…") {
                owner?.openCommandPalette(scope: .directoryPicker(initialPath: nil))
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
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
        }

        CommandGroup(replacing: .importExport) {}

        // No keyboard shortcut: Command-P must reach the terminal instead of
        // opening the print panel.
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                commandState.controller?.printBuffer()
            }
            .disabled(commandState.controller == nil)
        }
    }

    private func registerSessionBrowser() {
        SessionBrowserPresentation.open = {
            openWindow(id: SessionBrowserWindowID.value)
        }
    }
}
