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
import SwiftUI

/// Opens document windows/tabs, threading a LaunchSpec through AppModel
/// because the NSDocumentController path cannot carry parameters
@MainActor
enum WindowOpener {
    @discardableResult
    static func openWindow(spec: LaunchSpec) -> NSWindow? {
        AppModel.shared.setPendingLaunch(spec)
        guard let document = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true) else {
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        let window = document.windowControllers.first?.window
        // An explicitly opened window starts at the selected profile's
        // dimensions. Only windows restored by the system use a saved frame.
        if let window {
            TerminalWindowSizeStore.shared.configure(window, restoresFrame: false)
        }
        window?.makeKeyAndOrderFront(nil)
        return window
    }

    @discardableResult
    static func openTab(spec: LaunchSpec, targetWindow: NSWindow? = nil) -> NSWindow? {
        let targetWindow = targetWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        AppModel.shared.setPendingLaunch(spec)
        guard let document = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true),
              let newWindow = document.windowControllers.first?.window else {
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        // A tab can be created in a new window before it is merged into its
        // target tab group. Do not apply a saved frame during that interval.
        TerminalWindowSizeStore.shared.configure(newWindow, restoresFrame: false)
        newWindow.tabbingMode = .preferred
        newWindow.tabbingIdentifier = "TerminalDocument"

        if let existingWindow = targetWindow, existingWindow != newWindow {
            existingWindow.tabbingMode = .preferred
            existingWindow.tabbingIdentifier = "TerminalDocument"
            existingWindow.addTabbedWindow(newWindow, ordered: .above)
        }
        newWindow.makeKeyAndOrderFront(nil)
        return newWindow
    }

    /// The LaunchSpec a plain New Tab should use, honoring the General
    /// settings for working-directory and profile inheritance
    static func inheritedTabSpec() -> LaunchSpec {
        let defaults = UserDefaults.standard
        let inheritDirectory = defaults.object(forKey: "newTabsUseCurrentDirectory") as? Bool ?? true
        let inheritProfile = defaults.object(forKey: "newTabsUseCurrentProfile") as? Bool ?? true
        let front = TerminalSessionRegistry.shared.controller(for: NSApp.keyWindow ?? NSApp.mainWindow)
        return LaunchSpec(
            profileID: inheritProfile ? front?.profile.id : nil,
            workingDirectory: inheritDirectory ? front?.currentWorkingDirectory : nil
        )
    }
}

struct ProfileCommands: Commands {
    @ObservedObject var profiles: ProfileStore
    @State private var commandState = TerminalCommandState()

    var body: some Commands {
        CommandGroup(after: .newItem) {
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
