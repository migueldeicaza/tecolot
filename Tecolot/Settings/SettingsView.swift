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
    @State private var navigator = SettingsNavigator.shared

    @State private var query = ""
    /// The page that limits the search results, or nil for all pages.
    @State private var searchScope: SettingsDestination?
    /// False after the user opens a result, while the query stays typed.
    @State private var showsSearchResults = false
    @State private var revealRequest: SettingsRevealRequest?
    @State private var revealSerial = 0
    @FocusState private var searchIsFocused: Bool

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
        // Search once for the sidebar and the results list.
        let results = isSearching ? searchResults : []
        NavigationSplitView {
            Group {
                if isSearching {
                    searchSidebar(pages: SettingsSearchEngine.pages(in: results))
                } else {
                    pageSidebar
                }
            }
            .navigationTitle("Settings")
            // Wide enough for "Keyboard and Mouse" without truncation.
            .navigationSplitViewColumnWidth(min: 205, ideal: 215)
        } detail: {
            if isSearching && showsSearchResults {
                SettingsSearchResultsView(
                    query: query.trimmingCharacters(in: .whitespaces),
                    scope: searchScope,
                    results: scoped(results),
                    open: reveal
                )
            } else {
                detail
            }
        }
        // The search field reads this action from inside the searchable view.
        .onSubmit(of: .search, openFirstSearchResult)
        .searchable(text: $query, placement: .sidebar, prompt: "Search Settings")
        .searchFocused($searchIsFocused)
        .frame(minWidth: 800, minHeight: 560)
        .background(SettingsKeyHandler(focusSearch: {
            searchIsFocused = true
        }))
        .background(SettingsWindowCloseObserver(windowWillClose: resetSearch))
        .background(SettingsSpotlightHost(request: revealRequest))
        .onAppear(perform: repairActiveProfileSelection)
        .onChange(of: navigator.pendingDestination, initial: true) {
            if let pending = navigator.pendingDestination {
                // A search would hide the page that the caller asked for.
                resetSearch()
                destination = pending
                navigator.pendingDestination = nil
            }
        }
        .onChange(of: navigator.pendingSetting, initial: true) {
            if let pending = navigator.pendingSetting {
                navigator.pendingSetting = nil
                resetSearch()
                reveal(pending)
            }
        }
        .onChange(of: query) {
            showsSearchResults = isSearching
            if let searchScope, !SettingsSearchEngine.pages(in: searchResults).contains(searchScope) {
                self.searchScope = nil
            }
        }
        .onChange(of: destination) {
            // The spotlight is for a row of the page that search opened.
            if let revealRequest, revealRequest.id.entry.destination != destination {
                self.revealRequest = nil
            }
        }
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

    // MARK: - Search

    private enum SearchSidebarItem: Hashable {
        case allSettings
        case page(SettingsDestination)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var searchResults: [SettingsSearchResult] {
        SettingsSearchEngine.search(
            query,
            context: SettingsSearchContext(
                profilesAreEmpty: profiles.profiles.isEmpty,
                updatesEnabled: UpdaterModel.shared.updatesEnabled
            )
        )
    }

    /// The results of the page chosen in the sidebar, or all of them.
    private func scoped(_ results: [SettingsSearchResult]) -> [SettingsSearchResult] {
        guard let searchScope else {
            return results
        }
        return results.filter { $0.entry.destination == searchScope }
    }

    private var searchSidebarSelection: Binding<SearchSidebarItem?> {
        Binding(get: {
            guard showsSearchResults else {
                return nil
            }
            return searchScope.map(SearchSidebarItem.page) ?? .allSettings
        }, set: { item in
            switch item {
            case .allSettings:
                searchScope = nil
            case .page(let page):
                searchScope = page
            case nil:
                return
            }
            showsSearchResults = true
        })
    }

    /// Replaces the page list while a query is typed: all results, then
    /// each page that has results.
    private func searchSidebar(pages: [SettingsDestination]) -> some View {
        List(selection: searchSidebarSelection) {
            Label("All Settings", systemImage: "magnifyingglass")
                .tag(SearchSidebarItem.allSettings)
            Section {
                ForEach(pages) { page in
                    Label(page.title, systemImage: page.systemImage)
                        .tag(SearchSidebarItem.page(page))
                }
            }
        }
    }

    private func openFirstSearchResult() {
        if let first = scoped(searchResults).first {
            reveal(first.id)
        }
    }

    /// A closed Settings window opens again without the last search.
    private func resetSearch() {
        query = ""
        searchScope = nil
        showsSearchResults = false
        revealRequest = nil
    }

    /// Opens the page of a setting and puts the spotlight on its row.
    private func reveal(_ id: SettingID) {
        let entry = id.entry
        destination = SettingsDestination.repairedDestination(
            entry.destination,
            profilesAreEmpty: profiles.profiles.isEmpty
        )
        showsSearchResults = false
        revealSerial += 1
        revealRequest = destination == entry.destination && entry.kind != .page
            ? SettingsRevealRequest(id: id, serial: revealSerial)
            : nil
    }

    // MARK: - Pages

    private var pageSidebar: some View {
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
                    manageProfiles: {
                        destination = .manageProfiles
                    }
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
                .navigationTitle(SettingsDestination.general.title)
        case .tabs:
            TabsSettingsView()
        case .panes:
            PanesSettingsView()
        case .notifications:
            NotificationsSettingsView()
        case .manageProfiles:
            ManageProfilesSettingsView(activeProfileID: activeProfileSelection)
                .navigationTitle(SettingsDestination.manageProfiles.title)
        case .appearance, .window, .shell, .keyboardAndMouse, .terminal:
            profileSettingsDetail(for: currentDestination)
        case .data:
            DataRecoveryView(issueCenter: issueCenter, recovery: recovery)
                .navigationTitle(SettingsDestination.data.title)
        case .crashReports:
            CrashReportsView()
                .navigationTitle(SettingsDestination.crashReports.title)
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
        nonmutating set {
            selectedProfileID = newValue?.uuidString ?? SettingsView.selectedProfileIDDefault
        }
    }

    private var activeProfileSelection: Binding<TerminalProfile.ID?> {
        Binding(get: {
            activeProfileID
        }, set: {
            activeProfileID = $0
        })
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
        guard let activeProfileID else {
            return
        }
        do {
            self.activeProfileID = try profiles.duplicate(activeProfileID).id
            destination = SettingsDestination.destinationAfterCreatingProfile(from: currentDestination)
        } catch {
            profileErrorMessage = error.localizedDescription
        }
    }

    private func makeProfileDefault() {
        guard let activeProfileID else {
            return
        }
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

/// Handles the keys of the Settings window that must not depend on which
/// view has focus: Escape closes the window and Command-F starts a search.
struct SettingsKeyHandler: NSViewRepresentable {
    /// Moves the keyboard focus to the search field.
    var focusSearch: () -> Void = {}

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
        context.coordinator.focusSearch = focusSearch
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
        var focusSearch: () -> Void = {}
        private var monitor: Any?

        func startMonitoring() {
            guard monitor == nil else {
                return
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard
                    let self,
                    let window,
                    event.window === window,
                    window.attachedSheet == nil else {
                    return event
                }
                // The monitor runs before the main menu, so Command-F does
                // not reach the Find command of the terminal.
                // Caps Lock changes the letter and adds a flag of its own.
                let modifiers = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting(.capsLock)
                if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
                    focusSearch()
                    return nil
                }
                guard event.keyCode == 53 else {
                    return event
                }

                if let editor = window.firstResponder as? NSTextView {
                    // Some text is being edited. Do not close the window, let
                    // the text view handle the escape button. This includes
                    // a search field with a query or with text that an
                    // input method has not finished. An empty search field
                    // has nothing to cancel, so Escape closes from it.
                    let isEmptySearch = editor.delegate is NSSearchField
                        && editor.string.isEmpty
                        && !editor.hasMarkedText()
                    if !isEmptySearch {
                        return event
                    }
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
    case crashReports

    case appearance
    case window
    case shell
    case keyboardAndMouse
    case terminal
    case manageProfiles

    static let appPages: [Self] = [.general, .tabs, .panes, .notifications, .data, .crashReports]
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
        case .crashReports:
            return "Crash Reports"
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
        case .crashReports:
            return "exclamationmark.triangle"
        }
    }

    var isProfileDriven: Bool {
        switch self {
        case .appearance, .window, .shell, .keyboardAndMouse, .terminal:
            return true
        case .general, .tabs, .panes, .notifications, .manageProfiles, .data, .crashReports:
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
