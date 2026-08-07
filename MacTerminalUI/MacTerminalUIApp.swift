//
//  MacTerminalUIApp.swift
//  MacTerminalUI
//
//  Created by Miguel de Icaza on 8/5/25.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        openInitialDocumentIfNeeded()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    private func openInitialDocumentIfNeeded() {
        guard NSDocumentController.shared.documents.isEmpty else { return }
        guard let document = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true) else {
            return
        }
        if let window = document.windowControllers.first?.window {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct TabCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                // Inherits working directory and profile from the current
                // tab per the General settings
                WindowOpener.openTab(spec: WindowOpener.inheritedTabSpec())
            }
            .keyboardShortcut("t", modifiers: [.command])
        }
    }
}

struct TerminalCommands: Commands {
    @State private var commandState = TerminalCommandState()

    private var controller: TerminalSessionController? {
        commandState.controller
    }

    var body: some Commands {
        let isEnabled = controller != nil
        CommandMenu("Terminal") {
            Button("Export Buffer...") {
                controller?.exportBuffer()
            }
            .disabled(!isEnabled)
            Button("Export Selection...") {
                controller?.exportSelection()
            }
            .disabled(!isEnabled || controller?.selectionActive != true)

            Divider()

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
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<TerminalSessionController, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller?[keyPath: keyPath] ?? false },
            set: { newValue in
                controller?[keyPath: keyPath] = newValue
            }
        )
    }
}

@main
struct MacTerminalUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        DocumentGroup(newDocument: TerminalDocument()) { file in
            ContentView(document: file.$document)
                .environmentObject(model.profiles)
                .environmentObject(model.themes)
        }
        .commands {
            TabCommands()
            ProfileCommands(profiles: model.profiles)
            TerminalCommands()
        }

        // The Settings scene does not inherit the DocumentGroup environment
        Settings {
            SettingsView()
                .environmentObject(model.profiles)
                .environmentObject(model.themes)
        }
    }
}
