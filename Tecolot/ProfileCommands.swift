//
//  ProfileCommands.swift
//  Tecolot
//
//  Menu commands for launching windows/tabs with a specific profile,
//  switching the front window's theme, and applying a profile to a
//  running session. Stores are passed in explicitly: Commands do not
//  receive scene environment objects.
//
import AppKit
import os
import SwiftTerm
import SwiftUI

enum TerminalWindowInitialFrame {
    case profile
    case saved
    case windowGroup(NSRect)
    case cascaded(NSRect)
}

@MainActor
enum TerminalProfileWindowSizer {
    static func contentSize(for profile: TerminalProfile) -> NSSize {
        let terminal = TerminalView(
            frame: .zero,
            font: ProfileApplier.font(for: profile),
            options: ProfileApplier.terminalOptions(for: profile)
        )
        defer {
            let didClose = terminal.updateUiClosed()
            assert(didClose, "The terminal sizing view did not release its UI resources")
        }
        // Return the undecorated container size; the window host adds its measured chrome.
        let padding = GlobalAppearanceSettings.storedTerminalPadding
        return TerminalSessionContainerView.contentSize(
            forTerminalSize: terminal.getOptimalFrameSize().size,
            padding: padding.points,
            top: padding.topPoints(cardsEnabled: false)
        )
    }
}

/// Launch facade shared by commands, scripting, intents and restoration.
@MainActor
enum WindowOpener {
    @discardableResult
    static func openWindow(spec: LaunchSpec, initialFrame: TerminalWindowInitialFrame = .profile) -> NSWindow? {
        let manager = TerminalWindowManager.shared
        let group = manager.newGroup(tab: TerminalTab(spec: spec))
        guard
            let controller = manager.openWindow(group: group, initialFrame: initialFrame) as? TerminalWindowController,
            let window = controller.window else {
            return nil
        }
        let movesToActiveSpace: Bool
        if case .profile = initialFrame {
            movesToActiveSpace = false
        } else {
            movesToActiveSpace = true
        }
        let removesMoveToActiveSpace = movesToActiveSpace
            && !window.collectionBehavior.contains(.moveToActiveSpace)
        if movesToActiveSpace {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
        if spec.activate {
            controller.activate()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        if removesMoveToActiveSpace {
            DispatchQueue.main.async { [weak window] in
                window?.collectionBehavior.remove(.moveToActiveSpace)
            }
        }
        return window
    }

    /// The window that a new tab joins: the key or main window when it
    /// holds terminals, else the frontmost window that does. Other windows
    /// (Settings, Sessions) cannot hold a terminal tab.
    static func frontTerminalWindow(
        in candidates: [NSWindow]? = nil
    ) -> NSWindow? {
        let candidates = candidates ?? ([NSApp.keyWindow, NSApp.mainWindow].compactMap {
            $0
        } + NSApp.orderedWindows)
        return candidates.first {
            TerminalSessionRegistry.shared.controller(for: $0) != nil
        }
    }

    @discardableResult
    static func openTab(spec: LaunchSpec, targetWindow: NSWindow? = nil) -> NSWindow? {
        guard
            let window = targetWindow ?? frontTerminalWindow(),
            let controller = TerminalWindowManager.shared.controller(for: window) else {
            return openWindow(spec: spec)
        }
        TerminalWindowManager.shared.addTab(TerminalTab(spec: spec), to: controller.group)
        if spec.activate {
            controller.activate()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        return window
    }

    /// The LaunchSpec a plain New Tab should use, honoring the General
    /// settings for working-directory and profile inheritance
    static func inheritedTabSpec() -> LaunchSpec {
        let front = TerminalSessionRegistry.shared.controller(for: frontTerminalWindow())
        return inheritedTabSpec(
            profileID: front?.profile.id,
            workingDirectory: front?.currentWorkingDirectory,
            remoteDestination: front?.remoteDestination
        )
    }

    static func inheritedTabSpec(
        profileID: TerminalProfile.ID?,
        workingDirectory: String?,
        remoteDestination: String?,
        defaults: UserDefaults = .standard
    ) -> LaunchSpec {
        let inheritDirectory = defaults.object(forKey: "newTabsUseCurrentDirectory") as? Bool ?? true
        let inheritProfile = defaults.object(forKey: "newTabsUseCurrentProfile") as? Bool ?? true
        var spec = LaunchSpec(
            profileID: inheritProfile ? profileID : nil,
            workingDirectory: inheritDirectory ? workingDirectory : nil
        )
        spec.remoteDestination = remoteDestination
        if spec.remoteDestination != nil {
            spec.persistent = true
        }
        return spec
    }
}

struct ProfileCommands: Commands {
    @ObservedObject var profiles: ProfileStore
    @Environment(\.openWindow) private var openWindow
    @State private var commandState = TerminalCommandState()

    var body: some Commands {
        CommandGroup(after: .newItem) {
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
            Button("Attach to Session…") {
                openWindow(id: SessionBrowserWindowID.value)
            }
            Button("Attach to Remote Session…") {
                openWindow(id: SessionBrowserWindowID.value)
                // The window opens first, so that the host section shows in it.
                DispatchQueue.main.async {
                    SessionBrowserModel.shared.connectToHost()
                }
            }
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
        }

        CommandGroup(after: .toolbar) {
            Button("Change Theme…") {
                commandState.controller?.showThemePicker.toggle()
            }
            .keyboardShortcut("t", modifiers: [.command, .control])
            .disabled(commandState.controller == nil)

            Menu("Apply Profile to Window") {
                ForEach(profiles.profiles) { profile in
                    Button(profile.name) {
                        commandState.controller?.applyProfile(profile)
                    }
                }
            }
            .disabled(commandState.controller == nil)

            Divider()
        }
    }
}
