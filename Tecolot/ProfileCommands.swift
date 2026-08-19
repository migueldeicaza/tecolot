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
        return TerminalSessionContainerView.contentSize(
            forTerminalSize: terminal.getOptimalFrameSize().size
        )
    }
}

/// Opens document windows/tabs, threading a LaunchSpec through AppModel
/// because the NSDocumentController path cannot carry parameters
@MainActor
enum WindowOpener {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot",
        category: "WindowSizing"
    )

    @discardableResult
    static func openWindow(
        spec: LaunchSpec,
        initialFrame: TerminalWindowInitialFrame = .profile
    ) -> NSWindow? {
        guard let (document, windowController, window) = makeDocumentWindow(spec: spec) else {
            return nil
        }

        let initialDescription: String
        switch initialFrame {
        case .profile:
            let profile = AppModel.shared.resolveProfile(for: spec)
            let contentSize = TerminalProfileWindowSizer.contentSize(for: profile)
            TerminalWindowSizeStore.shared.setProfileContentSize(contentSize, on: window)
            TerminalWindowSizeStore.shared.configure(window, restoresFrame: false)
            initialDescription = "profile \(profile.name) \(profile.columns)x\(profile.rows)"
        case .saved:
            windowController.shouldCascadeWindows = false
            let didRestoreFrame = TerminalWindowSizeStore.shared.configure(
                window,
                restoresFrame: true
            )
            if didRestoreFrame {
                initialDescription = "saved normal frame"
            } else {
                let profile = AppModel.shared.resolveProfile(for: spec)
                let contentSize = TerminalProfileWindowSizer.contentSize(for: profile)
                TerminalWindowSizeStore.shared.setProfileContentSize(contentSize, on: window)
                initialDescription = "profile \(profile.name) \(profile.columns)x\(profile.rows); no saved frame"
            }
        case .windowGroup(let frame):
            windowController.shouldCascadeWindows = false
            TerminalWindowSizeStore.shared.restoreWindowGroupFrame(frame, to: window)
            initialDescription = "saved window-group frame"
        }

        // Do not let AppKit merge an explicit new window during first display.
        // WindowTabbingConfigurator enables later manual tab operations.
        window.tabbingMode = .disallowed
        window.tabbingIdentifier = "TerminalDocument"
        logFrame(window, stage: "before show", policy: initialDescription)
        document.showWindows()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        logFrameAfterDisplay(window, policy: initialDescription)
        return window
    }

    @discardableResult
    static func openTab(spec: LaunchSpec, targetWindow: NSWindow? = nil) -> NSWindow? {
        let targetWindow = targetWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let (document, _, newWindow) = makeDocumentWindow(spec: spec) else {
            return nil
        }
        // A tab can be created in a new window before it is merged into its
        // target tab group. Do not apply a saved frame during that interval.
        if targetWindow == nil {
            let profile = AppModel.shared.resolveProfile(for: spec)
            let contentSize = TerminalProfileWindowSizer.contentSize(for: profile)
            TerminalWindowSizeStore.shared.setProfileContentSize(contentSize, on: newWindow)
        }
        TerminalWindowSizeStore.shared.configure(newWindow, restoresFrame: false)
        newWindow.tabbingMode = .preferred
        newWindow.tabbingIdentifier = "TerminalDocument"

        if let existingWindow = targetWindow, existingWindow != newWindow {
            existingWindow.tabbingMode = .preferred
            existingWindow.tabbingIdentifier = "TerminalDocument"
            existingWindow.addTabbedWindow(newWindow, ordered: .above)
        }
        document.showWindows()
        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
        logFrameAfterDisplay(newWindow, policy: targetWindow == nil ? "profile tab window" : "new tab")
        return newWindow
    }

    private static func makeDocumentWindow(
        spec: LaunchSpec
    ) -> (NSDocument, NSWindowController, NSWindow)? {
        AppModel.shared.setPendingLaunch(spec)
        guard let document = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(false) else {
            AppModel.shared.discardPendingLaunch()
            logger.error("Could not create an untitled terminal document")
            return nil
        }
        document.makeWindowControllers()
        guard let windowController = document.windowControllers.first,
              let window = windowController.window else {
            AppModel.shared.discardPendingLaunch()
            document.close()
            logger.error("The untitled terminal document did not create a window")
            return nil
        }
        return (document, windowController, window)
    }

    private static func logFrame(_ window: NSWindow, stage: String, policy: String) {
        let frame = NSStringFromRect(window.frame)
        let content = NSStringFromRect(window.contentLayoutRect)
        let dimensions = TerminalSessionRegistry.shared.controller(for: window)?
            .terminal?.terminalDimensions
        let grid = dimensions.map { "\($0.cols)x\($0.rows)" } ?? "unavailable"
        let tabCount = window.tabGroup?.windows.count ?? 0
        logger.info("Window \(stage, privacy: .public): policy=\(policy, privacy: .public) visible=\(window.isVisible) frame=\(frame, privacy: .public) content=\(content, privacy: .public) grid=\(grid, privacy: .public) tabs=\(tabCount)")
    }

    private static func logFrameAfterDisplay(_ window: NSWindow, policy: String) {
        logFrame(window, stage: "after show", policy: policy)
        DispatchQueue.main.async {
            logFrame(window, stage: "next display cycle", policy: policy)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            logFrame(window, stage: "settled", policy: policy)
        }
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
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                WindowOpener.openWindow(spec: LaunchSpec())
            }
            .keyboardShortcut("n", modifiers: [.command])
        }

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
