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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        _ = SecureKeyboardEntry.shared
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        openInitialDocumentIfNeeded()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        guard !hasVisibleWindows else { return true }
        WindowOpener.openWindow(spec: LaunchSpec())
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasLiveProcess = sender.windows.contains { window in
            TerminalSessionRegistry.shared.controllers(for: window)
                .contains(where: TerminalClosePolicy.requiresConfirmation)
        }
        guard hasLiveProcess else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit and terminate running processes?"
        alert.informativeText = "A process is still running."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        SecureKeyboardEntry.shared.disableForTermination()
    }

    private func openInitialDocumentIfNeeded() {
        guard NSDocumentController.shared.documents.isEmpty else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "startupMode") == "windowGroup",
           let rawID = defaults.string(forKey: "startupWindowGroupID"),
           let id = UUID(uuidString: rawID),
           let group = AppModel.shared.windowGroups.group(withID: id),
           AppModel.shared.windowGroups.open(group) {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        var spec = LaunchSpec()
        if defaults.string(forKey: "startupMode") == "profile",
           let rawID = defaults.string(forKey: "startupProfileID") {
            spec.profileID = UUID(uuidString: rawID)
        }
        WindowOpener.openWindow(spec: spec, initialFrame: .saved)
    }
}

@Observable
@MainActor
final class SecureKeyboardEntry {
    static let shared = SecureKeyboardEntry()

    @ObservationIgnored private var enabledByThisApp = false
    var isEnabled = false {
        didSet {
            applyState()
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "SecureKeyboardEntry")
        applyState()
    }

    func disableForTermination() {
        guard enabledByThisApp else { return }
        DisableSecureEventInput()
        enabledByThisApp = false
    }

    private func applyState() {
        UserDefaults.standard.set(isEnabled, forKey: "SecureKeyboardEntry")
        if isEnabled {
            guard !enabledByThisApp else { return }
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

struct NewItemCommands: Commands {
    var body: some Commands {
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
        }
    }
}

struct TabSelectionCommands: Commands {
    @State private var commandState = TerminalCommandState()

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Menu("Select Tab") {
                ForEach(1...8, id: \.self) { number in
                    Button("Select Tab \(number)") {
                        selectTab(at: number - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [.command])
                }
                Divider()
                Button("Select Last Tab") {
                    selectLastTab()
                }
                .keyboardShortcut("9", modifiers: [.command])
            }

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

    private func selectTab(at index: Int) {
        guard UserDefaults.standard.bool(forKey: "useCommandDigitsForTabs"),
              let tabGroup = (NSApp.keyWindow ?? NSApp.mainWindow)?.tabGroup,
              tabGroup.windows.indices.contains(index) else {
            return
        }
        tabGroup.selectedWindow = tabGroup.windows[index]
    }

    private func selectLastTab() {
        guard UserDefaults.standard.bool(forKey: "useCommandDigitsForTabs"),
              let tabGroup = (NSApp.keyWindow ?? NSApp.mainWindow)?.tabGroup,
              let lastWindow = tabGroup.windows.last else {
            return
        }
        tabGroup.selectedWindow = lastWindow
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
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(!isEnabled)

            Button("Close Pane") {
                controller?.requestClose()
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(!isEnabled)

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

            Button("Clear Scrollback") {
                controller?.terminal?.clearScrollback()
            }
            .keyboardShortcut("k", modifiers: [.command])
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
                .keyboardShortcut("g", modifiers: [.command, .shift])
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
            get: { controller?[keyPath: keyPath] ?? false },
            set: { newValue in
                controller?[keyPath: keyPath] = newValue
            }
        )
    }

    private func performFindAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        controller?.terminal?.performTextFinderAction(item)
    }

    private func pasteEscaped() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let escaped = "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        controller?.terminal?.send(txt: escaped)
    }
}

struct TerminalPrintCommands: Commands {
    @State private var commandState = TerminalCommandState()

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                commandState.controller?.printBuffer()
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(commandState.controller == nil)
        }
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
    static let value = "settings"
}

struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: SettingsWindowID.value)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

@main
struct TecolotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    init() {
        UserDefaults.standard.register(defaults: [
            "useCommandDigitsForTabs": true,
            "startupMode": "default",
            "useMetalRenderer": true
        ])
    }

    var body: some Scene {
        DocumentGroup(newDocument: TerminalDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
                .environmentObject(model.profiles)
                .environmentObject(model.themes)
                .environmentObject(model.themeIndex)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            AppInfoCommands()
            UpdateCommands()
            SettingsCommands()
            NewItemCommands()
            TabSelectionCommands()
            SplitCommands()
            ProfileCommands(profiles: model.profiles)
            WindowGroupCommands(store: model.windowGroups)
            TerminalCommands()
            TerminalPrintCommands()
        }

        Window("Settings", id: SettingsWindowID.value) {
            SettingsView(issueCenter: model.issueCenter, recovery: model.recovery)
                .environmentObject(model.profiles)
                .environmentObject(model.themes)
                .environmentObject(model.themeIndex)
        }
        .defaultSize(width: 820, height: 560)
        .windowResizability(.contentMinSize)
    }
}
