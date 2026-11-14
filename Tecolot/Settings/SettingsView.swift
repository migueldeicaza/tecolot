//
//  SettingsView.swift
//  Tecolot
//
//  Settings window: App pages edit shared preferences. Profile pages edit
//  the profile selected in the Settings sidebar.
//
import Combine
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var issueCenter: PersistenceIssueCenter
    let recovery: DataRecoveryCoordinator
    @EnvironmentObject private var profiles: ProfileStore
    private let secureKeyboardEntry: SecureKeyboardEntry

    @State private var destination: SettingsDestination? = .general
    static let selectedProfileIDKey = "settingsSelectedProfileID"
    static let selectedProfileIDDefault = ""

    @AppStorage(selectedProfileIDKey) private var selectedProfileID = SettingsView.selectedProfileIDDefault
    @State private var profileErrorMessage: String?

    @MainActor
    init(
        issueCenter: PersistenceIssueCenter,
        recovery: DataRecoveryCoordinator,
        secureKeyboardEntry: SecureKeyboardEntry? = nil
    ) {
        self.issueCenter = issueCenter
        self.recovery = recovery
        self.secureKeyboardEntry = secureKeyboardEntry ?? .shared
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Section("App") {
                    ForEach(SettingsDestination.appPages) { destination in
                        Label(sidebarTitle(for: destination), systemImage: destination.systemImage)
                            .tag(destination)
                    }
                }
                Section("Profile") {
                    ProfilePickerRow(
                        profiles: profiles.profiles,
                        defaultProfileID: profiles.defaultProfileID,
                        selection: activeProfileSelection,
                        createProfile: createProfile,
                        duplicateProfile: duplicateProfile,
                        makeProfileDefault: makeProfileDefault,
                        manageProfiles: { destination = .manageProfiles }
                    )
                    .selectionDisabled()
                    ForEach(SettingsDestination.visibleProfileEditingPages(profilesAreEmpty: profiles.profiles.isEmpty)) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(destination)
                    }
                    Divider()
                    Label(SettingsDestination.manageProfiles.title, systemImage: SettingsDestination.manageProfiles.systemImage)
                        .tag(SettingsDestination.manageProfiles)
                }
            }
            .navigationTitle("Settings")
            .frame(minWidth: 170)
        } detail: {
            detail
        }
        .frame(minWidth: 800, minHeight: 560)
        .background(SettingsEscapeKeyHandler())
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
        activeProfileID.flatMap {
            profiles.profile(withID: $0)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch currentDestination {
        case .general:
            GeneralSettingsView(secureKeyboardEntry: secureKeyboardEntry)
        case .tabs:
            TabsSettingsView()
        case .panes:
            PanesSettingsView()
        case .notifications:
            NotificationsSettingsView()
        case .manageProfiles:
            ManageProfilesSettingsView(activeProfileID: activeProfileSelection)
        case .appearance, .window, .shell, .keyboardAndMouse, .terminal:
            profileSettingsDetail(for: currentDestination)
        case .data:
            DataRecoveryView(issueCenter: issueCenter, recovery: recovery)
        }
    }

    @ViewBuilder
    private func profileSettingsDetail(for destination: SettingsDestination) -> some View {
        if
            let section = ProfileSettingsSection(destination: destination),
            let profile = activeProfile {
            ProfileSettingsPage(section: section, profile: profile, update: updateActiveProfile)
                .navigationSubtitle("\(profile.name) profile")
        } else {
            ContentUnavailableView {
                Label("No Profile to Edit", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Create a profile before you change these settings.")
            } actions: {
                Button("New Profile", action: createProfile)
            }
        }
    }

    private var activeProfileID: TerminalProfile.ID? {
        get { UUID(uuidString: selectedProfileID) }
        nonmutating set { selectedProfileID = newValue?.uuidString ?? SettingsView.selectedProfileIDDefault }
    }

    private var activeProfileSelection: Binding<TerminalProfile.ID?> {
        Binding(get: { activeProfileID }, set: { activeProfileID = $0 })
    }

    static func repairedProfileID(
        selectedID: TerminalProfile.ID?,
        profileIDs: [TerminalProfile.ID],
        defaultID: TerminalProfile.ID
    ) -> TerminalProfile.ID? {
        if let selectedID, profileIDs.contains(selectedID) {
            return selectedID
        }
        return profileIDs.isEmpty ? nil : defaultID
    }

    private func repairActiveProfileSelection() {
        activeProfileID = Self.repairedProfileID(
            selectedID: activeProfileID,
            profileIDs: profiles.profiles.map(\.id),
            defaultID: profiles.defaultProfileID
        )
        destination = SettingsDestination.repairedDestination(
            currentDestination,
            profilesAreEmpty: profiles.profiles.isEmpty
        )
    }

    private func createProfile() {
        do {
            activeProfileID = try profiles.addNewProfile().id
            destination = SettingsDestination.destinationAfterCreatingProfile(from: currentDestination)
        } catch {
            profileErrorMessage = error.localizedDescription
        }
    }

    private func duplicateProfile() {
        guard let activeProfileID else { return }
        do {
            self.activeProfileID = try profiles.duplicate(activeProfileID).id
            destination = SettingsDestination.destinationAfterCreatingProfile(from: currentDestination)
        } catch {
            profileErrorMessage = error.localizedDescription
        }
    }

    private func makeProfileDefault() {
        guard let activeProfileID else { return }
        do {
            try profiles.setDefault(activeProfileID)
        } catch {
            profileErrorMessage = error.localizedDescription
        }
    }

    /// Returns false when the change could not be stored, so callers that
    /// coordinate multi-step operations (theme forking) can roll back.
    private func updateActiveProfile(_ mutate: (inout TerminalProfile) -> Void) -> Bool {
        guard var profile = activeProfile else {
            return false
        }
        mutate(&profile)
        do {
            try profiles.update(profile)
            return true
        } catch {
            profileErrorMessage = error.localizedDescription
            return false
        }
    }

    private var profileErrorPresentation: Binding<Bool> {
        Binding(
            get: {
                profileErrorMessage != nil
            },
            set: {
                if !$0 {
                    profileErrorMessage = nil
                }
            }
        )
    }
}

