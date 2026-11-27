//
//  TecolotApp.swift
//  Tecolot
//
//  Created by Miguel de Icaza on 8/5/25.
//

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftTerm
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didEnsureStartupWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        _ = SecureKeyboardEntry.shared
        CrashReporting.finishLaunch()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            DetachedSessionNotifications.shared.start()
        }
        // Do not wait for the activation: an app that starts in the
        // background (after a log in, or opened by another app) must restore
        // its windows, and a quit before the first activation must save them.
        DispatchQueue.main.async { [weak self] in
            self?.ensureStartupWindow()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureStartupWindow()
    }

    private func ensureStartupWindow() {
        guard !didEnsureStartupWindow else {
            return
        }
        didEnsureStartupWindow = true
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            let hasTerminalWindow = NSApp.windows.contains { window in
                !TerminalSessionRegistry.shared.controllers(for: window).isEmpty
            }
            // The windows of the last quit come back as they were. AppKit
            // restores no terminal window (see registerWindowIfAvailable).
            // These windows do not activate the app (LaunchSpec.activate).
            let restored = RestoreStore.shared.restore()
            guard !hasTerminalWindow, !restored else {
                return
            }
            self?.openStartupWindow()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        let manager = TerminalWindowManager.shared
        if
            hasVisibleWindows, manager.shownWindows().contains(where: {
                $0.window.isVisible
            }) {
            return true
        }
        manager.reopenWindow {
            WindowOpener.openWindow(spec: $0)
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let runningCount = TerminalClosePolicy.confirmationCount(in: TerminalSessionRegistry.shared.allControllers)
        let hasLiveProcess = runningCount > 0
        guard hasLiveProcess else {
            return saveForTermination(sender)
        }

        let alert = NSAlert()
        alert.messageText = "Quit and terminate running processes?"
        alert.informativeText = TerminalClosePolicy.quitMessage(runningPaneCount: runningCount)
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard ConfirmationKeyboard.runModal(alert) == .alertFirstButtonReturn else {
            return .terminateCancel
        }
        return saveForTermination(sender)
    }

    /// Saves the windows for the next launch, then quits. The writes run on
    /// a background queue; the quit waits for them for at most 3 seconds.
    private func saveForTermination(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard RestoreStore.shared.isEnabled, RestoreStore.shared.isReady else {
            return .terminateNow
        }
        RestoreStore.shared.saveForTermination() {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        SecureKeyboardEntry.shared.disableForTermination()
        RemoteHosts.shared.shutdown()
    }

    private func openStartupWindow() {
        TerminalWindowManager.shared.openStartupWindows {
            WindowOpener.openWindow(spec: $0, initialFrame: .saved)
        }
    }
}

@Observable
@MainActor
final class SecureKeyboardEntry {
    nonisolated static let enabledKey = "SecureKeyboardEntry"
    nonisolated static let enabledDefault = false

    static let shared = SecureKeyboardEntry()

    @ObservationIgnored private var enabledByThisApp = false
    @ObservationIgnored private let appliesState: Bool
    var isEnabled = SecureKeyboardEntry.enabledDefault {
        didSet {
            applyState()
        }
    }

    private init() {
        appliesState = true
        isEnabled = UserDefaults.standard.bool(forKey: SecureKeyboardEntry.enabledKey)
        applyState()
    }

    /// An in-memory stand-in that never changes secure input or stored preferences.
    init(isEnabled: Bool) {
        appliesState = false
        self.isEnabled = isEnabled
    }

    func disableForTermination() {
        guard enabledByThisApp else {
            return
        }
        DisableSecureEventInput()
        enabledByThisApp = false
    }

    private func applyState() {
        guard appliesState else {
            return
        }
        UserDefaults.standard.set(isEnabled, forKey: SecureKeyboardEntry.enabledKey)
        if isEnabled {
            guard !enabledByThisApp else {
                return
            }
            guard EnableSecureEventInput() == noErr else {
                isEnabled = false
                return
            }
            enabledByThisApp = true
        } else if enabledByThisApp {
            DisableSecureEventInput()
            enabledByThisApp = false
        }
    }
}

struct TabSelectionCommands: Commands {
    nonisolated static let useCommandDigitsForTabsKey = "useCommandDigitsForTabs"
    nonisolated static let useCommandDigitsForTabsDefault = true

    @State private var commandState = TerminalCommandState()

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Menu("Select Tab") {
                ForEach(1...9, id: \.self) { number in
                    Button("Select Tab \(number)") {
                        selectTab(at: number - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [.command])
                }
            }
            .disabled(owner == nil)

            Divider()

            Button("Select Previous Split") {
                commandState.controller?.workspace?.selectPreviousSplit()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!hasMultipleSplits)

            Button("Select Next Split") {
                commandState.controller?.workspace?.selectNextSplit()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!hasMultipleSplits)
        }
    }

    private var hasMultipleSplits: Bool {
        (commandState.controller?.workspace?.paneCount ?? 0) > 1
    }

    private var owner: TerminalWindowController? {
        _ = commandState.window
        return TerminalWindowCommandTarget.resolve(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow)?.terminal
    }

    private func selectTab(at index: Int) {
        guard UserDefaults.standard.bool(forKey: TabSelectionCommands.useCommandDigitsForTabsKey), let owner else {
            return
        }
        owner.selectNumberedTab(index)
    }


}

