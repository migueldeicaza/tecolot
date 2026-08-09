//
//  SettingsView.swift
//  Tecolot
//
//  Settings window: General and Appearance carry what most users need;
//  the full profile machinery lives in the last tab for advanced use.
//
import Combine
import SwiftUI
import TerminalProfilesKit

struct SettingsView: View {
    @ObservedObject var issueCenter: PersistenceIssueCenter
    let recovery: DataRecoveryCoordinator

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Appearance", systemImage: "paintbrush") {
                AppearanceSettingsView()
            }
            Tab("Profiles", systemImage: "person.2.badge.gearshape") {
                ProfilesSettingsView()
            }
            Tab(dataTabTitle, systemImage: "externaldrive.badge.checkmark") {
                DataRecoveryView(issueCenter: issueCenter, recovery: recovery)
            }
        }
        .frame(width: 760, height: 560)
    }

    private var dataTabTitle: String {
        issueCenter.issues.isEmpty ? "Data" : "Data (\(issueCenter.issues.count))"
    }
}

/// App-level (non-profile) settings, persisted via AppStorage
struct GeneralSettingsView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var windowGroups = AppModel.shared.windowGroups
    @AppStorage("newTabsUseCurrentDirectory") private var newTabsUseCurrentDirectory = true
    @AppStorage("newTabsUseCurrentProfile") private var newTabsUseCurrentProfile = true
    @AppStorage("useCommandDigitsForTabs") private var useCommandDigitsForTabs = true
    @AppStorage("restoredRowsLimit") private var restoredRowsLimit = 1_000
    @AppStorage("startupMode") private var startupMode = "default"
    @AppStorage("startupProfileID") private var startupProfileID = ""
    @AppStorage("startupWindowGroupID") private var startupWindowGroupID = ""
    @AppStorage("useMetalRenderer") private var useMetalRenderer = true
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if profiles.profiles.isEmpty {
                LabeledContent("Default profile:") {
                    Text("Built-in defaults")
                }
            } else {
                Picker("Default profile:", selection: defaultProfileBinding) {
                    ForEach(profiles.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .help("Used for new windows, and wherever no explicit profile is chosen")
            }

            Section("Startup") {
                Picker("Open:", selection: $startupMode) {
                    Text("A window with the default profile").tag("default")
                    Text("A window with this profile").tag("profile")
                    Text("A window group").tag("windowGroup")
                }
                if startupMode == "profile" {
                    Picker("Profile:", selection: $startupProfileID) {
                        ForEach(profiles.profiles) { profile in
                            Text(profile.name).tag(profile.id.uuidString)
                        }
                    }
                } else if startupMode == "windowGroup" {
                    Picker("Window group:", selection: $startupWindowGroupID) {
                        Text("None").tag("")
                        ForEach(windowGroups.groups) { group in
                            Text(group.name).tag(group.id.uuidString)
                        }
                    }
                }
            }

            Section("New tabs") {
                Toggle("Open with the working directory of the current tab", isOn: $newTabsUseCurrentDirectory)
                Toggle("Use the profile of the current window", isOn: $newTabsUseCurrentProfile)
            }
            Section("Tabs") {
                Toggle("Use Command-1 through Command-9 to select tabs", isOn: $useCommandDigitsForTabs)
            }
            Section("Rendering") {
                Toggle("Use Metal", isOn: metalRendererBinding)
                Text("Metal rendering is enabled by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Resume") {
                Stepper(
                    "Restore up to \(restoredRowsLimit) rows when a saved session opens",
                    value: $restoredRowsLimit,
                    in: 0...100_000,
                    step: 100
                )
                Text("Set the value to 0 to restore no terminal text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            get: { profiles.defaultProfileID },
            set: { id in
                do {
                    try profiles.setDefault(id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private var metalRendererBinding: Binding<Bool> {
        Binding(
            get: { useMetalRenderer },
            set: { enabled in
                useMetalRenderer = enabled
                TerminalSessionRegistry.shared.setUseMetalRenderer(enabled)
            }
        )
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

/// Edits the default profile without exposing the profile concept
struct AppearanceSettingsView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var themes: ThemeStore
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if profiles.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Profile to Edit", systemImage: "paintbrush")
                } description: {
                    Text("Create a profile before you change appearance settings.")
                } actions: {
                    Button("Create Profile", action: createProfile)
                }
            } else {
                appearanceEditor
            }
        }
        .alert("Could Not Change Appearance", isPresented: errorPresentation) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var appearanceEditor: some View {
        let profile = profiles.defaultProfile
        return VStack(spacing: 0) {
            ThemeBrowserView(themes: themes, selectedThemeName: profile.themeName) { theme in
                update { $0.themeName = theme.name }
            }
            Divider()
            ProfileTextSettings(profile: profile, update: update)
                .padding(.horizontal)
                .frame(maxHeight: 190)
            Text("These settings edit your default profile. More options are available under Profiles.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
    }

    private func update(_ mutate: (inout TerminalProfile) -> Void) {
        var profile = profiles.defaultProfile
        mutate(&profile)
        do {
            try profiles.update(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createProfile() {
        let profile = TerminalProfile(name: "Default")
        do {
            try profiles.add(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
