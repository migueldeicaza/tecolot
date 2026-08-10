//
//  SettingsView.swift
//  Tecolot
//
//  Settings window: General and Data are app-wide. The remaining pages edit
//  the profile selected in the Settings toolbar.
//
import Combine
import AppKit
import SwiftUI
import TerminalProfilesKit

struct SettingsView: View {
    @ObservedObject var issueCenter: PersistenceIssueCenter
    let recovery: DataRecoveryCoordinator
    @EnvironmentObject private var profiles: ProfileStore

    @State private var destination: SettingsDestination? = .general
    @State private var activeProfileID: TerminalProfile.ID?
    @State private var profileErrorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $destination) {
                ForEach(SettingsDestination.allCases) { destination in
                    Label(sidebarTitle(for: destination), systemImage: destination.systemImage)
                        .tag(destination)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 230)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            if currentDestination.isProfileDriven {
                ToolbarItem(placement: .automatic) {
                    profileMenu
                }
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .background(SettingsWindowConfigurator())
        .onKeyPress(.escape, action: closeOnEscape)
        .onAppear(perform: repairActiveProfileSelection)
        .onChange(of: profiles.profiles.map(\.id)) {
            repairActiveProfileSelection()
        }
        .onChange(of: activeProfileID) {
            repairActiveProfileSelection()
        }
        .alert("Could Not Change Profile", isPresented: profileErrorPresentation) {
            Button("OK") {
                profileErrorMessage = nil
            }
        } message: {
            Text(profileErrorMessage ?? "An unknown error occurred.")
        }
    }

    private var dataTabTitle: String {
        issueCenter.issues.isEmpty ? "Data" : "Data (\(issueCenter.issues.count))"
    }

    private func sidebarTitle(for destination: SettingsDestination) -> String {
        destination == .data ? dataTabTitle : destination.title
    }

    private var currentDestination: SettingsDestination {
        destination ?? .general
    }

    private var activeProfile: TerminalProfile? {
        activeProfileID.flatMap { profiles.profile(withID: $0) }
    }

    @ViewBuilder
    private var detail: some View {
        switch currentDestination {
        case .general:
            GeneralSettingsView()
        case .profiles:
            ProfilesSettingsView(activeProfileID: $activeProfileID)
        case .text, .window, .shell, .keyboard, .advanced:
            profileSettingsDetail(for: currentDestination)
        case .data:
            DataRecoveryView(issueCenter: issueCenter, recovery: recovery)
        }
    }

    @ViewBuilder
    private func profileSettingsDetail(for destination: SettingsDestination) -> some View {
        if let section = ProfileSettingsSection(destination: destination),
           let profile = activeProfile {
            ProfileSettingsPage(section: section, profile: profile, update: updateActiveProfile)
        } else {
            ContentUnavailableView {
                Label("No Profile to Edit", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Create a profile before you change these settings.")
            } actions: {
                Button("Create Profile", action: createProfile)
            }
        }
    }

    private var profileMenu: some View {
        Menu {
            ForEach(profiles.profiles) { profile in
                Button {
                    activeProfileID = profile.id
                } label: {
                    if profile.id == activeProfileID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
        } label: {
            Label(
                "Profile: \(activeProfile?.name ?? "None")",
                systemImage: "person.crop.circle"
            )
        }
        .disabled(profiles.profiles.isEmpty)
        .accessibilityLabel("Active profile")
    }

    private func repairActiveProfileSelection() {
        if let activeProfileID,
           profiles.profile(withID: activeProfileID) != nil {
            return
        }
        activeProfileID = profiles.profiles.isEmpty ? nil : profiles.defaultProfileID
    }

    private func createProfile() {
        var profile = profiles.defaultProfile
        profile.id = UUID()
        profile.name = uniqueProfileName(basedOn: "New Profile")
        do {
            try profiles.add(profile)
            activeProfileID = profile.id
        } catch {
            profileErrorMessage = error.localizedDescription
        }
    }

    private func uniqueProfileName(basedOn base: String) -> String {
        var name = base
        var number = 2
        while profiles.profile(named: name) != nil {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    private func updateActiveProfile(_ mutate: (inout TerminalProfile) -> Void) {
        guard var profile = activeProfile else { return }
        mutate(&profile)
        do {
            try profiles.update(profile)
        } catch {
            profileErrorMessage = error.localizedDescription
        }
    }

    private func closeOnEscape() -> KeyPress.Result {
        NSApp.keyWindow?.performClose(nil)
        return .handled
    }

    private var profileErrorPresentation: Binding<Bool> {
        Binding(
            get: { profileErrorMessage != nil },
            set: { if !$0 { profileErrorMessage = nil } }
        )
    }
}

/// Applies the initial Settings window size after SwiftUI creates its window.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.configure(window: view.window)
    }

    @MainActor
    final class Coordinator {
        private var didConfigure = false

        func configure(window: NSWindow?) {
            guard !didConfigure, let window else { return }
            didConfigure = true
            window.setContentSize(NSSize(width: 820, height: 560))
        }
    }
}

enum SettingsDestination: CaseIterable, Hashable, Identifiable {
    case general
    case text
    case window
    case shell
    case keyboard
    case advanced

    case profiles
    case data

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .profiles: return "Profiles"
        case .text: return "Text"
        case .window: return "Window"
        case .shell: return "Shell"
        case .keyboard: return "Keyboard"
        case .advanced: return "Advanced"
        case .data: return "Data"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .profiles: return "person.2.badge.gearshape"
        case .text: return "textformat"
        case .window: return "macwindow"
        case .shell: return "terminal"
        case .keyboard: return "keyboard"
        case .advanced: return "slider.horizontal.3"
        case .data: return "externaldrive.badge.checkmark"
        }
    }

    var isProfileDriven: Bool {
        switch self {
        case .text, .window, .shell, .keyboard, .advanced:
            return true
        case .general, .profiles, .data:
            return false
        }
    }
}

/// App-level (non-profile) settings, persisted via AppStorage
struct GeneralSettingsView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var windowGroups: WindowGroupStore
    @AppStorage("newTabsUseCurrentDirectory") private var newTabsUseCurrentDirectory = true
    @AppStorage("newTabsUseCurrentProfile") private var newTabsUseCurrentProfile = true
    @AppStorage("useCommandDigitsForTabs") private var useCommandDigitsForTabs = true
    @AppStorage("restoredRowsLimit") private var restoredRowsLimit = 1_000
    @AppStorage("startupMode") private var startupMode = "default"
    @AppStorage("startupProfileID") private var startupProfileID = ""
    @AppStorage("startupWindowGroupID") private var startupWindowGroupID = ""
    @AppStorage("useMetalRenderer") private var useMetalRenderer = true
    @State private var errorMessage: String?

    @MainActor
    init() {
        self.init(windowGroups: AppModel.shared.windowGroups)
    }

    init(windowGroups: WindowGroupStore) {
        _windowGroups = ObservedObject(wrappedValue: windowGroups)
    }

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

#Preview("Settings") {
    SettingsView(
        issueCenter: SettingsPreviewData.issueCenter,
        recovery: SettingsPreviewData.recovery
    )
    .environmentObject(SettingsPreviewData.profiles)
    .environmentObject(SettingsPreviewData.themes)
    .defaultAppStorage(SettingsPreviewData.defaults)
    .frame(width: 960, height: 640)
}

#Preview("General") {
    GeneralSettingsView(windowGroups: SettingsPreviewData.windowGroups)
        .environmentObject(SettingsPreviewData.profiles)
        .defaultAppStorage(SettingsPreviewData.defaults)
        .frame(width: 640, height: 520)
}