struct SplitCommands: Commands {
    @State private var commandState = TerminalCommandState()

    private var workspace: TerminalPaneWorkspace? {
        commandState.controller?.workspace
    }

    private var hasMultipleSplits: Bool {
        (workspace?.paneCount ?? 0) > 1
    }

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Menu("Select Split") {
                Button("Select Split Above") {
                    workspace?.selectSplit(in: .up)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!hasMultipleSplits)

                Button("Select Split Below") {
                    workspace?.selectSplit(in: .down)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!hasMultipleSplits)

                Button("Select Split Left") {
                    workspace?.selectSplit(in: .left)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!hasMultipleSplits)

                Button("Select Split Right") {
                    workspace?.selectSplit(in: .right)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!hasMultipleSplits)
            }

            Menu("Resize Split") {
                Button("Equalize Split") {
                    workspace?.equalizeSplits()
                }
                .keyboardShortcut("=", modifiers: [.command, .control])
                .disabled(!hasMultipleSplits)

                Divider()

                Button("Move Divider Up") {
                    workspace?.moveDivider(in: .up)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(!hasMultipleSplits)

                Button("Move Divider Down") {
                    workspace?.moveDivider(in: .down)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(!hasMultipleSplits)

                Button("Move Divider Left") {
                    workspace?.moveDivider(in: .left)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(!hasMultipleSplits)

                Button("Move Divider Right") {
                    workspace?.moveDivider(in: .right)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(!hasMultipleSplits)
            }

            Button(workspace?.zoomedControllerID == nil ? "Zoom Split" : "Reset Split Zoom") {
                workspace?.toggleSplitZoom()
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!hasMultipleSplits)
        }
    }
}

struct TerminalCommands: Commands {
    @State private var commandState = TerminalCommandState()
    @State private var secureKeyboardEntry = SecureKeyboardEntry.shared

    private var controller: TerminalSessionController? {
        commandState.controller
    }

    var body: some Commands {
        let isEnabled = controller != nil
        CommandMenu("Terminal") {
            Button("Split Pane") {
                if let controller {
                    controller.workspace?.split(controller, orientation: .vertical)
                }
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(!isEnabled)

            Button("Split Pane Horizontally") {
                if let controller {
                    controller.workspace?.split(controller, orientation: .horizontal)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!isEnabled)

            Button("Terminate Session") {
                controller?.terminateSession()
            }
            .disabled(controller?.isPersistent != true)

            Divider()

            Button("Export Buffer...") {
                controller?.exportBuffer()
            }
            .disabled(!isEnabled)
            Button("Export Selection...") {
                controller?.exportSelection()
            }
            .disabled(!isEnabled || controller?.selectionActive != true)

            Divider()

            Button("Clear to Start", action: clearScrollback)
                .keyboardShortcut("k", modifiers: [.command, .control])
                .disabled(!isEnabled)

            Divider()

            Button("Scroll to Previous Prompt") {
                controller?.scrollToPreviousPrompt()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(!isEnabled)

            Button("Scroll to Next Prompt") {
                controller?.scrollToNextPrompt()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .disabled(!isEnabled)

            Button("Soft Reset") {
                controller?.softReset()
            }
            .disabled(!isEnabled)
            Button("Hard Reset") {
                controller?.hardReset()
            }
            .disabled(!isEnabled)

            Divider()

            Toggle("Allow Mouse Reporting", isOn: binding(\.allowMouseReporting))
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!isEnabled)
            Toggle("Use Option as Meta Key", isOn: binding(\.optionAsMetaKey))
                .disabled(!isEnabled)
            Toggle("Use Metal Renderer", isOn: binding(\.useMetalRenderer))
                .disabled(!isEnabled)
            Toggle("Use Per-Frame Metal Buffering", isOn: binding(\.usePerFrameMetalBuffering))
                .disabled(!isEnabled)
            Toggle("Log host output to ~/Downloads/Logs", isOn: binding(\.logHostOutput))
                .disabled(!isEnabled)
            Toggle("Secure Keyboard Entry", isOn: Bindable(secureKeyboardEntry).isEnabled)

            Divider()

            Button("Bigger Font") {
                controller?.biggerFont()
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(!isEnabled)

            Button("Smaller Font") {
                controller?.smallerFont()
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(!isEnabled)

            Button("Default Font Size") {
                controller?.defaultFontSize()
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(!isEnabled)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") {
                    performFindAction(.showFindInterface)
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(!isEnabled)

                Button("Find Next") {
                    performFindAction(.nextMatch)
                }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(!isEnabled)

                Button("Find Previous") {
                    performFindAction(.previousMatch)
                }
                .keyboardShortcut("g", modifiers: [.command, .control])
                .disabled(!isEnabled)
            }

            Button("Paste Escaped") {
                pasteEscaped()
            }
            .keyboardShortcut("v", modifiers: [.command, .control])
            .disabled(!isEnabled)
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<TerminalSessionController, Bool>) -> Binding<Bool> {
        Binding(
            get: {
                controller?[keyPath: keyPath] ?? false
            },
            set: { newValue in
                controller?[keyPath: keyPath] = newValue
            }
        )
    }

    private func clearScrollback() {
        controller?.clearToStart()
    }

    private func performFindAction(_ action: NSTextFinder.Action) {
        controller?.performFind(action)
    }

    private func pasteEscaped() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            return
        }
        let escaped = "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        controller?.sendLiteralText(escaped)
    }
}

struct AppInfoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Tecolot") {
                let credits = NSAttributedString(
                    string: "A native terminal built with SwiftTerm.\n"
                        + "Copyright © 2026 Miguel de Icaza.\n\n"
                        + "Includes Symbols Nerd Font (Nerd Fonts 3.4.0),\n"
                        + "© Nerd Fonts contributors, MIT License."
                )
                NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
            }
        }
    }
}

private enum SettingsWindowID {
    static let value = SettingsNavigator.windowID
}

struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Lets the crash report notice open this window.
        let _ = SettingsNavigator.shared.openWindow = openWindow
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: SettingsWindowID.value)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

struct TecolotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    init() {
        UserDefaults.standard.register(defaults: [
            TabSelectionCommands.useCommandDigitsForTabsKey: TabSelectionCommands.useCommandDigitsForTabsDefault,
            StartupGroups.startupModeKey: StartupGroups.startupModeDefault,
            TerminalSessionController.useMetalRendererKey: TerminalSessionController.useMetalRendererDefault
        ])
    }

    var body: some Scene {
        Window("Settings", id: SettingsWindowID.value) {
            SettingsView(issueCenter: model.issueCenter, recovery: model.recovery)
                .environmentObject(model.profiles)
                .environmentObject(model.themes)
                .environmentObject(model.themeIndex)
                .environmentObject(model.systemAppearance)
                .windowFullScreenBehavior(.disabled)
        }
        .windowManagerRole(.associated)
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 820, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            AppInfoCommands()
            UpdateCommands()
            SettingsCommands()
            FileCommands(profiles: model.profiles)
            GroupWindowCommands()
            TabSelectionCommands()
            SplitCommands()
            ProfileCommands(profiles: model.profiles)
            TerminalCommands()
        }

        Window("Sessions", id: SessionBrowserWindowID.value) {
            SessionBrowserView()
                .windowFullScreenBehavior(.disabled)
        }
        .windowManagerRole(.associated)
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 860, height: 400)
    }
}
