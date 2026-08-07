//
//  SettingsView.swift
//  Tecolot
//
//  Settings window: General and Appearance carry what most users need;
//  the full profile machinery lives in the last tab for advanced use.
//
import SwiftUI
import TerminalProfilesKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            ProfilesSettingsView()
                .tabItem { Label("Profiles", systemImage: "person.2.badge.gearshape") }
        }
        .frame(width: 720, height: 520)
    }
}

/// App-level (non-profile) settings, persisted via AppStorage
struct GeneralSettingsView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @AppStorage("newTabsUseCurrentDirectory") private var newTabsUseCurrentDirectory = true
    @AppStorage("newTabsUseCurrentProfile") private var newTabsUseCurrentProfile = true

    var body: some View {
        Form {
            Picker("Default profile:", selection: defaultProfileBinding) {
                ForEach(profiles.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .help("Used for new windows, and wherever no explicit profile is chosen")

            Section("New tabs") {
                Toggle("Open with the working directory of the current tab", isOn: $newTabsUseCurrentDirectory)
                Toggle("Use the profile of the current window", isOn: $newTabsUseCurrentProfile)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var defaultProfileBinding: Binding<TerminalProfile.ID> {
        Binding(
            get: { profiles.defaultProfileID },
            set: { try? profiles.setDefault($0) }
        )
    }
}

/// Edits the default profile without exposing the profile concept
struct AppearanceSettingsView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var themes: ThemeStore

    var body: some View {
        let profile = profiles.defaultProfile
        VStack(spacing: 0) {
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
        try? profiles.update(profile)
    }
}
