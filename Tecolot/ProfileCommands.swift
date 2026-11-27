//
//  ProfileCommands.swift
//  Tecolot
//
//  Launch helpers and View-menu commands for switching the front window's
//  theme and applying a profile to a running session. Stores are passed in
//  explicitly: Commands do not receive scene environment objects.
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
    nonisolated static let newTabsUseCurrentDirectoryKey = "newTabsUseCurrentDirectory"
    nonisolated static let newTabsUseCurrentDirectoryDefault = true
    nonisolated static let newTabsUseCurrentProfileKey = "newTabsUseCurrentProfile"
    nonisolated static let newTabsUseCurrentProfileDefault = true

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
            ($0.windowController as? TerminalWindowController)?.isManaged == true
                || TerminalSessionRegistry.shared.controller(for: $0) != nil
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
        let inheritDirectory = defaults.object(forKey: WindowOpener.newTabsUseCurrentDirectoryKey) as? Bool ?? WindowOpener.newTabsUseCurrentDirectoryDefault
        let inheritProfile = defaults.object(forKey: WindowOpener.newTabsUseCurrentProfileKey) as? Bool ?? WindowOpener.newTabsUseCurrentProfileDefault
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
    @State private var commandState = TerminalCommandState()
    @State private var shortcuts = AppShortcutStore.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Change Theme…") {
                commandState.controller?.showThemePicker.toggle()
            }
            .appShortcut(.changeTheme, store: shortcuts)
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
