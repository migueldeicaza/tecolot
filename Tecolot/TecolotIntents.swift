//
//  TecolotIntents.swift
//  Tecolot
//
//  Shortcuts actions for opening local terminal sessions.
//

import AppIntents

struct OpenTerminalWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Terminal Window"
    static let description = IntentDescription("Opens a Tecolot terminal window.")
    static let openAppWhenRun = true

    @Parameter(title: "Working Directory")
    var workingDirectory: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        WindowOpener.openWindow(spec: LaunchSpec(workingDirectory: normalizedDirectory))
        return .result()
    }

    private var normalizedDirectory: String? {
        guard let workingDirectory else { return nil }
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct OpenTerminalTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Terminal Tab"
    static let description = IntentDescription("Opens a Tecolot terminal tab.")
    static let openAppWhenRun = true

    @Parameter(title: "Working Directory")
    var workingDirectory: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        var spec = WindowOpener.inheritedTabSpec()
        if let workingDirectory {
            let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                spec.workingDirectory = trimmed
            }
        }
        WindowOpener.openTab(spec: spec)
        return .result()
    }
}

struct TecolotAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenTerminalWindowIntent(),
            phrases: ["Open a terminal in \(.applicationName)"],
            shortTitle: "Open Terminal",
            systemImageName: "terminal"
        )
        AppShortcut(
            intent: OpenTerminalTabIntent(),
            phrases: ["Open a terminal tab in \(.applicationName)"],
            shortTitle: "Open Terminal Tab",
            systemImageName: "macwindow.badge.plus"
        )
    }
}
