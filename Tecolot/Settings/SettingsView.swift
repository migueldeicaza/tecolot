//
//  SettingsView.swift
//  Tecolot
//
//  Settings window: General and Appearance carry what most users need;
//  the full profile machinery lives in the last tab for advanced use.
//
import AppKit
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
        .frame(width: 720, height: 680)
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
    @AppStorage(AppearancePreferences.interfaceAppearanceKey)
    private var interfaceAppearance = InterfaceAppearance.system
    @AppStorage(AppearancePreferences.macosTitlebarStyleKey)
    private var macosTitlebarStyle = MacTitlebarStyle.native
    @AppStorage(AppearancePreferences.liquidGlassOpacityKey)
    private var liquidGlassOpacity = 0.7
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            applicationSettings
            Divider()
            if profiles.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Profile to Edit", systemImage: "paintbrush")
                } description: {
                    Text("Create a profile before you change appearance settings.")
                } actions: {
                    Button("Create Profile", action: createProfile)
                }
            } else {
                terminalAppearanceEditor
            }
        }
        .alert("Could Not Change Appearance", isPresented: errorPresentation) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .onChange(of: interfaceAppearance) { _, newValue in
            newValue.apply()
        }
    }

    private var applicationSettings: some View {
        Form {
            Section("Application") {
                Picker("Interface:", selection: $interfaceAppearance) {
                    ForEach(InterfaceAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                Picker("Titlebar:", selection: $macosTitlebarStyle) {
                    ForEach(MacTitlebarStyle.allCases) { style in
                        Text(style.displayName)
                            .tag(style)
                            .disabled(style == .liquidGlass && !supportsLiquidGlass)
                    }
                }
                if macosTitlebarStyle == .liquidGlass {
                    LabeledContent("Glass opacity:") {
                        HStack {
                            Slider(value: $liquidGlassOpacity, in: 0...1)
                            Text(liquidGlassOpacity, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    if !supportsLiquidGlass {
                        Text("Liquid Glass requires macOS 26 or later. Blended is used on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Titlebar changes apply to new windows. New tabs use the style of their window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: macosTitlebarStyle == .liquidGlass ? 220 : 170)
    }

    private var terminalAppearanceEditor: some View {
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

    private var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
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