struct SettingsEscapeKeyHandler: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView(coordinator: context.coordinator)
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        context.coordinator.window = nsView.window
    }

    static func dismantleNSView(_ nsView: WindowReaderView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class WindowReaderView: NSView {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not available")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.window = window
        }
    }

    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        var closeWindow: (NSWindow) -> Void = { window in
            window.performClose(nil)
        }
        private var monitor: Any?

        func startMonitoring() {
            guard monitor == nil else {
                return
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard
                    let self,
                    let window,
                    event.keyCode == 53,
                    event.window === window,
                    window.attachedSheet == nil else {
                    return event
                }
                
                if window.firstResponder is NSTextView {
                    // Some text is being edited. Do not close the window, let
                    // the text view handle the escape button.
                    return event
                }
                
                closeWindow(window)
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

enum SettingsDestination: CaseIterable, Hashable, Identifiable {
    case general
    case tabs
    case panes
    case notifications
    case data

    case appearance
    case window
    case shell
    case keyboardAndMouse
    case terminal
    case manageProfiles

    static let appPages: [Self] = [.general, .tabs, .panes, .notifications, .data]
    static let profilePages: [Self] = [.appearance, .window, .shell, .keyboardAndMouse, .terminal, .manageProfiles]

    static func destinationAfterCreatingProfile(from destination: Self) -> Self {
        destination.isProfileDriven || destination == .manageProfiles ? destination : .appearance
    }

    static func repairedDestination(_ destination: Self, profilesAreEmpty: Bool) -> Self {
        profilesAreEmpty && destination.isProfileDriven ? .manageProfiles : destination
    }

    static func visibleProfileEditingPages(profilesAreEmpty: Bool) -> [Self] {
        profilesAreEmpty ? [] : profilePages.filter(\.isProfileDriven)
    }

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .tabs:
            return "Tabs"
        case .panes:
            return "Panes"
        case .notifications:
            return "Notifications"
        case .manageProfiles:
            return "Manage Profiles"
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
        case .data:
            return "Data"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .tabs:
            return "rectangle.topthird.inset.filled"
        case .panes:
            return "rectangle.split.2x1"
        case .notifications:
            return "bell"
        case .manageProfiles:
            return "person.2.badge.gearshape"
        case .appearance:
            return "textformat"
        case .window:
            return "macwindow"
        case .shell:
            return "terminal"
        case .keyboardAndMouse:
            return "keyboard"
        case .terminal:
            return "slider.horizontal.3"
        case .data:
            return "externaldrive.badge.checkmark"
        }
    }

    var isProfileDriven: Bool {
        switch self {
        case .appearance, .window, .shell, .keyboardAndMouse, .terminal:
            return true
        case .general, .tabs, .panes, .notifications, .manageProfiles, .data:
            return false
        }
    }
}

#Preview("Settings") {
    SettingsView(
        issueCenter: SettingsPreviewData.issueCenter,
        recovery: SettingsPreviewData.recovery,
        secureKeyboardEntry: SecureKeyboardEntry(isEnabled: false)
    )
    .environmentObject(SettingsPreviewData.profiles)
    .environmentObject(SettingsPreviewData.themes)
    .environmentObject(SettingsPreviewData.themeIndex)
    .environmentObject(SystemAppearance(isDark: false))
    .defaultAppStorage(SettingsPreviewData.defaults)
    .frame(width: 960, height: 640)
}
