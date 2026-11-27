import SwiftUI

enum ProfileSettingsSection {
    case appearance
    case window
    case shell
    case keyboardAndMouse
    case terminal

    init?(destination: SettingsDestination) {
        switch destination {
        case .appearance:
            self = .appearance
        case .window:
            self = .window
        case .shell:
            self = .shell
        case .keyboardAndMouse:
            self = .keyboardAndMouse
        case .terminal:
            self = .terminal
        case .general, .tabs, .panes, .notifications, .shortcuts, .manageProfiles, .data, .crashReports:
            return nil
        }
    }

    var title: String {
        switch self {
        case .appearance:
            return "Appearance"
        case .window:
            return "Window"
        case .shell:
            return "Shell"
        case .keyboardAndMouse:
            return "Keyboard and Mouse"
        case .terminal:
            return "Terminal"
        }
    }
}

/// A single group of settings for the active profile.
struct ProfileSettingsPage: View {
    let section: ProfileSettingsSection
    let profile: TerminalProfile
    /// Reports whether the change was stored; most controls ignore the
    /// result, but theme operations roll back on failure.
    let update: ((inout TerminalProfile) -> Void) -> Bool

    @EnvironmentObject var themes: ThemeStore

    /// Adapter for child views that have no rollback path of their own.
    var updateIgnoringResult: ((inout TerminalProfile) -> Void) -> Void {
        { mutate in
            _ = update(mutate)
        }
    }

    var body: some View {
        Group {
            switch section {
            case .appearance:
                appearanceSettings
            case .window:
                windowSettings
            case .shell:
                shellSettings
            case .keyboardAndMouse:
                keyboardAndMouseSettings
            case .terminal:
                terminalSettings
            }
        }
        .formStyle(.grouped)
        .navigationTitle(section.title)
    }

    func binding<T>(_ keyPath: WritableKeyPath<TerminalProfile, T>) -> Binding<T> {
        Binding(
            get: {
                profile[keyPath: keyPath]
            },
            set: { newValue in
                update {
                    $0[keyPath: keyPath] = newValue
                }
            }
        )
    }

}

/// Keeps profile-page preview changes local to the preview canvas.
struct ProfileSettingsPagePreview: View {
    let section: ProfileSettingsSection
    @State private var profile = SettingsPreviewData.profile

    var body: some View {
        ProfileSettingsPage(section: section, profile: profile, update: apply)
    }

    private func apply(_ mutate: (inout TerminalProfile) -> Void) -> Bool {
        mutate(&profile)
        return true
    }
}
