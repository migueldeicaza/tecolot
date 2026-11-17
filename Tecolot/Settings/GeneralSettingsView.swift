import Sparkle
import SwiftUI

/// App-level (non-profile) settings, persisted via AppStorage
struct GeneralSettingsView: View {
    @EnvironmentObject private var profiles: ProfileStore
    private let groups: TerminalWindowManager
    @Bindable private var secureKeyboardEntry: SecureKeyboardEntry
    @AppStorage(WindowOpener.newTabsUseCurrentDirectoryKey) private var newTabsUseCurrentDirectory = WindowOpener.newTabsUseCurrentDirectoryDefault
    @AppStorage(WindowOpener.newTabsUseCurrentProfileKey) private var newTabsUseCurrentProfile = WindowOpener.newTabsUseCurrentProfileDefault
    @AppStorage(RestoreStore.restoredRowsLimitKey) private var restoredRowsLimit = RestoreStore.restoredRowsLimitDefault
    @AppStorage(StartupGroups.startupModeKey) private var startupMode = StartupGroups.startupModeDefault
    @AppStorage(StartupGroups.startupProfileIDKey) private var startupProfileID = StartupGroups.startupProfileIDDefault
    @State private var startupSelectionRevision = 0
    @AppStorage(TerminalSessionController.useMetalRendererKey) private var useMetalRenderer = TerminalSessionController.useMetalRendererDefault
    @AppStorage(TerminalSessionController.copyOnSelectKey) private var copyOnSelect = TerminalSessionController.copyOnSelectDefault
    @State private var errorMessage: String?

    @MainActor
    init(groups: TerminalWindowManager? = nil, secureKeyboardEntry: SecureKeyboardEntry? = nil) {
        self.groups = groups ?? .shared
        self.secureKeyboardEntry = secureKeyboardEntry ?? .shared
    }

    private func startupBinding(for group: TerminalTabGroup) -> Binding<Bool> {
        Binding(get: { _ = startupSelectionRevision
            return StartupGroups.ids().contains(group.id)
        }, set: { selected in
            var ids = StartupGroups.ids()
            if selected {
                ids.insert(group.id)
            } else {
                ids.remove(group.id)
            }
            StartupGroups.set(ids, orderedBy: groups.groups.map(\.id))
            startupSelectionRevision += 1
        })
    }

    var body: some View {
        Form {
            Section(SettingID.generalSectionStartup.title) {
                Picker(SettingID.generalStartupOpen.title, selection: $startupMode) {
                    Text("A new group with the default profile").tag("default")
                    Text("A new group with this profile").tag("profile")
                    Text("These groups").tag("groups")
                }
                .settingsAnchor(.generalStartupOpen)
                if startupMode == "profile" {
                    Picker(SettingID.generalStartupProfile.title, selection: $startupProfileID) {
                        ForEach(profiles.profiles) { profile in
                            Text(profile.name).tag(profile.id.uuidString)
                        }
                    }
                    .settingsAnchor(.generalStartupProfile)
                } else if startupMode == "groups" {
                    ForEach(groups.groups) { group in
                        Toggle(group.name, isOn: startupBinding(for: group))
                            .settingsAnchor(.generalStartupGroups)
                    }
                }
                Text("Used only when there is no group to show.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(
                    "Restore up to \(restoredRowsLimit) rows when a saved session opens",
                    value: $restoredRowsLimit,
                    in: 0...100_000,
                    step: 100
                )
                .settingsAnchor(.generalRestoreRows)
                Text("Set the value to 0 to restore no terminal text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .settingsAnchor(.generalRestoreRows)
            }

            Section(SettingID.generalSectionNewWindows.title) {
                if profiles.profiles.isEmpty {
                    LabeledContent(SettingID.generalDefaultProfile.title) {
                        Text("Built-in defaults")
                    }
                    .settingsAnchor(.generalDefaultProfile)
                } else {
                    Picker(SettingID.generalDefaultProfile.title, selection: defaultProfileBinding) {
                        ForEach(profiles.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .help("Used for new windows, and wherever no explicit profile is chosen")
                    .settingsAnchor(.generalDefaultProfile)
                }

                Toggle(SettingID.generalNewTabsCurrentDirectory.title, isOn: $newTabsUseCurrentDirectory)
                    .settingsAnchor(.generalNewTabsCurrentDirectory)
                Toggle(SettingID.generalNewTabsCurrentProfile.title, isOn: $newTabsUseCurrentProfile)
                    .settingsAnchor(.generalNewTabsCurrentProfile)
            }
            Section("Input") {
                Toggle(SettingID.generalSecureKeyboardEntry.title, isOn: $secureKeyboardEntry.isEnabled)
                    .settingsAnchor(.generalSecureKeyboardEntry)
                Text("Prevents other apps from reading what you type.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .settingsAnchor(.generalSecureKeyboardEntry)
            }
            Section("Selection") {
                Toggle(SettingID.generalCopyOnSelection.title, isOn: $copyOnSelect)
                    .settingsAnchor(.generalCopyOnSelection)
                Text("Copies the selected text to the clipboard when you complete a selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .settingsAnchor(.generalCopyOnSelection)
            }
            Section("Rendering") {
                Toggle(SettingID.generalUseMetal.title, isOn: metalRendererBinding)
                    .settingsAnchor(.generalUseMetal)
            }
            if UpdaterModel.shared.updatesEnabled {
                Section(SettingID.generalSectionUpdates.title) {
                    Toggle(SettingID.generalCheckForUpdates.title, isOn: automaticUpdateChecksBinding)
                        .settingsAnchor(.generalCheckForUpdates)
                    Toggle(SettingID.generalDownloadUpdates.title, isOn: automaticUpdateDownloadsBinding)
                        .disabled(!updater.automaticallyChecksForUpdates)
                        .settingsAnchor(.generalDownloadUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Could Not Change Default Profile", isPresented: errorPresentation) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var defaultProfileBinding: Binding<TerminalProfile.ID> {
        Binding(
            get: {
                profiles.defaultProfileID
            },
            set: { id in
                do {
                    try profiles.setDefault(id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    // Sparkle keeps these in UserDefaults itself, so they are read straight from
    // the updater rather than mirrored through @AppStorage.
    private var updater: SPUUpdater {
        UpdaterModel.shared.updater
    }

    private var automaticUpdateChecksBinding: Binding<Bool> {
        Binding(
            get: {
                updater.automaticallyChecksForUpdates
            },
            set: {
                updater.automaticallyChecksForUpdates = $0
            }
        )
    }

    private var automaticUpdateDownloadsBinding: Binding<Bool> {
        Binding(
            get: {
                updater.automaticallyDownloadsUpdates
            },
            set: {
                updater.automaticallyDownloadsUpdates = $0
            }
        )
    }

    private var metalRendererBinding: Binding<Bool> {
        Binding(
            get: {
                useMetalRenderer
            },
            set: { enabled in
                useMetalRenderer = enabled
                TerminalSessionRegistry.shared.setUseMetalRenderer(enabled)
            }
        )
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: {
                errorMessage != nil
            },
            set: {
                if !$0 {
                    errorMessage = nil
                }
            }
        )
    }
}

#Preview("General") {
    GeneralSettingsView(
        groups: TerminalWindowManager(registry: TerminalSessionRegistry()),
        secureKeyboardEntry: SecureKeyboardEntry(isEnabled: false)
    )
    .environmentObject(SettingsPreviewData.profiles)
    .defaultAppStorage(SettingsPreviewData.defaults)
    .frame(width: 640, height: 520)
}
